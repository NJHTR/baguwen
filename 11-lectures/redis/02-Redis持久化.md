# Redis 持久化：内存数据库断电了，数据还在吗？

> 精讲层级：从「零基础能看懂」到「fork + COW + AOF 重写时序级」，每个名词都拆开
> 阅读时间：约 35 分钟
> 配套速查：[持久化与淘汰（深度追问）](../../10-deep-dive/redis/02-持久化与淘汰.md)
> 返回：[精讲索引](../00-索引.md)

---

## 0. 一句话先讲明白

Redis 是内存数据库，断电内存就没了，所以需要两套落到磁盘的机制：
**RDB（Redis DataBase）**：定时 fork 一个子进程，把内存数据写成二进制快照。文件小、恢复快，但两次快照之间的数据会丢。
**AOF（Append Only File）**：把每条写命令追加到日志文件，按 `appendfsync` 策略决定什么时候刷盘（fsync）。数据安全，但文件大、恢复慢。
Redis 4.0 起支持**混合持久化**：AOF 重写时前半段用 RDB 格式、后半段是增量命令，兼顾恢复速度与完整性。
另外，内存有限，过期键要靠「惰性删除 + 定期删除」回收，内存满时按 `maxmemory-policy` 的 8 种策略淘汰。

---

## 1. 痛点背景：三个必须回答的问题

### 1.1 问题一：重启之后数据还在吗

Redis 把数据放在内存里，进程一重启，内存清零。如果没有任何持久化：

- 缓存场景：重启后缓存全空，所有请求瞬间打到数据库，可能把数据库打挂（缓存雪崩的一种）；
- 存储场景（比如用 Redis 存会话、排行榜）：数据直接丢失。

### 1.2 问题二：持久化会不会拖慢 Redis

- 如果每次写命令都同步写磁盘（fsync），单条命令的延迟从 0.1ms 涨到 1ms 以上，QPS 直接降一个量级；
- 如果异步写，断电时又可能丢数据。

**持久化的本质是「性能」与「数据安全」的取舍**——所有持久化参数，都是在这条线上选一个点。

### 1.3 问题三：内存满了怎么办

- Redis 的内存是有限的（`maxmemory` 可以设置上限）；
- 写满之后不能简单报错（业务会挂），也不能随便删（可能删掉重要数据）；
- 所以要有一套**淘汰策略（eviction policy）**，按规则决定删谁。

### 1.4 数字推导：RDB 文件能比内存小多少

- 内存里一个 100 万 key 的实例，每 key 平均 100B（含结构开销）→ 内存占用约 100MB；
- RDB 是紧凑二进制 + LZF 压缩，典型能压到内存的 50%~70%，即约 50~70MB；
- 所以「RDB 文件大小 ≈ 内存数据量的一半到一个量级之内」，恢复时反序列化回内存。

---

## 2. 逐步拆解：RDB、AOF、过期、淘汰

### 2.1 RDB 的触发时机

| 方式 | 命令/配置 | 特点 |
|---|---|---|
| 同步保存 | `SAVE` | 阻塞主线程，生产禁用 |
| 后台保存 | `BGSAVE` | fork 子进程，主线程几乎不阻塞 |
| 自动保存 | `save 900 1`（900 秒内至少 1 次写）、`save 300 10`、`save 60 10000`（6.x 默认；7.0 改为 3600 1 / 300 100 / 60 10000） | 默认三条规则 |
| 关闭时 | `SHUTDOWN`（若开启 save） | 正常退出会存一次 |
| 主从同步 | 从库全量同步时主库生成 RDB | 复制的基础 |

### 2.2 fork + COW：RDB 的核心机制

`fork()` 是操作系统调用，创建一个子进程。Redis 用它做快照，关键在于**写时复制（COW，Copy-On-Write）**：

```
fork 瞬间：
父进程内存页 ──┐
               ├── 物理页（只读共享）
子进程内存页 ──┘

父进程写某页时：
内核复制该页 → 父进程写新页，子进程仍读旧页
```

流程：

1. 主进程 `fork()` 出子进程（**只复制页表，不复制物理内存**）；
2. 子进程遍历内存，把数据写进 RDB 文件；
3. 主进程继续处理命令，写操作触发 COW 复制对应页；
4. 子进程写完，RDB 文件落盘完成。

**代价一：fork 本身会阻塞主线程**。
数字推导：10GB 的 Redis 实例，页 4KB → `10GB / 4KB = 262 万` 个页；每个页表项约 8B → 页表约 `262 万 × 8B = 21MB`。复制 21MB 页表通常需要几十毫秒，这期间主线程是停的。

**代价二：COW 会导致内存膨胀**。
父进程写入的页越多，被复制的页越多。极端情况（全量写）内存接近翻倍；`INFO memory` 里的 `rdb_last_cow_size` 能看上次 fork 的 COW 量。

### 2.3 AOF 的三步与三种 fsync 策略

AOF 记录的是**写命令**（RESP 协议），流程：

```
写命令 → 追加到 aof_buf（内存缓冲）→ write() 到文件 → fsync() 刷盘
```

| `appendfsync` | 行为 | 最多丢多少 | 性能 |
|---|---|---|---|
| `always` | 每条命令都 fsync | 几乎不丢（0） | 最差 |
| `everysec`（默认） | 后台每秒 fsync 一次 | 约 1 秒 | 好 |
| `no` | 交给操作系统刷盘 | 不确定（内核决定） | 最好 |

**数字推导**：假设写 TPS 5 万，`everysec` 下最坏丢 1 秒 = **5 万条命令**；换成 `always`，每条命令一次 fsync（假设 1ms），单线程 QPS 上限约 1000——差 50 倍。所以默认 `everysec` 是「丢 1 秒」换「50 倍吞吐」。

### 2.4 AOF 重写：为什么需要、怎么做

**为什么需要**：AOF 是追加写，同一个 key 被改 100 次就会留下 100 条命令。数字：每次 SET 约 100B，100 条 = 10KB；重写后只保留最终值 1 条（约 100B），**缩小 100 倍**。

**重写流程**：

```
父进程 fork 子进程
 ├── 子进程：遍历内存，生成「最小命令集」写入新 AOF 文件
 └── 父进程：继续处理命令，把新命令同时写入「AOF 重写缓冲区」（不能丢）
子进程写完 → 父进程把重写缓冲区追加到新 AOF 尾部 → 原子替换旧文件
```

**为什么需要重写缓冲区**：子进程写新文件的期间，父进程可能又改了数据；这些新命令如果不记录，重写后的 AOF 就少了数据。

**空间代价**：重写期间旧 AOF + 新 AOF + 重写缓冲区同时存在，磁盘占用约为原来的 2 倍。

### 2.5 混合持久化

配置 `aof-use-rdb-preamble yes`（4.0+，7.0 默认开启）：

- AOF 重写时，新文件**前半段是 RDB 格式**（加载快），后半段是重写期间的增量命令（保证完整）；
- 恢复时先加载 RDB 部分，再重放增量命令。

### 2.6 过期键删除：惰性 + 定期

| 策略 | 做法 | 优点 | 缺点 |
|---|---|---|---|
| 惰性删除 | 访问 key 时检查是否过期，过期就删并返回 nil | 省 CPU | 没人访问的 key 永远占内存 |
| 定期删除 | 每 100ms 抽样检查过期 key | 兜底回收 | 抽样不保证全删 |
| 定时器 | 每个 key 一个定时器 | 精确 | 内存/CPU 开销太大，Redis 不用 |

**定期删除的参数（数字推导）**：`activeExpireCycle` 每轮从过期字典随机抽 **20 个** key，删除其中过期的；如果过期比例 **超过 25%**，说明还有大量过期 key，继续抽下一轮（受时间上限限制，避免阻塞主线程）。

- 每秒 10 轮 × 20 个 = 200 个 key 被检查；
- 如果 100 万个 key 都过期，理论需要 `100 万 / 200 × (1/25%) ≈ 2 万秒`？——不对，因为比例高时会连续抽多轮直到降下来，实际会快得多；但这也说明「大量 key 同时过期」会给主线程带来压力，所以业务要加随机 TTL。

### 2.7 8 种淘汰策略逐个说

| 策略 | 淘汰范围 | 规则 | 适用 |
|---|---|---|---|
| `noeviction`（默认） | 不淘汰 | 写命令返回 OOM 错误 | 数据不能丢 |
| `allkeys-lru` | 所有 key | 近似 LRU（最久未使用） | 纯缓存，最常用 |
| `allkeys-lfu` | 所有 key | 最不经常使用 | 有热点数据 |
| `allkeys-random` | 所有 key | 随机 | 访问均匀 |
| `volatile-lru` | 设了 TTL 的 key | 近似 LRU | 缓存与持久数据混存 |
| `volatile-lfu` | 设了 TTL 的 key | LFU | 同上 |
| `volatile-random` | 设了 TTL 的 key | 随机 | 同上 |
| `volatile-ttl` | 设了 TTL 的 key | 剩余 TTL 最短优先 | 优先清快过期的 |

**近似 LRU**：Redis 不维护全局 LRU 链表，而是每个 key 记录 24 位时钟；淘汰时随机采样 `maxmemory-samples`（默认 5）个 key，挑最久未用的。采样越多越接近精确 LRU。

**LFU**：复用 24 位 lru 字段（8 位访问计数 + 16 位衰减时间，单位分钟），按 `lfu-log-factor` 增长、`lfu-decay-time` 衰减，解决「偶发访问把老热点顶掉」的问题。

---

## 3. 完整推导：RDB 与 AOF 怎么选（量化对比）

### 3.1 数据安全对比（丢多少）

| 配置 | 最多丢 |
|---|---|
| 只开 RDB，`save 60 10000` | 最多 60 秒内、或 1 万次写之后的数据 |
| 只开 AOF，`everysec` | 约 1 秒 |
| AOF `always` | 几乎不丢 |
| 混合持久化 + everysec | 约 1 秒（RDB 部分不丢，丢失的是增量） |

### 3.2 恢复速度对比（数字）

- RDB 恢复：直接反序列化二进制，100 万 key 约几秒；
- AOF 恢复：要逐条重放命令，同样 100 万 key 可能几十秒到几分钟；
- 混合持久化：前段 RDB 快加载 + 后段少量增量，接近 RDB 的速度。

### 3.3 文件大小对比（数字）

- RDB：紧凑 + 压缩，约为内存的 50%~70%；
- AOF：命令文本，同 key 多次修改会累积，重写前可能是内存的 2~5 倍；重写后接近内存大小。

### 3.4 COW 内存峰值推导

场景：10GB 实例，BGSAVE 期间父进程持续写入，约 50% 的页被修改。

- COW 复制的页 ≈ `10GB × 50% = 5GB`；
- 进程内存峰值 ≈ `10GB（父）+ 5GB（子进程看到的旧页副本被父进程复制）`，实际总内存可能到 15GB 左右；
- 再叠加 AOF 重写或其他子进程，风险更大。

所以大内存实例要：错峰做 BGSAVE、控制写流量、关闭 THP（透明大页会让 COW 一次复制 2MB 而不是 4KB）。

### 3.5 结论

| 场景 | 推荐 |
|---|---|
| 纯缓存，丢数据可接受 | 只开 RDB，或干脆不开 |
| 有会话/计数等不能丢的数据 | AOF everysec + 定期 RDB 备份 |
| 金融级不能丢 | AOF always + 双副本 + 定期 RDB 归档 |

---

## 4. 极简模型：3 个 key 的 RDB 和 AOF

### 4.1 数据

```
SET user:1 "tom"
SET user:2 "jerry"
SET count 100
```

### 4.2 RDB 文件里是什么（概念示意）

```
"REDIS" + 版本号
+ 数据库 0
+ key=user:1, type=string, value="tom"
+ key=user:2, type=string, value="jerry"
+ key=count,  type=string, value=100
+ EOF + CRC64 校验
```

二进制存放，不重复记录历史值，只存最终状态。

### 4.3 AOF 文件里是什么

```
*3\r\n$3\r\nSET\r\n$6\r\nuser:1\r\n$3\r\ntom\r\n
*3\r\n$3\r\nSET\r\n$6\r\nuser:2\r\n$5\r\njerry\r\n
*3\r\n$3\r\nSET\r\n$5\r\ncount\r\n$3\r\n100\r\n
```

每条写命令都是 RESP 协议文本，重放就是按顺序执行。

### 4.4 如果 `SET count 100` 执行了 100 次

- AOF 文件里 100 条命令（约 10KB）；
- 重写后只剩 1 条（约 100B）；
- RDB 里本来就只有 1 份最终值。

---

## 5. 为什么这样设计：四个被否决的方案

### 5.1 否决方案一：只做 RDB

- 两次快照之间的数据全丢（可能几十秒、上万条写）；
- 对「会话、计数、排行榜」这类数据不可接受。

### 5.2 否决方案二：只做 AOF

- 文件大、恢复慢（逐条重放）；
- 早期 AOF 的写放大和重写逻辑复杂；
- 一旦 AOF 文件损坏，恢复可能失败（虽然有 `aof-load-truncated` 容错）。

### 5.3 否决方案三：每条命令都 fsync（always）

- 性能从每秒几万降到几千（每条一次磁盘 fsync）；
- 磁盘寿命也会受影响；
- 所以默认用 `everysec`，把风险控制在 1 秒。

### 5.4 否决方案四：用定时器精确删除过期 key

- 每个 key 一个定时器，内存和 CPU 开销太大；
- Redis 单线程，定时器会打散命令处理；
- 选择「惰性 + 定期抽样」，成本低且够用。

### 5.5 否决方案五：内存满了直接拒绝写入（只有 noeviction）

- 缓存场景下会导致业务大面积报错；
- 所以提供 LRU/LFU 等淘汰策略，把「不可用」变成「少部分缓存失效」。

---

## 6. 关键参数为什么是这个值

### 6.1 `appendfsync` 为什么默认 everysec

`always` 太慢（每条 fsync），`no` 丢多少不可控；`everysec` 是「最多丢 1 秒」和「吞吐」的折中，也是绝大多数业务能接受的安全线。

### 6.2 `save` 规则为什么是 900/1、300/10、60/10000

三条规则分别覆盖「低频写」「中频写」「高频写」：

- 900 秒有 1 次写就存（低频）；
- 300 秒 10 次（中频）；
- 60 秒 1 万次（高频）。

阈值是经验值，目标是「数据变化量」和「快照频率」的平衡。

### 6.3 `auto-aof-rewrite-percentage 100` / `auto-aof-rewrite-min-size 64mb`

- 增长 100%（即 AOF 文件比上次重写后大一倍）才触发重写，避免频繁 fork；
- 最小 64MB 才触发，避免小文件频繁重写；
- 数字：如果重写后 AOF 是 100MB，涨到 200MB 才再次触发。

### 6.4 `maxmemory-samples` 为什么默认 5

- 采样 5 个 key 挑最久未用，已经能近似 LRU；
- 采样数越大越精确，但每次淘汰的计算量线性增加；
- 5 是「精度」与「CPU」的折中。

### 6.5 `maxmemory` 应该设多少

- 至少预留 20%~30% 给 fork/COW、复制缓冲区、客户端缓冲区；
- 例：机器 16GB，Redis 数据建议 `maxmemory` 别超过 10~12GB，否则 BGSAVE 时容易 OOM。

---

## 7. 版本演进：Redis 2.8 → 7.x

| 版本 | 持久化相关变化 |
|---|---|
| Redis 2.8 | AOF 重写使用「子进程 + 重写缓冲区」方案（现代 AOF 重写的基础） |
| Redis 3.0 | 引入 Cluster（与持久化无直接关系，但影响高可用设计） |
| Redis 4.0 | **混合持久化**（`aof-use-rdb-preamble`）；引入模块与 LFU |
| Redis 5.0 | Stream 类型；`BGREWRITEAOF` 调度优化 |
| Redis 6.0 | 多线程 IO；`io-threads` 可配 |
| Redis 7.0 | **多部分 AOF（Multi Part AOF）**：manifest + base + incr 文件，替代单文件重写缓冲区；混合持久化默认开启 |

7.0 的多部分 AOF 把「重写缓冲区」那套逻辑改成「子进程写 base、父进程继续写 incr，最后更新 manifest 原子切换」，更简单也更安全。

---

## 8. 亲手验证：看配置、触发持久化、模拟过期

> 环境说明：Redis 7.x 预期如下；Redis 6 没有 `#innodb` 无关项，AOF 目录结构不同（单文件）。

```bash
# 1. 看持久化配置
redis-cli CONFIG GET appendonly
# 预期：appendonly no（AOF 默认不开启，需要手动打开或改配置）

redis-cli CONFIG GET appendfsync
# 预期：appendfsync everysec

redis-cli CONFIG GET save
# 预期：save 3600 1 300 100 60 10000（7.0 默认值随版本略有差异）

redis-cli CONFIG GET aof-use-rdb-preamble
# 预期：aof-use-rdb-preamble yes

# 2. 手动触发并观察
redis-cli BGSAVE
# 预期：Background saving started

redis-cli INFO persistence
# 预期：rdb_bgsave_in_progress:0、rdb_last_bgsave_status:ok、
#       aof_enabled:0（若没开 AOF）、rdb_last_cow_size 等

# 3. 打开 AOF 并观察（会触发一次重写）
redis-cli CONFIG SET appendonly yes
redis-cli INFO persistence
# 预期：aof_enabled:1、aof_rewrite_in_progress:0

redis-cli BGREWRITEAOF
# 预期：Background append only file rewriting started

# 4. 看 AOF 目录（7.0 多部分 AOF）
ls /var/lib/redis/appendonlydir/
# 预期：appendonly.aof.manifest、appendonly.aof.1.base.rdb、appendonly.aof.1.incr.aof

# 5. 过期键验证
redis-cli SET k1 v1 EX 2
redis-cli TTL k1
# 预期：2（或 1）

sleep 3
redis-cli GET k1
# 预期：(nil)

redis-cli INFO keyspace
# 预期：过期 key 不计入 keys 统计

# 6. 淘汰配置与观察
redis-cli CONFIG GET maxmemory
# 预期：0（不限制）

redis-cli CONFIG GET maxmemory-policy
# 预期：noeviction

redis-cli CONFIG SET maxmemory 100mb
redis-cli CONFIG SET maxmemory-policy allkeys-lfu
redis-cli INFO stats | grep evicted_keys
# 预期：evicted_keys 会随内存压力上升
```

### 8.1 Java 侧看持久化状态

```java
try (Jedis jedis = new Jedis("127.0.0.1", 6379)) {
    jedis.info("persistence").lines()
        .filter(l -> l.startsWith("rdb_last_bgsave_status")
                  || l.startsWith("aof_enabled")
                  || l.startsWith("rdb_last_cow_size"))
        .forEach(System.out::println);
}
```

---

## 9. 常见误区

| 错误说法 | 正确说法 |
|---|---|
| 「RDB 不会丢数据」 | 两次快照之间的数据会丢 |
| 「AOF everysec 丢 0 数据」 | 最多丢约 1 秒 |
| 「fork 会复制全部内存」 | 只复制页表，物理页 COW 共享 |
| 「AOF 重写会阻塞主线程」 | 子进程做重写，fork 瞬间短暂阻塞 |
| 「Redis 用定时器删过期 key」 | 惰性 + 定期抽样，没有每 key 定时器 |
| 「LRU 是精确的」 | 采样近似 LRU，`maxmemory-samples` 控制精度 |
| 「noeviction 会删数据」 | 不淘汰，写命令直接报 OOM |
| 「RDB 和 AOF 只能二选一」 | 4.0+ 可混合持久化，也可以同时开 |
| 「AOF always 是零丢失」 | 操作系统/磁盘缓存仍可能丢最后一条，只是窗口极小 |

---

## 10. 连续追问 Q&A

### Q1：RDB 和 AOF 的本质区别？

RDB 存「某一时刻的数据快照」（二进制），AOF 存「到达这一时刻的所有写命令」（日志）。前者恢复快、文件小但可能丢；后者安全但文件大、恢复慢。

### Q2：fork 为什么快？为什么还会阻塞？

fork 只复制页表（不是物理内存），然后把父子进程的页标记为只读共享，所以很快；但复制页表本身是主线程做的，内存越大页表越大（10GB 约 21MB 页表），会阻塞几十毫秒。

### Q3：COW 具体什么时候发生？

父进程或子进程**写**共享页时触发缺页异常，内核复制该页给写入方。Redis 的子进程只读，所以只有父进程的写操作会触发 COW。

### Q4：AOF 重写期间，新写入的命令去哪了？

同时写旧 AOF 和「AOF 重写缓冲区」；子进程写完新文件后，父进程把重写缓冲区追加到新文件尾部，再原子替换。7.0 用多部分 AOF（incr 文件）替代。

### Q5：混合持久化为什么能恢复快？

前段是 RDB 二进制（直接反序列化，不用重放命令），后段只是重写期间产生的少量增量命令。

### Q6：过期键为什么不立刻删？

Redis 没有每个 key 的定时器（开销太大）。惰性删除负责「访问时清理」，定期删除负责「抽样兜底」，两者配合。

### Q7：定期删除一秒钟能删多少 key？

每 100ms 一轮，每轮最多抽 20 个 key；如果过期比例超过 25% 会连续抽多轮（有时间上限）。所以正常情况下每秒检查几百个 key，够用但不保证即时清理全部。

### Q8：从节点会主动删过期 key 吗？

不会。从节点等主节点的 DEL 命令同步；从节点读到过期 key 时返回 nil（逻辑过期），保证主从一致。

### Q9：内存淘汰策略怎么选？

纯缓存用 `allkeys-lru` 或 `allkeys-lfu`；缓存与持久数据混存用 `volatile-*`（只淘汰带 TTL 的）；不能丢就用 `noeviction` 并做好监控和容量规划。

### Q10：为什么大内存实例做 BGSAVE 容易出问题？

fork 阻塞时间变长 + COW 可能复制大量页导致内存翻倍；如果 `maxmemory` 设置太接近机器内存，容易 OOM 甚至被系统 kill。

### Q11：AOF 文件损坏了怎么办？

`redis-check-aof --fix` 可以截断末尾不完整命令；配置 `aof-load-truncated yes`（默认）允许加载截断的 AOF 并继续启动。

### Q12：RDB 和 AOF 同时开启时，重启用哪个恢复？

优先用 AOF（更完整）；如果 AOF 关闭或损坏，才用 RDB。7.0 的多部分 AOF 若 manifest 存在则按 AOF 恢复。

---

## 11. 一张图总结

```
数据写入
   │
   ├──► 内存（主存储）
   │      │
   │      ├── 定期 fork ──► RDB 快照文件（二进制、紧凑）
   │      │        └─ COW：父进程写时复制页，内存可能峰值翻倍
   │      │
   │      └── 每条写命令 ──► AOF 缓冲区 ──► AOF 文件（appendfsync 三档）
   │                              │
   │                              └── 膨胀 → 重写：fork 子进程写最小命令集
   │                                         + 重写缓冲区补增量 → 原子替换
   │
   └── 内存满 → 每 key 的 24bit LRU 时钟 + 采样 → 按 8 种策略淘汰
   过期键 → 惰性删除（访问时）+ 定期抽样（每 100ms 抽 20 个）
```

---

## 12. 一句话复盘

> RDB 是「定时快照」：fork + COW 让快照不阻塞主线程，但两次快照之间会丢数据；AOF 是「写日志」：三种 fsync 策略决定丢多少，重写让文件不再膨胀；混合持久化把两者优点拼起来。过期靠惰性 + 定期删除，内存满靠 8 种淘汰策略——持久化和淘汰，本质上都是「性能与安全」的取舍。

---

## 13. 自测题（先自己答，再看答案）

**1. `appendfsync everysec` 在什么情况下最多丢多少数据？**
答案：约 1 秒的写命令。如果 TPS 5 万，最坏丢 5 万条。

**2. fork 之后，为什么子进程看到的是「快照那一刻」的数据？**
答案：fork 后父子进程共享物理页且只读；父进程之后写页时触发 COW，复制出新页，子进程仍读旧页，所以子进程遍历到的是 fork 时刻的数据。

**3. AOF 重写期间，为什么需要重写缓冲区？**
答案：子进程只负责写 fork 时刻的内存；期间父进程的新写命令要单独记录，否则重写后的 AOF 会缺少这些命令。

**4. 定期删除的采样规则是什么？**
答案：每 100ms 一轮，随机抽 20 个过期字典里的 key；过期的删除，若过期比例 > 25% 继续下一轮（有时间上限）。

**5. `allkeys-lru` 和 `volatile-lru` 的区别？**
答案：前者在所有 key 中淘汰，后者只在设置了 TTL 的 key 中淘汰；后者适合「持久数据 + 缓存数据混存」的场景。

---

## 14. 关联文件

- 深一层（追问树 + 源码细节）：[持久化与淘汰](../../10-deep-dive/redis/02-持久化与淘汰.md)
- 同层精讲：[Redis 底层编码](01-Redis底层编码.md)
- 广度速查：[MySQL 与 Redis](../../04-database/MySQL与Redis.md)
- 返回：[精讲索引](../00-索引.md)
