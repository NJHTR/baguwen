# IO 模型与 epoll：为什么一个线程能扛一万连接？

> 精讲层级：从「零基础能看懂」到「源码级」，每个名词都拆开
> 阅读时间：约 35 分钟
> 配套速查：[IO 模型与 NIO（深度追问）](../../10-deep-dive/java/13-IO模型与NIO.md)
> 返回：[精讲索引](../00-索引.md)

---

## 0. 一句话先讲明白

一次网络读取分两个阶段：**等数据到达内核缓冲区**、**把数据从内核缓冲区拷贝到用户空间**。IO 模型就是看这两个阶段各自「谁在等、怎么等」。
epoll 属于**IO 多路复用**：它让一个线程同时盯着上万个文件描述符（fd），内核只在某个 fd「就绪」时通知它，于是线程不用为每个连接开一个线程去阻塞等待。
所以「一个线程扛一万连接」的本质是：**线程不再一对一绑定连接，而是被所有连接共享，只在有事件时才被唤醒干活。**
注意：epoll 是**同步 IO**（就绪通知，拷贝阶段仍需线程参与），Linux 上真正的异步 IO 是 io_uring（以及更早的 AIO）。

---

## 1. 它解决什么问题：一万个连接，怎么办

### 1.1 最直觉的方案：一个连接一个线程

服务端接受一个 TCP 连接（TCP 连接是内核里的一条四元组记录），就开一个线程，线程里 `read` 阻塞等待数据。代码简单，但规模一上来就撞墙。

**先算一笔账**（数字化推导一：线程模型的内存与切换成本）：

| 开销项 | 单个线程的量级 | 1 万线程 |
|---|---|---|
| 用户态线程栈（Java `-Xss` 默认约 1MB，glibc pthread 默认 8MB 虚拟） | 1MB 虚拟地址 | 约 10GB 虚拟地址空间 |
| 内核栈（Linux 默认 16KB） | 16KB | 约 156MB |
| 内核 `task_struct` 等调度结构 | 数 KB | 数十 MB |
| 一次上下文切换（context switch，CPU 从一个线程切到另一个线程） | 约 2~5 微秒 | 见下 |

假设 1 万个连接每秒各有 1 次请求，也就是每秒 1 万次「唤醒并处理」。每次处理至少一次唤醒 + 一次上下文切换：

```
1 万次/秒 × 3 微秒 = 30 毫秒/秒 ≈ 3% 的单核 CPU
```

看起来不高，但这是**只算切换、且假设每请求只切换一次**的理想值。真实情况是：线程栈与 `task_struct` 占用内存、调度器要维护 1 万个可运行/阻塞实体、锁竞争和缓存局部性都会明显恶化。更致命的是：**连接大部分时间没有数据**，线程却必须一直占着栈和调度资源。这就是经典的 **C10K 问题**（如何让单机同时处理一万个连接）。

### 1.2 线程模型的死穴不是「慢」，而是「浪费」

- 每个连接一个线程：99% 的时间线程在阻塞睡眠，资源却被占着。
- 线程多了之后，调度器成为瓶颈、每个线程的栈造成大量内存占用；连接数再往上一千万级（C10M）时根本不可能实现。

### 1.3 多路复用的思路

不要让线程去等某一个连接，而是让**内核**帮忙盯住所有连接，线程只问一句：「现在哪些连接有事件？」
```text
线程：内核，我这里有 1 万个 fd，谁有数据了叫我。
内核：3 号、817 号、9001 号有数据。
线程：只处理这 3 个。
```
这就是 IO 多路复用（multiplexing，多路信号复用一个等待通道）。要做到这点，需要回答三个问题：

1. 怎么把「我关心哪些 fd」告诉内核？（注册）
2. 内核怎么知道哪个 fd 就绪？（回调/轮询）
3. 线程怎么拿到就绪列表？（返回就绪事件）

`select`、`poll`、`epoll` 是同一问题的三代答案，差别就在这三个问题的实现方式上。

---

## 2. 一步步拆开：从两个阶段到四象限

### 2.1 先把名词解释清楚

| 名词 | 是什么 |
|---|---|
| 系统调用（syscall） | 用户态程序请求内核帮忙的入口，如 `read`、`epoll_wait`；每次调用要切换 CPU 特权级，有固定成本（通常几百纳秒到几微秒） |
| 用户态 / 内核态 | CPU 的两种特权级；应用代码跑在用户态，不能直接碰硬件和内核数据结构 |
| 文件描述符（fd） | 内核给「打开的资源」分配的整数编号；socket、文件、管道都是 fd |
| 内核缓冲区 | 内核替 socket 暂存收到的数据的内存区（socket 接收缓冲区），数据到达网卡后由内核写入 |
| DMA | Direct Memory Access，网卡把数据直接写进内存而不经过 CPU 搬运，减少 CPU 占用 |
| 阻塞 | 调用不返回，线程进入睡眠，让出 CPU，直到条件满足 |
| 非阻塞 | 调用立即返回；没有数据时返回 `EAGAIN` 错误码（表示「现在没有，稍后再试」） |

一次 `read(socket, buf, n)` 在内核里做两件事：

1. **等**：接收缓冲区为空时，等待数据到达（可能睡眠）。
2. **拷**：数据到达后，把数据从内核缓冲区拷贝到用户传入的 `buf`。

这两个阶段分别是否阻塞，决定了 IO 模型的分类。

### 2.2 四象限（按两个阶段排列）

| 模型 | 第一阶段：等数据 | 第二阶段：拷贝 | 典型代表 |
|---|---|---|---|
| 阻塞 IO（BIO） | 阻塞 | 阻塞 | 一连接一线程的 `read` |
| 非阻塞 IO（NIO） | 轮询，不阻塞 | 阻塞 | 循环 `read` 直到 `EAGAIN` |
| IO 多路复用 | 阻塞在 `select/poll/epoll_wait` | 阻塞 | Netty、Nginx、Redis |
| 信号驱动 IO | 不阻塞，收到 `SIGIO` 通知 | 阻塞 | 很少用 |
| 异步 IO（AIO） | 不阻塞 | 不阻塞（内核完成拷贝后通知） | Linux io_uring、Windows IOCP |

**关键澄清**：很多面试者把 epoll 说成异步 IO，这是错的。epoll 只解决「等数据」阶段：内核告诉你哪个 fd 就绪，**拷贝仍由你的线程调用 `read` 完成**，所以它是同步 IO（更准确地说是「同步的多路复用」）。真正两阶段都不阻塞的是异步 IO。

### 2.3 select：位图 + 全量轮询

`select(int nfds, fd_set *readfds, fd_set *writefds, fd_set *exceptfds, struct timeval *timeout)`：

- `fd_set` 是一个**位图**：每个 fd 对应一位，1024 位 = 128 字节。
- 每次调用都要把位图从用户态**拷贝**到内核态。
- 内核**线性扫描**这 1024 个位，检查每个 fd 是否就绪。
- 返回时把位图改写成「哪些 fd 就绪」，再拷贝回用户态；用户态还要**再扫一遍**才知道具体是谁。

三个硬伤：
1. 上限 `FD_SETSIZE = 1024`（编译期常量）。
2. 每次调用 O(n) 全量扫描，连接数越多越慢。
3. 每次都要全量拷贝 fd 集合，并有两次扫描（内核一次、用户一次）。

### 2.4 poll：数组 + 全量轮询

`poll(struct pollfd *fds, nfds_t nfds, int timeout)` 把位图换成 `pollfd` 数组（每个元素：fd、关心的事件、返回的事件），去掉了 1024 上限，但：

- 每次仍要把整个数组拷贝进内核；
- 内核仍要 O(n) 遍历所有 fd；
- 返回后用户态仍要遍历数组找就绪项。

所以 poll 只是「去掉了数量限制」，没解决轮询本质。

### 2.5 epoll：注册一次 + 回调 + 就绪链表

epoll 把「注册」和「等待」拆成三个系统调用：

| 调用 | 作用 |
|---|---|
| `epoll_create1(flags)` | 创建一个 epoll 实例，返回一个 fd（这个 fd 代表内核里的一棵红黑树 + 一条就绪链表） |
| `epoll_ctl(epfd, op, fd, event)` | 增/删/改关注列表：`EPOLL_CTL_ADD/MOD/DEL` |
| `epoll_wait(epfd, events, maxevents, timeout)` | 等待就绪事件，只返回就绪的（最多 `maxevents` 个） |

内核里每个 epoll 实例长这样（Linux 源码 `fs/eventpoll.c` 的 `struct eventpoll`，简化）：

```text
struct eventpoll
├── rbr       红黑树根：所有注册的 fd 都挂在这棵树上（按 fd 编号排序）
├── rdllist   就绪链表：已经就绪、等着被 epoll_wait 取走的 epitem
├── wq        等待队列：阻塞在 epoll_wait 上的线程
├── ovflist   溢出链表：回调期间临时收集的条目
└── ...
```

每个被注册的 fd 对应一个 `epitem`（红黑树节点 + 链表节点 + 事件信息）。注册时，内核通过 `poll` 机制给这个 fd 的等待队列挂上一个回调 `ep_poll_callback`。

**数据到达时的流程**：

```text
网卡收包 → 内核协议栈处理 → 数据进入 socket 接收缓冲区
→ 唤醒该 socket 的等待队列 → 调用 ep_poll_callback
→ 把对应 epitem 挂到 rdllist（就绪链表）
→ 唤醒阻塞在 epoll_wait 上的线程
```

于是 `epoll_wait` 只需要：**看 rdllist 非空，就把里面的 epitem 事件拷贝给用户**，复杂度 O(就绪数)，与总连接数无关。这就是「一个线程盯一万个连接」的技术基础。

### 2.6 三种多路复用的对比

| 维度 | select | poll | epoll |
|---|---|---|---|
| fd 上限 | `FD_SETSIZE`（默认 1024） | 无上限（受内存） | 无上限（受 `max_user_watches`） |
| 注册方式 | 每次调用全量传入 | 每次调用全量传入 | `epoll_ctl` 注册一次 |
| 每次等待的内核开销 | O(n) 扫描 + 全量拷贝 | O(n) 扫描 + 全量拷贝 | O(就绪数)，无全量拷贝 |
| 用户态重扫 | 需要 | 需要 | 不需要（直接拿到就绪事件） |
| 就绪通知方式 | 轮询 | 轮询 | 回调 + 就绪链表 |
| 水平/边缘触发 | 只有水平 | 只有水平 | 支持 LT 和 ET |
| 适用规模 | 千级以下 | 千级 | 十万级 |

### 2.7 LT 与 ET：epoll 的两种通知模式

- **LT（level-triggered，水平触发，默认）**：只要 fd 的接收缓冲区里还有数据，每次 `epoll_wait` 都会返回它。可以只读一部分，下次继续读。
- **ET（edge-triggered，边缘触发，`EPOLLET`）**：只在「状态发生变化」时通知一次（从无数据到有数据）。之后即使还有数据没读完，也不会再通知。

ET 的三条铁律：
1. **fd 必须设为非阻塞**（`O_NONBLOCK`），否则循环读到「没有数据」时，最后一次 `read` 会阻塞，把这个 epoll 线程卡死。
2. **必须循环读到 `EAGAIN`**，把内核缓冲区读空，否则剩余数据可能导致连接永远不再被通知（漏事件）。
3. **`accept` 在 ET 下也要循环到 `EAGAIN`**，否则一次多个连接到达时会漏掉后续连接。

LT 更安全（漏读会再次通知），ET 少一次内核通知、在高并发下略省，但写错就是线上事故。多数框架默认 LT。

### 2.8 Reactor 模式：谁来跑事件循环

Reactor 就是「事件循环 + 回调」的架构模式，把 `epoll_wait` 拿到的事件分发给处理器：

| 模式 | 结构 | 代表 |
|---|---|---|
| 单 Reactor 单线程 | 一个线程做 accept、读写、业务 | Redis 的命令处理（6.0 前网络 IO 也单线程） |
| 单 Reactor 多线程 | 一个线程跑事件循环，业务丢给线程池 | 简单改造，注意共享状态加锁 |
| 主从 Reactor | mainReactor 只 accept，多个 subReactor 各自 epoll 处理读写 | Netty 的 bossGroup/workerGroup、Nginx 多 worker |

---

## 3. 完整推导：为什么一个线程能扛一万连接

### 3.1 核心结论先给

一个线程能盯一万连接，不是因为线程变强了，而是因为**线程等待的方式变了**：从「每个线程等一个连接」变成「一个线程等所有连接，内核负责筛选就绪者」。

### 3.2 数字化推导二：select 的扫描成本

假设 1 万个连接，每秒 1000 次轮询（一次循环处理完再等）：

```text
select：每次检查 10000 个 fd
        每秒 1000 次 → 1000 万次 fd 检查/秒
        每次还要把 10000 位（1250 字节）的集合拷进拷出
epoll：每次只取就绪的 fd，假设平均 10 个就绪
        每秒 1000 次 → 1 万次事件处理/秒
```

**扫描量相差约 1000 倍**。连接数越大、活跃比例越低，差距越大。这也解释了为什么 epoll 在「大量空闲连接」场景优势巨大，而在「所有连接都繁忙」时优势缩小：此时就绪数也接近连接数。

### 3.3 数字化推导三：epoll 自身的内存

每个注册项（64 位系统）大约占 160 字节左右（`epitem` + 红黑树节点 + 等待队列项的开销，具体随内核版本变化）：

```text
1 万连接  × 160B ≈ 1.6MB
10 万连接 × 160B ≈ 16MB
100 万连接 × 160B ≈ 160MB
```

对比线程模型：1 万线程仅用户栈虚拟地址就 10GB 量级。两边的内存效率不是一个数量级。
（查看本机上限：`cat /proc/sys/fs/epoll/max_user_watches`，该上限由内核按可用内存估算，以实际输出为准。）

### 3.4 数字化推导四：上下文切换

线程模型里每个事件至少一次唤醒切换：

| 每秒事件数 | 假设 3 微秒/次切换 | 单核切换开销 |
|---|---|---|
| 1 万 | 30 毫秒 | 3% |
| 10 万 | 300 毫秒 | 30% |
| 100 万 | 3 秒 | 300%（不可能） |

同样的负载下，epoll 单线程只在一个线程里处理所有事件：线程不睡眠、不切换，事件在用户态循环里被顺序处理掉。这是「扛万连接」的第二个来源：**省掉了海量上下文切换**。

### 3.5 成立条件（必须说清楚，否则是背答案）

1. **IO 密集、事件稀疏**：连接虽多，但同一时刻活跃的少。若每个连接都在疯狂发数据，一个线程 CPU 根本处理不过来。
2. **单事件处理足够快**：回调和业务逻辑不能有阻塞操作（磁盘 IO、远程调用、大计算），否则会拖住整个事件循环。Redis 单线程模型也依赖「命令执行足够快」。
3. **多核要靠多个事件循环**：单线程只能用一个核；要利用多核就起多个 Reactor 线程/进程（Netty 多个 EventLoop、Nginx 多 worker）。
4. **fd 数量本身要够**：`ulimit -n`（单进程可打开 fd 上限）要调大，否则万连接在「打开 fd」这一步就失败。
5. **注意仍有拷贝**：`epoll_wait` 把就绪的 `epoll_event` 拷贝到用户数组，这不是零拷贝，只是不拷贝全量 fd 集合；想减少系统调用与拷贝次数，才轮到 io_uring。

---

## 4. 极简模型：3 个客户端 + 1 个 epoll 实例

把规模缩到最小，看清「注册、回调、就绪链表」：

假设监听 fd = 3，三个客户端连接 fd = 4、5、6。

**第一步：注册**

```text
epoll_ctl(ADD, fd=3, EPOLLIN)  → 红黑树插入节点 3
epoll_ctl(ADD, fd=4, EPOLLIN)  → 红黑树插入节点 4
epoll_ctl(ADD, fd=5, EPOLLIN)  → 红黑树插入节点 5
epoll_ctl(ADD, fd=6, EPOLLIN)  → 红黑树插入节点 6
红黑树：{3, 4, 5, 6}，就绪链表：空
```

**第二步：只有客户端 4 和 6 发来数据**

```text
内核收到 fd=4 的数据 → 回调 → epitem(4) 挂到就绪链表
内核收到 fd=6 的数据 → 回调 → epitem(6) 挂到就绪链表
epoll_wait 返回 2 个事件：[4, 6]
红黑树不变，仍跟踪 {3,4,5,6}
```

**第三步：线程只处理 4 和 6**

```text
read(4) → 拷贝数据、处理
read(6) → 拷贝数据、处理
fd=5 完全没被碰过
```

对比 select：每次调用都要把 `{3,4,5,6}` 位图传进去、内核扫 4 个、返回后再扫 4 个。规模到 1 万时，这个差异被放大 1000 倍。

用表格对比两种模型在这个模型下的「每次唤醒做的事情」：

| 模型 | 每次唤醒内核做的事 | 每次唤醒用户态做的事 |
|---|---|---|
| select | 扫 4 个 fd，改写位图，拷回 | 再扫 4 个 fd 找就绪 |
| epoll | 从就绪链表取 2 个 epitem，拷贝事件 | 直接处理 2 个事件 |

---

## 5. 为什么这样设计：至少两个被否决的方案

### 5.1 被否决方案一：一连接一线程（阻塞 IO）

**优点**：编程模型最简单，读代码像写同步代码；低并发下性能不差。
**否决理由**：内存与调度随连接数线性增长，1 万连接就接近不可维护，十万连接不可能。**只在低并发或连接数可控的场景保留**（例如管理后台、内部工具）。

### 5.2 被否决方案二：select/poll 的「每次全量轮询」

**优点**：接口简单、跨平台（select 几乎处处都有）。
**否决理由**：O(n) 扫描与全量拷贝，连接数一多就退化；select 还有 1024 硬上限。它们适合「fd 少、跨平台」的场景，不适合大规模连接。

### 5.3 被否决方案三：Linux 原生 AIO（libaio）

**做法**：直接使用内核 AIO 接口。
**否决理由**：Linux 原生 AIO 长期只对 `O_DIRECT` 等少数场景友好，网络 socket 支持差；glibc 的 POSIX AIO 实现本质是用户态线程池，不是真异步。这才是后来 io_uring 出现的背景。

### 5.4 为什么 epoll 用「红黑树 + 就绪链表」而不是哈希表

红黑树按 fd 编号有序，增删改 O(log n) 且无扩容抖动；就绪链表让 `epoll_wait` 与「总连接数」解耦，这是性能关键。fd 是稀疏整数，哈希表也能做 O(1) 均摊，但内核更看重「无扩容抖动 + 内存可控 + 有序遍历」，红黑树是当时的工程选择。

---

## 6. 关键参数为什么是这个值

### 6.1 `FD_SETSIZE = 1024`

- 历史原因：`fd_set` 是固定大小位图，1024 位 = 128 字节，早期系统 fd 数量少。
- 它是**编译期常量**：应用和 glibc 都按这个大小分配，改大需要重新编译，且与内核实现耦合。
- 这就是 select 无法支撑万连接的根本原因，也是 epoll 要替代它的直接动机。

### 6.2 `max_user_watches`

- 每个 epoll 注册项都要占内核内存，内核用 `max_user_watches` 防止一个用户把内存吃光。
- 默认值由内核按物理内存估算（不同内核版本公式不同），常见机器上是百万级；超过会 `ENOSPC`。
- 估算公式（工程口径）：约「可用内存 / 32KB」量级，每项约 160 字节。要精确值直接读 `/proc/sys/fs/epoll/max_user_watches`。

### 6.3 `epoll_wait` 的 timeout

- `-1`：无限阻塞，直到有事件或被信号打断。事件驱动服务器通常用 `-1`，让线程彻底睡眠、不占 CPU。
- `0`：立即返回，相当于轮询，会空转烧 CPU，只用于「同时还要处理其他定时任务」的特殊场景。
- 正数：最多等这么多毫秒。常用在「事件循环里还要跑定时器/心跳」的框架中（Netty、Redis 都有定时任务，会算出最近的超时时间）。

### 6.4 `listen` 的 backlog 与 `somaxconn`

- `listen(fd, backlog)` 的 backlog 是「已完成三次握手、等待 accept 的连接队列」上限；实际生效值是 `min(backlog, net.core.somaxconn)`。
- `somaxconn` 较新内核默认 4096（早期 128）。高并发短连接服务要同时调大 `somaxconn` 和 `tcp_max_syn_backlog`（半连接队列，SYN 队列），否则会丢连接或握手超时。

### 6.5 为什么默认 LT 而不是 ET

- LT 容错：只要没读完，下次还会通知，业务代码写错也不会漏事件（最多多几次唤醒）。
- ET 少一些唤醒，但要求非阻塞 + 读空 + accept 读空，任何一条写错都可能导致连接卡死或漏连接。
- 「默认安全、显式开启高性能」是接口设计的常见取舍，epoll 选择了 LT 作为默认。

`EPOLLONESHOT`（2.6.2+）让 fd 只通知一次，处理完重新 `MOD` 才能再触发，用于多线程共享 epoll 时保证同一连接同一时刻只有一个线程处理；`EPOLLEXCLUSIVE`（4.5+）用于多进程/线程等待同一监听 fd 时避免惊群（所有等待者同时被唤醒却只有一个能 accept），常与 `SO_REUSEPORT` 配合。

## 7. 版本演进

### 7.1 Linux 内核

| 版本 | 变化 |
|---|---|
| 2.4 时代 | `select`、`poll` 是主流；C10K 问题开始被讨论 |
| 2.5/2.6（2003 前后） | epoll 合入主线，成为大规模连接的标准方案 |
| 2.6.2 | 增加 `EPOLLONESHOT` |
| 2.6.9 前后 | `epoll` 接口稳定，LT/ET 语义定型 |
| 4.5（2016） | 增加 `EPOLLEXCLUSIVE`，缓解多进程 accept 惊群 |
| 5.1（2019） | io_uring 引入：提交队列（SQ）与完成队列（CQ）共享内存，用户态与内核态通过环通信 |
| 5.4 起 | io_uring 逐步补齐网络相关操作（accept/send/recv 等），并支持注册文件、固定缓冲区等优化 |

### 7.2 语言与框架层

- **Java**：Java 1.4 引入 NIO（`Selector`）；在 Linux 上，JDK 7+ 的 `Selector` 默认实现是 `EPollSelectorImpl`（基于 epoll），可用 `Selector.open().getClass()` 验证；Netty 4.x 另提供原生 epoll transport（`EpollEventLoopGroup`），比 JDK NIO 少一层封装。
- **Netty**：主从 Reactor 的典型实现。`bossGroup` 负责 accept，`workerGroup` 负责读写与业务，每个 EventLoop 绑定一个线程 + 一个 Selector。
- **Redis**：6.0 之前网络 IO 和命令执行都在单线程事件循环里；6.0 起网络读写可多线程，命令执行仍单线程（保持原子性）。这正说明「事件循环单线程」的瓶颈边界在哪。
- **Nginx**：多 worker 进程，每个 worker 独立 epoll，配合 `SO_REUSEPORT` 或 accept mutex 分配连接。
- **io_uring 支持**：Netty 5 及部分网络框架提供 io_uring transport；数据库/存储类应用用它做批量异步 IO。

---

## 8. 亲手验证

### 8.1 查看本机 epoll 能力与当前连接

```bash
uname -r                                  # 预期：5.x / 6.x 内核版本号
cat /proc/sys/fs/epoll/max_user_watches   # 预期：一个很大的数（百万级）
cat /proc/sys/net/core/somaxconn          # 预期：4096（较新内核）
ulimit -n                                 # 预期：1024 或 65535 等，决定单进程 fd 上限
ss -tan state established | wc -l         # 预期：当前 ESTABLISHED 连接数
```

### 8.2 观察一次 epoll 服务的系统调用

如果能编译运行一个 epoll 服务（见 8.3 的 Java 版本），用 `strace` 看它到底在等什么：

```bash
strace -f -c -e trace=epoll_create1,epoll_ctl,epoll_wait,accept4,read,write ./server
```

预期输出（节选，数字随压测变化）：

```text
% time     seconds  usecs/call     calls    errors syscall
------ ----------- ----------- --------- --------- ----------------
 99.80    5.000000     5000.00      1000           epoll_wait
  0.10    0.001000        1.00      1001           read
  0.05    0.000500        0.50      1000           write
  0.03    0.000100        1.00         1           epoll_create1
  0.02    0.000050        0.05      1000           epoll_ctl
```

关键读法：**阻塞的时间几乎都花在 `epoll_wait` 上**（这是睡眠，不占 CPU），真正的工作只有少量 read/write。这与「线程在等，但不消耗 CPU」的模型完全一致。

### 8.3 用 Java NIO 跑一个最小 epoll 服务器

Linux 上 `Selector.open()` 的底层实现就是 epoll。代码可直接运行（JDK 8+）：

```java
import java.net.InetSocketAddress;
import java.nio.ByteBuffer;
import java.nio.channels.*;
import java.util.Iterator;

public class EpollDemo {
    public static void main(String[] args) throws Exception {
        System.out.println("Selector 实现类: " + Selector.open().getClass().getName());
        try (ServerSocketChannel server = ServerSocketChannel.open()) {
            server.bind(new InetSocketAddress(8080));
            server.configureBlocking(false);
            Selector selector = Selector.open();
            server.register(selector, SelectionKey.OP_ACCEPT);
            ByteBuffer buffer = ByteBuffer.allocate(1024);
            while (true) {
                selector.select(); // 底层 epoll_wait
                Iterator<SelectionKey> it = selector.selectedKeys().iterator();
                while (it.hasNext()) {
                    SelectionKey key = it.next();
                    it.remove();
                    if (!key.isValid()) continue;
                    if (key.isAcceptable()) {
                        SocketChannel client = server.accept();
                        client.configureBlocking(false);
                        client.register(selector, SelectionKey.OP_READ);
                        System.out.println("accept: " + client.getRemoteAddress());
                    } else if (key.isReadable()) {
                        SocketChannel client = (SocketChannel) key.channel();
                        buffer.clear();
                        int n = client.read(buffer);
                        if (n == -1) { client.close(); continue; }
                        System.out.println("read " + n + " bytes");
                        client.write(ByteBuffer.wrap("ok\n".getBytes()));
                    }
                }
            }
        }
    }
}
```

预期交互：

```text
$ java EpollDemo
Selector 实现类: sun.nio.ch.EPollSelectorImpl
$ nc 127.0.0.1 8080
hello
accept: /127.0.0.1:xxxxx
read 5 bytes
ok
```

说明：本环境没有 Linux 网络与 JDK 运行栈，上面的输出是预期输出，未实际执行；`Selector.open()` 的实现类在 macOS 上是 `KQueueSelectorImpl`，Windows 上是 `WindowsSelectorImpl`，可以顺手验证「epoll 是 Linux 特有实现」。

万连接服务必须先把 `ulimit -n` 的软上限调到万级，否则 `accept` 会返回 `EMFILE`（Too many open files）。

---

## 9. 常见误区

| 错误说法 | 正确说法 |
|---|---|
| 「epoll 是异步 IO」 | epoll 是同步的多路复用：就绪后仍需线程调用 `read` 拷贝数据；真正的异步 IO 是 io_uring/AIO |
| 「epoll 一定比 select 快」 | 连接少或几乎全活跃时差距很小，甚至 epoll_ctl 的注册开销更明显；epoll 优势在大量空闲连接 |
| 「一个线程扛一万连接 = 一秒钟处理一万请求」 | 扛的是「同时在线连接」，不是「并发处理能力」；业务处理慢时事件循环会被拖死 |
| 「ET 比 LT 高级，应该优先用」 | ET 要求非阻塞 + 读空，写错会漏事件；LT 是默认且更安全的选项 |
| 「epoll_wait 零拷贝」 | 仍要把就绪的 `epoll_event` 拷贝到用户态，只是不拷贝全量 fd 集合 |
| 「select 的 1024 上限只是建议值」 | 是 `FD_SETSIZE` 编译期常量，超出部分会被直接忽略 |
| 「fd 关闭后必须显式 epoll_ctl DEL」 | 关闭 fd 时内核会自动从 epoll 移除；但如果 `dup` 过，需要按引用计数理解，别依赖「忘记 DEL 也没事」 |

---

## 10. 连续追问 Q&A

### Q1：IO 多路复用和异步 IO 的本质区别是什么？

**答**：看「拷贝数据」阶段由谁完成、线程是否参与。多路复用只是把「等数据」从每个连接自己等，改成内核统一等并通知；拷贝仍由线程调 `read` 完成，所以是同步。异步 IO 是应用发起请求后立即返回，内核完成「等 + 拷贝」，完成后通知应用，线程全程不参与拷贝。Linux 上 epoll 不是异步，io_uring 才是。

### Q2：select、poll、epoll 的核心区别，用一句话说？

**答**：select/poll 每次调用都要把「关心的 fd 集合」全量拷进内核并线性扫描；epoll 把注册和等待拆开，内核用回调维护「就绪链表」，每次只返回就绪的 fd。前者 O(n) 每轮，后者 O(就绪数)。

### Q3：epoll 的红黑树和就绪链表分别起什么作用？

**答**：红黑树负责「注册管理」：所有被监控 fd 按编号挂在树上，支持 O(log n) 的增删改，并防止重复注册。就绪链表负责「事件交付」：数据到达时由 `ep_poll_callback` 把 epitem 挂进链表，`epoll_wait` 只取链表。树解决「我关心谁」，链表解决「谁就绪了」。

### Q4：LT 和 ET 的区别？为什么 ET 必须配合非阻塞 fd？

**答**：LT 只要缓冲区有数据就重复通知；ET 只在状态从「无数据」变为「有数据」时通知一次。ET 必须循环读到 `EAGAIN`，否则剩余数据不会再触发通知；如果 fd 是阻塞的，最后一次「读空之后」的 `read` 会阻塞线程，把整个事件循环卡死，所以必须非阻塞。

### Q5：ET 模式下 accept 有什么坑？

**答**：多个连接同时到达时，ET 只通知一次「监听 fd 可读」。如果只 `accept` 一次，剩下的连接会留在队列里，且不会再有新的通知（除非又有新连接到达产生边沿）。正确做法是循环 `accept` 直到返回 `EAGAIN`。

### Q6：什么是惊群？epoll 怎么解决？

**答**：多个进程/线程阻塞在同一个监听 fd 上，一个新连接到达时全部被唤醒，但只有一个能 `accept`，其余白醒一次，这就是惊群（thundering herd），高并发下浪费大量 CPU。解决：`EPOLLEXCLUSIVE`（4.5+，只唤醒一个等待者）、`SO_REUSEPORT`（每个 worker 独立监听，内核按哈希分流）、或应用层 accept mutex。

### Q7：EPOLLONESHOT 解决什么问题？

**答**：多个线程共享同一个 epoll 实例时，一个 fd 就绪可能同时唤醒多个线程处理同一个连接，造成并发读写错乱。`EPOLLONESHOT` 让该 fd 只通知一次，处理线程处理完后重新 `epoll_ctl(MOD)` 重新武装，保证同一连接同一时刻只被一个线程处理。

### Q8：为什么 epoll 在连接数很大但活跃比例低时优势明显？

**答**：epoll 每轮的成本正比于「就绪事件数」，与总连接数无关；select/poll 每轮成本正比于「总 fd 数」。假设 10 万连接只有 100 个活跃，epoll 每轮处理 100 个事件，select 每轮扫 10 万个位。活跃比例越低，差距越大。

### Q9：一个线程处理一万连接，CPU 会不会成为瓶颈？

**答**：会，而且这是设计中必须正视的边界。单线程只能用一个核，所有事件处理、业务逻辑、序列化都串行。若每连接每秒 1 个事件、每事件 10 微秒，1 万事件/秒只占 10% CPU，没问题；若每连接每秒 100 个事件，就是 100 万事件/秒，单线程必然崩。此时要靠多 Reactor（多线程/多进程）横向扩展。

### Q10：io_uring 比 epoll 强在哪？

**答**：epoll 每次操作至少要 `epoll_wait` + `read`/`write` 两次系统调用，且用户态与内核态之间要拷贝就绪事件。io_uring 用共享内存的提交队列（SQ）和完成队列（CQ）：应用把一批请求写进 SQ，一次 `io_uring_enter` 提交，内核完成后把结果写进 CQ，应用直接读共享内存。批量提交把「N 次系统调用」压成「1 次」，还支持真正的异步和固定缓冲区等优化。代价是内核版本要求高、编程模型复杂、安全面更大。

### Q11：Redis 单线程为什么也能很快？和 epoll 什么关系？

**答**：Redis 是单线程事件循环 + epoll：网络事件由 epoll 收集，命令在内存里执行，单条命令是微秒级，且没有磁盘 IO 阻塞（持久化用子进程/后台线程）。它的快来自「纯内存 + 高效数据结构 + 无锁 + 事件驱动」，epoll 只是让单线程能同时管理大量连接。Redis 6.0 把网络读写改为多线程，但命令执行仍单线程，说明「事件循环单线程」的瓶颈主要在网络 IO 和协议解析。

---


## 11. 一张图总结

```text
应用线程
  │  循环调用 epoll_wait
  ▼
内核 epoll 实例
├── rbr（红黑树）      ：注册的 fd {3,4,5,6,...}        ← epoll_ctl
├── rdllist（就绪链表） ：[fd4, fd6]
└── wq（等待队列）      ：阻塞在 epoll_wait 的线程
        ▲
        │ 数据到达 socket → 等待队列回调 ep_poll_callback → 挂 rdllist
        │
   10,000 个连接（每个 fd 对应一个 epitem，约 160 字节）

对比：
  select/poll：每轮拷贝全部 fd 集合 + 内核 O(n) 扫描
  epoll      ：每轮只交付就绪的 k 个 → O(k)；注册/注销 O(log n)

成立条件：IO 密集 + 事件稀疏 + 单事件处理快 + 多核用多 Reactor
```

---

## 12. 一句话复盘

> epoll 把「每个连接一个阻塞线程」换成「一个线程等所有连接、内核只通知就绪者」：注册用红黑树、通知用回调、交付用就绪链表，于是等待成本与连接总数解耦，一个线程可以盯上万连接。它的本质是同步多路复用，拷贝阶段仍需线程参与；真正的异步要等 io_uring。扛万连接成立的前提是 IO 密集、事件稀疏、单事件处理快，并且 fd 上限、backlog 等系统参数已调好。

---

## 13. 自测题（先自己答，再看答案）

**1. epoll 是异步 IO 还是同步 IO？为什么？**
答案：同步 IO（多路复用）。epoll 只在「等数据」阶段帮线程筛选就绪 fd，数据拷贝仍由线程调用 `read` 完成。真正的异步 IO 在 Linux 上是 io_uring。

**2. 10 万个连接只有 1000 个活跃，epoll 每轮大致处理多少个事件？select 呢？**
答案：epoll 只处理约 1000 个就绪事件（O(k)）；select 每轮至少要扫描 10 万个 fd 位（O(n)），且每次都要全量拷贝 fd 集合。差距约 100 倍，且随活跃比例降低而扩大。

**3. LT 和 ET 分别适合什么场景？ET 写错会怎样？**
答案：LT 安全、适合大多数业务（默认）；ET 适合高频、可精确控制的场景（如 Netty 某些实现、Nginx）。ET 若没读到 `EAGAIN`，剩余数据不会再触发通知，连接可能永久卡住；若 fd 是阻塞的，最后一次 `read` 还会阻塞整个事件循环。

**4. 为什么 epoll 注册项要用红黑树而不是链表？**
答案：链表查找/删除 O(n)，注册和注销在大量 fd 时很慢；红黑树按 fd 有序，增删改 O(log n)，且没有哈希表扩容抖动。就绪交付则用链表，因为只需要按顺序取出。

**5. 一连接一线程的模型，1 万连接的主要开销在哪？**
答案：内存（每线程用户栈约 1MB、内核栈、task_struct）与调度（上下文切换约 2~5 微秒，大量线程时调度和缓存局部性恶化）；并且绝大多数线程在阻塞睡眠，资源被闲置占用。

**6. 为什么说「扛万连接」不等于「扛万并发」？**
答案：连接可以在线但空闲；真正的处理能力取决于事件循环每秒能处理多少事件。单线程 CPU 有限，业务处理慢（DB 调用、磁盘 IO、大计算）会阻塞事件循环，导致所有连接一起变慢。多核要靠多 Reactor。

**7. 用 io_uring 时，为什么系统调用次数能显著减少？**
答案：io_uring 用共享内存的提交/完成队列，应用把一批请求写入 SQ，一次 `io_uring_enter` 批量提交，内核完成后把结果写 CQ，应用读共享内存即可。相比 epoll 的「每次 wait + 每次 read/write」，批量提交把 N 次调用压成 1 次，并去掉了就绪事件的用户态拷贝。

---

## 14. 关联文件

- 深一层（追问树 + 源码细节）：[IO 模型与 NIO](../../10-deep-dive/java/13-IO模型与NIO.md)
- 网络基础配合阅读：[TCP 连接与调优](../../10-deep-dive/network/01-TCP连接与调优.md)
- 同层精讲：[HashMap 的 hash() 为什么要做高低 16 位扰动](01-HashMap-hash扰动.md)
- 返回：[精讲索引](../00-索引.md)

