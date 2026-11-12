# Kafka 可靠性与幂等（acks / 事务 / Exactly-Once）

> 面试权重：5/5　｜　追问深度：**L5（幂等生产者去重表 / 事务 2PC / LSO 过滤）**
> 一句话定位：Kafka 的"不丢不重"不是一个开关，而是**生产端 acks+重试+幂等**、**Broker 端副本+`min.insync.replicas`**、**消费端提交时机+幂等消费**三层各自解决问题后拼出来的结果。任何一层漏掉，可靠性就有洞。

**本文件用法**：先背「三端各丢在哪」的表，再逐层追问。答不出 PID/Sequence 与 LSO，就是只背了名词。
[返回深度追问索引](../00-索引.md)

---

## L1 一句话答案（10 秒能说出口）

不丢靠：生产端 `acks=all + retries + delivery.timeout.ms`，Broker 端 `replication.factor=3 + min.insync.replicas=2 + 关闭 unclean 选举`，消费端"处理完再手动提交"。不重靠：**幂等生产者**（PID + 每分区 Sequence Number，Broker 去重）+ **事务**（`transactional.id` 跨分区原子写 + `read_committed`）+ **消费端业务幂等**。**Exactly-Once 在 Kafka 内部由事务实现，跨系统只能"至少一次 + 业务幂等"做到效果上的 EOS。**

---

## L2 原理层：三端各自的丢与重

### 2.1 消息可能丢在哪

| 环节 | 丢失场景 | 解法 |
|---|---|---|
| 生产端 | `acks=0`；`acks=1` 时 Leader 未同步就宕机；重试耗尽异常没处理 | `acks=all` + 重试 + 失败回调/告警 |
| Broker 端 | 副本未同步 Leader 挂 + unclean 选举；`min.insync.replicas=1` | 副本 3、`min.insync=2`、关 unclean |
| 消费端 | 先提交 offset 后处理；多线程部分失败整体提交 | 处理成功再提交 + 幂等消费 |
| 运维 | retention 太短、Topic 误删、磁盘满 | 监控 lag/磁盘、谨慎 `delete.topic.enable` |

### 2.2 `acks` 三档

```
acks=0：发出即忘，不等响应 → 吞吐最高、可能静默丢
acks=1：Leader 写入本地（Page Cache）即 ack → Leader 挂且未同步则丢
acks=all(=-1)：等 ISR 内所有副本都写入才 ack → 最安全，依赖 ISR 大小与 RTT
```

### 2.3 `retries` 与 `delivery.timeout.ms`

- `retries`（2.1+ 默认 `Integer.MAX_VALUE`）不再决定总次数，**真正上限是 `delivery.timeout.ms`（默认 120000）**；约束 `delivery.timeout.ms >= linger.ms + request.timeout.ms`。
- 重试带来：**重复**（Broker 已写但 ack 丢 → 重发再写一条）、**乱序**（`max.in.flight > 1` 时后发先至）。幂等解决重复，`max.in.flight ≤ 5` + 幂等解决乱序。

### 2.4 幂等生产者：PID + Sequence Number（必背）

```
启动 → InitProducerIdRequest → Broker 分配 PID + epoch
每条消息 key = (PID, Topic-Partition)
每个 (PID, Partition) 维护单调递增 Sequence Number（按 batch 递增，从 0 开始）
Broker 为每个 (PID, Partition) 缓存最近 5 个 batch 的 (baseSeq, lastSeq)
  ├── seq == expected：正常追加
  ├── seq <= lastSeq（重复 batch）：直接 ack，不写盘（去重）
  └── seq > expected+1（缺批）：OutOfOrderSequence，生产者重发/重建会话
```

**边界**：只在**单分区、单生产者会话**内去重；Producer 重启（新 PID）不幂等；只解决"生产者重试导致的重复"，不管消费端重复。前提 `acks=all`、`retries>0`、`max.in.flight≤5`（3.0 起 `enable.idempotence` 默认 true，自动满足）。

### 2.5 事务：跨分区、跨会话原子写

```
① transactional.id（全局唯一、跨重启稳定）→ 定位 Transaction Coordinator
   （= __transaction_state 对应分区 Leader，hash(transactional.id) % 50）
② initTransactions()：InitProducerId，PID + epoch+1（旧实例被 fence）
③ beginTransaction() → 发消息（可跨多分区）→ sendOffsetsToTransaction()（offset 也入事务）
④ commitTransaction() / abortTransaction()
```

**2PC 落地**：Coordinator 在 `__transaction_state` 记状态（Ongoing/PrepareCommit/CompleteCommit…）与参与分区；消息写入各分区时附带 **control batch**（COMMIT/ABORT 标记）；提交先写 PREPARE，再向所有分区写 COMMIT 标记，最后 COMPLETE。任意一步崩溃，恢复后按状态机继续或回滚。**Fencing**：同 `transactional.id` 新实例让 epoch+1，旧僵尸实例再写即 `InvalidProducerEpoch` 被拒——这就是防"双写脑裂"。

### 2.6 `isolation.level` 与 LSO

| 级别 | 行为 | 代价 |
|---|---|---|
| `read_uncommitted`（默认） | 能读到事务中间态甚至被 abort 的消息 | 可能读到垃圾 |
| `read_committed` | 只返回已提交事务 + 非事务消息，跳过 abort 的记录 | **要等最早未结束事务** |

**LSO（Last Stable Offset）**= 第一个未完成事务的起始 offset。`read_committed` 消费者只能读到 `<= LSO`，并跳过 abort 范围——**所以一个长事务会卡住整个分区的 committed 读**。

### 2.7 消费端：`auto.offset.reset` 与三种提交

- `auto.offset.reset` 只在**没有有效已提交 offset**时生效（新组、位移越界被删）：`earliest`（全量重放！）、`latest`、`none`（抛异常）。
- `enable.auto.commit=true`（默认）：`poll()` 时按 `auto.commit.interval.ms`（5s）提交上一批最大 offset——**没处理完也可能被提交 → 丢**。
- `commitSync()`：同步、失败重试、语义最强；`commitAsync()`：异步、**失败不重试**（避免旧位移覆盖新位移），关闭前用 sync 兜底。
- 异步/多线程处理时按分区记录**连续完成**的水位，提交 `Map<TopicPartition, OffsetAndMetadata>`，不能提交空洞。

### 2.8 消息积压（lag）排查与扩容

```
排查：kafka-consumer-groups.sh --describe 看 LAG = LEO - committedOffset
     区分全分区积压（消费能力）vs 单分区（key 热点）；看消费者 GC、下游 RT、max.poll.interval.ms 超时导致的 Rebalance 风暴
扩容：消费者数 < 分区数 → 直接加消费者（超过分区数无用）
     已相等 → 扩分区 + 加消费者（注意 key 路由变化）；消费逻辑批量化/异步化
     临时方案：先把消息转存到多分区新 Topic 再慢慢消费
```

---

## L3 底层层：Broker 去重表与事务状态机

### 3.1 `ProducerStateManager`

Broker 为每个分区维护 `producerIdMap`：PID → `ProducerState`（epoch、lastSequence、最近 5 个 batch 的序列范围、lastOffset）。`handleProduceRequest` → `ReplicaManager.appendRecords` → `UnifiedLog.append` 时校验：

- 事务消息先校验 `(PID, epoch)`，不合法 → `InvalidProducerEpoch`；
- `batch.baseSequence <= lastSequence` 且落在缓存区间 → `isDuplicate=true`，**不追加，直接返回原 offset**；
- 乱序 → `OutOfOrderSequenceNumber`。
- **只缓存 5 个 batch** 是因为服务端 `max.in.flight` 上限就是 5，超过 5 的乱序批次协议层不允许，内存可控。

### 3.2 `__transaction_state` 与控制标记

- 事务状态 Topic：50 分区、compact，key = transactional.id；Coordinator = 对应分区 Leader。
- 事务消息与普通 record 混排，额外有 **Control Record**（`isControlBatch`，value 为 COMMIT/ABORT）。
- 消费者从 FetchResponse 的 `abortedTransactions` 得知哪些事务被中止，读到时丢弃。

### 3.3 EOS 的三种实现层次

| 层次 | 做法 | 保证/缺口 |
|---|---|---|
| 幂等生产者 | PID+Seq 去重 | 只消除**生产端重试重复**，不管消费端 |
| Kafka 事务 EOS | 幂等 + 事务 + `read_committed` + offset 入事务（`processing.guarantee=exactly_once_v2`） | 覆盖"Kafka→处理→Kafka"全链路 |
| 效果 EOS（业务最常用） | **至少一次投递 + 消费端业务幂等**（唯一键/去重表/状态机） | 跨系统也不重，但要业务自己设计 |

---

## L4 追问树（面试官一路往下问，你能撑到第几层？）

> 规则：第 1-3 层必备，4-6 层拉开差距，7 层以后是加分。

### 第 1 层｜Kafka 怎么保证消息不丢？
**答**：三端。生产端 `acks=all` + 重试 + 失败有回调；Broker 端副本 3、`min.insync.replicas=2`、关闭 unclean 选举；消费端处理成功再手动提交 offset，并配死信/重试兜底。缺任何一端都有洞。

### 第 2 层｜acks=0/1/all 区别？
**答**：0 发出去不管（可能静默丢）；1 Leader 写本地就 ack（Leader 挂且未同步会丢）；all 等 ISR 全部写入（最安全）。`acks=all` 必须配 `min.insync.replicas≥2`，否则 ISR 只剩 Leader 时等价于 acks=1。

### 第 3 层｜acks=all 就一定不丢吗？还有哪些丢消息场景？
**答**：不一定。① 没配 `min.insync.replicas`，ISR 收缩到 1；② 发生 unclean 选举；③ 生产端重试耗尽抛 `TimeoutException` 但没人处理；④ 消费端自动提交把未处理消息 commit 了；⑤ retention 到期被删。**acks 只解决"生产端确认"这一段。**

### 第 4 层｜重试会带来什么问题？
**答**：**重复**（Broker 写成功但 ack 丢，客户端重发）和**乱序**（`max.in.flight>1` 时后一批成功、前一批重发）。所以 `retries>0` 时要么开幂等（3.0 默认开），要么把 `max.in.flight` 降到 1（吞吐大幅下降）。

### 第 5 层｜幂等生产者原理？
**答**：`InitProducerIdRequest` 拿到 PID+epoch；每条消息按 (PID, 分区) 打**单调递增 Sequence Number**；Broker 缓存每个 (PID, 分区) 最近 5 个 batch 的序列范围，收到的 seq 小于期望判重复、直接 ack 不写盘，大于期望报乱序。**效果：重试不产生重复，且分区内保序。**

### 第 6 层｜幂等能覆盖跨会话、跨分区吗？
**答**：不能。幂等是 **PID + 分区** 维度的：Producer 重启后 PID 变了，旧消息无法判重；跨分区各 Seq 独立，没有全局原子。跨会话+跨分区靠**事务**：`transactional.id` 跨重启稳定，epoch 递增把旧实例 fence 掉。

### 第 7 层｜Kafka 事务怎么实现？
**答**：两阶段提交 + Transaction Coordinator：`transactional.id` 定位 Coordinator → `initTransactions` 拿 PID、epoch+1 → `AddPartitionsToTxn` 注册参与分区 → 消息带事务标记写入 → 提交时 Coordinator 先写 PREPARE_COMMIT 到 `__transaction_state`，再向所有参与分区写 COMMIT 控制标记，最后 COMPLETE；任意一步崩溃，重启后按状态机继续 commit 或 abort。

### 第 8 层｜消费者怎么知道哪些消息没提交？
**答**：`read_committed` 时 Broker 只返回 `<= LSO` 的消息，并在 FetchResponse 带 `abortedTransactions`；消费者读到 abort 事务范围内的 record 直接丢弃。LSO 是第一个未结束事务的起始 offset，**长事务会卡整个分区的 committed 读**。

### 第 9 层｜重复消费有哪几种场景？怎么解？
**答**：① 生产端重试没开幂等 → 同一条消息在 Topic 里重复（幂等生产者）；② 处理完未提交 offset 就崩溃/Rebalance → 新消费者从上次提交位置重放（处理完再提交）；③ 自动提交把未处理 offset 提交了（手动提交 + 连续水位）；④ 手动提交了 offset 但业务事务回滚 / 反过来（事务消息 + 消费幂等键）；⑤ 两个消费者组重复订阅（消费组规划）。**统一兜底：消费端幂等。**

### 第 10 层｜`auto.offset.reset=earliest` 是不是每次从头消费？
**答**：不是。只在**找不到有效已提交 offset**（新 group、offset 过期被删、越界）时生效。新上线消费组配 earliest 会把历史全量重放，上线前应用 `--reset-offsets` 显式指定起点，别靠 reset 配置撞运气。

### 第 11 层｜`commitSync` 和 `commitAsync` 怎么选？异步处理怎么提交？
**答**：`commitSync` 阻塞、失败重试、语义稳；`commitAsync` 不阻塞、失败不重试（避免旧位移覆盖新位移），关闭前 sync 兜底。异步/多线程处理不能直接用 poll 返回的最大 offset 提交，要按分区记录**连续完成**的水位，只提交连续部分，否则会跳过未完成消息。

### 第 12 层（终局）｜一次幂等生产者重试，Broker 端到底怎么判重？源码流程？
**答**：`KafkaApis.handleProduceRequest` → `ReplicaManager.appendRecords` → `Partition.appendRecordsToLeader` → `UnifiedLog.append` → `ProducerStateManager`：取出 `(PID, epoch)` 对应 `ProducerState`，比较 `batch.baseSequence` 与 `lastSequence+1`；若 baseSeq ≤ lastSeq 且落在最近 5 个缓存 batch 区间内 → `isDuplicate=true`，**不追加、直接返回原 offset**；若 > lastSeq+1 → `OutOfOrderSequenceException`；epoch 不匹配 → `InvalidProducerEpochException`（已被 fence）。随后更新 lastSequence/lastOffset，状态定期快照到 `.snapshot` 文件以便重启恢复。

---

## L5 名词拆解表（每个名词都拆开）

| 名词 | 是什么 | 为什么存在 | 面试追问点 |
|---|---|---|---|
| `acks` | 生产端确认级别 0/1/all | 吞吐与可靠性取档 | all 与 min.insync 的配合 |
| `retries` / `delivery.timeout.ms` | 重试次数 / 总时长上限 | 应对瞬时故障、防无限重试 | 谁先耗尽、与 linger 的约束 |
| PID | 幂等生产者会话 ID | 标识"同一生产者"以便去重 | 重启后 PID 变，幂等失效 |
| Sequence Number | 每 (PID, 分区) 的单调序号 | Broker 判重、判乱序 | 缓存 5 个 batch 的原因 |
| `enable.idempotence` | 开启幂等（3.0 默认 true） | 消除重试重复、保序 | 强制 acks=all、影响 max.in.flight |
| `transactional.id` | 跨重启稳定的事务身份 | 跨会话去重 + fencing | 与 PID 的区别 |
| Transaction Coordinator | 管理事务状态机的 Broker | 2PC 协调者 | 按 transactional.id 定位 |
| `__transaction_state` | 内部 compact Topic（50 分区） | 持久化事务状态 | 状态机有哪些状态 |
| `isolation.level` / LSO | 消费者隔离级别 / 首个未完成事务起点 | 隔离未提交与中止事务 | read_committed 的延迟代价 |
| `auto.offset.reset` | 无位移时的起点策略 | 新组/越界兜底 | 为何新组 earliest 会全量重放 |
| `commitSync`/`commitAsync` | 同步/异步提交 | 语义与吞吐权衡 | async 为何失败不重试 |

---

## 代码验证

```java
// 幂等 + 事务生产者：跨分区原子写（消费-处理-生产的 EOS 基础）
Properties p = new Properties();
p.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, "broker1:9092,broker2:9092");
p.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
p.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
p.put(ProducerConfig.ENABLE_IDEMPOTENCE_CONFIG, "true");          // 幂等
p.put(ProducerConfig.TRANSACTIONAL_ID_CONFIG, "order-task-tx-1"); // 事务身份，跨重启稳定
p.put(ProducerConfig.ACKS_CONFIG, "all");

KafkaProducer<String, String> producer = new KafkaProducer<>(p);
producer.initTransactions();
try {
    producer.beginTransaction();
    producer.send(new ProducerRecord<>("task-events", "task-1", "RUNNING"));
    producer.send(new ProducerRecord<>("task-audit",  "task-1", "started"));
    producer.commitTransaction();     // 两条要么都可见、要么都不可见
} catch (Exception e) {
    producer.abortTransaction();
    throw e;
} finally {
    producer.close();
}

// 事务消费者：只读已提交 + 处理完手动提交
Properties c = new Properties();
c.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, "broker1:9092");
c.put(ConsumerConfig.GROUP_ID_CONFIG, "task-consumer");
c.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
c.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
c.put(ConsumerConfig.ISOLATION_LEVEL_CONFIG, "read_committed");
c.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, "false");
try (KafkaConsumer<String, String> consumer = new KafkaConsumer<>(c)) {
    consumer.subscribe(List.of("task-events"));
    while (true) {
        for (ConsumerRecord<String, String> r : consumer.poll(Duration.ofMillis(500))) {
            // 业务幂等：DB 唯一键 / Redis SETNX / 状态机 CAS；失败不提交，进重试或死信
        }
        consumer.commitSync();
    }
}
```

```bash
# 看消费者组堆积
bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --group task-consumer
# GROUP  TOPIC  PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG  CONSUMER-ID

# 上线前显式指定位移（别依赖 auto.offset.reset）
bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --group g1 \
  --topic task-events --reset-offsets --to-earliest --execute

# 查看事务状态 Topic
bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic __transaction_state
```

---

## 高频错误（面试官最爱抓的）

| 错误说法 | 正确说法 |
|---|---|
| 「acks=all 就绝对不丢」 | 还要 `min.insync.replicas≥2` + 禁 unclean 选举 + 处理生产端超时异常 |
| 「开了幂等就 Exactly-Once」 | 幂等只去重生产端重试；跨分区/跨会话要事务，跨系统要业务幂等 |
| 「幂等能跨 Producer 重启」 | PID 会变，跨会话不幂等；要 `transactional.id` |
| 「retries 设大点就一直重试」 | `delivery.timeout.ms` 到点就抛 `TimeoutException` |
| 「auto.offset.reset=earliest 每次从头读」 | 只在该组没有有效已提交位移时生效 |

---

## 关联文件

- 架构与副本基础：[Kafka 架构与 ISR](./01-Kafka架构与ISR.md)｜[Kafka 零拷贝](./02-Kafka零拷贝.md)
- 异步落地的工程化：[异步与削峰](../backend-opt/02-异步与削峰.md)
- 项目落点：报告平台 异步任务若用 MQ，"任务状态机 + 幂等键"就是这里的**效果 EOS**

> **自测标准**：能说清三端各丢在哪、能白板画 PID+Sequence 去重流程、能解释事务 2PC 与 LSO、能区分"Kafka 内 EOS"和"业务效果 EOS"，算过关。
