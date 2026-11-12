# TCP 连接与调优（握手 / 挥手 / 窗口 / 拥塞控制 / backlog）

> 面试权重：5/5　｜　追问深度：**L5（内核 socket 状态机 / sk_buff / 拥塞控制实现）**
> 一句话定位：TCP 把"不可靠的 IP 报文"做成"可靠的字节流"。所有"连接为什么建不起来、为什么断、为什么慢"的问题，都能落到四个机制上：**握手建状态、挥手拆状态、滑动窗口做流量控制、拥塞控制做网络适配**。

**本文件用法**：先背 L2 的状态迁移与参数，再逐层往内核追。答不出"TIME_WAIT 为什么是 2MSL""backlog 管哪个队列"，说明只是背了名词。
[返回深度追问索引](../00-索引.md)

---

## L1 一句话答案（10 秒能说出口）

三次握手让双方各自确认"我的发、你的收、你的发、我的收"都正常，并同步初始序列号 ISN；四次挥手指两个方向各自关闭（半关闭），主动关闭方最后进入 **TIME_WAIT 等 2MSL**，保证最后那个 ACK 能送达、且旧连接的报文在网络里消亡；**CLOSE_WAIT 则是被动关闭方的应用没有调用 `close()`**，是代码问题。传输效率由**滑动窗口（接收能力）与拥塞控制（网络容量）取最小值**决定，再叠加 Nagle/延迟 ACK/backlog 这些工程细节。

---

## L2 原理层：握手、挥手、窗口与调优参数

### 2.1 三次握手：每一步的字段与状态迁移

```
客户端                                        服务端
  │ SYN=1, seq=x（ISN 随机）
  │ Options: MSS=1460, Window Scale=7, SACK permitted, Timestamps
  ▼
SYN_SENT        ─────────────────────────►   LISTEN
                                             │ 收到 SYN：创建请求块放入 SYN 队列
                                             ▼
                                           SYN_RCVD
                ◄─────────────────────────   SYN=1, ACK=1, seq=y, ack=x+1
  ▼ 收到 SYN+ACK，回 ACK=1, seq=x+1, ack=y+1（可带数据）
ESTABLISHED     ─────────────────────────►   收到 ACK：从 SYN 队列移到 accept 队列
                                              ▼
                                            ESTABLISHED
```

| 报文 | 关键字段 | 作用 |
|---|---|---|
| 第 1 个 SYN | `SYN=1, seq=x, MSS, WS, SACK_PERM, TS` | 发起连接 + 通告能力（最大段、窗口扩大、选择性确认、时间戳） |
| 第 2 个 SYN+ACK | `SYN=1, ACK=1, seq=y, ack=x+1` | 确认客户端 SYN + 同步自己的 ISN |
| 第 3 个 ACK | `ACK=1, seq=x+1, ack=y+1` | 确认服务端 SYN，客户端先进入 ESTABLISHED |

**为什么必须三次**：两次不够——服务端回 SYN+ACK 后无法确认"客户端收到了我的 ISN"，若此时建立连接，客户端可能因历史重复 SYN 而处于错误状态。三次让**双方都确认了对方收到了自己的 ISN**；ISN 随机化同时用于防序列号预测攻击（伪造 RST/注入）。四次没必要，第 2、3 次无法合并（方向不同）。

### 2.2 四次挥手、TIME_WAIT 与 CLOSE_WAIT

```
客户端（主动关闭）                          服务端（被动关闭）
ESTABLISHED                                 ESTABLISHED
  │ FIN=1, seq=u
  ▼
FIN_WAIT_1    ───────────────────────────►  收到 FIN，回 ACK
                                             ▼
FIN_WAIT_2                                 CLOSE_WAIT   ← 应用还没 close()
  │  ◄─────────────────────────────────────── FIN=1, seq=w（应用 close() 后发）
  ▼
TIME_WAIT（等 2MSL）─── 回 ACK（ack=w+1） ───► LAST_ACK
  │ 2MSL 后关闭
CLOSED
```

- **为什么四次**：TCP 全双工，两个方向独立关闭，FIN 只表示"我没数据要发了"（半关闭），对端仍可继续发。
- **TIME_WAIT 的两个作用**：① **保证最后一个 ACK 能到达**——若 ACK 丢失，对端会重发 FIN，2MSL 内还能重传 ACK，否则对端会一直停在 LAST_ACK；② **让本连接的报文在网络中消亡**——MSL 是报文最长存活时间，等 2MSL 后新连接（相同四元组）不会收到旧连接的迟到报文。Linux 的 MSL 固定 60s（`TCP_TIMEWAIT_LEN`），所以 TIME_WAIT 约 60s。
- **TIME_WAIT 多**：发生在**主动关闭方**（流量大的服务端常见）。处理：`SO_REUSEADDR` 允许 bind（不减少 TW）、`net.ipv4.tcp_max_tw_buckets`、**`tcp_tw_reuse=1`**（仅 outbound 连接、需 timestamps、1s 后复用，安全）、用连接池/长连接减少短连接。**不要用 `tcp_tw_recycle`**：它依赖对端时间戳单调，NAT 后多个客户端时间戳不一致会被误判定丢包，**Linux 4.12 已移除**。
- **CLOSE_WAIT 多**：发生在**被动关闭方**，说明应用收到 FIN 后没有 `close()`（异常路径未关连接、连接池泄漏、线程阻塞不释放）。这是**应用代码问题**，调内核参数无用，要查 fd 句柄与连接泄漏。

### 2.3 滑动窗口与零窗口探测

- 接收方在 ACK 里带 `rwnd`（接收窗口），发送方实际可发窗口 = `min(rwnd, cwnd)`；`rwnd` 反映**接收端处理能力**，`cwnd` 反映**网络容量**。
- 首部窗口字段只有 16 bit（最大 65535 字节），高带宽高时延链路（BDP 大）不够用，所以在握手里协商 **Window Scale**（移位因子，最大 14），把窗口扩大到约 1GB。
- 窗口为 0 时发送方停止发送，并启动**零窗口探测**（Zero Window Probe）：每隔一段时间发 1 字节探测，对端回 ACK（含最新窗口），避免"窗口更新 ACK 丢失导致双方死锁"。接收方也会用 **SWS（糊涂窗口避免）** 延迟通告小窗口，避免大量小段。

### 2.4 拥塞控制四阶段（Reno，Linux 默认 CUBIC）

| 阶段 | 触发 | cwnd 变化 |
|---|---|---|
| 慢启动 | 连接开始 / 超时后 | 每个 ACK +1 MSS，**每 RTT 翻倍**，直到 `ssthresh` |
| 拥塞避免 | cwnd >= ssthresh | 每 RTT +1 MSS（线性增长） |
| 快重传 | 收到 **3 个重复 ACK** | 立即重传丢失段，不等超时 |
| 快恢复 | 快重传之后 | `ssthresh = cwnd/2`，`cwnd = ssthresh`，直接进拥塞避免（不回慢启动） |

对比：**超时重传**更严重——`ssthresh = cwnd/2`、`cwnd = 1`，回到慢启动；**快重传 + 快恢复**只降一半并继续线性增长。现代内核默认 CUBIC（高带宽长肥管道更友好），BBR 则基于带宽与 RTT 建模、不靠丢包信号。

### 2.5 Nagle 与延迟 ACK 的 40ms 组合坑

- **Nagle 算法**：连接上还有未被 ACK 的小包时，新的小包先攒着，等 ACK 或攒够 MSS 再发（减少小包数量）。
- **延迟 ACK 与组合坑**：接收方不立即回 ACK，等最多 40ms（Linux 实际是每两个包或超时才回）。于是请求-响应模式里，客户端发小请求（Nagle 等 ACK）→ 服务端延迟 ACK 等 40ms → 客户端 40ms 后才发下一段，表现为"每次请求多 40ms"。解法：`TCP_NODELAY` 关 Nagle（Netty/HTTP 客户端默认开）、一次 `write` 发完整请求、减少往返次数。

### 2.6 backlog、SYN 队列与 accept 队列

```
listen(fd, backlog)
   ├── SYN 队列（半连接）：收到 SYN，回 SYN+ACK，等对方 ACK；上限≈tcp_max_syn_backlog，受 syncookies 影响
   └── accept 队列（全连接）：三次握手完成、等应用 accept()；上限 = min(backlog, net.core.somaxconn)
```

- **队列满了**：SYN 队列满 → 丢 SYN（客户端重试，`netstat -s` 的 `SYNs to LISTEN sockets dropped` 上涨）；accept 队列满 → 内核默认丢弃最后的 ACK（客户端以为已建连，实际服务端不认，之后发数据收到 RST），`tcp_abort_on_overflow=1` 时不丢而是直接回 RST。
- **观测**：`ss -lnt` 的 `Recv-Q` 是当前 accept 队列长度、`Send-Q` 是 backlog 上限；`Recv-Q` 持续接近 `Send-Q` 就是 accept 不过来。
- **Spring Boot** 的 `server.tomcat.accept-count`（默认 100）对应 accept 队列；Nginx 的 `listen ... backlog=511` 同理。

### 2.7 长连接、keepalive 与心跳

- `SO_KEEPALIVE` 是**空闲探测**：`tcp_keepalive_time`（默认 7200s）后才发第一个探测，`tcp_keepalive_intvl=75`、`tcp_keepalive_probes=9`。它只能发现死连接，**不能替代应用层心跳**，也不防 NAT/网关的超时。
- 中间设备（NAT、SLB、Nginx）有 idle timeout（常见 60s/300s），空闲连接被静默丢弃，客户端以为还活着。所以：**SSE 用注释事件心跳、WebSocket 用 ping/pong 或业务心跳，HTTP 长连接用 `keepalive_timeout` 与定时请求**。应用层心跳间隔要小于链路中各设备的最小 idle timeout。

### 2.8 粘包与拆包的四种解法

TCP 是**字节流**，没有消息边界，一次 `read` 可能读到半个消息或多个消息。解法：
1. **定长**：每条消息固定长度，简单但浪费（如不足补齐）；
2. **分隔符**：`\n`、`\0`（Redis RESP、SSE 的空行分隔、HTTP 头 `\r\n\r\n`）；
3. **长度前缀**（最通用）：固定 4 字节长度 + body（gRPC、自定义二进制协议、Kafka 协议）；
4. **自描述/分帧协议**：HTTP 的 `Content-Length`/chunked、WebSocket 帧（本身有边界，所以 WebSocket 不存在粘包问题，但帧里的流式 PCM 仍需业务切分）。

---

## L3 底层层：内核里的 socket 与队列

### 3.1 连接在内核里的表示

```
struct sock / struct tcp_sock
  ├── 状态机：TCP_SYN_SENT / SYN_RECV / ESTABLISHED / FIN_WAIT1 / TIME_WAIT ...
  ├── 发送队列 write_queue（sk_buff 链表）+ 重传队列 retransmit queue
  ├── 接收队列 receive_queue + ofo_queue（乱序重组）
  ├── snd_nxt / snd_una / rcv_nxt（序列号指针）
  └── 拥塞控制：snd_cwnd / ssthresh（tcp_cong.c 的算法钩子）
LISTEN socket
  ├── icsk_accept_queue（全连接队列，队列项 request_sock/young socket）
  └── SYN 队列（半连接，受 syncookies 保护）
```

数据发送路径：应用 `write()` → 按 MSS 分片 → 拷入 sk_buff → 进发送队列 → 网卡 DMA 发出 → 保存到重传队列直到被 ACK；`tcp_ack()` 处理 ACK 时更新 `snd_una`、滑动窗口、拥塞窗口，并触发重传/快恢复判断。

### 3.2 TIME_WAIT 的内核处理

主动关闭方在 `tcp_time_wait()` 里把 socket 从哈希表摘出、只保留一个 `inet_timewait_sock` 放进 **TIME_WAIT 哈希桶**，不占 fd/内存大头；2MSL 到期由定时器回收。这也解释了为什么 TIME_WAIT 多会占端口：四元组在 2MSL 内不可复用，除非 `tcp_tw_reuse` 用时间戳判断旧包不会误收。

### 3.3 观测手段（排障三件套）

```bash
ss -lnt                      # Recv-Q=accept 队列长度, Send-Q=backlog
ss -s                        # 各状态连接数汇总（TIME_WAIT/ESTAB 等）
tcpdump -i eth0 -nn 'tcp[tcpflags] & (tcp-syn|tcp-fin|tcp-rst) != 0'
ss -ti                       # 每个连接的 cwnd/rtt/重传次数（内核 tcp_info）
```

---

## L4 追问树（面试官一路往下问，你能撑到第几层？）

> 规则：第 1-3 层必备，4-6 层拉开差距，7 层以后是加分。

### 第 1 层｜三次握手为什么是三次，不是两次或四次？
**答**：三次让双方都确认"对方收到了我的 ISN、双方收发都正常"。两次不够：服务端发完 SYN+ACK 无法确认客户端是否收到，历史重复 SYN 会造成错误连接（ISN 随机化也是为此）。四次没必要：第 2、3 次方向不同不能合并，但已经满足双方各一次 SYN + 一次 ACK。

### 第 2 层｜握手每步的字段与状态迁移？
**答**：客户端 `SYN=1,seq=x` 带 MSS/窗口扩大/SACK/时间戳，进 `SYN_SENT`；服务端从 `LISTEN` 收到后回 `SYN=1,ACK=1,seq=y,ack=x+1`，进 `SYN_RCVD`；客户端回 `ACK=1,seq=x+1,ack=y+1` 进 `ESTABLISHED`；服务端收到后从 SYN 队列移到 accept 队列，也进 `ESTABLISHED`。

### 第 3 层｜SYN 队列满和 accept 队列满分别会发生什么？
**答**：SYN 队列（半连接）满 → 新 SYN 被丢弃（或 syncookies 兜底），客户端重试，`netstat -s` 的 "SYNs to LISTEN sockets dropped" 上涨；accept 队列（全连接）满 → 内核默丢弃最后的 ACK，客户端以为连上了，发数据时收到 RST；`tcp_abort_on_overflow=1` 时直接 RST。`ss -lnt` 的 Recv-Q/Send-Q 能看出来。

### 第 4 层｜四次挥手为什么是四次？能合并吗？
**答**：TCP 全双工，两个方向独立关闭。被动方收到 FIN 只表示对方不发数据了，它可能还有数据要发，所以先 ACK、等应用 `close()` 后再发自己的 FIN。若被动方也没有数据要发且延迟 ACK 未触发，FIN 与 ACK 可合并成三次；同时关闭时双方都进 FIN_WAIT，流程也会简化。

### 第 5 层｜TIME_WAIT 的两个作用？为什么是 2MSL？
**答**：① 保证最后一个 ACK 能到达（丢了可重传，否则对端卡在 LAST_ACK）；② 让旧连接的报文在网络中消亡，避免新连接（同四元组）收到历史报文。MSL 是报文最长存活时间，一来一回最长 2MSL，所以等 2MSL。Linux MSL 固定 60s。

### 第 6 层｜线上大量 TIME_WAIT 或 CLOSE_WAIT 怎么处理？
**答**：TIME_WAIT 在主动关闭方，属正常现象，处理靠连接池/长连接/`SO_REUSEADDR`/`tcp_tw_reuse`（仅 outbound + timestamps）；`tcp_tw_recycle` 因 NAT 下时间戳误判已在 4.12 移除，不能用。CLOSE_WAIT 是被动关闭方**应用没 close()**，查 fd 泄漏、异常路径未释放、连接池配置，调内核参数无用。

### 第 7 层｜滑动窗口怎么扩容？窗口为 0 怎么办？
**答**：首部窗口 16 bit 最大 65535，握手里协商 Window Scale 移位因子（≤14）把窗口扩到约 1GB，解决高 BDP 链路吞吐受限。窗口为 0 时发送方停止发送并启动零窗口探测（定时发 1 字节探测），对方回 ACK 带最新窗口；避免窗口更新 ACK 丢失导致双方死锁。

### 第 8 层｜拥塞控制四阶段？超时和快重传有什么不同？
**答**：慢启动（cwnd 每 RTT 翻倍到 ssthresh）、拥塞避免（线性 +1 MSS/RTT）、快重传（3 个重复 ACK 立即重传）、快恢复（ssthresh=cwnd/2，cwnd=ssthresh，直接线性增长）。区别：超时更严重（cwnd 打回 1、回慢启动）；快重传说明网络还能通、只是个别丢包，所以只降一半。

### 第 9 层｜Nagle 和延迟 ACK 为什么会凑出 40ms？怎么解？
**答**：Nagle 在"有未确认小包"时憋着不发，延迟 ACK 又最多等 40ms 才回 ACK，两个机制互等 → 请求-响应小包交互每次多 40ms。解法：`TCP_NODELAY` 关闭 Nagle、一次 write 发完整请求、或改用更少往返的协议（HTTP/2 多路复用）。

### 第 10 层｜keepalive 和业务心跳是什么关系？
**答**：`SO_KEEPALIVE` 是内核空闲探测，默认 2 小时才发第一个探测，太慢；且 NAT/负载均衡的 idle timeout（60s/300s）比它短得多。业务心跳（SSE 注释事件、WS ping/pong）间隔可控（20-30s），能穿代理、能统计 RTT，还能让服务端及时清理死连接。**两者互补，业务心跳才是主力。**

### 第 11 层｜粘包怎么解？为什么 WebSocket 没有这个问题？
**答**：TCP 是字节流无边界，解法有定长、分隔符、长度前缀、自描述协议（HTTP Content-Length/chunked）四种，最通用是长度前缀。WebSocket 在 TCP 之上有自己的帧协议（FIN/opcode/payload len），消息边界由协议保证，所以应用层不会粘包；但帧内传的音频 PCM 这类流式数据仍要业务按固定 chunk 切分。

### 第 12 层（终局）｜一次 `connect()` 到 ESTABLISHED，内核里发生了什么？
**答**：应用 `connect()` → 内核分配 `struct sock`、选源端口、生成随机 ISN、构造 SYN（带 MSS/WS/SACK/TS 选项）→ 经路由、邻居子系统封装成 sk_buff → 网卡发出 → 状态 `TCP_SYN_SENT`。收到 SYN+ACK 后更新 `snd_una`、记录对端窗口与选项，回 ACK 并置 `ESTABLISHED`。服务端 `LISTEN` socket 收到 SYN 时创建 `request_sock` 挂到 SYN 队列并回 SYN+ACK；收到第三个 ACK 时把它转成完整 socket 挂到 **accept 队列**，唤醒阻塞在 `accept()`/`epoll` 的进程，`accept()` 返回新 fd。**队列满、选项协商、状态迁移全在内核完成，应用只能通过 backlog/参数间接影响。**

---

## L5 名词拆解表（每个名词都拆开）

| 名词 | 是什么 | 为什么存在 | 面试追问点 |
|---|---|---|---|
| ISN | 初始序列号（随机） | 标识字节流起点、防序列号预测 | 为什么随机、防什么攻击 |
| TIME_WAIT | 主动关闭后等 2MSL 的状态 | 保证 ACK 送达 + 旧包消亡 | 为什么 2MSL、大量 TW 怎么办 |
| CLOSE_WAIT | 被动关闭方等应用 close 的状态 | 支持半关闭 | 堆积=应用没 close（代码问题） |
| rwnd / cwnd | 接收窗口 / 拥塞窗口 | 流量控制 / 拥塞控制 | 实际窗口取 min、二者区别 |
| 零窗口探测 | 窗口为 0 时的周期探测 | 防窗口更新 ACK 丢失死锁 | 探测间隔与退避 |
| 慢启动 / 拥塞避免 | cwnd 指数 / 线性增长 | 探测网络容量 | ssthresh 怎么变 |
| 快重传 / 快恢复 | 3 重复 ACK 立即重传 / 降半继续 | 减少等待超时 | 与超时重传的区别 |
| Nagle 算法 | 小包攒批发送 | 减少小包开销 | 与延迟 ACK 组合的 40ms（延迟 ACK 最多等 40ms） |
| backlog / somaxconn | listen 队列上限参数 | 控制 accept 队列长度 | 管的是全连接队列，SYN 队列另有参数 |
| 粘包 | 字节流无消息边界 | 应用需自己分帧 | 四种解法、长度前缀最通用 |

---

## 代码验证

```bash
# 1) 看握手/挥手相关状态与队列
ss -lnt                       # Recv-Q（accept 队列长度）Send-Q（backlog 上限）
ss -s                         # 各状态数量，关注 TIME-WAIT / ESTAB
tcpdump -i eth0 -nn 'tcp[tcpflags] & (tcp-syn|tcp-fin|tcp-rst) != 0' -c 20

# 2) 看单连接内核指标 + 相关参数
ss -ti dst 10.0.0.2:8080      # cwnd、rtt、重传次数
sysctl net.core.somaxconn net.ipv4.tcp_max_syn_backlog net.ipv4.tcp_tw_reuse
```

```java
// 3) Java 侧：关 Nagle + 开 keepalive（长连接客户端/服务端都适用）
Socket socket = new Socket();
socket.setTcpNoDelay(true);              // 关 Nagle，避免 40ms 组合坑
socket.setKeepAlive(true);               // 内核空闲探测（辅助，不能替代心跳）
socket.connect(new InetSocketAddress("api.example.com", 443), 1_000);

// 4) 粘包处理：长度前缀解码（Netty 写法，最通用）
pipeline.addLast(new LengthFieldBasedFrameDecoder(
        64 * 1024, 0, 4, 0, 4));             // maxFrame, offset, lenField, adjust, strip
pipeline.addLast(new LengthFieldPrepender(4));   // 发送时自动加 4 字节长度
```

---

## 高频错误（面试官最爱抓的）

| 错误说法 | 正确说法 |
|---|---|
| 「TIME_WAIT 是服务端 bug，要尽量消除」 | 它是主动关闭方的正常状态，保 ACK 送达与旧包消亡；只能减少短连接、复用端口 |
| 「CLOSE_WAIT 多也是内核参数问题」 | CLOSE_WAIT 是被动关闭方应用没调用 `close()`，是代码/连接泄漏问题 |
| 「listen 的 backlog 管 SYN 队列」 | backlog 管的是 accept 队列（全连接），SYN 队列由 `tcp_max_syn_backlog` 影响 |
| 「窗口大小就是 rwnd」 | 实际发送窗口 = min(rwnd, cwnd)，前者是接收能力，后者是网络容量 |
| 「快重传后 cwnd 回到 1」 | 回 1 的是超时重传；快重传后进快恢复，cwnd 降到一半继续线性增长 |
| 「keepalive 打开就不会断连」 | 默认 2 小时才探测，远大于 NAT/网关 idle timeout，必须业务心跳 |
| 「`tcp_tw_recycle` 能加速回收，可以开」 | 该参数在 NAT 下导致丢包，Linux 4.12 已移除，禁止使用 |

---

## 关联文件

- 下一层：TLS 与 HTTPS 握手（握手之上的握手）：[TLS 与 HTTPS 握手](./02-TLS与HTTPS握手.md)
- 网络与浏览器基础：[HTTP与浏览器](../../05-network/HTTP与浏览器.md)
- 系统层面的连接与 fd 排查：[Linux 性能排查](../ops/01-Linux性能排查.md)
- 项目落点：报告平台的 SSE 长连接、数字人 WebSocket 音频流都建立在 TCP 长连接上，遇到断连先查 NAT/LB idle timeout 与应用心跳

> **自测标准**：能画出三次握手/四次挥手的状态迁移与关键字段，说清 TIME_WAIT 两个作用与 2MSL，区分 TIME_WAIT/CLOSE_WAIT 归属，讲出拥塞控制四阶段与 Nagle+延迟 ACK 的 40ms，知道 backlog 管 accept 队列，算过关。
