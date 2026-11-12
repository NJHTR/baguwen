# SSE（Server-Sent Events 服务端推送）

> 面试权重：4/5　｜　追问深度：**L5（text/event-stream 规范 / chunked 传输 / 浏览器连接数限制）**
> 一句话定位：SSE 是**跑在原生 HTTP 上的单向服务端推送**——响应头 `Content-Type: text/event-stream`，响应体永不结束，服务端按文本行格式持续往下写，浏览器用 `EventSource` 接收，**断线自动重连并携带 `Last-Event-ID`**。比 WebSocket 简单得多，代价是"只能服务端→客户端"。

**本文件用法**：先背协议格式（6 行就能说清），再往下挖 Nginx/连接数/Spring 线程模型。你的 报告平台项目就在这里，面试一定会问"为什么不用 WebSocket"。
[返回深度追问索引](../00-索引.md)

---

## L1 一句话答案（10 秒能说出口）

SSE 就是**一个 `Content-Type: text/event-stream` 的、永不结束的 HTTP 响应**。服务端持续往响应体写 `data: xxx\n\n` 这样的文本块，浏览器 `EventSource` 收到 `onmessage`；每个事件可带 `id:`，断线重连时浏览器自动带请求头 `Last-Event-ID`，服务端就能从断点续推。单向、纯文本、自动重连、走标准 HTTP（不需要 Upgrade），适合"任务进度、通知、日志流"；需要双向就上 WebSocket。

---

## L2 原理层：协议格式与交互模型

### 2.1 一个最小可用的 SSE 响应

```http
HTTP/1.1 200 OK
Content-Type: text/event-stream; charset=utf-8
Cache-Control: no-cache
Connection: keep-alive
X-Accel-Buffering: no          # 让 Nginx 别缓冲

retry: 3000                    # 断线后 3s 再重连（毫秒）

id: 1
event: progress
data: {"taskId":"t1","percent":10}

id: 3
event: done
data: {"taskId":"t1","result":"ok"}
```

**每行一个字段，冒号后可选一个空格，事件之间用空行（`\n\n`）分隔。**

### 2.2 四个字段（全背）

| 字段 | 含义 | 细节 |
|---|---|---|
| `data:` | 消息正文 | 可多行，多行会被拼接成 `\n`；**只有带 data 的行才触发事件**（纯注释行可做心跳） |
| `event:` | 事件类型 | `addEventListener('progress', fn)`；默认类型是 `message` |
| `id:` | 事件 ID | 浏览器记住最后一个 id，重连时作为 `Last-Event-ID` 发送 |
| `retry:` | 重连间隔（毫秒） | 不写则用浏览器默认（约 3s） |

其他规则：以 `:` 开头是注释（如 `:heartbeat`），客户端忽略；必须 UTF-8、不能有 BOM、**不能二进制**（要 base64 塞进 data）；响应用 **chunked** 且**必须及时 flush**。

### 2.3 断线重连与 `Last-Event-ID`（SSE 最值钱的特性）

```
① 浏览器 EventSource 连上 → 服务端持续推 id: 1,2,3...
② 网络抖动/服务端重启/代理超时 → 连接断
③ 浏览器自动重连，请求头带 Last-Event-ID: 3
④ 服务端从 id=3 之后重放（内存环形 buffer / Redis Stream / DB 查变更）
⑤ 若 id 已过期，推一个"全量快照"事件让客户端重建状态
```

自动重连是浏览器给的，**不用手写**（比 WebSocket 省事）；但**断线期间的事件不会自动补**，要靠业务按 id 重放或推快照。

### 2.4 Nginx 部署（SSE 最容易翻车的地方）

```nginx
location /api/tasks/ {
    proxy_pass http://app_backend;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_buffering off;              # 重点：不缓冲，否则事件攒在 Nginx 一起发
    proxy_cache off;
    gzip off;                         # SSE 不能压缩（破坏 flush 时机）
    proxy_read_timeout 3600s;         # 重点：大于心跳间隔，否则空闲即断
    chunked_transfer_encoding on;
}
```

不配 `proxy_buffering off`：后端一条条推，浏览器却"一坨一坨"出现或不出现；不配超时：**每 60s 断一次**（Nginx 默认 60s）。ELB/ALB/K8s Ingress 同样有 idle timeout，要同步调大或用心跳焐热。

### 2.5 浏览器并发连接数限制

**HTTP/1.1 下同域最多约 6 个并发连接**，SSE 占一个，**每个标签页独立计算**——多开页面/多条通道会耗尽，其他接口请求排队。解法：① 升级 **HTTP/2**（多路复用，6 连接限制基本消失）；② 同域共享一个 EventSource（SharedWorker/BroadcastChannel）；③ 拆独立子域；④ **只保留一条总事件流，用 `event:` 类型分流**（推荐，报告平台 就该这么干）。

### 2.6 SSE vs WebSocket 选型

| 维度 | SSE | WebSocket |
|---|---|---|
| 方向 | **单向**（服务端→客户端） | **双向** |
| 协议 | 普通 HTTP 响应（无 Upgrade） | HTTP Upgrade 后切 `ws://` 帧协议 |
| 自动重连 | 内置 + `Last-Event-ID` 续传 | 自己实现（退避 + 心跳） |
| 数据 | 仅 UTF-8 文本，二进制要 base64 | 文本 + 二进制帧 |
| 代理/防火墙 | 兼容性极好（就是 HTTP） | 需支持 Upgrade |
| 连接数限制 | 占 HTTP/1.1 同域 6 连接之一 | 升级后独立连接，不占该限制 |
| 典型场景 | 任务进度、通知、日志、AI 打字机 | 聊天、协同编辑、音视频信令、语音 ASR |

**一句话选型**：只推不收 → SSE；要双向或二进制 → WebSocket。**报告平台 任务进度用 SSE**（省重连/心跳复杂度），**数字人 ASR 用 WebSocket**（音频二进制 + 双向控制）。

---

## L3 底层层：HTTP 传输与 Spring 线程模型

### 3.1 SSE 在 TCP 上的样子

- 响应无 `Content-Length`，用 **`Transfer-Encoding: chunked`**：每 chunk 是 `长度\r\n数据\r\n`，服务端每 flush 一次发一个 chunk。
- 请求是普通 GET（`Accept: text/event-stream`），**没有 Upgrade**，所以任何 HTTP 代理都能过（只要不缓冲）。
- 连接结束由 FIN / 终止块 `0\r\n\r\n` / 代理超时决定；本质是"HTTP 流式响应 + 约定的文本格式"。

### 3.2 Spring MVC 的 `SseEmitter` 线程模型

控制器返回 `SseEmitter` 后容器转 **async 模式**，**不会一直占 Tomcat 工作线程**；之后的 `emitter.send()` 由业务/调度线程通过 `AsyncContext` 写回。每个 emitter 对应一个 HTTP 连接（连接数 = 并发用户数），必须限制最大连接 + 超时清理；超时用 `SseEmitter(timeout)`（`-1` 别真不设，死连接会永久占资源）。**三处清理**：`onCompletion`/`onTimeout`/`onError`（客户端断开抛 `IOException: Broken pipe`）都要从注册表移除并 `complete()`。

### 3.3 WebFlux 的 `Flux<ServerSentEvent>`

控制器返回 `Flux<ServerSentEvent<TaskProgress>>`（`produces = text/event-stream`），`ServerSentEvent.builder().id(...).event(...).data(...)` 逐条构造；非阻塞、背压内建、连接多了也不吃线程，客户端断开时 Flux 自动 cancel（`doFinally` 清理）。**MVC 的 `SseEmitter` 是命令式、WebFlux 是流式，不能混用。**

---

## L4 追问树（面试官一路往下问，你能撑到第几层？）

> 规则：第 1-3 层必备，4-6 层拉开差距，7 层以后是加分。

### 第 1 层｜SSE 是什么？和轮询、长轮询有什么区别？
**答**：SSE 是一条**永不结束的 HTTP 响应**，服务端持续写文本事件。轮询是客户端定时问（延迟高、空请求多）；长轮询是服务端 hold 到有数据才返回（省空轮询但每次重连）；SSE 一条连接常驻、服务端主动 push、浏览器自动重连，实时性与连接效率更好。

### 第 2 层｜SSE 协议格式具体是什么？
**答**：响应头 `Content-Type: text/event-stream; charset=utf-8`、`Cache-Control: no-cache`。响应体是若干"字段行 + 空行"的事件块：`data:` 内容（可多行）、`event:` 类型、`id:` 事件 ID、`retry:` 重连毫秒；`:` 开头是注释（心跳）；**空行表示事件结束**。只有含 `data:` 的行才触发客户端事件。

### 第 3 层｜断线重连怎么实现？`Last-Event-ID` 有什么用？
**答**：浏览器 `EventSource` 检测到断开后**自动重连**（间隔由 `retry:` 指定，默认约 3s），重连时把最后收到的事件 `id` 放进请求头 `Last-Event-ID`。服务端据此把之后的事件重放（内存环形缓冲/Redis Stream/DB 增量查），避免断线丢事件。**这是 SSE 相比 WebSocket 最大的工程优势——重连与续传协议是现成的。**

### 第 4 层｜为什么响应头要 `Cache-Control: no-cache`？还有哪些头要注意？
**答**：防止浏览器/中间缓存把流式响应缓存起来。此外要 `Connection: keep-alive`、`X-Accel-Buffering: no`（让 Nginx 不缓冲）、`charset=utf-8`；**不能设 `Content-Length`**（要 chunked）；**不能开 gzip**（压缩会攒数据破坏实时性）。

### 第 5 层｜Nginx 上部署 SSE 要改什么？不改会出现什么现象？
**答**：`proxy_buffering off`（关键，否则"一坨一坨"或不推送）、`proxy_cache off`、`gzip off`、`proxy_http_version 1.1` + `proxy_set_header Connection ""`、`proxy_read_timeout` 调大于心跳间隔（否则默认 60s 就断）。现象：攒批 → 推不动/大延迟；超时 → 每 60s 重连，进度闪烁/重复。

### 第 6 层｜浏览器对 SSE 有什么限制？HTTP/1.1 同域 6 连接怎么影响它？
**答**：SSE 走普通 HTTP 连接，HTTP/1.1 同域最多约 6 个并发，**SSE 占一个且每个标签页独立计算**，多开页面就可能占满，导致其他请求排队、后续 SSE 建不起来。解法：HTTP/2、单页只开一条 EventSource 用 `event:` 分流、SharedWorker 共享、独立子域。

### 第 7 层｜SSE 和 WebSocket 怎么选？
**答**：看"要不要双向、要不要二进制、要不要极简"。单向推送（进度、通知、日志、AI 流式输出）用 SSE：纯 HTTP、代理友好、自动重连、代码少；双向或二进制（聊天、协同编辑、语音 ASR 音频流、WebRTC 信令）用 WebSocket。**选型要能说清代价，而不是背表格。**

### 第 8 层｜Spring 里怎么实现 SSE？`SseEmitter` 和 `Flux<ServerSentEvent>` 区别？
**答**：MVC 用 `SseEmitter`：请求转 async，业务线程 `send`，容器异步写回，**不长期占工作线程**；WebFlux 返回 `Flux<ServerSentEvent>`，声明式、非阻塞、天然背压。前者命令式要自己管超时/清理，后者响应式、连接多时更省资源。两者都要求 `produces=text/event-stream`。

### 第 9 层｜`SseEmitter` 连接泄漏怎么排查？
**答**：症状是连接数只涨不降、内存注册表越来越大、网关连接打满。三处必须清理：`onCompletion`/`onTimeout`/`onError` 里移除并 `complete()`；`send()` 抛 `IOException`（`Broken pipe`）时立即移除；设合理 timeout + 定时清理"无心跳"的 emitter。加心跳（`:ping\n\n`）让死连接尽快暴露。

### 第 10 层（终局）｜从 HTTP 协议层看，SSE 响应体是怎么"持续"的？为什么必须 flush？
**答**：响应用 `Transfer-Encoding: chunked`、无 `Content-Length`，服务端每写一个事件就 flush 一次 → 内核把缓冲区封成 chunk（`<hex 长度>\r\n<data>\r\n`）经 TCP 发出；客户端 `EventSource` 解析字节流，遇空行切事件。不 flush（或中间代理开 buffering）数据就停在内核/Nginx 缓冲区，表现为"没消息"。连接结束由 FIN/chunked 终止块或代理超时决定；Spring 的 `send()` 最终走 `AsyncContext` 响应输出流并 flush，Tomcat 用 NIO 事件循环交给 socket。**所以 SSE 三个必答题：chunked 无 Content-Length、必须 flush、代理必须关 buffering。**

---

## L5 名词拆解表（每个名词都拆开）

| 名词 | 是什么 | 为什么存在 | 面试追问点 |
|---|---|---|---|
| `text/event-stream` | SSE 的 MIME 类型 | 标识"事件流，浏览器按格式解析" | 缺了它浏览器只当普通文本 |
| `data:` | 事件正文行 | 承载业务数据 | 多行 data 如何拼接、二进制怎么传 |
| `event:` | 事件类型 | 客户端按类型分发 | 默认类型是 `message` |
| `id:` | 事件 ID | 断线续传的游标 | 重连时变成 `Last-Event-ID` |
| 空行 | 事件分隔符 | 告诉解析器"事件完了" | 忘了空行 → 客户端收不到 |
| `EventSource` | 浏览器 SSE 客户端 API | 自动解析 + 自动重连 | 为什么不能自定义请求头 |
| `Last-Event-ID` | 重连请求头 | 让服务端知道从哪续推 | 服务端如何重放/快照 |
| `Cache-Control: no-cache` | 禁止缓存响应 | 流式响应不能被缓存 | 漏配导致"卡住/旧数据" |
| `X-Accel-Buffering: no` | 给 Nginx 的免缓冲提示 | 防止代理攒批 | 还要配合 `proxy_buffering off` |
| `proxy_read_timeout` | 代理等待上游数据的超时 | 防僵死连接 | 小于心跳间隔就周期性断连 |
| `SseEmitter` / `Flux<ServerSentEvent>` | Spring MVC / WebFlux 的 SSE 返回类型 | 命令式 / 响应式推送 | 线程模型、超时、三处清理 |
| 心跳 | 周期性注释/空事件 | 保活 + 探测死连接 | 间隔怎么定（< 代理超时） |

---

## 代码验证

```java
// 1) Spring MVC + SseEmitter：报告平台 任务进度推送（注册表 + 三处清理）
@RestController
@RequestMapping("/api/tasks")
public class TaskProgressController {
    private final Map<String, List<SseEmitter>> emitters = new ConcurrentHashMap<>();

    @GetMapping(value = "/{taskId}/events", produces = MediaType.TEXT_EVENT_STREAM_VALUE)
    public SseEmitter events(@PathVariable String taskId) {
        SseEmitter e = new SseEmitter(30 * 60 * 1000L);          // 30 分钟超时，别用 -1
        emitters.computeIfAbsent(taskId, k -> new CopyOnWriteArrayList<>()).add(e);
        e.onCompletion(() -> remove(taskId, e));                 // 重点：正常结束
        e.onTimeout(() -> { remove(taskId, e); e.complete(); }); // 重点：超时
        e.onError(err -> remove(taskId, e));                     // 重点：客户端断开
        try {
            e.send(SseEmitter.event().id("0").name("connected")
                    .data(Map.of("taskId", taskId)).reconnectTime(3000));
        } catch (IOException ex) { remove(taskId, e); }
        return e;
    }

    // 任务执行中按 seq 推进度；结束时发 done 并 complete
    public void progress(String taskId, long seq, int percent) {
        for (SseEmitter e : emitters.getOrDefault(taskId, List.of())) {
            try {
                e.send(SseEmitter.event().id(String.valueOf(seq)).name("progress")
                        .data(Map.of("percent", percent, "seq", seq)));
                if (percent >= 100) { e.send(SseEmitter.event().name("done").data(Map.of("ok", true))); e.complete(); }
            } catch (IOException | IllegalStateException ex) { remove(taskId, e); }
        }
        if (percent >= 100) emitters.remove(taskId);
    }

    private void remove(String taskId, SseEmitter e) {
        var list = emitters.get(taskId);
        if (list != null) list.remove(e);
    }
}

// 2) 心跳：间隔小于代理超时，发注释行保活并探测死连接
@Scheduled(fixedDelay = 15_000)
public void heartbeat() {
    emitters.forEach((taskId, list) -> list.forEach(e -> {
        try { e.send(SseEmitter.event().comment("ping")); }      // 输出 ": ping\n\n"
        catch (IOException ex) { list.remove(e); }
    }));
}
```

```javascript
// 3) 前端：不要重复 new EventSource，卸载必须 close
const es = new EventSource(`/api/tasks/${taskId}/events`);
es.addEventListener('progress', e => render(JSON.parse(e.data)));
es.addEventListener('done', () => es.close());
es.onerror = () => { if (es.readyState === EventSource.CLOSED) { /* 手动重建或提示 */ } };
window.addEventListener('beforeunload', () => es.close());
```

```bash
# 4) 命令行验证（应一条条到达而不是攒到最后）
curl -N -H "Accept: text/event-stream" http://localhost:8080/api/tasks/t1/events
```

---

## 高频错误（面试官最爱抓的）

| 错误说法 | 正确说法 |
|---|---|
| 「SSE 和 WebSocket 都是长连接，选哪个都行」 | SSE 单向文本、走 HTTP、自动重连；WebSocket 双向二进制、需 Upgrade |
| 「SSE 会一直占用 Tomcat 线程」 | 转 async 模式，不占工作线程；但每个连接占一个 socket |
| 「响应头不需要特别设置」 | 必须 `text/event-stream` + `no-cache`，且不能有 `Content-Length` |
| 「Nginx 直接反代就行」 | 必须 `proxy_buffering off`、关 gzip、调大 `proxy_read_timeout` |
| 「每次 onerror 都 new 一个 EventSource」 | 会重复连接泄漏；只在 CLOSED 时重建，卸载时必须 `close()` |

---

## 关联文件

- 双向推送对照：[WebSocket](./06-WebSocket.md)
- 网络协议基础（HTTP/1.1、chunked、keep-alive）：[HTTP与浏览器](../../05-network/HTTP与浏览器.md)
- 异步任务如何产生进度事件：[异步与削峰](../backend-opt/02-异步与削峰.md)
- 项目落点：**报告平台的任务进度推送就用 SSE**（`POST /api/tasks` 返回 taskId → `GET /api/tasks/{id}/events` 订阅），"为什么不用 WebSocket"用 2.6 的表

> **自测标准**：能默写 SSE 响应头与事件格式、说清断线重连流程（`Last-Event-ID` → 重放/快照）、说出 Nginx 三项配置、解释 6 连接限制、对比 WebSocket 做选型，算过关。
