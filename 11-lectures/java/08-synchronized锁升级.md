# synchronized 在对象头里到底发生了什么变化？

> 精讲层级：从「零基础能看懂」到「源码级」，每个名词都拆开
> 阅读时间：约 35 分钟
> 配套速查：[synchronized 与锁升级（深度追问）](../../10-deep-dive/java/09-synchronized与锁升级.md)
> 返回：[精讲索引](../00-索引.md)

---

## 0. 一句话先讲明白

`synchronized` 的锁状态不在锁对象里单开一个字段，而是**存在对象头的 Mark Word（对象头里的一小段元数据）里**。JVM 会按「竞争激烈程度」逐级升级：

- 没人抢：**偏向锁**（只用一个 CAS 把当前线程 ID 写进对象头，之后连 CAS 都不用）
- 有短暂竞争：**轻量级锁**（在栈帧上放一个 Lock Record，用 CAS 把对象头改成指向它，失败就自旋）
- 竞争激烈：**重量级锁**（对象头指向一个 C++ 的 `ObjectMonitor`，抢不到的线程进队列阻塞，由操作系统唤醒）

**只升不降**。这就是为什么同一个 `synchronized` 关键字，在无竞争时几乎免费，在高竞争时才变成昂贵的阻塞。

---

## 1. 痛点背景：为什么需要一个「会变形的锁」

### 1.1 先看没有锁会出什么事

```java
public class Counter {
    private int count = 0;
    public void inc() { count++; }   // 不是原子操作
}
```

`count++` 在字节码里是四步：

```
aload_0                        // 取 this
dup
getfield  count                // 1. 读 count 到栈顶
iconst_1                       // 2. 压入常量 1
iadd                           // 3. 相加
putfield  count                // 4. 写回 count
```

两个线程同时执行时，可能出现「A 读到 0、B 读到 0、A 写 1、B 写 1」——**两次自增只加了 1**，这叫丢失更新（lost update）。

### 1.2 锁要同时解决三个问题

| 问题 | 含义 | 锁如何解决 |
|---|---|---|
| 原子性 | 一段代码要么全做、要么不做 | 互斥：同一时刻只有一个线程进入临界区 |
| 可见性 | 一个线程的修改，另一个线程要能看到 | 释放锁时把工作内存刷回主内存，获取锁时从主内存重新读 |
| 有序性 | 编译器/CPU 不能随意重排临界区内的指令 | 锁的内存语义天然禁止临界区内外重排 |

### 1.3 但「锁」本身很贵，所以必须分级

如果所有 `synchronized` 都直接走重量级锁（操作系统互斥量）：

```
一次无竞争的加锁/解锁：需要系统调用（futex）+ 内核态/用户态切换
耗时：约 20 ~ 100 纳秒（有竞争时还要加上线程挂起/唤醒，微秒级）
对比：一次普通 CAS 约 1 ~ 10 纳秒，一条加法指令不到 1 纳秒
```

而现实中大量 `synchronized` 是**单线程访问**或**竞争极短**的（比如 `Vector` 的方法、`StringBuffer`）。为这些场景付内核切换的代价太浪费，所以 JVM 设计了三级锁：**能不加锁就不加（偏向），能自旋就不阻塞（轻量级），实在不行才阻塞（重量级）**。

---

## 2. 逐步拆解：字节码、对象头、三级锁

### 2.1 三种写法与字节码

```java
public class SyncDemo {
    private final Object lock = new Object();
    private int count;

    public void block() { synchronized (lock) { count++; } }   // 同步代码块
    public synchronized void method() { count++; }             // 同步实例方法
    public static synchronized void staticMethod() { }         // 同步静态方法
}
```

**同步代码块**编译后是两条指令 + 一张异常表：

```
public void block();
  Code:
     0: aload_0
     1: getfield      #7        // lock
     4: dup
     5: astore_1
     6: monitorenter            // ← 进入监视器
     7: aload_0
     8: dup
     9: getfield      #13       // count
    12: iconst_1
    13: iadd
    14: putfield      #13
    17: aload_1
    18: monitorexit             // ← 正常退出
    19: goto          27
    22: astore_2
    23: aload_1
    24: monitorexit             // ← 异常出口也必须释放
    25: aload_2
    26: athrow
    27: return
  Exception table:
     from    to  target type
         7    19    22   any
```

**数字化推导**：一条同步代码块在字节码层是 **1 条 `monitorenter` + 2 条 `monitorexit`**，第 2 条挂在异常表（`Exception table`）上。偏移量 7~19 是临界区，一旦抛异常跳到 22 执行 `monitorexit` 再 `athrow`——**编译器替我们保证了 finally 语义**，所以不会因为异常导致锁泄漏。

**同步方法**没有 `monitorenter`，而是方法访问标志多一个 `ACC_SYNCHRONIZED`：

```
javap -v SyncDemo | findstr ACC_SYNCHRONIZED
  flags: (0x0021) ACC_PUBLIC, ACC_SYNCHRONIZED
  flags: (0x0029) ACC_PUBLIC, ACC_STATIC, ACC_SYNCHRONIZED
```

JVM 在方法调用时检查这个标志，自动加锁/解锁，不需要显式指令。

| 写法 | 锁对象 | 字节码表现 |
|---|---|---|
| `synchronized (obj)` | 括号里的对象 | `monitorenter` + `monitorexit` ×2 |
| `synchronized void m()` | `this` | 方法标志 `ACC_SYNCHRONIZED` |
| `static synchronized void s()` | `Xxx.class`（Class 对象） | 同上，但锁的是类对象 |

**实例锁和类锁互不影响**：一个线程锁 `this`、另一个线程锁 `Xxx.class`，两者不冲突。

### 2.2 对象头：Mark Word 到底长什么样

HotSpot 的对象在内存里分三部分：

```
┌─────────────────────────── 对象头（Header） ───────────────────────────┬──────────┐
│ Mark Word (8 字节 / 64 bit)  │  Klass Pointer (4 或 8 字节)  │ 数组长度(仅数组) │  实例字段 │
└───────────────────────────────────────────────────────────┴──────────────────┘
```

`Mark Word` 是一个「复用的 8 字节」：同一块内存，在**不同锁状态下存不同的东西**。这就是为什么它能在不增加对象大小的前提下表达 5 种状态。

**64 位下五种状态的位布局**（数字推导：`25+31+1+4+1+2 = 64`）：

| 状态 | 位布局 | 关键位 |
|---|---|---|
| 无锁 | `unused:25`、`hashCode:31`、`unused:1`、`age:4`、`biased_lock:1=0`、`lock:2=01` | lock=01，biased_lock=0 |
| 偏向锁 | `ThreadID:54`、`epoch:2`、`unused:1`、`age:4`、`biased_lock:1=1`、`lock:2=01` | lock=01，biased_lock=1 |
| 轻量级锁 | `ptr_to_lock_record:62`、`lock:2=00` | 指向栈帧 Lock Record |
| 重量级锁 | `ptr_to_heavyweight_monitor:62`、`lock:2=10` | 指向 ObjectMonitor |
| GC 标记 | 空（内容由 GC 使用）、`lock:2=11` | 与锁无关 |

**逐位解释**：

| 字段 | 位数 | 含义 | 为什么需要 |
|---|---|---|---|
| `hashCode` | 31 | 对象身份哈希（第一次调用 `Object.hashCode()` 才写入） | 无锁/偏向态才存得下 |
| `age` | 4 | 分代年龄，最大 15 | GC 判断晋升老年代 |
| `biased_lock` | 1 | 是否处于「可偏向」模式 | 与 lock 位组合区分偏向态 |
| `lock` | 2 | 锁标志位：01/00/10/11 | **最核心的判别位** |
| `ThreadID` | 54 | 偏向的线程 ID | 无竞争时省掉 CAS |
| `epoch` | 2 | 偏向批次号 | 支持「批量重偏向」 |
| `ptr` | 62 | 指向 Lock Record 或 ObjectMonitor | 有竞争时把状态「外包」出去 |

**一个关键冲突**：偏向锁需要 54 位存 ThreadID，`hashCode` 需要 31 位，两者**不能同时存在**。所以一旦对象调用过 `hashCode()`（或 `System.identityHashCode()`），偏向锁就会被撤销——这也是「计算过 hashCode 的对象没有偏向锁」的原因。

### 2.3 偏向锁：一次 CAS 记住「常用人」

**加锁流程**：

1. 检查对象头 `biased_lock=1 && lock=01`（表示可偏向），且 `ThreadID` 为空 → **CAS 把自己的线程 ID 写进高 54 位**
2. CAS 成功 → 拿到锁，Mark Word 保持「偏向当前线程」
3. 之后同一线程再进入：只比较 `ThreadID` 是否等于自己，**相等就直接过，一条 CAS 都不用**
4. 如果 ThreadID 是别的线程：进入**撤销（revoke）**流程

**撤销为什么贵**：偏向锁假设「永远同一个线程」，一旦出现第二个线程，必须：

1. **等到安全点（safepoint）**——一个所有线程都停下来的时刻（GC、偏向撤销都靠它）
2. 由 VM 线程把 Mark Word 改回「无锁」或「轻量级锁」
3. **遍历持有偏向的线程的栈帧**，修正栈上的锁记录

一次偏向撤销的停顿在几十微秒到毫秒级，**批量场景下是灾难**，所以 HotSpot 又加了两个批量优化。下一节详细讲。

### 2.4 轻量级锁：栈帧里的 Lock Record

**加锁流程**：

1. 在当前线程的**栈帧**中分配一个 `Lock Record`（锁记录），包含 `_displaced_header`（保存原 Mark Word）和 `_owner`（指向锁对象）
2. 把对象的 Mark Word **复制**到 `_displaced_header`
3. **CAS**：把对象的 Mark Word 改成「指向这个 Lock Record 的指针」，并把 `lock` 位置成 `00`
4. CAS 成功 → 拿到轻量级锁
5. CAS 失败 → 检查 Mark Word 是否指向**本线程的某个 Lock Record**（是自己重入）→ 是则再压一个 Lock Record（重入计数）
6. 否则说明有别人持有 → **自旋**（自适应自旋）尝试；自旋超过阈值 → **膨胀为重量级锁**

**解锁**：CAS 把 `_displaced_header` 写回对象头。如果发现对象头已经被改成重量级锁（指向 `ObjectMonitor`），则走 `ObjectMonitor::exit`。

**栈帧模型**（极简：一个线程两层重入）：

```
线程栈帧
├── Lock Record #2  _displaced_header = null（重入，标记用）
├── Lock Record #1  _displaced_header = 原 Mark Word
└── 局部变量 ...
对象头 Mark Word ──► 指向 Lock Record #1
```

### 2.5 重量级锁：ObjectMonitor 与三个队列

对象头指向的 `ObjectMonitor` 是 HotSpot 用 C++ 实现的「管程（monitor）」：

```cpp
class ObjectMonitor {
  void*    _owner;             // 当前持有锁的线程
  intptr_t _recursions;        // 重入次数
  ObjectWaiter* _WaitSet;      // 调用 wait() 的线程（双向循环链表）
  ObjectWaiter* _EntryList;    // 被唤醒后、等待抢锁的线程
  ObjectWaiter* _cxq;          // 刚竞争失败、还没排队的线程（LIFO 栈）
  volatile markOop _header;    // 原始 Mark Word
  intptr_t _count, _waiters;
};
```

**三个队列的分工（面试高频）**：

| 队列 | 里面是谁 | 什么时候进 | 什么时候出 |
|---|---|---|---|
| `_cxq` | 刚竞争失败的线程（后进先出） | `ObjectMonitor::enter` 自旋失败后 | 持有者 `exit` 时被批量转移到 `_EntryList` |
| `_EntryList` | 等锁的线程 | 从 `_cxq` 转移过来 | 抢到锁 |
| `_WaitSet` | 调了 `wait()` 的线程 | `wait()` 时（进入前先完全释放锁） | `notify/notifyAll` 后被移到 `_EntryList` |

**加锁流程**：

```
enter(monitor)
 ├─ CAS(_owner, null, self) 成功 → 直接拿到（这是非公平的根源：新线程可以插队）
 ├─ 是自己 → _recursions++
 └─ 失败 → 自适应自旋 → 仍失败 → 包成 ObjectWaiter 头插进 _cxq → park() 挂起
```

**解锁流程**：`_recursions--`，归零则 `_owner=null`，然后从 `_EntryList/_cxq` 唤醒一个线程——**被唤醒的线程还要重新竞争**，不是直接交接。

`wait/notify` 的语义也在这里：`wait()` 把线程放进 `_WaitSet` 并**完全释放锁**（重入次数暂存），`notify()` 把 `_WaitSet` 里的线程移到 `_EntryList`（**不释放锁**），所以它们必须在 `synchronized` 块里调用。

### 2.6 锁升级的完整路径

```
无锁（lock=01, biased=0）
  │ 第一个线程访问，且偏向延迟已过
  ▼
偏向锁（lock=01, biased=1, ThreadID=当前线程）
  │ 第二个线程来抢，撤销偏向
  ▼
轻量级锁（lock=00，Mark Word 指向栈帧 Lock Record）
  │ CAS 失败且自旋超限
  ▼
重量级锁（lock=10，Mark Word 指向 ObjectMonitor）
```

**只升不降**：降级需要额外的 safepoint 与栈帧遍历，收益不确定，HotSpot 直接不做。

---

## 3. 完整推导：三个数字化细节

### 3.1 Mark Word 位布局为什么是 25/31/1/4/1/2

```
无锁态 64 位分配：
  unused(25) + hashCode(31) + unused(1) + age(4) + biased_lock(1) + lock(2)
  25 + 31 + 1 + 4 + 1 + 2 = 64（恰好占满 64 位）
```

- `hashCode` 31 位：`Object.hashCode()` 返回 int（32 位），但锁标志要占 2 位，所以只能塞 31 位（符号位之外）
- `age` 4 位：最大 15，GC 默认阈值 `-XX:MaxTenuringThreshold=15`，4 位刚好
- `lock` 2 位：01/00/10/11 四种组合，其中 01 由 `biased_lock` 再细分「无锁/偏向锁」
- 剩下的 1 位是对齐填充（保证字段边界）

### 3.2 偏向锁的批量优化：20 与 40

每次偏向撤销都要 safepoint，单个对象反复撤销会拖垮整体。于是 HotSpot 以**类**为单位统计：

| 阈值 | 触发动作 | 效果 |
|---|---|---|
| 同一类的偏向撤销次数达到 **20** | **批量重偏向（bulk rebias）** | 把该类对象的 `epoch` +1，旧 epoch 的偏向全部失效但允许重新偏向 |
| 撤销次数达到 **40** | **批量撤销（bulk revoke）** | 该类**彻底禁止**偏向，之后创建的对象都从无锁开始 |

判定靠 Mark Word 里那 2 位 `epoch` 与类对象上记录的 `epoch` 比较：不一致 ⇒ 直接视为「可偏向但需要重新 CAS」。

### 3.3 自旋的耗时对比

```
无竞争偏向锁：0 次 CAS，约 1~2 纳秒（几次内存读）
轻量级锁：1 次 CAS，约 5~20 纳秒
自旋成功：自旋 N 次 CAS（默认几十次，约 100 纳秒 ~ 微秒）
重量级锁（有竞争）：futex 系统调用 + 挂起/唤醒，约 10 ~ 100 微秒
```

**换算**：如果临界区只有几十条指令（约 10 纳秒），走重量级锁的唤醒成本是它的**上千倍**。所以「自旋」的意义是在「短临界区」和「阻塞」之间插一层缓冲。

---

## 4. 极简模型：三个线程先后访问同一个锁对象

用一个 `new Object()` 当锁，线程 t1、t2、t3 依次访问：

| 时刻 | 动作 | Mark Word 状态 | `lock` 位 | 说明 |
|---|---|---|---|---|
| 初始 | 对象刚创建 | 无锁（hash=0, age=0） | `01` | biased_lock=0 |
| t1 第一次进入 | CAS 写入 t1 的 ID | 偏向 t1 | `01` | 1 次 CAS |
| t1 第二次进入（重入） | 比较 ThreadID == t1 | 偏向 t1 | `01` | **0 次 CAS** |
| t2 尝试进入 | 发现偏向的是 t1 → 撤销 | 撤销需 safepoint，变为无锁/轻量级 | `00` 或 `01` | 代价最大的一步 |
| t2 拿到轻量级锁 | CAS 指向 t2 栈帧的 Lock Record | 指向 t2 的 Lock Record | `00` | t1 若还持有则自旋 |
| t3 也来抢 | CAS 失败，自旋 | 仍指向 t2 | `00` | 自旋中 |
| 自旋超限 | 膨胀 | 指向 ObjectMonitor | `10` | t3 进 `_cxq` 阻塞 |
| t2 释放 | `exit`：`_recursions--`，唤醒 t3 | 仍指向 ObjectMonitor | `10` | 不降级 |
| t3 被唤醒 | 重新 CAS 抢 `_owner` | 指向 ObjectMonitor | `10` | 非公平，可能被新来的抢先 |

**这张表把「为什么偏向锁省钱、撤销为什么贵、非公平从哪来」全串起来了。**

---

## 5. 为什么这样设计：四个被否决的方案

### 5.1 方案一：所有锁都用重量级锁（直接交给操作系统）

- 优点：实现最简单，语义最清晰
- 否决原因：无竞争时也要系统调用，而现实中绝大多数 `synchronized` 是无竞争或极短竞争的。用内核锁做「本来没人抢」的场景，性能损失数十到上百纳秒每次，且高并发下线程挂起/唤醒会让 CPU 频繁切换。

### 5.2 方案二：所有锁都用自旋（不阻塞）

- 优点：没有内核态切换，短临界区最快
- 否决原因：临界区长（比如里面做 IO、等锁）时，自旋会**空转烧 CPU**。8 核机器上 8 个线程同时自旋，CPU 直接 100% 却什么也没干。所以必须「先自旋，超限再阻塞」。

### 5.3 方案三：只有偏向锁，撤销也保留偏向（不升级）

- 优点：一旦偏向成功，后续永远零 CAS
- 否决原因：偏向只适合「单线程」；两个线程交替访问时，如果撤销后又重新偏向另一个线程，会在两个线程之间反复撤销/偏向，每次都要 safepoint，比轻量级锁还慢。所以设计成「撤销后升级到轻量级」，而不是「撤销后重新偏向」——重偏向只作为批量优化存在。

### 5.4 方案四：干脆废弃 `synchronized`，全部改用 `ReentrantLock`

- 优点：`ReentrantLock` 有公平锁、可中断、可超时、多个 `Condition`
- 否决原因：`synchronized` 是语法级、异常安全（自动释放）、JIT 可做锁消除/锁粗化，而且**无竞争时比 `ReentrantLock` 更快**（偏向锁时代）或至少持平。`ReentrantLock` 是 AQS 实现，每次加锁都要 CAS `state`，且必须手动 `finally unlock`，忘写就死锁。所以工程取舍是：**默认 `synchronized`，需要高级能力才用 `ReentrantLock`**。

> 补充：JDK 15 之后偏向锁默认关闭，`synchronized` 与 `ReentrantLock` 的性能差距进一步缩小，这个取舍仍然成立——语法简单、自动释放的价值不依赖于偏向锁。

---

## 6. 关键参数为什么是这个值

| 参数 | 值 | 为什么 |
|---|---|---|
| 对象头 Mark Word | 8 字节（64 位 JVM） | 与指针宽度对齐，便于原子读写；32 位 JVM 是 4 字节 |
| `lock` 标志 | 2 位 | 需要区分 4 类：01（普通/偏向）、00（轻量级）、10（重量级）、11（GC） |
| 偏向延迟 `-XX:BiasedLockingStartupDelay` | 4000 ms（默认，旧版） | 启动时大量类初始化会导致撤销，延迟开启避免启动抖动 |
| 批量重偏向阈值 | 20 | 经验值：少于 20 次撤销，逐个撤销的成本可接受 |
| 批量撤销阈值 | 40 | 达到两倍阈值说明该类确实存在多线程竞争，彻底禁用偏向 |
| 自适应自旋 | 由上次成功率决定 | 固定自旋次数在不同硬件上表现差异大，自适应能自动适配 |

---

## 7. 版本演进

| 版本 | 变化 |
|---|---|
| JDK 1.2 | `synchronized` 一律重量级锁（基于 `ObjectMonitor`） |
| JDK 1.6 | 引入偏向锁、轻量级锁、自适应自旋、锁消除、锁粗化（JEP 早期优化），性能大幅提升 |
| JDK 1.7 / 1.8 | 偏向锁默认开启；偏向延迟默认 4 秒 |
| JDK 15 | JEP 374：**默认禁用偏向锁**（`-XX:+UseBiasedLocking` 不再是默认值），原因：偏向锁的撤销逻辑复杂、维护成本高、现代应用里多线程场景多，收益下降 |
| JDK 18+ | 偏向锁相关选项被标记为废弃/逐步移除；默认已经没有偏向锁 |
| Java 21 | `synchronized` 仍走「无锁 → 轻量级 → 重量级」的路径；虚拟线程下 `synchronized` 会**钉住（pin）载体线程**，官方建议在虚拟线程场景优先用 `ReentrantLock` |

**版本差异的面试表述**：JDK 8 里问「偏向锁」是必答项；Java 21 里问偏向锁，要补一句「JDK 15 起默认关闭，但它是理解锁升级的起点，且仍是高频原理题」。

---

## 8. 亲手验证

### 8.1 看字节码

```java
public class SyncDemo {
    private final Object lock = new Object();
    private int count;
    public void block() { synchronized (lock) { count++; } }
    public synchronized void method() { count++; }
    public static synchronized void staticMethod() { }
}
```

```bash
javac SyncDemo.java
javap -c -p SyncDemo
javap -v SyncDemo | findstr ACC_SYNCHRONIZED
```

预期输出（节选）：

```
public void block();
     6: monitorenter
    18: monitorexit
    24: monitorexit
  Exception table:
     from    to  target type
         7    19    22   any

  flags: (0x0021) ACC_PUBLIC, ACC_SYNCHRONIZED
  flags: (0x0029) ACC_PUBLIC, ACC_STATIC, ACC_SYNCHRONIZED
```

**观察点**：`block()` 有 1 条 `monitorenter` + 2 条 `monitorexit`（正常 + 异常）；`method()` 没有指令，只有 `ACC_SYNCHRONIZED` 标志。

### 8.2 竞态 vs 加锁

```java
public class RaceDemo {
    static int unsafe = 0;
    static int safe = 0;
    static final Object LOCK = new Object();

    public static void main(String[] args) throws Exception {
        Runnable unsafeTask = () -> { for (int i = 0; i < 100_000; i++) unsafe++; };
        Runnable safeTask = () -> {
            for (int i = 0; i < 100_000; i++) synchronized (LOCK) { safe++; }
        };
        Thread a = new Thread(unsafeTask), b = new Thread(unsafeTask);
        a.start(); b.start(); a.join(); b.join();
        Thread c = new Thread(safeTask), d = new Thread(safeTask);
        c.start(); d.start(); c.join(); d.join();
        System.out.println("无锁结果 = " + unsafe + "（通常 < 200000）");
        System.out.println("加锁结果 = " + safe + "（一定是 200000）");
    }
}
```

预期输出：

```
无锁结果 = 137842（每次不同，但小于 200000）
加锁结果 = 200000
```

**关键点**：无锁时每次结果不同但一定小于 20 万（丢失更新），加锁后稳定 20 万。这也是「`i++` 不是原子操作」的最小复现。

### 8.3 可重入与 wait 必须持锁

```java
public class ReentrantDemo {
    public static void main(String[] args) throws Exception {
        Object lock = new Object();
        synchronized (lock) {
            synchronized (lock) {                  // 重入：同一线程再次进入
                System.out.println("重入成功");
            }
        }
        try {
            lock.wait();                            // 不持锁调用
        } catch (IllegalMonitorStateException e) {
            System.out.println("不持锁 wait -> IllegalMonitorStateException");
        }
    }
}
```

预期输出：`重入成功`，随后抛出 `IllegalMonitorStateException`（不持锁调用 `wait()`）。

---

## 9. 常见误区

| 错误说法 | 正确说法 |
|---|---|
| 「锁对象里有一个锁字段」 | 锁状态在**对象头 Mark Word**，不是对象字段 |
| 「`synchronized` 一上来就是重量级锁」 | 无竞争走偏向，短竞争走轻量级，才到重量级 |
| 「锁可以降级」 | 只升不降；偏向撤销是「恢复无锁」，不是降级 |
| 「轻量级锁 CAS 失败就直接阻塞」 | 先自适应自旋，超限才膨胀成重量级 |
| 「`notify()` 会释放锁并把锁交给等待线程」 | 只是把线程从 `_WaitSet` 移到 `_EntryList`，锁要等同步块结束才释放 |
| 「静态方法锁的是 `this`」 | 锁的是 `Class` 对象，实例锁与类锁互不进互斥 |
| 「偏向锁一定更快」 | 有竞争时撤销要 safepoint，反复撤销反而更慢；JDK 15 起默认关闭 |
| 「`synchronized` 在虚拟线程里没区别」 | 虚拟线程里 `synchronized` 会 pin 载体线程，建议改用 `ReentrantLock` |

---

## 10. 连续追问 Q&A

### Q1：为什么同步代码块有两条 `monitorexit`？

一条在正常路径末尾，另一条挂在**异常表**的 handler 上：偏移 7~19 内任何异常都会跳到 22，先 `monitorexit` 再 `athrow`。这样保证抛异常时也能释放监视器，否则会死锁。这也是 Java 编译器保证「`synchronized` 等价于 `try-finally` 加锁」的实现方式。

### Q2：Mark Word 为什么要复用而不是独立字段？

因为对象头空间有限。一个 Java 对象至少要 16 字节（对象头 12 + 对齐 4），如果每加一种能力都加字段，小对象的内存开销就崩了。复用的前提是「同一时刻只有一种状态」，所以用 `lock` 2 位当判别位，不同值对应不同的解释方式。

### Q3：偏向锁的「批量重偏向」和「批量撤销」有什么区别？

重偏向（20 次）是「把这一批对象的 `epoch` 加 1」，旧 epoch 的偏向失效但允许重新偏向新线程；撤销（40 次）是「这个类以后禁止偏向」，新对象直接按无锁创建。前者是给「多个线程交替访问不同对象」的场景留活路，后者是承认「这个类就是多线程竞争」。

### Q4：轻量级锁的 Lock Record 为什么放在栈上？

因为栈帧是**线程私有**的，不需要同步就能访问，而且随方法结束自动回收，不用 GC 管理。对象头只要存一个指针指过去，CAS 就完成了「认领」语义。如果把锁记录放堆上，就要考虑分配和回收成本。

### Q5：`ObjectMonitor` 的 `_cxq` 和 `_EntryList` 有什么区别？

`_cxq` 是「刚竞争失败、还没被正式排队」的线程（用 CAS 头插，LIFO），`_EntryList` 是「被唤醒后等待重新抢锁」的线程。持有者 `exit` 时会把 `_cxq` 批量转到 `_EntryList`，再从中唤醒。分成两个队列是为了减少临界区里的操作：入 `_cxq` 很快（无锁 CAS），排队与唤醒交给持有者线程处理。

### Q6：为什么 `synchronized` 是非公平的？

`ObjectMonitor::enter` 第一步就是 `CAS(_owner, null, self)`，新来的线程可以直接抢；被唤醒的线程也要重新参与竞争，不保证先到先得。这样做的收益是减少唤醒后的空转、提高吞吐；代价是可能饥饿。JVM 没有提供公平版开关。

### Q7：偏向锁为什么必须等到 safepoint 才能撤销？

撤销要修改对象头，而且如果对象正被某个线程持有偏向，还要**遍历该线程的栈帧**去修正锁记录——这些都要求其他线程处于「可控的静止状态」，也就是 safepoint。这也是偏向撤销比普通 CAS 慢几个数量级的原因。

### Q8：自旋次数是固定的吗？

不是。HotSpot 用「自适应自旋」：上次同一个锁自旋成功，这次就多转几圈；上次失败，这次就少转或不转。固定自旋在不同 CPU 上表现差异太大（缓存的代价、核数都不同），自适应让 JVM 自己学习。

### Q9：重入是怎么实现的？为什么 `_recursions` 要单独记？

轻量级锁靠「每次重入压一个新 Lock Record，`_displaced_header` 置 null」，解锁时弹一个；重量级锁靠 `ObjectMonitor._recursions++`，`exit` 时 `--`，归零才真正释放。记录重入次数是 `synchronized` 可重入语义的物理基础。

### Q10：既然偏向锁默认关了，面试还问它干什么？

因为偏向锁是理解「锁为什么能分级」「为什么撤销贵」「为什么有 epoch」的最好入口，而且 JDK 8 项目仍大量存在。答问题时可以这么说：机制要讲清，再补一句「JDK 15 起默认禁用（JEP 374），现在实际路径是无锁 → 轻量级 → 重量级」。

### Q11：`synchronized` 和 `ReentrantLock` 怎么选？

默认 `synchronized`：语法简单、异常自动释放、JIT 可做锁消除/粗化。需要以下能力时用 `ReentrantLock`：公平锁、`tryLock(timeout)`、可中断等待、多个 `Condition`、跨方法手动控制加解锁。另外虚拟线程场景官方建议优先 `ReentrantLock`，避免 pin 载体线程。

---

## 11. 一张图总结

```
synchronized(obj)
   │
   ├─ 字节码：monitorenter / monitorexit×2（异常表兜底）
   │
   └─ 对象头 Mark Word（8 字节，复用）
        ├─ lock=01, biased_lock=0  → 无锁（存 hashCode/age）
        │      │ 第一次进入，CAS 写 ThreadID
        │      ▼
        ├─ lock=01, biased_lock=1  → 偏向锁（存 ThreadID/epoch）
        │      │ 第二个线程来抢 → safepoint 撤销（20/40 批量优化）
        │      ▼
        ├─ lock=00                 → 轻量级锁（指向栈帧 Lock Record）
        │      │ CAS 失败 + 自旋超限
        │      ▼
        ├─ lock=10                 → 重量级锁（指向 ObjectMonitor）
        │            ├─ _owner / _recursions
        │            ├─ _cxq       （刚竞争失败，LIFO）
        │            ├─ _EntryList （等锁）
        │            └─ _WaitSet   （wait() 的线程）
        └─ lock=11                 → GC 标记（与锁无关）
```

---

## 12. 一句话复盘

> `synchronized` 把锁状态编码进对象头的 Mark Word：无竞争时用一次 CAS 写下线程 ID 成为偏向锁，出现竞争时撤销并升级为「栈帧 Lock Record + CAS + 自旋」的轻量级锁，自旋失败再膨胀成 `ObjectMonitor`（三个队列 + 操作系统阻塞）；只升不降，偏向锁因撤销太贵在 JDK 15 被默认关闭，但它的分级思想仍是理解 JVM 锁的入口。

---

## 13. 自测题（先自己答，再看答案）

**1. 同步代码块的字节码为什么是 1 个 `monitorenter` + 2 个 `monitorexit`？**

答案：一条正常路径释放，另一条挂在异常表上，保证抛异常也能释放监视器，避免死锁。编译器把 `synchronized` 翻译成了带 finally 语义的加解锁。

**2. 一个对象调用过 `hashCode()` 后，还能进入偏向锁吗？**

答案：不能。偏向态需要 54 位存 ThreadID，`hashCode` 需要 31 位，两者在同一个 Mark Word 里冲突。调用 `hashCode()` 会写入 hash 并导致对象退出偏向态。

**3. 偏向锁撤销为什么要 safepoint？批量优化阈值是多少？**

答案：撤销要改对象头并遍历持有者栈帧，必须在所有线程静止（safepoint）时做。同一类撤销 20 次触发批量重偏向（epoch+1），40 次触发批量撤销（该类禁止偏向）。

**4. 轻量级锁加锁时 CAS 的是哪块内存？**

答案：CAS 对象的 Mark Word，把它从「原始值（已备份到 Lock Record 的 `_displaced_header`）」改成「指向当前线程栈帧中 Lock Record 的指针」，同时 lock 位改成 00。

**5. 为什么 `notify()` 之后线程不会立刻执行？**

答案：`notify` 只把线程从 `_WaitSet` 移到 `_EntryList`，并不释放锁，也不交接锁。被移出的线程要等当前线程退出同步块（`exit` 释放 `_owner`）后重新竞争锁，抢到才从 `wait()` 返回。

**6. JDK 15 为什么默认禁用偏向锁？**

答案：JEP 374 给出的理由：偏向锁的撤销逻辑复杂、与其他同步机制的交互维护成本高；现代应用多线程场景增多，偏向锁的收益下降；禁用后能简化代码并减少 safepoint 相关的性能抖动。

---

## 14. 关联文件

- 深一层（追问树 + 源码细节）：[synchronized 与锁升级](../../10-deep-dive/java/09-synchronized与锁升级.md)
- 同层精讲：[线程池执行流程](07-线程池执行流程.md)｜[volatile 与内存屏障](09-volatile与内存屏障.md)
- 相关精讲：[Spring 事务失效](../spring/01-Spring事务失效.md)（事务方法与锁的边界）
- 返回：[精讲索引](../00-索引.md)
