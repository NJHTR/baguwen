# volatile 到底在 CPU 上做了什么？

> 精讲层级：从「零基础能看懂」到「源码级」，每个名词都拆开
> 阅读时间：约 35 分钟
> 配套速查：[volatile、CAS 与 AQS（深度追问）](../../10-deep-dive/java/10-volatile-CAS-AQS.md)
> 返回：[精讲索引](../00-索引.md)

---

## 0. 一句话先讲明白

`volatile` 是 Java 里**最轻量的同步手段**，它只保证两件事：

1. **可见性**：一个线程写了 `volatile` 变量，其他线程立刻能读到最新值
2. **有序性**：禁止编译器/CPU 把 `volatile` 读写和其他指令随意重排

它**不保证原子性**——`volatile int i; i++` 照样丢更新。

实现方式不是锁，而是**内存屏障（memory barrier）**：JIT 在 `volatile` 读写的两边插入特定的 CPU 指令，强制刷出写缓冲、禁止重排、并让其他 CPU 核心的缓存行失效。x86 上你甚至能看到一条 `lock addl $0,(%rsp)` 的汇编指令，这就是可见性的物理落点。

---

## 1. 痛点背景：两个真实会出事故的现象

### 1.1 现象一：线程看不到修改

```java
public class VisibilityBug {
    static boolean stop = false;                  // 没有 volatile
    public static void main(String[] args) throws Exception {
        new Thread(() -> {
            while (!stop) { }                     // 读 stop（可能被 JIT 提升成寄存器读）
            System.out.println("退出了");
        }).start();
        Thread.sleep(100);
        stop = true;
        System.out.println("已置 stop = true");
    }
}
```

这段代码在有些 JVM/CPU 上会**永远不打印「退出了」**：工作线程把 `stop` 读进寄存器后，循环里不再回主内存读，主线程的修改对它不可见。

### 1.2 现象二：重排序导致拿到「半成品对象」

```java
public class Singleton {
    private static Singleton instance;             // 没有 volatile
    public static Singleton get() {
        if (instance == null) {
            synchronized (Singleton.class) {
                if (instance == null) instance = new Singleton();   // 三步可能被重排
            }
        }
        return instance;
    }
}
```

`new Singleton()` 在字节码层是三步：

```
1. new           # 分配内存（此时对象字段都是默认值 0/null）
2. invokespecial # 调用构造器初始化
3. putstatic     # 把引用赋给 instance
```

`2` 和 `3` 之间没有数据依赖，**CPU/编译器可以把 3 提到 2 前面**。于是另一个线程可能在第一次检查时看到 `instance != null`，拿到的却是一个**字段还没初始化**的对象——后续使用直接 NPE 或脏数据。

### 1.3 为什么硬件层会这样

| 硬件现实 | 具体数字 | 后果 |
|---|---|---|
| CPU 有 L1/L2/L3 缓存，写操作先落在 **store buffer（写缓冲）** | 写 L1 约 4 个周期，写主存约 100+ 周期 | 别的核暂时看不到这次写 |
| 编译器/JIT 会重排指令以填满流水线 | 乱序执行窗口可达数百条指令 | 逻辑顺序被打破 |
| 缓存以 **缓存行（cache line）** 为单位同步 | x86 通常 64 字节 | 改一个变量会牵动整行 |

Java 不能直接控制这些硬件细节，所以定义了**Java 内存模型（JMM，Java Memory Model）**：一套规范，告诉你能依赖什么、不能依赖什么。`volatile` 就是 JMM 暴露给程序员的「最小同步原语」。

---

## 2. 逐步拆解：JMM、happens-before、内存屏障

### 2.1 JMM 的主内存与工作内存

| 名词 | 是什么 | 对应硬件 |
|---|---|---|
| 主内存（main memory） | 所有线程共享的变量所在的地方 | 堆内存 + 最终落到物理内存 |
| 工作内存（working memory） | 每个线程私有的变量副本 | CPU 寄存器 + L1/L2 缓存 + store buffer |
| 主内存与工作内存的 8 种操作 | `read/load/use/assign/store/write/lock/unlock` | JMM 的抽象原语，用于描述交互 |

**关键理解**：线程不能直接读写主内存，必须先 `read`（从主内存读到工作内存）→ `load`（存入副本变量）→ `use`（传给执行引擎）；写则是 `assign`（改副本）→ `store`（写回工作内存）→ `write`（写回主内存）。这中间任何一步没同步，就会产生可见性问题。

### 2.2 happens-before：JMM 的核心规则

**happens-before（先行发生）不是「时间上先发生」**，而是「前一个操作的**可见性影响**对后一个操作成立」。A hb B 意味着：A 写过的变量，B 一定能看到 A 写后的值。

八条规则（必须逐条能举例）：

| # | 规则 | 一个例子 |
|---|---|---|
| 1 | 程序顺序：同线程内，前面的操作 hb 后面的操作 | 线程内 `a=1; b=a;` 能读到 1 |
| 2 | 监视器锁：对同一把锁的 `unlock` hb 后续的 `lock` | 线程 A 在 `synchronized` 里写 `x=1`，线程 B 随后进同一个同步块能读到 1 |
| 3 | volatile：对同一变量的 `volatile 写` hb 后续的 `volatile 读` | 生产者写 `flag=true`，消费者读到 true 后能看到之前的所有写 |
| 4 | 线程启动：`Thread.start()` hb 该线程内的任何操作 | 主线程 `x=1` 后 `start()`，子线程能读到 1 |
| 5 | 线程终止：线程内所有操作 hb 其他线程从 `join()` 返回 | `join()` 之后能拿到子线程的结果 |
| 6 | 中断：`interrupt()` hb 被中断线程检测到中断 | `isInterrupted()` 返回 true 前，中断设置已可见 |
| 7 | 对象终结：构造完成 hb `finalize()` 开始 | `finalize` 能看到构造后的字段 |
| 8 | 传递性：A hb B、B hb C ⇒ A hb C | `volatile` 写 + 程序顺序，把可见性传递出去 |

**规则 8 是组合技**：`x=1; volatileFlag=true;` 之后别的线程读到 `volatileFlag`，通过规则 3 + 规则 8，也能看到 `x=1`。这就是「volatile 能把之前所有写都刷出去」的原理。

### 2.3 四种内存屏障

| 屏障 | 作用 | 一句话记忆 |
|---|---|---|
| `LoadLoad` | 前面的读先于后面的读 | 读读不重排 |
| `StoreStore` | 前面的写先于后面的写 | 写写不重排 |
| `LoadStore` | 前面的读先于后面的写 | 读写不重排 |
| `StoreLoad` | 前面的写先于后面的读 | 写读不重排（最贵） |

**volatile 的插入位置**（JSR-133 cookbook 的经典结论）：

```
volatile 写：  StoreStore 屏障 → 写 volatile 变量 → StoreLoad 屏障
volatile 读：  读 volatile 变量 → LoadLoad 屏障 → LoadStore 屏障
```

数字化解释为什么 `StoreLoad` 最贵：它要求**把 store buffer 里的写全部刷到缓存/主存，并等待完成**，x86 上通常用 `mfence` 或 `lock` 前缀实现，代价约 20~100 个周期；而 L1 命中只要 4 个周期左右，一次普通加法不到 1 个周期。

### 2.4 volatile 在字节码和汇编层

- 字段访问标志：`ACC_VOLATILE`（`javap -v` 能看到）
- JIT 编译后：x86 上 volatile 写常见 `lock addl $0,(%rsp)`——**往栈顶加 0**，看起来无意义，但 `lock` 前缀会（a）锁住该缓存行保证原子（b）作为内存屏障清空 store buffer（c）使其他核的对应缓存行失效
- 注意：**`volatile` 的同步不是解释器做的**，而是 JIT 在生成机器码时按 JMM 插入屏障

---

## 3. 完整推导：三个经典场景

### 3.1 推导一：DCL 为什么必须加 volatile

把 `new` 的三步写成内存操作：

```
t1 线程：                          t2 线程：
allocate(obj)                      if (instance != null)   ← 可能在这里读到非 null
init(obj.a = 1)                    return instance;        ← 拿到 a = 0 的半成品
instance = obj
```

如果 `instance = obj` 被重排到 `init` 之前，t2 就会拿到「分配了但没初始化」的对象。加上 `volatile` 后，`instance = obj` 这个 volatile 写之前会插入 `StoreStore` 屏障，保证前面的 `init` 写完才执行赋值——**看到非 null 就意味着初始化完成**。

```java
private static volatile Singleton instance;   // volatile 修的就是这一句
```

### 3.2 推导二：`i++` 为什么不是原子的

`volatile int i; i++` 的字节码（实例字段）：

```
aload_0
dup
getfield   i          // 1. 读
iconst_1
iadd                  // 2. 加
putfield   i          // 3. 写
```

三步之间都可能被其他线程插入。两个线程各执行一次，最坏结果 `i = 1`（而不是 2）。**volatile 只保证第 1 步读到最新值、第 3 步立刻可见，不保证三步整体原子。**

正确做法：`synchronized`、`AtomicInteger.incrementAndGet()`、或 `LongAdder`。

### 3.3 推导三：伪共享的量化损失

**伪共享（false sharing）**：两个线程分别修改**同一个缓存行里的不同变量**。虽然逻辑上无关，但缓存一致性协议（MESI）以缓存行为单位失效，导致每次写都要让对方的缓存行失效。

```java
class Pair {
    volatile long a;   // 和 b 在同一个 64 字节缓存行里
    volatile long b;
}
```

```
缓存行大小：64 字节
long 占 8 字节 → Pair 的 a、b 极可能落在同一行
线程 1 写 a：让线程 2 的缓存行失效
线程 2 写 b：让线程 1 的缓存行失效
→ 每次写都要跨核同步，实测比无竞争慢 3~10 倍（视 CPU 而定）
```

解法：缓存行填充（在变量间塞 7 个无用 `long`，凑满 64 字节）或 `@sun.misc.Contended` 注解（JDK 8+，需要 `-XX:-RestrictContended` 才对手写类生效）。JDK 内部的 `LongAdder.Cell`、`Thread` 的某些字段都用了这招。

---

## 4. 极简模型：两个线程、一个 volatile 变量

线程 A 写、线程 B 读，指令序列：

```
线程 A：                       线程 B：
x = 1;                         if (flag) {
flag = true;  // volatile            int y = x;   // y 一定等于 1 吗？
                               }
```

不加 `volatile` 时，编译器/CPU 允许的组合：

| 组合 | A 的实际执行顺序 | B 看到的 x | 说明 |
|---|---|---|---|
| 1 | `x=1; flag=true` | 1 | 正常 |
| 2 | `flag=true; x=1` | 0 或 1 | **重排**，B 可能读到旧 x |
| 3 | 写进 store buffer 未刷出 | 0 | B 看不到 flag |
| 4 | 循环里把 flag 提到寄存器 | 永远不结束 | 可见性丢失 |

加上 `volatile` 后：

- `flag = true` 前有 `StoreStore`：保证 `x=1` 已经写出去，不会重排到 `flag` 之后
- `flag = true` 后有 `StoreLoad`：保证 flag 的值立刻对其他核可见
- B 读 `flag` 后插 `LoadLoad/LoadStore`：保证后面的 `x` 读不会被提前

于是「B 看到 flag 为 true」⇒「B 一定能看到 x = 1」。**这就是 volatile 用一条屏障换来的一条 happens-before 边。**

---

## 5. 为什么这样设计：四个被否决的方案

### 5.1 方案一：所有共享变量都用 `synchronized`

- 优点：可见性、有序性、原子性一次全解决
- 否决原因：`synchronized` 是互斥锁，会把并发读变成串行读。而现实中大量场景是「一个写、多个读」的**状态标志**（如 `running`、`initialized`、配置开关），用锁代价过高。volatile 的读几乎和普通读一样快。

### 5.2 方案二：用 `final` 代替 `volatile`

- 优点：`final` 也有特殊的内存语义（构造完成后，其他线程一定能看到正确初始化的 final 字段）
- 否决原因：`final` 只能赋值一次，无法表达「运行期修改的状态」。而且 `final` 保证的是「构造安全发布」，不解决运行中改值的问题。

### 5.3 方案三：全部用 `AtomicInteger` 等原子类

- 优点：既有可见性又有原子性
- 否决原因：很多场景**不需要原子性**（比如「是否关闭」的布尔开关），用 CAS 会引入额外的同步开销（`lock cmpxchg` 比普通写贵得多），而且原子类只适合单变量；多字段一致性仍要锁。

### 5.4 方案四：假设「硬件是顺序一致的」，不定义 JMM

- 优点：编程简单，不用考虑重排
- 否决原因：x86 是 TSO（Total Store Order，只允许 store-load 重排），ARM/Power 是弱内存模型（允许更多重排）。如果不定义 JMM，同一份 Java 代码在不同 CPU 上行为不同——这是 Java「一次编写到处运行」的底线。JMM 的价值就是**把硬件差异关进笼子，给程序员统一的抽象**。

---

## 6. 关键参数与数值

| 参数/数值 | 值 | 为什么 |
|---|---|---|
| 缓存行大小 | 64 字节（x86 常见） | 伪共享的粒度；填充要凑满 64 或 128 |
| `StoreLoad` 屏障成本 | 约 20~100 周期 | 要刷 store buffer，最贵 |
| L1 命中 | 约 4 周期 | 对比基准 |
| 主存访问 | 约 100+ 周期 | 可见性追平缓存的代价 |
| `@Contended` 默认 padding | 128 字节（JDK 8+） | 同时覆盖 64 和 128 字节缓存行的 CPU |
| `-XX:-RestrictContended` | 默认受限 | 防止用户滥用 `@Contended` 浪费内存 |
| volatile 读开销 | 约等于普通读 + 1 条屏障 | 读侧基本免费，写侧才有明显代价 |

**为什么 x86 上只需要 `StoreLoad` 屏障**：x86 的 TSO 模型只允许「写后读」重排，写写、读读、读写都不重排，所以 JMM 要求的四种屏障在 x86 上大部分退化成空操作，只有 volatile 写后的 `StoreLoad` 需要真指令（`lock addl $0,(%rsp)` 或者 `mfence`）。这也是「同一段 Java 代码在 x86 上很少出问题，在 ARM 上翻车」的原因。

---

## 7. 版本演进

| 版本 | 变化 |
|---|---|
| JDK 1.4 及以前 | JMM 存在严重缺陷：`volatile` 的语义不完整（允许某些重排），`final` 字段的可见性也没有保证 |
| JDK 5 | **JSR-133 修订 JMM**：明确 happens-before 八条规则、修复 volatile 语义（volatile 写 hb 后面所有读，包括普通变量的读）、修复 final 字段语义 |
| JDK 8 | 引入 `@sun.misc.Contended`（内部 API），`LongAdder` 用它做 Cell 填充 |
| JDK 9 | `Unsafe.compareAndSwapInt` 逐步被 `VarHandle` 替代（`java.lang.invoke.VarHandle` 提供 acquire/release 语义） |
| JDK 17 / 21 | JMM 规则未变；`VarHandle` 成为标准；虚拟线程不改变 volatile 语义（虚拟线程之间同样遵守 JMM） |

**面试表述**：JDK 5 是 volatile 语义的分水岭，JSR-133 之前「volatile 不保证与普通变量之间的重排」，之后才变成今天的语义。

---

## 8. 亲手验证

### 8.1 可见性：volatile 让线程退出

```java
public class VisibilityDemo {
    static volatile boolean stop = false;

    public static void main(String[] args) throws Exception {
        Thread t = new Thread(() -> {
            long n = 0;
            while (!stop) { n++; }
            System.out.println("线程退出，自旋了 " + n + " 次");
        });
        t.start();
        Thread.sleep(100);
        stop = true;
        t.join(1000);
        System.out.println("主线程结束");
    }
}
```

预期输出：

```
线程退出，自旋了 321463 次（数字每次不同）
主线程结束
```

把 `volatile` 去掉再跑，可能仍然能退出（JIT 优化程度不同），也可能一直不退出——**这正是可见性 bug 的可怕之处：它不是必现的**。

### 8.2 原子性：volatile 救不了 `i++`

```java
import java.util.concurrent.atomic.AtomicInteger;

public class AtomicDemo {
    static volatile int count = 0;
    static AtomicInteger atomic = new AtomicInteger();

    public static void main(String[] args) throws Exception {
        Runnable r = () -> {
            for (int i = 0; i < 100_000; i++) { count++; atomic.incrementAndGet(); }
        };
        Thread a = new Thread(r), b = new Thread(r);
        a.start(); b.start(); a.join(); b.join();
        System.out.println("volatile 结果 = " + count + "（通常 < 200000）");
        System.out.println("Atomic 结果   = " + atomic.get() + "（一定是 200000）");
    }
}
```

预期输出：

```
volatile 结果 = 143627（每次不同，小于 200000）
Atomic 结果   = 200000
```

### 8.3 伪共享：填充前后的耗时差

```java
public class FalseSharingDemo {
    static class Plain { volatile long a; volatile long b; }
    static class Padded { volatile long a; long p1,p2,p3,p4,p5,p6,p7; volatile long b; }

    public static void main(String[] args) throws Exception {
        System.out.println("plain  = " + cost(new Plain()));
        System.out.println("padded = " + cost(new Padded()));
    }
    static long cost(Object o) throws Exception {
        long n = 30_000_000L;
        long begin = System.nanoTime();
        Thread t1 = new Thread(() -> { for (long i = 0; i < n; i++) write(o, 0); });
        Thread t2 = new Thread(() -> { for (long i = 0; i < n; i++) write(o, 1); });
        t1.start(); t2.start(); t1.join(); t2.join();
        return (System.nanoTime() - begin) / 1_000_000;   // 毫秒
    }
    static void write(Object o, int idx) {
        if (o instanceof Plain p) { if (idx == 0) p.a++; else p.b++; }
        else { Padded p = (Padded) o; if (idx == 0) p.a++; else p.b++; }
    }
}
```

预期输出（数字随机器变化，但 padded 明显更小）：

```
plain  = 2100
padded = 410
```

**观察点**：同样两个线程各加 3000 万次，填充后把两个变量放进不同缓存行，耗时可能降到原来的 1/3 ~ 1/5。

---

## 9. 常见误区

| 错误说法 | 正确说法 |
|---|---|
| 「`volatile` 保证原子性」 | 只保证可见性 + 有序性；`i++` 照样丢更新 |
| 「`volatile` 是靠加锁实现的」 | 靠内存屏障/`lock` 前缀，不进内核、不阻塞线程 |
| 「happens-before 就是时间先后」 | 是**可见性保证**，不是时钟顺序；并发下时间先后无法定义 |
| 「x86 上 volatile 写必须用 `mfence`」 | 常用 `lock addl $0,(%rsp)`，效果等价且更便宜 |
| 「DCL 加了 `synchronized` 就够了」 | 不加 `volatile` 可能拿到半初始化对象 |
| 「`volatile` 数组的每个元素都是 volatile」 | `volatile int[] arr` 只保证**引用**可见，元素不是 volatile |
| 「用了 volatile 就不用管线程安全了」 | 只解决可见性/有序性，复合操作仍需锁或原子类 |
| 「伪共享只在高并发下才出现」 | 两个线程写同一缓存行就可能触发，哪怕变量逻辑无关 |

---

## 10. 连续追问 Q&A

### Q1：`volatile` 到底保证了哪几件事？

三件：① 可见性：写立刻对其他线程可见；② 有序性：volatile 读写不会被重排到屏障之外；③ 与普通变量的 happens-before：volatile 写之前的普通写，对后续读该 volatile 变量的线程可见。**不保证原子性**。

### Q2：`volatile` 的可见性在 CPU 层怎么实现？

写：`lock` 前缀指令使本地缓存行进入独占（Modified）状态，广播 invalidate 让其他核的缓存行变为 Invalid，同时清空 store buffer 充当屏障。其他核下次读该变量时缓存未命中，必须回主存或从该核缓存转发（cache-to-cache），于是拿到新值。

### Q3：为什么说 `StoreLoad` 屏障最贵？

因为它要求「前面所有 store 都刷出并等待完成，后面的 load 才能执行」，本质是把 CPU 的乱序执行窗口截断。x86 上用 `mfence` 或 `lock` 前缀实现，代价约 20~100 周期，而普通 L1 读只要 4 周期。

### Q4：happens-before 和「程序执行顺序」有什么区别？

执行顺序是「实际先执行哪条指令」，happens-before 是「哪个操作的结果对另一个操作可见」。JMM 允许实际执行顺序与代码顺序不同（重排），只要不破坏 happens-before 关系。所以可见性是**规范保证的语义**，不是物理时序。

### Q5：DCL 单例为什么必须加 `volatile`？不加会怎样？

`new` 的三步（分配→初始化→赋值）里，赋值的 `putstatic` 可能被重排到初始化之前。另一个线程在第一次检查时看到 `instance != null`，会拿到字段还没初始化的对象。`volatile` 在赋值前插 `StoreStore`，禁止这个重排。

### Q6：`volatile` 能替代 `synchronized` 吗？

不能。`volatile` 只适合「一个线程写、其他线程读」的状态标志/一次性发布；涉及「读-改-写」复合操作、多个变量的一致性、需要互斥的临界区，就必须用锁或原子类。简单判断：如果代码里有 `if (x) x = ...` 这种依赖当前值的更新，`volatile` 不够。

### Q7：`volatile` 和 `AtomicInteger` 什么关系？

`AtomicInteger` 内部的 `value` 字段本身就是 `volatile` 的，然后用 CAS 保证复合操作的原子性。所以 `AtomicInteger` = `volatile`（可见性）+ CAS（原子性）。`LongAdder` 则进一步用分段 Cell 降低 CAS 竞争。

### Q8：`volatile int[] arr` 和 `AtomicIntegerArray` 有什么区别？

`volatile int[] arr` 只让「数组引用」具有 volatile 语义（重新赋值 `arr = new int[10]` 可见），`arr[0]++` 完全不是原子的，也不是 volatile 的。`AtomicIntegerArray` 对每个元素用 `Unsafe` 的 volatile 语义 + CAS，元素级别安全。

### Q9：什么是伪共享？怎么解决？

多个线程修改**同一个缓存行**里的不同变量，缓存一致性协议以行为单位失效，导致互相「误伤」。解决：缓存行填充（补 7 个 long 凑 64 字节）、`@Contended` 注解、或把变量按线程分开（如 `LongAdder` 的 Cell）。

### Q10：`volatile` 写之后，之前的所有普通写都会对其他线程可见吗？

会。这就是 happens-before 的传递性：线程 A 内 `x = 1` 程序顺序先于 `volatileFlag = true`（规则 1），而 `volatileFlag` 写 hb 线程 B 的读（规则 3），由传递性（规则 8）得到 B 能看到 `x = 1`。这正是 DCL 能成立的原因。

### Q11：Java 21 的虚拟线程会改变 volatile 的语义吗？

不会。JMM 是语言级规范，虚拟线程之间、虚拟线程与平台线程之间同样遵守 happens-before。虚拟线程改变的是「线程如何调度、阻塞是否占平台线程」，不改变内存可见性规则。

---

## 11. 一张图总结

```
线程 A 写 volatile flag             线程 B 读 volatile flag
   │                                    │
   ├─ 普通写 x = 1                       ├─ 普通读 x
   │                                    │
   ├─ StoreStore 屏障（保证 x=1 先写出去） │
   ├─ 写 flag = true                     ├─ 读 flag == true
   ├─ StoreLoad 屏障（刷 store buffer）   ├─ LoadLoad 屏障
   │   └─ lock addl / mfence             ├─ LoadStore 屏障
   │   └─ 广播 invalidate，其他核缓存行失效 │
   ▼                                    ▼
         └───────── happens-before ─────┘
              B 一定能看到 x = 1

底层三件套：
  store buffer + 内存屏障 + MESI 缓存行失效
```

---

## 12. 一句话复盘

> `volatile` 不是锁，而是「用内存屏障把可见性和有序性钉死」的轻量原语：写前 `StoreStore`、写后 `StoreLoad`，读后 `LoadLoad` + `LoadStore`；底层靠 `lock` 前缀清 store buffer 并使其他核缓存行失效；它给出 happens-before 边，但不提供原子性，所以 `i++`、DCL 之外的复合操作仍然要锁或原子类。

---

## 13. 自测题（先自己答，再看答案）

**1. `volatile` 能保证 `i++` 的线程安全吗？为什么？**

答案：不能。`i++` 是「读-加-写」三步，`volatile` 只保证读到的值最新、写出的值立刻可见，不保证三步之间不被其他线程插入，所以仍会丢更新。

**2. DCL 单例为什么必须给 `instance` 加 `volatile`？**

答案：`new` 的「初始化」和「引用赋值」可能被重排，导致其他线程看到非 null 但未初始化完成的对象。`volatile` 在赋值前插入 `StoreStore` 屏障，禁止这个重排。

**3. happens-before 的八条规则里，哪一条让 volatile 能把之前的普通写也传播出去？**

答案：规则 3（volatile 写 hb 后续读）+ 规则 1（程序顺序）+ 规则 8（传递性）。`x=1` 程序顺序先于 `volatileFlag=true`，而 volatile 写 hb 读，传递得到 B 能看到 `x=1`。

**4. 为什么 x86 上 volatile 读几乎不要钱，写却要加指令？**

答案：x86 是 TSO 模型，读读/读写/写写都不重排，只有「写后读」需要屏障，所以 volatile 读侧的 `LoadLoad/LoadStore` 退化成空操作，只有 volatile 写后的 `StoreLoad` 需要 `lock addl` 或 `mfence`。

**5. 两个线程分别写同一对象的两个 volatile long 字段，为什么会变慢？怎么解决？**

答案：两个字段很可能在同一 64 字节缓存行里，每次写都要让对方缓存行失效（伪共享）。解决：缓存行填充到不同行，或用 `@Contended`（需 `-XX:-RestrictContended`）。

**6. `AtomicInteger` 为什么既有可见性又有原子性？**

答案：内部 `value` 字段是 `volatile`（可见性），`compareAndSet` 用 CPU 的 `lock cmpxchg` 指令做原子的读-比-写（原子性）。两者组合才构成完整的线程安全。

---

## 14. 关联文件

- 深一层（追问树 + 源码细节）：[volatile、CAS 与 AQS](../../10-deep-dive/java/10-volatile-CAS-AQS.md)
- 同层精讲：[线程池执行流程](07-线程池执行流程.md)｜[synchronized 锁升级](08-synchronized锁升级.md)
- 相关精讲：[Spring 事务失效](../spring/01-Spring事务失效.md)（ThreadLocal 与可见性）
- 返回：[精讲索引](../00-索引.md)
