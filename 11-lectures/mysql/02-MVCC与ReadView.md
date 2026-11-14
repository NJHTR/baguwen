# MVCC 与 ReadView：为什么能读到「过去」的数据？

> 精讲层级：从「零基础能看懂」到「版本链 + 可见性判断级」，每个名词都拆开
> 阅读时间：约 35 分钟
> 配套速查：[MVCC 与事务隔离（深度追问）](../../10-deep-dive/mysql/02-MVCC与事务隔离.md)
> 返回：[精讲索引](../00-索引.md)

---

## 0. 一句话先讲明白

MVCC（Multi-Version Concurrency Control，多版本并发控制）让「读」不用加锁：每行数据旁边挂着一条**由 undo log 串起来的旧版本链**，每行还隐藏了两个字段——最后修改它的事务 ID（`DB_TRX_ID`）和指向旧版本的指针（`DB_ROLL_PTR`）。
读的时候，数据库临时生成一个**快照（ReadView）**，用四个字段判断「版本链上哪个版本对我可见」，于是读到的是事务开始时那一刻的数据。
`REPEATABLE READ`（RR）在事务第一次快照读时生成 ReadView 并复用，`READ COMMITTED`（RC）每条 SELECT 都重新生成——这就是两个隔离级别在 MVCC 上的唯一区别。

---

## 1. 痛点背景：如果没有 MVCC

### 1.1 读写互斥的世界

假设只有「锁」这一种并发控制：

| 操作 | 要加的锁 | 后果 |
|---|---|---|
| 事务 A 读 id=1 | 共享锁 S | 事务 B 想改 id=1，要等 A 释放 |
| 事务 B 改 id=1 | 排他锁 X | 事务 C 想读 id=1，要等 B 提交 |

结果：**读会阻塞写，写会阻塞读**。一个秒杀场景里，只要有人在下单，所有查商品详情的人都被卡住——这在互联网业务里不可接受。

### 1.2 那不用锁行不行？直接读最新数据有什么问题

如果没有锁、也不保留旧版本，事务 A 读两次会读到两个不同的值：第一次读余额 100，第二次读余额 200（因为事务 B 提交了）。这就是「不可重复读」，会让业务算错账。

所以需求很明确：**既要读不被写阻塞，又要事务内看到一致的数据。** 这两个要求只能靠「多版本」实现——让每个事务看自己那个时间点的版本。

### 1.3 名词预告

| 名词 | 一句话解释（后面会展开） |
|---|---|
| 事务 ID（`trx_id`） | InnoDB 给每个写事务分配的递增编号 |
| undo log | 记录「旧值」的日志，用于回滚和重建旧版本 |
| 版本链 | 同一行多个旧版本用 `DB_ROLL_PTR` 串成的单向链表 |
| ReadView | 读快照，记录「生成时刻哪些事务还没提交」 |
| 快照读 | 普通 SELECT，按 ReadView 读历史版本，不加锁 |
| 当前读 | UPDATE/DELETE/SELECT ... FOR UPDATE，读最新版本并加锁 |

---

## 2. 逐步拆解：从行记录到可见性判断

### 2.1 每行都藏着两个字段

InnoDB 的行格式（COMPACT / DYNAMIC）里，除了业务列，还有隐藏字段：

| 隐藏字段 | 大小 | 作用 |
|---|---|---|
| `DB_TRX_ID` | 6B | 最后修改这一行的事务 ID |
| `DB_ROLL_PTR` | 7B | 指向 undo log 中「上一个版本」的指针 |
| `DB_ROW_ID` | 6B | 没有主键时自动生成的隐藏主键 |

**数字化感受一下**：6 字节 = 48 位，最大能表示 `2^48 ≈ 2.8 × 10^14` 个事务；按每秒 10 万个写事务算，可以用 **约 89 年**。所以「事务 ID 用完」在现实中不用担心，但它的上限确实是 6B（追到底会被问到这个）。

### 2.2 版本链怎么串起来

```
聚簇索引里的行（当前版本）
┌────────────────────────────────────────┐
│ 列数据：balance = 300                   │
│ DB_TRX_ID = 30                          │
│ DB_ROLL_PTR ─────────────┐              │
└──────────────────────────┼──────────────┘
                           ↓
               undo log 中的旧版本
        ┌────────────────────────────────┐
        │ 旧值：balance = 200             │
        │ DB_TRX_ID = 20                  │
        │ roll_pointer ─────┐             │
        └───────────────────┼─────────────┘
                            ↓
                 更旧的版本（balance = 100，trx_id = 10）
                            ↓
                         …链尾（NULL）
```

- 每次 UPDATE 都是**写一个新版本**，旧值进 undo log；
- 回滚时顺着链反向恢复；MVCC 读时顺着链往旧版本找。

### 2.3 ReadView 的四个字段

ReadView 是「读快照」，本质是一个结构体，核心四个字段：

| 字段 | 含义 | 通俗解释 |
|---|---|---|
| `m_ids` | 生成 ReadView 时，所有**活跃（未提交）**事务的 ID 列表 | 「这一刻还在跑的事务名单」 |
| `min_trx_id` | `m_ids` 里的最小值 | 名单里最老的那个 |
| `max_trx_id` | 生成时**下一个将要分配**的事务 ID | 「未来事务的起点」，注意是最大值 + 1 |
| `creator_trx_id` | 创建这个 ReadView 的事务 ID | 「我自己」 |

### 2.4 可见性判断四步（逐行伪代码）

对版本链上某个版本的 `trx_id`，依次做：

```text
if trx_id == creator_trx_id:
    return 可见                    # 1. 自己改的，永远可见

if trx_id < min_trx_id:
    return 可见                    # 2. 比名单里最老的还老，说明早已提交

if trx_id >= max_trx_id:
    return 不可见                  # 3. 在我之后才开的事务，肯定没提交

# 4. 处于 [min_trx_id, max_trx_id) 区间：
if trx_id in m_ids:
    return 不可见                  # 4a. 名单里的人，生成快照时还没提交
else:
    return 可见                    # 4b. 不在名单里，说明生成快照前已提交
```

如果不可见，就顺着 `DB_ROLL_PTR` 取上一个版本，重复四步，直到可见或链尾。

### 2.5 快照读 vs 当前读

| | 快照读 | 当前读 |
|---|---|---|
| 语句 | 普通 `SELECT` | `SELECT ... FOR UPDATE`、`LOCK IN SHARE MODE`、`UPDATE`、`DELETE`、`INSERT` |
| 读哪个版本 | 按 ReadView 判断的可见版本 | **永远读最新已提交版本** |
| 加锁 | 不加锁 | 加记录锁/间隙锁 |
| 用途 | 报表、查询 | 改数据前的检查、扣库存 |

**关键理解**：`UPDATE` 必须读最新版本，否则会覆盖别人的更新；所以「可重复读」只对快照读成立。

---

## 3. 完整推导：拿一条真实的版本链走一遍

假设事务 ID 已经分配到了 100，活跃事务是 20 和 30。

### 3.1 场景设定

行 `id = 1` 的版本链：

```
V3（当前行）：trx_id = 30，balance = 300
V2（undo）： trx_id = 20，balance = 200
V1（undo）： trx_id = 10，balance = 100
```

现在事务 40（当前读/写事务）执行快照读，生成 ReadView：

```
creator_trx_id = 40
m_ids = [20, 30]          （20、30 还没提交）
min_trx_id = 20
max_trx_id = 100          （下一个要分配的 ID）
```

### 3.2 逐版本判断

| 版本 | trx_id | 第 1 步：== 40？ | 第 2 步：< 20？ | 第 3 步：>= 100？ | 第 4 步：在 m_ids 里？ | 结论 |
|---|---|---|---|---|---|---|
| V3 | 30 | 否 | 否 | 否 | 在（30 在名单里） | 不可见 |
| V2 | 20 | 否 | 否 | 否 | 在（20 在名单里） | 不可见 |
| V1 | 10 | 否 | **是** | 否 | — | **可见** |

所以事务 40 读到 `balance = 100`。

### 3.3 为什么这个结果是「正确」的

- 事务 20 和 30 在事务 40 生成快照时**都还没提交**，它们改的值对 40 来说「还没发生」；
- 事务 10 早就提交了，它的值对 40 可见；
- 这就是「快照读」的语义：**看到生成 ReadView 那一刻已经提交的数据，看不到之后才提交的**。

### 3.4 ReadView 的生成时机差异（RR vs RC）

| 隔离级别 | ReadView 生成时机 | 效果 |
|---|---|---|
| REPEATABLE READ（RR，默认） | 事务内**第一次快照读**时生成，之后所有快照读复用 | 事务内多次读结果一致 |
| READ COMMITTED（RC） | **每条 SELECT 都重新生成** | 每次读都能看到别人新提交的数据 |
| SERIALIZABLE | 读也加锁，不靠 MVCC | 相当于串行 |

**陷阱**：`BEGIN` 不等于生成 ReadView。RR 下 `BEGIN` 之后、第一次 SELECT 之前别人提交的数据，第一次 SELECT 是**能看到**的（因为 ReadView 是第一次 SELECT 才建的）。要让 `BEGIN` 就定格，用 `START TRANSACTION WITH CONSISTENT SNAPSHOT`。

### 3.5 长事务为什么危险（数字推导）

假设一个事务开了 10 分钟，期间另一个热点行被更新了 1000 次：

- 每产生一个旧版本，undo log 里大约多一条记录（行大小 + 事务头，按 100B 估）；
- 1000 个版本 ≈ `1000 × 100B = 100KB` 的 undo 不能被 purge（因为长事务的 ReadView 还需要它们）；
- 如果表里有 1 万行这样的热点行，undo 会膨胀到 `1 万 × 100KB = 1GB`；
- 同时每次查询要沿更长的版本链回溯，读变慢。

所以监控长事务（`information_schema.innodb_trx`）不是运维洁癖，是性能问题。

---

## 4. 极简模型：三个事务、一行数据

把规模缩到最小：

```
初始：id = 1, balance = 0, trx_id = 0（建表时无事务）

T1（trx_id=10）：UPDATE balance = 100;  COMMIT;
T2（trx_id=20）：UPDATE balance = 200;  （未提交）
T3（trx_id=30）：SELECT balance FROM t WHERE id = 1;
```

### 4.1 T3 的快照长什么样

T3 生成 ReadView 时，活跃事务是 T2（20），T1 已提交：

```
m_ids = [20]
min_trx_id = 20
max_trx_id = 30 （下一个待分配）
creator_trx_id = 30
```

### 4.2 T3 读到什么

- 当前版本 trx_id = 20，20 在 m_ids 里 → 不可见；
- 沿 roll_ptr 找旧版本：trx_id = 10 < min_trx_id(20) → **可见** → 读到 100。

### 4.3 然后 T2 提交，T3 再读一次（RR）

- RR 复用同一个 ReadView，m_ids 还是 `[20]`；
- 版本链上的 20 仍然「在名单里」→ 不可见 → 还是读 100。

**这就是「可重复读」**：不是数据没变，而是 T3 的 ReadView 没变。

### 4.4 换到 RC

- 第二次 SELECT 重新生成 ReadView：此时 T2 已提交，`m_ids = []`；
- 20 不在名单里 → 可见 → 读到 200。

**两个隔离级别的全部差异，就在「ReadView 什么时候生成」这一个动作上。**

---

## 5. 为什么这样设计：三个被否决的方案

### 5.1 否决方案一：只加读写锁（不用多版本）

| 方案 | 读 | 写 |
|---|---|---|
| 纯锁 | 加 S 锁 | 加 X 锁，与 S 互斥 |

被否决的原因：读阻塞写、写阻塞读，并发能力差。互联网业务里读远多于写，让读排队是灾难。

### 5.2 否决方案二：只保留最新版本（靠「读时加锁」保证一致）

如果只有最新版本，事务想「可重复读」就必须一直持锁到事务结束，等于退化成 SERIALIZABLE，并发极差。保留旧版本 + 快照判断，才能在不加锁的情况下读到一致数据。

### 5.3 否决方案三：全局时间戳排序（TSO）

理论上可以给每个事务分配时间戳，按时间戳决定可见性（类似 Spanner 的 TrueTime）。但 MySQL 是单机/主从架构，没有全局授时，维护全局时间戳成本高，而且会引入等待。InnoDB 选择「本地 trx_id + ReadView」的轻量方案。

### 5.4 为什么是 undo log 而不是「另存一份历史表」

- undo log 本身就要为回滚存在，复用它做 MVCC 是「一鱼两吃」；
- 另存历史表要额外写、额外空间、额外同步，成本更高。

---

## 6. 关键参数为什么是这个值

### 6.1 `DB_TRX_ID` 为什么是 6 字节

- InnoDB 设计上用 6B 表示事务号，也就是 48 位，最大 2.8×10^14；
- 8 字节会浪费空间（每行都存），4 字节又不够用；
- 6 字节是「空间」与「寿命」的折中：按每秒 10 万写事务，能用近 90 年。

### 6.2 `DB_ROLL_PTR` 为什么是 7 字节

7B 的指针要编码：undo 表空间号 + undo 页号 + 页内偏移。7 字节足够覆盖大表空间，且不是 8 字节的对齐浪费。

### 6.3 行隐藏开销对页容量的影响（数字推导)

每行固定隐藏开销 `6 + 7 + 5 = 18B`（不含 `DB_ROW_ID`），加上主键 8B 共 26B：

- 1KB 的行，26B 只占 2.5%，影响可忽略；
- 100B 的小行，26B 占 26%，意味着同样的页能放的行数少 `1/4` 左右——小表大宽索引设计时要留意。

### 6.4 `m_ids` 为什么用数组/链表而不是哈希

- 活跃事务数量通常很少（个位数到几十），线性判断足够快；
- ReadView 生成频繁（RC 下每条 SQL 一次），用简单结构分配更快；
- 真正需要快速判断的是「版本链回溯」，那是顺序访问，不是哈希场景。

---

## 7. 版本演进：MySQL 5.6 / 5.7 / 8.0

| 版本 | 与 MVCC 相关的变化 |
|---|---|
| MySQL 5.6 | InnoDB 成为默认引擎，一致性读（ReadView + 版本链）成为默认行为；undo 表空间可独立配置 |
| MySQL 5.7 | 支持 `innodb_undo_tablespaces` 独立 undo 表空间；`innodb_undo_log_truncate` 可回收 undo 空间；长事务监控视图完善 |
| MySQL 8.0 | 默认 2 个 undo 表空间并支持在线 truncate；`information_schema.INNODB_TRX`、`performance_schema` 更完整；**快照读语义未变** |

**注意**：网上很多「8.0 MVCC 大改」的说法不准确。MVCC 的核心（版本链 + ReadView）从 5.x 到 8.0 语义稳定，变化主要在 undo 空间管理、监控和性能上。

---

## 8. 亲手验证：两个会话看 RR 和 RC

> 环境：MySQL 8.0，开两个客户端（会话 A / B）。预期输出已注明，5.7 上结果一致。

### 8.1 准备

```sql
CREATE TABLE t_mvcc (id INT PRIMARY KEY, balance INT) ENGINE=InnoDB;
INSERT INTO t_mvcc VALUES (1, 0);
-- 预期：Query OK, 1 row affected
```

### 8.2 RR 下：快照读不变，当前读变

```sql
-- 会话 A
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
BEGIN;
SELECT balance FROM t_mvcc WHERE id = 1;
-- 预期：balance = 0（此刻生成 ReadView）

-- 会话 B
BEGIN;
UPDATE t_mvcc SET balance = 100 WHERE id = 1;
COMMIT;

-- 会话 A（ReadView 没变）
SELECT balance FROM t_mvcc WHERE id = 1;
-- 预期：balance = 0（还是快照）

UPDATE t_mvcc SET balance = 200 WHERE id = 1;   -- 当前读
SELECT balance FROM t_mvcc WHERE id = 1;
-- 预期：balance = 200（自己改的版本，creator 可见）

COMMIT;
```

### 8.3 RC 下：每次 SELECT 重新生成 ReadView

```sql
-- 会话 A
SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
BEGIN;
SELECT balance FROM t_mvcc WHERE id = 1;   -- 0

-- 会话 B
UPDATE t_mvcc SET balance = 300 WHERE id = 1; COMMIT;

-- 会话 A
SELECT balance FROM t_mvcc WHERE id = 1;
-- 预期：balance = 300（新的 ReadView 能看到已提交数据）
COMMIT;
```

### 8.4 验证「BEGIN 不生成 ReadView」

```sql
-- 会话 A（RR）
BEGIN;                                     -- 不 SELECT
-- 会话 B 更新并提交
-- 会话 A 第一次 SELECT
SELECT balance FROM t_mvcc WHERE id = 1;
-- 预期：能看到 B 的新值（因为 ReadView 是这次 SELECT 才生成的）
```

### 8.5 看活跃事务与长事务

```sql
SELECT trx_id, trx_state, trx_started, trx_mysql_thread_id
FROM information_schema.INNODB_TRX
ORDER BY trx_started;
-- 预期：能看到当前活跃事务及其开始时间，trx_started 很早的就是长事务

SHOW ENGINE INNODB STATUS\G
-- 预期：TRANSACTIONS 段列出活跃事务；HISTORY LIST LENGTH 越大说明 undo 堆积越多
```

---

## 9. 常见误区

| 错误说法 | 正确说法 |
|---|---|
| 「MVCC 解决了幻读」 | 快照读不幻读，当前读仍可能幻读，靠 next-key lock 兜 |
| 「RR 在 BEGIN 时生成快照」 | 在第一次快照读时生成（除非 `WITH CONSISTENT SNAPSHOT`） |
| 「`max_trx_id` 是活跃事务里的最大值」 | 是「下一个要分配」的 ID，即最大值 + 1 |
| 「undo log 提交后立刻删除」 | `update undo` 要等 purge 确认没有 ReadView 需要它 |
| 「RC 隔离级别下没有 MVCC」 | RC 也走 MVCC，只是每条 SELECT 重建 ReadView |
| 「MVCC 让读写完全不冲突」 | 写-写仍靠锁；当前读也加锁 |
| 「二级索引也有独立版本链」 | 版本链只在聚簇索引，二级索引命中后要回表判断可见性 |
| 「可重复读 = 数据真的没变」 | 数据一直在变，是 ReadView 让你「看起来」没变 |

---

## 10. 连续追问 Q&A

### Q1：MVCC 到底解决了什么问题？

解决**读-写冲突**：读不加锁、读到事务开始时的一致快照；写不阻塞读。它不解决写-写冲突（靠锁），也不解决当前读的幻读（靠间隙锁）。

### Q2：版本链是存在哪里的？

存在 undo log（回滚日志）里。聚簇索引的当前行通过 `DB_ROLL_PTR` 指向 undo 中的上一个版本，旧版本里又有 `roll_pointer` 指向更旧的版本，形成单向链表。

### Q3：ReadView 四个字段能默写吗？

`m_ids`（活跃事务列表）、`min_trx_id`（列表最小值）、`max_trx_id`（下一个待分配 ID）、`creator_trx_id`（创建者自己）。

### Q4：可见性判断的四步顺序能不能调换？

不能。必须按「自己 → 小于 min → 大于等于 max → 区间内查 m_ids」的顺序；调换会错误判断边界情况（比如自己的版本）。

### Q5：为什么 RR 能可重复读？

因为 ReadView 在事务内复用：事务开始时活跃的事务列表固定了，之后别人提交的事务不在这个列表里，但它们的 `trx_id` 大于等于 `max_trx_id`，仍然不可见。

### Q6：RR 下第一次 SELECT 之前别人提交的数据，能看到吗？

能。ReadView 是第一次 SELECT 时生成的，所以它看到的是「第一次 SELECT 之前已提交」的数据。这是常被忽略的细节：`BEGIN` 只是开始事务，不是开始快照。

### Q7：快照读和当前读分别有哪些语句？

快照读：普通 SELECT。当前读：`SELECT ... FOR UPDATE`、`SELECT ... LOCK IN SHARE MODE`（8.0 写作 `FOR SHARE`）、UPDATE、DELETE、INSERT。

### Q8：为什么 UPDATE 一定要当前读？

因为要基于最新已提交的数据做修改，否则会覆盖别人的更新（丢失更新）。当前读会加锁，保证修改期间别人改不了。

### Q9：幻读到底解决没有？

快照读不会幻读（ReadView 固定）；当前读会幻读（能看到新插入的行），InnoDB 用 next-key lock（记录锁 + 间隙锁）锁住范围来防幻读。严格说 RR 也没有 100% 消除幻读的边角情况。

### Q10：长事务为什么会让数据库变慢？

长事务的 ReadView 让 `min_trx_id` 卡在很早的位置，之后的 undo 都不能 purge，版本链越来越长，查询回溯越来越慢，undo 表空间膨胀。还会占锁、阻塞 DDL。

### Q11：怎么发现长事务？

`information_schema.INNODB_TRX` 按 `trx_started` 排序；`SHOW ENGINE INNODB STATUS` 看 `HISTORY LIST LENGTH`；`performance_schema.events_transactions_*` 也能追踪。

### Q12：二级索引查询怎么和 MVCC 配合？

二级索引叶子只有索引列和主键，没有版本信息。通过二级索引找到主键后回表，**可见性判断在聚簇索引行上做**；如果只查索引列（覆盖索引），遇到已删除的记录可能还需要回表确认（delete-mark 与 purge 的细节）。

---

## 11. 一张图总结

```
写：UPDATE → 旧值写入 undo，行上 DB_TRX_ID=新事务，DB_ROLL_PTR→旧版本
                                 │
读：生成 ReadView（RR：首次快照读；RC：每条 SELECT）
      │
      ▼
  从当前版本沿版本链回溯：
      ① trx_id == creator        → 可见
      ② trx_id < min_trx_id      → 可见
      ③ trx_id >= max_trx_id     → 不可见（往后找旧版本）
      ④ m_ids 里 → 不可见；否则可见
      │
      ▼
  返回第一个可见版本（这就是「快照」）
```

---

## 12. 一句话复盘

> 每行用 6 字节事务 ID + 7 字节回滚指针，把旧版本用 undo log 串成链；读时生成一个四字段的 ReadView，按「自己的、比最老的还老、比未来的还新、是否在活跃名单」四步判断版本可见性。RR 与 RC 的唯一区别是 ReadView 生成时机：RR 一次事务一个，RC 一条 SQL 一个。

---

## 13. 自测题（先自己答，再看答案）

**1. 某个版本的 trx_id = 25，ReadView 的 min_trx_id = 20、max_trx_id = 100、m_ids = [20, 30]，可见吗？**
答案：可见。25 落在 `[20, 100)` 区间内，但不在 `m_ids = [20, 30]` 里，说明它在生成 ReadView 之前已经提交，所以可见。若 `m_ids = [20, 25, 30]`，25 在名单里，则不可见。

**2. 为什么 RR 下 `BEGIN` 后第一次 SELECT 之前别人提交的数据能看到？**
答案：ReadView 是第一次快照读时生成的，生成时刻那些事务已提交，所以可见。

**3. `update undo` 什么时候能被清理？**
答案：等 purge 线程确认没有活跃 ReadView 需要这个版本（即该版本对所有 ReadView 都可见）后清理；`insert undo` 提交后即可删。

**4. 一条 SQL 在 RC 下生成几次 ReadView？**
答案：一次（每条 SELECT 生成一次）；在 RR 下一个事务只生成一次（首次快照读）。

**5. 为什么 UPDATE 之后的 SELECT 能看到自己改的值？**
答案：自己改的版本 `trx_id == creator_trx_id`，可见性判断第一步就返回可见。

---

## 14. 关联文件

- 深一层（追问树 + 源码细节）：[MVCC 与事务隔离](../../10-deep-dive/mysql/02-MVCC与事务隔离.md)
- 同层精讲：[B+ 树索引](01-B+树索引.md)｜[三大日志与崩溃恢复](03-三大日志与崩溃恢复.md)
- 排查工具：[MySQL 与 Redis](../../04-database/MySQL与Redis.md)
- 返回：[精讲索引](../00-索引.md)
