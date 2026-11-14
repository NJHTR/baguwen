# JVM 内存布局与对象布局：一个 `new Object()` 到底占多少字节？

> 精讲层级：从「零基础能看懂」到「源码级」，每个名词都拆开
> 阅读时间：约 35 分钟
> 配套速查：[JVM 内存区域（深度追问）](../../10-deep-dive/java/05-JVM内存区域.md)
> 返回：[精讲索引](../00-索引.md)

---

## 0. 一句话先讲明白

JVM 把内存分成**线程私有**（程序计数器、虚拟机栈、本地方法栈）和**线程共享**（堆、方法区；JDK 8 后方法区由元空间实现，在本地内存）两大类，另外还有一块不在规范里的**直接内存**。
一个对象在堆里的布局固定是：**对象头 + 实例数据 + 对齐填充**。对象头 = `Mark Word`（8 字节）+ `Class Pointer`（压缩后 4 字节）= 12 字节；按 8 字节对齐后，**`new Object()` 占 16 字节**。

```
┌───────────────────────── 对象（new Object()） ─────────────────────────┐
│ Mark Word 8B │ Class Pointer 4B │   （实例数据：无）  │ 对齐填充 4B   │
└──────────────────────────────────────────────────────────────────────┘
   合计 12 字节 -> 向上对齐到 8 的倍数 -> 16 字节
```

几个名词先解释掉：

| 名词 | 是什么 |
|---|---|
| 对象头（object header） | 每个对象开头的一段固定元数据：Mark Word + 类指针 |
| Mark Word | 8 字节，混存 hashCode、GC 年龄、锁状态 |
| Class Pointer | 指向该对象的「类元数据」（这个对象是哪个类的） |
| 对齐填充（padding） | 为满足 8 字节对齐而补的空字节 |
| 压缩指针（compressed oops） | 把 8 字节引用压成 4 字节的技术 |

---

## 1. 它解决什么问题（先讲痛点，不讲定义）

### 1.1 为什么内存要分区

如果所有数据都放一块内存，会同时踩三个坑：

1. **生命周期不同**：方法调用结束，局部变量就该消失；而对象可能要活很久。混在一起没法回收。
2. **线程隔离**：每个线程各跑各的方法，局部变量天然是私有的；如果放共享区，每次读写都要同步，性能崩掉。
3. **管理成本**：类元数据（类的结构信息）变化很少但数量多，对象数据变化频繁；用不同的区域分别管理，GC 和类卸载才能各干各的。

所以 JVM 按「谁拥有 + 活多久」把内存分区：**线程私有区随线程/方法结束自动回收，共享区交给 GC。**

### 1.2 为什么要研究对象布局

因为线上真实问题经常落在这几个数字上：

- **内存估算**：10 万个对象占多少堆？不知道对象大小就算不准容量。
- **OOM 排查**：堆 dump 里看到的「类很大」「对象数异常」都是从布局推出来的。
- **压缩指针**：堆调到 32GB 以上反而变慢，原因就在引用宽度。
- **锁与 GC**：Mark Word 里存着锁状态和 GC 年龄，这是「锁升级」「对象最多熬 15 次 GC」的物理原因。

---

## 2. 一步步拆开

### 2.1 五个区域逐个拆

| 区域 | 私有/共享 | 存什么 | 会不会 OOM | 关键参数 |
|---|---|---|---|---|
| 程序计数器 | 私有 | 当前线程执行到哪条字节码 | **不会** | 无 |
| 虚拟机栈 | 私有 | 栈帧：局部变量表、操作数栈、动态链接、返回地址 | `StackOverflowError` | `-Xss` |
| 本地方法栈 | 私有 | native 方法的栈帧 | `StackOverflowError` | `-Xss` |
| 堆 | 共享 | 对象实例、数组 | `OutOfMemoryError: Java heap space` | `-Xms/-Xmx` |
| 方法区（元空间） | 共享 | 类元数据、运行时常量池 | `OutOfMemoryError: Metaspace` | `-XX:MaxMetaspaceSize` |
| 直接内存 | 进程级 | `DirectByteBuffer` 的堆外缓冲 | `OutOfMemoryError: Direct buffer memory` | `-XX:MaxDirectMemorySize` |

三个容易错的地方：

1. **程序计数器是唯一不会 OOM 的区域**。它只存一个行号，大小固定。
2. **栈溢出是 `StackOverflowError`（Error），不是 OOM**。递归太深就是它。
3. **方法区在 JDK 8 之后叫元空间，用的是本地内存，不在 `-Xmx` 管辖范围**。这就是「堆没满但进程内存一直涨」的原因之一。

### 2.2 对象头：Mark Word 的 64 位怎么分配

对象头第一段是 `Mark Word`，8 字节 = 64 位。它要同时装下三样东西，靠「不同状态下复用同一块字节」实现：

| 位域 | 宽度 | 内容 |
|---|---|---|
| unused | 25 位 | 未使用（早期用于偏向锁线程 ID） |
| identity_hashcode | 31 位 | 惰性计算的 `System.identityHashCode` |
| unused | 1 位 | 未使用 |
| GC 分代年龄 | 4 位 | 0~15，对象每熬过一次 Minor GC 加 1 |
| 偏向锁标记 | 1 位 | JDK 15 起默认关闭，该位空闲 |
| 锁状态 | 2 位 | `01` 无锁 / `00` 轻量级锁 / `10` 重量级锁 / `11` GC 标记 |

两个推论直接来自这张表：

- **GC 年龄只有 4 位 → 最大 15**，所以 `-XX:MaxTenuringThreshold` 最大只能是 15（默认也是 15）。
- **hashCode 只有 31 位**，所以 `hashCode()` 返回的 int 其实是 31 位有效值（负数只是符号位的表现）。第一次调用时算出来写进这里，之后直接读。

### 2.3 对象头第二段：Class Pointer

`Class Pointer`（类指针）指向方法区里该类的元数据，回答「这个对象是什么类」。64 位 JVM 上默认 **8 字节**，开启压缩指针后 **4 字节**。

```
对象头（压缩指针开启）= Mark Word 8B + Class Pointer 4B = 12 字节
对象头（压缩指针关闭）= Mark Word 8B + Class Pointer 8B = 16 字节
```

**数组对象**还要额外 4 字节存**长度**（`arraylength` 指令读的就是它），所以数组头是 16 字节。

### 2.4 实例数据：字段会重排

JVM 不会按你写的顺序放字段，而是按「字段宽度从大到小」重排，目的是减少对齐空洞：

```
long / double（8B）
  ↓
int / float（4B）
  ↓
short / char（2B）
  ↓
byte / boolean（1B）
  ↓
引用（压缩后 4B）
```

重排后仍然可能产生空洞（比如 8 字节对齐要求），这些空洞就是「对齐填充」，最后整体补齐到 8 的倍数。

### 2.5 三种对象的完整推导

**`new Object()`**：

```
Mark Word        8B
Class Pointer    4B（压缩）
实例数据          0B
小计             12B
对齐到 8 的倍数   16B      ← 补 4B 填充
所以：一个空对象占 16 字节
```

**`byte[16]`**：

```
对象头（含长度）  16B（8 + 4 + 4）
元素数据         16B
小计             32B（正好对齐）
```

**验证方式**：用 `Unsafe` 读「第一个实例字段的偏移」和「数组的 baseOffset」，能反推出头有多大（见第 8 节实测）。

### 2.6 压缩指针：4 字节怎么装下 64 位地址

- 对象在堆里**按 8 字节对齐**，所以任何对象地址的低 3 位都是 0；
- 于是存引用时可以只存「地址 >> 3」，读的时候再 `<< 3` 还原；
- 4 字节 = 32 位，能表示 `2^32` 个不同的值，每个值代表 8 字节 → 最大寻址 **2^32 × 8 = 32GB**。

这就是「**堆小于 32GB 时压缩指针生效，超过就失效**」的由来。超过之后引用变回 8 字节，对象变大、缓存命中率下降——**所以把堆从 30GB 调到 34GB 反而可能更慢**。

压缩指针有两套开关：`UseCompressedOops`（管对象引用）和 `UseCompressedClassPointers`（管类指针，对应独立的「压缩类空间」，默认上限 1GB）。

### 2.7 TLAB：为什么分配对象几乎没有成本

分配对象本该是「在 Eden 找一块空闲内存」，正常需要查找空闲块。但 JVM 用了两级优化：

1. **指针碰撞（pointer bump）**：Eden 是一整块连续内存，分配只需把「当前指针」往前走 `size` 字节，一条加法；
2. **TLAB（Thread Local Allocation Buffer）**：多线程同时 bump 会打架，于是每个线程在 Eden 里预占一小块私有缓冲，线程在自己的 TLAB 里 bump，用完再申请新块。

实测默认 `UseTLAB = true`，且大小会自适应（`ResizeTLAB`）。大对象（放不进 TLAB）走慢路径直接进 Eden 或老年代。GC 时 Survivor 区给每个 GC 线程也划一块，叫 PLAB，语义相同。

---

## 3. 完整推导

### 3.1 推导一：为什么 Mark Word 是 8 字节而不是 4 字节

32 位 JVM 的 Mark Word 是 4 字节（32 位）：

```
hash 25 位 | age 4 位 | biased 1 位 | lock 2 位 = 32 位
```

64 位 JVM 如果继续用 4 字节，31 位的 hash 就放不下（32 位下 hash 只有 25 位，`identityHashCode` 的取值范围会缩水）。而对象头大小又必须固定，所以选 8 字节，把 hash 扩到 31 位、并留出 25 位空闲给未来的锁优化。**8 字节是「hash 精度 + 对齐友好 + 预留空间」的结果。**

### 3.2 推导二：为什么必须 8 字节对齐

三个原因：

1. **CPU 访问效率**：多数平台读未对齐的 8 字节要两次内存访问；
2. **压缩指针的前提**：对齐保证低 3 位为 0，才能用「右移 3 位」把 32 位扩成 35 位地址；
3. **缓存行友好**：8 字节对齐让字段落在缓存行内的概率更高。

对齐的代价是「可能浪费几个字节」。`new Object()` 的 12 字节就浪费了 4 字节（12 → 16）。但换来的是每个对象地址都能安全压缩，整体更省。

### 3.3 推导三：`String` 对象约 24 字节

```
12(头) + 4(value 引用) + 4(hash) + 1(coder) + 1(hashIsZero) = 22B -> 对齐 24B
```

它指向的 `byte[]` 另算（16 字节头 + 内容）。所以 `"hi"` 这个字面量大约 `24 + 24 = 48` 字节。

### 3.4 推导四：100 万个空对象占多少

```
16B × 1,000,000 = 16,000,000B ≈ 15.26MB
```

加上数组引用本身（`Object[]` 100 万个槽位，压缩指针下 4B/槽 = 4MB）以及 TLAB 预留的浪费，实际约 20MB。
**这个估算能力在「容器里该配多大堆」时很关键**：如果业务要常驻 500 万个对象，光对象头就 80MB。

---

## 4. 极简模型：把 64 位 Mark Word 缩小到 8 位

64 位太抽象，用 8 位模型理解「同一块字节如何复用」：

```
8 位模型：hash 3 位 | age 2 位 | lock 2 位 | 未用 1 位
无锁状态：  [h h h][a a][0 1][x]     -> lock=01 表示无锁
轻量锁：    [指针地址 5 位][0 0][x]   -> lock=00，原 hash 被移到栈上 Lock Record
重量锁：    [Monitor 指针 5 位][1 0]  -> lock=10，A 指向 ObjectMonitor
GC 标记：   [ ................. ][1 1] -> lock=11

同一个字节，不同状态下解释不同 —— 这就是「Mark Word 复用」。
```

真实 64 位版本只是把位数放大，规律一模一样：**锁状态由最低 2 位决定，其余位按状态解释**。所以「判断对象处于什么锁」只需 `mark & 0b11`。

---

## 5. 为什么这样设计（被否决的四个方案）

**方案 A：不用压缩指针，引用就 8 字节。** 否决原因：堆里到处都是引用（每个对象字段、每个数组元素），8 字节会让内存几乎翻倍、缓存命中率大幅下降；而对象天然 8 字节对齐，正好能省 3 位。代价是「堆不能超过 32GB」，这被当作可接受的边界（大堆场景用别的方案）。

**方案 B：对象头只放类指针，hash 和 GC 年龄另存一个表。** 否决原因：`hashCode()` 是高频操作（HashMap 每次定位都要），查表意味着又一层内存访问；GC 年龄在每次 GC 都要读改，同样需要快。放进对象头 = 一次内存读，快得多。代价是对象头固定占 12 字节甚至对空对象「浪费」——但这是**用空间换访问速度**的经典取舍。

**方案 C：所有对象都栈上分配（不建堆）。** 否决原因：对象生命周期多数时候编译期无法确定；栈帧大小在编译期固定，动态大小对象没法放；而且对象可能被其他线程引用，栈是线程私有的。JVM 的做法是「逃逸分析发现不逃逸才优化掉」，而不是默认栈分配。

**方案 D：继续用永久代而不是元空间。** 否决原因：永久代大小固定（`-XX:MaxPermSize`），类元数据一多就 `PermGen space` OOM，且回收条件苛刻。元空间用本地内存、默认不设上限（受物理内存与 `MaxMetaspaceSize` 限制），类卸载后能归还内存。

**方案 E：不做对齐，按需紧凑排列。** 否决原因：未对齐访问在部分平台会异常、在多数平台要拆成两次访问；而且没有对齐就无法用「右移 3 位」压缩指针。**对齐的少量浪费换来的是访问效率 + 压缩能力。**

---

## 6. 关键参数为什么是这个值

| 参数 | 默认/取值 | 为什么 |
|---|---|---|
| 对象头（压缩） | 12 字节 | Mark Word 8 + 类指针 4 |
| 数组额外长度 | 4 字节 | 数组长度是 int |
| 对齐粒度 | 8 字节 | 保证低 3 位为 0，压缩指针才能 `<<3` |
| 压缩指针生效条件 | 堆 ≤ 约 32GB | 4 字节 × 8 = 32GB 可寻址 |
| 压缩类空间上限 | 1GB | `CompressedClassSpaceSize` 默认值（实测） |
| `MaxTenuringThreshold` | 15 | Mark Word 的 age 只有 4 位，最大 15 |
| `UseTLAB` | true | 避免分配竞争，实现指针碰撞 |
| 元空间上限 | 默认无上限 | 用本地内存，靠 `-XX:MaxMetaspaceSize` 限制 |

---

## 7. 版本演进

**JDK 6**：方法区由**永久代**实现，字符串常量池也在永久代；对象头已含 hash/age/锁标记。

**JDK 7**：字符串常量池**移到堆**；永久代仍在。

**JDK 8**：**移除永久代，改用元空间**（本地内存）；`MaxMetaspaceSize` 取代 `MaxPermSize`；压缩指针默认开启。

**JDK 9 / 17**：`String` 内部改 `byte[] + coder`，String 对象大小从 24B 变成 24B（字段数没变，只是引用类型变了）；JDK 15 起**偏向锁默认禁用**（JEP 374），Mark Word 里的偏向位空闲，锁升级路径变成「无锁 → 轻量级 → 重量级」。

**JDK 21**：无结构性变化；虚拟线程的栈帧放在堆上（属于线程模型的变化，对象布局不变）；分代 ZGC 属于 GC 层。

---

## 8. 亲手验证

```java
import java.lang.reflect.Field;
import sun.misc.Unsafe;

public class LayoutProbe {
    static class A { int x; long y; Object ref; }        // 混合字段：观察重排与填充
    static class OnlyRef { Object a; }                   // 只有引用：观察压缩指针效果

    public static void main(String[] args) throws Exception {
        Field f = Unsafe.class.getDeclaredField("theUnsafe");
        f.setAccessible(true);
        Unsafe u = (Unsafe) f.get(null);

        System.out.println("A.x  偏移 = " + u.objectFieldOffset(A.class.getDeclaredField("x")));
        System.out.println("A.y  偏移 = " + u.objectFieldOffset(A.class.getDeclaredField("y")));
        System.out.println("A.ref 偏移 = " + u.objectFieldOffset(A.class.getDeclaredField("ref")));
        System.out.println("OnlyRef.a 偏移 = " + u.objectFieldOffset(OnlyRef.class.getDeclaredField("a")));
        System.out.println("byte[].baseOffset = " + u.arrayBaseOffset(byte[].class));
        System.out.println("long[].indexScale = " + u.arrayIndexScale(long[].class));
        System.out.println("addressSize = " + u.addressSize());

        // 用堆增量估算 new Object() 的平均大小
        int n = 2_000_000;
        Object[] keep = new Object[n];
        System.gc(); Thread.sleep(300);
        Runtime r = Runtime.getRuntime();
        long before = r.totalMemory() - r.freeMemory();
        for (int i = 0; i < n; i++) keep[i] = new Object();
        long after = r.totalMemory() - r.freeMemory();
        System.out.println("new Object() 平均约 " + (after - before) / (double) n + " 字节（含测量噪声）");
        System.out.println("keep 数组非空元素 = " + keep.length);
    }
}
```

```bash
javac -encoding UTF-8 --add-exports jdk.unsupported/sun.misc=ALL-UNNAMED LayoutProbe.java
java --add-exports jdk.unsupported/sun.misc=ALL-UNNAMED LayoutProbe
# 关掉压缩指针再看第一个引用字段的偏移（应从 12 变成 16）
java -XX:-UseCompressedOops --add-exports jdk.unsupported/sun.misc=ALL-UNNAMED LayoutProbe
```

预期输出（默认开启压缩指针）：

```
A.x  偏移 = 12
A.y  偏移 = 16
A.ref 偏移 = 24
OnlyRef.a 偏移 = 12
byte[].baseOffset = 16
long[].indexScale = 8
addressSize = 8
new Object() 平均约 16.x 字节（含测量噪声）
```

加 `-XX:-UseCompressedOops` 后，`OnlyRef.a 偏移` 会从 **12** 变成 **16**（引用从 4 字节变 8 字节），而 `A.x/A.y/A.ref` 因字段重排恰好不变——**这是「看布局要看具体字段排列」的绝佳例子**。

这组数字回答了三件事：

1. 第一个字段从 **12** 开始 → 对象头 12 字节 = Mark Word 8 + 压缩类指针 4；
2. `byte[].baseOffset = 16` → 数组头 16 字节 = 12 + 长度 4；
3. `new Object()` 堆增量约 16 字节 → 12 字节头 + 4 字节对齐填充。

---

## 9. 常见误区

| 错误说法 | 正确说法 |
|---|---|
| 「对象头只有 8 字节 Mark Word」 | 压缩指针下是 12 字节（8 + 4 类指针），数组再加 4 字节长度 |
| 「方法区就是永久代」 | JDK 8 起是元空间，在本地内存，不属于 `-Xmx` |
| 「字符串常量池在元空间」 | 在堆里（JDK 7 起） |
| 「栈溢出是 OOM」 | 是 `StackOverflowError`（Error），由递归深度导致 |
| 「堆越大越好」 | 超过约 32GB 压缩指针失效，引用变 8 字节，可能更慢 |
| 「对象一定分配在堆上」 | C2 逃逸分析后可标量替换/栈上分配，根本不在堆 |
| 「字段按代码顺序排列」 | JVM 按宽度重排以减少空洞 |
| 「`new Object()` 占 12 字节」 | 12 字节头 + 4 字节对齐填充 = 16 字节 |

---

## 10. 连续追问 Q&A

### Q1：JVM 内存分哪几块？哪些线程私有？
**答**：私有：程序计数器、虚拟机栈、本地方法栈；共享：堆、方法区（JDK 8 后元空间）；另有直接内存。程序计数器唯一不会 OOM。

### Q2：`new Object()` 为什么占 16 字节？
**答**：Mark Word 8 + 压缩类指针 4 = 12，按 8 字节对齐后补 4 字节填充 = 16。压缩指针关闭时是 Mark Word 8 + 类指针 8 = 16，正好不用填充。

### Q3：Mark Word 里存了什么？为什么只有 8 字节却够用？
**答**：31 位 hash、4 位 GC 年龄、2 位锁状态、1 位偏向标记，其余空闲。之所以够用，是因为不同状态下这些位**复用**（轻量级锁时 hash 被移到栈上 Lock Record，重量级锁时存 Monitor 指针）。

### Q4：GC 年龄为什么最大是 15？
**答**：Mark Word 里 age 字段只有 4 位，最大表示 15，所以 `-XX:MaxTenuringThreshold` 上限就是 15。

### Q5：压缩指针是什么？为什么 32GB 是分水岭？
**答**：对象 8 字节对齐，地址低 3 位恒为 0，所以引用只存「地址 >> 3」，4 字节可表示 `2^32` 个值、每个值 8 字节 → 32GB。超过之后只能退回 8 字节引用。

### Q6：为什么类指针和对象引用是两个开关？
**答**：`UseCompressedOops` 管对象引用；`UseCompressedClassPointers` 管指向类元数据的指针（用独立的压缩类空间，默认上限 1GB）。两者可以独立开关。

### Q7：数组对象头为什么比普通对象多 4 字节？
**答**：要存数组长度，`arraylength` 指令直接读这 4 字节。所以数组头 16 字节，`byte[].baseOffset` 实测就是 16。

### Q8：TLAB 是什么？解决什么问题？
**答**：线程私有的分配缓冲。多个线程同时在 Eden 分配会竞争，TLAB 让每个线程在自己的小块里做「指针碰撞」，避免加锁，分配成本降到一条加法。默认开启且自适应大小。

### Q9：逃逸分析能让对象不在堆上吗？
**答**：能。C2 判断对象没逃出方法后，可做标量替换（把对象拆成字段放寄存器）或栈上分配，再加锁消除。但只在 C2 编译后的代码里生效，解释执行阶段仍在堆上。

### Q10：为什么元空间替代永久代？
**答**：永久代大小固定、回收条件苛刻，容易 `PermGen space` OOM，且「调多大」很难猜。元空间用本地内存、默认不设上限，类卸载后能归还，解决了这两个问题。

### Q11：一个 100 万元素的 `Object[]` 占多少？
**答**：数组头 16 字节 + 100 万 × 4 字节引用（压缩指针）= 约 4MB；它指向的 100 万个对象另算（每个至少 16 字节 ≈ 16MB）。

### Q12：JDK 21 对象布局有变化吗？
**答**：没有。Mark Word、类指针、对齐规则都没变。变化在别处：JDK 15 禁用偏向锁让 Mark Word 的偏向位空闲；虚拟线程把栈帧放到堆上，但对象布局不变。

---

## 11. 一张图总结

```
JVM 内存
├── 线程私有
│   ├── 程序计数器        行号，不会 OOM
│   ├── 虚拟机栈          栈帧；递归太深 -> StackOverflowError
│   └── 本地方法栈        native 栈帧
├── 线程共享
│   ├── 堆               对象/数组；分代：Eden:S0:S1:Old = 8:1:1
│   └── 方法区(元空间)    类元数据、运行时常量池（本地内存）
└── 直接内存              DirectByteBuffer（不受 -Xmx 限制）

对象布局（压缩指针开启）
┌────────────┬───────────────┬──────────┬──────────┐
│ Mark Word  │ Class Pointer │ 实例数据  │ 对齐填充  │
│   8B       │     4B        │  重排后   │ 补到 8 倍数│
└────────────┴───────────────┴──────────┴──────────┘
     new Object() = 12B -> 16B
     byte[16]     = 16 + 16 = 32B

压缩指针：引用 4B，存「addr >> 3」，2^32 × 8 = 32GB 上限
```

---

## 12. 一句话复盘

> 内存按「谁拥有、活多久」分为线程私有（PC/栈）和共享（堆/元空间），外加直接内存。对象 = 对象头 + 实例数据 + 对齐；对象头是 Mark Word（8B，存 hash/GC 年龄/锁状态）+ 类指针（压缩后 4B）= 12B，对齐后空对象 16B。压缩指针靠「8 字节对齐 + 右移 3 位」把引用压到 4B，换来 32GB 的堆上限；TLAB 让对象分配变成指针加法。

---

## 13. 自测题（先自己答，再看答案）

**1. `new Object()` 占多少字节？怎么算的？**
答案：16 字节。Mark Word 8 + 压缩类指针 4 = 12，按 8 字节对齐补 4 = 16。

**2. 为什么数组对象的头比普通对象多 4 字节？**
答案：要存数组长度，供 `arraylength` 指令使用；`byte[].baseOffset` 实测为 16。

**3. 压缩指针为什么最多只能覆盖 32GB？**
答案：引用 4 字节 = 32 位，存「地址 >> 3」，`2^32 × 8 字节 = 32GB`。

**4. Mark Word 里 GC 年龄几位？由此推出什么参数上限？**
答案：4 位，最大 15，所以 `MaxTenuringThreshold` 上限是 15。

**5. 栈溢出和堆溢出分别是什么异常？**
答案：栈是 `StackOverflowError`（Error，递归过深）；堆是 `OutOfMemoryError: Java heap space`（对象太多/泄漏）。

**6. TLAB 解决什么问题？**
答案：多线程在 Eden 分配对象会竞争；TLAB 给每个线程私有小块，用指针碰撞免锁分配。

---

## 14. 关联文件

- 上一篇精讲：[String 常量池与 intern](04-String常量池与intern.md)
- 深一层：[JVM 内存区域](../../10-deep-dive/java/05-JVM内存区域.md)
- 下一篇精讲：[GC 三色标记与写屏障](06-GC三色标记与写屏障.md)
- 线上排查：[JVM 调优与线上排查](../../10-deep-dive/java/14-JVM调优与线上排查.md)
- 返回：[精讲索引](../00-索引.md)
