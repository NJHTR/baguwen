# ThreadLocal

> 面试权重：4/5　｜　追问深度：**L5（`ThreadLocalMap` 归属 / 弱引用 Entry / 探测式清理 / 哈希增量）**
> 一句话定位：不是「每个线程一个变量副本」，而是**每个 `Thread` 对象里挂着一个 `ThreadLocalMap`**，`ThreadLocal` 只是这个 map 的 key；所以数据跟着线程走，线程死数据才死。

[返回深度追问索引](../00-索引.md)

## L1 一句话答案（10 秒能说出口）

`Thread` 里有两个字段 `threadLocals`（`ThreadLocalMap`）和 `inheritableThreadLocals`；`ThreadLocal.get/set` 就是以自己为 key 去当前线程的这个 map 里读写。`Entry` 的 key 是**弱引用**（`ThreadLocal` 可被回收），value 是**强引用**（回收不了），所以线程池里线程常驻时必须 `remove()`，否则 value 泄漏且污染下一个任务。

## L2 原理层：数据挂在 Thread 上，ThreadLocal 只是 key

```
Thread
 ├── threadLocals            : ThreadLocalMap   ← 普通 ThreadLocal 存这里
 ├── inheritableThreadLocal  : ThreadLocalMap   ← InheritableThreadLocal 存这里
 └── ...
ThreadLocalMap
 └── table : Entry[]   （长度必须是 2^n）
      Entry extends WeakReference<ThreadLocal<?>>   // key = ThreadLocal（弱）
      └── Object value                               // value（强引用！）
```

```java
// 源码骨架（JDK 17，简化）
public void set(T value) {
    Thread t = Thread.currentThread();
    ThreadLocalMap map = getMap(t);              // t.threadLocals
    if (map != null) map.set(this, value);       // this 就是 key
    else createMap(t, value);                    // 懒加载
}
public T get() {
    ThreadLocalMap map = getMap(Thread.currentThread());
    if (map != null) { ThreadLocalMap.Entry e = map.getEntry(this); if (e != null) return (T) e.value; }
    return setInitialValue();
}
```

| 关注点 | 答案 |
|---|---|
| 数据存在哪 | 当前 `Thread` 的 `ThreadLocalMap.table` 里 |
| key 是什么 | `ThreadLocal` 实例本身（弱引用） |
| 为什么不需要加锁 | 只有一个线程会读写自己线程的 map（**线程封闭**） |
| 何时回收 | 线程结束 + map 不可达 ⇒ 整体被 GC；线程池线程不死 ⇒ 必须手动 `remove` |
| `initialValue` | 没 `set` 过时 `get` 会调用，写入 map |

## L3 底层层：弱引用 Entry / 开放寻址 / 探测式清理

### 3.1 为什么 key 用弱引用，value 却是强引用

`Entry` 继承 `WeakReference<ThreadLocal<?>>`，`referent` 就是 key。这样当外部再没有强引用指向某个 `ThreadLocal`（例如局部创建用完），GC 就能回收这个 key，Entry 变成 `key == null`。**但 value 是 `Entry` 的普通字段（强引用）**，key 被回收后 value 依然被「Thread → map → table[i] → value」这条链强引用住 ⇒ **泄漏**。所以弱引用只是「让 key 能被回收」，不能解决 value 泄漏；真正兜底是 `expungeStaleEntry` + 业务 `remove()`。

### 3.2 `threadLocalHashCode` 与开放寻址

```java
private final int threadLocalHashCode = nextHashCode();
private static final int HASH_INCREMENT = 0x61c88647;   // 黄金分割相关常数
private static int nextHashCode() { return nextHashCode.getAndAdd(HASH_INCREMENT); }
private static Entry getEntryAfterMiss(ThreadLocal<?> key, int i, Entry e) {
    Entry[] tab = table; int len = tab.length;
    while (e != null) {
        ThreadLocal<?> k = e.get();
        if (k == key) return e;
        if (k == null) expungeStaleEntry(i);     // 重点：探测式清理
        else i = nextIndex(i, len);              // 线性探测：i+1 & (len-1)
        e = tab[i];
    }
    return null;
}
```

- `0x61c88647 ≈ 2^32 × 0.382`（黄金分割的平方），配合长度为 2 的幂，`hash & (len-1)` 几乎不冲突——这是**斐波那契散列**
- 冲突用**开放寻址 + 线性探测**，不用链表：map 很小（通常个位数元素），链表指针反而浪费；`Entry` 本身就是 `WeakReference` 对象，再挂 `next` 更亏
- **探测式清理 `expungeStaleEntry(i)`**：从 `i` 往后扫，遇到 `key == null` 就把 value 置 null、并把「被探测链挡住的后续元素」重新 hash 搬回原位（rehash 修复），直到遇到空槽停止
- `cleanSomeSlots(n)`：启发式（log2 次扫描）少量清理；`set` 时 `size >= threshold`（2/3）先 `rehash()`，若仍无空位则**扩容 ×2 并全量 rehash**

### 3.3 为什么 `ThreadLocalMap` 定义在 `Thread` 里（而不是 `ThreadLocal` 里）

如果 map 放在 `ThreadLocal` 上（`ThreadLocal -> Map<Thread, Object>`），那么这个 `ThreadLocal`（常常是 `static`，活到进程结束）会**强引用所有线程及其数据**，线程死了也回收不了。放在 `Thread` 上则生命周期自然绑定线程：线程结束，map 随之不可达，整块回收——这是「把状态放对生命周期所有者身上」的经典设计。

### 3.4 线程池里为什么必须 `remove()`（两个独立后果）

| 后果 | 机制 |
|---|---|
| **内存泄漏** | 池线程不死 ⇒ `Thread → map → Entry → value` 一直可达，大对象（用户上下文、`SimpleDateFormat`）永不释放 |
| **数据污染** | 线程被复用，下一个任务 `get()` 到上一个任务残留的值 ⇒ 串号、越权（用户 A 的上下文给了 B） |

`remove()` 会真正清掉 Entry（`e.clear()` + `expungeStaleEntry`），是唯一可靠的解法；`finally` 里调用是标准姿势。Java 8 的 `ThreadLocal` 不能继承销毁，Spring 的 `RequestContextHolder`、MyBatis 的 `SqlSession`、`TransactionSynchronizationManager` 都靠手动/框架兜底清理。

### 3.5 `InheritableThreadLocal` 与 `TransmittableThreadLocal`

| | `InheritableThreadLocal` | `TransmittableThreadLocal`（阿里 TTL） |
|---|---|---|
| 传递时机 | **`new Thread()` 时**，`Thread` 构造器里 `inheritValues` 浅拷贝父线程 map | 每次**任务提交/执行**时，由装饰器捕获快照再回放 |
| 线程池 | 失效（线程复用，创建时已定，后续父线程改动传不进去） | 支持（`TtlRunnable` / `TtlCallable` / 线程池装饰） |
| 拷贝方式 | 引用复制（同一对象，非深拷贝） | 引用复制 + 快照，任务结束还原 |
| 适用 | 手动 `new Thread` 的场景 | 线程池 / `@Async` / 异步编排 |

## L4 追问树（面试官一路往下问，你能撑到第几层？）

> 规则：从上往下问。**第 1-3 层是应届生必备，第 4-6 层是拉开差距，第 7 层以后是"能答出来就是加分"。**

### 第 1 层｜`ThreadLocal` 原理？
**答**：每个 `Thread` 有一个 `ThreadLocalMap` 字段，`ThreadLocal` 自己只是 key；`get/set` 就是拿当前线程的 map 按 `this` 为 key 读写。所以不同线程天然隔离，不需要锁。

### 第 2 层｜数据到底存在哪？为什么说「不是每个线程一份副本」？
**答**：存在**线程对象自己**的 `threadLocals` 字段里（`ThreadLocalMap.table`）。不是 `ThreadLocal` 持有 N 份副本，而是每个线程持有自己的 map；`ThreadLocal` 只是一个所有线程共享的 key。

### 第 3 层｜`Entry` 为什么 key 弱引用、value 强引用？
**答**：key 弱引用是为了让没人引用的 `ThreadLocal` 能被回收，避免 ThreadLocal 对象本身泄漏；value 强引用是因为「线程还在用这个值」的语义——但这也正是泄漏根源：key 被回收后 Entry 变成 `(null, value)`，value 还被线程 map 强引用。

### 第 4 层｜`expungeStaleEntry` 做了什么？为什么要有「重新 rehash 搬移」？
**答**：从过期槽位 `i` 往后扫，把 `key == null` 的 Entry 的 value 置 null（断开强引用）；同时把「因为线性探测被挡在后面」的有效元素重新计算索引搬回原位，遇到空槽结束。不搬移的话，删除会在探测链中间留下空洞，后续 `get` 提前遇到 null 就查不到元素——开放寻址必须「删除后修复链」。

### 第 5 层｜`threadLocalHashCode` 为什么用 `0x61c88647`？
**答**：这是黄金分割相关常数（≈ 2^32×0.382），搭配容量为 2 的幂的 table，`hash & (len-1)` 能把槽位均匀打散（斐波那契散列），冲突概率极低。因为 map 容量通常很小（16 起），用链表不划算，均匀散布比链地址更省。

### 第 6 层｜线程池里不 `remove` 会怎样？有几种坏法？
**答**：两种：① **内存泄漏**——池线程不死，`Thread→map→value` 一直可达，大对象永不释放；② **数据污染**——线程复用，下一个任务读到上个任务的值，可能导致越权/串号。而且弱引用也救不了，因为 value 是强引用，必须 `expunge`/`remove` 才断链。

### 第 7 层｜`InheritableThreadLocal` 怎么把值传给子线程？为什么在线程池里失效？
**答**：`Thread` 构造器里调 `inheritValues(parent)`，把父线程 `inheritableThreadLocals` 的 Entry **浅拷贝（引用复制）**到子线程。线程池的线程是复用的，`new Thread` 只发生一次，之后父线程再改值不会重新拷贝，所以失效——而且任务提交线程和执行线程根本不是父子关系。

### 第 8 层｜TTL（`TransmittableThreadLocal`）怎么解决这个问题？
**答**：不靠继承，靠**装饰任务**：提交任务时捕获当前线程的 TTL 值快照，包装成 `TtlRunnable`；线程池执行前把快照 `replay` 到执行线程的 holder，任务结束 `restore` 原值。所以能跨线程池传递且不污染池线程。代价是必须装饰（`TtlExecutors` 或 `@Async` 配置 taskDecorator），漏装饰就失效。

### 第 9 层｜`ThreadLocal` 和 `synchronized` 有什么区别？各适合什么？
**答**：`synchronized` 是**时间换空间**（串行化共享变量，多线程改同一份）；`ThreadLocal` 是**空间换时间**（每个线程一份，无锁并发）。适合「天然按线程隔离」的上下文：用户身份、`SimpleDateFormat`、事务连接、MDC 日志 traceId。不适合共享状态（如计数器）。

### 第 10 层｜`get()` 时 key 已被回收（Entry 的 key 为 null）会怎样？
**答**：`getEntryAfterMiss` 探测到 `k == null` 会调 `expungeStaleEntry(i)` 顺手清理，并继续往后探测；所以**读也能触发清理**。但如果之后再没人用这个 map（线程池空闲线程），泄漏就一直在，这也是为什么清理不能替代 `remove()`。

### 第 11 层｜`SimpleDateFormat` 为什么用 `ThreadLocal` 包一层？有更好的方案吗？
**答**：`SimpleDateFormat` 内部 `Calendar` 可变且非线程安全，多线程共用会解析出错误日期。`ThreadLocal` 给每个线程一份实例解决竞争；但更好的方案是直接换 `DateTimeFormatter`（不可变、线程安全），根本不需要 `ThreadLocal`——能不用就不用。

### 第 12 层（终局）｜一次 `set(value)` 从调用到内存落地，发生了什么？
**答**：`Thread.currentThread()` → 取 `t.threadLocals`，null 则 `createMap` 建 `Entry[]`（长度 16、阈值 2/3）→ 计算 `index = threadLocalHashCode & (len-1)` → 从 index 线性探测：命中同 key 就替换 value；命中 `key == null` 走 `replaceStaleEntry`（顺手清理并可能把新值放进更靠前的过期槽）→ `size++`，若 `size >= threshold` 先 `rehash()`（`cleanSomeSlots` + 全量 `expungeStaleEntries`，仍挤则扩容 ×2）→ 写入 `table[i]`。**分水岭：能说出「懒加载 + 开放寻址 + 阈值 2/3 + rehash 时才扩容」。**

## L5 名词拆解表（"每个名词都拆开"）

| 名词 | 是什么 | 为什么存在 | 面试追问点 |
|---|---|---|---|
| `ThreadLocalMap` | `Thread` 的字段，`Entry[]` 实现的哈希表 | 数据随线程生命周期走 | 为什么定义在 Thread 而不是 ThreadLocal |
| `threadLocals` / `inheritableThreadLocals` | `Thread` 上两个字段 | 普通/可继承两套语义 | 懒加载时机（`createMap`） |
| `Entry` | 继承 `WeakReference<ThreadLocal<?>>`，带 value | key 可回收，value 承载数据 | 为何 value 不用弱引用（会被提前回收） |
| 弱引用 key | `referent = ThreadLocal` | 让无引用的 ThreadLocal 可被 GC | 弱引用不能防 value 泄漏 |
| 强引用 value | `Entry.value` 普通字段 | 线程存活期间值必须可用 | 泄漏链：Thread→map→value |
| `expungeStaleEntry` | 从过期槽往后清理并 rehash 修复 | 开放寻址删除后必须修复探测链 | 为什么要搬移后续元素 |
| `cleanSomeSlots` | 启发式清理（log2 次扫描） | 平摊清理成本，避免每次全扫 | 何时触发（set/rehash） |
| `threadLocalHashCode` | 每个 ThreadLocal 的哈希值 | 定位 table 槽位 | 与 `hashCode()` 无关、不可变 |
| `HASH_INCREMENT` | `0x61c88647` | 黄金分割增量，均匀散布 | 斐波那契散列、容量必须 2^n |
| 线性探测 / `nextIndex` | 冲突时 `(i+1) & (len-1)` | 小表比链表更省 | 探测链与删除空槽问题 |
| `threshold` = 2/3 | 扩容阈值 | 开放寻址要留空槽，负载因子不能高 | 触发 `rehash` 与 resize |
| `InheritableThreadLocal` | 构造 `Thread` 时浅拷贝父线程 map | 支持父→子传递 | 线程池场景失效原因 |
| `TransmittableThreadLocal` | 阿里 TTL，任务提交时快照传递 | 解决线程池上下文传递 | 装饰器、replay/restore |
| 线程封闭 | 数据只被一个线程访问 | 免锁的理论基础 | 与 `synchronized` 对比 |

## 代码验证（`jshell` + 一个 `T.java`）

```java
// 1) 线程池复用 → 不 remove 就数据污染（jshell 直接跑）
import java.util.concurrent.*;
ThreadLocal<String> ctx = new ThreadLocal<>();
ExecutorService pool = Executors.newFixedThreadPool(1);
pool.execute(() -> { ctx.set("用户A"); System.out.println("任务1 设置后=" + ctx.get()); });   // 不 remove
Thread.sleep(100);
pool.execute(() -> System.out.println("任务2 读到脏值=" + ctx.get()));                      // 用户A ← 污染
pool.execute(() -> { ctx.set("用户B"); try { System.out.println("任务3=" + ctx.get()); } finally { ctx.remove(); } });
Thread.sleep(100);
pool.execute(() -> System.out.println("任务4 干净=" + ctx.get()));                          // null
pool.shutdown();

// 2) InheritableThreadLocal：new Thread 能继承，线程池不能
InheritableThreadLocal<String> itl = new InheritableThreadLocal<>();
itl.set("父线程值");
new Thread(() -> System.out.println("子线程继承到=" + itl.get())).start();   // 父线程值
Thread.sleep(100);

// 3) 哈希增量与槽位：0x61c88647 让连续 key 均匀散布
int HASH_INCREMENT = 0x61c88647; int len = 16; int h = 0;
for (int i = 0; i < 8; i++) { h += HASH_INCREMENT; System.out.print((h & (len - 1)) + " "); }
System.out.println();   // 7 14 5 12 3 10 1 8 —— 均匀且不重复（注意第一个是 7，不是 0）
```

```java
// 4) 反射验证「数据挂在 Thread 上」（保存为 T.java，需要 --add-opens）
// javac T.java && java --add-opens java.base/java.lang=ALL-UNNAMED T
public class T {
    public static void main(String[] a) throws Exception {
        ThreadLocal<String> tl = new ThreadLocal<>();
        tl.set("hello");
        var f = Thread.class.getDeclaredField("threadLocals");
        f.setAccessible(true);
        Object map = f.get(Thread.currentThread());
        System.out.println("当前线程的 threadLocals=" + map);          // ThreadLocalMap 实例
        var t = map.getClass().getDeclaredField("table"); t.setAccessible(true);
        System.out.println("table 长度=" + java.lang.reflect.Array.getLength(t.get(map))); // 16
        tl.remove();
        boolean anyLeft = java.util.Arrays.stream((Object[]) t.get(map))
                .anyMatch(java.util.Objects::nonNull);
        System.out.println("remove 后还有 Entry 吗=" + anyLeft);     // false（Entry 已被清理）
    }
}
```

## 高频错误（面试官最爱抓的）

| 错误说法 | 正确说法 |
|---|---|
| 「ThreadLocal 是每个线程存一份副本」 | 副本在 `Thread` 的 `ThreadLocalMap` 里，ThreadLocal 只是 key |
| 「弱引用能解决内存泄漏」 | 只能回收 key，value 仍被线程强引用，必须 `remove` |
| 「`ThreadLocalMap` 用链表解决冲突」 | 用**开放寻址 + 线性探测**，且删除后要 rehash 修复 |
| 「`ThreadLocal` 是线程安全的共享变量」 | 它实现的是**线程封闭**，跨线程根本读不到 |
| 「`InheritableThreadLocal` 在线程池也有效」 | 只在 `new Thread` 时拷贝，池化场景要 TTL |
| 「线程池线程结束后 map 会回收」 | 池线程复用不结束，必须显式 `remove` |
| 「`ThreadLocal` 的 hash 用对象的 `hashCode()`」 | 用自增的 `threadLocalHashCode`（`0x61c88647` 步长） |
| 「`get()` 发现 key 为 null 会抛 NPE」 | 会触发清理并返回 `initialValue`，不抛异常 |

## 关联文件

- 上一层（Java 并发八股）：[Java基础与并发](../../03-java/Java基础与并发.md)（第 17 节 ThreadLocal 与内存泄漏）
- 同层追问：[线程池](./08-线程池.md)（池化是泄漏前提）｜[synchronized 与锁升级](./09-synchronized与锁升级.md)｜[volatile、CAS 与 AQS](./10-volatile-CAS-AQS.md)
- Spring 侧落地：[SpringBoot与后端工程](../../03-java/SpringBoot与后端工程.md)（`RequestContextHolder`、事务连接绑定、`@Async` 上下文丢失）
- 典型场景：AI Agent 基础设施里「请求级 traceId / 用户上下文」放 `ThreadLocal`，异步链路必须 TTL 或显式透传；`Reactor` 场景则用 `Context` 而非 `ThreadLocal`
- 速查：[深度追问索引](../00-索引.md)

## 自测标准

- 能说出数据存在 `Thread.threadLocals`，并解释为什么 map 不放在 ThreadLocal 里
- 能画出 `Entry` 的弱引用 key + 强引用 value 与完整泄漏链
- 能讲清 `expungeStaleEntry` 的清理 + rehash 搬移，以及 2/3 阈值与 2^n 容量
- 能解释 `0x61c88647` 的作用，以及为什么用开放寻址不用链表
- 能列线程池不 `remove` 的两个后果，并说出 `InheritableThreadLocal` 与 TTL 的差异
- L4 讲到第 6 层（探测式清理）→ 及格；讲到第 12 层（set 全流程）→ 优秀
