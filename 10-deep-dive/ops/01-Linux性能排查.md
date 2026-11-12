# Linux 性能排查（负载 / CPU / 内存 / IO / 网络 / 方法论）

> 面试权重：5/5　｜　追问深度：**L5（/proc 数据源 / perf 采样 / eBPF / OOM killer 内核路径）**
> 一句话定位：性能排查的套路是**先判断哪个资源饱和（USE），再用工具定位到进程/线程/系统调用，最后才看代码**。面试官从"接口变慢"一路问到内核，考的是你能不能说出每一步用哪个命令、看哪个指标、下什么结论。

**本文件用法**：背下 L2 的指标含义与 L4 的三条排查路径，任何"线上变慢"的题都能套。别一上来就说"看日志"。
[返回深度追问索引](../00-索引.md)

---

## L1 一句话答案（10 秒能说出口）

排查顺序固定为：**平均负载 → CPU/内存/磁盘/网络四类资源（USE：使用率/饱和度/错误）→ 定位到进程与线程 → 系统调用与调用栈（strace/perf/火焰图）→ 再回到应用代码**。核心认知：平均负载不是 CPU 使用率（它算可运行 + 不可中断进程），`wa` 高说明在等 IO，`available` 才是真正可用内存，OOM killer 是内核在内存耗尽时的最后手段。

---

## L2 原理层：指标与工具

### 2.1 平均负载（`uptime` / `top` 的三个数值）

```
load average: 0.52, 1.20, 1.85      ← 1 分钟、5 分钟、15 分钟
```

- 是**指数衰减的滑动平均**，不是区间平均值；三个值一起看趋势（1 高 15 低 = 突发；15 高 = 长期压力）。
- 统计的是**可运行（R）** + **不可中断睡眠（D）** 的进程/线程数，**不是 CPU 使用率**：`load=2` 在 4 核机器上只用了半台，在 1 核机器上已经排队。经验阈值：**load ≈ 核数**表示刚好饱和，持续 > 核数 × 1.5 且请求变慢才需要处理；**load 高但 CPU 很低** → 看 `wa` 和 `ps -eo state` 找 D 状态进程。

### 2.2 CPU 指标分解（`top` / `vmstat` 的 us/sy/wa/st）

| 指标 | 含义 | 高的时候说明什么 |
|---|---|---|
| `us` | 用户态 CPU | 业务代码计算密集（热点函数、JSON 序列化、正则） |
| `sy` | 内核态 CPU | 系统调用/上下文切换/锁竞争/中断下半部多 |
| `wa` | IO 等待（**不计入 CPU 使用率**，但在 load 里） | 磁盘/NFS/网络存储慢，或 swap |
| `hi` / `si` / `st` | 硬中断 / 软中断 / 被虚拟化偷走 | 网卡收包打满单核；云主机邻居抢占或 CPU 限流 |

### 2.3 `vmstat` / `mpstat`：看趋势与单核

```bash
vmstat 1        # r 运行队列 b 阻塞 si/so swap bi/bo 块设备 us/sy/id/wa/st
mpstat -P ALL 1 # 每个核的 us/sy/wa/st；单核打满 vs 均匀分布，结论完全不同
```

- `r` 长期 > 核数 → CPU 饱和；`b` 长期 > 0 → 有进程卡在 D 状态（IO/锁）；`si/so` 非 0 → 在换页。**单核打满**常见于单线程任务（一个线程跑满、软中断绑核、GC 线程）——`mpstat -P ALL` 一眼能看出来，比看总 CPU 有用。

### 2.4 内存：`free` 的正确读法

```bash
free -m
#               total  used  free  shared  buff/cache  available
# Mem:           7822  3100   420     120        4302       4500
```

- `buffer` 是块设备元数据缓存，`cache` 是 **Page Cache**（读过的文件页）；它们**可被回收**，所以 `free` 小不代表内存不足，**看 `available`**（估算还能给新进程用多少）。`used` 高 + `available` 低才是真紧张；`cache` 持续上涨通常是正常的文件读写缓存。
- `swap`：`si/so` 持续非 0 说明在频繁换页，性能会断崖式下降；容器里通常禁用 swap。
- **OOM killer**：内存耗尽时内核按 `oom_score`（由 `oom_score_adj` 调整）杀进程，日志在 `dmesg`；容器里受 cgroup v2 `memory.max` 限制，触发的是 **cgroup 内 OOM**（`memory.events` 的 `oom_kill` 计数），容器进程被杀（exit 137）。排查：`dmesg -T | grep -i oom`、`docker inspect` 的 `OOMKilled`、`cat /sys/fs/cgroup/.../memory.events`。

### 2.5 磁盘：`iostat -x` 看什么

| 指标 | 含义 | 判读 |
|---|---|---|
| `await` | 平均 IO 等待时间（队列等待 + 设备处理，ms） | 机械盘 > 20ms、SSD > 5-10ms 就偏高 |
| `%util` | 设备忙碌时间占比 | 接近 100% 说明饱和；**SSD 并发高时 %util 100% 仍可能有余量** |
| `r/s` `w/s` / `aqu-sz` | 每秒 IO 次数 / 平均队列长度 | 对比业务预期，`aqu-sz` 持续 > 1 表示排队 |

`iowait` 高不一定是磁盘坏：可能是 NFS/网络存储慢、文件锁、甚至 CPU 被限流；要结合 `iostat` 的 `await` 与 `%util` 共同判断。

### 2.6 网络：连接、丢包、重传

```bash
ss -s                      # 连接数汇总（TIME_WAIT/ESTAB/CLOSE_WAIT）
netstat -s | grep -iE 'retrans|drop|overflow'      # 内核计数器
tcpdump -i eth0 -nn port 8080 -c 20
```

- 先看**连接数与状态分布**（是不是连接泄漏/端口耗尽），再看**丢包与重传**（`retrans`、`SYNs to LISTEN sockets dropped`），最后才抓包看具体报文。丢包也可能在网卡/交换机/安全组，内核计数器只能看到本机视角。

### 2.7 工具定位：strace / perf / 火焰图 / bpftrace

| 工具 | 回答什么问题 | 注意 |
|---|---|---|
| `strace -c -f -p PID` | 进程在**系统调用层**干什么、时间花在哪个 syscall | 有性能开销（ptrace），生产短时使用 |
| `perf top -g` / `perf record -F 99 -g` | 当前 CPU 热点的**函数调用栈**，配合 FlameGraph 出火焰图 | 需要 perf 权限/符号表；采样频率决定准确性 |
| `bpftrace` | 自定义内核态观测（off-CPU、IO 延迟分布、锁等待） | 需要内核 eBPF 支持 |
| `pidstat -u -r -d -w -p PID` | 单进程的 CPU/内存/磁盘/上下文切换 | 快速确认是谁在吃资源 |
| `top -H -p PID` / `jstack` / `jcmd` | 线程级 CPU、Java 线程栈、堆信息 | 定位"哪个线程在跑" |

`perf` 与 `strace` 的分工：**strace 看"调用了什么、等了多久"，perf 看"CPU 在执行哪段代码"**；接口慢但没有 CPU 热点时，优先 strace 与 off-CPU 分析（eBPF）。

### 2.8 USE 方法论

对每个资源问三个问题：**使用率（Utilization）**、**饱和度（Saturation，排队）**、**错误（Errors）**。

| 资源 | 使用率 | 饱和度 | 错误 |
|---|---|---|---|
| CPU | `top` 的 us+sy、`mpstat` | `vmstat` 的 `r` 运行队列 | `perf` 的 stall、`dmesg` 的 MCE |
| 内存 | `free` 的 used、`vmstat` | `si/so`、`vmstat` 的 `b` | OOM kill、`dmesg` |
| 磁盘 / 网络 | `iostat` 的 `%util`、`sar -n DEV` 带宽 | `await`/`aqu-sz`、`ss -s`、重传 | IO error、丢包、`ifconfig` errors |

### 2.9 三条实战排查路径

**CPU 高**

```
top 找高 CPU 进程 → top -H -p PID 找线程 → printf '%x' 线程ID 转 16 进制
→ jstack PID | grep -A 30 <十六进制>（Java）或 perf top -p PID 看热点函数
→ 判断是业务计算、GC、JSON/正则、锁自旋还是软中断（看 sy/hi/si）
```

**内存持续涨**

```
ps -eo pid,rss,comm --sort=-rss | head     # 找 RSS 大户，区分应用内存 vs Page Cache（可回收）
→ Java: jmap -histo:live PID / jcmd GC.heap_info；堆外看 DirectByteBuffer/Netty
→ 容器: cgroup memory.current / memory.stat，注意 limit 与 OOM 计数
→ 结论：真泄漏（对象无界增长）/ 缓存无上限（没设 maximumSize）/ 堆外或 Native 泄漏
```

**接口变慢**

```
系统层：load / CPU(us/sy/wa) / 内存(available、swap) / iostat(await,%util) / 网络(重传、连接数)
应用层：线程池队列与活跃数、DB 连接池等待(connection-timeout)、GC 日志停顿
依赖与代码层：DB 慢查询与锁、Redis RTT、下游 P99；strace 看 syscall、火焰图看热点、jstack 看锁
```

### 2.10 项目落点

- **报告平台的 Docker 沙箱**：不可信代码吃满 CPU/内存会触发 `--cpus` 限流与 cgroup OOM（exit 137），排查看 `docker stats`、`docker inspect` 的 `OOMKilled`、`/sys/fs/cgroup/.../memory.events`。
- **报告平台的 SSE / 数字人 WebSocket**：长连接多会吃 fd（`ulimit -n`）与内存，`ss -s` 看 ESTAB 数量、`lsof -p` 看 fd 增长；NIO 事件循环与软中断打满时 `si`、`sy` 升高，用 `mpstat -P ALL` 看是否单核打满。

---

## L3 底层层：数据从哪来、采样怎么发生

### 3.1 指标的数据源：`/proc` 虚拟文件系统

| 工具 | 实际读的文件 |
|---|---|
| `uptime` / `top` 负载 | `/proc/loadavg` |
| `top` / `vmstat` CPU | `/proc/stat`（每个核的 user/system/idle/iowait/softirq…） |
| `free` / 内存 | `/proc/meminfo`（MemAvailable、Cached、Buffers、SwapCached…） |
| `iostat` | `/proc/diskstats` + `/sys/block/*/stat` |
| `ss` / 进程级 | `/proc/net/tcp`、`/proc/net/snmp`；`/proc/<pid>/status`（VmRSS/Threads）、`/proc/<pid>/stack`（D 状态看内核栈） |

`/proc` 是内核在内存里现算的，不落盘；所以"看指标"本质是"让内核把统计结构体格式化给你"。

### 3.2 perf 采样与火焰图原理

`perf record -F 99 -g` 通过 `perf_event_open` 注册一个 **PMU/软件定时器**，每 10ms 触发一次中断，在中断上下文**抓当前 CPU 的指令指针与调用栈**（内核栈 + 用户栈，需要 frame pointer 或 DWARF 展开），把 `(栈, 次数)` 累积起来；`perf report` 按栈聚合，FlameGraph 把相同前缀合并成矩形——**矩形宽度 ≈ 采样占比 ≈ 时间占比**。这也是为什么火焰图"平顶宽"就是热点；`off-CPU` 火焰图则是把"阻塞等待"作为采样目标（eBPF），专门找 IO/锁等待。

### 3.3 OOM killer 的内核路径（简化）

```
应用申请内存 → 伙伴系统不足 → 回收（kswapd/direct reclaim）仍不足
→ out_of_memory() → 按 badness() 打分（oom_score，受 oom_score_adj 影响）杀分最高者
→ 若在 cgroup 内则受 memory.max 限制，先触发 cgroup OOM
```

所以 OOM 的根因往往不是"当前被杀进程"，而是**某个进程无界增长把整机/整 cgroup 的内存吃光**；排查要看"谁增长"，而不是只盯被杀的进程。

---

## L4 追问树（面试官一路往下问，你能撑到第几层？）

> 规则：第 1-3 层必备，4-6 层拉开差距，7 层以后是加分。

### 第 1 层｜平均负载的三个数值是什么意思？load 高但 CPU 不高说明什么？
**答**：分别是 1/5/15 分钟的指数衰减滑动平均，统计"可运行 + 不可中断睡眠（D）"的进程数，不是 CPU 使用率。load 高而 CPU 低，说明大量进程卡在 D 状态（磁盘/NFS/锁/内核 IO 等待），这时要看 `vmstat` 的 `b`、`iostat` 的 `await` 和 `ps` 的 D 状态进程，而不是加 CPU。

### 第 2 层｜CPU 的 us/sy/wa/st 怎么解读？sy 高一般是什么原因？
**答**：`us` 用户态计算、`sy` 内核态（系统调用/上下文切换/锁/中断处理）、`wa` 等 IO（不计入 CPU 使用率但计入 load）、`st` 被虚拟化层偷走。`sy` 高常见于频繁系统调用（大量小读写、线程切换）、锁竞争、网络软中断；结合 `vmstat` 的 `cs`（上下文切换次数）和 `strace -c` 能进一步定位。

### 第 3 层｜free 里 available 和 buffer/cache 是什么关系？cache 高是内存泄漏吗？
**答**：buffer/cache 是块设备缓存与 Page Cache，属于**可回收**内存，`free` 小不代表内存不足；`available` 是内核估算的"还能给新进程用多少"，才是关键指标。cache 高通常是正常现象（文件读写多）；判断泄漏要看**进程 RSS 是否持续增长**且 `available` 持续下降。

### 第 4 层｜swap 和 OOM killer 怎么触发？容器里 OOM 怎么排查？
**答**：物理内存不足时内核先回收 Page Cache，仍不够就把匿名页换出到 swap；swap 也满或禁用时触发 OOM killer，按 `oom_score`（受 `oom_score_adj` 影响）杀进程。容器里受 cgroup `memory.max` 限制，先触发 cgroup OOM，进程被 SIGKILL（exit 137）。排查：`dmesg -T | grep -i oom`、`docker inspect` 的 `OOMKilled`、cgroup v2 的 `memory.events`（`oom_kill` 计数）、`memory.current/max`。

### 第 5 层｜iostat 的 await 和 %util 怎么看？iowait 高一定是磁盘问题吗？
**答**：`await` 是平均 IO 等待（队列等待 + 设备处理），`%util` 是设备忙碌比例；机械盘 await > 20ms、SSD > 5-10ms 偏高，`%util` 接近 100% 且 `aqu-sz` 排队说明饱和（但 SSD 并发高时 %util 100% 也可能有余量）。`iowait` 高不一定是本地磁盘问题：NFS/云盘慢、文件锁、甚至 CPU 被限流都会抬高它，要结合 `iostat`、`pidstat -d` 和 `dmesg` 一起判断。

### 第 6 层｜网络问题怎么定位到丢包/重传/连接数？
**答**：先 `ss -s` 看连接总数与状态分布（TIME_WAIT/CLOSE_WAIT 是否异常），再 `netstat -s` 看 `retrans`、`SYNs to LISTEN sockets dropped`、`receive buffer errors` 等内核计数器，然后 `sar -n DEV` 看吞吐与丢包，最后 `tcpdump` 抓具体报文。要注意本机计数器看不到交换机/安全组的丢包，需要结合对端与链路设备。

### 第 7 层｜strace、perf、火焰图分别解决什么问题？
**答**：`strace -c` 统计系统调用次数与耗时，回答"进程在等什么 syscall"（文件读写、网络、锁 futex）；`perf top` 看实时 CPU 热点函数；`perf record -F 99 -g` + FlameGraph 生成火焰图，按调用栈聚合采样，找"哪段代码占 CPU"。慢但 CPU 不高时用 strace/off-CPU（eBPF），CPU 高时用 perf/火焰图。

### 第 8 层｜USE 方法论怎么落到每一类资源？
**答**：对 CPU/内存/磁盘/网络各问三个问题：使用率（top、free、iostat %util、sar）、饱和度（vmstat r/b、swap si/so、await/aqu-sz、重传）、错误（OOM、dmesg IO error、网卡 errors）。先找"哪个资源到了瓶颈"，再看"谁在占用/排队"，避免盲目翻代码。

### 第 9 层｜线上 CPU 突然 100%，你怎么查？
**答**：`top` 找高 CPU 进程 → `top -H -p PID` 找线程 → 线程 id 转十六进制 → Java 用 `jstack` 定位栈（GC 线程、业务循环、锁自旋），非 Java 用 `perf top -p PID` 看热点函数。同时看 `us` vs `sy`：us 高是业务计算，sy 高是 syscall/切换，`si` 高是网络软中断。还要看是否刚发版/流量突增，以及 GC 日志是否有 Full GC。

### 第 10 层｜内存持续上涨怎么排查？
**答**：`ps -eo pid,rss,comm --sort=-rss` 找 RSS 大户，区分应用内存与 Page Cache（cache 可回收）；Java 用 `jmap -histo:live`/`jcmd GC.heap_info` 看堆内，堆外看 DirectByteBuffer/Netty/线程栈；容器看 cgroup `memory.current` 与 `memory.events`。结论三选一：真泄漏（对象无界增长）、缓存无上限（Caffeine 没设 maximumSize）、堆外/Native 泄漏。**别只看 free，要看 available 与进程 RSS 趋势。**

### 第 11 层（终局）｜接口从 50ms 变慢到 800ms，你怎么从系统层一路查到应用层？
**答**：系统层先看 load/CPU（us/sy/wa/st）→ 内存（available/swap/OOM）→ 磁盘（iostat await/%util）→ 网络（重传/连接数），排除资源饱和；应用层看线程池队列与活跃数、DB 连接池等待、GC 停顿；依赖层看 DB 慢查询与锁、Redis RTT、下游 RPC P99；代码层用 `strace -c -f -p` 看 syscall 耗时分布、`perf record` 生成火焰图看 CPU 热点、`jstack` 抓线程栈看锁与阻塞、`pidstat -w` 看上下文切换。**最后用 traceId 把链路 span 对齐，确认耗时卡在哪一跳，再改代码。**

---

## L5 名词拆解表（每个名词都拆开）

| 名词 | 是什么 | 为什么存在 | 面试追问点 |
|---|---|---|---|
| load average | 1/5/15 分钟的可运行+不可中断进程均值 | 快速判断系统是否过载 | 为何不含 CPU 使用率、D 状态为何计入 |
| us / sy / wa / st | 用户态/内核态/IO 等待/被偷走 | 分解 CPU 去向 | sy 高、wa 高分别怎么继续查 |
| `available` | 内核估算的可用内存 | 区分"能回收的 cache"与"真可用" | 与 free 的区别 |
| swap / OOM killer | 换页 / 内存耗尽杀进程 | 内存兜底 | oom_score、cgroup OOM、exit 137 |
| `await` / `%util` | 平均 IO 等待 / 设备忙碌度 | 判断磁盘饱和 | 与 iowait 的区别 |
| `ss -s` / `netstat -s` | 连接汇总 / 协议栈计数器 | 网络问题第一现场 | 重传、drop、overflow 各代表什么 |
| `strace` | 跟踪系统调用 | 看进程在等什么 | 性能开销、ptrace 原理 |
| `perf` / 火焰图 | 采样 CPU 栈并聚合 | 找热点函数 | 采样频率、栈展开、平顶含义 |
| eBPF / bpftrace | 内核可编程观测 | 低开销看内核事件（off-CPU、锁、IO） | kprobe/tracepoint、为何比 strace 轻 |
| USE 方法论 | 使用率/饱和度/错误 | 系统化排查不漏资源 | 四类资源各对应哪些指标 |

---

## 代码验证

```bash
# 1) 负载/CPU/内存/磁盘/网络：先判断资源是否饱和
uptime; vmstat 1 5; mpstat -P ALL 1 3
free -m; iostat -x 1 3; ss -s
netstat -s | grep -iE 'retrans|drop|overflow'
dmesg -T | grep -i -E 'oom|out of memory' | tail

# 2) 定位到进程/线程/系统调用
pidstat -u -r -w -p <pid> 1; top -H -p <pid>
strace -c -f -p <pid> -o /tmp/strace.txt & sleep 10; kill %1
perf top -p <pid>

# 3) 火焰图 + eBPF（采样 30s；eBPF 看 read 耗时分布）
perf record -F 99 -g -p <pid> -- sleep 30
perf script | ./stackcollapse-perf.pl | ./flamegraph.pl > flame.svg
bpftrace -e 'kprobe:vfs_read { @s[tid]=nsecs; } kretprobe:vfs_read /@s[tid]/ { @us=hist((nsecs-@s[tid])/1000); delete(@s[tid]); }'
```

---

## 高频错误（面试官最爱抓的）

| 错误说法 | 正确说法 |
|---|---|
| 「平均负载就是 CPU 使用率」 | 它是可运行 + 不可中断进程数均值；load 高 CPU 低说明卡在 IO/D 状态 |
| 「free 快没了就是内存不足」 | buffer/cache 可回收，要看 `available` |
| 「iowait 高一定是磁盘慢」 | 可能是 NFS/云盘、文件锁、CPU 限流；要结合 await/%util |
| 「OOM 杀掉谁就是谁的锅」 | 通常是别的进程无界增长吃光内存，被杀的是"分最高"的受害者 |
| 「strace 可以长期挂生产」 | ptrace 有显著开销，生产只做短时定位，长期观测用 eBPF |

---

## 关联文件

- 系统调用与连接状态的内核背景：[TCP 连接与调优](../network/01-TCP连接与调优.md)
- 应用层如何量化慢请求：[接口性能优化](../backend-opt/01-接口性能优化.md)
- 日志/指标/追踪如何串起来定位、容器 OOM 的 cgroup 细节：[可观测性](./02-可观测性.md)、[Docker](../middleware/07-Docker.md)

> **自测标准**：能解释 load 三值与 CPU 各指标、说清 free/available 与 OOM killer、看懂 iostat 的 await/%util、区分 strace/perf/火焰图用途、背出 USE 四类资源对应指标、讲出"CPU 高/内存涨/接口慢"三条排查路径，算过关。
