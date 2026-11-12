# IO 模型与 NIO（BIO / NIO / epoll / Netty）

> 面试权重：4/5　｜　追问深度：**L5（Linux 内核 `eventpoll` + 网卡中断 + Netty `EpollEventLoop`）**
> 一句话定位：IO 模型题的陷阱在于「非阻塞」和「多路复用」被混为一谈。真正的分水岭是 **epoll 的红黑树 + 就绪链表 + 回调、LT/ET 的差别、Reactor 的线程模型**，再往上是 Netty 的 `EventLoop` 无锁化与 `ByteBuf` 引用计数。答到这一层，SSE 长连接、网关、RPC 的追问都能接住。

**本文件用法**：从 L1 往下读，每读完一层合上书自问自答。**停在答不出的那一层，就是你的真实水平线。**
[返回深度追问索引](../00-索引.md)

---

## L1 一句话答案（10 秒能说出口）

BIO 是「一连接一线程，读不到就阻塞」；NIO 是「非阻塞 + 一个 Selector 管所有连接」，由内核告诉你哪些连接就绪；Linux 上这个「内核告诉你」的能力就是 **epoll**（红黑树存 fd、就绪链表存事件、回调把就绪 fd 塞进链表），所以一个线程能撑上万连接。Netty 则是基于 epoll 的 **主从 Reactor + 无锁串行 EventLoop + 引用计数 ByteBuf** 的工程实现。

---

## L2 原理层：五种 IO 模型的本质差别

| 模型 | 谁在等数据 | 典型 API | Java 形态 |
|---|---|---|---|
| 阻塞 IO（BIO） | 用户线程阻塞在 `read` | `read()` | `InputStream.read()` |
| 非阻塞 IO | 用户线程轮询 `read` 返回 `EAGAIN` | `O_NONBLOCK` | `channel.configureBlocking(false)` |
| IO 多路复用 | 一个线程等「多个 fd 中谁就绪」 | `select/poll/epoll` | `Selector` |
| 异步 IO（AIO） | 内核把数据拷到用户空间后通知 | `io_uring`/`io_submit` | `AsynchronousChannel`（Linux 上是用户态模拟） |

**关键区分**：前四种都是「同步 IO」——数据从内核到用户空间的拷贝仍要用户线程参与；只有 AIO 是真正的异步。面试常问「NIO 是异步的吗」，正确回答是：**NIO 是同步非阻塞 + 多路复用，不是异步**。

---

## L3 底层层：epoll、Reactor、Netty

### 3.1 select / poll / epoll 的差别

| 维度 | select | poll | epoll |
|---|---|---|---|
| 数据结构 | `fd_set` 位图（1024 上限） | `pollfd[]` 数组 | 内核红黑树 + 就绪链表 |
| 每次调用 | 全量 fd 从用户态拷到内核态 | 同左 | `epoll_ctl` 一次注册，`epoll_wait` 不再拷贝 |
| 复杂度 | O(n) 遍历所有 fd | O(n) | **O(1) 取就绪**（回调维护就绪链表） |
| 触发方式 | 只有 LT | 只有 LT | 支持 LT 与 ET |

Linux `eventpoll` 的核心结构（讲这三样就够专业）：

1. **红黑树**：`epoll_ctl(ADD)` 把 fd 及其回调挂到 `rbr`，增删查 O(log n)，避免每次全量拷贝。
2. **就绪链表 `rdllist`**：当某个 socket 有数据，内核网络栈调用注册的回调 `ep_poll_callback`，把这个 `epitem` 挂到就绪链表——**这是「事件驱动」的本质，不是轮询**。
3. **等待队列**：`epoll_wait` 把自己的 `wait_queue_entry` 挂到 `eventpoll.wq`，就绪链表非空或超时就返回，因此不需要扫描全部 fd。

实测（JDK 17/Windows）`Selector` 的实现类是 `sun.nio.ch.WEPollSelectorImpl`——连 Windows 版 JDK 都用 wepoll 模拟了 epoll 语义；Linux 上是 `EPollSelectorImpl`。

### 3.2 LT 与 ET：最容易翻车的一题

| 模式 | 语义 | 不读完会怎样 |
|---|---|---|
| 水平触发 LT（默认） | 只要 fd 可读，每次 `epoll_wait` 都返回它 | 不读也没关系，下次还通知（简单但可能空转） |
| 边缘触发 ET | 只在「状态变化」时通知一次 | 必须一次读到 `EAGAIN`，否则剩余数据可能再也不通知 |

ET 的正确写法有三个硬性要求：① fd 必须设为**非阻塞**（否则最后一次 `read` 会阻塞住整个 event loop）；② 读循环直到返回 `EAGAIN`；③ 写类似，注册 `EPOLLOUT` 前先尝试写。Netty 默认用 LT，因为它更不容易出错；只在高性能场景（如自研网关）才开 ET（`EpollChannelOption.EPOLL_MODE`）。

### 3.3 Reactor 模式与 Netty 的线程模型

```
单 Reactor 单线程 : accept + read + 业务都在一个线程（Redis 6 前）
单 Reactor 多线程 : accept/read 一个线程，业务丢线程池
主从 Reactor     : mainReactor 只 accept，subReactor 各管一批连接读写
```

Netty 就是主从 Reactor：`bossGroup`（通常 1 个线程）只做 `accept`，`workerGroup`（默认 2×CPU）负责读写与业务 handler。**每个 Channel 一生只绑定一个 EventLoop 线程**，所以同一个 Channel 的所有事件串行执行——这是 Netty「无锁化」的根源（不需要为 Channel 状态加锁）。

与 Proactor 的区别：Reactor 是「就绪通知，用户自己读写」；Proactor 是「完成通知，内核替你读写」（真正的 AIO）。Linux 上传统 AIO 不成熟，Netty 直接用 epoll；`io_uring` 才是 Linux 上接近 Proactor 的方案。

### 3.4 Java NIO 三件套与 Buffer 的四个指针

| 组件 | 作用 | 易错点 |
|---|---|---|
| `Channel` | 双向通道（可读可写） | 必须非阻塞才能注册 Selector（`FileChannel` 不行） |
| `Buffer` | 数据容器（position/limit/capacity/mark） | 写后必须 `flip()` 才能读；读完 `clear()` 或 `compact()` |
| `Selector` | 多路复用器 | `select()` 返回后必须 `selectedKeys().iterator().remove()`，否则下次重复处理 |

Buffer 状态机：写模式 `position` 递增；`flip()` 让 `limit = position`、`position = 0`；`clear()` 重置（不擦数据）；`compact()` 把未读数据移到头部再进入写模式。**忘了 `flip` 是最常见的 NIO bug**。

### 3.5 零拷贝：四种层次

| 方式 | 拷贝次数 | Java API |
|---|---|---|
| 传统 `read` + `write` | 4 次（2 次 DMA + 2 次 CPU） | `InputStream`/`OutputStream` |
| `sendfile` | 3 次（数据不进用户态） | `FileChannel.transferTo` |
| `sendfile + DMA gather` | 2 次 | 同上，内核支持时 |

Netty 的「零拷贝」是更宽的概念：① 堆外 `DirectByteBuf` 避免堆内到堆外的拷贝；② `CompositeByteBuf` 把多个 buffer 逻辑拼接而不复制；③ `slice`/`duplicate` 共享底层内存；④ `FileRegion` 底层就是 `transferTo`。

**实测**：`FileChannel.transferTo` 把一个 1MB 文件搬到另一个 Channel，返回 `1048576`，目标文件大小一致。

### 3.6 DirectByteBuffer 与堆外内存回收

- `ByteBuffer.allocateDirect(n)` 分配堆外内存，`isDirect() = true`、`hasArray() = false`（没法直接拿 `byte[]`）。
- 回收靠 `Cleaner`（`jdk.internal.ref.Cleaner`，实测反射能读到该字段）：对象不可达后 Cleaner 在 GC 时触发 `Unsafe.freeMemory`。**堆外泄漏通常是「DirectByteBuffer 对象还被引用」**。上限由 `-XX:MaxDirectMemorySize`（默认 = 最大堆）控制，实测 8m 时抛 `Cannot reserve ... bytes of direct buffer memory`。
- Netty 自己实现了 `PlatformDependent` 与池化 `ByteBuf`，大量使用堆外内存，所以线上必须配 `-XX:MaxDirectMemorySize` 并监控 `BufferPoolMXBean`（实测能看到 `direct`/`mapped` 两个池的 count 与 used）。

---

## L4 追问树（面试官一路往下问，你能撑到第几层？）

> 规则：从上往下问。**第 1-3 层是应届生必备，第 4-6 层拉开差距，第 7 层以后是加分。**

### 第 1 层｜BIO、NIO、多路复用有什么区别？
**答**：BIO 一个连接一个线程，`read` 阻塞，连接一多线程就爆；NIO 把连接设为非阻塞，`read` 没数据立刻返回，但需要自己轮询；多路复用把「轮询」交给内核（`select/epoll`），一个线程等一批 fd，谁就绪处理谁。NIO 在 Linux 上就是基于 epoll 的多路复用。

### 第 2 层｜为什么一个线程能管上万个连接？
**答**：线程不再「陪」每个连接等待。所有 fd 注册到 epoll，数据到达时内核通过回调把 fd 放进就绪链表，线程只需 `epoll_wait` 取就绪列表逐个处理。线程时间花在「处理就绪事件」而不是「阻塞等待」，所以连接数与线程数解耦。

### 第 3 层｜select、poll、epoll 的区别？epoll 为什么快？
**答**：select 用位图、fd 上限 1024、每次调用全量拷贝 fd 集合并 O(n) 遍历；poll 用数组解决上限但仍有拷贝和遍历；epoll 用内核红黑树管理 fd（`epoll_ctl` 注册一次），socket 有数据时内核回调 `ep_poll_callback` 把 `epitem` 挂到就绪链表，`epoll_wait` 只返回就绪 fd。快在三件事：不拷贝、不遍历、事件驱动。

### 第 4 层｜LT 和 ET 的区别？ET 要注意什么？
**答**：LT 只要可读就一直通知，ET 只在状态变化时通知一次。ET 必须：fd 非阻塞、一次读到 `EAGAIN`（否则剩余数据可能永远收不到通知）、写侧先尝试写再注册 `EPOLLOUT`。Netty 默认 LT 是为了不出错；开 ET 能减少通知次数但要自己保证读干净。

### 第 5 层｜epoll 的惊群问题是什么？怎么解决？
**答**：多个进程/线程同时 `epoll_wait` 同一个 listen fd，新连接到达时全部被唤醒但只有一个 `accept` 成功，其他白醒。解法：`EPOLLEXCLUSIVE`（内核只唤醒一个）、`SO_REUSEPORT`（每进程一个 listen socket，内核 hash 分发）、或「mainReactor 只在一个线程 accept」（Netty bossGroup 默认 1 线程就是规避它）。

### 第 6 层｜Reactor 有几种？Netty 是哪一种？
**答**：单 Reactor 单线程（Redis 风格）、单 Reactor 多线程（accept/read 一个线程，业务给线程池）、主从 Reactor（main 只 accept，sub 负责读写）。Netty 是主从 Reactor：`bossGroup` accept、`workerGroup` 处理 IO，且每个 Channel 固定绑一个 EventLoop 线程。

### 第 7 层｜Netty 的 EventLoop 为什么能做到无锁？
**答**：一个 Channel 从注册到关闭只绑定一个 EventLoop（一个线程），该 Channel 的所有 IO 事件和 handler 回调都在这个线程上串行执行，所以操作 Channel 状态不需要加锁。跨线程提交用 `EventLoop.execute` 丢进该线程任务队列。这就是 Netty 的「串行无锁化」。

### 第 8 层｜Netty 的零拷贝具体指什么？
**答**：四个层次：堆外 `DirectByteBuf` 免堆内到堆外拷贝；`CompositeByteBuf` 逻辑拼接不复制；`slice`/`duplicate` 共享底层数组；文件传输用 `FileRegion`（底层 `transferTo` 走 sendfile）。注意它和操作系统的「零拷贝」不是一回事，Netty 更多指「减少用户态内存拷贝」。

### 第 9 层｜ByteBuf 为什么要引用计数？泄漏怎么排查？
**答**：ByteBuf 背后可能是堆外或池化内存，GC 管不到、必须显式释放。引用计数让多个 handler 共享同一个 buffer 时安全决定何时回收（归零才 release）。排查用 `-Dio.netty.leakDetection.level=paranoid`，Netty 会对未释放的 buffer 打印分配栈；生产常用 simple/advanced。

### 第 10 层（终局）｜从网卡收到包到 Netty handler 被调用，内核和 JVM 各做了什么？
**答**：① 网卡 DMA 写入内核 `sk_buff` → 硬中断只做最少工作，剩余交给 NAPI 轮询；② 软中断 `NET_RX_SOFTIRQ` 走协议栈，TCP 把数据放进 socket 接收队列并唤醒等待者，epoll 场景下调 `ep_poll_callback` 把 `epitem` 挂到 `rdllist`；③ `epoll_wait` 返回就绪 fd，Netty 的 `EpollEventLoop`（封装 `Native.epollWait`）拿到事件；④ 经 `AbstractNioChannel` 触发 `ChannelPipeline` 的 inbound 链，到你的 `channelRead`；⑤ 数据从内核 socket 缓冲拷进 `ByteBuf`。整条链上真正阻塞的只有 `epoll_wait` 一次系统调用。

---

## L5 名词拆解表（"每个名词都拆开"）

| 名词 | 是什么 | 为什么存在 | 面试追问点 |
|---|---|---|---|
| fd | 文件描述符（socket 也是 fd） | 内核资源的句柄 | 为什么有 `ulimit -n` |
| `select`/`poll` | 老一代多路复用 | 一个线程等多个 fd | 缺点（拷贝 + 遍历 + 上限） |
| `epoll` | Linux 事件驱动多路复用 | O(1) 取就绪、无全量拷贝 | 红黑树/就绪链表/回调 |
| LT/ET | 水平/边缘触发 | 通知策略不同 | ET 为什么必须读干净 |
| Reactor | 就绪通知 + 用户读写的事件模型 | 单线程管多连接 | 单/多/主从三种 |
| Proactor | 完成通知 + 内核代读写 | 真正异步 | Linux 上为何少用 |
| `EventLoop` | Netty 的事件循环（1 线程 1 循环） | Channel 串行化、无锁 | 为什么一个 Channel 绑一个 |
| `ChannelPipeline` | handler 双向链 | 把 IO 处理拆成可组合的链 | inbound/outbound 方向 |
| `ByteBuf` | Netty 的缓冲区（读写下标分离） | 免 flip、支持池化/堆外 | readerIndex/writerIndex |
| 零拷贝 | 减少数据拷贝的技术集合 | 降 CPU/内存带宽开销 | sendfile vs mmap vs Netty 四种 |

---

## 代码验证（`NioProbe.java`，JDK 17 编译运行通过）

```java
import java.lang.reflect.Field;
import java.net.*;
import java.nio.*;
import java.nio.channels.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;

public class NioProbe {
    public static void main(String[] a) throws Exception {
        // 1) 单线程 Selector 同时管 Server 与 Client
        Selector sel = Selector.open();
        ServerSocketChannel server = ServerSocketChannel.open();
        server.bind(new InetSocketAddress("127.0.0.1", 0));
        server.configureBlocking(false);
        server.register(sel, SelectionKey.OP_ACCEPT);
        int port = ((InetSocketAddress) server.getLocalAddress()).getPort();
        SocketChannel client = SocketChannel.open();
        client.configureBlocking(false);
        client.connect(new InetSocketAddress("127.0.0.1", port));
        client.register(sel, SelectionKey.OP_CONNECT);

        SocketChannel accepted = null;
        StringBuilder got = new StringBuilder();
        long deadline = System.currentTimeMillis() + 3000;
        while (System.currentTimeMillis() < deadline && got.indexOf("pong") < 0) {
            if (sel.select(200) == 0) continue;
            for (Iterator<SelectionKey> it = sel.selectedKeys().iterator(); it.hasNext(); ) {
                SelectionKey k = it.next();
                it.remove();                                   // 必须 remove，否则重复处理
                if (k.isConnectable()) { client.finishConnect(); k.interestOps(SelectionKey.OP_WRITE); }
                else if (k.isWritable()) { client.write(StandardCharsets.UTF_8.encode("ping")); k.interestOps(SelectionKey.OP_READ); }
                else if (k.isAcceptable()) {
                    accepted = server.accept();
                    accepted.configureBlocking(false);
                    accepted.register(sel, SelectionKey.OP_READ);
                } else if (k.isReadable()) {
                    ByteBuffer buf = ByteBuffer.allocate(64);
                    if (((SocketChannel) k.channel()).read(buf) > 0) {
                        buf.flip();                            // 写模式转读模式
                        String s = StandardCharsets.UTF_8.decode(buf).toString();
                        if (k.channel() == accepted) accepted.write(StandardCharsets.UTF_8.encode("pong"));
                        got.append(s);
                    }
                }
            }
        }
        System.out.println("selector=" + sel.getClass().getSimpleName() + ", echo=" + got);
        client.close(); server.close(); if (accepted != null) accepted.close(); sel.close();

        // 2) 零拷贝 transferTo
        Path src = Files.createTempFile("nio-src", ".bin");
        Path dst = Files.createTempFile("nio-dst", ".bin");
        byte[] data = new byte[1 << 20];
        new Random(42).nextBytes(data);
        Files.write(src, data);
        try (FileChannel in = FileChannel.open(src, StandardOpenOption.READ);
             FileChannel out = FileChannel.open(dst, StandardOpenOption.WRITE)) {
            System.out.println("transferTo=" + in.transferTo(0, in.size(), out) + " bytes");
        }
        Files.deleteIfExists(src); Files.deleteIfExists(dst);

        // 3) 堆外缓冲 + Cleaner
        ByteBuffer direct = ByteBuffer.allocateDirect(1024);
        Field cleaner = direct.getClass().getDeclaredField("cleaner");
        cleaner.setAccessible(true);
        System.out.println("direct=" + direct.isDirect() + ", hasArray=" + direct.hasArray()
                + ", cleaner=" + cleaner.get(direct).getClass().getName());
    }
}
```

```bash
javac -encoding UTF-8 NioProbe.java
java --add-opens java.base/java.nio=ALL-UNNAMED NioProbe

java -XX:MaxDirectMemorySize=8m -cp . 自己写一个循环 allocateDirect 的类
```

**实测输出**：`selector=WEPollSelectorImpl, echo=pingpong`（Windows JDK 17；Linux 上是 `EPollSelectorImpl`）；`transferTo=1048576 bytes`；`direct=true, hasArray=false, cleaner=jdk.internal.ref.Cleaner`。

---

## 高频错误（面试官最爱抓的）

| 错误说法 | 正确说法 |
|---|---|
| 「NIO 就是异步 IO」 | NIO 是同步非阻塞 + 多路复用，真正异步是 AIO/io_uring |
| 「epoll 也是轮询所有 fd」 | 事件驱动：回调把就绪 fd 挂链表，`epoll_wait` 只取就绪 |
| 「select 和 epoll 性能差不多」 | select 每次全量拷贝 + O(n) 遍历，连接多时差距巨大 |
| 「零拷贝就是一次都不拷贝」 | 是减少拷贝次数（少掉用户态那两次），DMA 拷贝仍在 |
| 「DirectByteBuffer 会被 GC 直接回收」 | 靠 Cleaner/虚引用在对象不可达后释放，时机不确定 |

---

## 关联文件

- 广度版（60 秒能答）：[Java基础与并发](../../03-java/Java基础与并发.md)；网络层背景见 [HTTP 与浏览器](../../05-network/HTTP与浏览器.md)
- 同层追问：[ConcurrentHashMap](./12-ConcurrentHashMap.md)（Netty 的 Channel 注册表也是并发 Map）｜[JVM 调优与线上排查](./14-JVM调优与线上排查.md)（堆外内存泄漏怎么查）
- 典型场景：报告平台的 SSE 是长连接，如果用 BIO 模型一个连接一个线程，几百个前端就把线程池打满——Tomcat 的 NIO 连接器 + Servlet 异步/SSE 正是这页的落地；MinIO 文件上传下载走 `FileChannel.transferTo` 就是零拷贝；Docker 沙箱的流式输出靠的是 `Channel` 非阻塞读写而不是每个容器一个线程傻等
- 延伸：网关/代理的并发模型（Nginx 多进程 + epoll、Netty 主从 Reactor）是 [系统设计入门](../../06-system-design/系统设计入门.md) 里「高并发接入层」的标配

> **自测标准**：能讲清「epoll 凭什么比 select 快」「LT/ET 的坑」「Netty 的 EventLoop 为什么无锁」，并跑通 `NioProbe` 的三段输出，算过关。