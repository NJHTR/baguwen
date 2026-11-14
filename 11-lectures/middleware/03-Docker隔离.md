# Docker 隔离：namespace 和 cgroup 到底做了什么？

> 精讲层级：从「零基础能看懂」到「源码级」，每个名词都拆开
> 阅读时间：约 35 分钟
> 配套速查：[Docker（深度追问）](../../10-deep-dive/middleware/07-Docker.md)
> 返回：[精讲索引](../00-索引.md)

---

## 0. 一句话先讲明白

容器不是「轻量虚拟机」，它是宿主机上的**普通进程**：用 **namespace** 把进程「能看见的世界」隔开（进程、网络、挂载点、主机名等），用 **cgroup** 把它「能用多少资源」限住（CPU、内存、进程数），再用 **OverlayFS** 这类联合文件系统把它「看到的根目录」拼出来。
三者组合，外加一层镜像分发与运行时管理，就是我们说的容器。
关键推论：容器与宿主机**共享同一个内核**，所以启动快、密度高，但隔离性弱于虚拟机；内核漏洞、配置不当都可能让容器逃逸。

---

## 1. 它解决什么问题：一台机器上跑十个应用

### 1.1 裸进程部署的四个痛点

1. **进程互相可见**：A 应用 `ps` 能看到 B 应用的所有进程，甚至能 `kill` 掉。
2. **端口与网络冲突**：两个应用都想监听 8080。
3. **依赖互相污染**：A 要 JDK 8，B 要 JDK 17；A 改了 `/etc/hosts`，B 跟着受影响。
4. **资源互相挤占**：一个应用内存泄漏吃光宿主机，其他应用一起被打挂。

### 1.2 两类解决方案

| 方案 | 做法 | 隔离强度 | 代价 |
|---|---|---|---|
| 虚拟机（VM） | Hypervisor 虚拟硬件，每台 VM 跑完整客户机操作系统和独立内核 | 强（硬件级） | 每台 VM 一个内核 + 系统盘，内存开销 GB 级，启动几十秒 |
| 容器 | 复用宿主内核，用 namespace/cgroup/文件系统隔离进程 | 中（内核级） | 共享内核，隔离靠内核机制，存在逃逸面 |

**数字化推导一：密度与启动**

假设 10 个微服务，每服务实际需要 512MB 业务内存：

```text
虚拟机方案：每台 VM 至少 2GB（系统 + 运行时 + 业务）
            10 × 2GB = 20GB；启动 10 × 30 秒 = 300 秒
容器方案：每容器约 200MB（运行时 + 业务，共享内核）
          10 × 200MB = 2GB；启动 10 × 0.5 秒 = 5 秒
```

内存密度差约一个数量级，启动速度差几十倍。这就是容器流行的直接原因。
但代价同样明确：**VM 里内核崩了只影响自己；容器里内核崩了影响所有容器。**

### 1.3 Docker 到底做了什么

Docker 不是发明了容器，Linux 早就有 namespace/cgroup（LXC 就在用）。Docker 做的是把它们**产品化**：

- 镜像：把文件系统 + 元数据打包成可分发、分层复用的格式；
- 运行时：一条命令完成「拉镜像、建隔离、配网络、限资源、起进程」；
- 生态：仓库、网络、卷、编排。

真正创建容器的那一步由 **OCI 运行时**完成（标准叫法 OCI，Open Container Initiative）。在 Linux 上，Docker 的调用链大致是：

```text
docker CLI → dockerd（守护进程）→ containerd（容器生命周期）→ containerd-shim
→ runc（OCI 运行时）→ 调用 clone() 创建 namespace、写 cgroup、pivot_root 切换根目录、exec 启动进程
```

---

## 2. 一步步拆开

### 2.1 namespace：进程「能看见什么」

namespace（命名空间）是内核给一组进程提供的「隔离视图」：同一个名字（如 PID、hostname、网卡）在不同 namespace 里可以指向不同对象。

创建 namespace 的方式：`clone()` 系统调用带 `CLONE_NEW*` 标志，或 `unshare()` 把当前进程移入新 namespace。**术语首次出现解释**：`clone()` 是 Linux 创建进程/线程的系统调用（类似 fork，但可以指定共享哪些资源）；`unshare()` 让当前进程脱离某些共享资源、进入新的隔离视图。

传统七种 namespace：

| namespace | 隔离什么 | 生活化理解 | 验证方式 |
|---|---|---|---|
| Mount（mnt） | 挂载点视图：容器有自己的 `/`、`/proc`、`/sys` 挂载表 | 每个人看到不同的文件柜布局 | `cat /proc/$$/mountinfo`，容器内看不到宿主其他挂载 |
| UTS | 主机名、域名（`hostname`、`domainname`） | 每个人有自己的名字 | `hostname` 在容器内外不同 |
| IPC | System V IPC 与 POSIX 消息队列、信号量、共享内存 | 每个人有自己的信箱 | `ipcs` 在容器内为空 |
| PID | 进程 ID 视图：容器内 PID 1 是自己的主进程 | 每个人从 1 开始给自己的孩子编号 | 容器内 `ps` 只看得到容器进程；宿主上仍能看到它 |
| Network（net） | 网卡、IP、路由表、端口、iptables 规则 | 每个人有自己的电话和地址 | `ip addr`、`ss -lntp` 容器内外不同 |
| User | UID/GID 映射：容器内 root 可以映射为宿主普通用户 | 每个人有自己的身份表 | `cat /proc/self/uid_map` |
| Cgroup | cgroup 层级视图：容器只看到自己那棵子树 | 每个人只看到自己的配额单 | `cat /proc/self/cgroup` |

第五种网络 namespace 是面试重点，补两个名词：

- **veth pair**：一对虚拟网卡，像一根两端可插的网线；一端放进容器 network namespace（容器里的 `eth0`），另一端插在宿主机的网桥上（如 `docker0`）。
- **网桥（bridge）**：宿主机上的虚拟交换机，把多个 veth 连起来，实现容器间二层互通；出公网时通过 iptables 做 NAT（网络地址转换，把容器源 IP 改成宿主 IP）。

Linux 后续还增加了 **time namespace**（5.6，隔离 `CLOCK_MONOTONIC`/`CLOCK_BOOTTIME` 的偏移），所以严格说现代内核是八种，面试说「传统七种 + time」最稳妥。

### 2.2 cgroup：进程「能用多少」

namespace 只隔离「看得见什么」，不限制「用多少」。一个容器里的进程仍能吃满 CPU、耗尽内存——这就需要 cgroup（control group，控制组）。**术语首次出现解释**：cgroup 是内核把进程分组、并对每组做资源计量与限额的机制；它既负责「限」，也负责「统计」。

**cgroup v1 与 v2 的区别**：

| 维度 | cgroup v1 | cgroup v2 |
|---|---|---|
| 层级结构 | 每个子系统（cpu、memory、blkio、pids……）各有一棵独立树，一个进程可以属于多棵树 | 统一层级（unified hierarchy）：只有一棵树，控制器按需启用 |
| 挂载点 | `/sys/fs/cgroup/cpu/`、`/sys/fs/cgroup/memory/` 等 | `/sys/fs/cgroup/` 下统一目录 |
| 资源限制方式 | 每个控制器一套自己的文件，命名不统一 | 统一命名风格，如 `cpu.max`、`memory.max` |
| 设备限制 | `devices` 控制器 | 没有 devices 控制器，用 eBPF 程序挂到 cgroup |
| 现状 | 老发行版、老 Docker 环境常见 | 新发行版（systemd 默认 unified）与 Docker 20.10+ 支持 |

**CPU 限制**（v2）：

```bash
cat /sys/fs/cgroup/cpu.max        # 形如 "50000 100000"：每 100ms 周期最多用 50ms CPU
                                   # 50ms / 100ms = 0.5 核
cat /sys/fs/cgroup/cpu.weight     # 1~10000 的相对权重，默认 100（v1 叫 cpu.shares，默认 1024）
cat /sys/fs/cgroup/cpuset.cpus    # 绑定到哪些物理核
```

注意区分两种限制：

- **quota（硬限）**：`cpu.max` 直接卡上限，超了就节流；
- **weight（权重）**：仅在 CPU 竞争时按比例分配，没有竞争时可以用满。`--cpus=0.5` 配的是 quota；`--cpu-shares=512` 配的是 weight。

**内存限制**（v2）：

```bash
cat /sys/fs/cgroup/memory.max      # 硬上限，超过触发 cgroup 内 OOM
cat /sys/fs/cgroup/memory.high     # 软上限，超过后内核会节流并回收
cat /sys/fs/cgroup/memory.current  # 当前用量（包含 page cache）
cat /sys/fs/cgroup/memory.swap.max # 可用 swap 上限
```

**进程数限制**：`pids.max`（v1/v2 同名）。这是防御 fork bomb 的关键：进程数到上限后 `fork` 返回 `EAGAIN`。

**IO 限制**：v2 用 `io.max`（按设备限制带宽/IOPS），v1 用 `blkio.throttle.*`。

### 2.3 OverlayFS：容器「看到的根目录」

镜像不是解压成完整副本，而是**分层叠加**。OverlayFS 把多个只读目录（lowerdir）和一个可写目录（upperdir）合并成一个视图（merged）：

```text
lowerdir（只读镜像层，可多层，从下到上）：
  base 层（ubuntu）→ 依赖层（JDK）→ 应用层（app.jar）
upperdir（容器可写层，每个容器独立）
workdir（OverlayFS 内部工作目录）
        ↓ 合并
merged（容器里看到的 /）
```

**copy-up（写时复制）**：读文件时直接从 lower 读；当容器要**修改** lower 里的文件时，内核先把该文件完整复制到 upperdir，再在 upper 上改。删除 lower 里的文件时，在 upper 放一个 **whiteout**（特殊字符设备 0/0）做「删除标记」；删除整个 lower 目录时用 **opaque** 标记。

三个直接后果：

1. 容器可写层很小——只存「改过的文件」；
2. 第一次修改大文件会触发一次完整复制，性能抖动、磁盘占用上升；
3. 容器删掉后，可写层销毁；镜像层（lower）不受影响。

### 2.4 镜像分层与构建缓存

Dockerfile 里**只有会改变文件系统的指令**（`RUN`、`COPY`、`ADD`）才产生新层；`ENV`、`LABEL`、`CMD`、`EXPOSE` 等只改元数据。每层有内容摘要（digest），层之间共享：

```dockerfile
FROM eclipse-temurin:17-jdk
WORKDIR /app
COPY pom.xml .
RUN mvn dependency:go-offline          # 依赖层：pom 不变就命中缓存
COPY src ./src
RUN mvn package -DskipTests            # 代码层：src 变了才重跑
CMD ["java", "-jar", "target/app.jar"]
```

**构建缓存命中规则**：某条指令命中缓存的前提是「指令本身 + 它的输入 + 父层」都没变。`COPY`/`ADD` 会把文件内容纳入校验，所以把「变化少」的步骤放前面（先 `pom.xml`，后 `src`），能显著减少重复构建。

### 2.5 容器与虚拟机的本质区别

| 维度 | 容器 | 虚拟机 |
|---|---|---|
| 内核 | 与宿主共享同一个内核 | 每台 VM 独立内核 |
| 隔离机制 | namespace + cgroup + 文件系统 | 硬件虚拟化（VT-x/AMD-V）+ Hypervisor |
| 启动 | 毫秒~秒 | 秒~分钟 |
| 资源开销 | 接近裸进程 | 每个 VM 固定内核/系统开销 |
| 安全边界 | 内核级，逃逸面较大 | 硬件级，较强 |
| 能跑什么 | 依赖宿主内核（Linux 容器不能直接跑 Windows 程序） | 任意客户机操作系统 |
| 典型场景 | 微服务、CI、弹性伸缩 | 强隔离、多租户、异构系统 |

### 2.6 逃逸是怎么发生的

容器逃逸（escape）指容器内进程突破隔离，访问或控制宿主机。常见原理：

1. **特权容器**：`--privileged` 会放开几乎所有 capabilities、关闭默认 seccomp/AppArmor，容器内近似宿主 root；挂上 `/` 就能直接改宿主文件。
2. **危险 capability**：默认 Docker 会丢弃大部分 capability，但 `CAP_SYS_ADMIN`（可 mount、unshare、pivot_root）、`CAP_SYS_PTRACE`（可跟踪宿主进程）、`CAP_NET_ADMIN` 等一旦给多了，隔离就形同虚设。
3. **挂载敏感路径**：把 `/var/run/docker.sock` 挂进容器，容器内就能指挥宿主 Docker 起新容器、挂宿主根目录；把宿主 `/`、`/proc`、`/sys` 挂进去同理。
4. **user namespace 未启用**：默认情况下容器内 UID 0 就是宿主 UID 0；一旦能写到宿主文件系统，破坏力等于宿主 root。启用 user namespace（或 rootless）后，容器 root 映射到宿主普通 UID。
5. **内核漏洞**：容器与宿主共享内核，内核提权漏洞（如某些 cgroup release_agent 逃逸、runc 历史漏洞）可被用于逃逸。运行时要及时打补丁。

防御方向：非 root 用户运行、只读根文件系统、drop 掉所有非必要 capabilities、启用 seccomp/AppArmor/SELinux、禁用特权模式、不挂 docker.sock、启用 user namespace / rootless、内核与运行时及时更新；对强隔离场景用 gVisor（用户态内核）或 Kata Containers（轻量 VM）做「第二层边界」。

### 2.7 资源限制与 JVM 的配合（Java 后端必问）

容器里很多「OOM 莫名被杀」不是 Docker 的问题，而是 JVM 不知道自己在容器里：

- 老 JDK（8 早期）读 `/proc/meminfo` 和 `Runtime.availableProcessors()`，看到的是**宿主机**的内存和核数；
- 容器限制 512MiB、宿主 64GB 时，JVM 可能按 64GB 去设默认堆和 GC 线程，直接超出 cgroup 限制被 OOM killer 杀掉；
- JDK 10+ 默认开启容器感知（`UseContainerSupport`），按 cgroup 限制算内存和 CPU；JDK 8u191+ 也回移了该能力。

实践：用 `-XX:MaxRAMPercentage=70` 之类按比例设置堆上限，并确认 `-XX:ActiveProcessorCount` 与 cgroup CPU quota 匹配，避免 GC 线程数和实际可用 CPU 不匹配。

---

## 3. 完整推导

### 3.1 数字化推导二：镜像层共享省了多少空间

假设 10 个服务镜像，每个都基于同一个 800MB 的基础镜像，各自应用层 200MB：

```text
不做共享（每镜像完整存一份）：10 × (800 + 200) = 10GB
分层 + 内容寻址（层共享）： 800 + 10 × 200 = 2.8GB
节省：(10 - 2.8) / 10 = 72%
```

拉取时同理：节点上已有 800MB 基础层，新服务只需拉 200MB 的差异层。这是容器镜像分发的核心收益，也是「为什么 Dockerfile 要把依赖层放前面」的根本原因。

### 3.2 数字化推导三：内存限制与 JVM 参数

容器 `-m 512m`，JVM 里除了堆还有：

| 区域 | 估算 |
|---|---|
| 堆（`-Xmx`） | 由 `MaxRAMPercentage` 决定 |
| 元空间（Metaspace） | 默认无上限，实际常见 80~150MB |
| 线程栈 | 每线程约 1MB（`-Xss`），100 个线程约 100MB |
| 直接内存 / JIT / GC 结构 | 几十 MB |
| 代码缓存 | 数十 MB |

如果 `MaxRAMPercentage=25%（默认）`，512MiB 只给堆 128MB，业务稍大就频繁 GC；设成 `75%` 则堆 384MB，加上元空间与线程栈约 200MB，总量 584MB，**超过 512MB 限制，可能被 OOMKilled**。
合理做法：堆 60%~70%，`-XX:MaxMetaspaceSize` 设上限、控制线程数，并预留 20%~30% 给非堆。

### 3.3 数字化推导四：CPU quota 与 GC 线程

容器 `--cpus=0.5`（quota 50ms / period 100ms）：

- 若 JVM 能感知容器，则可用处理器数约 1，GC 线程规模按 1 核设置，符合实际；
- 若感知不到（老 JDK 或错误配置），可能按宿主 8 核创建 8 个并行 GC 线程，却只有 0.5 核可用，导致 GC 期间线程争抢、延迟抖动明显。

所以「容器 CPU 限制」不只是限速，还会改变 JVM 的线程决策；配置时要让两边对齐。

### 3.4 数字化推导五：copy-up 的代价

容器里第一次修改镜像层中的一个 100MB 文件：内核要先复制 100MB 到可写层，再写修改。假设磁盘 200MB/s，单次写延迟约 0.5 秒，同时多占 100MB 磁盘。若有 1 万个小文件各被改一次，除了数据量外还有大量 inode 与元数据操作，启动/写放大问题明显——这也是「容器适合无状态、数据放 volume」的原因。

---

## 4. 极简模型：两个「容器」、三个进程

不用 Docker，手工用 `unshare` 就能看到隔离：

```text
宿主：
  PID 1000 bash（容器 A 内命令）
  PID 1001 sleep 300（容器 A 主进程）
  PID 1002 bash（容器 B 内命令）

容器 A（unshare --pid --fork --mount-proc）：
  视角：PID 1 = sleep 300，PID 2 = bash，看不到宿主任何其他进程
容器 B（另一个 PID namespace）：
  视角：自己的一套 PID 1、2，与 A 互不可见
```

对宿主机来说，1000/1001/1002 都是普通进程，共享同一个内核、同一份 `/proc`（只是被 mount namespace 换了视图）。**这就是「容器是普通进程」的最直观证明。**

---

## 5. 为什么这样设计：替代方案与被否决原因

### 4.1 被否决方案一：只用 chroot

chroot 能把进程的根目录换成子目录，看起来像「隔离了文件系统」。

**否决理由**：chroot 只是改根目录，不隔离进程（`ps` 看得到全部）、不隔离网络（端口冲突依旧）、不限制资源（照样吃满 CPU/内存），且 root 用户很容易逃出 chroot。它只是容器文件隔离的一小块，单独用不构成容器。

### 4.2 被否决方案二：每应用一个系统用户

**做法**：不同应用用不同 Linux 用户跑，靠文件权限隔离。

**否决理由**：用户只隔离「文件权限」，进程、网络、PID 等全部共享；root 可无视权限；无法限制资源。它只能降低误操作风险，不是隔离方案。

### 4.3 被否决方案三：全虚拟机

**优点**：隔离最强，能跑异构系统。
**否决理由**：启动慢、内存开销大、密度低；微服务场景下每个服务一台 VM 成本不可接受。VM 适合「强隔离/多租户」，不适合「高密度微服务」。

### 4.4 被否决方案四：LXC/LXD 直接用

LXC 是更早的容器管理工具，同样基于 namespace/cgroup。

**否决理由**：配置复杂、镜像与分发生态弱、与编排系统集成差；Docker 通过「分层镜像 + 简单命令 + 仓库」把体验标准化，才让容器真正普及。

### 4.5 为什么 cgroup 要从 v1 走向 v2

v1 每个控制器一棵树，进程可以属于不同的树，导致「同一个进程在 CPU 树里属于 A、在内存树里属于 B」，管理和统计都容易错乱，不同控制器的行为也不一致。v2 统一为一棵树，控制器按需启用，并支持将子树委派给非 root 进程（systemd/Docker 用），语义一致、实现简化。代价是老内核/老系统兼容问题，过渡期长。

---

## 6. 关键参数为什么是这个值

### 5.1 默认不限制内存（`-m` 不设）

Docker 默认不给容器内存上限：容器可以吃光宿主内存，触发的是宿主级 OOM，可能连带其他服务。生产必须设置 `-m`/`--memory` 与 `--memory-swap`，并配合 JVM 参数。

### 5.2 `cpu.shares` / `cpu.weight` 的默认值

v1 默认 `cpu.shares=1024`，v2 默认 `cpu.weight=100`，都是「相对权重」不是上限：没有竞争时容器可用满 CPU；有竞争时按权重比例分。要硬限制必须设 quota（`--cpus`）。默认值的意义是「同优先级」；想区分服务等级再调权重。

### 5.3 `pids.max` 默认 `max`

默认不限进程数，一个 fork bomb 就能拖垮宿主。生产建议显式设置（如 200~1000），既能防 fork bomb，也要给 JVM 线程数留余量（Java 线程数往往几十到几百）。

### 5.4 OverlayFS 的 `merged`/`upper`/`work` 结构

`workdir` 是 OverlayFS 内部使用的空目录，必须与 upperdir 在同一个文件系统；`upperdir` 必须可写。这些是内核要求，不是 Docker 随便起的名字。容器运行时会把它们放在 `/var/lib/docker/overlay2/<id>/` 下。

### 5.5 JVM 容器感知开关与比例

`UseContainerSupport`（JDK 10+ 默认开）决定是否读 cgroup；`MaxRAMPercentage` 默认 25%（JDK 10+），对容器偏保守；`InitialRAMPercentage` 默认 1.6%。这些默认值是「安全优先」：宁可堆小一点，也不要超限被杀。生产按负载调。

## 7. 版本演进

### 7.1 Linux 内核

| 时间/版本 | 事件 |
|---|---|
| 2.4.19（2002） | mount namespace 出现 |
| 2.6.19（2006） | UTS、IPC namespace |
| 2.6.23~2.6.24 | user namespace（早期不完整）、PID、network namespace 陆续加入 |
| 2.6.24（2008） | cgroup v1 合入，最初叫 process containers |
| 3.8（2013） | user namespace 对非特权用户可用，rootless 容器的基础 |
| 4.5（2016） | cgroup v2 合入 |
| 4.6（2016） | cgroup namespace |
| 5.6（2020） | time namespace |
| 5.x 之后 | cgroup v2 控制器补齐（如 io、cpuset 等的细节完善），overlayfs 多层 lower 稳定 |

### 7.2 Docker 与 OCI

| 版本/时间 | 变化 |
|---|---|
| 2013 | Docker 1.0 发布，容器进入大众视野 |
| 2015~2017 | OCI（Open Container Initiative）成立并发布运行时/镜像规范，runc 成为参考实现 |
| 1.12（2016） | 内置 containerd，运行时分拆 |
| 17.06（2017） | Docker 项目拆分为 moby，社区版/企业版分家 |
| 19.03（2019） | rootless 模式实验性支持，BuildKit 可选 |
| 20.10（2020） | 支持 cgroup v2，rootless 稳定，`docker buildx` 普及 |
| 23.0（2022） | BuildKit 成为默认构建器 |
| 24.x / 25.x（2023） | 默认配置更安全（seccomp/AppArmor 默认收紧），与新版 containerd/runc 对齐；cgroup v2 成为新系统主流 |

### 7.3 安全事件与演进

- 2019 年 runc 漏洞（CVE-2019-5736）：容器内可篡改宿主机上的 runc 二进制，进而逃逸；修复后运行时会重新校验自身。
- 2022 年 cgroup v1 `release_agent` 相关漏洞（CVE-2022-0492）：在具备 `CAP_SYS_ADMIN` 等条件时可被用于逃逸，随后内核与运行时都加了限制。
- 这些事件推动了默认安全策略：默认 seccomp 配置、限制 capabilities、非特权模式、user namespace 与 rootless 的推广。

### 7.4 JVM 容器感知

- JDK 8 早期版本：看不到 cgroup，按宿主配置算堆和 CPU。
- JDK 8u191+、JDK 10+：支持容器感知（`UseContainerSupport`），按 cgroup 限制计算 `MaxRAMPercentage` 与可用处理器数。
- 新版 JDK 在容器内默认行为更合理，但「堆上限比例、元空间、线程数」仍要显式配置才能避免 OOMKilled。

---

## 8. 亲手验证

> 说明：以下命令需要 Linux 环境（部分需要 root）。当前写作环境无 Linux 与 Docker，所有输出为预期输出，未实际执行。

### 8.1 看 namespace

```bash
# 查看当前进程的各类 namespace 编号
ls -l /proc/self/ns/
# 预期：cgroup, ipc, mnt, net, pid, time, user, uts 各一行，末尾是 inode 编号

# 进入新的 PID namespace，并在其中启动 bash
sudo unshare --pid --fork --mount-proc bash
echo $$                 # 预期：1（在新 PID namespace 里它是 1 号进程）
ps aux                  # 预期：只看到 bash 自己（看不到宿主进程）

# 只隔离 UTS（主机名）namespace
sudo unshare --uts bash
hostname test-box       # 预期：本命令成功
hostname                # 预期：test-box
exit
hostname                # 预期：回到宿主原主机名，未被修改
```

### 8.2 看 cgroup 限制

```bash
# 确认 cgroup 版本
stat -fc %T /sys/fs/cgroup/
# 预期：cgroup2fs 表示 v2；tmpfs 表示 v1

cat /sys/fs/cgroup/cgroup.controllers
# 预期（v2）：cpu cpuset io memory pids 等控制器列表

# 启动一个限制 256MB、0.5 核、最多 100 个进程的容器
docker run -d --name demo \
  -m 256m --memory-swap 256m --cpus 0.5 --pids-limit 100 \
  nginx:alpine

docker stats --no-stream demo
# 预期：MEM USAGE / LIMIT 显示约 xxMB / 256MiB，CPU % 上限受 0.5 核约束

docker inspect -f '{{.HostConfig.Memory}} {{.HostConfig.NanoCpus}} {{.HostConfig.PidsLimit}}' demo
# 预期：268435456 500000000 100
# 256MiB = 268435456 字节；0.5 核 = 500000000 纳核；PidsLimit = 100

# 在容器 cgroup 中直接看限制（路径随 cgroup 驱动不同）
docker exec demo cat /sys/fs/cgroup/memory.max
# 预期：268435456
```

### 8.3 看 OverlayFS 挂载与镜像层

```bash
docker inspect -f '{{json .GraphDriver.Data}}' demo
# 预期：{"LowerDir":"/var/lib/docker/overlay2/.../diff:...","MergedDir":".../merged",
#        "UpperDir":".../diff","WorkDir":".../work"}

docker exec demo cat /proc/mounts | grep overlay
# 预期：overlay / overlay rw,lowerdir=...,upperdir=...,workdir=... 0 0

docker history nginx:alpine
# 预期：若干层，每层对应 Dockerfile 中的一条指令（RUN/COPY/ADD 产生文件层）
# 注意：IMAGE 列为 <missing> 的层是中间层，SIZE 为 0B 的是元数据层
```

### 8.4 验证构建缓存

```bash
docker build -t demo:v1 .
docker build -t demo:v2 .
# 预期：第二次构建输出大量 "CACHED"（缓存命中）
# 若修改 src/ 后重建，从 COPY src 开始的那一层及其后续层会重新执行
```

### 8.5 逃逸演示（危险操作，仅在隔离的实验环境理解原理，勿在生产执行）

```bash
# 特权容器相当于把宿主控制权交出去：挂载宿主根目录后可直接读写宿主文件
docker run --rm -it --privileged -v /:/host alpine chroot /host sh
# 预期：进入宿主文件系统的 root shell（这正是必须禁止 --privileged 的原因）

# 挂载 docker.sock 等价于把宿主 Docker 控制权交给容器
docker run --rm -it -v /var/run/docker.sock:/var/run/docker.sock docker:cli sh
# 预期：容器内可执行 docker run，在宿主上启动新容器
```

### 8.6 观察容器内外的内核与资源视图

```bash
uname -a                      # 宿主机与容器内结果一致（共享内核）
docker run --rm alpine uname -a   # 预期：内核版本与宿主相同
docker run --rm alpine free -m    # 预期：看到的是宿主机内存（除非用 lxcfs 之类做伪装）
docker run --rm --pid=host alpine ps aux   # 预期：能看到宿主机全部进程（隔离被主动放弃）
```

---

## 9. 常见误区

| 错误说法 | 正确说法 |
|---|---|
| 「容器是轻量级虚拟机」 | 容器是共享宿主内核的普通进程，没有独立内核 |
| 「namespace 能限制 CPU 和内存」 | namespace 只隔离视图；资源限制由 cgroup 完成 |
| 「cgroup 能限制磁盘容量」 | cgroup 主要限制 CPU/内存/进程数/IO 带宽；磁盘容量靠文件系统配额或 volume 限制 |
| 「容器内 root 一定等于宿主 root」 | 默认 UID 0 映射到宿主 UID 0（风险高）；启用 user namespace 或 rootless 后映射到普通用户 |
| 「镜像每一层都存完整文件」 | 层是差异 + 内容寻址，相同层跨镜像共享 |
| 「容器删了镜像就没了」 | 删容器只删可写层；镜像层仍在，除非显式删除镜像 |
| 「容器内存限制只算 JVM 堆」 | 元空间、线程栈、直接内存等也计入 cgroup；page cache 也计入但可回收 |
| 「容器里 free 看到的就是容器可用内存」 | 默认读的是宿主 `/proc/meminfo`；需要 lxcfs 等工具才显示容器视角 |

---

## 10. 连续追问 Q&A

### Q1：容器和虚拟机最本质的区别是什么？

**答**：是否共享内核。VM 通过 Hypervisor 虚拟硬件、跑独立客户机内核，隔离边界在硬件层；容器直接复用宿主内核，靠 namespace/cgroup/文件系统把进程「伪装」成独立系统。所以容器轻、快、密度高，但内核漏洞或配置不当会波及宿主；VM 重、慢，但隔离强。

### Q2：七种 namespace 分别隔离什么？

**答**：mount 隔离挂载点；UTS 隔离主机名/域名；IPC 隔离消息队列/信号量/共享内存；PID 隔离进程编号（容器内 PID 1 是主进程）；network 隔离网卡/IP/端口/路由/iptables；user 隔离 UID/GID 映射；cgroup 隔离 cgroup 视图。现代内核另有 time namespace（5.6+），隔离单调时钟/启动时钟偏移。

### Q3：namespace 和 cgroup 的区别，一句话？

**答**：namespace 管「看得见什么」（隔离视图），cgroup 管「能用多少」（资源限额与统计）。只有 namespace 没有 cgroup，容器可以吃光宿主；只有 cgroup 没有 namespace，进程仍然互相看见、端口冲突。

### Q4：cgroup v1 和 v2 的核心区别？为什么 v2 更好？

**答**：v1 每个控制器独立一棵树，进程可属于不同树，语义混乱、统计易错；v2 统一为一棵层级树，控制器按需启用、统一命名（`cpu.max`、`memory.max`），支持子树委派，设备限制改用 eBPF。v2 让资源管理有一致的模型，代价是旧系统兼容过渡。

### Q5：容器里的 PID 1 有什么特殊？没有 init 会怎样？

**答**：PID namespace 里第一个进程是 PID 1，内核对它特殊处理：收不到未处理的信号（除非自己注册 handler），且负责回收孤儿进程。如果 PID 1 是业务进程（如 Java）且不处理僵尸进程回收，容器里会出现僵尸进程堆积；所以常加 `--init`（tini/dumb-init）或应用自己处理。

### Q6：`--pid=host` 会带来什么后果？

**答**：容器与宿主共享 PID namespace，容器内 `ps` 能看到并操作宿主所有进程（有权限时甚至可以 kill 宿主进程），PID 隔离完全失效。除非是排障工具容器且受控，否则不应使用。

### Q7：OverlayFS 的 copy-up 什么时候发生？有什么性能影响？

**答**：容器第一次「写」lower 层里的文件时，内核先把整个文件复制到 upper 层，再在 upper 上修改；读不触发复制。影响：首次写大文件有复制延迟和磁盘放大；大量小文件写入有 inode/元数据开销。所以容器适合无状态，数据放 volume。

### Q8：镜像为什么要分层？构建缓存怎么命中？

**答**：分层让相同内容跨镜像共享（基础层只存一份），拉取/推送只传差异层，并支持逐层缓存。构建缓存命中条件是「指令 + 输入 + 父层」未变：`RUN` 看命令字符串与父层，`COPY/ADD` 还会校验文件内容摘要。把变化少的指令放前面能提高命中率。

### Q9：容器 OOM 是谁杀的？为什么设了 512MB 还被杀？

**答**：容器内存到 `memory.max` 时，cgroup 触发 OOM，由内核 OOM killer 杀掉容器内的进程（表现为容器退出、`docker inspect` 显示 OOMKilled）。设了 512MB 仍被杀，通常是 JVM 非堆内存（元空间、线程栈、直接内存）叠加导致总量超限，而不是堆本身超了。要用容器感知参数并预留非堆余量。

### Q10：容器逃逸的常见路径有哪些？怎么防？

**答**：特权容器、过多 capability（如 SYS_ADMIN）、挂载宿主敏感路径（`/var/run/docker.sock`、宿主根目录）、未启用 user namespace、内核/运行时漏洞。防御：非 root 运行、只读根文件系统、drop 非必要 capabilities、seccomp/AppArmor、禁 `--privileged`、不挂 docker.sock、启用 user namespace/rootless、及时升级，强隔离场景用 gVisor/Kata。

### Q11：`docker run` 到进程启动，中间发生了什么？

**答**：CLI 请求 dockerd；dockerd 准备镜像、网络、卷，调用 containerd；containerd 调 runc；runc 按 OCI 规范执行：`clone(CLONE_NEW*)` 创建各 namespace、写 cgroup 限额、`pivot_root` 切换到镜像的 merged 根目录、设置 capabilities/seccomp、`exec` 启动容器主进程；之后 containerd-shim 负责托管进程与收集退出状态。

### Q12：rootless 容器和 user namespace 的原理？

**答**：user namespace 让容器内的 UID/GID 与宿主 UID/GID 建立映射（如容器内 root 映射到宿主普通用户 100000）。这样即使容器内是 root，在宿主看来只是普通用户，破坏力受限。rootless Docker 以此为基础，让整个 Docker 守护进程以普通用户运行，不需要 root 权限，代价是网络/存储等功能受限或需要额外配置。

### Q13：容器里 `free -m` 为什么显示的是宿主内存？

**答**：`free` 读 `/proc/meminfo`，而 procfs 默认不按 cgroup 过滤，显示的是宿主全局内存。要显示容器视角可用 lxcfs 把 `/proc/meminfo` 等文件伪装成 cgroup 限额；同理 `nproc`、`top` 也会看到宿主数据（JVM 的容器感知是自己读 cgroup 文件，不依赖这些命令）。

---

## 11. 一张图总结

```text
宿主机（一个内核）
│
├── 容器 A 的普通进程（宿主 PID 1001）
│    ├── namespace：mnt/uts/ipc/pid/net/user/cgroup → 自己的视图
│    ├── cgroup：cpu.max=0.5核、memory.max=512MiB、pids.max=100
│    └── overlay merged = lower(镜像层,只读) + upper(可写层)
│
├── 容器 B 的普通进程
│    └── 另一套 namespace / cgroup / overlay
│
└── 共享：内核、CPU/内存、物理网卡（容器经 veth + bridge + NAT 接入）

docker run 链路：CLI → dockerd → containerd → runc
  → clone(CLONE_NEW*) + 写 cgroup + pivot_root + exec

隔离强度：VM > gVisor/Kata > 默认容器 > 裸进程
密度与启动：容器 > VM
```

---

## 12. 一句话复盘

> 容器是「namespace 隔离视图 + cgroup 限制资源 + OverlayFS 拼装根目录」的普通进程，共享宿主内核，因此轻快、密度高，但隔离边界弱于虚拟机。镜像分层与 copy-up 让分发和存储高效，代价是首次写放大；默认不设资源限制、默认容器 root 等于宿主 root、过度挂载与特权模式是线上事故与逃逸的主要来源，生产必须显式限制资源、非 root 运行、最小权限并启用 user namespace/rootless。

---

## 13. 自测题（先自己答，再看答案）

**1. 容器内 `ps` 只能看到自己的进程，靠的是哪个 namespace？宿主上还能看到这些进程吗？**
答案：PID namespace。宿主上仍能看到（它们是宿主的普通进程），只是容器内看到的是另一套 PID 编号视图。

**2. 只给容器加 `--cpus=0.5`，不设 `-m`，会有什么风险？**
答案：CPU 被限制在 0.5 核，但内存不受限；容器（尤其 JVM）可能吃光宿主内存，触发宿主级 OOM，波及其他服务。生产必须同时设置内存限制。

**3. 容器第一次修改镜像中的 100MB 文件会发生什么？**
答案：触发 copy-up：内核把该文件从 lower 层完整复制到 upper 可写层，再修改。会带来一次 100MB 的复制开销与磁盘占用，首次写有性能抖动。

**4. 为什么 Dockerfile 要把 `COPY pom.xml` 和 `mvn dependency:go-offline` 放在 `COPY src` 之前？**
答案：利用分层缓存。依赖层只依赖 pom.xml，改业务代码时 pom 不变，依赖层命中缓存，避免每次构建重新下载依赖。

**5. `--privileged` 为什么危险？**
答案：它放开几乎所有 capability、关闭默认 seccomp/AppArmor，容器内接近宿主 root；配合挂载宿主目录即可直接控制宿主机，等于放弃隔离。

**6. 容器 `-m 512m`，JVM 设置 `-Xmx512m` 为什么大概率会被 OOMKilled？**
答案：cgroup 限制的是进程总内存，不只是堆；元空间、线程栈、直接内存、代码缓存等还要占几百 MB，总额超过 512MiB 就触发 cgroup OOM。应该用 `MaxRAMPercentage` 按比例留出非堆余量。

**7. cgroup v2 相对 v1 最大的结构变化是什么？**
答案：从「每个控制器一棵独立树」改为「统一的一棵层级树」，控制器按需启用，统一命名与委派模型，解决了 v1 多树导致的管理与统计混乱。

---

## 14. 关联文件

- 深一层（追问树 + 源码细节）：[Docker](../../10-deep-dive/middleware/07-Docker.md)
- 相关问题排查：[Linux 性能排查](../../10-deep-dive/ops/01-Linux性能排查.md)
- 同层精讲：[IO 模型与 epoll](../java/10-IO模型与epoll.md)
- 返回：[精讲索引](../00-索引.md)

