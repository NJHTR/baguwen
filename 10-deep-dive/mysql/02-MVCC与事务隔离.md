# MVCC 与事务隔离（Multi-Version Concurrency Control）

> 面试权重：5/5　｜　追问深度：**L5（InnoDB 事务子系统与源码）**
> 一句话定位：MySQL 靠「读不加锁、写不阻塞读」撑住高并发。所有「RR 和 RC 到底差在哪」「可重复读为什么还能读到新数据」「快照读和当前读」的追问，答案都是 undo 版本链 + ReadView。

**本文件用法**：从 L1 往下读，每读完一层，合上书自问自答。**停在答不出的那一层，就是你的真实水平线。**
[返回深度追问索引](../00-索引.md)

---

## L1 一句话答案（10 秒能说出口）

MVCC 是"一致性非锁定读"：每行记录有隐藏的 `DB_TRX_ID`（最后修改它的事务 ID）和 `DB_ROLL_PTR`（指向 undo log 里上一个版本），多个版本用指针串成版本链。读的时候生成一个 ReadView，用四个字段判断"版本链上哪个版本对我可见"，从而在不加锁的情况下读到事务开始时的数据。RR 在事务第一次快照读时生成 ReadView 并复用，RC 每条 SQL 都重新生成。

---

## L2 原理层：四个隔离级别、两种读、一套判断

### 2.1 隔离级别与它解决/没解决的问题

| 隔离级别 | 脏读 | 不可重复读 | 幻读 | InnoDB 的实现 |
|---|---|---|---|---|
| READ UNCOMMITTED | 会 | 会 | 会 | 基本不用 |
| READ COMMITTED | 不会 | 会 | 会（当前读） | 每条语句新建 ReadView |
| REPEATABLE READ（默认） | | | 快照读不会，当前读靠 next-key lock 防 | 首次快照读建 ReadView，事务内复用 |
| SERIALIZABLE | | | | 读加共享锁 / 退化成串行 |

**注意**：SQL 标准里 RR 允许幻读，InnoDB 的 RR 用"快照读 + 间隙锁"把幻读基本堵住了，但**当前读仍可能幻读**（见第 7 层）。

### 2.2 快照读 vs 当前读

| | 快照读（一致性读） | 当前读（锁定读） |
|---|---|---|
| 语句 | 普通 `SELECT` | `SELECT ... FOR UPDATE` / `LOCK IN SHARE MODE` / `UPDATE` / `DELETE` / `INSERT` |
| 读哪个版本 | 按 ReadView 判断可见版本 | **总是读最新已提交版本**，并加锁 |
| 加锁 | 不加锁 | 加行锁/间隙锁/next-key lock |

### 2.3 版本链是怎么串起来的

```
聚簇索引行记录
├── 列数据 ...
├── DB_TRX_ID   = 6B，最近一次修改这行的事务 ID
└── DB_ROLL_PTR = 7B，指向 undo log 中的旧版本
        │
        ▼
   undo record（旧版本）: 旧列值 + DB_TRX_ID + roll_pointer
        │
        ▼
   undo record（更旧版本）...
```

- `insert undo`：只用于回滚，事务提交后可以直接删除
- `update undo`：MVCC 需要用它重建旧版本，事务提交后不能马上删，要等 **purge 线程**确认没有 ReadView 需要它才回收
- 长事务 → 大量 update undo 不能 purge → 版本链变长、undo 表空间膨胀、查询变慢

### 2.4 ReadView 四个字段与可见性判断（必须能默写）

| 字段 | 含义 |
|---|---|
| `m_ids` | 生成 ReadView 时，所有**活跃（未提交）**事务 ID 的列表 |
| `min_trx_id` | `m_ids` 中的最小值 |
| `max_trx_id` | 生成时**下一个将要分配**的事务 ID（不是 m_ids 最大值） |
| `creator_trx_id` | 创建这个 ReadView 的事务 ID |

对版本链上某个版本的 `trx_id` 依次判断：

1. `trx_id == creator_trx_id` → **可见**（自己改的）
2. `trx_id < min_trx_id` → **可见**（在 ReadView 之前就已提交）
3. `trx_id >= max_trx_id` → **不可见**（ReadView 之后才开启的事务）
4. `min_trx_id <= trx_id < max_trx_id`：在 `m_ids` 里 → **不可见**（还没提交）；不在 → **可见**（已提交）

不可见就顺着 `roll_pointer` 找上一个版本，重复判断，直到 `DB_ROLL_PTR` 为空（表示这是最初版本）。

### 2.5 RR 与 RC 的差异只有一句话

- **RC**：每条 `SELECT` 都生成新的 ReadView → 每次读都能看到别人新提交的数据（不可重复读）
- **RR**：事务内**第一次快照读**时生成 ReadView，之后所有快照读复用 → 事务内看到的数据定格
- 陷阱：`BEGIN` 不是生成时机，`START TRANSACTION WITH CONSISTENT SNAPSHOT` 才是让 `BEGIN` 时立刻建 ReadView 的语法

---

## L3 底层层：事务 ID、undo、purge 怎么配合

### 3.1 事务 ID 与行格式

- InnoDB 维护全局递增的 `trx_id`（`trx_sys`），事务提交/回滚后 ID 不回退；超过 2^48 会回卷（现实中几乎不可能，但有 6B 上限）。
- 行格式（COMPACT/DYNAMIC）的隐藏字段：`DB_TRX_ID`(6B) + `DB_ROLL_PTR`(7B) + 无主键时的 `DB_ROW_ID`(6B)。
- 每次 `UPDATE` 不是原地改，而是**写一条新版本**（或原地改并记录 undo），旧值进 undo log，`DB_TRX_ID` 更新为当前事务，`DB_ROLL_PTR` 指向 undo。

### 3.2 purge：垃圾回收不在提交时发生

```
事务提交 → update undo 进入 history list
        → purge 线程扫描，找出「比所有活跃 ReadView 的 min_trx_id 都小」的 undo
        → 这些版本的 trx_id 已经"人人可见"，可以安全物理删除
        → 否则保留（还有老事务需要看）
```

**长事务的最大危害**：它持有的 ReadView 让 `min_trx_id` 卡住，所有比它晚的 undo 都不能 purge，undo 表空间持续膨胀，`innodb_history_list_length` 飙升。

### 3.3 二级索引与 MVCC 的配合（高频盲区）

- 二级索引叶子只有「索引列 + 主键」，**没有 trx_id 版本链**。
- 通过二级索引查数据时，先拿到主键再回表，**可见性判断发生在聚簇索引的行上**。
- 所以 `SELECT 唯一索引列` 走覆盖索引时，可能读到"索引里存在但已被删除"的记录——因为二级索引删除是打 `delete mark`，purge 前索引项还在，覆盖索引不查聚簇索引就无法判断删除，必须回表。**结论：覆盖索引 + 已删除数据，是要回表判断的。**

### 3.4 当前读如何拿到最新版

`UPDATE/DELETE` 走 `row_search_mvcc` 的当前读路径：先定位记录，沿版本链找到**最新已提交版本**；若最新版本是未提交事务写的，则等待锁或走 semi-consistent read（RC 下 update 碰到不匹配的行会先释放锁再重试）。写成功后新版本 `DB_TRX_ID` = 当前事务。

---

## L4 追问树（面试官一路往下问，你能撑到第几层？）

> 规则：从上往下问。**第 1-3 层是应届生必备，第 4-6 层是拉开差距，第 7 层以后是"能答出来就是加分"。**

### 第 1 层｜什么是 MVCC？
**答**：多版本并发控制。每行有 `DB_TRX_ID` 和 `DB_ROLL_PTR`，旧版本存在 undo log 里串成版本链；读时用 ReadView 判断哪个版本可见，实现"读不加锁、读写不互相阻塞"。

### 第 2 层｜MVCC 解决什么问题？不解决什么？
**答**：解决读-写冲突（快照读不加锁、读到一致快照），保证 RC/RR 的隔离性。不解决写-写冲突（靠锁），也不解决当前读的幻读（靠 next-key lock）。

### 第 3 层｜版本链是怎么串起来的？
**答**：聚簇索引行上的 `DB_ROLL_PTR` 指向 undo log 中的旧版本记录，旧版本里又有 `roll_pointer` 指向更旧的版本，形成单向链表；`DB_TRX_ID` 标明是哪个事务写的。判断可见性时沿链回溯。

### 第 4 层｜ReadView 有哪四个字段？分别什么意思？
**答**：`m_ids` 活跃事务列表、`min_trx_id` 活跃最小 ID、`max_trx_id` 下一个要分配的 ID、`creator_trx_id` 创建者自己。判断顺序：自己的 → 可见；小于 min → 可见；大于等于 max → 不可见；处于区间内看是否在 m_ids 里。

### 第 5 层｜RR 和 RC 的差异到底在哪？
**答**：只差 ReadView 的生成时机。RC 每条语句建一个，RR 事务内第一次快照读建一个后复用。所以在 RC 下每次 SELECT 都能看到别人新提交的数据（不可重复读），RR 下不行。

### 第 6 层｜`BEGIN` 就会生成 ReadView 吗？
**答**：不会。RR 下要在**第一次快照读（SELECT）**时才生成；如果 `BEGIN` 之后、第一次 SELECT 之前别人提交了数据，这条 SELECT 仍然能看到（因为 ReadView 是在这之后建的）。要 `BEGIN` 就定格，得用 `START TRANSACTION WITH CONSISTENT SNAPSHOT`。

### 第 7 层｜RR 能完全解决幻读吗？
**答**：不能。**快照读**不幻读（ReadView 固定，新插入的行不可见）；**当前读**（`SELECT ... FOR UPDATE`、`UPDATE`）会读到新插入的行，这就是幻读。InnoDB 用 next-key lock（记录锁 + 间隙锁）在当前读时锁住范围来防幻读。经典场景：事务 A 先快照读，事务 B 插入并提交，A 再 `UPDATE` 全表 → A 会"看到"新行（当前读），这就是 RR 下的幻读。

### 第 8 层｜为什么 RR 下 `UPDATE` 能看到别人刚提交的新值，SELECT 却看不到？
**答**：因为 `UPDATE` 是当前读，读的是最新已提交版本；`SELECT` 是快照读，按 ReadView 读历史版本。所以"可重复读"只对快照读成立，改数据时必须看到最新值，否则会覆盖别人的更新。

### 第 9 层｜undo log 什么时候能删？
**答**：`insert undo` 提交后即可删；`update undo` 要等 purge 线程确认没有活跃 ReadView 需要它（即该版本对所有 ReadView 都可见）后才能删。长事务会卡住 purge，导致 undo 膨胀、查询变慢。

### 第 10 层｜长事务为什么危险？怎么发现？
**答**：长事务的 ReadView 让 `min_trx_id` 停在很早的位置，中间所有 undo 无法 purge，版本链变长、回表变慢、undo 表空间/ibdata 膨胀，还会占锁、阻塞 DDL。发现：`information_schema.innodb_trx` 按 `trx_started` 排序、`information_schema.innodb_metrics` 里 `trx_rseg_history_len`，或 `SHOW ENGINE INNODB STATUS` 的 HISTORY LIST。

### 第 11 层｜RC 下没有间隙锁，那幻读怎么办？业务上怎么选隔离级别？
**答**：RC 下当前读会幻读，但 RC 有优势：间隙锁少、并发高、死锁少，很多互联网公司用 RC + 业务幂等/唯一索引兜底。选型看场景：金融强一致用 RR 或悲观锁，高并发互联网业务常用 RC。

### 第 12 层（终局）｜InnoDB 源码里一次一致性读怎么找到旧版本？
**答**：入口是 `row_search_mvcc()`（`row0sel.cc`），通过 `ReadView::changes_visible(trx_id)` 判断可见性；不可见时调用 `row_sel_build_prev_vers()` → `trx_undo_prev_version_build()`（`trx0undo.cc`）从 `DB_ROLL_PTR` 取 undo 记录、用 undo 的 `roll_pointer` 继续回溯，重建出旧版本再判断，直到可见或链尾。

---

## L5 名词拆解表（"每个名词都拆开"）

| 名词 | 是什么 | 为什么存在 | 面试追问点 |
|---|---|---|---|
| MVCC | 多版本并发控制 | 读不加锁、读写不阻塞 | 是否解决写-写冲突 |
| ReadView | 一次读的一致性视图 | 定义"哪些事务对我是可见的" | 四个字段、生成时机 |
| `m_ids` | 活跃未提交事务 ID 列表 | 判断区间内事务是否已提交 | 与 `min/max_trx_id` 的关系 |
| `min_trx_id` | 活跃事务最小 ID | 比它小的一定已提交 | 长事务为何卡住 purge |
| `max_trx_id` | 下一个待分配 ID | 比它大的一定是之后才开始的 | 注意是"下一个"不是"最大" |
| `creator_trx_id` | 创建 ReadView 的事务 | 自己的修改永远可见 | 事务内 update 后 select |
| `DB_TRX_ID` | 行隐藏字段，最后修改事务 | 判断版本归属 | 6 字节、事务回卷 |
| `DB_ROLL_PTR` | 行隐藏字段，指向 undo 旧版本 | 串起版本链 | 7 字节、insert/update undo 区别 |
| 快照读 | 普通 SELECT，按 ReadView 读 | 高并发下免锁读 | 是否加锁 |
| 当前读 | FOR UPDATE / UPDATE / DELETE 等 | 必须看到最新版本并加锁 | 与幻读的关系 |
| insert undo | 插入回滚日志 | 回滚用，提交即删 | 为什么不等 purge |
| update undo | 更新回滚日志 | MVCC 重建旧版本需要 | purge 条件 |
| purge | 后台清理 undo 的线程 | 回收不再需要的版本 | `history list length` 告警 |
| semi-consistent read | RC 下 update 先放锁再重试 | 减少锁冲突 | RC 特有优化 |

---

## 代码验证（开两个 mysql 客户端，按顺序执行，观察结果）

```sql
-- 准备
CREATE TABLE t_mvcc (id INT PRIMARY KEY, amount INT) ENGINE=InnoDB;
INSERT INTO t_mvcc VALUES (1, 100);

-- ===== 会话 A（RR）=====
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
BEGIN;
SELECT amount FROM t_mvcc WHERE id = 1;          -- 看到 100，此刻生成 ReadView

-- ===== 会话 B =====
BEGIN; UPDATE t_mvcc SET amount = 200 WHERE id = 1; COMMIT;

-- ===== 回到会话 A =====
SELECT amount FROM t_mvcc WHERE id = 1;          -- ① 仍 100（快照读，旧版本可见）
UPDATE t_mvcc SET amount = 300 WHERE id = 1;     -- ② 当前读：基于 200 改，行级锁
SELECT amount FROM t_mvcc WHERE id = 1;          -- ③ 300（自己改的版本 creator 可见）
COMMIT;

-- 验证 RC 的差异：同样的步骤换成 READ COMMITTED，① 会看到 200

-- 验证 ReadView 生成时机（RR）：BEGIN 后先不 SELECT，等 B 提交后再第一次 SELECT
-- 此时能看到 B 的新值——证明 ReadView 建于第一次快照读，而不是 BEGIN

-- 查看活跃事务与长事务（线上排查必用）
SELECT trx_id, trx_state, trx_started, trx_mysql_thread_id
FROM information_schema.innodb_trx ORDER BY trx_started;
SHOW ENGINE INNODB STATUS\G   -- 看 TRANSACTIONS 段与 HISTORY LIST LENGTH
```

---

## 高频错误（面试官最爱抓的）

| 错误说法 | 正确说法 |
|---|---|
| 「MVCC 解决了幻读」 | 快照读不幻读，当前读会；靠 next-key lock 兜 |
| 「RR 是 BEGIN 时生成快照」 | 是第一次快照读时生成（除非 `WITH CONSISTENT SNAPSHOT`） |
| 「`max_trx_id` 是活跃事务最大值」 | 是下一个要分配的 ID（最大值 + 1） |
| 「undo log 提交后立刻删除」 | `update undo` 要等 purge；只有 `insert undo` 提交即删 |
| 「RC 下没有 MVCC」 | RC 也走 MVCC，只是每条语句重建 ReadView |
| 「MVCC 让读写完全不冲突」 | 写-写仍靠锁；当前读也会加锁 |
| 「二级索引也有版本链」 | 版本链只在聚簇索引，二级索引需回表判断 |

---

## 关联文件

- 广度版：[MySQL与Redis](../../04-database/MySQL与Redis.md)
- 同层追问：[B+ 树索引](./01-B+树索引.md)｜[锁与死锁](./03-锁与死锁.md)｜[执行计划与 SQL 优化](./04-执行计划与SQL优化.md)
- 典型场景：政企数字化项目里"报表读到的数据前后不一致"——先查是不是长事务/RC 隔离级别导致的
- 索引：[深度追问索引](../00-索引.md)

> **自测标准**：能不看书写出 ReadView 四个字段 + 可见性四步判断，能说清 RR/RC 唯一差异和 `BEGIN` 陷阱，能现场复现"快照读不变、当前读变"的实验，算过关。
