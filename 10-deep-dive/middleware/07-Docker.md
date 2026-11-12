# Docker（namespace / cgroup / OverlayFS / 运行时调用链）

> 面试权重：5/5　｜　追问深度：**L5（clone() 命名空间 / cgroup v2 控制器 / overlayfs 写时复制 / runc 启动链）**
> 一句话定位：**容器不是轻量级虚拟机，而是"被内核隔离了视野、被 cgroup 限了资源、被 OverlayFS 拼出了根文件系统"的普通进程。** Docker 只是把这套内核能力（namespace + cgroup + UnionFS + capabilities/seccomp）包装成镜像与命令行的工具。

**本文件用法**：能说清"容器 = 进程 + 隔离 + 限额 + 镜像"就过了 L1；能说出 `clone()` 的 flag 和 overlayfs 的 lower/upper/merged，才到 L5。你的 报告平台 沙箱执行不可信代码，就是这些限制的实战。
[返回深度追问索引](../00-索引.md)

---

## L1 一句话答案（10 秒能说出口）

Docker 用 **namespace** 给进程隔离"视野"（PID、网络、挂载点、主机名、IPC、用户、cgroup），用 **cgroup** 限制"用量"（CPU、内存、IO、进程数），用 **OverlayFS** 把只读镜像层 + 可写容器层叠成根文件系统，用 **capabilities/seccomp** 收窄"权限"。容器内 `pid 1` 在宿主机上就是普通进程，**共享宿主机内核**——这是它与虚拟机（各自一套内核、硬件虚拟化）的本质区别。

---

## L2 原理层：隔离、限额、分层、网络

### 2.1 namespace 七件套（隔离"看得见什么"）

| namespace | 隔离内容 | 直观效果 |
|---|---|---|
| **PID** | 进程号空间 | 容器内看到 pid 1 是自己的 init，看不到宿主机进程 |
| **NET** | 网络设备、协议栈、端口、路由 | 独立 IP/网卡，端口隔离（需 `-p` 映射） |
| **MNT** | 挂载点表 | 容器有自己的 `/`，看不到宿主机其他挂载 |
| **UTS** | 主机名与域名 | 可设独立 hostname |
| **IPC** | System V IPC / POSIX 消息队列 / 共享内存 | 进程间通信不串 |
| **USER** | UID/GID 映射 | 容器内 root 可映射为宿主机非 root（rootless） |
| **CGROUP** | cgroup 根视图 | 容器内看不到宿主机 cgroup 树（v2） |

> 记忆：**PID 看进程、NET 看网卡、MNT 看文件、UTS 看主机名、IPC 看共享内存、USER 看身份、CGROUP 看限额树。**

### 2.2 cgroup：限制"能用多少"（v1 vs v2）

| 资源 | cgroup v1（分子系统树） | cgroup v2（统一层级） |
|---|---|---|
| CPU | `cpu.cfs_quota_us` / `cpu.cfs_period_us` | `cpu.max`（如 `50000 100000` = 0.5 核） |
| 内存 | `memory.limit_in_bytes` / `memory.memsw.*` | `memory.max` / `memory.high` / `memory.swap.max` |
| 进程数 | `pids.max` | `pids.max` |
| IO | `blkio.throttle.*` | `io.max` |

Docker 参数映射：`--memory 512m` → `memory.max`；`--cpus 1.5` → `cpu.max=150000 100000`；`--cpuset-cpus` → `cpuset.cpus`；`--pids-limit` → `pids.max`。**超内存触发 cgroup OOM killer（容器 exit 137），超 CPU 只是被 throttle（`cpu.stat` 的 `throttled_time` 上涨，表现为延迟抖动）。**

### 2.3 OverlayFS：镜像分层与写时复制

```
镜像层（只读，多层叠加）              容器层（可写）
  lowerdir: overlay2/<id3>/diff   ← 第 3 层（COPY app.jar）
            overlay2/<id2>/diff   ← 第 2 层（RUN apt-get）
            overlay2/<id1>/diff   ← 底层（FROM ubuntu）
  upperdir: overlay2/<idc>/diff   ← 容器可写层
  workdir:  overlay2/<idc>/work
  merged:   overlay2/<idc>/merged ← 容器看到的 /
```

- **读**：从 upper 逐层向下，找到第一个同名文件（最上层可见）。
- **写（CoW）**：改 lower 中的文件要先**整个复制到 upper**（copy-up）再改——**改大文件很贵**，别在容器里改镜像层大文件。
- **删除**：在 upper 创建 **whiteout**（字符设备 `0:0` / `.wh.` 前缀）遮住下层文件，删除目录用 opaque 目录。
- 镜像层**只读**，容器层**可写但随容器删除消失**；`docker commit` 可把容器层固化成新镜像层。

### 2.4 镜像层与构建缓存

- **每条会改文件系统的指令产生一层**：`RUN` / `COPY` / `ADD` 产生层；`ENV`/`CMD`/`LABEL`/`EXPOSE` 只改元数据（BuildKit）。
- **缓存 key** = 父层 + 指令 + 上下文文件校验和。`COPY pom.xml` 命中 → `RUN mvn dependency:go-offline` 命中；源码一变后面全失效，**所以依赖要放在源码之前 COPY**。
- 优化：`.dockerignore` 排除 node_modules/.git、合并 `RUN` 并清理（`apt update && install && rm -rf /var/lib/apt/lists/*`）、`--mount=type=cache` 缓存 Maven/npm、**多阶段构建**只保留产物。

### 2.5 网络模式

| 模式 | 行为 | 场景 |
|---|---|---|
| `bridge`（默认） | 容器连 `docker0` 网桥，配 veth pair + 独立 IP；出网 iptables `MASQUERADE`，入网靠 `-p` 做 **DNAT** | 绝大多数应用 |
| `host` | 共享宿主机 network namespace | 高性能/端口直用（牺牲隔离） |
| `none` | 只有 lo，无网卡 | **安全沙箱跑不可信代码** |
| `container:<id>` | 共享另一个容器的 netns | sidecar / 代理 |
| 自定义 bridge/overlay/macvlan | 用户网络，内置 DNS、隔离更好 | 多容器编排 |

**`-p 8080:80` 原理**：在 `DOCKER` 链加 `DNAT --to-destination 172.17.0.2:80`；出网走 `POSTROUTING MASQUERADE` 源地址伪装。

### 2.6 运行时调用链

```
docker CLI ──HTTP/gRPC──► dockerd（镜像/网络/卷/API，生成 OCI spec）
                              ▼
                         containerd（镜像拉取、容器生命周期）
                              ▼
                     containerd-shim（每容器一个常驻）──────► runc（创建后即退出）
                              ▼                                   │
                     容器内 pid 1 进程（宿主机普通进程，父进程是 shim）
```

- **shim 的作用**：容器进程的父进程不是 containerd（daemon 重启不影响容器）、接管 stdio/退出码、支持 `docker exec`。`runc` 只负责"按 OCI spec 创建并 exec"，不常驻。

---

## L3 底层层：一次 `docker run` 内核发生了什么

### 3.1 创建容器的内核动作序列

```
1. 镜像拉取解压到 overlay2 diff 目录 → 生成 lowerdir 列表
2. mount("overlay", merged, "overlay", "lowerdir=...,upperdir=...,workdir=...")
3. clone/unshare 创建进程：CLONE_NEWPID | NEWNET | NEWNS | NEWUTS | NEWIPC | NEWUSER | NEWCGROUP
4. 在 mnt ns 内 pivot_root() 到 merged → 旧根移到 /put_old 后卸载
5. 在 net ns 内创建 veth pair（一端 eth0、一端接 docker0），配 IP/默认路由
6. 写 cgroup v2：cpu.max / memory.max / pids.max / io.max
7. 收权限：capabilities（丢大部分）、seccomp profile、AppArmor/SELinux、no_new_privs、--user 降权
8. execve 容器入口命令（java -jar app.jar）
```

### 3.2 宿主机视角

```bash
ps -ef | grep java       # 容器内 pid 1 在宿主机上是普通进程，例如 pid 12345
docker exec -it app ps -ef   # 容器内看到 pid 1 = java
# 对应关系：宿主机 12345 ↔ 容器内 1
```

**结论**：没有虚拟化层，只有内核的命名空间视图 + cgroup 限额 + 拼接的 rootfs，所以**共享内核**：`uname` 显示宿主机内核、内核漏洞影响宿主机、不能跑不同内核版本。

### 3.3 安全边界

容器默认比 VM 弱：共享内核；默认 capabilities 非空（如 `CAP_NET_RAW`）；**挂 `docker.sock` = 交出宿主机 root**；`--privileged` 几乎无隔离。加固见 2.6 与代码中的沙箱命令。

---

## L4 追问树（面试官一路往下问，你能撑到第几层？）

> 规则：第 1-3 层必备，4-6 层拉开差距，7 层以后是加分。

### 第 1 层｜Docker 是什么？和虚拟机本质区别？
**答**：Docker 是**进程级隔离 + 镜像分发**工具。VM 用 Hypervisor 虚拟硬件、跑独立内核（强隔离、重、启动秒级）；容器共享宿主机内核，用 namespace 隔离视野、cgroup 限资源、OverlayFS 拼 rootfs（弱隔离、轻、启动毫秒级、密度高）。**一句话：VM 虚拟硬件，容器虚拟"视野"。**

### 第 2 层｜Docker 靠什么隔离进程？
**答**：Linux namespace：PID（进程号）、NET（网络栈）、MNT（挂载点）、UTS（主机名）、IPC（进程间通信）、USER（UID 映射）、CGROUP（限额树视图）。`clone()`/`unshare()` 带这些 flag 创建进程，进程就"看不到"外面的资源。**隔离的是可见性，不是资源用量。**

### 第 3 层｜资源限额靠什么？cgroup v1 和 v2 区别？
**答**：cgroup。v1 每个资源独立层级（cpu、memory、blkio、pids…），挂载点分散；v2 统一层级，用 `cpu.max`、`memory.max`、`pids.max`、`io.max` 限流，支持 `memory.high` 软限与 `memory.events` 统计。超内存被 cgroup OOM killer 杀（exit 137），超 CPU 被 throttle。**Docker 的 `--memory`/`--cpus`/`--pids-limit` 最终就是写这些文件。**

### 第 4 层｜镜像分层怎么实现？UnionFS 是什么？
**答**：镜像由多个**只读层**叠加，联合文件系统（Linux 默认 overlay2）把 `lowerdir`（镜像层）+ `upperdir`（容器可写层）+ `workdir` 挂到 `merged`，容器看到合并后的 `/`，同名文件以最上层为准。好处：层可复用（多镜像共享基础层，省磁盘和拉取时间）、构建可缓存。

### 第 5 层｜写时复制具体怎么发生？删文件呢？
**答**：读时直接从下层读；**写时**若文件在下层，先把整个文件 copy-up 到 upper 再改（大文件修改很贵）；**删除时**在 upper 创建 whiteout（`.wh.` / `0:0`）遮住下层同名文件，或 opaque 目录遮整个目录。所以容器里 `rm` 大文件不释放镜像层空间，只是加标记。

### 第 6 层｜构建缓存怎么工作？Dockerfile 怎么优化？
**答**：每条指令以"父层+指令+上下文校验和"为 key 查缓存。所以**易变的放后面**：先 `COPY pom.xml` + `RUN mvn dependency:go-offline`，再 `COPY src`；`.dockerignore` 排除无关文件；`RUN` 合并并清理；多阶段构建只把 jar 拷进运行时镜像；最终用 `jre-slim`/`distroless` 而非 `jdk-full`/`ubuntu`。

### 第 7 层｜`docker run` 背后到底调了哪些组件？
**答**：CLI → `dockerd`（准备镜像/网络/卷，生成 OCI spec）→ `containerd`（拉镜像、生命周期）→ `containerd-shim`（每容器常驻，接管 stdio/退出码）→ `runc`（`clone/unshare` 建 namespace、写 cgroup、`pivot_root`、exec 入口后退出）。**容器进程父进程是 shim，所以 daemon 重启容器不挂。**

### 第 8 层｜容器网络怎么通？`-p` 端口映射原理？
**答**：默认 bridge：宿主机建 `docker0`，每个容器一对 **veth pair**（容器端 eth0，宿主机端接 docker0），容器 IP 由 docker0 网段分配，出网 iptables `MASQUERADE` 做 SNAT。`-p 8080:80` 在 `DOCKER` 链加 `DNAT --to-destination 容器IP:80`，外部访问宿主机 8080 被改写到容器 80。

### 第 9 层｜host / none / container 网络模式什么时候用？
**答**：`host` 共享宿主机网络栈（端口直接用、性能最好、无隔离，适合代理/监控）；`none` 只有 lo（**跑不可信代码的沙箱首选**，直接断网）；`container:<id>` 共享另一个容器 netns（sidecar、service mesh）。自定义 bridge 有内置 DNS，比默认 bridge 更适合多容器。

### 第 10 层｜容器里的 root 和宿主机 root 一样吗？
**答**：默认 **UID 相同**（容器内 root = 宿主机 root），只是 caps 被裁剪、挂载受限，逃逸后危害大。用 `--user` 以非 root 运行，或开 **user namespace**（rootless docker / `--userns-remap`）把容器 root 映射成宿主机普通 UID。

### 第 11 层｜怎么给"不可信代码"做 Docker 沙箱？
**答**：纵深防御：`--network none`（断网）、`--read-only` + `--tmpfs /tmp`（根文件系统只读）、`--memory`/`--cpus`/`--pids-limit`（防 fork 炸弹）、`--cap-drop=ALL`、`--security-opt no-new-privileges`、non-root `--user`、seccomp 默认 profile、**禁止挂 docker.sock、禁止 `--privileged`**、执行超时后 `docker kill`、每任务独立容器不复用。容器隔离非绝对安全，生产可加 gVisor/Kata/Firecracker。

### 第 12 层（终局）｜从敲下 `docker run` 到业务进程启动，内核层依次发生了什么？
**答**：dockerd 生成 OCI spec → containerd 调 shim → shim 调 runc → runc 创建子进程并 `unshare` 各 namespace（`CLONE_NEW*`，rootless 加 `NEWUSER`）→ mnt ns 里 `mount("overlay", lower+upper+work)` 再 `pivot_root` 到 merged → net ns 里建 veth pair 接 docker0、配 IP/路由 → 写 cgroup v2 的 `cpu.max/memory.max/pids.max` → 设 capabilities、seccomp/AppArmor、`no_new_privs`、降权 → `execve("/usr/bin/java", ...)`。此时宿主机 `ps` 能看到这个 java 进程，`/proc/<pid>/ns/*` 指向新 namespace，`/sys/fs/cgroup/...` 下能看到限额文件。**全程内核只做"创建视图 + 限额 + 替换根 + 收窄权限"，没有启动任何新内核。**

---

## L5 名词拆解表（每个名词都拆开）

| 名词 | 是什么 | 为什么存在 | 面试追问点 |
|---|---|---|---|
| namespace | 内核的资源视图隔离机制 | 让进程"看不到"外面资源 | 七种分别隔离什么、`clone` flag |
| cgroup | 资源限额与统计机制 | 限制 CPU/内存/IO/进程数 | v1 vs v2、`memory.max`、exit 137 |
| OverlayFS | 联合文件系统（overlay2 驱动） | 镜像分层复用 + 容器可写层 | lower/upper/merged、whiteout |
| copy-up | 写时把下层文件复制到上层 | 保持镜像层只读 | 修改大文件为何慢 |
| whiteout | 上层"遮住"下层的标记 | 表达删除而不改下层 | `.wh.` 前缀、opaque 目录 |
| 镜像层 | 只读 fs diff + 元数据 | 共享、缓存、分发 | 哪些指令产生层 |
| 构建缓存 | 按指令与上下文校验和复用层 | 加速构建 | 为什么依赖要先 COPY |
| 多阶段构建 | 多个 `FROM`，只拷产物 | 减小最终镜像 | `COPY --from=`、distroless |
| dockerd / containerd | API 守护进程 / 容器运行时管理 | 接口与生命周期分离 | 与 K8s CRI 的关系 |
| containerd-shim | 每容器常驻中间进程 | daemon 重启不影响容器 | 父进程是谁、exec 怎么实现 |
| runc | OCI 运行时实现 | 按 spec 真正创建容器 | 为何创建完就退出 |
| veth pair | 成对虚拟网卡 | 连接容器 netns 与网桥 | 端口映射与 NAT |
| capabilities / seccomp | 细粒度权限 / 系统调用过滤 | 最小权限原则 | `--cap-drop=ALL`、默认 profile |

---

## 代码验证

```dockerfile
# 1) 多阶段构建 + 依赖缓存 + 瘦运行时（报告平台 后端镜像）
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app
COPY pom.xml .
RUN --mount=type=cache,target=/root/.m2 mvn -B dependency:go-offline   # 依赖层缓存
COPY src ./src
RUN --mount=type=cache,target=/root/.m2 mvn -B package -DskipTests

FROM eclipse-temurin:21-jre-alpine
RUN addgroup -S app && adduser -S app -G app          # 非 root
WORKDIR /app
COPY --from=build /app/target/*.jar app.jar
USER app
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/actuator/health | grep -q UP || exit 1
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-jar", "app.jar"]
```

```bash
# 2) 不可信代码沙箱（报告平台的代码执行器）：能限的都限上
docker run --rm \
  --network none \                          # 断网，防外连/横向
  --read-only \                             # 根文件系统只读
  --tmpfs /tmp:rw,noexec,nosuid,size=64m \  # 只给临时目录可写且不可执行
  --memory 256m --memory-swap 256m \        # 禁用 swap，超限 OOM
  --cpus 0.5 \                              # cpu.max = 50000 100000
  --pids-limit 64 \                         # 防 fork 炸弹
  --cap-drop=ALL \                          # 丢弃所有 capabilities
  --security-opt no-new-privileges \
  --user 1000:1000 \
  -v /srv/jobs/42:/job:ro \                 # 只读挂载代码
  job-runner:py311 python /job/main.py

# 3) 验证限额生效
docker stats --no-stream job-runner
docker inspect -f '{{.State.OOMKilled}} {{.State.ExitCode}}' <container>
cat /sys/fs/cgroup/system.slice/docker-<id>.scope/memory.max   # v2 路径
cat /sys/fs/cgroup/system.slice/docker-<id>.scope/cpu.max

# 4) 网络与镜像分层
iptables -t nat -L DOCKER -n | grep 8080    # 看 DNAT 规则
docker history --no-trunc app-backend:latest
docker run --rm -it --entrypoint sh alpine -c 'mount | head'   # 看 overlay 挂载
```

---

## 高频错误（面试官最爱抓的）

| 错误说法 | 正确说法 |
|---|---|
| 「容器是轻量级虚拟机」 | 共享宿主机内核，只是 namespace/cgroup/rootfs 包装的进程 |
| 「namespace 能限制 CPU 和内存」 | namespace 管可见性，cgroup 管资源限额 |
| 「容器里改文件会修改镜像」 | 镜像层只读，改动在容器可写层（copy-up/whiteout） |
| 「`rm` 镜像里的大文件能释放空间」 | 只是 whiteout 遮住，层还在，最终镜像大小不变 |
| 「容器的 pid 1 和宿主机一样」 | 是容器入口进程，宿主上另有 PID，父进程是 shim |
| 「`--memory` 超了会变慢」 | 触发 cgroup OOM killer，进程被杀（exit 137） |
| 「挂 docker.sock 只是方便」 | 等于把宿主机 root 交给容器内进程，沙箱绝不能挂 |

---

## 关联文件

- 项目沙箱实战：报告平台的不可信代码执行（`--network none` + 只读 + 限额）
- 异步任务如何触发容器执行：[异步与削峰](../backend-opt/02-异步与削峰.md)
- 应用性能（容器内 JVM 内存与 cgroup 关系，`MaxRAMPercentage`）：[接口性能优化](../backend-opt/01-接口性能优化.md)
- 网络基础（NAT、DNS）：[HTTP与浏览器](../../05-network/HTTP与浏览器.md)

> **自测标准**：能说出七种 namespace 各隔离什么、cgroup v2 怎么限内存/CPU、overlayfs 的 lower/upper/merged 与 copy-up/whiteout、dockerd→containerd→shim→runc 的职责、容器网络与 `-p` 的 iptables 原理，算过关。
