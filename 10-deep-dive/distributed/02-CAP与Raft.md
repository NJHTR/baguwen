# CAP 与 Raft

> 面试权重：4/5　｜　追问深度：**L5（Raft 的 term/选举/日志复制/commitIndex / 脑裂与租约 / ZAB 对比）**
> 一句话定位：CAP 说的是「网络分区一定发生，所以只能在一致性 C 与可用性 A 之间取舍」；Raft 是把这个取舍做成 **CP** 的工程答案：用 term 把时间分段、用多数派投票选主、用日志复制 + commitIndex 保证「已提交的日志一定在多数派上」。

[返回深度追问索引](../00-索引.md)

## L1 一句话答案（10 秒能说出口）

CAP：一致性、可用性、分区容忍三者最多同时满足两个，而分布式系统里 **P 必须保留**，所以真实系统只能选 CP（etcd、ZooKeeper、HBase）或 AP（Eureka、Cassandra）。Raft 是 CP 共识算法：节点分 Leader/Follower/Candidate，用**任期 term** 和**随机选举超时**选主，Leader 把日志通过 `AppendEntries` 复制到多数派后才算 committed，客户端读请求走 Leader（或 readIndex/lease）保证线性一致。

## L2 原理层：CAP 取舍 + Raft 的三个子问题

| 组合 | 含义 | 代表系统 |
|---|---|---|
| CP | 分区时拒绝写入/读，保证一致 | etcd、ZooKeeper、HBase、Consul |
| AP | 分区时继续服务，允许读到旧数据 | Eureka、Cassandra、DynamoDB、Redis Cluster（部分场景） |
| CA | 单机才可能，分布式里不存在 | 单机数据库 |

**BASE**：Basically Available（基本可用）+ Soft state（软状态）+ Eventually consistent（最终一致），是 AP 系统的工程化表述。多数派读写公式：`W + R > N` 即可读到最新值（N=3、W=2、R=2）。

**Raft 把共识拆成三个子问题**：

| 子问题 | 手段 | 关键约束 |
|---|---|---|
| 选主（Leader Election） | 任期 term + 随机选举超时 + 多数派投票 | 同一 term 最多一个 Leader |
| 日志复制（Log Replication） | `AppendEntries` + `nextIndex/matchIndex` | 已提交日志必须在多数派上 |
| 安全性（Safety） | 日志匹配性质 + 选举限制 + commit 规则 | Leader 一定包含已提交日志 |

```
Raft 节点状态机
                   选举超时(150~300ms 随机)
  Follower -------------------------------> Candidate
     ^  收到 Leader 心跳/更高 term              | 收到多数派选票
     |                                          v
     +-------------------------------------- Leader
                    发现更高 term 时退回 Follower
```

**日志与索引**：每条日志是 `(index, term, command)`。`commitIndex` 是「已提交的最大索引」（由 Leader 推进），`lastApplied` 是「已应用到状态机的最大索引」。**只有 appl 到状态机之后才对客户端可见**。

**一次写请求**：客户端发命令给 Leader → Leader 追加本地日志 → 并行发 `AppendEntries` 给所有 Follower → 收到**多数派**成功响应 → 推进 `commitIndex` → apply 到状态机 → 返回客户端。下一轮心跳把新 `commitIndex` 带给 Follower，让它们也 apply。

## L3 底层层：Raft 的选举与复制规则（面试的深水区）

### 3.1 选举

- Follower 在 `electionTimeout`（**随机 150-300ms**）内没收到心跳 → 变 Candidate、`term + 1`、给自己投票、并行发 `RequestVote`
- 随机化是为了**避免同时选举导致选票瓜分**（第一个超时的节点更容易赢）
- 候选人的 `RequestVote` 只有满足两天才能当选：**拿到多数派选票** 且 **日志至少和投票者一样新**（比较 `lastLogTerm`，相等再比 `lastLogIndex`）
- 同一 term 内每个节点只投一票（持久化 `votedFor`），保证不会选出两个 Leader
- 选举平票则等待下一个随机超时重选

### 3.2 日志复制与一致性检查

`AppendEntries` 请求带 `prevLogIndex`、`prevLogTerm`、若干 `entries`、`leaderCommit`。Follower 的处理：

1. 如果 `prevLogIndex` 位置没有日志，或该位置日志的 term 不等于 `prevLogTerm` → **拒绝**
2. 拒绝后 Leader 把该 Follower 的 `nextIndex` 递减重试（优化：用冲突 term 一次回退多步），直到找到共同前缀
3. 匹配后，若遇到冲突的旧日志（同 index 不同 term）→ **截断自己的日志**再追加
4. 追加成功后更新自己的 `commitIndex = min(leaderCommit, lastLogIndex)`

**日志匹配性质**：如果两份日志在某个 index/term 相同，则它们之前的所有日志都相同。这是「多数派 + 一致性检查」能保证安全的核心。

### 3.3 commitIndex 的提交规则（最容易答错）

Leader 只能通过「**当前 term 的日志被多数派复制**」来推进 `commitIndex`；**不能**直接根据「旧 term 的日志已在多数派上」就提交它，必须等当前 term 产生一条新日志被多数派确认，把 `commitIndex` 一次推上去（**间接提交**）。原因：旧 term 的日志即使复制到多数派，也可能被后来的 Leader 覆盖（Raft 论文 Figure 8）。这是 `Figure 8` 经典反例，答出来是明显加分项。

### 3.4 脑裂与租约

- 网络分区后，旧 Leader 在少数派一侧：它无法再把日志复制到多数派，写请求全部无法提交，**不会产生脑裂**；多数派一侧选出新 Leader，term 更高
- 旧 Leader 恢复后收到更高 term 的 `AppendEntries`/`RequestVote` → 主动退位，未提交的日志被截断
- **租约（lease）**：Leader 在租约期内可以本地读（不查多数派），前提是「多数派不会在租约内选出新 Leader」；etcd 的 `lease read` 用时钟近似，NTP 跳变会破坏安全性，所以也有 `readIndex`（安全版：向多数派确认仍是 Leader 再读）

### 3.5 与 Paxos / ZAB 的关系

| | Paxos | Raft | ZAB |
|---|---|---|---|
| 定位 | 共识问题的基础协议 | 可理解性优先的共识算法 | ZooKeeper 的原子广播协议 |
| Leader | Multi-Paxos 可有可选 leader | **强 Leader**，日志必须连续 | 强 Leader（主备），`ZXID = (epoch, counter)` |
| 日志 | 可乱序（Basic Paxos 单值） | 连续日志 + 匹配性质 | 连续日志 + 事务 ID |
| 选举 | — | 随机超时 + 多数派投票 | Fast Leader Election，比较 `(epoch, zxid)` |
| 恢复 | — | 由 Leader 一致性检查修复 | 恢复模式：Leader 选日志最全的节点，广播同步 |
| 读 | — | Leader 读 / readIndex / lease | 读可本地（可能旧）或 sync |

本质上 Raft 和 ZAB 都是「Multi-Paxos 的工程化变体」，为了可理解性和工程约束（强 Leader、连续日志）做了简化。

## L4 追问树（面试官一路往下问，你能撑到第几层？）

> 规则：从上往下问。**第 1-3 层是应届生必备，第 4-6 层是拉开差距，第 7 层以后是"能答出来就是加分"。**

### 第 1 层｜CAP 是什么？
**答**：Consistency（所有节点同一时刻看到同一份数据）、Availability（每个请求都能得到非错误响应）、Partition tolerance（网络分区时系统仍能运行）。三者最多同时满足两个；分布式里分区必然发生，所以 P 必选，只能在 C 和 A 之间取舍。

### 第 2 层｜为什么说 P 必须保留？
**答**：网络分区是客观事实（交换机故障、跨机房链路抖动），你不能选择「不分分区」。既然 P 一定在，那么分区发生时要么拒绝服务保一致（CP），要么继续服务容忍旧数据（AP）。

### 第 3 层｜CP 和 AP 分别举例？BASE 是什么？
**答**：CP：etcd、ZooKeeper、HBase（分区时少数派不可用）；AP：Eureka（节点间互相注册，分区时各自服务，可能注册表陈旧）、Cassandra。BASE 是 AP 的工程化表述：基本可用、软状态、最终一致。

### 第 4 层｜Raft 有哪几种角色？term 是什么？
**答**：Leader（处理写、发心跳）、Follower（被动接收日志）、Candidate（选举中）。term 是单调递增的「任期编号」，是逻辑时钟：收到更高 term 的请求就更新自己的 term 并退回 Follower，同一 term 最多一个 Leader。

### 第 5 层｜选举超时为什么要随机？
**答**：如果所有 Follower 同时超时，会同时变成 Candidate 并各自拉票，选票被瓜分导致不断重选。随机化（150-300ms）让某个节点先超时、先拿到多数票，选举能快速收敛。

### 第 6 层｜选举时如何保证选出的 Leader 一定包含已提交日志？
**答**：`RequestVote` 带候选人的 `lastLogTerm/lastLogIndex`，投票者只在「候选人日志至少和我一样新」时才投票（先比 term 再比 index）。已提交日志一定在多数派上，而新 Leader 必须拿到多数派选票，两者交集保证了 Leader 拥有所有已提交日志。

### 第 7 层｜日志复制里 `AppendEntries` 的一致性检查怎么做？
**答**：请求带 `prevLogIndex/prevLogTerm`；Follower 检查自己该位置的日志 term 是否匹配，不匹配就拒绝，Leader 递减 `nextIndex` 重试直到找到共同前缀，然后截断冲突日志并追加新日志。这是「日志匹配性质」的实现。

### 第 8 层｜commitIndex 怎么推进？为什么不能直接提交旧 term 的日志？
**答**：Leader 只把「当前 term 的日志被多数派确认」的 index 推进为 committed；旧 term 的日志即使已在多数派上也不能直接提交，必须等当前 term 一条新日志提交时顺带推上去（间接提交）。否则可能出现「旧 term 日志在多数派上但后来被覆盖」的 Figure 8 反例。

### 第 9 层｜脑裂怎么防？租约是什么？
**答**：靠多数派：少数派一侧的旧 Leader 无法把日志复制给多数派，写请求提交不了；多数派选出更高 term 的新 Leader。租约是「Leader 在租约期内本地读」的优化，前提是多数派不会在租约内选主；时钟漂移会破坏租约安全，所以 etcd 另外提供 readIndex。

### 第 10 层｜Raft 的读请求有哪些方式？分别牺牲什么？
**答**：1）走 Leader 读（默认，经过日志确认，线性一致）；2）readIndex：Leader 先向多数派确认自己还是 Leader，再本地读（安全、少一次日志写）；3）lease read：靠时钟租约直接本地读（最快，最怕时钟跳变）；4）follower read：从 Follower 读，可能读到旧数据（需要业务容忍或配合日志序号）。

### 第 11 层｜Paxos 和 Raft、ZAB 什么关系？
**答**：Paxos 是共识问题的理论基础（Basic Paxos 解决单值，Multi-Paxos 解决日志序列）；Raft 是强调可理解性的 Multi-Paxos 变体（强 Leader、连续日志、随机超时）；ZAB 是 ZooKeeper 的原子广播协议，也是强 Leader + 连续日志，用 ZXID 标识事务，恢复模式要选日志最全的节点。

### 第 12 层（终局）｜一次写请求在 Raft 集群的完整流程？
**答**：客户端发命令给 Leader → Leader 追加到本地日志（带当前 term）→ 并行向 Follower 发 `AppendEntries`（带 `prevLogIndex/prevLogTerm`）→ Follower 做一致性检查、截断冲突日志、追加并返回成功 → Leader 收到多数派成功（含自己）→ 推进 `commitIndex` 到该 index → apply 到状态机（对客户端可见）→ 返回成功 → 下一次心跳把 `commitIndex` 通知 Follower，让它们也 apply。**分水岭：能说出「多数派确认 + 只推进当前 term + apply 后才可见」三件事。**

## L5 名词拆解表（每个名词都拆开）

| 名词 | 是什么 | 为什么存在 | 面试追问点 |
|---|---|---|---|
| CAP | 一致性/可用性/分区容忍三选二 | 描述分布式系统的取舍边界 | 为什么必须选 P |
| BASE | 基本可用/软状态/最终一致 | AP 系统的工程化准则 | 与 ACID 对比 |
| CP / AP | 两类系统取舍 | 指导系统选型 | 各举 2 个系统 |
| 多数派（Quorum） | 过半节点 | 任意两个多数派必有交集 | 3 节点容忍 1 台故障 |
| Raft term | 单调递增的任期号 | 逻辑时钟，拒绝过期 Leader | 收到更高 term 必须更新并退位 |
| Leader/Follower/Candidate | 三种角色 | 把共识拆成可实现的三个子问题 | 角色转换条件 |
| 选举超时 | Follower 等心跳的时限（随机） | 触发选举且避免选票瓜分 | 为什么随机、心跳要更短 |
| `RequestVote` | 拉票 RPC | 选主 | `lastLogTerm/Index` 检查 |
| `AppendEntries` | 日志复制/心跳 RPC | 复制日志并维持 Leader 权威 | `prevLogIndex/prevLogTerm` 一致性检查 |
| `nextIndex` / `matchIndex` | 每个 Follower 的复制进度 | 决定从哪开始补日志 | 回退优化（冲突 term 快速回退） |
| `commitIndex` / `lastApplied` | 已提交 / 已应用索引 | 区分「多数派确认」与「状态机可见」 | 只能提交当前 term 日志 |
| 日志匹配性质 | 同 index+term 则前缀相同 | 保证多数派日志一致 | 与截断冲突日志配合 |
| 脑裂 | 分区两侧都自认 Leader | 分区场景的典型故障 | 多数派 + term 防止双写 |
| 租约（lease） | Leader 一段时间内的读权限 | 本地读优化，避免每读都问多数派 | 时钟漂移风险、readIndex |
| ZAB / ZXID | ZK 的原子广播协议 / 事务 ID | ZooKeeper 的一致性基础 | 与 Raft 的区别、恢复模式 |

## 代码验证（JDK 单文件可跑：模拟 Raft 选举与多数派提交）

```java
// 保存为 RaftDemo.java：javac RaftDemo.java && java RaftDemo
import java.util.*;
import java.util.stream.*;

public class RaftDemo {
    static final int N = 3;                                  // 3 节点集群，容忍 1 台故障
    static int[] term = new int[N];
    static int[] votedFor = {-1, -1, -1};                    // -1 表示没投票
    static int[] lastLogIndex = {5, 4, 3};
    static int[] lastLogTerm = {1, 1, 1};
    static boolean[] alive = {true, true, true};

    static List<Integer> quorum() {                          // 多数派：任意 2 个节点
        return IntStream.range(0, N).filter(i -> alive[i]).boxed().collect(Collectors.toList());
    }
    static int requestVote(int candidate) {                  // 返回得票数
        term[candidate]++; votedFor[candidate] = candidate;
        int votes = 1;
        for (int v : quorum()) {
            if (v == candidate) continue;
            if (term[v] < term[candidate]) { term[v] = term[candidate]; votedFor[v] = -1; } // 更高 term：先重置本 term 的投票
            boolean newer = lastLogTerm[candidate] > lastLogTerm[v]
                    || (lastLogTerm[candidate] == lastLogTerm[v] && lastLogIndex[candidate] >= lastLogIndex[v]);
            if (term[v] == term[candidate] && votedFor[v] == -1 && newer) {   // 日志不够新则拒票
                votedFor[v] = candidate; votes++;
            }
        }
        return votes;
    }
    static boolean appendEntries(int leader, int follower, int prevIndex, int prevTerm) {
        if (!alive[follower]) return false;
        if (lastLogIndex[follower] < prevIndex) return false;              // 缺日志，需回退 nextIndex
        lastLogIndex[follower] = Math.max(lastLogIndex[follower], prevIndex + 1);
        lastLogTerm[follower] = term[leader];
        return true;
    }
    public static void main(String[] args) {
        System.out.println("初始日志长度=" + Arrays.toString(lastLogIndex) + " 存活=" + Arrays.toString(alive));
        System.out.println("节点0 拉票得票=" + requestVote(0) + "（需 2 票）" + " term=" + Arrays.toString(term));

        // 节点0 当选，复制一条新日志
        int ack = 1;                                             // 自己算一票
        for (int f = 1; f < N; f++) if (appendEntries(0, f, lastLogIndex[0] - 1, lastLogTerm[0])) ack++;
        System.out.println("AppendEntries 成功数=" + ack + " -> 多数派确认=" + (ack >= N / 2 + 1));

        // 模拟故障：节点2 宕机，重新选举，节点2 恢复后日志落后
        alive[2] = false;
        System.out.println("节点2 宕机，存活节点=" + quorum());
        int votes = requestVote(1);
        System.out.println("节点1 拉票得票=" + votes + "（2 票即可当选）");
        alive[2] = true;
        System.out.println("节点2 恢复，日志长度=" + lastLogIndex[2] + " -> 落后，Leader 需从 nextIndex 补齐");
    }
}
```

## 高频错误（面试官最爱抓的）

| 错误说法 | 正确说法 |
|---|---|
| 「CAP 里可以选 CA」 | 分布式系统 P 必选，只有单机才谈 CA |
| 「Raft 是 Paxos 的简化版，性能更好」 | 主要目标是**可理解性**，安全规则比 Multi-Paxos 更明确（强 Leader + 连续日志） |
| 「日志复制到多数派就算提交」 | 还要满足「当前 term 的日志」才能推进 commitIndex |
| 「Follower 收到 AppendEntries 直接覆盖本地日志」 | 先做 `prevLogIndex/prevLogTerm` 检查，冲突才截断 |
| 「分区时会出现两个 Leader 同时写」 | 少数派 Leader 无法获得多数派确认，写不成功；新 Leader term 更高 |
| 「租约读绝对安全」 | 依赖时钟，NTP 跳变会破坏安全性，安全做法是 readIndex |
| 「ZooKeeper 的 ZAB 就是 Raft」 | 两者都是强 Leader + 连续日志，但协议、选举、恢复流程不同（ZXID vs term） |
| 「最终一致就是弱一致、不可靠」 | BASE 是工程上可接受的强可用性方案，靠补偿与对账兜底 |

## 关联文件

- 上一层（数据库/Redis 八股）：[MySQL与Redis](../../04-database/MySQL与Redis.md)
- 同层追问：[分布式事务](./01-分布式事务.md)（一致性在业务上的落地）｜[限流熔断降级](./03-限流熔断降级.md)（分区/故障时的可用性策略）
- 典型场景：Docker 沙箱任务调度的「任务状态一致性」可以用 etcd/Redis 的原子操作实现；AI Agent 多实例选主场景可以直接用 etcd 的 lease + 选举
- 速查：[深度追问索引](../00-索引.md)

## 自测标准

- 能讲清 CAP 三者关系、为什么 P 必选，并能给 CP/AP 各举两个系统
- 能画出 Raft 角色状态机与一次选举流程，说明随机超时的作用
- 能讲清 `AppendEntries` 的一致性检查与 `nextIndex` 回退
- 能解释 `commitIndex` 只能提交当前 term 日志（Figure 8）
- 能说清脑裂为什么不会发生，以及 lease read 与 readIndex 的差别
- L4 讲到第 8 层（commitIndex）算及格；讲到第 12 层（写请求全流程）算优秀
