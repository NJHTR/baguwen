# Redis 底层编码：一个 key 到底存在什么结构里？

> 精讲层级：从「零基础能看懂」到「结构体 + 阈值推导级」，每个名词都拆开
> 阅读时间：约 35 分钟
> 配套速查：[数据结构与编码（深度追问）](../../10-deep-dive/redis/01-数据结构与编码.md)
> 返回：[精讲索引](../00-索引.md)

---

## 0. 一句话先讲明白

Redis 对外只暴露 5 种类型（string、hash、list、set、zset），但内部给每种类型准备了**多种编码（encoding）**：
数据量小的时候用**连续内存的紧凑结构**（intset、listpack）省内存；数据量大了自动切换成**通用结构**（hashtable、quicklist、跳表）换性能。
你写 `HSET user:1 name tom` 时，到底存成 listpack 还是 hashtable，取决于配置阈值和实际大小——**这决定了内存占用和一个命令的复杂度**。

---

## 1. 痛点背景：内存到底是内存，key 是有成本的

### 1.1 一个 key 不只是「数据」

如果 Redis 用最朴素的方式存每个值：一个堆分配的字符串，那么每个 key 至少包含：

| 开销 | 字节数 |
|---|---|
| dictEntry（哈希表节点：key 指针、value 指针、next 指针） | 约 24B |
| redisObject（类型、编码、引用计数、LRU 等元信息） | 16B |
| SDS 头（字符串长度、分配长度、flags） | 3~8B |
| 实际数据 | 看内容 |

**最小 43B 就出去了**，哪怕你只存了 `{"a": 1}` 两个字节。

### 1.2 数字推导：小对象用 hash 存能省多少

假设要存一个用户的 5 个字段：`name=tom`、`age=20`、`city=bj`、`level=3`、`vip=1`。

方案 A：每个字段一个 string key（`user:1:name` 等）

- 5 个 key，每个 key 名约 12B，每个 value 约 5B；
- 每个 key 至少 `24（dictEntry）+ 16（robj）+ 8（SDS 头）+ 12（key 名）+ 5（值）≈ 65B`；
- 5 个 ≈ **325B**，还不含哈希表本身的桶数组。

方案 B：一个 hash key，字段做 field

- 1 个 dictEntry + 1 个 robj ≈ 40B；
- hash 内部用 listpack 存 5 个 field-value：每个 entry 约 `1~2B 头 + 字段内容`，5 组约 60~80B；
- 合计约 **100~120B**。

**差 2~3 倍**。当 Redis 里存了几千万个小对象时，这个差距就是几十 GB 内存和几万块钱的区别。

### 1.3 所以 Redis 的设计目标

| 目标 | 手段 |
|---|---|
| 小数据省内存 | 紧凑编码（连续内存、无指针） |
| 大数据保性能 | 通用编码（哈希表、跳表、链表） |
| 对使用者透明 | 根据阈值自动转换 |

---

## 2. 逐步拆解：五种类型 × 编码

### 2.1 redisObject：每个 value 都套一层壳

Redis 里所有 value 都是 `robj`（redisObject）：

| 字段 | 作用 |
|---|---|
| `type` | 逻辑类型：string / hash / list / set / zset |
| `encoding` | 物理编码：int、embstr、raw、listpack、hashtable、intset、quicklist、skiplist |
| `lru` | 24 位，用于 LRU 淘汰（或 LFU 的计数 + 衰减时间） |
| `refcount` | 引用计数，共享对象用（0~9999 的整数共享） |
| `ptr` | 指向真正的数据（SDS、dict、listpack 等） |

`sizeof(robj) = 16B`。这就是「每个 value 都有 16B 壳」的来源。

### 2.2 string 的三种编码

| 编码 | 触发条件 | 说明 |
|---|---|---|
| `int` | 值能解析成 long 且不超过范围 | 直接把数字存在 `ptr` 里，不额外分配 |
| `embstr` | 长度 ≤ 44 字节 | robj 和 SDS **分配在同一块内存**，一次 malloc |
| `raw` | 长度 > 44 字节 | robj 和 SDS 分开分配，两次 malloc |

**为什么是 44 字节（数字推导）**：

- `robj` 16B；
- `sdshdr8` 头 3B（len、alloc、flags）；
- 结尾 `\0` 1B；
- 合计 20B；
- jemalloc 的内存块是 64B，`64 - 20 = 44B`；
- 所以 44 字节以内，robj + SDS 能塞进一个 64B 块，只分配一次。

### 2.3 SDS：Redis 自己实现的字符串

| C 字符串 | SDS（Simple Dynamic String） |
|---|---|
| 以 `\0` 结尾，`strlen` 要 O(n) 遍历 | 有 `len` 字段，取长度 O(1) |
| 不能存 `\0`（会被当结尾） | 二进制安全，可存任意字节 |
| 拼接要手动 realloc，频繁分配 | 预分配：`< 1MB` 时翻倍，`≥ 1MB` 时多给 1MB |
| 缩短后内存不回收 | 惰性释放：不立即 free，保留空间复用 |

SDS 头有 5 种（sdshdr5/8/16/32/64），按字符串长度选最小的头，进一步省内存。

### 2.4 五种类型 × 编码 × 阈值（Redis 7.x）

| 类型 | 编码 | 转换阈值（配置项） | 转成什么 |
|---|---|---|---|
| string | int / embstr / raw | 44 字节 | raw |
| hash | listpack / hashtable | `hash-max-listpack-entries 128`、`hash-max-listpack-value 64` | hashtable |
| list | listpack / quicklist | `list-max-listpack-size 128`（负数按内存，如 -2 = 8KB） | quicklist |
| set | intset / listpack / hashtable | `set-max-intset-entries 512`、`set-max-listpack-entries 128` | hashtable |
| zset | listpack / skiplist | `zset-max-listpack-entries 128`、`zset-max-listpack-value 64` | skiplist + dict |

**注意版本**：Redis 7.0 之前，hash/zset 的紧凑编码叫 **ziplist**，配置项是 `hash-max-ziplist-entries`；7.0 起换成 **listpack**。**编码转换是单向的**：一旦变成 hashtable/skiplist，删数据也不会自动转回紧凑编码（要重建 key）。

### 2.5 list：quicklist 是什么

list 默认编码是 **quicklist（快速列表）**：一个双向链表，但**每个节点不是单个元素，而是一个 listpack**。

```
quicklist
 ├── node1：listpack["a","b","c", ...]（约 128 个元素或 8KB）
 ├── node2：listpack[...]
 └── node3：listpack[...]
```

- 为什么不用纯链表：每个元素一个节点，指针开销 16B/元素，太费内存；
- 为什么不用单个 listpack：元素太多时，插入/删除要整体移动内存，O(n) 太慢；
- quicklist 折中：节点内连续（省内存），节点间用链表（插入快）。

### 2.6 zset：为什么同时有跳表和 dict

zset（有序集合）要同时支持两种操作：

| 操作 | 需要什么 | 谁负责 |
|---|---|---|
| `ZSCORE key member`（按成员查分数） | 哈希查找 | `dict`（member → score），O(1) |
| `ZRANGE key 0 9`（按分数排序/排名） | 有序结构 | `skiplist`（跳表），O(log n + k) |

**跳表（skiplist）** 是多层链表：

```
level 3:  head ─────────────────────────► 30 ─────────► NULL
level 2:  head ─────────► 10 ───────────► 30 ─────────► NULL
level 1:  head ─► 5 ────► 10 ────► 20 ──► 30 ─────────► NULL
level 0:  head ─► 5 ─► 7 ─► 10 ─► 15 ─► 20 ─► 25 ─► 30 ─► NULL
                    ↑ 每层节点带 forward 指针和 span（跨度）
```

- 新节点的层数**随机**：每层以 `1/4` 的概率继续往上，最高 32 层（`ZSKIPLIST_MAXLEVEL`）；
- 期望层数 = `1/(1-0.25) ≈ 1.33` 层，所以内存开销可控；
- 节点里存 `span`（到下一个节点的跨度），`ZRANK` 靠累加 span 算排名，不用遍历。

### 2.7 dict 与渐进式 rehash

Redis 的哈希表是 `dict`，内部有**两个**哈希表：

```
dict
 ├── ht[0]：正常使用的表
 ├── ht[1]：rehash 时的新表（平时为 NULL）
 └── rehashidx：迁移到哪个桶了（-1 表示没在迁移）
```

**为什么需要两个表**：扩容时如果一次性把旧表所有元素搬到新表，单线程会卡住（几十万个 key 要搬）。渐进式 rehash 把迁移摊到每次操作里：

| 阶段 | 读 | 写 |
|---|---|---|
| 迁移中 | 先查 ht[0]，再查 ht[1] | 只写 ht[1]（保证不重复） |
| 迁移完成 | 交换 ht[0] 和 ht[1]，释放旧表 | 正常 |

**触发条件（数字推导）**：
- 负载因子 `used / size ≥ 1` 时扩容，新 size 是第一个 ≥ `used × 2` 的 2 的幂；
- 如果正在做 BGSAVE/BGREWRITEAOF（fork 子进程），要 `≥ 5` 才强制扩容（避免 COW 复制大量页导致内存翻倍）；
- 负载因子 `< 0.1` 时缩容。

### 2.8 为什么单线程还快

| 原因 | 解释 |
|---|---|
| 纯内存操作 | 一次哈希/跳表查找约 100ns 级，不碰磁盘 |
| IO 多路复用 | epoll 同时监听上万连接，不需要每连接一个线程 |
| 避免锁 | 单线程执行命令，不存在竞态，没有加锁开销 |
| 高效数据结构 | SDS、listpack、跳表都是为场景定制的 |
| 协议简单 | RESP 协议解析开销小 |

**注意版本**：Redis 6.0 引入了**网络 IO 多线程**（读写 socket、协议解析可以多线程），但**命令执行仍然是单线程**；`UNLINK`、`BGSAVE` 等也用后台线程/子进程分担。所以「Redis 单线程」准确说法是「命令执行单线程」。

---

## 3. 完整推导：两个关键设计的取舍计算

### 3.1 为什么 listpack 替代 ziplist（数字推导）

ziplist 的每个 entry 存了「前一个 entry 的长度（prevlen）」，用于**从后往前遍历**。问题：

- 当某个 entry 的长度变化，导致它的 prevlen 从 1 字节变成 5 字节（长度 ≥ 254 时用 5 字节）；
- 后面那个 entry 的 prevlen 也要改，可能又触发连锁变化；
- 最坏情况下，插入一个元素要让 **n 个 entry 依次扩容**，复杂度 O(n²)。

listpack 的改进：每个 entry 只存自己的长度和 **backlen**（从后往前的偏移），不再依赖前一个 entry，**彻底避免连锁更新**。所以 Redis 7.0 把 hash/zset 的紧凑编码从 ziplist 换成 listpack。

### 3.2 为什么阈值是 128 和 64

- `hash-max-listpack-entries 128`：listpack 内查找是 O(n)，128 个元素平均比较 64 次，成本可接受；超过 128 后哈希表 O(1) 的收益超过 listpack 省内存的收益；
- `hash-max-listpack-value 64`：单个 value 太长时，listpack 的「连续内存」优势消失（一个大字符串就把页占满），而且扩容/移动成本高，转 hashtable 更稳。

### 3.3 跳表 vs 红黑树（为什么 Redis 选跳表）

| 对比 | 跳表 | 红黑树 |
|---|---|---|
| 范围查询 | 底层链表直接顺序扫 | 需要中序遍历，回溯复杂 |
| 实现难度 | 简单（插入/删除不用旋转） | 复杂（旋转、变色） |
| 并发控制 | 更容易做无锁（节点局部修改） | 旋转影响面大 |
| 内存 | 每节点平均 1.33 个 forward 指针 | 每节点左右孩子 + 颜色 |

Redis 是单线程，并发不是关键，但**范围查询友好、实现简单**是决定性的。

---

## 4. 极简模型：三个 key 的字典

### 4.1 字典本身

```
Redis 的全局字典（db 0）
key                       value（robj）
─────────────────────────────────────────
"user:1"      ──────────►  robj(type=hash, encoding=listpack) ──► listpack 字节数组
"tags"        ──────────►  robj(type=set,  encoding=intset)   ──► intset 字节数组
"rank"        ──────────►  robj(type=zset, encoding=listpack) ──► listpack 字节数组
```

### 4.2 一个 listpack 里的字节布局（示意）

```
hash 的 listpack：
[总字节数 4B][元素数 2B][entry1][entry2][...][结束标记 0xFF]

entry 的结构：
[encoding 1~2B 表示类型/长度][data][backlen 1~5B]
```

对比「一个元素一个节点」的哈希表：listpack 省掉了每个元素的 dictEntry（24B）和指针（8B），所以 5 个字段能省 150B 左右。

### 4.3 把模型放大

```
1 个字段的 hash   → listpack（1 个 entry）
128 个字段的 hash → 还是 listpack
129 个字段的 hash → 立即转 hashtable（桶 + dictEntry + 指针，内存涨，但 O(1)）
```

---

## 5. 为什么这样设计：三个被否决的方案

### 5.1 否决方案一：所有类型都直接用 hashtable

- 内存开销大：每个元素 24B dictEntry + 8B 指针 + 哈希表桶数组；
- 小对象场景（Redis 的主流场景之一）内存会翻 2~5 倍；
- 范围查询还是要额外排序结构。

### 5.2 否决方案二：所有类型都用 listpack（或 ziplist）

- 查找 O(n)，大数据量下慢；
- 元素插入/删除要移动连续内存，O(n)；
- 单个元素过大时，一个 listpack 会变成巨型分配，碎片严重。

### 5.3 否决方案三：zset 只用跳表，不要 dict

- `ZSCORE` 变成 O(log n)（跳表按 member 查要遍历），而实际业务里「按成员查分数」非常频繁；
- 用 dict 后 `ZSCORE` 是 O(1)，代价只是 16B 左右的额外指针/节点，值得。

### 5.4 否决方案四：string 直接用 C 字符串

- `strlen` O(n)、不能存 `\0`、扩容要手动 realloc、截断不释放内存；
- 用 SDS 一次性解决四个问题，代价只是 3~8B 的头。

---

## 6. 关键参数为什么是这个值

### 6.1 编码阈值（Redis 7.x 默认）

| 参数 | 默认值 | 为什么 |
|---|---|---|
| `hash-max-listpack-entries` | 128 | O(n) 扫描在 128 内可接受 |
| `hash-max-listpack-value` | 64 | 单值 64B 内连续内存划算 |
| `list-max-listpack-size` | 128（或 -2=8KB） | 节点太大插入慢、太小指针多 |
| `set-max-intset-entries` | 512 | intset 二分查找，512 内效率高 |
| `set-max-listpack-entries` | 128 | 7.2+ 引入 |
| `zset-max-listpack-entries` | 128 | 同上 |
| `zset-max-listpack-value` | 64 | 同上 |

### 6.2 为什么是 2 的幂（dict 扩容）

- `hash % size` 用 `hash & (size-1)` 替代，前提是 size 是 2 的幂；
- 位运算比取模快，且天然处理负数（按位与不看符号）；
- 扩容时元素的新位置要么不变、要么移到「原位置 + oldsize」，方便渐进迁移。

### 6.3 为什么 skiplist 最大 32 层

- 每层晋升概率 1/4，期望层数 1.33；
- 32 层能表示 `4^31` 量级的元素（远超实际需求），足够；
- 层数太高浪费指针（每层 8B forward + 8B span = 16B），太低查询变慢。

### 6.4 为什么字符串是 44 字节（已推导）

16（robj）+ 3（sdshdr8 头）+ 1（`\0`）= 20B，64B 内存块剩余 44B。

---

## 7. 版本演进：Redis 3.x → 7.x

| 版本 | 与底层编码相关的变化 |
|---|---|
| Redis 3.2 | list 引入 quicklist，替代 ziplist + linkedlist 两种编码 |
| Redis 4.0 | 引入 LFU 淘汰和模块系统；`UNLINK` 异步删除 |
| Redis 5.0 | 引入 Stream 类型（底层 rax 基数树） |
| Redis 6.0 | 网络 IO 多线程（命令执行仍单线程）；RESP3 |
| Redis 7.0 | **hash/zset 的紧凑编码从 ziplist 换成 listpack**；多部分 AOF |
| Redis 7.2 | set 增加 listpack 编码（`set-max-listpack-entries`） |

所以：如果你在 Redis 6 上执行 `OBJECT ENCODING` 看到一个 hash 是 `ziplist`，是正常的；Redis 7 上同样场景会显示 `listpack`。

---

## 8. 亲手验证：看编码随阈值变化

> 环境说明：以下命令在 Redis 7.x 上预期如注释；Redis 6 及以前 hash/zset 显示 `ziplist`、没有 `*-max-listpack-*` 配置；Redis 3.x 可能没有 `OBJECT ENCODING` 的全部编码名。

```bash
# 1. string 三种编码
redis-cli SET s1 123
redis-cli OBJECT ENCODING s1
# 预期：int

redis-cli SET s2 "hello"
redis-cli OBJECT ENCODING s2
# 预期：embstr（长度 <= 44）

redis-cli SET s3 "$(printf 'a%.0s' {1..50})"
redis-cli OBJECT ENCODING s3
# 预期：raw（长度 > 44）

# 2. hash：小数据 listpack，value 超 64B 转 hashtable
redis-cli HSET user:1 name tom age 20
redis-cli OBJECT ENCODING user:1
# 预期：listpack

redis-cli HSET user:2 name "$(printf 'a%.0s' {1..65})"
redis-cli OBJECT ENCODING user:2
# 预期：hashtable（value 长度 65 > 64）

# 3. set：全是整数用 intset
redis-cli SADD tags 1 2 3
redis-cli OBJECT ENCODING tags
# 预期：intset

# 4. zset：小数据 listpack，超过 128 个成员转 skiplist
redis-cli ZADD rank 89 tom 95 jerry
redis-cli OBJECT ENCODING rank
# 预期：listpack

redis-cli ZADD rank $(for i in $(seq 1 200); do echo "$i m$i"; done)
redis-cli OBJECT ENCODING rank
# 预期：skiplist

# 5. 看阈值配置
redis-cli CONFIG GET 'hash-max-*'
redis-cli CONFIG GET 'zset-max-*'
redis-cli CONFIG GET set-max-intset-entries
# 预期：hash-max-listpack-entries 128 等

# 6. 看内存占用
redis-cli MEMORY USAGE user:1
# 预期：约 100~200 字节（取决于字段内容和版本）
```

### 8.1 Java 侧观察（Jedis）

```java
try (Jedis jedis = new Jedis("127.0.0.1", 6379)) {
    jedis.hset("user:java", Map.of("name", "tom", "age", "20"));
    System.out.println(jedis.objectEncoding("user:java"));   // 预期：listpack
    System.out.println(jedis.memoryUsage("user:java"));      // 预期：约 100+ 字节
}
```

---

## 9. 常见误区

| 错误说法 | 正确说法 |
|---|---|
| 「Redis 只有 5 种底层编码」 | 5 种类型，底层 11 种以上编码 |
| 「zset 底层是红黑树」 | 是跳表 + dict（小数据时 listpack） |
| 「编码变大后会自动变回来」 | 转换单向，只能删 key 重建或 RESTORE |
| 「listpack 就是 ziplist 改名」 | listpack 去掉了 prevlen，解决连锁更新 |
| 「Redis 是纯单线程」 | 命令执行单线程；6.0 起网络 IO 有后台线程，删除/持久化也用后台 |
| 「哈希表扩容是一次性搬完」 | 渐进式 rehash，每次操作迁移一个桶 |
| 「intset 可以降级」 | 升级不可逆（2→4→8 字节） |
| 「值越大用 listpack 越省」 | 超过阈值反而更费，转 hashtable 更快 |

---

## 10. 连续追问 Q&A

### Q1：Redis 一个 key 最小占多少内存？

一个 key 至少：dictEntry（约 24B）+ key 的 SDS（头 3~8B + 内容）+ robj（16B）+ value。空 value 也要 40B 以上。所以「存小对象用 Redis 不划算」是有依据的。

### Q2：为什么 hash 小的时候用 listpack 而不是 hashtable？

省内存：listpack 连续存储，没有每个元素的 dictEntry 和指针；128 个元素内 O(n) 扫描成本可接受。超过阈值后哈希表的 O(1) 更值。

### Q3：listpack 怎么从后往前遍历？

每个 entry 末尾有 backlen（变长编码的自身长度），从尾部减掉 backlen 就能找到上一个 entry，不需要像 ziplist 那样依赖前一个 entry 的 prevlen。

### Q4：zset 为什么要 dict + skiplist 两个结构？

dict 负责按 member 查 score（O(1)），skiplist 负责按 score 排序和范围查询（O(log n)）。两者共享同一份 member/score 数据，不是两份拷贝。

### Q5：跳表的层数怎么随机？期望几层？

新节点初始 1 层，每层以 1/4 概率继续上升，最高 32 层。期望层数 `1/(1-0.25)=1.33`，所以平均每节点 1.33 个 forward 指针，内存可控，查询 O(log n)。

### Q6：dict 扩容为什么要有两个哈希表？

为了让迁移可以渐进：ht[0] 是旧表，ht[1] 是新表；每次操作顺带搬一个桶，查找时先 ht[0] 再 ht[1]，写只写 ht[1]。如果一次性搬，单线程会被几十万个 key 卡住。

### Q7：渐进式 rehash 期间，查找怎么保证找到？

先查 ht[0]，没找到再查 ht[1]；因为迁移是「搬走」而不是「复制」，一个 key 只会在其中一张表里，所以两次查找能覆盖。

### Q8：为什么扩容在 BGSAVE 时要放宽到负载因子 5？

fork 子进程做快照时，父进程写内存会触发 COW 复制页。如果此时扩容（大量写新表），COW 复制量会暴涨，内存可能翻倍。所以 fork 期间尽量不扩容。

### Q9：为什么 string 要区分 embstr 和 raw？

embstr 让 robj 和 SDS 连续分配，一次 malloc，省一次内存分配和缓存跳转；超过 44B 放不进一个 jemalloc 块，只能分开分配成 raw。

### Q10：SDS 预分配策略具体是什么？

- 修改后长度 `< 1MB`：分配 `2 × 新长度`；
- `≥ 1MB`：分配 `新长度 + 1MB`；
- 惰性释放：缩短字符串不立刻 free，保留已分配空间减少再分配。

### Q11：Redis 6 的多线程会不会破坏命令原子性？

不会。多线程只负责网络读写和协议解析，命令执行仍然在单线程里顺序执行，所以单条命令的原子性不变；需要多条命令原子时仍用 Lua 或事务。

### Q12：为什么 big key 危险？

因为命令执行单线程：`DEL` 一个百万元素的 hash、`HGETALL` 一个巨型 hash，都会让主线程阻塞；网络层要把大结果传出去也会占带宽。治理方式：拆分、`UNLINK` 异步删、`HSCAN` 分批。

---

## 11. 一张图总结

```
key ──► 全局 dict ──► dictEntry ──► robj(type, encoding, ptr)
                                      │
        ┌─────────────────────────────┼─────────────────────────────┐
        ▼                             ▼                             ▼
      string                        hash/list/set                  zset
   int/embstr/raw               listpack/intset/quicklist      listpack/skiplist+dict
   （SDS 或直接存数字）          （连续内存，小数据）            （跳表保序，dict 查分）

阈值：hash 128 项 / 64B、zset 128 项 / 64B、set intset 512、list 节点 128
超过 → 转 hashtable / skiplist / quicklist（单向，不回退）
```

---

## 12. 一句话复盘

> Redis 用「类型 + 编码」两层抽象：小数据用 listpack/intset 这类连续内存结构省空间，超过阈值换成 hashtable/跳表保性能。理解编码，就理解了 Redis 的内存占用、命令复杂度和「为什么 big key 危险」。

---

## 13. 自测题（先自己答，再看答案）

**1. 为什么 embstr 的边界是 44 字节？**
答案：robj 16B + sdshdr8 头 3B + `\0` 1B = 20B，jemalloc 的 64B 块剩余 44B；超过 44B 就要分开分配成 raw。

**2. 一个 hash 有 200 个字段、每个 value 30B，用的是什么编码？**
答案：hashtable。字段数 200 > 128，超过 `hash-max-listpack-entries`。

**3. 渐进式 rehash 期间，一个 key 可能同时存在于两张表吗？**
答案：不会。迁移是「搬走」，查的时候先 ht[0] 再 ht[1]，写只写 ht[1]。

**4. 为什么 zset 的 `ZSCORE` 是 O(1)，`ZRANGE` 是 O(log n + k)？**
答案：`ZSCORE` 走 dict 按 member 查；`ZRANGE` 走跳表按分数定位起点再顺序取 k 个。

**5. Redis 6 的多线程解决了什么？**
答案：解决网络 IO 和协议解析的瓶颈，命令执行仍单线程，因此命令原子性和数据结构不需要加锁。

---

## 14. 关联文件

- 深一层（追问树 + 源码细节）：[数据结构与编码](../../10-deep-dive/redis/01-数据结构与编码.md)
- 同层精讲：[Redis 持久化](02-Redis持久化.md)
- 广度速查：[MySQL 与 Redis](../../04-database/MySQL与Redis.md)
- 返回：[精讲索引](../00-索引.md)
