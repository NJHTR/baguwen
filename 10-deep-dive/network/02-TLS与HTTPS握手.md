# TLS 与 HTTPS 握手（证书 / ECDHE / 1.3 / HTTP2/3）

> 面试权重：5/5　｜　追问深度：**L5（TLS 1.3 密钥派生 / Record 层 AEAD / 证书链验签）**
> 一句话定位：HTTPS = HTTP + TLS。TLS 用**非对称加密/证书**解决"和谁通信、对方是不是真的"，用**密钥交换**协商出一个只有双方知道的对称密钥，之后所有数据用**对称加密**传输。追问到最后，拼的是 TLS1.2 与 1.3 的握手差异、证书链验证和"握手到底付出了几个 RTT"。

**本文件用法**：先背 L2 的 TLS1.2 时序与 TLS1.3 的差异，再逐层往下。答不出"ECDHE 为什么前向安全""0-RTT 的重放风险"，说明只背了名词。
[返回深度追问索引](../00-索引.md)

---

## L1 一句话答案（10 秒能说出口）

HTTPS 在 TCP 之上加了一层 TLS：**证书链**证明服务器身份（由受信 CA 签名），**密钥交换（ECDHE）**协商出会话密钥，**对称加密（AES-GCM/ChaCha20）**加密后续所有数据。TLS1.2 完整握手要 **2-RTT**（ClientHello → ServerHello/Certificate/ServerKeyExchange → ClientKeyExchange/Finished），TLS1.3 把密钥交换塞进 ClientHello 的 `key_share`，压到 **1-RTT**，会话复用时还能 **0-RTT**（但有重放风险）。ECDHE 每次握手生成临时密钥，所以私钥泄露也解不开历史流量，即**前向安全**。

---

## L2 原理层：证书、握手、复用与性能

### 2.1 三类密码学原语各干什么

| 原语 | 算法 | 速度 | 在 TLS 里的用途 |
|---|---|---|---|
| 对称加密 | AES-GCM、ChaCha20-Poly1305 | 极快（有硬件加速） | **加密应用数据**（握手后所有 record） |
| 非对称加密/密钥交换 | RSA、ECDHE（X25519/P-256） | 慢 2-4 个数量级 | 身份认证、协商出对称密钥 |
| 哈希/签名 | SHA-256、HMAC | 快 | 证书签名、完整性校验、密钥派生 |

所以 TLS 是**混合加密**：非对称只用来"认证 + 换密钥"，真正传数据用对称。RSA 密钥交换（客户端用服务端公钥加密 pre-master）没有前向安全；ECDHE 是**临时**密钥交换，每次握手都不同。

### 2.2 证书链与 CA 校验（身份怎么被证明）

```
根 CA 证书（浏览器/系统内置，自签名，无条件信任）
    └── 中间 CA 证书（由根 CA 签名）
            └── 站点证书（由中间 CA 签名，含域名 SAN、有效期、公钥）
```

- 服务端下发**站点证书 + 中间证书**（根证书通常不下发，客户端本地有）。客户端逐级验签：站点证书的签名用中间 CA 公钥验证 → 中间 CA 的签名用根 CA 公钥验证 → 根证书在信任库里则认为链路可信。同时校验**域名（SAN）**、**有效期**、**用途（serverAuth）**、**吊销状态（CRL/OCSP）**。
- 常见错误：链不完整（只发站点证书 → 某些客户端报 unknown CA）、证书过期、域名不匹配、根证书不被信任（自签）。证书本身不加密，只包含公钥与身份；**私钥永远在服务端**，用私钥签名、客户端用证书公钥验签。

### 2.3 TLS 1.2 完整握手（2-RTT）

```
Client                                               Server
  │ ClientHello（version, random, session_id, cipher_suites,
  │   extensions: SNI/ALPN/groups/sig_algs）
  ├──────────────────────────────────────────────►
  │  ◄── ServerHello(选定套件, random) + Certificate(站点+中间证书)
  │      + ServerKeyExchange(ECDHE 参数 + 签名) + [CertificateRequest] + ServerHelloDone
  │ ClientKeyExchange(客户端 ECDHE 公钥) + ChangeCipherSpec + Finished(加密)
  ├──────────────────────────────────────────────►
  │ ◄────────────────────────────────────────────── ChangeCipherSpec + Finished
  │ 之后：应用数据（全部对称加密）
```

- **两个 RTT**：第一个 RTT 协商参数、拿证书；第二个 RTT 换密钥、验证 Finished。`ServerKeyExchange` 里 ECDHE 参数由服务端**用证书私钥签名**，客户端验签后才信；RSA 密钥交换则没有这条消息。
- 双方由 `pre_master_secret` 经 `PRF(master_secret, client_random + server_random)` 派生 **master_secret**，再派生 `client_write_key / server_write_key / IV`；`Finished` 是对整个握手 transcript 的 HMAC，**任何中间人篡改**都会导致 Finished 校验失败。

### 2.4 TLS 1.3：1-RTT 与 0-RTT

```
Client                                               Server
  │ ClientHello（supported_versions=1.3, key_share=X25519 公钥,
  │   psk_key_exchange_modes, [early_data]）
  ├──────────────────────────────────────────────►
  │ ◄── ServerHello(服务端 key_share) + {EncryptedExtensions, Certificate,
  │     CertificateVerify, Finished}（除 ServerHello 外全部加密）
  │ Finished（客户端）—— 之后应用数据（1-RTT）
  ├──────────────────────────────────────────────►
```

- **1-RTT**：客户端在 ClientHello 就带 `key_share`，服务端回自己的 `key_share` 后双方立刻能算共享密钥，省掉了一整个往返；且证书等握手消息从第二个 flight 起就**加密**（防窃听握手内容）。
- **0-RTT**：基于之前会话的 **PSK**，客户端在 ClientHello 里直接带 `early_data`，第一个包就能发应用数据。代价是**可重放**（攻击者可截获 early data 重放），所以只对幂等请求（GET/静态资源）启用，服务端要配 `ssl_early_data` 并用 `Early-Data: 1` 头做防重放。
- **HelloRetryRequest**：客户端没带服务端支持的 `key_share`（如只带 P-256，服务端偏好 X25519）时，服务端回 HRR 让客户端重发，变成 2-RTT。所以现代客户端会预发多个 key_share。密钥派生用 `HKDF-Extract` + `HKDF-Expand-Label`，每阶段换密钥（密钥更新 `KeyUpdate`）。

### 2.5 会话复用：Session ID vs Session Ticket vs PSK

| 方式 | 做法 | 优点 | 缺点 |
|---|---|---|---|
| Session ID（TLS1.2） | 服务端缓存会话状态，客户端带 session_id 复用 | 简单 | 服务端内存/多机共享问题，扩容后失效 |
| Session Ticket（TLS1.2） | 服务端把会话状态**加密成 ticket** 交给客户端，下次带回 | 服务端无状态、可多机共享 | 依赖 ticket key 安全，key 泄露可解密会话 |
| PSK（TLS1.3） | 用 NewSessionTicket 发 PSK，下次 ClientHello 带 `pre_shared_key` | 1-RTT/0-RTT 复用 | 0-RTT 重放风险；PSK 与票绑定 |

生产配置：Nginx `ssl_session_cache shared:SSL:10m; ssl_session_timeout 1d; ssl_session_tickets on;`，注意 ticket key 定期轮换（`ssl_session_ticket_key` 多把轮换）。

### 2.6 中间人、证书固定与 HSTS

- **中间人（MITM）**：攻击者截获连接后冒充服务端。能成功的前提是客户端**信任了攻击者的证书**（用户手动装了根证书、企业代理、恶意软件）。防护：HSTS 强制 HTTPS、证书固定、校验证书链与域名、CT（Certificate Transparency）审计。
- **证书固定（Certificate Pinning）**：客户端内置服务端证书/公钥的指纹（对叶子证书、中间 CA 或 SPKI 做 pin），不匹配就拒绝。缺点：**证书轮换要做备份 pin、发版升级**，App 用得多，浏览器一般靠 HSTS + CT。
- **HSTS**：响应头 `Strict-Transport-Security: max-age=31536000; includeSubDomains; preload`，让浏览器后续强制走 HTTPS，防降级到 HTTP 的劫持。

### 2.7 HTTPS 性能损耗与优化

- **损耗来源**：① 握手往返（TLS1.2 2-RTT，新建连接多 2 个 RTT）；② 非对称运算（RSA 签名/解密 CPU 高，ECDSA/X25519 便宜）；③ 证书链体积（几 KB，且会占首包）；④ 对称加解密（有 AES-NI 后几乎可忽略）。
- **优化**：TLS1.3、会话复用（session cache/ticket/PSK）、**OCSP stapling**（服务端代客户端取 OCSP 响应并随握手下发，省一个客户端请求、防隐私泄露）、**TLS 卸载**到 LB/Nginx（后端走内网 HTTP）、ECDSA 证书、HTTP/2 复用连接减少握手次数；证书链要配全（`ssl_certificate` 文件里按 站点 → 中间 顺序拼接）。

### 2.8 HTTP/2 多路复用与 TCP 层队头阻塞，HTTP/3/QUIC

- **HTTP/2**：一个 TCP 连接上多路复用多个 stream（帧 + stream id），解决 HTTP/1.1 的**应用层队头阻塞**（前一个请求没回来后面的排队）和连接数限制。**但它没解决 TCP 层队头阻塞**：TCP 保证按序交付，一个包丢了整个连接的后续数据都要等重传，所有 stream 一起卡住。
- **HTTP/3 / QUIC**：跑在 **UDP** 上，自带可靠传输（包号 + ACK + 重传）、**每个 stream 独立**（丢包只阻塞所在 stream），内嵌 TLS1.3（握手 1-RTT/0-RTT）、支持**连接迁移**（用 Connection ID 而不是四元组，切换 Wi-Fi/4G 不断连）。代价是 UDP 在部分网络被限制、CPU 开销略高。

### 2.9 项目落点

报告平台的 SSE 长连接、数字人 WebSocket 都要走 `https/wss`：长连接对握手成本不敏感，但**连接建立时的 TLS 握手、证书链、会话复用**决定首屏体验；Docker 私有 registry 走自签证书时要给客户端/节点装内部 CA，否则报 `x509: certificate signed by unknown authority`。

---

## L3 底层层：Record 层与密钥派生

### 3.1 TLS Record 协议

```
每个 record：ContentType(1B) | Version(2B) | Length(2B) | Fragment(加密)
ContentType: 20=ChangeCipherSpec, 21=Alert, 22=Handshake, 23=ApplicationData
TLS1.2 加密：AEAD（AES-GCM/ChaCha20-Poly1305）在 record 上做
TLS1.3 加密：握手消息也是 record(22)+密文，nonce 由 密钥 + 序号(sequence number) 构造
```

### 3.2 TLS1.3 的 HKDF 密钥派生（终局铺垫）

```
Early Secret     = HKDF-Extract(0, PSK)
Handshake Secret = HKDF-Extract(Derive-Secret(Early, "derived", ""), ECDHE 共享密钥)
Master Secret    = HKDF-Extract(Derive-Secret(Handshake, "derived", ""), 0)
client_handshake_traffic_secret = Derive-Secret(Handshake Secret, "c hs traffic", transcript)
server_handshake_traffic_secret = Derive-Secret(Handshake Secret, "s hs traffic", transcript)
client_application_traffic_secret_0 = Derive-Secret(Master Secret, "c ap traffic", transcript)
```

`Derive-Secret` 内部是 `HKDF-Expand-Label`（带 label 与 transcript hash），保证**不同阶段/方向的密钥互不相关**；`CertificateVerify` 用证书私钥对"握手上下文"签名，覆盖整条 transcript，防中间人拼接。

### 3.3 观测与调试

```bash
openssl s_client -connect api.example.com:443 -servername api.example.com -tls1_3 -brief
openssl s_client -connect api.example.com:443 -msg </dev/null | head -80     # 看 handshake 报文
echo | openssl s_client -connect api.example.com:443 2>/dev/null | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
curl -v --tlsv1.3 https://api.example.com/ -o /dev/null
```

---

## L4 追问树（面试官一路往下问，你能撑到第几层？）

> 规则：第 1-3 层必备，4-6 层拉开差距，7 层以后是加分。

### 第 1 层｜HTTPS 到底加密了什么？
**答**：加密 HTTP 的**内容**（请求行/头/体），也加密 HTTP/2 的帧；但**连接的元数据**（目标 IP、端口、SNI 中的域名、流量大小与时间）在 TLS1.2/1.3 中大多可见（ECH 可隐藏 SNI）。身份靠证书验证，不是"连上就是安全"。

### 第 2 层｜TLS1.2 完整握手的每一步作用？
**答**：ClientHello 报版本/随机数/套件/扩展（SNI 指明域名、ALPN 协商 h2）；ServerHello 选定套件并给随机数；Certificate 下发站点+中间证书；ServerKeyExchange 给 ECDHE 参数并用私钥签名；ServerHelloDone 结束服务端 flight；ClientKeyExchange 给客户端 ECDHE 公钥；双方由 pre-master 派生 master 与写密钥；ChangeCipherSpec 切换加密；Finished 用 transcript HMAC 校验握手完整性。

### 第 3 层｜为什么需要证书链？浏览器怎么验证？
**答**：证书是"公钥 + 身份 + CA 签名"，单张证书无法自证。链式信任从内置根 CA 出发，逐级验签到底层站点证书，同时校验域名 SAN、有效期、用途、吊销状态。链不完整（缺中间证书）、过期、域名不符、根不被信任都会报错。

### 第 4 层｜ECDHE 为什么能前向安全？RSA 密钥交换为什么不能？
**答**：ECDHE 每次握手生成**临时**公私钥对，用完即弃，会话密钥由双方临时公钥算出的共享秘密派生，**不落到任何长期私钥上**——长期私钥（证书）泄露也无法解密历史流量。RSA 密钥交换是客户端用服务端**长期公钥**加密 pre-master，攻击者只要事后拿到长期私钥就能解密历史流量，所以没有前向安全。

### 第 5 层｜TLS1.3 为什么只要 1-RTT？0-RTT 有什么风险？
**答**：1.3 要求客户端在 ClientHello 里就带 `key_share`（临时公钥），服务端回自己的 key_share 后立刻能算共享密钥，省去 1.2 里"ClientKeyExchange 再走一个往返"的步骤；且签名改为 `CertificateVerify`，证书消息也加密。0-RTT 用之前会话的 PSK 在第一个包就发应用数据，代价是**可重放**，只对幂等请求开放。

### 第 6 层｜会话复用有哪几种？生产怎么配？
**答**：Session ID（服务端缓存会话，简单但多机不好共享）、Session Ticket（服务端把状态加密成 ticket 给客户端，无状态、多机友好）、TLS1.3 的 PSK（用 NewSessionTicket 下发，支持 1-RTT/0-RTT 复用）。生产配 `ssl_session_cache shared:SSL:10m`、合理 `ssl_session_timeout`、ticket key 轮换，同时注意 ticket key 泄露会危及复用会话。

### 第 7 层｜中间人怎么攻击 HTTPS？证书固定和 HSTS 防什么？
**答**：MITM 截获连接后用自己的证书冒充服务端，前提是客户端信任该证书（企业代理装根证书、恶意软件、被攻陷的 CA）。防护：HSTS 强制 HTTPS 并禁止用户忽略证书错误、证书固定（内置证书/公钥指纹，不匹配即拒绝，需备份 pin 应对轮换）、CT 日志审计。**普通用户点"继续访问"就等于放弃验证。**

### 第 8 层｜OCSP stapling 解决什么问题？
**答**：OCSP 是客户端向 CA 实时查询证书是否吊销，会带来额外请求、延迟和隐私泄露（CA 知道你访问谁）。stapling 由**服务端**定期获取 OCSP 响应并在握手时"钉"给客户端（TLS1.3 里是 Certificate 扩展），客户端无需外连 CA，既省时延又保护隐私；要配 `ssl_stapling on; ssl_stapling_verify on;` 与 DNS resolver。

### 第 9 层｜HTTPS 性能损耗在哪？怎么优化？
**答**：握手 RTT（1.2 是 2-RTT）、非对称运算 CPU、证书链体积、对称加解密的吞吐（有 AES-NI 可忽略）。优化：TLS1.3、会话复用、OCSP stapling、TLS 卸载到 LB/网关、ECDSA/X25519 证书与套件、HTTP/2 复用连接减少握手次数、长连接（SSE/WS）避免频繁建连。

### 第 10 层｜HTTP/2 多路复用为什么还会队头阻塞？HTTP/3 怎么解？
**答**：HTTP/2 在**应用层**用 stream 多路复用，解决了 HTTP/1.1 的请求排队；但底层仍是**单个 TCP 连接**，TCP 保证按序交付，任何一个包丢失，后续所有 stream 的数据都要等重传——这是 TCP 层队头阻塞。HTTP/3 把传输换成 QUIC（UDP），每个 stream 独立按序，丢包只阻塞所在 stream；QUIC 内嵌 TLS1.3（1-RTT/0-RTT），还支持连接迁移。

### 第 11 层（终局）｜TLS1.3 从 ClientHello 到 Finished，密钥是怎么算出来的？
**答**：ClientHello 带 `key_share`（X25519 公钥）与 `supported_versions=1.3`；服务端回 ServerHello + 自己的 key_share，双方用 X25519 算出 ECDHE 共享密钥 → `HKDF-Extract` 出 **Handshake Secret**（输入为 early secret 的 derived 值 + ECDHE 共享密钥）→ 用 `Derive-Secret`（transcript hash）派生 `client_handshake_traffic_secret` / `server_handshake_traffic_secret`，之后的服务端握手消息（EncryptedExtensions/Certificate/CertificateVerify/Finished）全部用这两个密钥以 AEAD 加密；再 `HKDF-Extract` 出 **Master Secret**，派生 application traffic secret，Finished 校验 transcript 通过后切换应用数据密钥。**每一阶段密钥都由 HKDF + transcript 绑定，任何报文被篡改都会让 Finished 失败。**

---

## L5 名词拆解表（每个名词都拆开）

| 名词 | 是什么 | 为什么存在 | 面试追问点 |
|---|---|---|---|
| 对称加密 | 同一密钥加解密（AES-GCM/ChaCha20） | 快，承担数据加密 | AEAD、nonce 不能重用 |
| 非对称加密 | 公钥/私钥对（RSA/ECDSA） | 认证与密钥交换、防冒充 | 为什么不用它加密数据（慢） |
| 证书链 | 站点证书 → 中间 CA → 根 CA（内置信任锚） | 从信任锚逐级验证身份 | 链不完整/过期/域名不符/自签为何不可信 |
| SNI | ClientHello 里的域名扩展 | 一台 IP 托管多个站点，选证书 | 明文泄露域名、ECH |
| ECDHE | 临时椭圆曲线密钥交换 | 提供前向安全 | 与 RSA 密钥交换对比（前向安全=长期私钥泄露不影响历史会话） |
| PSK / NewSessionTicket | TLS1.3 会话复用凭证 | 1-RTT/0-RTT 复用 | 0-RTT 重放风险 |
| Session Ticket | 服务端加密的会话票据 | 无状态复用、多机友好 | ticket key 轮换与泄露 |
| OCSP stapling | 服务端代取吊销状态并下发 | 省请求、保护隐私 | 与直接 OCSP 的区别 |
| HSTS | 强制浏览器走 HTTPS 的响应头 | 防降级劫持 | preload、includeSubDomains |
| QUIC / HTTP/3 | 基于 UDP 的可靠传输 + 内嵌 TLS1.3 | 消除 TCP 层队头阻塞、连接迁移 | 与 HTTP/2 的本质差异 |

---

## 代码验证

```bash
# 1) 看 TLS1.3 握手与协商结果（协议版本、套件、ALPN、会话复用）
openssl s_client -connect api.example.com:443 -servername api.example.com -tls1_3 -brief

# 2) 逐条看握手报文（ClientHello/ServerHello/Certificate/Finished）
openssl s_client -connect api.example.com:443 -msg </dev/null 2>/dev/null | head -100

# 3) 验证证书链、域名与有效期（链不完整会在这里暴露）
echo | openssl s_client -connect api.example.com:443 -showcerts 2>/dev/null | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
```

```nginx
# 5) Nginx 的 HTTPS 关键配置（TLS1.3 + 会话复用 + OCSP stapling）
server {
    listen 443 ssl http2;
    server_name api.example.com;
    ssl_certificate     /etc/nginx/certs/fullchain.pem;   # 站点证书+中间证书，顺序不能错
    ssl_certificate_key /etc/nginx/certs/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:SSL:10m;
    ssl_stapling        on;
    ssl_stapling_verify on;
    resolver            223.5.5.5 valid=300s;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
}
```

```java
// 6) Java HttpClient 指定 TLS1.3 并做超时（报告平台 调用下游 HTTPS 的写法）
HttpClient client = HttpClient.newBuilder()
        .sslContext(SSLContext.getInstance("TLSv1.3"))
        .connectTimeout(Duration.ofSeconds(2)).build();
HttpResponse<String> resp = client.send(HttpRequest.newBuilder(
        URI.create("https://api.example.com/health")).timeout(Duration.ofSeconds(3)).GET().build(),
        HttpResponse.BodyHandlers.ofString());
```

---

## 高频错误（面试官最爱抓的）

| 错误说法 | 正确说法 |
|---|---|
| 「HTTPS 用非对称加密传数据」 | 非对称只用于认证与密钥交换，数据用对称加密（AES-GCM/ChaCha20） |
| 「TLS1.2 是 1-RTT，TLS1.3 是 0-RTT」 | 1.2 完整握手 2-RTT，1.3 是 1-RTT，0-RTT 只在会话复用 + early_data 时 |
| 「RSA 密钥交换也有前向安全」 | 没有；只有 ECDHE/DHE 这类临时密钥交换才有前向安全 |
| 「OCSP stapling 是让客户端少发一个证书」 | 是服务端代取吊销状态并随握手下发，省客户端的 OCSP 请求并保护隐私 |
| 「HTTP/2 解决了所有队头阻塞」 | 只解决应用层；TCP 层丢包仍会阻塞所有 stream，HTTP/3 才解决 |
| 「0-RTT 可以随便用，反正更快」 | 0-RTT 可被重放，只适合幂等请求，并要配合防重放策略 |

---

## 关联文件

- 下层：TCP 连接与调优（握手依赖 TCP 三次握手）：[TCP 连接与调优](./01-TCP连接与调优.md)
- 网络与浏览器基础（HTTP/2、缓存、队头阻塞）：[HTTP与浏览器](../../05-network/HTTP与浏览器.md)
- 可观测性（TLS 握手耗时怎么打点）：[可观测性](../ops/02-可观测性.md)

> **自测标准**：能画出 TLS1.2 的 2-RTT 握手与 TLS1.3 的 1-RTT 差异，说清证书链验证与 ECDHE 前向安全，区分 Session ID/Ticket/PSK，解释 0-RTT 重放风险与 OCSP stapling，说明 HTTP/2 与 HTTP/3 的队头阻塞差异，算过关。
