# synchronized 与锁升级

> 面试权重：5/5　｜　追问深度：**L5（Mark Word / 偏向锁撤销 / ObjectMonitor 竞争队列）**
> 一句话定位：`synchronized` 是 JVM 内置的悲观互斥锁，锁状态不独立存在，而是**存在对象头的 Mark Word 里**，按竞争激烈程度从偏向锁 → 轻量级锁（CAS + 自旋）→ 重量级锁（`ObjectMonitor` + OS 互斥量）逐级升级，且**只升不降**。

[返回深度追问索引](../00-索引.md)

## L1 一句话答案（10 秒能说出口）

同步代码块编译成 `monitorenter` / `monitorexit` 两条字节码，同步方法靠方法访问标志 `ACC_SYNCHRONIZED`；JVM 把锁状态记在**对象头 Mark Word** 里，先尝试偏向锁（无竞争时一次 CAS 记线程 ID），有竞争升级为轻量级锁（栈帧 Lock Record + CAS 自旋），自旋失败再膨胀成重量级锁（`ObjectMonitor`，`_owner` 记录持有者，竞争线程进 `_EntryList`/`_cxq` 排队阻塞）。

## L2 原理层：三种写法与对象头布局

```java
synchronized (obj) { ... }              // 锁 obj 这个对象
public synchronized void m() { ... }    // 锁 this
public static synchronized void s() { } // 锁 Class 对象（XXX.class）
```

| 写法 | 锁的是谁 | 字节码表现 |
|---|---|---|
| 同步代码块 | 括号里的对象 | `monitorenter` … `monitorexit` ×2（正常 + 异常路径） |
| 同步实例方法 | `this` | 方法标志 `ACC_SYNCHRONIZED`，无显式指令 |
| 同步静态方法 | `Class` 对象 | 同上；类锁与实例锁互不影响 |

**对象头（64 位 HotSpot）**：

```
┌──────────── Mark Word (8 字节 / 64 bit) ────────────┬── Klass Pointer ──┬─ 数组长度(仅数组) ─┐
│ biased_lock:1 | lock:2 | 其余位按状态复用              │ 压缩后 4 字节      │      4 字节        │
└─────────────────────────────────────────────────────┴───────────────────┴───────────────────┘
```

**Mark Word 的 5 种状态**（`lock` 2 bit 是判别位）：

| 状态 | lock 位 | biased_lock | 内容 | 为什么存在 |
|---|---|---|---|---|
| 无锁 | `01` | 0 | 25bit unused + 31bit hashCode + 1bit unused + 4bit 分代年龄 | 普通对象，`hashCode` 也在里面 |
| 偏向锁 | `01` | 1 | 54bit ThreadID + 2bit epoch + 1bit unused + 4bit age | 无竞争时免 CAS，重入只比线程 ID |
| 轻量级锁 | `00` | — | 62bit 指向**栈上 Lock Record** 的指针 | 短暂竞争用自旋代替阻塞 |
| 重量级锁 | `10` | — | 62bit 指向**堆中 ObjectMonitor** 的指针 | 竞争激烈时交给 OS 排队 |
| GC 标记 | `11` | — | 空（用于标记存活） | 与锁无关，但同占 2 位 |

**升级路径（单行道）**：`无锁 → 偏向锁 →(有竞争) 轻量级锁 →(自旋失败) 重量级锁`。`hashCode` 一旦被计算，偏向状态会被撤销（偏向下无法再存 hash），这是「调过 `hashCode()` 后没偏向锁」的原因。**JDK 15 起偏向锁默认关闭（JEP 374），但在 Java 21 面试里仍是必问的历史知识点**——它是理解「锁为什么能这么便宜」的起点。

## L3 底层层：偏向锁撤销 / Lock Record / ObjectMonitor

### 3.1 偏向锁：一次 CAS 记住「常用人」

加锁：对象头 `biased_lock=1, lock=01` 且 ThreadID 为空 → **CAS 把自己的线程 ID 写进高 54 位**；成功即拿到锁。之后每次进入只比较 ThreadID，相等就直接过（连 CAS 都不用）。重入次数不记在对象头，而在栈上 Lock Record 里，每重入一次压一个。

**撤销（revoke）为什么贵**：偏向锁假设「永远同一个线程」，一旦第二个线程来抢，必须**等到 safepoint**，由 VM 线程把 Mark Word 改回无锁，并**遍历持有者线程的栈帧**修正锁记录。单次撤销要停顿。

**批量优化（阈值写在 `Thread` 类里）**：

| 机制 | 触发 | 动作 |
|---|---|---|
| 批量重偏向（bulk rebias） | 同一类对象撤销达 **20** 次 | 把该类的 `epoch` +1，旧 epoch 的偏向全部失效并允许重偏向 |
| 批量撤销（bulk revoke） | 撤销达 **40** 次 | 该类**彻底禁止**偏向，后续新对象无锁创建 |

判定靠 Mark Word 里的 **epoch** 与类对象上的 epoch 比较：不一致 ⇒ 直接视为可重偏向。

### 3.2 轻量级锁：栈上 Lock Record + CAS

线程栈帧中会分配 **Lock Record**：`_displaced_header`（保存原 Mark Word）+ `_owner`（指向锁对象）。

1. 把对象 Mark Word **复制**到 Lock Record 的 `_displaced_header`
2. **CAS** 把对象 Mark Word 改成「指向 Lock Record 的指针」，并置 `lock=00`
   - 成功 ⇒ 拿到轻量级锁
   - 失败 ⇒ 检查是不是自己重入（指向本线程栈帧）⇒ 是则再加一个 Lock Record
   - 否则 ⇒ 有别人持有 ⇒ **自旋**（自适应自旋，次数由上次成功率决定，`-XX:PreBlockSpin` 老参数）尝试；自旋超限 ⇒ **膨胀为重量级锁**，进入等待队列挂起

解锁：CAS 把 `_displaced_header` 写回；若发现 Mark Word 已不是自己那份（已膨胀）⇒ 走重量级解锁（`ObjectMonitor::exit`）。

### 3.3 重量级锁：ObjectMonitor（HotSpot C++ 结构）

```cpp
class ObjectMonitor {
  volatile markOop _header;    // 原始 Mark Word
  intptr_t _count;             // 重入次数（_recursions 的旧名）
  intptr_t _waiters;           // wait 的线程数
  intptr_t _recursions;        // 重入次数
  void*    _owner;             // 重点：当前持有锁的线程
  ObjectWaiter* volatile _WaitSet;   // 重点：调用 wait() 的线程（双向循环链表）
  ObjectWaiter* volatile _EntryList; // 重点：等锁被唤醒后争抢的线程
  ObjectWaiter* volatile _cxq;       // 刚进入竞争、还没排队的线程（单向 LIFO）
  void*    _next;
};
```

**加锁（`ObjectMonitor::enter`）**：

1. `CAS(_owner, null, self)` —— 直接抢，成功就返回（**这就是非公平的根源**）
2. 是自己 ⇒ `_recursions++`
3. 失败 ⇒ 自适应自旋试几次；仍失败 ⇒ 把线程包成 `ObjectWaiter` **头插进 `_cxq`**，`park()` 挂起
4. 持有者 `exit()` 时 `_recursions--`，归零则 `_owner=null`，从 `_EntryList`/`_cxq` 唤醒线程（被唤醒者**还要重新抢**，不是直接交接）

`wait()`：把当前线程放进 `_WaitSet` 并**完全释放锁**（`_recursions` 保存），`notify()` 把 `_WaitSet` 里的线程移到 `_EntryList`（**并不释放锁**，退出同步块后它才能抢）。所以 `wait/notify` 必须在持锁时调用，否则 `IllegalMonitorStateException`。

### 3.4 为什么 `synchronized` 只支持非公平

- `monitorenter` 的实现就是「先 CAS `_owner` 再说」，**新来的线程可以直接插队**，阻塞队列里的线程被唤醒后还要重新竞争
- 公平锁需要维护严格 FIFO 并在每次加锁时检查「队列前面有没有人」（`ReentrantLock` 的 `hasQueuedPredecessors`），额外开销换吞吐下降
- JVM 没有提供公平版 `synchronized` 的开关；要公平就换 `new ReentrantLock(true)`

好处：非公平吞吐更高（减少线程唤醒的上下文切换），代价是可能饥饿。

### 3.5 锁消除与锁粗化（JIT 层）

- **锁消除**：逃逸分析证明锁对象不逃逸出方法（如方法内 `new Object()` 加锁），JIT 直接删掉 `monitorenter/monitorexit`
- **锁粗化**：循环体内反复加同一把锁，JIT 把锁提升到循环外，减少进出开销
- 这也是「压测时 synchronized 有时看起来几乎不要钱」的原因：**微基准必须防 JIT 优化**（JMH）

## L4 追问树（面试官一路往下问，你能撑到第几层？）

> 规则：从上往下问。**第 1-3 层是应届生必备，第 4-6 层是拉开差距，第 7 层以后是"能答出来就是加分"。**

### 第 1 层｜`synchronized` 的原理？
**答**：代码块编译成 `monitorenter`/`monitorexit`，方法用 `ACC_SYNCHRONIZED` 标志；JVM 进入时获取对象的 monitor，退出时释放。锁状态存在**对象头 Mark Word**，不是独立字段。

### 第 2 层｜为什么反编译同步代码块能看到两条 `monitorexit`？
**答**：一条是正常路径，一条挂在**异常表（Exception table）的 handler** 上——必须保证抛异常也能释放锁，否则死锁。字节码里有 `monitorexit` + `athrow` 的补偿路径。

### 第 3 层｜锁升级的过程？为什么只升不降？
**答**：无锁 → 偏向（一次 CAS 记 ThreadID）→ 轻量级（CAS 换 Mark Word 指向栈上 Lock Record + 自旋）→ 重量级（`ObjectMonitor` 排队阻塞）。不降级是因为**降级需要额外 safepoint + 遍历栈帧**，收益不确定；HotSpot 选择让锁停在最重状态，简单且稳定。

### 第 4 层｜偏向锁怎么加？撤销为什么这么贵？
**答**：无竞争时 CAS 把线程 ID 写进 Mark Word 高 54 位；重入只比较 ID，连 CAS 都省。撤销时要**等 safepoint**（停下所有线程），改回无锁，并**遍历持有者线程的栈帧**把锁记录改掉。所以偏向锁只适合「一直同一个线程」的场景，JDK 15 起默认关闭。

### 第 5 层｜批量重偏向 / 批量撤销的阈值是多少？靠什么判定？
**答**：同一类的偏向撤销达 **20** 次触发批量重偏向（类 `epoch` +1，旧对象的偏向失效但仍可重新偏向）；达 **40** 次触发批量撤销（该类彻底禁止偏向）。判定靠 Mark Word 里的 2 bit `epoch` 与类上的 epoch 比对，不一致就直接视为可重偏向。

### 第 6 层｜轻量级锁的 Lock Record 在哪？CAS 的到底是什么？
**答**：在当前**线程栈帧**里分配 Lock Record，先把对象 Mark Word 存进 `_displaced_header`，然后 CAS 把对象的 Mark Word 替换成「指向该 Lock Record 的指针」并把 `lock` 位改成 `00`。CAS 成功 = 拿到锁；失败且指向本线程栈帧 = 重入（再压一个 Lock Record）；失败且指向别人 = 自旋/膨胀。

### 第 7 层｜自旋是怎么停的？为什么要"自适应"？
**答**：自旋失败超过阈值（或全局自旋失败）就膨胀为重量级锁。自适应自旋的次数不固定：由「上次在这个锁上自旋是否成功、成功率」决定——成功的锁下次多转几圈，总失败的锁直接不转。目的是避免在「临界区很长」的锁上空转浪费 CPU。

### 第 8 层｜`ObjectMonitor` 的关键字段？`_EntryList` 和 `_WaitSet` 区别？
**答**：`_owner` 持有者、`_recursions` 重入次数、`_cxq` 刚竞争失败的栈、`_EntryList` 被唤醒后等抢锁的队列、`_WaitSet` 调了 `wait()` 的线程。区别：`_WaitSet` 里的线程是**主动让出**等 `notify`；`_EntryList` 里是**被动等锁**，`notify` 只是把线程从 `_WaitSet` 搬到 `_EntryList`，并不释放锁。

### 第 9 层｜为什么 `synchronized` 是非公平的？有什么后果？
**答**：`enter` 第一步就是 `CAS(_owner, null, self)`，新线程可以直接抢；被 `exit` 唤醒的线程还要重新参与竞争。后果是**老线程可能饥饿**，但减少了唤醒后的空转，吞吐更高。要公平必须用 `new ReentrantLock(true)`，代价是每次都要 `hasQueuedPredecessors` 检查队列。

### 第 10 层｜`synchronized` 和 `ReentrantLock` 怎么选？
**答**：优先 `synchronized`——语法简单、JVM 持续优化（锁消除/粗化/偏向）、异常安全自动释放。需要以下能力才上 `ReentrantLock`：公平锁、`tryLock(timeout)` 可中断/可超时、`Condition` 多等待队列（`synchronized` 只有一个 `_WaitSet`）、跨方法手动控制锁粒度。

### 第 11 层｜锁真的"只升不降"吗？有没有例外？
**答**：常规路径不降级。但有两处「看起来像降级」：① 偏向锁撤销本身是恢复到无锁（这是撤销，不是降级）；② JIT 的锁消除/粗化会把锁**直接消灭**或提升，属于编译优化而非降级。另外 `ObjectMonitor` 在 `exit` 后 `_owner=null`，对象 Mark Word 仍是重量级锁指针，**不会**变回轻量级。

### 第 12 层（终局）｜一次 `monitorenter` 在 CPU / OS 层到底发生了什么？
**答**：轻量级阶段：`lock cmpxchg` 指令（x86 上隐含缓存行锁定 / 必要时总线锁），保证 CAS 原子，并触发 MESI 的独占状态转换。重量级阶段：`ObjectMonitor::enter` 竞争失败 → `ObjectWaiter` 入队 → `Thread::park` → 底层 `pthread_mutex_lock`/`futex(FUTEX_WAIT)` 陷入内核挂起；`exit` 时 `unpark` → `futex(FUTEX_WAKE)` 唤醒，线程从内核态返回用户态继续竞争。**分水岭：能说出「轻量级锁是用户态 CAS，重量级锁才进内核」——这就是锁升级的价值。**

## L5 名词拆解表（"每个名词都拆开"）

| 名词 | 是什么 | 为什么存在 | 面试追问点 |
|---|---|---|---|
| Mark Word | 对象头 8 字节，存 hash/年龄/锁标志 | 复用同一块内存表达 5 种锁状态，零额外空间 | 5 种状态的位布局、hashCode 与偏向的冲突 |
| Klass Pointer | 对象头中指向类元数据的指针 | 找类型、虚方法表、方法区入口 | 压缩指针（`-XX:+UseCompressedOops`） |
| `monitorenter` / `monitorexit` | JVM 指令，获取/释放 monitor | 把「加锁」语义显式落到字节码 | 为什么有两条 exit（异常表） |
| `ACC_SYNCHRONIZED` | 方法访问标志位 | 同步方法不需要显式指令 | 静态方法与实例方法锁对象不同 |
| 偏向锁 | 无竞争时一次 CAS 记 ThreadID | 消除重复加锁的 CAS 开销 | 撤销要 safepoint、JDK 15 后默认关 |
| `epoch` | Mark Word 里 2 bit 的「偏向批次号」 | 支持批量重偏向，避免逐个撤销 | 20/40 阈值与批量重偏向流程 |
| Lock Record | 栈帧中的锁记录（`_displaced_header` + owner） | 保存原 Mark Word 与重入计数，栈上分配无锁开销 | 在哪分配、重入时压几个 |
| `_displaced_header` | Lock Record 里备份的原 Mark Word | 解锁时 CAS 还原对象头 | 膨胀后还原失败怎么办 |
| 自适应自旋 | 自旋次数由上次成功率决定 | 减少「短临界区」的线程阻塞代价 | 自旋失败后膨胀 |
| `ObjectMonitor` | C++ 实现的管程对象（堆中） | 重量级锁的真正载体 | 关键字段、`enter/exit` 流程 |
| `_owner` / `_recursions` | 持有线程 / 重入次数 | 实现可重入与所有权判断 | 重入如何计数、何时清零 |
| `_WaitSet` | 调用 `wait()` 的线程集合 | 让线程主动等待并释放锁 | 与 `_EntryList` 的区别、`notify` 搬移 |
| `_EntryList` / `_cxq` | 等锁队列 / 刚失败的栈 | 竞争线程排队，避免忙等 | 入队顺序、被唤醒后为何还要抢 |
| safepoint | 全局停顿点，所有线程暂停 | 让 VM 能安全地批量改对象头/栈帧 | 偏向撤销、GC、去优化都在此发生 |
| 锁消除 / 粗化 | JIT 优化：删锁 / 合并锁 | 减少不可能有竞争或过细的加锁开销 | 逃逸分析、JMH 防优化 |

## 代码验证（`javac` + `javap` + `jshell` 逐条跑）

```java
// 保存为 SyncDemo.java
public class SyncDemo {
    private final Object lock = new Object();
    private int count;
    public void block() { synchronized (lock) { count++; } }      // 代码块 → monitorenter
    public synchronized void method() { count++; }                 // 方法标志 ACC_SYNCHRONIZED
    public static synchronized void staticMethod() { }              // 锁 Class 对象
}
```

```bash
javac SyncDemo.java
javap -c -p SyncDemo      # 看 block() 里的 monitorenter/monitorexit ×2 + 异常表
javap -v SyncDemo | findstr ACC_SYNCHRONIZED   # 同步方法没有 monitorenter，靠标志位
```

```java
// 用 jshell 验证：可重入，且 wait() 不持锁必抛 IMSE
Object lock = new Object();
synchronized (lock) { synchronized (lock) { System.out.println("重入 OK"); } }
try { lock.wait(); } catch (IllegalMonitorStateException e) { System.out.println("不持锁 wait → IMSE"); }
```

```java
// 保存为 DeadlockDemo.java：javac DeadlockDemo.java && java DeadlockDemo
import java.lang.management.ManagementFactory;

public class DeadlockDemo {
    public static void main(String[] args) throws Exception {
        Object x = new Object(), y = new Object();
        Thread t1 = new Thread(() -> { synchronized (x) { sleep(100); synchronized (y) { } } }, "t1");
        Thread t2 = new Thread(() -> { synchronized (y) { sleep(100); synchronized (x) { } } }, "t2");
        t1.start(); t2.start();
        t1.join(1000); t2.join(1000);
        long[] ids = ManagementFactory.getThreadMXBean().findDeadlockedThreads();
        System.out.println("死锁线程数=" + ids.length);   // 2
        System.exit(0);
    }
    static void sleep(long ms) { try { Thread.sleep(ms); } catch (InterruptedException e) { } }
}
```

## 高频错误（面试官最爱抓的）

| 错误说法 | 正确说法 |
|---|---|
| 「锁对象里有一个锁字段」 | 锁状态在**对象头 Mark Word**，不在对象字段 |
| 「synchronized 一定是重量级锁」 | 无竞争走偏向锁，短竞争走轻量级锁 |
| 「锁可以降级」 | 只升不降；偏向锁撤销是恢复无锁，不是降级 |
| 「轻量级锁失败就直接阻塞」 | 先自适应自旋，超限才膨胀成重量级 |
| 「`notify()` 会释放锁并交接」 | 只是把线程从 `_WaitSet` 移到 `_EntryList`，锁要等同步块结束才释放 |
| 「静态方法锁的是 `this`」 | 锁的是 `Class` 对象；实例锁与本类锁不互斥 |
| 「偏向锁在 Java 21 还是默认开启」 | JDK 15 起默认关闭（JEP 374），但考点仍在 |
| 「`wait()` 是 Thread 的方法，不需要持锁」 | 必须在持有 monitor 时调用，否则 IMSE |

## 关联文件

- 上一层（Java 并发八股）：[Java基础与并发](../../03-java/Java基础与并发.md)（第 15 节 synchronized 与 Lock）
- 同层追问：[线程池](./08-线程池.md)（`Worker` 也用 AQS 做忙闲标记）｜[volatile、CAS 与 AQS](./10-volatile-CAS-AQS.md)｜[ThreadLocal](./11-ThreadLocal.md)
- Spring 侧落地：[SpringBoot与后端工程](../../03-java/SpringBoot与后端工程.md)（单例 Bean 的线程安全与局部锁）
- 典型场景：审批状态流转用「乐观锁 + `synchronized` 都别乱加」——正确姿势是数据库行锁/版本号，`synchronized` 只在单 JVM 内有效，分布式场景必须换 Redis/DB 锁
- 速查：[深度追问索引](../00-索引.md)

## 自测标准

- 能背出 Mark Word **5 种状态**的 lock 位，并画出升级路径
- 能讲清偏向锁「加锁 1 次 CAS、撤销要 safepoint + 遍历栈帧」以及 20/40 批量阈值
- 能解释轻量级锁的 Lock Record 在哪、CAS 换的是什么
- 能默写 `ObjectMonitor` 的 `_owner/_recursions/_WaitSet/_EntryList/_cxq` 并说清 `enter/exit` 流程
- 能说清「为什么非公平」→ 直接 CAS 抢 `_owner`
- L4 讲到第 8 层（Monitor 字段）→ 及格；讲到第 12 层（`cmpxchg`/`futex`）→ 优秀
