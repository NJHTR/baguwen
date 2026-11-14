# TLS 握手：HTTPS 到底加密了什么，握手为什么是 1~2 个往返？

> 精讲层级：从「零基础能看懂」到「协议字段与密钥派生级」，每个名词都在第一次出现时拆开
> 阅读时间：约 35 分钟
> 配套速查：[TLS 与 HTTPS 握手（深度追问）](../../10-deep-dive/network/02-TLS与HTTPS握手.md)
> 返回：[精讲索引](../00-索引.md)

---

## 0. 一句话先讲明白

HTTPS = HTTP + TLS。TLS 用**证书**回答"我是不是我要连的那个人"（身份认证），用**密钥交换**协商出一个只有双方知道的会话密钥，之后所有数据用**对称加密**传输。TLS 1.2 的完整握手需要**两个往返（2-RTT）**，TLS 1.3 把密钥交换材料直接塞进第一个 ClientHello，压到**一个往返（1-RTT）**，会话复用时甚至能 **0-RTT**。HTTPS 加密的是 HTTP 的**内容**，不是"整条连接的一切"——目标 IP、端口、SNI 里的域名、流量大小仍然可见。

---

## 1. 先讲痛点：明文 HTTP 缺什么

### 1.1 名词先解释

| 名词 | 一句话解释 |
|---|---|
| 对称加密 | 加密和解密用同一把钥匙（如 AES），速度快，适合加密大数据 |
| 非对称加密 | 一对钥匙：公钥加密、私钥解密（或私钥签名、公钥验签），速度慢 2~4 个数量级 |
| 数字签名 | 用私钥对一段数据的摘要签名，别人用公钥验证"这确实是你发的、且没被改" |
| 证书 | 一份由 CA 背书的"公钥 + 身份（域名）"文件，里面还有 CA 的签名 |
| CA | Certificate Authority，受信任的证书颁发机构，其根证书被预装在操作系统/浏览器里 |
| 证书链 | 站点证书 → 中间 CA → 根 CA，逐级用上一级的公钥验证下一级的签名 |
| 握手 | 双方协商协议版本、加密套件、交换密钥材料、验证身份的过程 |
| RTT | Round-Trip Time，一个请求-响应往返的时间；握手开销常用 RTT 计量 |
| 前向安全 | 长期私钥泄露后，**历史会话**仍然安全（因为会话密钥不依赖长期私钥推不出来） |
| 会话密钥 | 本次连接专用的对称密钥，握手协商出来，连接结束就丢弃 |
| AEAD | 同时做加密与完整性校验的算法（如 AES-GCM），密文被改会校验失败 |

### 1.2 明文 HTTP 的三个致命问题

| 问题 | 攻击方式 | 后果 |
|---|---|---|
| 窃听 | 同一 Wi-Fi 下抓包 | 密码、Cookie、聊天内容全部明文可见 |
| 篡改 | 中间人修改响应 | 注入广告、改转账账号、改下载内容 |
| 冒充 | 伪造服务器/客户端 | 钓鱼站、中间人代理 |

这对应安全三要素：**机密性**（加密）、**完整性**（防篡改）、**身份认证**（证明对端是谁）。TLS 三件事都要做，而三件事需要不同的密码学工具。

### 1.3 为什么不能只用一种加密

- **只用对称加密**：速度快，但"双方怎么安全地共享同一把钥匙"是死循环——第一次通信时把密钥发过去，就会被窃听。
- **只用非对称加密**：安全，但慢 2~4 个数量级。RSA-2048 一次签名/解密是毫秒级，用它加密 1 GB 数据完全不现实（按 1 MB/s 级别估算要上千秒）。

所以 TLS 用**混合加密**：非对称/证书负责"认证 + 换密钥"，对称负责"传数据"。

---

## 2. 逐步拆解：证书、TLS 1.2、TLS 1.3

### 2.1 三类原语各自的分工

| 原语 | 算法 | 速度量级 | 在 TLS 里的用途 |
|---|---|---|---|
| 对称加密 | AES-128-GCM、ChaCha20-Poly1305 | 每秒数 GB | 加密应用数据（握手后的所有记录） |
| 非对称加密 | RSA-2048/4096、ECDSA P-256、ECDHE X25519 | 每秒数千~数万次操作 | 身份认证（签名/验签）、密钥交换 |
| 哈希/签名 | SHA-256、HMAC、AEAD | 每秒数 GB | 证书签名、握手 transcript 校验、密钥派生 |

### 2.2 证书链：身份是怎么被证明的

```
根 CA 证书（自签名，预装在操作系统/浏览器的信任库，无条件信任）
   └── 中间 CA 证书（由根 CA 签名）
         └── 站点证书（由中间 CA 签名；包含域名 SAN、公钥、有效期）
```

服务端在握手时下发**站点证书 + 中间证书**（根证书通常不下发，因为客户端本地已有）。客户端验证顺序：

1. 用中间 CA 的公钥验证站点证书上的签名；
2. 用根 CA 的公钥验证中间 CA 证书上的签名；
3. 根证书在自己的信任库里 → 整条链可信；
4. 再检查：域名（SAN，Subject Alternative Name）是否匹配、有效期、用途（serverAuth）、是否被吊销（CRL 证书吊销列表 / OCSP 在线证书状态查询）。

常见错误与原因：

| 现象 | 原因 |
|---|---|
| `unable to get local issuer certificate` | 服务端没下发中间证书，链不完整 |
| `certificate has expired` | 证书过期 |
| `hostname mismatch` | SAN 里没有这个域名 |
| `self signed certificate` | 自签证书不在信任库 |

### 2.3 TLS 1.2 完整握手：两个往返

```
客户端                                              服务端
  │ ① ClientHello
  │    - version(如 TLS1.2)
  │    - client_random(32 字节随机数)
  │    - session_id（想复用会话时带）
  │    - cipher_suites（支持的套件列表）
  │    - extensions: SNI(域名)、ALPN(应用协议协商，用于选出 h2 或 http/1.1)、
  │                  supported_groups、signature_algorithms
  ├──────────────────────────────────────────────►
  │                                          ② ServerHello
  │                                             - 选定的 version/cipher_suite
  │                                             - server_random(32 字节)
  │                                          ③ Certificate（站点+中间证书）
  │                                          ④ ServerKeyExchange（ECDHE 参数 + 签名）
  │                                          ⑤ [CertificateRequest]（可选，双向认证）
  │  ◄────────────────────────────────────────────⑥ ServerHelloDone
  │ ⑦ ClientKeyExchange（客户端 ECDHE 公钥）
  │ ⑧ ChangeCipherSpec（"后面的数据要加密了"）
  │ ⑨ Finished（对握手 transcript 的校验值，加密）
  ├──────────────────────────────────────────────►
  │  ◄──────────────────────────────────────────── ⑩ ChangeCipherSpec + Finished
  │ 之后：应用数据（全部对称加密）
```

- **第一个 RTT**：协商版本/套件、拿证书、拿到服务端的 ECDHE 参数并验签；
- **第二个 RTT**：客户端发自己的 ECDHE 公钥，双方算出会话密钥，用 Finished 校验握手完整性；
- `Finished` 是对整段握手消息（transcript）的 HMAC，**任何中间人篡改**都会导致校验失败。

### 2.4 ECDHE 与前向安全

ECDHE（Ephemeral Elliptic Curve Diffie-Hellman，临时椭圆曲线密钥交换）的核心是 **DH 协商**：双方各生成一个临时私钥，交换对应的公钥，各自用自己的私钥和对方的公钥算出一个**相同的共享秘密**。

用一个极小的玩具参数（真实曲线是 256 位起的椭圆曲线）：

```
公开参数：素数 p = 23，生成元 g = 5
A 的临时私钥 a = 6   → A 的公钥 = 5^6 mod 23 = 8
B 的临时私钥 b = 15  → B 的公钥 = 5^15 mod 23 = 19
A 计算：19^6 mod 23 = 2
B 计算：8^15 mod 23 = 2      ← 共享秘密相同
```

窃听者只能看到 p、g、8、19，要反推出 a 或 b 需要解离散对数问题（真实参数下计算不可行）。**临时**的意思是：a、b 每次握手都重新生成，握手完就丢。

- **前向安全**：即使攻击者以后拿到了服务器的长期私钥（证书对应的私钥），也**无法解密历史流量**，因为会话密钥来自临时 ECDHE 私钥，而临时私钥早已销毁。
- 对比 **RSA 密钥交换**：客户端用服务器长期公钥加密 pre-master，服务器用长期私钥解密。攻击者只要事后拿到长期私钥，就能解开历史密文——**没有前向安全**。TLS 1.3 因此删掉了 RSA 密钥交换。

### 2.5 TLS 1.3：1-RTT 与 0-RTT

```
客户端                                              服务端
  │ ClientHello
  │   - supported_versions = 1.3
  │   - key_share = 客户端的 X25519 公钥
  │   - psk_key_exchange_modes（想复用/0-RTT 时带）
  │   - [early_data]（0-RTT 时带应用数据）
  ├──────────────────────────────────────────────►
  │ ServerHello（服务端的 key_share）
  │ + {EncryptedExtensions, Certificate, CertificateVerify, Finished}
  │   （除 ServerHello 外全部加密）
  │ Finished（客户端，加密）
  ├──────────────────────────────────────────────►
  │ 之后：应用数据
```

- **1-RTT 怎么做到的**：客户端在第一个 ClientHello 里就带 `key_share`（临时公钥），服务端回 ServerHello 时也带自己的 `key_share`，双方**立刻能算出共享密钥**，不再像 1.2 那样需要"客户端收到服务端参数后再回一个 ClientKeyExchange"的第二个往返。
- **证书也从第二个 flight 起加密**，中间人看不到站点证书内容（域名仍能在 SNI 中看到，除非用 ECH）。
- **0-RTT**：基于之前连接留下的 PSK（Pre-Shared Key，预共享密钥），客户端在 ClientHello 里直接带 `early_data`，第一个包就能发应用数据。代价是**可重放**：攻击者可以截获 early data 再重放一次，所以只对幂等操作（GET、静态资源）开放，服务端要配置 `ssl_early_data` 并做防重放（如 `Early-Data` 头）。
- **HelloRetryRequest**：如果客户端带的 `key_share` 不是服务端支持的那条曲线，服务端会回 HRR 让客户端重发，这一次退化成 2-RTT。现代客户端通常预发多个 key_share 避免这个情况。

### 2.6 会话复用：Session ID / Session Ticket / PSK

| 方式 | 做法 | 优点 | 缺点 |
|---|---|---|---|
| Session ID（TLS1.2） | 服务端缓存会话状态，客户端下次带 session_id | 简单 | 服务端内存、多机共享难 |
| Session Ticket（TLS1.2） | 服务端把会话状态**加密成 ticket** 交给客户端，下次带回 | 无状态、多机友好 | ticket key 泄露可解密会话 |
| PSK（TLS1.3） | 服务端用 NewSessionTicket 发 PSK，客户端下次带 `pre_shared_key` | 支持 1-RTT/0-RTT 复用 | 0-RTT 有重放风险 |

### 2.7 HTTPS 到底加密了哪部分

| 内容 | 是否加密 | 说明 |
|---|---|---|
| HTTP 请求行 / 头 / 体 | 加密 | TLS 加密的是应用数据 |
| HTTP/2 的帧 | 加密 | HTTP/2 跑在 TLS 之上 |
| 目标 IP、端口 | 不加密 | 网络层元数据，中间设备必须能看到 |
| SNI（域名） | TLS1.2 明文；TLS1.3 默认也明文 | 一个 IP 托管多站点时服务器靠它选证书；ECH（加密的 ClientHello 扩展）可隐藏 |
| TLS1.2 的证书内容 | 明文 | 所以能看到"访问了哪个站点" |
| TLS1.3 的证书内容 | 加密 | 握手后段全部加密 |
| 流量大小、时序 | 不加密 | 可被流量分析（如推断页面类型） |

### 2.8 OCSP stapling

OCSP（Online Certificate Status Protocol）用来查询证书是否被吊销。传统做法是**客户端**去 CA 查，会多一次网络请求、泄露访问隐私。**stapling** 是让**服务端**定期取 OCSP 响应并"钉"在握手消息里下发给客户端（TLS1.3 里是 Certificate 扩展），客户端无需外连 CA，省时延也保护隐私。Nginx 配 `ssl_stapling on; ssl_stapling_verify on;` 即可。

---

## 3. 完整推导

### 3.1 推导一：建连到底花了几个 RTT

| 场景 | TCP 握手 | TLS 握手 | 总 RTT（到能发应用数据） |
|---|---|---|---|
| HTTP 明文 | 1 | 0 | 1 |
| TLS1.2 完整握手 | 1 | 2 | 3 |
| TLS1.3 完整握手 | 1 | 1 | 2 |
| TLS1.3 会话复用 | 1 | 1（可复用可 0） | 2（或 1） |
| TLS1.3 0-RTT（复用） | 1 | 0 | 1（TCP 建连期间就能发数据） |

按 RTT = 30 毫秒（同城）和 150 毫秒（跨洋）估算：

```
同城：TLS1.2 = 3×30 = 90ms；TLS1.3 = 2×30 = 60ms；0-RTT = 30ms
跨洋：TLS1.2 = 3×150 = 450ms；TLS1.3 = 2×150 = 300ms；0-RTT = 150ms
```

这就是为什么"迁移到 TLS1.3 + 会话复用"对首屏体验有明显提升：省掉的是真金白银的 RTT。

### 3.2 推导二：TLS1.2 的密钥材料有多少字节

```
client_random = 32 字节
server_random = 32 字节
pre_master_secret = 48 字节（RSA 密钥交换时）
master_secret = PRF(pre_master_secret, "master secret", client_random + server_random) 取前 48 字节

写密钥块 = PRF(master_secret, "key expansion", server_random + client_random)
  → 需要 client_write_key + server_write_key + client_write_IV + server_write_IV
  以 AES-128-GCM 为例：2×16（key）+ 2×4（固定 IV） = 40 字节
```

所以握手交换的"随机数"本身不保密，真正的秘密来自 ECDHE 的共享点（或 RSA 加密的 pre_master）。TLS1.3 改为 HKDF（HMAC-based Key Derivation Function，基于 HMAC 的密钥派生函数）：

```
Handshake Secret = HKDF-Extract(Derive-Secret(Early, "derived", ""), ECDHE 共享密钥)
client_handshake_traffic_secret = Derive-Secret(Handshake Secret, "c hs traffic", transcript)
Master Secret = HKDF-Extract(Derive-Secret(Handshake, "derived", ""), 0)
```

每一阶段的密钥都和"当前握手 transcript 的哈希"绑定，任何报文被改，后续密钥就对不上、Finished 校验失败。

### 3.3 推导三：TLS 记录层的开销

TLS 记录（record）头 5 字节（类型 1 + 版本 2 + 长度 2）。以 AES-GCM 为例：

```
AES-GCM 的额外开销：显式 nonce 8 字节 + 认证标签 16 字节
单条记录最大明文 16 KiB（2^14）
开销占比 = (5 + 8 + 16) / (16384 + 5 + 8 + 16) ≈ 29 / 16413 ≈ 0.18%
```

也就是说"加密"本身在带宽上的额外开销不到 0.2%，HTTPS 的"慢"主要慢在握手 RTT 与非对称运算，而不是对称加密本身。

### 3.4 推导四：非对称运算有多贵

以服务端 RSA-2048 签名为例（数量级估算，硬件不同差异大）：

```
一次 RSA-2048 私钥签名：约 1~5 毫秒（单核）
一次 ECDSA P-256 签名：约 0.1~0.5 毫秒
一次 AES-GCM 加密 16 KiB：约 10~30 微秒（有 AES-NI）
```

按这个比例，**用非对称加密传数据比对称慢 2~3 个数量级**；这也是"混合加密"的根本原因——握手只做几次非对称运算，数据全程用对称。

---

## 4. 极简模型：用两个同学传纸条理解 TLS

把 TLS 想象成两个同学要在教室里传纸条，怕被别人看：

1. **身份**：A 有一张"学校盖章的身份卡"（证书），卡上有 A 的公钥；B 手里有"学校公章的真伪对照表"（根 CA 信任库），能验证身份卡上的章是不是真的。
2. **换钥匙**：两人各自在纸条上写一个只有自己知道的数字，按约定公式混合成同一个"暗号"（DH）。即使纸条被别人看到，也算不出这个"暗号"（离散对数难题）。
3. **传内容**：之后所有纸条都用这个"暗号"对应的对称密码加密，并附一个校验码（AEAD 的认证标签），改一个字都会被发现。

TLS1.2 的流程像：

```
A → B：我支持这些密码本，我的随机数 R1
B → A：选这套密码本，我的随机数 R2，我的身份卡，我的换钥匙参数（签名）
A → B：我的换钥匙参数
（双方算出暗号，之后加密说话）
```

相当于"先把身份卡和参数递过去，再确认一次"，所以两个来回。TLS1.3 把"我的换钥匙参数"提前到第一张纸条里：

```
A → B：我支持 TLS1.3，我的换钥匙参数，我的随机数
B → A：我的换钥匙参数 + 加密后的身份卡和完成校验
（之后直接加密说话）
```

一个来回搞定。

---

## 5. 为什么这样设计：被否决的方案

### 5.1 方案 A：全部用对称加密（被否决）

- 优点：最快
- 否决原因：密钥分发问题无解——双方第一次通信时如何安全地共享密钥？把密钥明文发过去会被窃听。
- 现实中的例外：预共享密钥（PSK）场景（如企业内网、物联网设备预置密钥），但无法适用于公开互联网。

### 5.2 方案 B：全部用非对称加密（被否决）

- 优点：无需协商对称密钥
- 否决原因：慢 2~3 个数量级；RSA 还有长度限制（一次只能加密比模数短的块）；很容易被流量分析。

### 5.3 方案 C：不做证书，裸做 DH 协商（被否决）

- 优点：少一次证书传输与验证
- 否决原因：**中间人可以同时和两边做 DH**，双方以为在和对方通信，实际都在和攻击者通信（经典 MITM）。必须有"认证"这一步。

### 5.4 方案 D：用长期密钥直接做 ECDH，不生成临时密钥（被否决）

- 优点：可以省掉签名步骤，甚至做到 0-RTT
- 否决原因：没有前向安全——长期私钥一旦泄露，历史流量全部可解。TLS1.3 明确要求"前向安全的密钥交换"。

### 5.5 方案 E：取消 CA，全靠自签 + 第一次信任（TOFU，被否决）

- 优点：无中心化、无证书费
- 否决原因：规模化不可行（用户不可能每次手动确认指纹），且无法应对首次连接即被中间人的场景。SSH 的 known_hosts 是 TOFU 的小范围应用，不适合 Web。

### 5.6 一句话取舍

| 方案 | 安全 | 性能 | 适用 |
|---|---|---|---|
| 纯对称 | 低（密钥分发） | 最高 | 预共享密钥场景 |
| 纯非对称 | 高 | 最差 | 仅用于密钥交换/签名 |
| 无证书 DH | 低（MITM） | 高 | 不可用 |
| TLS 混合 | 高 | 好 | 互联网标准 |

---

## 6. 关键参数为什么是这个值

| 参数 | 常见值 | 为什么是这个值 |
|---|---|---|
| RSA 密钥长度 | 2048 位（4096 更安全但更慢） | 2048 位在可预见的算力下安全，且性能可接受；4096 位签名慢数倍 |
| ECDSA / ECDHE 曲线 | P-256、X25519 | 256 位椭圆曲线约等于 3072 位 RSA 的安全性，且运算快、密钥短 |
| 对称套件 | AES-128-GCM / ChaCha20-Poly1305 | 128 位对称密钥已足够安全；ChaCha20 在无 AES 硬件加速的移动端更快 |
| TLS 记录最大明文 | 16 KiB（2^14） | 兼顾吞吐与内存；太大则单条记录重传代价高 |
| 证书有效期 | 90 天（自动化签发趋势） | 缩短泄露窗口，配合 ACME 自动续期 |
| Session Ticket 生命周期 | 数小时~数天 | 太长则 ticket key 泄露影响面大，太短则复用率低 |
| OCSP 响应有效期 | 数天 | 平衡吊销信息及时性与服务端缓存成本 |
| `ssl_session_cache` | 10 MB shared | 约可缓存 4 万个会话，够中小规模服务使用 |
| HTTP/2 最大流数 | 2^31-1（实现常限制 100~1000） | 防止单连接被无限流打爆内存 |

---

## 7. 版本演进

### 7.1 协议版本

| 版本 | 年份 | 关键变化 |
|---|---|---|
| SSL 2.0/3.0 | 1995/1996 | 已废弃，存在严重漏洞（POODLE 等） |
| TLS 1.0（RFC 2246） | 1999 | 标准化，2021 年被主流浏览器禁用 |
| TLS 1.1 | 2006 | 修 CBC 相关缺陷，仍被禁用 |
| TLS 1.2（RFC 5246） | 2008 | 支持 AEAD、SHA-256、ECDHE；目前仍是兼容性基线 |
| TLS 1.3（RFC 8446） | 2018 | 1-RTT/0-RTT、删除 RSA 密钥交换与 CBC、加密握手、强制前向安全 |

### 7.2 TLS 1.2 → 1.3 的取舍

| 维度 | TLS 1.2 | TLS 1.3 |
|---|---|---|
| 握手 RTT | 2 | 1（复用可 0） |
| 密钥交换 | RSA / DHE / ECDHE | 只有 (EC)DHE，强制前向安全 |
| 对称算法 | 含 CBC、RC4 等 | 只保留 AEAD（AES-GCM、ChaCha20） |
| 握手加密 | 后半段才加密 | 除 ServerHello 外全加密 |
| 会话复用 | Session ID / Ticket | PSK |
| 证书压缩 | 无 | 有（压缩证书链） |

### 7.3 实现生态

- OpenSSL 1.1.1 起完整支持 TLS1.3；OpenSSL 3.x 引入 provider 架构
- JDK 11 起支持 TLS1.3；JDK 8 较新更新也支持（需确认具体版本）
- Nginx 1.13+ 支持 TLS1.3
- 国密 TLS（SM2/SM3/SM4）在国内部分场景使用，采用双证书体系，与国际标准 TLS 并行演进

---

## 8. 亲手验证：openssl 与抓包

> 说明：以下命令在 OpenSSL 3.x + Linux 环境执行；不同 OpenSSL 版本输出字段略有差异，以实际为准。部分命令需要联网，若无法联网可对本地自建服务测试。

### 8.1 看一次 TLS1.3 握手的结果

```bash
openssl s_client -connect example.com:443 -servername example.com -tls1_3 -brief
```

预期输出（节选）：

```
Connecting to 93.184.216.34
CONNECTION ESTABLISHED
Protocol version: TLSv1.3
Ciphersuite: TLS_AES_256_GCM_SHA384
Peer certificate: CN = example.com
Verification: OK
```

把 `-tls1_3` 换成 `-tls1_2`，会看到 `Protocol version: TLSv1.2` 与不同的套件。

### 8.2 逐条看握手报文

```bash
openssl s_client -connect example.com:443 -servername example.com -msg </dev/null 2>/dev/null | head -60
```

预期输出（节选）：

```
<<< TLS 1.3, Handshake [length 00c8], ClientHello
    ...
    extensions: server_name, supported_versions, key_share, ...
>>> TLS 1.3, Handshake [length 007a], ServerHello
    ...
    extensions: key_share
```

可以看到 ClientHello 里带了 `key_share`（这是 TLS1.3 能 1-RTT 的关键），而 TLS1.2 的 ClientHello 里没有。

### 8.3 看证书链与域名

```bash
echo | openssl s_client -connect example.com:443 -showcerts 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
```

预期输出（节选）：

```
subject=CN = example.com
issuer=C = US, O = ..., CN = ...
notBefore=...
notAfter=...
X509v3 Subject Alternative Name:
    DNS:example.com, DNS:www.example.com
```

链不完整的站点会在握手时直接报 `unable to get local issuer certificate`。

### 8.4 量一下非对称运算有多慢

```bash
openssl speed rsa2048 ecdsap256        # 对比 RSA-2048 与 ECDSA P-256 的签名/验证速度
```

预期：ECDSA P-256 的签名速度通常是 RSA-2048 的数倍到十几倍（具体取决于 CPU）。

### 8.5 验证 HTTPS 加密了什么

```bash
# 抓包看 SNI 是否明文（TLS1.3 默认仍是明文）
sudo tcpdump -i any -nn -A 'tcp port 443' -c 5 | grep -i 'example.com'
```

预期：能在 ClientHello 里看到明文域名（SNI）。而 HTTP 的 `GET /` 与 `Host` 头在 TLS1.3 下不可见（只能看到加密的应用数据记录）。

---

## 9. 常见误区

| 错误说法 | 正确说法 |
|---|---|
| 「HTTPS 把所有东西都加密了」 | 只加密 HTTP 内容；IP、端口、SNI 域名、流量大小仍可见（ECH 可隐藏 SNI） |
| 「HTTPS 用非对称加密传数据」 | 数据用对称加密传；非对称只用于认证与换密钥 |
| 「TLS1.3 的 0-RTT 没有风险」 | 0-RTT 可被重放，只适合幂等请求，服务端要做防重放 |
| 「证书里包含私钥」 | 证书只有公钥与身份信息；私钥只在服务端，签名用它 |
| 「自签证书加密强度不够」 | 加密强度不差，问题是**身份无法被第三方验证**，容易被中间人 |
| 「OCSP stapling 是客户端去 CA 查吊销」 | 是服务端代取并随握手下发，客户端省请求且保护隐私 |
| 「会话复用不安全，应该每次完整握手」 | 复用是标准优化；风险在 ticket key 管理，而不是复用本身 |
| 「TLS1.3 只是性能优化，安全性差不多」 | 它还删掉了不安全的 RSA 密钥交换与 CBC 套件，强制前向安全 |
| 「证书链越多越安全」 | 链越长传输与验证成本越高；信任来自根 CA，不来自中间证书数量 |

---

## 10. 连续追问 Q&A

### Q1：为什么证书能证明服务器的身份？

证书由受信任的 CA 用其私钥签名，内容是"这个公钥属于这个域名"。客户端用本地信任库里的根 CA 公钥逐级验签，链路通了就说明"某个受信任的 CA 愿意为这个公钥背书"。攻击者拿不出受信任 CA 的签名，就伪造不了证书。

### Q2：TLS1.3 为什么能 1-RTT？

因为客户端在第一个 ClientHello 里就带了 `key_share`（ECDHE 公钥），服务端回自己的 key_share 后双方立刻算出共享密钥，不需要像 TLS1.2 那样再等一个 ClientKeyExchange 往返。证书与 Finished 也从第二个 flight 起加密发送。

### Q3：0-RTT 的重放风险具体怎么利用？

攻击者录下客户端发的 0-RTT 应用数据（比如一个"点赞"请求），之后原样重放给服务端。因为是复用 PSK，服务端无法区分是第一次还是重放。所以只允许幂等请求用 0-RTT，并配合时间窗口/防重放缓存。

### Q4：为什么 TLS1.3 删掉了 RSA 密钥交换？

RSA 密钥交换没有前向安全：攻击者只要事后拿到服务器长期私钥，就能解密历史流量。TLS1.3 要求所有密钥交换都具备前向安全，因此只保留 (EC)DHE。

### Q5：前向安全和加密强度是一回事吗？

不是。加密强度是"当前破解难度"；前向安全是"长期私钥泄露后历史会话是否还能被解"。AES-256 很强，但如果会话密钥能由长期私钥推出，历史流量依然可解。

### Q6：中间人攻击在什么条件下能成功？

关键是"客户端信任了攻击者的证书"：用户手动安装了攻击者的根证书（企业代理/恶意软件）、CA 被攻破、或者用户点了"继续访问"忽略证书错误。加密协议本身不能解决"用户主动放弃验证"。

### Q7：证书固定（pinning）是什么？为什么浏览器一般不做？

客户端内置服务端证书/公钥的指纹，不匹配就拒绝，能防"被信任的 CA 乱签"。但证书轮换时客户端要更新、发版，运维成本高，所以 App 用得多，浏览器主要靠 HSTS + CT（Certificate Transparency）审计。

### Q8：为什么 HTTPS 还需要 HSTS？

HTTPS 本身不阻止用户输入 `http://` 或点击 http 链接，首次访问可能被劫持（SSL Strip）。HSTS 让浏览器记住"这个站点只走 HTTPS"，后续强制跳转。

### Q9：TLS1.2 的握手为什么是 2-RTT，能不能优化？

1.2 的流程要求"客户端拿到服务端参数后才能发自己的密钥交换"，所以至少两个往返。优化手段：会话复用（Session ID/Ticket 减少到 1-RTT）、TLS1.3（结构上改成 1-RTT）、0-RTT（复用 + early data）。

### Q10：为什么抓包还能看到我访问的域名？

因为 SNI（Server Name Indication）是 ClientHello 里的明文扩展，服务器靠它选择证书。要隐藏需要 ECH（Encrypted Client Hello），目前部署还不普遍。此外 DNS 查询通常也是明文（除非 DoH/DoT）。

### Q11：OCSP stapling 失败会怎样？

服务端取不到 OCSP 响应时，一般会不带 stapling 继续握手（客户端可以选择自己去查或直接信任证书有效期）；严格模式下某些客户端会拒绝。生产要监控 stapling 是否生效。

### Q12：证书过期了会怎样？怎么避免？

浏览器直接报错，API 客户端抛异常。避免：自动化续期（ACME）、提前 30 天告警、证书有效期缩短到 90 天并配自动化、灰度环境也配监控。

### Q13：HTTP/2 和 TLS 是什么关系？

HTTP/2 规范要求实际部署必须基于 TLS（浏览器强制 h2 over TLS），通过 ALPN 协商。HTTP/3 则把传输换成 QUIC，TLS1.3 内嵌在 QUIC 里，不再是"TCP + TLS"的分层。

---

## 11. 一张图总结

```
TLS 的组成
  身份认证：证书链（站点 → 中间 CA → 根 CA）
  密钥交换：ECDHE（临时密钥，前向安全）
  数据加密：AEAD 对称加密（AES-GCM / ChaCha20-Poly1305）

TLS1.2（2-RTT）                         TLS1.3（1-RTT）
  C → S  ClientHello                      C → S  ClientHello + key_share
  S → C  ServerHello/Cert/SKE/Done        S → C  ServerHello + encrypted
  C → S  CKE/CCS/Finished                        {Cert, CertVerify, Finished}
  S → C  CCS/Finished                     C → S  Finished（加密）
  应用数据                                 应用数据
  ↑ 多了"客户端回密钥交换"的往返            ↑ 密钥交换材料提前，省一个往返

HTTPS 加密范围
  加密：HTTP 内容、HTTP/2 帧、TLS1.3 的证书
  明文：IP、端口、SNI 域名、流量大小与时间
```

---

## 12. 一句话复盘

> TLS 用证书链证明"对端是谁"，用 ECDHE 临时密钥交换协商出会话密钥（因此具备前向安全），再用对称 AEAD 加密数据。TLS1.2 因为要等客户端回密钥交换而需要 2-RTT；TLS1.3 把 key_share 提前到 ClientHello 并联手加密握手消息，做到 1-RTT，复用 PSK 时可 0-RTT（但有重放风险）。HTTPS 加密的是内容，不是连接的全部元数据。

---

## 13. 自测题（先自己答，再看答案）

**1. TLS 的"混合加密"分别用非对称和对称做什么？**
答案：非对称用于身份认证（证书签名/验签）与密钥交换（ECDHE），协商出会话密钥；对称用于加密应用数据。原因是非对称安全但慢，对称快但密钥分发难。

**2. TLS1.2 完整握手为什么是 2-RTT？TLS1.3 怎么省掉一个？**
答案：1.2 需要"客户端收到服务端参数后再发 ClientKeyExchange"这一往返；1.3 让客户端在 ClientHello 里就带 key_share，服务端回自己的后双方立刻算出密钥，省掉一个往返。

**3. 前向安全是什么？ECDHE 为什么能做到？**
答案：长期私钥泄露后历史会话仍不可解。ECDHE 每次握手生成临时私钥、用完即弃，会话密钥不依赖长期私钥，所以事后拿到长期私钥也解不开。

**4. 0-RTT 的风险是什么？什么场景能用？**
答案：可被重放。只适合幂等请求（GET、静态资源），服务端要配防重放策略。

**5. HTTPS 哪些内容仍然明文可见？**
答案：目标 IP、端口、SNI 域名（TLS1.2/1.3 默认）、流量大小与时间；TLS1.2 的证书内容也明文，TLS1.3 证书加密。

**6. 证书链不完整会导致什么错误？为什么？**
答案：客户端报 `unable to get local issuer certificate` 或 unknown CA；因为中间证书缺失，客户端无法把站点证书的签名连到本地信任的根 CA 上。

---

## 14. 关联文件

- 深一层（协议细节与调优）：[TLS 与 HTTPS 握手](../../10-deep-dive/network/02-TLS与HTTPS握手.md)
- 相关精讲：[TCP 三次握手四次挥手](./01-TCP三次握手四次挥手.md)｜[Kafka 零拷贝](../middleware/01-Kafka零拷贝.md)
- 返回：[精讲索引](../00-索引.md)
