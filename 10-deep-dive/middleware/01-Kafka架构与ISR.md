# Kafka 架构与 ISR（副本同步与元数据层）

> 面试权重：5/5　｜　追问深度：**L5（副本同步协议 / HW 推进 / KRaft Raft 元数据层）**
> 一句话定位：Kafka 是「把消息当提交日志写磁盘」的分布式系统。Topic 切 Partition 解决并行与顺序，Partition 做多副本解决可用性，**ISR 是"哪些副本还配当 Leader"的活名单，HW 是"消费者能看到哪"的边界线**。

**本文件用法**：从 L1 往下读，每读完一层合上书自问自答。停在哪层答不出，你的真实水平线就在哪层。
[返回深度追问索引](../00-索引.md)

---

## L1 一句话答案（10 秒能说出口）

一个 Topic 被切成多个 Partition 分布在多个 Broker 上，每个 Partition 有 1 个 Leader + N 个 Follower 副本。**读写都走 Leader，Follower 主动拉取同步**；能和 Leader 保持同步（默认 30 秒内追上）的副本组成 **ISR**，只有 ISR 里的副本有资格在 Leader 挂掉后被选为新 Leader。Leader 维护 **LEO**（下一条要写的 offset）和 **HW**（ISR 中最小 LEO），**消费者只能读到 HW 之前的消息**。

---

## L2 原理层：从 Broker 到消费者组

### 2.1 分层结构

```
Kafka Cluster
├── Broker-0 / Broker-1 / Broker-2        ← 一个 Kafka 进程 = 一个 Broker
│   └── Topic: order-events               ← 逻辑消息分类
│       ├── Partition-0  Leader=Broker-0  ← 并行与顺序的最小单位
│       │   ├── Replica on Broker-1（Follower）
│       │   └── Replica on Broker-2（Follower）
│       ├── Partition-1  Leader=Broker-1
│       └── Partition-2  Leader=Broker-2
└── Controller（某个 Broker 兼任）          ← 选主 / ISR 变更 / 扩缩容
```

**三条铁律**：① **Partition 内有序、Partition 间无序**（全局有序只能单分区）；② **读写只走 Leader**，Follower 只同步 + 待命，保证单写者顺序；③ 分区路由：指定 partition > `hash(key) % partitionCount` > 未指定（2.4 前轮询，之后 **粘性分区**：攒满一批再换分区，减少请求数）。

### 2.2 Replica 与 ISR

副本因子一般 3（1 主 2 从）。ISR 是**动态名单**：

| 事件 | 结果 |
|---|---|
| Follower 落后时间 > `replica.lag.time.max.ms`（默认 30000） | 被踢出 ISR（收缩） |
| 被踢出的 Follower 重新追上 Leader 的 LEO | 重新加入 ISR（扩张） |
| ISR 变化 | 通知 Controller → 持久化 → 广播 `LeaderAndIsr` |

> 老版本用 `replica.lag.max.messages`（落后条数），流量突增时会误踢导致 `acks=all` 无法写入；**所以改成按时间判断，面试必须答时间维度**。

### 2.3 HW 与 LEO（必考）

```
Leader     LEO = 8   HW = 6
Follower-A LEO = 8              ← 已同步，在 ISR
Follower-B LEO = 6              ← 落后 2 条但 30s 内追过 → 仍在 ISR
HW = min(ISR 各副本 LEO) = 6  → 消费者可见 offset 0~5
```

- **LEO**：该副本下一条要写的 offset（日志末尾）。
- **HW**：ISR 中最小 LEO，**HW 之前的消息才算已提交、才对消费者可见**，也是 Leader 切换不丢消息的边界。
- 重启的 Follower LEO 可能超过 Leader，需按 HW 截断，再用 **Leader Epoch** 修正（见 L3）。

### 2.4 元数据两种模式

| | ZooKeeper 模式（≤3.x） | KRaft（2.8 预览 / 3.3 生产 / 4.0 移除 ZK） |
|---|---|---|
| 元数据 | ZK znode（`/brokers/topics/...`） | 内部 Topic `__cluster_metadata`（Raft 复制） |
| Controller 选举 | 抢临时节点 `/controller`，先到先得 | Controller quorum 用 Raft 选 Active |
| 规模/恢复 | 分区上万后 ZK 成瓶颈，恢复分钟级 | 百万分区，故障秒级切换 |

### 2.5 分区分配策略与消费者组

| 策略 | 分配方式 | Rebalance 类型 |
|---|---|---|
| Range | 按 Topic 逐个均分，前 n 个多一个 | Eager |
| RoundRobin | 所有分区排成一圈轮询 | Eager |
| Sticky | 尽量保留上次分配、最小迁移 | Eager |
| CooperativeSticky | 粘性 + **增量迁移** | Cooperative |

3.x 默认 `RangeAssignor,CooperativeStickyAssignor`。组内**一个 Partition 只分给一个消费者**（并行度上限 = 分区数），不同组各消费一份全量。Offset 提交到 **`__consumer_offsets`**（默认 50 分区、`cleanup.policy=compact`，key = groupId+topic+partition）；组的 **Coordinator** = 该 Topic 对应分区的 Leader（`hash(groupId) % 50`）。

**Partition 数怎么选**：`分区数 ≈ 目标吞吐 ÷ 单分区实测吞吐`，再留 2-3 倍余量；分区越多并行度越高，但每分区至少 3 个文件（句柄暴涨）、元数据/Controller 压力、Rebalance 与故障恢复时间都上升。经验：**单 Broker 控制在几千分区以内，且分区数要 ≥ 消费者并行度上限**（否则加消费者无效）。

---

## L3 底层层：副本同步协议与 HW 推进

### 3.1 Follower 是「拉」不是「推」

Follower 用 `FetchRequest` 带 `fetchOffset` 向 Leader 拉数据，Leader 侧处理：

```java
// 简化版 Partition.fetchRecords 思路
// 1. 校验 fetchOffset 合法（>= logStartOffset 且 <= LEO）
// 2. 从本地 Log 读 [fetchOffset, min(fetchOffset+maxBytes, HW)) —— Follower 也只能读到 Leader 的 HW
// 3. 更新该 Follower 的 remoteLEO = fetchOffset + 返回记录数
// 4. maybeIncrementLeaderHW() 尝试推进 HW
```

**为什么是拉**：推模式需要 Broker 感知每个 Follower 的速度做限速；拉模式天然背压——Follower 慢就少拉。

### 3.2 HW 推进与 Leader Epoch

`HW = min(Leader.LEO, ISR 各 Follower 的 remoteLEO)`，只在 remoteLEO 变化、ISR 收缩、追加日志时尝试推进，**且只能单调递增**。因为依赖下一次 Fetch，HW 更新有延迟——这是 Leader 切换可能丢 HW 之后消息的根因。

**Leader Epoch**：每个 Leader 任期一个单调编号，日志记录 `(epoch, startOffset)`。新 Leader 广播 epoch，Follower 发现不一致时通过 `OffsetsForLeaderEpochRequest` 精确截断到上一任期结束位置，避免"按旧 HW 截断误删已提交数据"。

### 3.3 Controller 与 Leader 选举

**ZK 模式**：Broker 抢 `/controller` 临时节点 → 监听元数据变更 → Broker 下线时从 ISR 选第一个存活副本当新 Leader（默认 AR 顺序 + ISR 优先）→ 写 ZK → 广播 `LeaderAndIsr`。
**KRaft**：Controller 节点组成 Raft quorum（3/5 个），元数据以日志写入 `__cluster_metadata` 并复制，Broker 作为 Observer 订阅；**没有 ZK watcher 风暴，切换秒级**。

### 3.4 日志目录（追问落点）

```
/kafka-logs/order-events-0/
├── 00000000000000000000.log        ← 消息本体（Segment，log.segment.bytes 默认 1GB 滚动）
├── 00000000000000000000.index      ← 稀疏索引：相对 offset → 物理位置
├── 00000000000000000000.timeindex  ← 时间戳 → 相对 offset
└── leader-epoch-checkpoint         ← (epoch, startOffset)
```

---

## L4 追问树（面试官一路往下问，你能撑到第几层？）

> 规则：第 1-3 层必备，4-6 层拉开差距，7 层以后是加分。

### 第 1 层｜说说 Kafka 架构，一条消息从生产到消费经过哪些组件？
**答**：Producer 按 key 算 Partition → 找 Leader Broker → `ProduceRequest` → Leader 追加本地日志并同步 Follower → Follower ack → Leader 更新 HW 后给 Producer ack → Consumer 发 `FetchRequest` → 只读到 HW 之前 → 处理完把 offset 提交到 `__consumer_offsets`。

### 第 2 层｜Partition 和 Replica 什么关系？为什么要 Leader/Follower？
**答**：Partition 是逻辑分片（并行与顺序单位），Replica 是它的物理副本（因子 3 = 1 主 2 从）。读写只走 Leader 保证**同一分区单写者**（省掉分布式并发控制、天然有序）；Follower 同步数据保证 Leader 挂了能顶上，并可跨机架分布。

### 第 3 层｜ISR 是什么？哪些副本在 ISR 里？
**答**：与 Leader 保持同步的副本集合，默认以 `replica.lag.time.max.ms=30s` 为界：Follower 每次 Fetch 后 Leader 更新 `lastCaughtUpTimeMs`，超过 30s 没追到 LEO 就踢出。**ISR 只含副本不含消费者**；`acks=all` 与 `min.insync.replicas` 都在 ISR 上做文章。

### 第 4 层｜`replica.lag.max.messages` 为什么被废弃？
**答**：按"落后条数"判断，流量突增时 Follower 一下落后几万条，即使一直在追也会被全踢出 ISR，导致 `acks=all` 直接不可用（NotEnoughReplicas）。按"最后一次追上的时间"判断后，只要在持续追就不踢，只惩罚真正卡住/宕机的副本。

### 第 5 层｜HW 和 LEO 区别？消费者能读到哪？
**答**：LEO 是副本日志末尾，HW 是 ISR 最小 LEO。消费者只能读 `offset < HW`，因为只有这些消息保证至少在 ISR 多副本上存在；HW 之后的消息虽写在 Leader 磁盘上，但 Leader 此刻挂掉新 Leader 不一定有，不能暴露给消费者。

### 第 6 层｜`acks=all` 时 Leader 等谁？和 `min.insync.replicas` 如何配合？
**答**：Leader 写入本地后**等 ISR 中所有副本都写入**才 ack（不是等 HW）；`min.insync.replicas=2` 是写入前置门槛：ISR < 2 时直接拒绝写入（NotEnoughReplicas）。`replication.factor=3 + min.insync.replicas=2 + acks=all` = 容忍 1 副本挂掉且不丢消息。

### 第 7 层｜ISR 只剩 Leader 自己时，`acks=all` 会怎样？
**答**：语义退化为 `acks=1`；若配了 `min.insync.replicas=2`，ISR(1) < 2 就直接拒写。这是刻意的取舍：**宁可不可写，也不接受只有一份副本的数据**。所以高可用告警必须盯 `UnderReplicatedPartitions`。

### 第 8 层｜`unclean.leader.election` 是什么？Controller 挂了怎么办？
**答**：允许非 ISR 副本当 Leader：开了可用性优先但会丢消息/日志截断，关了（默认 false）宁可分区不可用。Controller 挂了：ZK 模式重新抢临时节点并从 ZK 重建元数据（分区多时分钟级）；KRaft 模式 Raft quorum 立刻选新 Active，秒级恢复。

### 第 9 层｜消费者组什么时候 Rebalance？Eager 和 Cooperative 区别？
**答**：触发：成员加入/离开（含 `session.timeout.ms` 默认 45s 心跳超时）、订阅 Topic 分区数变化、订阅关系变化。Eager：全员 revoke 全部分区（整个组停消费）再重新分配；Cooperative：只迁移需要动的分区，其他人继续消费，可能多轮才收敛但停顿极小。配合 `group.instance.id` 静态成员和 `max.poll.interval.ms` 防误踢。

### 第 10 层｜`__consumer_offsets` 为什么 50 分区、为什么 compact？
**答**：50 分区让不同组的 offset 提交分散到不同 Broker（`hash(groupId) % 50` 定位 Coordinator，避免热点）；compact 是因为只需要每个 `(group, topic, partition)` 的最新 offset，历史值无意义，压缩后 Topic 不膨胀。

### 第 11 层（终局）｜Leader 收到 Follower 的 Fetch 请求后，HW 在源码里怎么推进？
**答**：`Partition.fetchRecords()` 读出 `[fetchOffset, min(fetchOffset+maxBytes, HW))` 的数据，把该副本 `remoteLEO = fetchOffset + records.size`，同时更新 `lastCaughtUpTimeMs`；随后 `maybeIncrementLeaderHW()` 计算 `min(leaderLog.logEndOffset, ISR 所有 remoteLEO)`，若大于当前 HW 就更新并唤醒 `delayedFetch` 与等待 `acks=all` 的 Producer 请求。**所以 HW 推进依赖"下一次 Fetch"，天生有延迟；消费者可读上界也被卡在 HW——这就是需要 `fetch.max.bytes` / `replica.fetch.max.bytes` 控制单次拉取的原因。**

---

## L5 名词拆解表（每个名词都拆开）

| 名词 | 是什么 | 为什么存在 | 面试追问点 |
|---|---|---|---|
| Broker | 一个 Kafka 进程，管理若干分区日志 | 水平扩展与副本分布的物理载体 | 单 Broker 能扛多少分区、受什么限制 |
| Topic / Partition | 逻辑分类 / 物理分片 | 命名空间 + 并行有序 | 分区越多越好吗、代价是什么 |
| Replica | 分区副本（AR 集合） | 容灾 | 副本因子能大于 Broker 数吗（不能） |
| Leader / Follower | 副本角色，读写走 Leader | 单写者保证顺序 | Follower 能否服务读（follower fetch 仅特定场景） |
| Controller | 集群元数据管理者 | 集中决策选主/ISR/扩缩容 | ZK 临时节点 vs KRaft Raft |
| ISR | 与 Leader 同步的副本集合 | 选主候选 + `acks=all` 等待集合 | 落后怎么判断、变更怎么传播 |
| LEO / HW | 日志末尾 / ISR 最小 LEO | 副本进度 / 消费者可见边界 | 为什么 HW 之后不可见、截断问题 |
| Leader Epoch | Leader 任期编号 | 修复 HW 截断丢数据 | `OffsetsForLeaderEpoch` 截断逻辑 |
| `min.insync.replicas` | 写入要求的最小 ISR | 用拒写换安全 | 与 acks=all 的可用性代价 |
| Unclean 选举 | 允许非 ISR 当 Leader | 极端情况保可用 | 默认 false，开启丢数据 |
| `__consumer_offsets` | 内部 compact Topic 存位移 | offset 也要高可用 | 50 分区、Coordinator 定位 |
| Rebalance | 消费者组重分配分区 | 成员/分区变化后恢复均衡 | Eager vs Cooperative、超时参数 |
| KRaft | Raft 自管元数据的模式 | 支撑更大规模、更快恢复 | `__cluster_metadata`、Controller quorum |

---

## 代码验证

```java
// 生产者：acks=all + 幂等，观察分区与 offset
Properties p = new Properties();
p.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, "broker1:9092,broker2:9092,broker3:9092");
p.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
p.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
p.put(ProducerConfig.ACKS_CONFIG, "all");                 // 等 ISR 全部写入
p.put(ProducerConfig.ENABLE_IDEMPOTENCE_CONFIG, "true"); // 幂等（自动要求 acks=all）
try (KafkaProducer<String, String> producer = new KafkaProducer<>(p)) {
    RecordMetadata md = producer.send(
        new ProducerRecord<>("order-events", "order-1", "{\"id\":1}")).get();
    System.out.printf("partition=%d offset=%d%n", md.partition(), md.offset());
}

// 消费者：手动提交 + 从最早读，验证"只能读到 HW 之前"
Properties c = new Properties();
c.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, "broker1:9092");
c.put(ConsumerConfig.GROUP_ID_CONFIG, "order-consumer");
c.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
c.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
c.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, "false");
c.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
try (KafkaConsumer<String, String> consumer = new KafkaConsumer<>(c)) {
    consumer.subscribe(List.of("order-events"));
    while (true) {
        for (ConsumerRecord<String, String> r : consumer.poll(Duration.ofMillis(500))) {
            // 业务处理
        }
        consumer.commitSync();       // 处理完才提交
    }
}
```

```bash
# 看副本与 ISR：Isr 比 Replicas 少 = 有副本被踢出
bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic order-events
# Partition: 0  Leader: 1  Replicas: 1,2,0  Isr: 1,2,0

# 扩缩容不会自动搬数据，需要副本重分配
bin/kafka-reassign-partitions.sh --bootstrap-server localhost:9092 \
  --reassignment-json-file reassign.json --execute --verify
```

---

## 高频错误（面试官最爱抓的）

| 错误说法 | 正确说法 |
|---|---|
| 「Follower 也对外提供读服务」 | 读写只走 Leader（follower 读仅用于跨 DC 复制） |
| 「acks=all 是等所有副本（含非 ISR）」 | 只等 ISR；`min.insync.replicas` 控制 ISR 低于阈值时拒写 |
| 「HW 就是 Leader 的 LEO」 | HW = ISR 中最小 LEO，可能远小于 Leader LEO |
| 「消费者能读到 LEO 之前的消息」 | 只能读到 HW 之前的消息 |
| 「ISR 用落后消息条数判断」 | 0.10.1 后按 `replica.lag.time.max.ms` 时间判断 |
| 「加 Broker 后旧分区会自动均衡」 | 不会，需要 `kafka-reassign-partitions.sh` |
| 「unclean 选举默认开着」 | 默认 false，开了才可能在 ISR 全挂时用落后副本顶上 |

---

## 关联文件

- 纵深下一层：[Kafka 零拷贝与高性能](./02-Kafka零拷贝.md)｜[Kafka 可靠性与幂等](./03-Kafka可靠性与幂等.md)
- 系统设计里的 MQ 选型与高可用：[系统设计入门](../../06-system-design/系统设计入门.md)
- 项目落点：报告平台的异步任务通道、数字人的流式消息通道都可套这套副本模型
- 广度对照：[MySQL与Redis](../../04-database/MySQL与Redis.md)（持久化与副本思路）

> **自测标准**：能不停顿从 L1 讲到第 7 层，能手画 HW/LEO 图并解释"为什么只能读到 HW"，能说清 `acks=all + min.insync.replicas` 的取舍，算过关。
