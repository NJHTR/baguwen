# 执行计划与慢 SQL 优化（EXPLAIN & Optimization）

> 面试权重：5/5　｜　追问深度：**L5（MySQL 优化器成本模型与源码）**
> 一句话定位：面试问"怎么优化慢 SQL"，答"加索引"只能拿一半分。真正的链路是：慢查询日志定位 → `EXPLAIN` 看执行计划 → 判断优化器为什么这么选 → 改 SQL/索引/分页方式。

**本文件用法**：从 L1 往下读，每读完一层，合上书自问自答。**停在答不出的那一层，就是你的真实水平线。**
[返回深度追问索引](../00-索引.md)

---

## L1 一句话答案（10 秒能说出口）

`EXPLAIN` 里先看 `type`（访问方式，至少要到 range，最好 ref/const）和 `Extra`（有没有 `Using filesort`/`Using temporary`），再看 `key` 是否用上期望的索引、`rows` 扫描行数、`filtered` 过滤比例。优化器在多个执行方案之间按"IO 成本 + CPU 成本"估算选最便宜的那个；深分页慢是因为要扫描并丢弃前 N 行，用延迟关联或游标分页解决。

---

## L2 原理层：EXPLAIN 每个字段到底在看什么

### 2.1 字段速查（面试会被要求"挑重点说"）

| 字段 | 含义 | 关注点 |
|---|---|---|
| `id` | 查询序号，越大越先执行 | 子查询/union 的执行顺序 |
| `select_type` | SIMPLE / PRIMARY / SUBQUERY / DERIVED / UNION | 有没有派生表（`DERIVED` 常意味着临时表） |
| `type` | 访问类型 | **最重要**，见下表 |
| `possible_keys` | 可能用到的索引 | 有但 `key` 为 NULL = 优化器放弃了 |
| `key` | 实际用的索引 | 是否符合预期 |
| `key_len` | 用到的索引字节长度 | 判断联合索引用了几列 |
| `ref` | 与索引比较的对象 | const / 列 / 函数 |
| `rows` | 预估扫描行数 | 越大越可疑 |
| `filtered` | 按条件过滤后的剩余比例 | 很低说明索引选择性差 |
| `Extra` | 附加信息 | **第二重要**，见 2.3 |

### 2.2 type 从好到坏

```
system > const > eq_ref > ref > range > index > ALL
```

- `const`：主键/唯一索引等值命中，最多一行
- `eq_ref`：join 时被驱动表用主键/唯一索引
- `ref`：普通索引等值
- `range`：索引范围扫描（`between`、`in`、`>`）
- `index`：全索引扫描（比 ALL 好一点，但扫全部索引）
- `ALL`：全表扫描 —— 线上要重点消灭

### 2.3 Extra 里的"红绿灯"

| Extra | 含义 | 判定 |
|---|---|---|
| `Using index` | 覆盖索引，不回表 | 低风险：好 |
| `Using index condition` | ICP，索引层先过滤 | 低风险：好 |
| `Using where` | Server 层再过滤 | 中风险：正常 |
| `Using filesort` | 无法用索引排序，额外排序 | 高风险：要优化 |
| `Using temporary` | 用了临时表（group by / distinct / union） | 高风险：要优化 |
| `Using join buffer (hash join)` | 8.0 哈希连接 | 中风险：视数据量 |
| `Select tables optimized away` | 优化器直接从索引统计拿到结果 | 低风险：很好 |

### 2.4 优化器怎么"算账"

优化器对每个候选方案估算 `cost = IO 成本 + CPU 成本`：

- 读一个数据页 ≈ `io_block_read_cost`（默认 1.0），从 Buffer Pool 读 ≈ `memory_block_read_cost`（默认 0.25）
- 每判断一行 ≈ `cpu_tuple_cost` 等
- 最终选 cost 最小的方案（连接顺序、单表访问方式、是否用索引）

```sql
SELECT * FROM mysql.server_cost;   -- 8.0 的 CPU 类成本
SELECT * FROM mysql.engine_cost;   -- IO 类成本
```

**关键**：`rows` 是**估算值**，来自索引统计信息（`cardinality`），统计不准 → 成本算错 → 选错索引。

### 2.5 深分页为什么慢

```sql
-- 慢：要扫描 1000010 行，回表 1000010 次，最后只返回 10 行
SELECT * FROM t_order ORDER BY id LIMIT 1000000, 10;
```

三种优化：

| 方案 | 写法 | 适用 |
|---|---|---|
| 游标分页 | `WHERE id > 上次最大 id ORDER BY id LIMIT 10` | 连续翻页、允许跳页丢失 |
| 延迟关联 | `SELECT o.* FROM t_order o JOIN (SELECT id FROM t_order ORDER BY id LIMIT 1000000,10) t ON o.id = t.id` | 必须跳页 |
| 覆盖索引先取 id | 同延迟关联，子查询只查 id，不产生回表 | 同上 |

---

## L3 底层层：优化器内部流程与统计信息

### 3.1 一条 SQL 的优化流程

```
SQL 解析 → 预处理 → 逻辑优化（子查询展开、外连接简化、条件下推）
→ 物理优化（JOIN::optimize → make_join_plan → best_access_path）
   ├── 对每个表枚举访问方式（全表 / 各索引 range / ref / index merge）
   ├── 枚举连接顺序（表多时用贪心/剪枝，不是全排列）
   └── 用 cost 模型累加，选最小
→ 生成执行计划 → 执行器调用 InnoDB 接口
```

### 3.2 统计信息从哪来、为什么不准

- `cardinality`（基数）估算来自**采样索引页**：`innodb_stats_persistent_sample_pages` 默认 20 页（不是全表）。
- 统计信息持久化：`innodb_stats_persistent=ON`（默认），重启不用重算；自动更新由 `innodb_stats_auto_recalc` 控制（表变化超过 10% 触发）。
- 不准的典型原因：数据倾斜（90% 都是 status=0）、大事务批量导入后没 `ANALYZE`、采样页恰好偏。
- 8.0 增强：**直方图** `ANALYZE TABLE t UPDATE HISTOGRAM ON status WITH 64 BUCKETS`，对倾斜列更准；`index skip scan`（8.0.13）可跳过最左列；`EXPLAIN ANALYZE` 给出实际耗时。

### 3.3 优化器"选错索引"的四种典型场景

1. 统计信息过期/不准 → `ANALYZE TABLE` 或建直方图
2. 回表成本估低了（`rows` 估小）→ 强制索引 `FORCE INDEX`（临时）、改写 SQL
3. 多个索引都能用，优化器选了区分度差的 → 调整索引顺序/删除冗余索引
4. 函数/隐式转换让候选索引消失 → 改 SQL（见 01 文件第 6 层）

---

## L4 追问树（面试官一路往下问，你能撑到第几层？）

> 规则：从上往下问。**第 1-3 层是应届生必备，第 4-6 层是拉开差距，第 7 层以后是"能答出来就是加分"。**

### 第 1 层｜EXPLAIN 你重点看哪几列？
**答**：`type`（有没有全表扫）、`key`（用没用上期望索引）、`rows`（扫描量）、`Extra`（有没有 filesort/temporary/覆盖索引）。`possible_keys` 有但 `key` 为空，说明优化器主动放弃了索引，要查原因。

### 第 2 层｜`type` 从好到坏排一下，`ref` 和 `range` 有什么区别？
**答**：`system > const > eq_ref > ref > range > index > ALL`。`ref` 是等值匹配索引，通常能定位到少量记录；`range` 是索引范围扫描，扫描量取决于范围大小。线上至少要达到 `range`，`ALL` 必须处理。

### 第 3 层｜`Using filesort` 和 `Using temporary` 严重吗？
**答**：严重度看数据量。`filesort` 是 order by 用不上索引、在内存/磁盘排序，数据量大时会用到磁盘临时文件、变慢；`temporary` 是用了临时表，常见于 group by 无索引、distinct、union。优化方向：让排序/分组列走联合索引、减少返回列、先用索引过滤再 join。

### 第 4 层｜优化器是怎么选执行计划的？
**答**：枚举单表访问方式和连接顺序，对每个方案按成本模型算"IO 成本 + CPU 成本"（读页成本 + 处理行成本），选最小的。它依赖统计信息（cardinality）估算行数，所以统计不准就会选错。

### 第 5 层｜明明有索引，为什么走了全表扫描？
**答**：常见四类：① 列上做函数/运算；② 隐式类型转换（varchar 列 = 数字）；③ 区分度太低，优化器算完发现回表比全表还贵；④ 统计信息过期/数据倾斜，`rows` 估错。定位方法：`EXPLAIN` + `optimizer_trace` 看它在比较哪些方案、各方案成本多少。

### 第 6 层｜深分页为什么慢？具体怎么优化？
**答**：`LIMIT 1000000,10` 要先读出并回表 1000010 行、丢掉前 1000000 行，代价随偏移量线性增长。优化：① 游标分页 `WHERE id > last_id ORDER BY id LIMIT 10`（推荐，O(1) 定位）；② 延迟关联：先用覆盖索引子查询取 10 个 id，再 join 回表；③ 业务上限制最大页数。

### 第 7 层｜`ORDER BY` 怎么才能用上索引避免 filesort？
**答**：排序顺序要和联合索引的前缀一致，且不能中间隔列、不能混用升降序（8.0 可以用降序索引）。比如索引 `(user_id, created_at)`，`WHERE user_id=? ORDER BY created_at` 能用上；`ORDER BY amount` 就用不上。

### 第 8 层｜join 怎么写才快？驱动表怎么选？
**答**：小表驱动大表；被驱动表的 join 列必须有索引（否则是 BNL 全表扫）；能用 `STRAIGHT_JOIN` 的场景明确指定驱动表；join 字段类型/字符集要一致，否则隐式转换导致索引失效。8.0 有 hash join，但大表 join 仍要控制数据量。

### 第 9 层｜统计信息不准怎么办？
**答**：`ANALYZE TABLE` 重算统计信息；倾斜列建直方图（8.0）；调大 `innodb_stats_persistent_sample_pages` 提高采样精度；临时用 `FORCE INDEX` 验证猜想；根治是优化 SQL/索引结构，让优化器不需要猜。

### 第 10 层｜线上一条慢 SQL，你的排查步骤？
**答**：① 慢查询日志（`slow_query_log`、`long_query_time`）或 `performance_schema` 找出 SQL；② `EXPLAIN` / `EXPLAIN ANALYZE` 看计划和实际耗时；③ 看 `rows`、回表次数、排序/临时表；④ `SHOW PROFILE`/`performance_schema` 看各阶段耗时；⑤ 改索引或改 SQL，压测对比；⑥ 上线后回归慢日志。

### 第 11 层｜为什么 `count(*)` 也慢？怎么优化？
**答**：InnoDB 的 `count(*)` 必须遍历索引计数（不像 MyISAM 存了总行数），但会选最小的二级索引扫描。优化：计数单独维护（缓存/计数表）、限制业务上的实时 count、用 `count(1)`/`count(*)` 都可以但别用 `count(可空列)`、分页场景用近似值或 `SQL_CALC_FOUND_ROWS`（已不推荐）。

### 第 12 层（终局）｜优化器源码里"选索引"发生在哪？
**答**：`JOIN::optimize()`（`sql/sql_select.cc`）→ `make_join_plan()` 枚举连接顺序 → `best_access_path()` 对每张表枚举访问方式，调用 `handler::read_cost/info` 拿估算行数与成本；成本常数来自 `server_cost`/`engine_cost` 表；最终 `JOIN::best_plan` 落成执行计划，再由 `JOIN::exec()` 调用引擎接口。

---

## L5 名词拆解表（"每个名词都拆开"）

| 名词 | 是什么 | 为什么存在 | 面试追问点 |
|---|---|---|---|
| `type` | 表的访问方式 | 一眼判断 SQL 好坏 | 各值的含义与顺序 |
| `key_len` | 实际用到的索引字节数 | 判断联合索引使用了几列 | 变长字段/字符集如何影响 |
| `filtered` | 条件过滤后的剩余百分比 | 评估索引选择性 | 很低说明索引不好 |
| `rows` | 预估扫描行数 | 成本模型的核心输入 | 为什么不准（采样估算） |
| filesort | 无法用索引时的排序 | 内存/磁盘排序 | 全字段排序 vs rowid 排序 |
| temporary | 内部临时表 | group by/distinct/union 需要 | 何时落盘 |
| 成本模型 | cost = IO + CPU | 在方案间做取舍 | `server_cost`/`engine_cost` |
| cardinality | 索引列不同值的估算数 | 判断区分度 | 采样 20 页、倾斜 |
| optimizer_trace | 优化器决策过程日志 | 解释"为什么选它" | 开启与解读 |
| 延迟关联 | 先取 id 再 join 回表 | 深分页减少回表 | 为什么能快 |
| `EXPLAIN ANALYZE` | 带实际耗时的执行计划（8.0.18+） | 估算 vs 实际对比 | 看 loops/actual time |

---

## 代码验证（本地实例执行，关注注释里的预期）

```sql
-- 准备：造 100 万行（用存储过程或 INSERT ... SELECT 生成，略）
CREATE TABLE t_order_big (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  user_id BIGINT NOT NULL,
  status TINYINT NOT NULL,
  amount DECIMAL(10,2),
  created_at DATETIME NOT NULL,
  KEY idx_user_created (user_id, created_at),
  KEY idx_status (status)
) ENGINE=InnoDB;

-- 1. 深分页：type=index 或 ALL，rows 很大
EXPLAIN SELECT * FROM t_order_big ORDER BY id LIMIT 1000000, 10;

-- 2. 延迟关联：子查询走覆盖索引（key=PRIMARY, Extra=Using index）
EXPLAIN SELECT o.* FROM t_order_big o
JOIN (SELECT id FROM t_order_big ORDER BY id LIMIT 1000000, 10) t ON o.id = t.id;

-- 3. 游标分页：直接 range 定位（type=range），与偏移量无关
EXPLAIN SELECT * FROM t_order_big WHERE id > 1000000 ORDER BY id LIMIT 10;

-- 4. order by 用上联合索引（Extra 不应出现 filesort）
EXPLAIN SELECT * FROM t_order_big WHERE user_id = 1001 ORDER BY created_at LIMIT 10;
-- 5. order by 用不上索引（Extra: Using filesort）
EXPLAIN SELECT * FROM t_order_big WHERE user_id = 1001 ORDER BY amount LIMIT 10;

-- 6. 看优化器到底在比什么（8.0）
SET optimizer_trace = 'enabled=on';
EXPLAIN SELECT * FROM t_order_big WHERE status = 1;
SELECT * FROM information_schema.OPTIMIZER_TRACE\G
SET optimizer_trace = 'enabled=off';

-- 7. 统计信息与直方图
ANALYZE TABLE t_order_big;
ANALYZE TABLE t_order_big UPDATE HISTOGRAM ON status WITH 64 BUCKETS;
SELECT * FROM information_schema.COLUMN_STATISTICS;

-- 8. 慢查询日志开关（生产按需开）
SET GLOBAL slow_query_log = ON;
SET GLOBAL long_query_time = 1;
SET GLOBAL log_queries_not_using_indexes = ON;
-- 分析：mysqldumpslow -s t /var/lib/mysql/slow.log | head -20
```

```java
// 游标分页的 Java 写法（MyBatis-Plus 同理，核心是 where id > lastId）
public List<Order> pageByCursor(long lastId, int size) {
    return jdbcTemplate.query(
        "SELECT * FROM t_order_big WHERE id > ? ORDER BY id LIMIT ?",
        (rs, rowNum) -> mapOrder(rs), lastId, size);
}
// 注意：前端要保存上一页最后一条 id；跳页场景改用延迟关联，不要 offset 硬翻
```

---

## 高频错误（面试官最爱抓的）

| 错误说法 | 正确说法 |
|---|---|
| 「rows 是实际扫描行数」 | 是优化器的估算值 |
| 「有索引就一定会走」 | 优化器按成本选，可能主动放弃 |
| 「深分页加索引就行」 | 索引改变不了"要跳过前 N 行"的本质 |
| 「`count(*)` 比 `count(1)` 慢」 | InnoDB 下两者等价，都会选最小索引扫描 |
| 「`SELECT *` 只是多传数据」 | 还会导致回表、放弃覆盖索引 |
| 「优化器选错只能 FORCE INDEX」 | 先 ANALYZE/直方图/改写 SQL，FORCE 是临时手段 |

---

## 关联文件

- 广度版：[MySQL与Redis](../../04-database/MySQL与Redis.md)
- 同层追问：[B+ 树索引](./01-B+树索引.md)｜[MVCC 与事务隔离](./02-MVCC与事务隔离.md)｜[锁与死锁](./03-锁与死锁.md)
- 典型场景：政企数字化项目的报表慢 SQL——先 `EXPLAIN` 确认 `type`/`rows`，再决定加 `(tenant_id, created_at)` 联合索引还是改游标分页
- 索引：[深度追问索引](../00-索引.md)

> **自测标准**：能看着任意一条 `EXPLAIN` 说出①②③④四个字段的问题与改法，能写出三种深分页优化并解释为什么快，能说清优化器成本模型的输入，算过关。
