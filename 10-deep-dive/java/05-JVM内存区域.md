# JVM 内存区域（JVM Memory Areas & Object Layout）

> 面试权重：5/5　｜　追问深度：**L5（对象头位布局 / TLAB 分配路径 / OopMap）**
> 一句话定位：背下「五块内存 + 哪个会 OOM」只是开场。真正分层的是**对象在内存里长什么样、分配为什么几乎是零成本、GC 怎么在 safepoint 精确找到所有引用**。答到「Mark Word 第几位是什么」这一层，面试官就知道你读过源码。

**本文件用法**：从 L1 往下读，每读完一层合上书自问自答。**停在答不出的那一层，就是你的真实水平线。**
[返回深度追问索引](../00-索引.md)

---

## L1 一句话答案（10 秒能说出口）

JVM 运行时数据区分**线程私有**（程序计数器、虚拟机栈、本地方法栈）和**线程共享**（堆、方法区；JDK 8 后方法区由**元空间**实现、在本地内存），另有不在规范里的**直接内存**。会 OOM 的是堆、元空间、直接内存；栈会 `StackOverflowError`；程序计数器是唯一不会 OOM 的区域。

---

## L2 原理层：五块内存 + 谁会 OOM

| 区域 | 私有/共享 | 存什么 | 异常 | 常用参数 |
|---|---|---|---|---|
| 程序计数器 | 私有 | 当前字节码行号 | **无** | 无 |
| 虚拟机栈 | 私有 | 栈帧（局部变量表/操作数栈/动态链接/返回地址） | `StackOverflowError` | `-Xss` |
| 本地方法栈 | 私有 | native 方法栈帧 | `StackOverflowError` | `-Xss` |
| 堆 | 共享 | 对象实例、数组 | `OutOfMemoryError: Java heap space` | `-Xms/-Xmx/-Xmn` |
| 方法区（元空间） | 共享 | 类元数据、常量、静态变量（JDK8 起静态变量随 Class 对象在堆） | `OutOfMemoryError: Metaspace` | `-XX:MaxMetaspaceSize` |
| 直接内存 | 进程 | `DirectByteBuffer` 的堆外缓冲 | `OutOfMemoryError: Direct buffer memory` | `-XX:MaxDirectMemorySize` |

**堆内分代**：`Eden : S0 : S1 = 8 : 1 : 1`（`-XX:SurvivorRatio=8`），新生代默认占堆 1/3（`-XX:NewRatio=2`，即 new:old = 1:2）。所以默认堆 = 新生代 1/3 + 老年代 2/3。

**JDK 8 的关键变化**：永久代（PermGen）被移除，改用**元空间**——元数据搬到本地内存（不受 `-Xmx` 限制，受物理内存与 `MaxMetaspaceSize` 限制）。这解决了「永久代调多大都容易 OOM」的老问题（`OutOfMemoryError: PermGen space` 成为历史），但换来了「元空间不设上限会吃光物理内存」的新坑。

---

## L3 底层层：对象布局、分配路径、GC 怎么找根

### 3.1 对象在内存里的布局（含实测偏移）

```
┌──────────────────────── 对象头（12B，开启压缩指针） ────────────────────────┐
│ Mark Word (8B)          │ Class Pointer (4B，压缩)                          │
├─────────────────────────────────────────────────────────────────────────────┤
│ 实例数据（按字段类型重排：long/double 先、然后 int/float、short/char、引用、byte/boolean） │
├─────────────────────────────────────────────────────────────────────────────┤
│ 对齐填充（8 字节对齐；不够就补到 8 的倍数）                                   │
└─────────────────────────────────────────────────────────────────────────────┘
数组对象：Mark Word(8) + Class Pointer(4) + length(4) + 元素...
```

**实测（`Unsafe.objectFieldOffset`，JDK 17 默认压缩指针）**：类 `A { int x; long y; Object ref; }` 的字段偏移是 `x=12`、`y=16`、`ref=24`；`byte[].baseOffset=16`（= 12 头 + 4 长度）、`long[].indexScale=8`、`addressSize=8`。

**这组数字证明了什么**：第一个字段从第 **12** 字节开始 → 对象头 8B Mark Word + 4B 压缩类指针；数组的 baseOffset 是 **16** → 多了 4B 的 length。要看压缩指针的效果，得用「只有引用字段的类」：压缩时该字段偏移 12，加 `-XX:-UseCompressedOops` 后变 16（引用从 4B 变 8B），再加 `-XX:-UseCompressedClassPointers` 后 `byte[]` 的 baseOffset 从 16 变 24。上面 `A` 类因为字段布局有空洞，关掉压缩后偏移恰好不变——这正是「看布局要看具体字段排列」的例子。

### 3.2 Mark Word：8 字节里的 64 个 bit

| 位域 | 宽度 | 内容 |
|---|---|---|
| unused | 25 bit | 未使用（原偏向锁线程 ID 等） |
| identity_hashcode | 31 bit | 惰性计算的 `System.identityHashCode` |
| unused | 1 bit | 未使用 |
| GC age | 4 bit | 分代年龄（最大 15，所以 `MaxTenuringThreshold` ≤15） |
| biased_lock | 1 bit | 偏向锁标记（JDK 15 起默认关闭，JEP 374） |
| lock | 2 bit | `01` 无锁 / `00` 轻量级锁 / `10` 重量级锁 / `11` GC 标记 |

**为什么 GC age 只有 4 bit**：4 bit 最大 15，所以 `-XX:MaxTenuringThreshold` 最大只能设 15（实测默认就是 15）。这也是「对象最多熬 15 次 Minor GC」的硬件原因。

**为什么 `hashCode()` 调一次就固定**：第一次调用时由线程相关的随机算法（Marsaglia xor-shift）算出并写进 Mark Word，之后直接读；这也意味着**同时占用 Mark Word 的空间**，锁状态变化时 hash 会被移到别处（轻量级锁时存在 Lock Record 里）。

### 3.3 压缩指针：为什么堆小于 32GB 才开

- 64 位 JVM 的引用默认 8 字节，堆里全是引用会很浪费。开启 **CompressedOops** 后引用变 4 字节，用「基址 + (引用值 << 3)」解码（对象 8 字节对齐 → 低 3 位恒为 0，可以省掉）。
- 4 字节 × 8 = **32GB**，这就是「堆超过 32GB 压缩指针失效」的由来。实测：默认堆 4GB 时 `UseCompressedOops = true`；启动参数里 `-XX:+UseCompressedOops` 是 ergonomic 决定的。
- 超过 32GB 后引用变 8 字节，对象变大、缓存命中率下降，**所以「堆调到 32GB 以上反而可能变慢」**——这是真实调优里很著名的一条经验。
- 独立的 `UseCompressedClassPointers` 只管「类指针」，它用的压缩类空间默认上限 1GB。

### 3.4 TLAB：为什么对象分配几乎零成本

- 分配对象 = 在 Eden 里**指针碰撞（pointer bump）**：`top += size`，一条加法 + 一次边界比较，没有锁、没有查找空闲块。
- 但多线程同时 bump 会打架，于是每个线程在 Eden 里预分一块 **TLAB（Thread Local Allocation Buffer）**，线程在自己的 TLAB 里 bump，用完再向 Eden 申请新块。
- 实测默认 `-XX:+UseTLAB = true`，`-XX:+ResizeTLAB = true`（JVM 会按分配速率动态调 TLAB 大小）；`TLABWasteTargetPercent` 默认 1%（TLAB 尾部浪费上限）。
- 大对象（超过 `PretenureSizeThreshold` 或放不进 TLAB）走慢路径：直接分配到老年代或 Eden 共享区，可能触发 GC。
- **PLAB**：GC 时 Survivor 区给每个 GC 线程也划一块，语义同 TLAB，用于晋升对象。

### 3.5 逃逸分析：对象真的都在堆上吗

- `-XX:+DoEscapeAnalysis`（实测默认 true，**只有 C2 开启**）分析对象的引用是否「逃出」方法/线程。
- 三种结果：
  1. **不逃逸** → 可以**栈上分配**（实际 HotSpot 不怎么真的在栈上分配，而是走下一招）；
  2. **标量替换**（`-XX:+EliminateAllocations`，实测 true）：把对象拆成若干标量（字段）放进寄存器，对象根本不创建；
  3. **锁消除**（`-XX:+EliminateLocks`）：不可能竞争的 `synchronized` 直接去掉。
- 所以「`new` 的对象一定在堆上」是**错的**。但注意：这些优化只在 C2 编译后的代码里生效，解释执行、C1 都还是老老实实分配。

### 3.6 OopMap 与 safepoint：GC 怎么精确找到引用

- GC 做可达性分析需要**遍历所有引用**。如果每个 safepoint 都从栈帧里逐条解释执行找到哪些是引用，代价极高。
- 所以 JIT 在生成代码时，在每个 **safepoint** 的位置记录一张 **OopMap**：栈上哪个偏移、哪个寄存器里是 oop（对象引用）。GC 到时只按表取，O（表大小）而不是扫描整个栈。
- **safepoint** 是线程必须「停下来配合 GC」的检查点：方法返回、循环回边（back-edge）、native 调用返回处会插 safepoint poll。
- 这就解释了「为什么 GC 要 STW」「为什么一个执行长循环的线程会卡住 GC」：**它没跑到 safepoint poll 就不会停**（`-Xlog:safepoint` 能看到 `Time since last safepoint`）。

---

## L4 追问树（面试官一路往下问，你能撑到第几层？）

> 规则：从上往下问。**第 1-3 层是应届生必备，第 4-6 层拉开差距，第 7 层以后是加分。**

### 第 1 层｜JVM 内存分哪几块？
**答**：线程私有：程序计数器、虚拟机栈、本地方法栈；线程共享：堆、方法区（JDK 8 起由元空间实现，在本地内存）；外加规范之外、进程级的直接内存。堆还分新生代（Eden + 两个 Survivor）和老年代。

### 第 2 层｜哪些区域会 OOM，哪些不会？
**答**：堆 → `Java heap space`；元空间 → `Metaspace`；直接内存 → `Direct buffer memory`；虚拟机栈 → `StackOverflowError`（是 Error 不是 OOM，除非栈在创建时申请不到内存才会 OOM）；程序计数器 → 唯一不会 OOM 的区域。另外还有 `GC overhead limit exceeded`（GC 花了大量时间却几乎没回收出空间）。

### 第 3 层｜对象在内存里长什么样？
**答**：对象头（Mark Word 8B + 压缩类指针 4B）+ 实例数据（按类型重排以对齐）+ 8 字节对齐填充；数组再多 4B 的 length。实测第一个字段偏移是 12、`byte[]` 的 baseOffset 是 16，正好印证 header 12B / 数组 header 16B。

### 第 4 层｜Mark Word 里存了什么？
**答**：64 bit 里混存了：identity hashCode（31 bit，惰性算一次就固定）、GC 分代年龄（4 bit，最大 15）、锁状态标记（2 bit：01 无锁 / 00 轻量级 / 10 重量级 / 11 GC 标记）、偏向标记（1 bit，JDK 15 起默认关闭）。它是「无锁→偏向→轻量级→重量级」锁升级的存储载体，也是为什么 GC 年龄最大只能到 15。

### 第 5 层｜压缩指针是什么？为什么堆小于 32G 才生效？
**答**：把 64 位引用压成 4 字节，利用对象 8 字节对齐省掉低 3 位，解码方式是「基址 + (值 << 3)」。4 字节 × 8 = 32GB 是能表示的最大地址范围，超过就失效、引用退回 8 字节。所以「堆调到 32G 以上反而更慢」是真实存在的调优经验：引用变大 → 对象变大 → 缓存命中率下降。

### 第 6 层｜对象一定分配在堆上吗？
**答**：不一定。C2 的逃逸分析（`DoEscapeAnalysis`）能判断对象没逃出方法，于是做标量替换（`EliminateAllocations`）把对象拆成字段放寄存器，或栈上分配；再加锁消除。但只有 C2 编译后的代码享受这个优化，解释执行阶段还是老老实实在堆上分配。另外 TLAB 让堆分配本身变成「指针碰撞」，所以「堆分配慢」这个前提有一部分已经不成立。

### 第 7 层｜TLAB 是什么，解决什么问题？
**答**：Thread Local Allocation Buffer，每个线程在 Eden 里预占一小块，分配对象时在自己的 TLAB 里做指针碰撞（`top += size`），避免多线程竞争 Eden 的分配指针。用完向 Eden 申请新块。默认开启且大小自适应；TLAB 尾巴浪费超过 `TLABWasteTargetPercent`（默认 1%）就会换新块。GC 时 Survivor 里的对应物叫 PLAB。

### 第 8 层｜为什么需要 safepoint？OopMap 是干嘛的？
**答**：GC 要 STW，但线程得跑到「安全点」才能停——安全点设在方法返回、循环回边、native 返回处，靠 poll 指令检测。停下后 GC 要找到所有栈上/寄存器里的引用，靠的是 JIT 在每个安全点生成的 **OopMap**（哪些位置是 oop 的表），这样不用解释整个栈帧，O(表大小) 就能精确定位根。所以「一个线程在长循环里不跑 safepoint poll 会拖住整次 GC」是真的。

### 第 9 层｜直接内存是什么？会 OOM 吗？
**答**：`ByteBuffer.allocateDirect` 分配的堆外内存（`DirectByteBuffer`），NIO/Netty 用它避免「堆内 → 堆外」的拷贝（配合 `FileChannel` 的零拷贝）。它不受 `-Xmx` 限制但受物理内存和 `-XX:MaxDirectMemorySize`（默认等于最大堆）限制，超了抛 `OutOfMemoryError: Direct buffer memory`。Java 9+ 的 `Cleaner` 负责在对象不可达时释放，不释放也会泄漏。

### 第 10 层（终局）｜`-Xmx` 到 mmap、`new` 到汇编，各发生了什么？
**答**：① 启动时 `-Xmx` 由 `Arguments::parse` 解析，`os::reserve_memory` 用 **`mmap(PROT_NONE)`** 先保留虚拟地址（`ReservedHeapSpace`），提交时再 `mprotect`/`commit_memory` —— 所以「堆大小不等于立刻占满物理内存」，`-Xms=-Xmx` 是为了避免运行时反复扩容（`UseTransparentHugePages` 又是另一层）。② C2 编译后的 `new` 走 fast path：`mov rax, [r15 + thread_top]`（取 TLAB top）→ `add rax, size` → `cmp rax, [r15 + thread_end]` → 超了就跳到 slow path 调 `Runtime1::new_instance`，没超就 `mov [top], class_ptr` 并返回。整个分配**没有函数调用、没有锁**，这就是「Java 分配对象比 C 的 malloc 还快」的原因。

---

## L5 名词拆解表（"每个名词都拆开"）

| 名词 | 是什么 | 为什么存在 | 面试追问点 |
|---|---|---|---|
| 栈帧 | 方法调用的一次记录 | 存局部变量/操作数栈/返回地址 | 递归多深会 SOE（`-Xss` 决定） |
| Mark Word | 对象头前 8 字节 | 存 hash + GC 年龄 + 锁状态 | 为什么 GC 年龄最多 15 |
| Class Pointer | 指向方法区类元数据 | 让对象知道自己是谁 | 压缩后 4 字节 |
| 8 字节对齐 | 对象大小向上取整到 8 的倍数 | 让压缩指针能省 3 位 | 空对象为什么占 16 字节 |
| 压缩指针 | 4 字节引用（<<3 解码） | 省内存、提高缓存命中 | 32GB 分水岭 |
| TLAB | 线程私有分配缓冲 | 避免分配竞争，实现指针碰撞 | 与 PLAB 的区别 |
| 指针碰撞 | `top += size` 式分配 | 分配近乎零成本 | 为什么比 malloc 快 |
| 逃逸分析 | C2 判断对象是否外泄 | 支持栈上分配/标量替换/锁消除 | 只对 C2 代码生效 |
| 标量替换 | 把对象拆成字段放寄存器 | 彻底消除分配 | 与栈上分配的关系 |
| OopMap | 安全点处的引用位置表 | 让 GC 精确找根 | 没有它就得扫整个栈 |
| safepoint | 线程必须停下的检查点 | 保证 GC 时世界静止 | 长循环为何阻塞 GC |
| 元空间 | JDK 8 的方法区实现（本地内存） | 取代受 `-Xmx` 限制的永久代 | 不设上限会吃光物理内存 |
| 直接内存 | 堆外的 `DirectByteBuffer` | 避免堆内外拷贝（零拷贝） | 默认上限 = 最大堆 |

---

## 代码验证（`JvmProbe.java`，JDK 17 编译运行通过）

```java
import java.lang.reflect.Field;
import java.util.*;
import sun.misc.Unsafe;

public class JvmProbe {
    static class A { int x; long y; Object ref; }      // 混合类型：观察布局补偿
    static class OnlyRef { Object a; }                 // 只有引用：观察压缩指针效果
    static int depth;
    static void recurse() { depth++; recurse(); }

    public static void main(String[] args) throws Exception {
        Field f = Unsafe.class.getDeclaredField("theUnsafe");
        f.setAccessible(true);
        Unsafe u = (Unsafe) f.get(null);
        System.out.println("x=" + u.objectFieldOffset(A.class.getDeclaredField("x"))       // 12
                + " y=" + u.objectFieldOffset(A.class.getDeclaredField("y"))              // 16
                + " ref=" + u.objectFieldOffset(A.class.getDeclaredField("ref")));        // 24
        System.out.println("byte[].baseOffset=" + u.arrayBaseOffset(byte[].class)         // 16
                + " long[].scale=" + u.arrayIndexScale(long[].class)                      // 8
                + " OnlyRef.a=" + u.objectFieldOffset(OnlyRef.class.getDeclaredField("a"))); // 压缩 12 / 不压缩 16

        System.out.println("maxHeap=" + Runtime.getRuntime().maxMemory() / 1024 / 1024 + "MB");
        if (args.length > 0 && args[0].equals("soe")) {
            try { recurse(); } catch (StackOverflowError e) {
                System.out.println("StackOverflowError at depth=" + depth);               // -Xss 越小越浅
            }
        }
        if (args.length > 0 && args[0].equals("oom")) {
            try {
                List<long[]> keep = new ArrayList<>();
                while (true) keep.add(new long[1024 * 1024]);                             // 8MB/次
            } catch (OutOfMemoryError e) { System.out.println("OOM: " + e.getMessage()); }
        }
    }
}
```

```bash
javac -encoding UTF-8 --add-exports jdk.unsupported/sun.misc=ALL-UNNAMED JvmProbe.java
java --add-exports jdk.unsupported/sun.misc=ALL-UNNAMED JvmProbe

# 看默认值：压缩指针、TLAB、逃逸分析、TenuringThreshold
java -XX:+PrintFlagsFinal -version | grep -E 'UseCompressedOops|UseTLAB|DoEscapeAnalysis|MaxTenuringThreshold'
# PowerShell 用 Select-String 代替 grep

# 验证栈深度受 -Xss 影响 / 堆 OOM
java -Xss256k --add-exports jdk.unsupported/sun.misc=ALL-UNNAMED JvmProbe soe
java -Xmx16m --add-exports jdk.unsupported/sun.misc=ALL-UNNAMED JvmProbe oom

# 关掉压缩指针：OnlyRef.a 的偏移从 12 变成 16，引用从 4B 变 8B
java -XX:-UseCompressedOops --add-exports jdk.unsupported/sun.misc=ALL-UNNAMED JvmProbe
```

**实测输出**：`x=12 y=16 ref=24`、`byte[].baseOffset=16 long[].scale=8 OnlyRef.a=12`；加 `-XX:-UseCompressedOops` 后 `OnlyRef.a=16`；`-Xss256k` 时 `StackOverflowError at depth≈3900`（随栈帧大小浮动）；`-Xmx16m` 时 `OOM: Java heap space`。

---

## 高频错误（面试官最爱抓的）

| 错误说法 | 正确说法 |
|---|---|
| 「方法区就是永久代」 | JDK 8 起是元空间，在本地内存，不在堆里 |
| 「字符串常量池在元空间」 | 在**堆**里（JDK 7 起从永久代挪过去） |
| 「对象一定分配在堆上」 | 逃逸分析后可栈上分配/标量替换，根本不在堆 |
| 「栈溢出是 OOM」 | `StackOverflowError` 是 Error；`-Xss` 越小越容易溢出 |
| 「堆越大越好」 | 超过 32GB 压缩指针失效，引用翻倍，可能更慢 |
| 「对象头只有 8 字节 Mark Word」 | 还有 4B 类指针（压缩）= 12B，数组再加 4B 长度 |
| 「GC 遍历栈找引用」 | 靠 safepoint 的 OopMap 精确定位，不解释整栈 |

---

## 关联文件

- 广度版（60 秒能答）：[Java基础与并发](../../03-java/Java基础与并发.md) 的 JVM 内存区域小节
- 同层追问：[垃圾回收 GC](./06-垃圾回收GC.md)（本文的 OopMap/safepoint/对象布局是 GC 的前置）｜[类加载与双亲委派](./07-类加载与双亲委派.md)（元空间里存的就是它加载的类元数据）
- 典型场景：实习项目里 `OutOfMemoryError: Java heap space` 先看 `-Xmx` 和泄漏（导出堆 dump 用 MAT 找支配树）；`Metaspace` OOM 多半是反射/动态代理/热部署生成类太多（见 [泛型擦除与反射](./04-泛型擦除与反射.md) 的 inflation）；接口 P99 抖动要看 safepoint 与 GC 停顿（见 06）
- 面试延伸：虚拟线程（Java 21）把栈帧放到堆上，但「栈帧」「safepoint」的概念不变

> **自测标准**：能画出对象头 12 字节的组成、说出压缩指针 32GB 分水岭的推导、讲清 OopMap 为什么让 GC 变快，并跑通 `JvmProbe` 三种模式的输出，算过关。
