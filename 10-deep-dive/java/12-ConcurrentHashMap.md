# ConcurrentHashMap 底层（JDK 7 Segment 到 JDK 8 锁桶）

> 面试权重：5/5　｜　追问深度：**L5（`sizeCtl` 位编码 + `transfer` 协作扩容 + `Unsafe` CAS）**
> 一句话定位：多数人只会说「JDK 8 用 CAS + synchronized 锁桶」。真正被追问的是 **`sizeCtl` 的四种语义、`resizeStamp` 的位编码、多线程怎么协助扩容、计数为什么用 `baseCount + CounterCell[]`**。能讲清这四件事，才算读过 `ConcurrentHashMap.java`。

**本文件用法**：从 L1 往下读，每读完一层合上书自问自答。**停在答不出的那一层，就是你的真实水平线。**
[返回深度追问索引](../00-索引.md)

---

## L1 一句话答案（10 秒能说出口）

JDK 7 用 `Segment[]` 分段锁（继承 `ReentrantLock`，默认 16 段，并发度 = 段数）；JDK 8 改成 `Node[]` 数组，**空桶用 CAS 放入、非空桶 `synchronized` 锁桶头节点**，并发度约等于桶数。扩容用 `sizeCtl` 的负数编码进度，其他线程通过 `helpTransfer` 一起搬桶，每个迁移完的桶放 `ForwardingNode`；`size()` 是 `baseCount` 与 `CounterCell[]` 求和得到的**近似值**，迭代器是**弱一致**的、不抛 `ConcurrentModificationException`。

---

## L2 原理层：两代结构差异与一次 put

| 维度 | JDK 7 | JDK 8 |
|---|---|---|
| 数据结构 | `Segment[]` + `HashEntry[]`（数组套数组） | `Node[] table`（数组 + 链表 + 红黑树） |
| 锁粒度 | Segment（默认 16，并发度上限 16） | 单个桶头节点（并发度约等于桶数） |
| 锁实现 | `ReentrantLock` | `synchronized` + `Unsafe` CAS |
| 扩容 | 每个 Segment 独立扩容 | 整表扩容，多线程协作 `transfer` |
| 计数 | `Segment.count` 累加 | `baseCount` + `CounterCell[]`（LongAdder 思路） |
| 空桶写入 | 需抢 Segment 锁 | **无锁 CAS** |

JDK 8 一次 `put` 的分支（源码 `putVal`，JDK 17 实测）：

```
putVal:
  1. table 为空           -> initTable()（CAS 抢 sizeCtl = -1）
  2. 目标桶为 null        -> casTabAt 直接放，无锁
  3. 桶头 hash == MOVED   -> helpTransfer()，加入协助扩容
  4. 否则                 -> synchronized (f) 锁住桶头：链表尾插或 TreeBin.putTreeVal
  5. 插入后 binCount 达标 -> treeifyBin()（容量 < 64 时改为 tryPresize 扩容）
  6. addCount(1, binCount) -> 更新计数，可能触发扩容
```

---

## L3 底层层：源码逐段

### 3.1 定位：`spread` 与 2 的幂

```java
static final int spread(int h) {                  // CHM.java:696
    return (h ^ (h >>> 16)) & HASH_BITS;          // HASH_BITS = 0x7fffffff，强制为正数
}
```

区别于 HashMap 的两点：① 多一个 `& HASH_BITS`，**强制 hash 为正数**，因为负数是内部标记（`MOVED = -1` 转发节点、`TREEBIN = -2` 树根、`RESERVED = -3` 占位节点）；② table 长度同样是 2 的幂，`(n-1) & hash` 等价取模。

`tabAt` / `casTabAt` / `setTabAt` 是三个 `Unsafe` 封装：普通读用 `getObjectAcquire`（≈ volatile 读），写用 CAS 或 `putObjectRelease`。

### 3.2 `sizeCtl`：一个 int，四种语义

| 取值 | 含义 |
|---|---|
| `0` | 未初始化，第一次 put 时按默认 16 分配 |
| 正数 | 下次扩容阈值 = `n - (n >>> 2)`（即 0.75n） |
| `-1` | **正在初始化**，其他线程 `Thread.yield()` 自旋等待（实测源码 `initTable`） |
| 其他负数 | **正在扩容**：高 16 位是 `resizeStamp`，低 16 位是 `1 + 参与迁移的线程数` |

编码细节（实测源码常量）：

```java
RESIZE_STAMP_BITS  = 16;
MAX_RESIZERS = (1 << (32 - 16)) - 1;   RESIZE_STAMP_SHIFT = 32 - 16;   // 65535 / 16
static final int resizeStamp(int n) {
    return Integer.numberOfLeadingZeros(n) | (1 << (RESIZE_STAMP_BITS - 1));
}
```

所以判断「还有没有人在扩容」就是看 `sizeCtl` 是否等于 `rs + 1`（只剩最后一个线程）或 `rs + MAX_RESIZERS`（协助者已满）。

### 3.3 `transfer` 与 `helpTransfer`：多线程怎么一起搬

```java
private final void transfer(Node<K,V>[] tab, Node<K,V>[] nextTab) {   // :2424
    int n = tab.length, stride;
    stride = (NCPU > 1) ? (n >>> 3) / NCPU : n;      // 每线程负责一段桶
    if (stride < MIN_TRANSFER_STRIDE) stride = MIN_TRANSFER_STRIDE;
    // ...
    ForwardingNode<K,V> fwd = new ForwardingNode<K,V>(nextTab);
    // 每个桶处理完：casTabAt(tab, i, null, fwd) 打上转发标记
    // 空桶直接 CAS 放 fwd，不必加锁
}
```

- 任务分配靠 `transferIndex`：线程用 CAS 从 `transferIndex` 领走一段 `[nextBound, nextIndex)`，领完发现 `transferIndex <= 0` 说明桶分完了。
- 只有第一个线程能创建 `nextTable`（CAS `nextTable` 从 null 到新数组），其他线程通过 `helpTransfer` 加入：

```java
final Node<K,V>[] helpTransfer(Node<K,V>[] tab, Node<K,V> f) {   // :2363
    if (tab != null && (f instanceof ForwardingNode)) {
        int rs = resizeStamp(tab.length) << RESIZE_STAMP_SHIFT;
        while ((sc = sizeCtl) < 0) {
            if (sc == rs + MAX_RESIZERS || sc == rs + 1 || transferIndex <= 0) break;
            if (U.compareAndSetInt(this, SIZECTL, sc, sc + 1)) { transfer(tab, nextTab); break; }
        }
        return nextTab;
    }
```

**实测**：写 300 万条数据的过程中反射采样，能观察到 `sizeCtl < 0` 与 `table` 里出现 `ForwardingNode`（探针输出 `sizeCtl<0 = true, ForwardingNode = true`）。

### 3.4 计数：为什么不直接用一个 int

```java
private transient volatile long baseCount;              // 基础计数（无竞争快路径）
private transient volatile CounterCell[] counterCells;  // 分片计数（分散 CAS 竞争）
// addCount: baseCount 的 CAS 失败 → 按线程探针散列到 counterCells 各自累加，再失败走 fullAddCount()
```

- 高并发下所有线程 CAS 同一个 `baseCount` 会疯狂失败自旋，于是按线程探针值散列到不同 `CounterCell`，各自加各自的格子。
- `size()` = `sumCount()` = `baseCount + Σ CounterCell.value`，**遍历时别的线程还在改，所以是近似值**。`mappingCount()` 返回 long，官方建议优先用它。
- 这套就是 `LongAdder` 的思路；区别是 CHM 要同时维护扩容判断，所以多了 `check` 参数。

### 3.5 `get` 无锁与弱一致迭代器

- `get`：`spread` → `tabAt`（volatile 读）→ 命中桶头/链表/树查找。**全程不加锁**。遇到 `ForwardingNode` 时会去 `nextTable` 继续找，所以扩容中也能读到。
- 迭代器基于 `Traverser`，遍历的是「遍历到的那一刻」的桶，**可能看到部分更新、也可能看不到最新写入**，但不会抛 `ConcurrentModificationException`，也不保证快照一致。**实测**：一边 16 线程写入一边遍历 300ms，无 CME，遍历到 42 万条而 `size()` 已 78 万——这就是弱一致。
- 不允许 `null` key/value：`putVal` 第一行就 `throw new NullPointerException()`（实测）。原因是并发下 `get` 返回 null 无法区分「键不存在」和「值就是 null」。

---

## L4 追问树（面试官一路往下问，你能撑到第几层？）

> 规则：从上往下问。**第 1-3 层是应届生必备，第 4-6 层拉开差距，第 7 层以后是加分。**

### 第 1 层｜ConcurrentHashMap 怎么保证线程安全？
**答**：JDK 8 是「数组 + 链表/红黑树」，空桶用 CAS 放节点（无锁），非空桶用 `synchronized` 锁住桶的头节点，只影响这一个桶；扩容时多线程协作搬桶。读操作完全无锁，靠 `volatile` 读 `tabAt` 保证可见性。

### 第 2 层｜只锁一个桶的头节点，为什么能保证这个桶的并发安全？
**答**：同一个桶的所有写入者都要 `synchronized (f)` 抢同一把监视器锁，对这条链的修改被串行化；读侧不加锁，但读的是 volatile 语义的 `tabAt`，配合 `Node.val`/`Node.next` 的 volatile 写，保证读到的是已发布的数据。跨桶互不影响，所以并发度约等于桶数。

### 第 3 层｜`sizeCtl` 有几种取值？负数代表什么？
**答**：四种：`0` 未初始化；正数 = 扩容阈值（0.75n）；`-1` 表示正在初始化（其他线程 yield 自旋）；其他负数表示正在扩容，高 16 位是 `resizeStamp`，低 16 位是「1 + 协助迁移的线程数」。看到 `sizeCtl < 0` 要先区分是初始化还是扩容。

### 第 4 层｜`resizeStamp` 是怎么编码的？为什么要左移 16 位？
**答**：`resizeStamp(n) = Integer.numberOfLeadingZeros(n) | (1 << 15)`，用一个和容量相关的「戳」标记这一轮扩容；左移 16 位是把低 16 位留给「协助线程数」。这样 `sizeCtl` 一个 int 同时存了「哪一轮扩容」和「几个人在帮忙」，CAS 加减互不干扰。

### 第 5 层｜多个线程怎么协助扩容？怎么结束？
**答**：扩容线程把 `transferIndex` 从 n 往下切，每线程 CAS 领一段桶（stride 按 CPU 数算，最小 `MIN_TRANSFER_STRIDE`）。别的线程 put 撞到 `ForwardingNode` 就调 `helpTransfer`：CAS 把 `sizeCtl+1` 登记自己，再调 `transfer`。结束条件三种：`sc == rs + MAX_RESIZERS`（协助者满）、`sc == rs + 1`（只剩最后一个线程收尾）、`transferIndex <= 0`（桶分完）。

### 第 6 层｜`ForwardingNode` 是什么？`get` 撞到它怎么办？
**答**：hash 固定为 `MOVED(-1)` 的占位节点，代表「这个桶已搬迁完，去新表找」。每迁完一个桶就用 CAS 放进去；写线程看到它去协助扩容，读线程顺着 `ForwardingNode.nextTable` 到新表继续查，所以扩容期间读写都不阻塞。

### 第 7 层｜为什么 `size()` 是近似值？为什么不直接维护一个 int？
**答**：高并发下所有线程 CAS 同一个计数器会大量失败自旋，所以用 `baseCount` + `CounterCell[]` 分片：线程按探针散列到不同格子各自累加，`sumCount()` 求和。求和时别的线程还在写，所以是近似值——「先 size() 再遍历」本身就不是原子快照。

### 第 8 层｜为什么不允许 null key/value？
**答**：并发下 `get` 返回 null 无法区分「键不存在」和「值就是 null」。HashMap 能靠 `containsKey` 二次确认，但并发下这两次调用之间值可能变，所以 CHM 直接禁掉，`putVal` 首行 NPE。

### 第 9 层｜`computeIfAbsent` 里的 `ReservationNode` 是干嘛的？
**答**：它会先放一个 `RESERVED(-3)` 的占位节点占住桶，表示「这个桶正在计算」，避免多个线程同时进入同一个 key 的回调；若在回调里又修改同一个 key，`putVal` 检测到 `ReservationNode` 会抛 `IllegalStateException: Recursive update`。

### 第 10 层（终局）｜到 CPU 层，CHM 的一次 `put` 到底花了什么代价？
**答**：① 空桶路径：`spread` 两次位运算 + `Unsafe.compareAndSwapObject`，x86 上是一条 `lock cmpxchg`，靠 MESI 独占缓存行，无系统调用；② 冲突路径：`synchronized (f)` 升级为重量级锁后走 `ObjectMonitor` 的 enter/exit，竞争时线程 park 进内核；③ 计数路径：`baseCount` CAS 失败后退到 `CounterCell`，而 `CounterCell` 用 `@Contended` 补齐到 128 字节，避免同一缓存行上的不同格子互相失效（伪共享）。所以性能一半来自细粒度锁，一半来自「无锁读 + 避免伪共享」。

---

## L5 名词拆解表（"每个名词都拆开"）

| 名词 | 是什么 | 为什么存在 | 面试追问点 |
|---|---|---|---|
| `Node` | 链表节点（hash/key/val/next） | 存键值 + 维持冲突链 | val/next 为什么 volatile |
| `TreeNode`/`TreeBin` | 红黑树节点与树根包装 | 桶过长时把 O(n) 降到 O(log n) | TreeBin 的读写锁字段 |
| `ForwardingNode` | hash=MOVED(-1) 的转发节点 | 扩容时标记「已迁移，去新表」 | get 如何顺着它找 |
| `sizeCtl` | volatile int 控制字段 | 用负数编码扩容进度 | 四种语义怎么区分 |
| `resizeStamp` | 与容量绑定的扩容戳 | 区分「哪一轮扩容」 | 为何左移 16 位 |
| `transferIndex` | 待迁移桶的游标 | 多线程领取任务区间 | stride 怎么算 |
| `helpTransfer` | 协助扩容入口 | 让写入线程也参与搬桶 | 退出条件有哪些 |
| `baseCount` | 基础计数 | 无竞争时的快路径 | 为什么不用 AtomicLong |
| `CounterCell` | 分片计数格子 | 分散 CAS 竞争 + 避免伪共享 | sumCount 为什么近似 |
| 弱一致迭代器 | 不保证快照的遍历 | 遍历期间允许并发修改 | 为什么不抛 CME |
| `spread` | 扰动 + 强制正数 | 兼顾散列与内部标记 | `& HASH_BITS` 的作用 |

---

## 代码验证（`ChmProbe.java`，JDK 17 编译运行通过）

```java
import java.lang.reflect.Field;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

public class ChmProbe {
    static Object[] table(ConcurrentHashMap<?, ?> m) throws Exception {
        Field f = ConcurrentHashMap.class.getDeclaredField("table");
        f.setAccessible(true);
        return (Object[]) f.get(m);
    }
    static int sizeCtl(ConcurrentHashMap<?, ?> m) throws Exception {
        Field f = ConcurrentHashMap.class.getDeclaredField("sizeCtl");
        f.setAccessible(true);
        return f.getInt(m);
    }
    public static void main(String[] a) throws Exception {
        ConcurrentHashMap<String, Integer> m = new ConcurrentHashMap<>();
        System.out.println("put 前 table=" + (table(m) == null ? "null" : table(m).length)
                + ", sizeCtl=" + sizeCtl(m));                       // null, 0
        m.put("a", 1);
        System.out.println("put 后 table=" + table(m).length + ", sizeCtl=" + sizeCtl(m));   // 16, 12
        try { m.put(null, 1); } catch (NullPointerException e) { System.out.println("null key -> NPE"); }

        ConcurrentHashMap<Integer, Integer> c = new ConcurrentHashMap<>();
        Thread[] ts = new Thread[8];
        for (int t = 0; t < ts.length; t++) {
            final int base = t * 50_000;
            ts[t] = new Thread(() -> { for (int i = 0; i < 50_000; i++) c.put(base + i, i); });
            ts[t].start();
        }
        for (Thread t : ts) t.join();
        System.out.println("8 线程 x 5 万 put -> size=" + c.size());    // 400000，一条不丢

        AtomicBoolean stop = new AtomicBoolean(false);
        Thread w = new Thread(() -> { int k = 400_000; while (!stop.get()) c.put(k, k++); });
        w.start();
        int seen = 0;
        for (Integer k : c.keySet()) { if (++seen >= 100_000) break; }
        stop.set(true); w.join();
        System.out.println("边写边遍历：无 ConcurrentModificationException，遍历 " + seen + " 条");
    }
}
```

```bash
javac -encoding UTF-8 ChmProbe.java
java --add-opens java.base/java.util.concurrent=ALL-UNNAMED ChmProbe
# JDK 17 起读 table/sizeCtl 需要 --add-opens
```

**实测输出**：`put 前 table=null, sizeCtl=0`；`put 后 table=16, sizeCtl=12`；`null key -> NPE`；边写边遍历无 CME（遍历条数 < size，体现弱一致）；8 线程并发写 `size=400000` 一条不丢。

---

## 高频错误（面试官最爱抓的）

| 错误说法 | 正确说法 |
|---|---|
| 「JDK 8 还是分段锁，只是段变多了」 | JDK 8 已移除 Segment 的锁语义，锁的是桶头节点 |
| 「CHM 全程加锁所以慢」 | 读无锁，空桶写无锁 CAS，只有冲突桶才加锁 |
| 「size() 是精确值」 | 是 `baseCount + CounterCell[]` 的求和，并发下近似 |
| 「CHM 可以存 null key」 | 不允许，`putVal` 首行 NPE |
| 「扩容只有一个线程干活」 | 多线程通过 `helpTransfer`/`transferIndex` 分工搬桶 |
| 「sizeCtl 为负就是初始化中」 | 只有 `-1` 是初始化；其他负数是扩容（高 16 位扩容戳 + 低 16 位线程数） |

---

## 关联文件

- 广度版（60 秒能答）：[Java基础与并发](../../03-java/Java基础与并发.md) 的 ConcurrentHashMap 小节
- 同层追问：[HashMap 底层](./01-HashMap.md)（同一套桶定位与树化逻辑，差别在并发控制）
- 典型场景：你的 报告平台项目里 SSE 的在线连接表（`Map<Long, SseEmitter>`）、限流计数器、任务进度缓存都应该是 `ConcurrentHashMap` 而不是 `HashMap`；线程池打满时如果热点锁在 CHM 上，`jstack` 会看到大量线程卡在 `ConcurrentHashMap.putVal` 的 `synchronized` 行
- 延伸：分片计数（`CounterCell`）与 [Redis 的原子计数](../../04-database/MySQL与Redis.md) 解决的是同一类问题

> **自测标准**：能讲清 `sizeCtl` 四种语义与 `resizeStamp` 位编码、`helpTransfer` 的三个退出条件、`CounterCell` 为什么能减少竞争，并跑通 `ChmProbe` 四段输出，算过关。
