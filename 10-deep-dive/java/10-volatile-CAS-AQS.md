# volatile、CAS 与 AQS

> 面试权重：5/5　｜　追问深度：**L5（内存屏障 / MESI / CLH 变体队列 / `state` 语义）**
> 一句话定位：`volatile` 用**内存屏障**把「可见性 + 有序性」落到 CPU 指令；CAS 用 CPU 的 `cmpxchg` 原子指令实现无锁更新；AQS 则用 **`volatile int state` + 一个 CLH 变体的双向队列**，把「能不能拿到锁」抽象成一个 int，把「拿不到怎么办」统一成排队 + `park`。

[返回深度追问索引](../00-索引.md)

## L1 一句话答案（10 秒能说出口）

JMM 规定每个线程有工作内存（寄存器 + CPU 缓存），共享变量在主内存，`volatile` 靠内存屏障保证**写入立刻对其他线程可见、且禁止指令重排**；CAS 靠 `Unsafe.compareAndSwapInt`（x86 的 `lock cmpxchg`）做无锁原子更新，但有 ABA 和自旋开销；AQS 用 `volatile int state` 表示锁状态、双向队列排队线程，子类只实现 `tryAcquire/tryRelease`，`acquire/release` 是模板方法。

## L2 原理层：JMM 三大特性 + happens-before 八条

**主内存 / 工作内存**：线程不能直接读写主内存，必须先拷到工作内存（缓存 + 寄存器）再操作，因此产生可见性问题。

| 特性 | 含义 | 靠什么保证 |
|---|---|---|
| 原子性 | 操作不可被打断 | `synchronized`、CAS、`Atomic*`；`long/double` 非 volatile 写不保证（32 位机器） |
| 可见性 | 一个线程改了，别的线程立刻能看到 | `volatile`、`synchronized`、`final` |
| 有序性 | 禁止编译器/CPU 重排到破坏语义 | `volatile`、`synchronized`、happens-before |

**happens-before 八条（JSR-133）**：

| # | 规则 | 用途 |
|---|---|---|
| 1 | 程序顺序：同线程内前面的写先于后面的读 | 单线程语义不能变 |
| 2 | 监视器锁：对同一把锁的 `unlock` 先于后续 `lock` | 解释 `synchronized` 的可见性 |
| 3 | volatile：volatile **写**先于后续对同一变量的**读** | 解释 `volatile` |
| 4 | 线程启动：`Thread.start()` 先于该线程内任何操作 | 父线程写的变量子线程可见 |
| 5 | 线程终止：线程内所有操作先于 `join()` 返回 | 拿得到子线程结果 |
| 6 | 中断：`interrupt()` 先于被中断线程检测到中断 | 中断可见 |
| 7 | 对象终结：构造完成先于 `finalize()` 开始 | 终结器能看到字段 |
| 8 | 传递性：A hb B，B hb C ⇒ A hb C | 组合推导 |

**四种内存屏障**：

| 屏障 | 作用 | 典型插入点 |
|---|---|---|
| `LoadLoad` | 前面的读先于后面的读 | volatile 读**之后** |
| `StoreStore` | 前面的写先于后面的写 | volatile 写**之前** |
| `LoadStore` | 前面的读先于后面的写 | volatile 读**之后** |
| `StoreLoad` | 前面的写先于后面的读（最贵） | volatile 写**之后** |

即：**volatile 写 = StoreStore + 写 + StoreLoad；volatile 读 = 读 + LoadLoad + LoadStore**。x86 本身是 TSO 模型，只需在写后补 `StoreLoad`（用 `lock addl $0,(%rsp)` 实现，`lock` 前缀顺便触发缓存行独占）。

## L3 底层层：ACC_VOLATILE / MESI / CAS 指令 / AQS 队列

### 3.1 volatile 在字节码与汇编层

- 字段访问标志 `ACC_VOLATILE`（`javap -v` 可见）；**JIT 会在读写处插入内存屏障**，不是 JVM 解释器做同步
- x86 上 volatile 写的实际指令是 `lock addl $0,0(%rsp)`（或 `mov` + `mfence`）；`lock` 前缀 = 对缓存行加锁 + 使其他核对应缓存行**失效**
- `volatile` **不保证原子性**：`volatile int i; i++` 仍是「读-改-写」三步，`i++` 必错，要用 `AtomicInteger`

### 3.2 MESI 缓存一致性与伪共享

四态：`M`（Modified 独占脏）、`E`（Exclusive 独占干净）、`S`（Shared 共享）、`I`（Invalid 失效）。

写 `volatile` 变量时，CPU 通过**总线嗅探（snooping）**发现其他核持有该缓存行 ⇒ 发 invalidate 让对方置 `I`；对方下次读要回主存/从该核 cache 拿最新值 —— 这就是「可见性」在硬件层的来源。

**伪共享（False Sharing）**：两个线程分别写**同一个缓存行（64 字节）里的不同变量**，虽然逻辑无关，但每次写都要让对方的缓存行失效，性能掉一个量级。解决：缓存行填充（`long p1..p7`）或 `@sun.misc.Contended`（`LongAdder.Cell` 就用了）。

### 3.3 DCL 单例为什么必须加 volatile

```java
if (INSTANCE == null) {                 // 第一次检查（无锁）
    synchronized (Singleton.class) {
        if (INSTANCE == null)           // 第二次检查
            INSTANCE = new Singleton(); // ① 分配内存 ② 初始化 ③ 引用赋值（②③ 可能重排）
    }
}
```

`new` 的 ②③ 可能被重排成 ①③②：另一个线程在第一次检查时看到**非 null 但字段还没初始化**的对象，拿出去用就是半个对象。`volatile` 用 `StoreStore` 屏障禁止 ②③ 重排，这才让 DCL 正确。

### 3.4 CAS：`cmpxchg` 与 ABA、LongAdder

```java
// JDK 8 是 Unsafe.compareAndSwapInt(obj, offset, expect, update)；JDK 9+ 换 VarHandle
// 两者最终都落到 CPU 的 lock cmpxchg 指令
public final boolean compareAndSet(int e, int u) { return unsafe.compareAndSwapInt(this, valueOffset, e, u); }
```

- **底层**：`lock cmpxchg` —— 比较内存值是否等于 expect，等于则写 update，全程原子（缓存行锁定）
- **ABA**：值从 A→B→A，CAS 看不出中间变过。解法：`AtomicStampedReference`（值 + 版本号戳）或 `AtomicMarkableReference`（只记是否被改过）
- **自旋开销**：高并发下大量 CAS 失败会空转吃 CPU。`LongAdder` 的解法是**分段 CAS**：`base + Cell[]`，每个线程按 `probe` 哈希到一个 Cell 各自累加，`sum()` 时再加起来——空间换时间，代价是 `sum()` 不精确（并发中）

### 3.5 AQS：`state` + CLH 变体双向队列

```java
public abstract class AbstractQueuedSynchronizer {
    private volatile int state;                  // 重点：锁状态/许可数/重入次数，语义由子类定义
    private transient volatile Node head, tail;  // 队首（哨兵）/ 队尾
    static final class Node {
        volatile int waitStatus;                 // 见下表
        volatile Node prev, next; volatile Thread thread;
        Node nextWaiter;                         // 条件队列 / 共享模式标记
    }
}
```

| `waitStatus` | 值 | 含义 |
|---|---|---|
| `CANCELLED` | 1 | 线程已取消（超时/中断） |
| `SIGNAL` | -1 | 后继节点需要被唤醒，当前节点释放时 `unpark` 它 |
| `CONDITION` | -2 | 在 Condition 条件队列里等待 |
| `PROPAGATE` | -3 | 共享模式下传播唤醒 |
| 默认 | 0 | 初始状态 |

**`acquire` 模板方法（独占）**：

```
acquire(1)
 ├─ tryAcquire(1) 成功 → 返回            ← 子类实现（公平/非公平差异全在这）
 ├─ addWaiter(EXCLUSIVE) 入队尾（CAS 改 tail）
 ├─ acquireQueued(node, 1)：
 │    自旋：前驱是 head 且 tryAcquire 成功 → 自己变 head，返回
 │    否则 shouldParkAfterFailedAcquire：把前驱 waitStatus 置 SIGNAL
 │         → LockSupport.park(this)
 └─ 被中断过 → selfInterrupt() 补中断标记
```

**`ReentrantLock` 公平 vs 非公平的唯一差别**：

| 实现 | `tryAcquire` | 结果 |
|---|---|---|
| `NonfairSync` | `if (c == 0) { if (compareAndSetState(0, 1)) ... }` —— **直接抢** | 新线程可插队 |
| `FairSync` | 先 `if (!hasQueuedPredecessors() && compareAndSetState(0, 1))` | 队列前面有人就不抢 |

**`Condition` 的 await/signal（队列转移）**：每个 `ConditionObject` 有自己的一条单向条件队列（`firstWaiter/lastWaiter`，节点 `waitStatus=CONDITION`）。

- `await()`：`fullyRelease(state)`（**完全释放锁，保存 state**）→ 线程入**条件队列** → 自旋 `park`；被 `signal` 后从条件队列**转移到 AQS 同步队列**，再 `acquireQueued` 重新抢锁
- `signal()`：把条件队列首节点 `transferForSignal` 到同步队列并置 `waitStatus=0`+前驱 `SIGNAL`（**不释放锁**）

## L4 追问树（面试官一路往下问，你能撑到第几层？）

> 规则：从上往下问。**第 1-3 层是应届生必备，第 4-6 层是拉开差距，第 7 层以后是"能答出来就是加分"。**

### 第 1 层｜`volatile` 保证什么？不保证什么？
**答**：保证**可见性**（写立刻对读可见）和**有序性**（禁止指令重排）；**不保证原子性**，`i++` 照样错，需要 `AtomicInteger` 或 `synchronized`。

### 第 2 层｜`volatile` 底层怎么做到可见 + 有序？
**答**：不是靠锁，而是靠 **CPU 内存屏障**：写前 `StoreStore`、写后 `StoreLoad`，读后 `LoadLoad` + `LoadStore`。x86 上写后那条由 `lock addl $0,(%rsp)` 实现，`lock` 前缀把本地缓存行置为独占并使其他核失效。

### 第 3 层｜happens-before 有哪些？怎么用它解释可见性？
**答**：八条（程序顺序、锁、volatile、start、join、中断、finalize、传递性）。可见性的本质是「hb 关系」：A hb B 且 A 写了变量，则 B 能看到。`synchronized` 的可见性来自「解锁 hb 后续加锁」，`volatile` 来自「写 hb 后续读」。

### 第 4 层｜四种内存屏障分别防什么重排？为什么 `StoreLoad` 最贵？
**答**：`LoadLoad` 防读读、`StoreStore` 防写写、`LoadStore` 防读写、`StoreLoad` 防写读。`StoreLoad` 最贵是因为它要求**把 store buffer 全部刷出并等待**，x86 上要 `mfence`/`lock` 前缀，代价接近一次内存往返。

### 第 5 层｜为什么 DCL 单例必须 `volatile`？
**答**：`new` 的三步（分配、初始化、赋值）里 ②③ 可能重排，导致别的线程拿到**未初始化完成**的对象。`volatile` 在写后插 `StoreStore`（实际是禁止前面的初始化被排到引用赋值之后），保证「看到非 null 时对象一定初始化完」。

### 第 6 层｜MESI 和 `volatile` 是什么关系？伪共享怎么解？
**答**：`volatile` 的可见性在硬件层就是 MESI 的 invalidate 协议：写时独占并让其他核缓存行失效。伪共享是**不同变量落在同一 64 字节缓存行**，互相 invalidate；解法是填充到不同行或 `@Contended`，`LongAdder.Cell`、`Disruptor` 都用这招。

### 第 7 层｜CAS 的底层是什么指令？有什么问题？
**答**：x86 的 `lock cmpxchg`（ARM 是 `ldrex/strex` 或 `cas`）。两个问题：**ABA**（值绕一圈回来了看不出变化，用 `AtomicStampedReference` 加版本号解）；**自旋开销**（高并发大量失败空转，用 `LongAdder` 分段或退避解）。

### 第 8 层｜`LongAdder` 为什么比 `AtomicLong` 快？代价是什么？
**答**：`AtomicLong` 所有线程 CAS **同一个 `value`**，竞争激烈时大量失败重试；`LongAdder` 用 `base + Cell[]`，线程按 `probe` 哈希分散到不同 Cell 各自 CAS，冲突概率大降，`sum()` 再汇总。代价：`sum()` 是弱一致的，并发累加时可能不准；内存占用更大。

### 第 9 层｜AQS 的 `state` 是什么？为什么用 `volatile`？谁来改？
**答**：`volatile int state`，语义由子类定义：`ReentrantLock` 里是重入次数（0 表示空闲），`Semaphore` 里是剩余许可，`CountDownLatch` 里是计数，`ReentrantReadWriteLock` 里高 16 位读锁、低 16 位写锁。用 `volatile` 保证可见性，所有修改都通过 `compareAndSetState`（CAS）保证原子性，只有 `exclusiveOwnerThread` 自己能改。

### 第 10 层｜`acquire` 的流程？`Node.waitStatus` 各值什么意思？
**答**：`tryAcquire` 成功即返回；失败 `addWaiter` 入队 → `acquireQueued` 自旋：前驱是 head 就再试 `tryAcquire`，失败则把前驱置 `SIGNAL` 然后 `park`。`waitStatus`：`SIGNAL(-1)` 后继需要唤醒、`CANCELLED(1)` 已取消、`CONDITION(-2)` 在条件队列、`PROPAGATE(-3)` 共享模式传播、`0` 初始。

### 第 11 层｜公平锁和非公平锁在源码上差哪一行？
**答**：就差 `tryAcquire` 里那句判断：非公平直接 `compareAndSetState(0,1)` 抢（还能插队）；公平先 `hasQueuedPredecessors()`，队列里有前驱就不抢。非公平的 `lock()` 还会先裸 CAS 一次，等于插两次队。

### 第 12 层｜`Condition.await()` 里到底发生了什么？为什么必须持锁？
**答**：`await` 先 `fullyRelease(state)` **完全释放锁**（把 state 存进节点，方便恢复重入次数），再把当前线程包成 `waitStatus=CONDITION` 的节点加入**条件队列**，然后自旋 `park`。`signal` 把它转移（`transferForSignal`）到 AQS 同步队列，等它重新 `acquireQueued` 抢到锁才从 `await` 返回。不持锁调用会 `IllegalMonitorStateException`，因为 `fullyRelease` 需要先校验 `isHeldExclusively()`。

### 第 13 层（终局）｜一次 `volatile` 写在 CPU 上到底发生了什么？
**答**：JIT 生成 `mov` + `lock` 前缀指令 → `lock` 使当前核缓存行进入 **M** 态并广播 invalidate（同时充当内存屏障，清空 store buffer、禁止指令越过）→ 其他核嗅探到后把自己的缓存行置 **I** → 它们下次读该变量必须回主存/从当前核缓存转发（cache-to-cache transfer）拿到新值 → 这就是「可见性」的物理实现。**分水岭：能说出 `lock` 前缀、store buffer、cache line invalidate 三件事。**

## L5 名词拆解表（"每个名词都拆开"）

| 名词 | 是什么 | 为什么存在 | 面试追问点 |
|---|---|---|---|
| JMM | Java 内存模型，规范线程与主内存交互的抽象 | 屏蔽不同 CPU 的缓存/重排差异 | 与硬件内存模型（x86 TSO）区别 |
| happens-before | 定义「前一个操作的可见性影响后一个」的偏序关系 | 给程序员可推理的规则，而非看汇编 | 八条规则、传递性 |
| 内存屏障 | CPU/编译器层面禁止重排的指令 | 把 hb 规则落到指令 | 四种屏障、x86 只需 StoreLoad |
| MESI | 四态缓存一致性协议 | 多核缓存不读到脏数据 | 四态转换、总线嗅探 |
| 伪共享 | 不同变量共享同一缓存行互相失效 | 解释「莫名慢十倍」 | 64 字节、`@Contended`、padding |
| `lock cmpxchg` | x86 原子比较交换指令 | CAS 的硬件基础 | 与 `mfence` 的区别 |
| ABA | 值 A→B→A，CAS 无法察觉 | 解释无锁栈/链表的隐蔽 bug | `AtomicStampedReference` 解 |
| `LongAdder` | `base + Cell[]` 分段累加器 | 高并发下降低 CAS 冲突 | `sum()` 不精确、`@Contended` |
| AQS `state` | `volatile int`，子类赋予语义 | 用一个 int 统一表达锁/许可/计数 | ReentrantLock/Semaphore/CountDownLatch 各是什么 |
| CLH 变体队列 | AQS 的双向 FIFO 队列（`head/tail`） | 让等待线程排队 `park`，避免忙等 | 为何是双向（需要 `unpark` 后继） |
| `Node.waitStatus` | 节点状态：SIGNAL/CANCELLED/CONDITION/PROPAGATE | 决定是否要唤醒后继、是否在条件队列 | 各值含义与转换 |
| `hasQueuedPredecessors` | 判断同步队列前面是否有人 | 公平锁的唯一开关 | 与 `tryAcquire` 的关系 |

## 代码验证（`jshell` 逐条跑）
```java
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import java.util.concurrent.locks.*;
import java.util.stream.IntStream;

// 1) volatile 可见性：去掉 volatile 可能死循环（JIT 提升为寄存器读）
class Flag { volatile boolean stop; }
Flag f = new Flag();
new Thread(() -> { while (!f.stop) { } System.out.println("线程看到 stop=true 退出了"); }).start();
Thread.sleep(200); f.stop = true;

// 2) volatile 不保证原子性 → i++ 丢更新；AtomicInteger 才对
int[] wrong = new int[1];
IntStream.range(0, 100_000).parallel().forEach(i -> wrong[0]++);
AtomicInteger right = new AtomicInteger();
IntStream.range(0, 100_000).parallel().forEach(i -> right.incrementAndGet());
System.out.println(wrong[0] + " vs " + right.get());   // 前者 <= 100000 且不确定

// 3) CAS + ABA 检测
AtomicInteger ai = new AtomicInteger(1);
System.out.println(ai.compareAndSet(1, 2) + " " + ai.compareAndSet(1, 3) + " " + ai.get()); // true false 2
AtomicStampedReference<Integer> asr = new AtomicStampedReference<>(1, 0);
int s = asr.getStamp();
asr.compareAndSet(1, 2, s, s + 1); asr.compareAndSet(2, 1, s + 1, s + 2);
System.out.println(asr.getReference() + " stamp=" + asr.getStamp());          // 1 stamp=2
System.out.println(asr.compareAndSet(1, 9, s, s + 1));                       // false，被戳记挡住

// 4) 手写 Mutex，验证 AQS 模板方法（只需实现 tryAcquire/tryRelease）
class Mutex extends AbstractQueuedSynchronizer {
    protected boolean tryAcquire(int a) { return compareAndSetState(0, 1); }
    protected boolean tryRelease(int a) { setState(0); return true; }
    void lock() { acquire(1); } void unlock() { release(1); }
}
Mutex m = new Mutex(); m.lock(); m.unlock();   // 只实现 tryAcquire/tryRelease，模板方法在 AQS 里
System.out.println("AQS 模板方法 OK（注意：这个 Mutex 不可重入，lock 两次会自己挂起）");
```

## 高频错误（面试官最爱抓的）

| 错误说法 | 正确说法 |
|---|---|
| 「`volatile` 保证原子性」 | 只保证可见性 + 有序性，`i++` 照样丢更新 |
| 「`volatile` 靠加锁实现」 | 靠内存屏障/`lock` 前缀，不进内核、不阻塞 |
| 「happens-before 是时间先后」 | 是**可见性保证**，不是时钟顺序 |
| 「DCL 加 `synchronized` 就够了」 | 不加 `volatile` 可能拿到半初始化对象 |
| 「CAS 没有锁所以没开销」 | 自旋失败是纯 CPU 空转，高并发反而更慢 |
| 「AQS 队列是 CLH 队列」 | 是 **CLH 变体**（双向、显式 `head/tail`），原版 CLH 无 next 指针 |
| 「`signal()` 会唤醒并让它立刻执行」 | 只是转移到同步队列，还要重新抢锁 |

## 关联文件

- 上一层（Java 并发八股）：[Java基础与并发](../../03-java/Java基础与并发.md)（第 16-19 节 volatile / ThreadLocal / CAS / AQS）
- 同层追问：[synchronized 与锁升级](./09-synchronized与锁升级.md)（Mark Word 与 Monitor）｜[线程池](./08-线程池.md)（`Worker` 的 AQS 用法）｜[ThreadLocal](./11-ThreadLocal.md)
- Spring 侧落地：[SpringBoot与后端工程](../../03-java/SpringBoot与后端工程.md)（`@Async` + `AtomicInteger` 做任务计数）
- 典型场景：AI Agent 基础设施里「工具调用计数、限流令牌桶」用 `LongAdder` / `Semaphore`；`ConcurrentHashMap` 的 `size()` 也是分段思想
- 速查：[深度追问索引](../00-索引.md)

## 自测标准

- 能背 happens-before 八条，并用它解释 `synchronized` 与 `volatile` 的可见性
- 能说清四种内存屏障、volatile 写/读各插在哪、x86 上为什么 `StoreLoad` 最贵
- 能用 `new` 三步重排解释 DCL 为什么必须 `volatile`
- 能讲 CAS 指令、ABA、`AtomicStampedReference`、`LongAdder` 的分段 Cell
- 能默写 AQS 的 `state` + `Node.waitStatus`，画出 `acquire` 流程和 Condition 队列转移
- L4 讲到第 9 层（`state` 语义）→ 及格；讲到第 13 层（`lock` 前缀 + store buffer）→ 优秀
