# HTTP 与浏览器

> 面试权重：5/5（必考）　|　建议投入：3 天
> 适用场景：前端一面网络基础轮、二面项目追问（缓存/跨域/登录态）、全栈岗位部署与安全题

**怎么用**：网络题的特点是「听起来都会，深问就断片」。先背 60 秒版建立主线，再用原理展开补细节；第 6 节「输入 URL 到渲染」要能一条线讲完，这是区分度最高的一题。

相关文档：[JS 核心八股](../01-js/JS核心八股.md) ｜ [Vue3 原理与对比](../02-vue/Vue3原理与对比.md) ｜ [SpringBoot 与后端工程](../03-java/SpringBoot与后端工程.md) ｜ [MySQL 与 Redis](../04-database/MySQL与Redis.md)

## 1. HTTP 报文与常见状态码

**一句话答案**：HTTP 是应用层的请求-响应协议，请求报文由请求行、请求头、空行、请求体组成，响应报文由状态行、响应头、空行、响应体组成；状态码首位表示类别，1xx 信息、2xx 成功、3xx 重定向、4xx 客户端错误、5xx 服务端错误。

**原理展开**：
- 请求行：`GET /api/users?page=1 HTTP/1.1`；`Host` 必带，`Content-Type/Content-Length/Accept/Authorization/Cookie` 决定服务端怎么解析。
- 响应行：`HTTP/1.1 200 OK`；`Cache-Control/ETag/Set-Cookie` 控制缓存与登录态。
- 高频码：`200` 成功、`201` 创建、`204` 无内容；`301/308` 永久重定向、`302/307` 临时重定向、`304` 协商缓存命中；`400` 参数错、`401` 未认证、`403` 无权限、`404` 不存在、`405` 方法不允许、`429` 限流；`500` 服务端异常、`502` 网关上游错误、`503` 服务不可用、`504` 网关超时。
- 方法与幂等：`GET/HEAD` 安全，`GET/HEAD/PUT/DELETE` 幂等，`POST` 不幂等；幂等决定了失败重试是否安全。
- `401` 与 `403` 的区别：前者是「你是谁不知道」，后者是「知道你是谁但不让做」。

```http
GET /api/users?page=1 HTTP/1.1
Host: example.com
Accept: application/json
Cookie: sessionId=abc123

HTTP/1.1 200 OK
Content-Type: application/json
Cache-Control: max-age=60

{"code":0,"data":[]}
```

**面试怎么答（60 秒版）**：
HTTP 是请求-响应模型，报文分请求行、头部、空行、body 四部分。状态码按首位分类，2xx 成功，3xx 重定向和缓存，4xx 客户端问题，5xx 服务端问题。项目里最常打交道的是 200、304、401、403、502 和 504：304 是协商缓存命中，401 是没登录或者 token 过期，403 是登录了但没权限，502 一般是网关后面的服务挂了，504 是网关等待上游超时。另外要注意方法幂等，GET/PUT/DELETE 幂等可以安全重试，POST 不幂等，重试要做防重。

**追问陷阱**：
- 错误：「401 和 403 差不多」 → 正确：401 缺认证信息，403 认证通过但无权限；401 通常配合 `WWW-Authenticate`。
- 错误：「301 和 302 只是数字不同」 → 正确：301 永久且可被缓存，302/307 临时；307/308 保留原方法和 body。
- 错误：「状态码只是给前端看的」 → 正确：网关、监控、SEO、CDN 缓存都依赖它，用错会影响排查。

## 2. HTTP/1.1、HTTP/2 与 HTTP/3

**一句话答案**：HTTP/1.1 是文本协议，靠 `keep-alive` 复用 TCP 但同域并发受限且存在队头阻塞；HTTP/2 用二进制分帧和多路复用解决应用层队头阻塞并压缩头部；HTTP/3 基于 UDP 的 QUIC，解决 TCP 层队头阻塞，支持 0-RTT 和连接迁移。

**原理展开**：
- HTTP/1.1：`Connection: keep-alive` 复用连接，浏览器同域并发约 6 个；管线化理论上可并发但存在队头阻塞，实际未普及。
- HTTP/2：二进制帧 + stream id，一个 TCP 连接并发多个请求；HPACK 压缩请求头；服务端推送已被主流浏览器放弃；仍有 TCP 层队头阻塞——丢一个包，所有流一起等重传。
- HTTP/3：QUIC 跑在 UDP 上，TLS 1.3 内建，每个流独立重传，丢包不影响其他流；支持 0-RTT 恢复和连接迁移（4G 切 WiFi 不断）；部署受 UDP 放行和中间设备影响。
- 浏览器的 HTTP/2 基本强制 HTTPS；HTTP/3 需要 Alt-Svc 或 DNS HTTPS 记录发现。
- 面试落点：说清「1.1 文本 + 并发限制」「2 多路复用但 TCP 阻塞」「3 QUIC 解决 TCP 阻塞」三层即可。

**面试怎么答（60 秒版）**：
HTTP/1.1 是文本协议，一个连接一个请求，虽然 keep-alive 能复用连接，但同域并发只有 6 个左右，还有队头阻塞。HTTP/2 改成二进制分帧，用 stream id 在一条 TCP 连接上多路复用，头部用 HPACK 压缩，还支持服务端推送，应用层的队头阻塞解决了。但 HTTP/2 底层还是 TCP，只要丢一个包，所有流都要等重传，所以 HTTP/3 换成基于 UDP 的 QUIC，每个流独立重传，还支持 0-RTT 和连接迁移。实际部署里 HTTP/2 已经很普遍，HTTP/3 在 CDN 上逐步开启。

**追问陷阱**：
- 错误：「HTTP/2 彻底解决了队头阻塞」 → 正确：只解决应用层，TCP 层丢包阻塞仍然存在，HTTP/3 才解决。
- 错误：「HTTP/3 是跑在 TCP 上的」 → 正确：跑在 UDP + QUIC 上，所以能自定义重传和拥塞控制。
- 错误：「HTTP/2 服务端推送很有用」 → 正确：浏览器已移除支持，别当卖点答。
- 错误：「HTTP/1.1 没有多路复用」 → 正确：有 keep-alive 连接复用，但没有真正并行的请求流。

## 3. 强缓存与协商缓存

**一句话答案**：强缓存由 `Cache-Control` 的 `max-age` 决定，命中后不发请求直接用本地副本；协商缓存靠 `ETag/If-None-Match` 或 `Last-Modified/If-Modified-Since` 向服务端确认，未变化返回 `304`，浏览器继续用缓存。

**原理展开**：
- 强缓存优先级：`Cache-Control` 高于 `Expires`（`Expires` 是绝对时间，依赖客户端时钟，已过时）。
- `no-cache` 不是不缓存，而是每次使用前必须协商；`no-store` 才是完全禁止存储；`immutable` 表示有效期内连刷新都不重新验证。
- 协商缓存：浏览器带 `If-None-Match: "etag值"` 或 `If-Modified-Since`，服务端比较后返回 `304 Not Modified`（无 body，省带宽）。
- `ETag` 精度比 `Last-Modified` 高（内容哈希 vs 秒级时间），优先级也更高。
- Vue/Vite 部署策略：`index.html` 设 `no-cache`，`/assets/*.[hash].js` 设 `max-age=31536000, immutable`；内容变则哈希变，URL 变自然绕过缓存。

```nginx
location /assets/ {
  add_header Cache-Control "public, max-age=31536000, immutable";
}
location = /index.html {
  add_header Cache-Control "no-cache";
}
```

**面试怎么答（60 秒版）**：
缓存分强缓存和协商缓存。强缓存看 Cache-Control 的 max-age，命中就直接用本地缓存，连请求都不发。协商缓存是过期之后带 If-None-Match 去问服务端，服务端比较 ETag，没变就返回 304，浏览器继续用本地副本，省的是响应体带宽。ETag 比 Last-Modified 更准，优先级也更高。项目里 index.html 必须 no-cache，打包后的静态资源带 hash 可以设一年 immutable，发版时 hash 变了就是新 URL，用户自然会拉到新文件。

**追问陷阱**：
- 错误：「`no-cache` 是不缓存」 → 正确：是缓存但每次使用前必须协商；`no-store` 才完全不存。
- 错误：「强缓存过期就会重新下载」 → 正确：过期后走协商缓存，304 就不重新下载。
- 错误：「`index.html` 也要长期缓存提速」 → 正确：会导致发版后拿着旧 HTML 引用旧资源，必须 no-cache。
- 错误：「ETag 和 Last-Modified 等价」 → 正确：ETag 内容级精确，Last-Modified 只有秒级且文件时间不可靠。

## 4. 跨域与 CORS

**一句话答案**：同源策略要求协议、域名、端口完全一致，浏览器默认拦截跨源读取响应；CORS 是服务端通过 `Access-Control-Allow-*` 响应头授权、浏览器据此放行的机制，非简单请求会先发 OPTIONS 预检。

**原理展开**：
- 简单请求条件：方法为 `GET/HEAD/POST`，且请求头只有安全头部，`Content-Type` 限 `application/x-www-form-urlencoded`、`multipart/form-data`、`text/plain`。
- 不满足就发预检 `OPTIONS`，带 `Access-Control-Request-Method/Headers`；服务端回 `Access-Control-Allow-Origin/Methods/Headers/Max-Age`，预检结果会被缓存。
- 带 Cookie 时需要前端 `credentials: 'include'`，服务端 `Access-Control-Allow-Credentials: true`，且 `Allow-Origin` 不能是 `*`，必须回显具体源。
- 跨域是浏览器拦截，简单请求可能已经到达服务端并产生副作用，所以「跨域了但数据写进去了」是正常的。
- 开发环境能跑是因为 Vite/webpack dev server 配了 proxy：浏览器请求同源的 dev server，dev server 再转发给后端，跨域发生在服务端之间，不受同源策略约束。
- 其他方案：生产用同域部署/Nginx 反向代理、后端开 CORS、JSONP（只支持 GET，历史方案）、postMessage（iframe 通信）。

```ts
// vite.config.ts：开发代理
import { defineConfig } from 'vite'
export default defineConfig({
  server: {
    proxy: {
      '/api': { target: 'http://localhost:8080', changeOrigin: true },
    },
  },
})
```

```js
fetch('http://api.example.com/user', { credentials: 'include' })
```

**面试怎么答（60 秒版）**：
跨域是浏览器同源策略的限制，协议、域名、端口任一不同就算跨源，浏览器会拦截读取响应。解决靠 CORS，服务端返回 Access-Control-Allow-Origin 这些头，简单请求直接带过去，非简单请求先发 OPTIONS 预检。带 cookie 时 Allow-Origin 不能写星号，要回显具体域名，前端还要开 credentials。开发环境能跑是因为 dev server 配了 proxy，浏览器实际请求的是同源的开发服务器，由它转发到后端。生产环境要么同域部署或者 Nginx 反代，要么后端正确配置 CORS。

**追问陷阱**：
- 错误：「跨域是服务器拒绝了请求」 → 正确：是浏览器拦截；简单请求服务端可能已经处理了。
- 错误：「预检失败说明接口没发」 → 正确：预检失败时真实请求不会发；但简单请求是直接发的。
- 错误：「本地用 proxy 没跨域，生产也不会有」 → 正确：生产域名不同就跨域，要靠网关或后端 CORS。
- 错误：「`Access-Control-Allow-Origin: *` 万能」 → 正确：带凭证时不能用 `*`，多域名要按白名单回显。

## 5. Cookie、Session、Token 与 JWT

**一句话答案**：Cookie 是浏览器自动随请求发送的小段数据；Session 是服务端存会话、Cookie 里只放 sessionId；Token 是客户端保存、放请求头里的凭证；JWT 是自包含的 Token 格式，服务端验签即可，无需存储，但撤销困难。

**原理展开**：
- Cookie：单域约 4KB，属性有 `HttpOnly`（防 JS 读取）、`Secure`（仅 HTTPS）、`SameSite`（防 CSRF）、`Domain/Path/Max-Age`；每次同域请求自动携带。
- Session：状态存在服务端（内存/Redis），横向扩容需要共享存储；Cookie 泄露风险相对低。
- JWT 结构：`header.payload.signature`，前两段是 base64url 编码的明文 JSON，签名用 HS256（共享密钥）或 RS256（公私钥）；payload 只防篡改、不加密，不能放密码等敏感信息。
- 无状态优点：服务端不存会话、易水平扩展、跨端友好；缺点：无法立即失效、payload 变大会增加请求头体积。
- 登出方案：客户端删 token；服务端用 refresh token 撤销 + access token 短 TTL，必要时维护黑名单（Redis）或用户级 token 版本号。
- 安全存储取舍：`localStorage` 方便但有 XSS 风险；`HttpOnly + SameSite` Cookie 防 XSS 读取但要防 CSRF。

```js
const token = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig'
const payload = token.split('.')[1]
const json = JSON.parse(atob(payload)) // { sub: '1' }：payload 是明文，任何人都能解
console.log(json.sub)
```

**面试怎么答（60 秒版）**：
Cookie 是浏览器自动携带的小数据，Session 是把会话状态存在服务端，Cookie 只存 sessionId，好处是能主动踢人，坏处是分布式要共享存储。Token 是客户端保存、放 Authorization 头里的凭证，JWT 是其中一种格式，由 header、payload、signature 三段组成，前两段是明文，只签名不加密，所以不能放敏感信息。JWT 的好处是服务端无状态、好扩展，坏处是不能立即失效，所以一般 access token 设短一点，配 refresh token，登出时把 refresh token 作废，必要时用 Redis 黑名单兜底。

**追问陷阱**：
- 错误：「JWT 是加密的」 → 正确：默认只签名不加密，payload 可被任何人解码，JWE 才加密。
- 错误：「JWT 注销很容易」 → 正确：无状态无法即时废止，要用短 TTL + 黑名单/refresh token。
- 错误：「token 放 localStorage 最安全」 → 正确：有 XSS 窃取风险；HttpOnly Cookie 更防 XSS 但要配 SameSite 防 CSRF。
- 错误：「Cookie 和 Session 是两种并列技术」 → 正确：Session 通常依赖 Cookie 传 sessionId，也可以走 header。

## 6. 从输入 URL 到页面渲染

**一句话答案**：DNS 解析域名拿到 IP → TCP 三次握手（HTTP/3 走 QUIC）→ TLS 握手协商密钥 → 发送 HTTP 请求拿到响应 → 解析 HTML 构建 DOM、解析 CSS 构建 CSSOM → 合成渲染树 → 布局计算位置 → 绘制像素 → 分层合成上屏。

**原理展开**：
- DNS：浏览器缓存 → 系统缓存 → hosts → 本地 DNS 递归查询（根 → 顶级域 → 权威域）；可用 `dns-prefetch`/`preconnect` 提前建连。
- 连接：TCP 三次握手 SYN/SYN-ACK/ACK；TLS 1.2 约 2-RTT，TLS 1.3 约 1-RTT。
- 请求响应：HTML 是流式解析的，浏览器边下边解析；解析中预加载扫描器会提前发现资源。
- 阻塞关系：CSS 阻塞渲染（也阻塞其后 JS 执行），普通 `<script>` 阻塞 HTML 解析，`defer` 解析完按序执行，`async` 下载完立即执行。
- 渲染流水线：DOM + CSSOM → Render Tree（不含 `display:none`）→ Layout（几何位置）→ Paint（绘制指令）→ Composite（GPU 分层合成）。
- 事件时机：`DOMContentLoaded` 在 DOM 解析完、defer 脚本执行后触发；`load` 等所有图片等资源加载完成。
- 首屏优化落点：SSR/预渲染、关键 CSS 内联、资源压缩与拆包、CDN、图片懒加载与预连接。

```html
<link rel="preconnect" href="https://cdn.example.com" />
<link rel="stylesheet" href="/main.css" />
<script src="/app.js" defer></script>
<script src="/analytics.js" async></script>
```

**面试怎么答（60 秒版）**：
输入 URL 后先查 DNS，顺序是浏览器缓存、系统缓存、hosts，再到本地 DNS 递归查根和权威服务器拿到 IP。然后 TCP 三次握手，如果是 HTTPS 再走 TLS 握手协商出会话密钥。接着发 HTTP 请求，服务端返回 HTML，浏览器流式解析构建 DOM，同时解析 CSS 构建 CSSOM，两者合成渲染树，再做布局计算位置、绘制、分层合成上屏。这个过程中 CSS 会阻塞渲染，普通 script 会阻塞解析，所以脚本一般加 defer 或 async。DOM 解析完触发 DOMContentLoaded，所有资源加载完才触发 load。

**追问陷阱**：
- 错误：「`DOMContentLoaded` 要等图片加载完」 → 正确：不等，DOM 解析完就触发；等资源的是 `load`。
- 错误：「CSS 只影响样式不阻塞」 → 正确：CSS 阻塞渲染，也阻塞其后 JS 执行，避免闪屏。
- 错误：「渲染树包含所有 DOM 节点」 → 正确：`display:none`、`<head>` 等不参与渲染树。
- 错误：「DNS 解析只查一次」 → 正确：有各级缓存和 TTL，换网络/清缓存后要重新解析。

## 7. 重排、重绘与性能

**一句话答案**：改几何属性（宽高、位置、字体、增删节点）触发重排（layout），改外观（颜色、背景、阴影）触发重绘（paint），`transform/opacity` 只触发合成（composite），开销依次递减。

**原理展开**：
- 重排：尺寸、位置、边距、字体、显隐、DOM 增删都会让浏览器重新计算布局，影响范围可能扩散到兄弟/父节点。
- 重绘：颜色、背景、可见性、阴影变化只重画，不重新布局。
- 合成：`transform`、`opacity`、`filter` 在合成层处理，可交给 GPU，动画首选。
- 布局抖动：读写交替会强制同步布局，比如循环里读 `offsetWidth` 再写 `style.width`，每次都触发一次 layout。
- 优化手段：读写分离批量处理、`DocumentFragment` 离线批量插入、`transform` 代替 `top/left`、动画用 `requestAnimationFrame`、`will-change` 按需加并在结束后移除。
- 框架层面：虚拟 DOM 和批量更新减少真实 DOM 操作次数（原理见 [Vue3 原理与对比](../02-vue/Vue3原理与对比.md)，本文不展开）。

```js
// 错误：读写交替：每次循环都强制同步布局
items.forEach((el) => {
  el.style.width = el.offsetWidth + 10 + 'px'
})

// 正确：先读后写：只布局一次
const widths = items.map((el) => el.offsetWidth)
items.forEach((el, i) => {
  el.style.width = widths[i] + 10 + 'px'
})
```

**面试怎么答（60 秒版）**：
重排是布局变了，比如宽高位置或者增删 DOM，浏览器要重新计算几何信息，开销最大。重绘是只改颜色背景这类外观，不重新布局。transform 和 opacity 可以只走合成层，交给 GPU，所以动画优先用它们。最常见的性能坑是读写交替，循环里读 offsetWidth 再写样式，会强制同步布局，正确做法是先批量读、再批量写。另外大量 DOM 操作用 DocumentFragment 离线处理，动画用 requestAnimationFrame，will-change 不要滥用。

**追问陷阱**：
- 错误：「重绘比重排慢」 → 正确：通常重排更贵，因为影响布局范围；但大面积重绘也不轻。
- 错误：「`display:none` 隐藏元素能减少重排」 → 正确：切换 `display` 本身触发重排；做动画用 `transform/opacity`。
- 错误：「频繁读 `offsetWidth` 无所谓」 → 正确：每次读取都可能强制同步布局，是布局抖动的根源。
- 错误：「`will-change` 越多越流畅」 → 正确：会提前占用 GPU 内存，适当使用并在动画结束后移除。

## 8. 浏览器存储

**一句话答案**：Cookie 约 4KB 且自动随请求发送；`localStorage` 约 5MB、同源持久、同步 API；`sessionStorage` 同源同标签页、关闭标签页失效；IndexedDB 容量大、异步、支持事务和索引，适合大量结构化数据。

**原理展开**：
- 对比：Cookie 4KB、随请求发送、可设过期；localStorage 约 5MB、永久、同步、不随请求发送；sessionStorage 同源同标签页、关闭即失效；IndexedDB 容量按磁盘配额、异步事务。
- `localStorage` 只能存字符串，存对象要 `JSON.stringify`，读取要 `JSON.parse`；同步 API 会阻塞主线程，不要存大对象。
- IndexedDB 是异步事件/事务模型，适合缓存列表数据、离线数据、日志；常用封装 Dexie.js。
- Cache Storage 配合 Service Worker 缓存请求响应，是 PWA 离线能力的核心。
- 选型：登录态用 HttpOnly Cookie；用户偏好（主题、语言）用 localStorage；离线大数据用 IndexedDB/Cache Storage。

```js
localStorage.setItem('theme', 'dark')
console.log(localStorage.getItem('theme')) // dark

const request = indexedDB.open('notes-db', 1)
request.onupgradeneeded = () => {
  request.result.createObjectStore('notes', { keyPath: 'id' })
}
request.onsuccess = () => {
  const db = request.result
  const tx = db.transaction('notes', 'readwrite')
  tx.objectStore('notes').put({ id: 1, text: '面试笔记' })
}
```

**面试怎么答（60 秒版）**：
浏览器存储主要有四种。Cookie 只有 4KB，但会自动跟着请求发给服务端，所以主要用来传 sessionId 或 token。localStorage 大概 5MB，同源共享、永久保存，但是同步 API，存大对象会阻塞主线程。sessionStorage 和 localStorage 类似，但只在当前标签页有效，关掉就没了。IndexedDB 容量大、异步、支持事务和索引，适合缓存大量结构化数据和离线数据。选型上登录态放 HttpOnly Cookie，用户偏好放 localStorage，离线缓存用 IndexedDB 或者 Cache Storage。

**追问陷阱**：
- 错误：「localStorage 会随请求发给后端」 → 正确：不会，只有 Cookie 会。
- 错误：「localStorage 可以直接存对象」 → 正确：只能存字符串，直接存对象会变成 `[object Object]`。
- 错误：「sessionStorage 多个标签页共享」 → 正确：每个标签页独立，同源也不共享。
- 错误：「IndexedDB 是同步 API」 → 正确：全异步，用事件或 Promise 封装。

## 9. XSS 与 CSRF

**一句话答案**：XSS 是把恶意脚本注入页面执行，窃取 Cookie、篡改 DOM；CSRF 是诱导已登录用户向目标站发起请求，利用 Cookie 自动携带。防御上 XSS 靠输出转义、CSP、HttpOnly，CSRF 靠 CSRF Token、SameSite Cookie、Origin 校验。

**原理展开**：
- XSS 三类：存储型（恶意内容入库，所有访问者中招）、反射型（URL 参数原样回显）、DOM 型（前端把不可信数据塞进 `innerHTML`/`eval`）。
- XSS 防御：输出按上下文编码（HTML/JS/URL/CSS）、避免 `innerHTML` 和 `v-html`、富文本用 DOMPurify 过滤、CSP 限制脚本源、Cookie 加 `HttpOnly`、输入校验。
- CSRF 原理：用户在 A 站已登录，访问恶意 B 站，B 站自动向 A 站发请求（表单、图片、fetch），浏览器带上 A 站 Cookie，A 站无法区分请求来源。
- CSRF 防御：CSRF Token（同步器模式，服务端校验）、`SameSite=Lax/Strict`、校验 `Origin/Referer`、敏感操作二次验证；CORS 不能防 CSRF。
- 两者区别：XSS 是「在站内执行脚本」，CSRF 是「借用户的身份发请求」；XSS 能直接读 token，所以防住 XSS 是前提。

```js
const userInput = '<img src=x onerror="alert(document.cookie)">'
const box = document.getElementById('msg')
// 错误：XSS 入口：用户输入里的 onerror 会执行
box.innerHTML = userInput
// 正确：文本节点自动转义
box.textContent = userInput
```

```http
Set-Cookie: sessionId=abc123; HttpOnly; Secure; SameSite=Lax
```

**面试怎么答（60 秒版）**：
XSS 是把脚本注入到页面里执行，分存储型、反射型和 DOM 型，最常见的是把用户输入直接 innerHTML。防御核心是输出转义，富文本用 DOMPurify 白名单过滤，再配合 CSP 和 HttpOnly Cookie。CSRF 不一样，它不需要拿到 Cookie，而是利用浏览器会自动带 Cookie，诱导用户在已登录状态下发请求。防御靠 CSRF Token、SameSite Cookie、校验 Origin 或 Referer。要注意 CORS 防不了 CSRF，因为表单和图片发起的请求不走 CORS 检查。

**追问陷阱**：
- 错误：「用了 Vue/React 就不会 XSS」 → 正确：文本插值默认转义，但 `v-html`、`dangerouslySetInnerHTML` 仍是入口。
- 错误：「CORS 能防 CSRF」 → 正确：不能，表单/图片请求不受 CORS 限制，要靠 Token 和 SameSite。
- 错误：「CSRF 需要先拿到用户 Cookie」 → 正确：不需要，浏览器自动携带才是攻击前提。
- 错误：「只在前端防就够了」 → 正确：存储型 XSS 在服务端入库，后端也要校验和转义。

## 10. HTTPS 握手简化版

**一句话答案**：HTTPS = HTTP + TLS，先用证书链验证服务器身份、用非对称加密/密钥交换协商出对称会话密钥，之后所有数据用对称加密传输；TLS 1.3 把握手压缩到 1-RTT。

**原理展开**：
- 三个目标：机密性（对称加密）、完整性（MAC/AEAD）、身份认证（证书 + CA 信任链）。
- TLS 1.2（ECDHE）简化：客户端发 ClientHello（随机数 + 支持的套件）→ 服务端回 ServerHello + 证书 + 密钥交换参数 → 客户端验证证书、生成预主密钥 → 双方各自算出会话密钥 → Finished 校验握手完整性。
- TLS 1.3：合并流程到 1-RTT，废除 RSA 密钥交换等不安全套件，支持会话恢复 0-RTT（有重放风险，只用于幂等请求）。
- 证书校验：域名是否匹配、是否在有效期、CA 签名链是否可信、是否被吊销。
- 为什么不全用非对称加密：非对称运算慢，只用于握手和签名；会话密钥短期有效，泄露影响小。

**面试怎么答（60 秒版）**：
HTTPS 就是在 HTTP 下面加了 TLS。握手时客户端先发 ClientHello，带随机数和加密套件；服务端回 ServerHello、证书和密钥交换参数；客户端验证证书链，确认服务端身份，然后双方协商出对称的会话密钥，之后的数据都用对称加密传。这么设计是因为非对称加密慢，只用来握手和签名，真正的数据传输用对称加密。TLS 1.3 把握手优化到 1 个 RTT，还支持 0-RTT 会话恢复。证书解决身份认证，防中间人冒充。

**追问陷阱**：
- 错误：「HTTPS 用非对称加密传输数据」 → 正确：数据用对称加密，非对称只用于握手和签名。
- 错误：「有了证书数据就不会被篡改」 → 正确：证书防冒充，完整性靠 MAC/AEAD 校验。
- 错误：「HTTPS 抓包看不到内容」 → 正确：可以通过代理安装信任根证书做中间人，或用浏览器 TLS 密钥日志解密。
- 错误：「HTTPS 一定慢很多」 → 正确：开销主要在握手，TLS 1.3 和连接复用后差距很小。

## 加分项：深挖到此

### 加分项：深挖到此 · 发版后白屏，缓存链路怎么查

被追问「线上发版后用户还是旧页面怎么排查」时，答：先看 `index.html` 是否被缓存，它必须 `no-cache` 或 `max-age=0, must-revalidate`；再看静态资源是否带内容哈希并且一年 immutable，正常发版后 URL 变化会自然拉新。如果用了 Service Worker，旧版本可能一直接管页面，要配合 `skipWaiting` + `clientsClaim` 或更新提示；CDN 还要刷新缓存目录。排查顺序是 HTML → 资源 URL → Service Worker → CDN，这个链路答出来，面试官会认为你真发过版。

### 加分项：深挖到此 · 登录态在前后端如何闭环

被追问「JWT 方案怎么设计登录、续期和登出」时，答：登录成功后发短期 access token（15~30 分钟）+ 长期 refresh token（7 天）；access token 放内存或 HttpOnly Cookie，refresh token 放 HttpOnly Cookie 并绑定设备；接口 401 时用 refresh token 换新 token，并发刷新要做单飞避免风暴；登出时服务端把 refresh token 记录作废（Redis），access token 靠短 TTL 自然过期，敏感操作可查黑名单；前端路由守卫看本地是否有有效 token，但最终权限以接口 401/403 为准。这套闭环能把 JWT 无状态的缺点补上。

## 高频题库

| 题号 | 题目 | 考点 | 答案要点 |
| --- | --- | --- | --- |
| 1 | HTTP 报文由哪些部分组成？ | 报文结构 | 请求行/状态行 + 头部 + 空行 + body；Host 必带 |
| 2 | 常见状态码及含义？ | 状态码 | 200/201/204/301/302/304/400/401/403/404/429/500/502/503/504 |
| 3 | 401 和 403 的区别？ | 状态码 | 401 未认证可重试登录；403 已认证无权限 |
| 4 | GET 和 POST 的区别？ | 方法语义 | 语义、幂等、缓存、参数位置、长度限制（浏览器/服务器实现层面） |
| 5 | HTTP/1.1 有什么问题？ | HTTP 版本 | 文本协议、并发连接数限制、应用层队头阻塞 |
| 6 | HTTP/2 的核心改进？ | HTTP 版本 | 二进制分帧、多路复用、HPACK、服务端推送（已废弃） |
| 7 | HTTP/3 为什么用 UDP？ | HTTP 版本 | QUIC 解决 TCP 队头阻塞、0-RTT、连接迁移 |
| 8 | 强缓存和协商缓存区别？ | 缓存 | Cache-Control 命中不发请求；ETag/Last-Modified 返回 304 |
| 9 | no-cache 和 no-store 区别？ | 缓存 | no-cache 每次协商；no-store 完全不存 |
| 10 | Vue 项目静态资源怎么配缓存？ | 缓存实战 | index.html no-cache；hash 资源一年 immutable |
| 11 | 什么是同源策略？ | 跨域 | 协议+域名+端口一致；限制读取响应，不是限制发送 |
| 12 | CORS 简单请求和预检请求区别？ | 跨域 | 简单请求直接发；其余先 OPTIONS，预检可缓存 |
| 13 | 为什么开发环境不跨域生产跨域？ | 跨域实战 | dev server proxy 转发；生产需同域/网关/CORS |
| 14 | Cookie 和 localStorage 区别？ | 存储 | Cookie 4KB 自动携带；localStorage 5MB 不随请求发送 |
| 15 | Session 和 JWT 各自优劣？ | 登录态 | Session 可主动踢人但需共享存储；JWT 无状态但撤销难 |
| 16 | JWT 三段结构是什么？ | 登录态 | header.payload.signature；前两段明文，只签名不加密 |
| 17 | JWT 登出怎么实现？ | 登录态 | 删客户端 token；refresh token 作废；黑名单/短 TTL |
| 18 | 输入 URL 到页面渲染的流程？ | 浏览器 | DNS → TCP → TLS → 请求响应 → DOM/CSSOM → 渲染树 → 布局 → 绘制 → 合成 |
| 19 | DOMContentLoaded 和 load 区别？ | 浏览器 | DOM 解析完 vs 所有资源加载完 |
| 20 | async 和 defer 区别？ | 浏览器 | async 下载完立即执行、顺序不定；defer 解析完按序执行 |
| 21 | 重排和重绘的区别？ | 性能 | 几何变化 vs 外观变化；transform/opacity 只合成 |
| 22 | 如何减少重排重绘？ | 性能 | 读写分离、DocumentFragment、transform 动画、rAF |
| 23 | XSS 原理和防御？ | 安全 | 注入脚本执行；输出转义、CSP、HttpOnly、DOMPurify |
| 24 | CSRF 原理和防御？ | 安全 | 借用 cookie 自动携带；CSRF Token、SameSite、Origin 校验 |
| 25 | HTTPS 握手为什么用非对称加密？ | HTTPS | 安全协商对称密钥；传输用对称加密保证性能 |

> 全库导航：[README](../README.md) ｜ [路线图](../00-plan/路线图.md) ｜ 相关：[JS 核心八股](../01-js/JS核心八股.md) ｜ [Vue3 原理与对比](../02-vue/Vue3原理与对比.md) ｜ [SpringBoot 与后端工程](../03-java/SpringBoot与后端工程.md) ｜ [系统设计入门](../06-system-design/系统设计入门.md)
