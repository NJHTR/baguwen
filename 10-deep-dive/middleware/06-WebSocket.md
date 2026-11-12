# WebSocket（Upgrade 握手 / 帧协议 / 心跳 / 集群会话）

> 面试权重：5/5　｜　追问深度：**L5（HTTP Upgrade 握手 / 帧头比特位 / 掩码算法）**
> 一句话定位：WebSocket 是**借用一次 HTTP 请求完成握手（101 Switching Protocols）后，在同一条 TCP 连接上切换到自定义帧协议的全双工通道**。握手解决"怎么从 HTTP 转过来、顺便鉴权"，帧协议解决"消息边界、二进制、控制帧"，剩下的心跳、断线、集群广播都是工程问题。

**本文件用法**：重点背握手三行头 + 帧头比特图 + 掩码规则，这是"协议层"追问的分水岭。你的多模态项目就是 WebSocket 实战，示例已贴。
[返回深度追问索引](../00-索引.md)

---

## L1 一句话答案（10 秒能说出口）

客户端发带 `Upgrade: websocket`、`Connection: Upgrade`、`Sec-WebSocket-Key` 的 HTTP 请求，服务端返回 **101 Switching Protocols** 和算好的 `Sec-WebSocket-Accept`（`base64(sha1(key + 固定 GUID))`）；之后同一条 TCP 连接不再走 HTTP，而按 WebSocket 帧格式收发：**客户端发的帧必须掩码，服务端发的帧不能掩码**；帧头用 FIN/opcode 表示分片与类型，支持文本、二进制、ping/pong、close。心跳用 ping/pong 保活，Nginx 要放行 Upgrade 并调大超时。

---

## L2 原理层：握手与帧格式

### 2.1 HTTP Upgrade 握手（请求 / 响应原文）

```http
GET /ws/asr?token=eyJhbGciOi... HTTP/1.1
Host: api.example.com
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==        ← 16 字节随机数的 base64
Sec-WebSocket-Version: 13
```

```http
HTTP/1.1 101 Switching Protocols
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
```

**`Sec-WebSocket-Accept` 算法（必会手算）**：`accept = base64( SHA1( key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11" ) )`。固定 GUID 让握手"不像普通 HTTP"，防中间代理误缓存/复用；**它不是鉴权/加密**，只是证明对端真懂 WebSocket。安全靠 `Origin` 校验 + `wss://` + token 鉴权。

### 2.2 帧格式（字节级，必背）

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-------+-+-------------+-------------------------------+
|F|R|R|R| opcode|M| Payload len |    Extended payload length    |
|I|S|S|S|  (4)  |A|     (7)     |            (16/64)            |
|N|V|V|V|       |S|             |  (payload len==126/127 时)    |
| |1|2|3|       |K|             |                               |
+-+-+-+-+-------+-+-------------+ - - - - - - - - - - - - - - - +
|    Extended payload length continued, if payload len == 127    |
+-------------------------------+-------------------------------+
| Masking-key, if MASK set to 1 (4 bytes)                        |
+-------------------------------+-------------------------------+
| Payload Data (masked if MASK=1)                                |
+---------------------------------------------------------------+
```

| 字段 | 位宽 | 含义 |
|---|---|---|
| FIN | 1 bit | 1 = 消息最后一帧；0 = 后面还有分片 |
| RSV1-3 | 3 bit | 扩展用（`permessage-deflate` 用 RSV1），没协商必须 0 |
| opcode | 4 bit | `0x0` 延续、`0x1` 文本、`0x2` 二进制、`0x8` close、`0x9` ping、`0xA` pong |
| MASK | 1 bit | **客户端→服务端必须为 1；服务端→客户端必须为 0** |
| Payload len | 7 bit | 0-125 直接表示；**126** 后接 2 字节（16 位）；**127** 后接 8 字节（64 位） |
| Masking-key | 4 字节（MASK=1） | 掩码密钥，`payload[i] ^= mask[i % 4]` |

**控制帧约束**：opcode ≥ 0x8（close/ping/pong），**payload ≤ 125 字节、不可分片、FIN 必须为 1**；可插在分片消息中间（心跳不被大消息阻塞）。

### 2.3 为什么客户端必须掩码？服务端不能掩码？

防**缓存投毒**：早期代理会缓存看起来像 HTTP 的流量，攻击者构造 payload 污染缓存；客户端掩码后载荷不再可预测。**掩码不是加密**（密钥在帧里），只打乱明文形态，RFC 规定服务端收到未掩码客户端帧要用 **1002** 关闭。服务端方向不存在该威胁，掩码纯属额外 CPU，所以不掩码。

### 2.4 分片与"粘包"

- 一条消息可拆成首帧（opcode 文本/二进制 + FIN=0）+ 若干延续帧（opcode=0x0）+ 末帧（FIN=1），接收方**按 FIN 重组完整消息**后才回调业务。**所以 WebSocket 应用层不存在 TCP 粘包/拆包问题**（协议自带帧边界）；但帧里的流式数据（音频 PCM、自定义二进制协议）仍要业务按长度/时间片切分——多模态项目上传的 PCM 按固定 chunk（如 20/40ms）切好。裸 TCP 则必须用「长度前缀 / 分隔符 / 定长」自己分帧。

### 2.5 心跳与超时检测

| 方式 | 谁发 | 说明 |
|---|---|---|
| 协议级 ping/pong | 服务端发 `0x9`，客户端自动回 `0xA` | **浏览器 JS 不能主动发 ping**，但收到会自动回 pong |
| 业务心跳 | 两端发 JSON `{"type":"ping"}` | 穿过代理、可统计 RTT、浏览器端唯一可控方式 |

**两者都要**：JS 收不到 ping 回调，无法感知对端存活；业务心跳还可避免代理 idle timeout 断连（间隔小于 `proxy_read_timeout`，一般 20-30s）。

### 2.6 Spring 的三种实现与集群会话

| 方式 | 用法 | 适用 |
|---|---|---|
| `WebSocketHandler`（原生） | 继承 `TextWebSocketHandler`/`BinaryWebSocketHandler`，`WebSocketConfigurer` 注册 | 自定义二进制协议（**数字人 ASR 音频流**） |
| `@ServerEndpoint`（JSR-356） | `@OnOpen/@OnMessage/@OnClose/@OnError`，Spring Boot 需 `ServerEndpointExporter` | 简单、但不便注入 Spring Bean |
| STOMP over WebSocket | `@MessageMapping` + `SimpMessagingTemplate`/Broker Relay | 订阅/广播语义（聊天室、行情） |

**集群会话**：`WebSocketSession` 是单机内存对象，A 节点无法直接向 B 节点的连接发消息。方案：**Redis pub/sub**（各节点订阅，收到广播后只推本地 session，最常用）、**MQ**（更可靠可回放）、网关**粘性会话**（固定路由，扩缩容差）、STOMP Broker Relay。**广播要按 userId/roomId 过滤，别全量推。**

---

## L3 底层层：从 TCP 字节流到业务消息

### 3.1 一次文本帧的解析过程（Tomcat 侧）

```
TCP 字节流 → Tomcat NIO 读事件 → WsFrameServer/WsFrameBase.processInputBuffer()
  ├── 读 2 字节头：FIN/opcode、MASK/payloadLen
  ├── payloadLen==126 → 再读 2 字节；==127 → 再读 8 字节
  ├── MASK=1 → 再读 4 字节 masking key，读 payload 并按 mask 解码
  ├── opcode：0x1/0x2 且 FIN=1 → 直接回调 onMessage；分片 → 缓冲到 FIN=1 再回调
  │           0x9 ping → 自动回 0xA pong；0xA pong → 标记存活；0x8 close → 回 close 并关闭
  └── 业务 onMessage(完整消息)
```

### 3.2 握手在服务端是谁处理的

- Tomcat 的 `UpgradeProtocol`：`Http11Processor` 检测 `Upgrade: websocket` 后交给 `WsHttpUpgradeHandler`，完成 101 后把 socket 移交给帧处理器；Spring 的 `HandshakeInterceptor.beforeHandshake` 在升级前执行鉴权——**这是放 token 鉴权的最佳位置**。

### 3.3 Nginx / 网关配置（不配必挂）

```nginx
location /ws/ {
    proxy_pass http://app_backend;
    proxy_http_version 1.1;                  # 重点：必须 1.1 才支持 Upgrade
    proxy_set_header Upgrade $http_upgrade;  # 重点：透传 Upgrade
    proxy_set_header Connection "upgrade";   # 重点：明确要求升级
    proxy_read_timeout 3600s;                # 重点：默认 60s 空闲断连
}
```

漏配症状：**握手返回 200/400 而不是 101**、**连接每 60s 断一次**、**大消息卡住**。

---

## L4 追问树（面试官一路往下问，你能撑到第几层？）

> 规则：第 1-3 层必备，4-6 层拉开差距，7 层以后是加分。

### 第 1 层｜WebSocket 是什么？和 HTTP 什么关系？
**答**：它借一次 HTTP 请求完成握手（101 切换协议），之后在同一 TCP 连接上跑自己的帧协议，实现全双工。**握手是 HTTP 的，通信不是**；所以兼容 80/443、能过大部分防火墙，但不再受 HTTP 请求-响应模型约束。

### 第 2 层｜握手过程怎么走？`Sec-WebSocket-Accept` 怎么算？
**答**：客户端 GET，带 `Upgrade: websocket`、`Connection: Upgrade`、`Sec-WebSocket-Version: 13`、`Sec-WebSocket-Key`（16 字节随机 base64）。服务端校验后返回 `101` + `Sec-WebSocket-Accept = base64(SHA1(key + GUID))`。之后连接进入帧模式，HTTP 解析器退出。

### 第 3 层｜这个 Key/Accept 是鉴权吗？防什么？
**答**：不是鉴权也不是加密（GUID 公开）。它证明**对端真的实现了 WebSocket**，并让握手流量不像"普普通通可被缓存的 HTTP 响应"，防中间代理误处理。真正的安全靠 `wss://`、`Origin` 校验、握手时带 token 鉴权。

### 第 4 层｜帧格式长什么样？
**答**：首 2 字节：FIN(1) + RSV(3) + opcode(4)，然后 MASK(1) + payload len(7)；长度 126 → 后接 2 字节真长度，127 → 后接 8 字节；MASK=1 还有 4 字节掩码；最后 payload。opcode：0x0 延续、0x1 文本、0x2 二进制、0x8 close、0x9 ping、0xA pong。控制帧 ≤125 字节且不能分片。

### 第 5 层｜为什么客户端必须掩码，服务端不能掩码？
**答**：防代理缓存投毒——攻击者构造 payload 污染中间代理缓存；客户端掩码后载荷不再是可预测明文。服务端方向不存在该威胁，掩码只费 CPU。掩码不是加密（`payload[i] ^= mask[i%4]`，密钥就在帧里），服务端收到未掩码的客户端帧必须用 1002 关闭。

### 第 6 层｜分片机制？WebSocket 还有"粘包"问题吗？
**答**：一条消息可拆成首帧（opcode 文本/二进制 + FIN=0）+ 延续帧（opcode=0x0）+ 末帧（FIN=1），接收端按 FIN 重组。**所以应用层没有 TCP 粘包问题**，帧边界由协议保证；但帧里的流式数据（音频 PCM、自定义二进制）仍需业务按长度/时间片切分。控制帧可插在分片中间，心跳不会被大消息堵住。

### 第 7 层｜心跳怎么做？为什么要业务心跳？
**答**：协议级是服务端发 ping（0x9）、对端回 pong（0xA）；JS 无法主动发 ping 也无法感知 ping，且部分代理只对"有数据"的连接保活，所以要加业务心跳（客户端定时发 `{"type":"ping"}`、服务端回 pong），既保活又统计 RTT。间隔要小于 Nginx `proxy_read_timeout`（默认 60s），一般 20-30s。

### 第 8 层｜Nginx 反代 WebSocket 要配什么？
**答**：`proxy_http_version 1.1`（HTTP/1.0 不支持 Upgrade）、`proxy_set_header Upgrade $http_upgrade`、`proxy_set_header Connection "upgrade"`、`proxy_read_timeout` 调大（默认 60s 断空闲连接）、必要时 `proxy_buffering off`。漏配表现为握手失败（200/400）或周期性断连。

### 第 9 层｜集群下怎么给"另一个节点上的用户"发消息？
**答**：`WebSocketSession` 在单机内存里，不能跨节点直接调。用 Redis pub/sub 或 MQ 广播：各节点订阅频道，收到后只推本地 session（按 userId/roomId 过滤）；更复杂的用网关粘性路由或 STOMP Broker Relay。**别在业务代码里全量广播，节点多了会放大 N 倍流量。**

### 第 10 层（终局）｜一个音频二进制帧从浏览器到服务端，字节层发生了什么？
**答**：浏览器 `ws.send(arrayBuffer)` → WebSocket 实现构造帧：`FIN=1, opcode=0x2, MASK=1`，payload len 按大小写 7 位或 126/127 扩展，生成 4 字节随机掩码并 `payload[i]^=mask[i%4]` → TCP 发出 → Nginx（需 Upgrade 配置）按字节流转发 → Tomcat NIO 读缓冲 → `WsFrameBase` 解析首字节得 FIN/opcode、第二字节得 MASK/长度、按需读扩展长度与 masking key、解掩码 → 组装完整二进制消息 → `BinaryWebSocketHandler.handleBinaryMessage` → 业务把 PCM 帧按序推给 SenseVoice ASR，返回的 partial/final 文本再 `session.sendMessage(new TextMessage(...))`。**整条链路没有任何 HTTP 头/包体，只有 TCP 上的帧。**

---

## L5 名词拆解表（每个名词都拆开）

| 名词 | 是什么 | 为什么存在 | 面试追问点 |
|---|---|---|---|
| Upgrade / 101 | HTTP 协议切换机制 | 复用 80/443、穿过防火墙 | 为什么必须 HTTP/1.1 |
| `Sec-WebSocket-Key` | 16 字节随机 base64 | 握手防伪 | 与 Accept 的算法 |
| `Sec-WebSocket-Accept` | SHA1(key+GUID) 的 base64 | 证明对端真懂 WS | GUID 固定值的作用 |
| FIN | 帧头 1 bit，末帧标记 | 支持分片 | 分片重组时机 |
| opcode | 帧类型（文本/二进制/控制） | 区分数据与控制 | 0x0/0x1/0x2/0x8/0x9/0xA |
| MASK + Masking-key | 客户端掩码位与 4 字节密钥 | 防代理缓存投毒 | 服务端为何不掩码、1002 关闭 |
| 控制帧 | close/ping/pong | 保活与优雅关闭 | ≤125 字节、不可分片 |
| `WebSocketHandler` | Spring 原生处理器 | 自定义协议入口 | Text/Binary 基类 |
| STOMP | WS 上的消息语义协议 | 订阅/广播免自己管路由 | SimpleBroker vs Relay |
| `ConcurrentWebSocketSessionDecorator` | 线程安全发送装饰器 | 多线程 send 会冲突 | 单 session 串行发送 |

---

## 代码验证

```java
// 1) Spring 原生 WebSocket：多模态项目音频流上行 + ASR 文本下行
@Component
public class AsrWebSocketHandler extends BinaryWebSocketHandler {
    private final SenseVoiceClient asr;
    private final Map<String, ConcurrentWebSocketSessionDecorator> sessions = new ConcurrentHashMap<>();

    @Override
    public void afterConnectionEstablished(WebSocketSession s) {
        sessions.put(s.getId(), new ConcurrentWebSocketSessionDecorator(s, 5000, 64 * 1024));
    }

    @Override
    protected void handleBinaryMessage(WebSocketSession s, BinaryMessage msg) throws Exception {
        asr.feed(s.getId(), msg.getPayload());                  // 16kHz/16bit 单声道 PCM 分片
        for (String partial : asr.pollPartial(s.getId())) {
            sessions.get(s.getId()).sendMessage(
                    new TextMessage("{\"type\":\"partial\",\"text\":\"" + partial + "\"}"));
        }
    }

    @Override
    public void afterConnectionClosed(WebSocketSession s, CloseStatus status) {
        sessions.remove(s.getId());
        asr.close(s.getId());                                    // 清理 ASR 会话，防泄漏
    }
}
```

```java
// 2) 注册 handler + 握手鉴权 + 空闲超时（beforeHandshake 里校验 token）
@Configuration
@EnableWebSocket
public class WsConfig implements WebSocketConfigurer {
    public void registerWebSocketHandlers(WebSocketHandlerRegistry r) {
        r.addHandler(new AsrWebSocketHandler(), "/ws/asr")
         .addInterceptors(new AuthHandshakeInterceptor())      // 校验 token → attrs.put("userId", ...)
         .setAllowedOrigins("https://example.com");
    }
    // setMaxBinaryMessageBufferSize(256KB) / setMaxSessionIdleTimeout(120s) 在 ServletServerContainerFactoryBean 里配
}
```

```javascript
// 3) 前端 new WebSocket(wss://...?token=...)：binaryType='arraybuffer' 收音频帧，
//    onclose 里指数退避重连（≤30s），卸载/离开页面必须 close()，并用业务心跳保活
```

```bash
# 4) 手工握手验证：curl -i -N -H "Connection: Upgrade" -H "Upgrade: websocket" \
#    -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" <url>
# 期望：HTTP/1.1 101 Switching Protocols + Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
```

---

## 高频错误（面试官最爱抓的）

| 错误说法 | 正确说法 |
|---|---|
| 「WebSocket 就是 HTTP 长连接」 | 握手是 HTTP，之后切独立帧协议，不再有请求-响应语义 |
| 「WebSocket 会占 Tomcat 线程」 | NIO 事件驱动，空闲不占线程；大量连接主要吃内存与 fd |
| 「服务端发的帧也要掩码」 | 只有客户端→服务端需要掩码，服务端必须不掩码 |
| 「WebSocket 有粘包问题」 | 帧协议自带边界，应用层无粘包；流式二进制要自己切分 |
| 「浏览器可以主动发 ping 帧」 | JS 无该 API，只能靠业务心跳 |

---

## 关联文件

- 单向推送对照：[SSE](./05-SSE.md)；网络协议基础（HTTP/1.1、Upgrade、TCP）：[HTTP与浏览器](../../05-network/HTTP与浏览器.md)
- 项目落点：**多模态项目用 WebSocket 做 SenseVoice 流式 ASR**（上行 PCM 二进制帧、下行 partial/final 文本、TTS 音频帧），讲帧格式与心跳用 L2/L3 的图

> **自测标准**：能写出握手请求/响应三行头、手算 `Sec-WebSocket-Accept`、画出帧头比特位、解释掩码原因、说清 Nginx 配置与集群广播方案，算过关。
