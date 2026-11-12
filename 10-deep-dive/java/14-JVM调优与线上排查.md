# JVM 调优与线上排查（OOM / GC / CPU / 容器）

> 面试权重：5/5　｜　追问深度：**L5（GC 日志语义 + safepoint + 容器 cgroup 与 JIT deopt）**
> 一句话定位：调优题的真正考法不是背参数，而是「线上 CPU 100% 你怎么办」「堆内存没满为什么进程被杀了」。答案要落到**工具链路（jstack/jmap/MAT/Arthas）+ 现象分类（8 类 OOM）+ 容器边界（cgroup、MaxRAMPercentage、OOMKilled）**。这套能力直接对应你实习里「接口超时、线程池打满、容器重启」的真实排查。

**本文件用法**：从 L1 往下读，每读完一层合上书自问自答。**停在答不出的那一层，就是你的真实水平线。**
[返回深度追问索引](../00-索引.md)

---

## L1 一句话答案（10 秒能说出口）

先分类再动手：**CPU 高**用 `top -Hp` 找线程再 `jstack` 对 `nid`；**内存涨**用 `jcmd GC.class_histogram` / `jmap -dump` + MAT 看支配树；**GC 频繁**看 `-Xlog:gc*` 的停顿与回收效率。容器里最大坑是 **`-Xmx` 不等于进程内存**：JVM 还有元空间、线程栈、直接内存、代码缓存，超了 cgroup 上限就被内核 OOM Killer 杀掉（K8s 里是 `OOMKilled`，退出码 137），此时 JVM 根本来不及打 OOM 日志。

---

## L2 原理层：8 类 OOM 与对应现场

| 类型 | 典型触发 | 现场特征 / 复现方式 |
|---|---|---|
| `Java heap space` | 对象太多/泄漏 | `-Xmx16m` 循环 `new long[1MB]`（实测复现）；堆 dump 里某类占比异常 |
| `GC overhead limit exceeded` | 存活率高、GC 忙但回收很少 | 堆几乎满 + 频繁 Full GC，`UseGCOverheadLimit` 默认开 |
| `Metaspace` | 动态生成类过多（CGLIB/反射/热部署） | `-XX:MaxMetaspaceSize=32m` + 大量生成代理类；`METASPACE` 日志 |
| `Compressed class space` | 类元数据超过压缩类空间 | `CompressedClassSpaceSize` 默认 1GB（实测 flag），爆了要调大 |
| `Direct buffer memory` | NIO/Netty 堆外泄漏 | `-XX:MaxDirectMemorySize=8m` + 循环 `allocateDirect`（实测 `Cannot reserve 1048576 bytes of direct buffer memory`） |
| `unable to create new native thread` | 线程数超系统限制 | `-Xss` 太大或 `ulimit -u` 太小；一个连接一个线程的 BIO 模型最容易踩 |
| `Requested array size exceeds VM limit` | 数组长度超上限 | 实测 `new byte[Integer.MAX_VALUE]` 与 `[MAX-1]` 抛此错，`[MAX-2]` 才变成 heap space |
| `Out of swap space` / `kill process or sacrifice child` | 进程整体内存超限 | 容器里就是 `OOMKilled`（137），JVM 无机会打日志 |

**排查第一步永远是区分「堆内还是堆外」**：堆内能 dump 出来看，堆外（直接内存、线程栈、元空间、代码缓存）dump 里看不到，要看 `pmap`/`NMT`/`BufferPoolMXBean`/监控。

---

## L3 底层层：日志、工具链、容器与 JIT

### 3.1 GC 日志怎么读（G1，实测输出）

```
[0.006s][info][gc] Using G1
[0.052s][info][gc] GC(0) Pause Young (Normal) (G1 Evacuation Pause) 14M->2M(32M) 1.417ms
```

字段含义：`GC(0)` 第几次 GC，`Pause Young (Normal)` 停顿类型，`(G1 Evacuation Pause)` 触发原因（复制式回收），`14M->2M(32M)` = 回收前 14M、回收后 2M、堆总 32M，`1.417ms` 本次停顿。**看三个指标**：停顿是否超 SLA、回收效率（前→后降幅）、频率（1 秒多次说明分配速率过高）。

G1 关键参数（默认值实测）：`-XX:MaxGCPauseMillis=200`（目标不是保证）、`-XX:G1HeapRegionSize`（实测 2MB，由堆/2048 推）、`-XX:InitiatingHeapOccupancyPercent`（触发并发标记的堆占用，默认 45）、`-XX:ConcGCThreads`（并发标记线程）、`-XX:G1NewSizePercent/G1MaxNewSizePercent`。**调优顺序：先降分配速率，再调停顿目标，最后才动堆大小。**

### 3.2 内存泄漏定位：三件套

```bash
# 1) 看谁最多（在线、快、有开销，慎用 live）
jcmd <pid> GC.class_histogram | head -30
# 2) 抓堆转储（线上用 -XX:+HeapDumpOnOutOfMemoryError 自动抓更稳）
jmap -dump:live,format=b,file=/tmp/heap.hprof <pid>
# 3) 用 MAT 打开：Histogram -> 找可疑类 -> Dominator Tree 看支配大小 -> Path to GC Roots（排除弱引用）
```

实测 `jcmd <pid> GC.class_histogram` 输出 `[B`（byte[]）、`[C`（char[]）排前面很常见，单看不够，要算「保留大小」（retained size）；`-XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/data/dump` 是必须提前配的。OOM 后先看 dump 里**占大头的类是谁的字段引用着**，常见嫌疑：本地缓存无上限、`ThreadLocal` 没 remove、连接/流没关、监听器注册未注销。

### 3.3 CPU 100%：从线程号到代码行

```bash
top -Hp <pid>                  # 找出占 CPU 最高的线程 TID（十进制）
printf '%x\n' <TID>            # 转 16 进制，得到 nid
jstack <pid> | grep -A 30 'nid=0x<NID>'   # 或 jcmd <pid> Thread.print
```

关键点：`jstack` 里的 `nid` 是**16 进制**，`top -Hp` 给的是十进制，必须先转换——这是「为什么找不到对应线程」的头号原因。实测 `jcmd <pid> Thread.print` 输出里线程行格式是 `"busy-worker" #21 prio=5 os_prio=0 cpu=... tid=0x... nid=0x8f20 runnable`，`nid` 就是 TID。看到 `RUNNABLE` 且栈顶是自己业务方法 = 死循环/大计算；大量 `BLOCKED` 看锁持有者；`WAITING` 在连接池/队列上 = 下游慢。

### 3.4 Arthas：不用重启的在线诊断

| 命令 | 用途 | 备注 |
|---|---|---|
| `dashboard` | 整体面板（线程/GC/堆） | 先看全局 |
| `thread -n 3` | CPU 最高的 3 个线程栈 | 等价 top -Hp + jstack |
| `thread -b` | 找阻塞其他线程的锁持有者 | 排查死锁/锁竞争 |
| `trace <类> <方法>` | 方法调用耗时分布（traceId 链路） | 定位接口哪一步慢 |
| `watch <类> <方法> '{params, returnObj}'` | 观察入参返回值 | 不改代码复现问题 |
| `tt` / `ognl` / `sc` / `sm` | 记录调用、执行表达式、查类/方法 | 线上热修辅助 |

原理：`arthas` 通过 **attach 到目标 JVM**（Java Agent + `Instrumentation`）在运行时做字节码增强，所以能无侵入观测；这也是它比「改代码加日志再发版」快的原因，但注意 `trace` 会带来额外开销，生产要短时使用。

### 3.5 JIT：分层编译与去优化（deopt）

- 分层编译（`TieredCompilation=true`，实测默认）：方法先被 C1 快速编译（带 profiling），热点方法再被 C2 优化成机器码；`TieredStopAtLevel=4` 表示允许到 C2。
- `-XX:+PrintCompilation` 实测输出格式：`时间戳 编译ID 层级 方法名 (字节数)`，例如 `22  3  3  java.lang.StringLatin1::hashCode (42 bytes)`；出现 `made not entrant` 表示该编译版本被废弃（发生了去优化/重新编译）。
- deopt 常见原因：类层次变化（新类加载让虚调用假设失效）、`uncommon trap`（假设的分支走了另一条）、数组越界假设失败、`@Contended`/偏向锁撤销。deopt 本身正常，但**高频 deopt** 会让 CPU 升高、接口抖动。
- 与排查的关系：`-XX:+PrintCompilation` 发现大量 `made not entrant` + `top` 显示编译线程吃 CPU，说明代码类型不稳定（比如大量反射、动态代理、频繁变化的实现类）。

### 3.6 容器：为什么 `-Xmx` 配了还是被 OOMKilled

- JVM 进程 RSS = 堆 + 元空间 + 线程栈（`-Xss` × 线程数）+ 直接内存 + 代码缓存（实测 `ReservedCodeCacheSize=240MB` 左右，ergonomic）+ GC 自身结构。**只算堆必然超。**
- 容器感知：JDK 10+ 默认读取 cgroup 限额来算最大堆。注意 **JDK 17 实测不接受 `-XX:+UseContainerSupport`**（会报 `Unrecognized VM option`），容器支持是默认行为；JDK 8u191+ 才需要显式打开。
- `-XX:MaxRAMPercentage`（实测默认 25）：容器限额的 25% 作为最大堆；实测传 `-XX:MaxRAMPercentage=50` 后 `MaxHeapSize` 从 4.2G 变 8.4G。容器里更推荐用百分比而不是写死 `-Xmx`，否则换规格要改配置。
- `OOMKilled` 判断：`kubectl describe pod` 看 `Last State: Terminated, Reason: OOMKilled, Exit Code: 137`；`dmesg` 里能看到内核 OOM killer 的日志。**被内核杀时 JVM 来不及执行任何 OOM 处理**，所以不会生成 heap dump——这就是「没日志」的原因。
- 两个兜底参数：`-XX:+HeapDumpOnOutOfMemoryError`（实测默认 false，必须显式开）、`-XX:+ExitOnOutOfMemoryError`（实测默认 false，让 JVM 自己退出交给编排重启，比僵死更好）。

---

## L4 追问树（面试官一路往下问，你能撑到第几层？）

> 规则：从上往下问。**第 1-3 层是应届生必备，第 4-6 层拉开差距，第 7 层以后是加分。**

### 第 1 层｜线上接口突然变慢，你怎么排查？
**答**：先分层定位：看监控的 RT/QPS/错误率，确认是全部接口还是单个接口；`top -Hp` 看 CPU、`free`/容器监控看内存、`jstack` 看线程状态。如果大量线程 BLOCKED/WAITING，多半是锁竞争、连接池耗尽或下游慢；如果是 GC 停顿，看 GC 日志；如果是单线程打满，用 `thread -n`/`top -Hp` 定位到方法。

### 第 2 层｜CPU 100% 怎么精确定位到代码行？
**答**：`top -Hp <pid>` 找高 CPU 的十进制 TID → `printf '%x'` 转 16 进制 nid → `jstack <pid> | grep -A 30 nid=0x...` 看栈。`jstack` 的 nid 是 16 进制，不转换就永远对不上，这是最常见的坑。Arthas 的 `thread -n 3` 直接给结果，原理一样。

### 第 3 层｜内存泄漏怎么定位？
**答**：三步：`jcmd GC.class_histogram` 看哪个类实例数/字节数异常；`jmap -dump:live` 抓 heap dump；用 MAT 看 Dominator Tree（按 retained size 排序）和 Path to GC Roots，找到「谁还引用着它」。常见泄漏源是本地缓存无上限、ThreadLocal 未 remove、集合只加不减、流/连接未关闭。

### 第 4 层｜8 类 OOM 怎么快速区分？
**答**：看异常 message 就够：`Java heap space` 是堆内；`GC overhead limit exceeded` 是堆满且 GC 无效；`Metaspace`/`Compressed class space` 是类太多；`Direct buffer memory` 是堆外；`unable to create new native thread` 是线程数超限；`Requested array size exceeds VM limit` 是数组长度超上限；容器里 `OOMKilled/137` 是进程整体超 cgroup，属于内核杀进程。

### 第 5 层｜为什么堆没满，进程却被杀了？
**答**：因为进程 RSS 不只是堆。还有元空间、线程栈（`-Xss × 线程数`，线程一多就是几个 G）、直接内存、代码缓存、GC 结构。容器 cgroup 限制的是整个进程的 RSS，超了内核 OOM Killer 直接杀。所以容器里要用 `-XX:MaxRAMPercentage` 留余量，或者显式限制 `-XX:MaxDirectMemorySize`、控制线程数。

### 第 6 层｜jstack 里看不到高 CPU 的线程怎么办？
**答**：几种情况：① nid 没转 16 进制，对不上；② 高 CPU 的是**编译线程**（C1/C2 CompilerThread）或 GC 线程，栈里根本没有业务方法——这时看 `PrintCompilation` 或 GC 日志；③ 线程已经结束，抓取时的快照里没有，要连续多次抓；④ 容器里 `jstack` 抓的是 JVM 内线程，若 CPU 在外部进程（sidecar）则要换工具。

### 第 7 层｜Arthas 为什么能不改代码就 trace？
**答**：它 attach 到目标 JVM（Java Agent + `Instrumentation.retransformClasses`），在运行时对目标方法做字节码增强，把耗时/入参埋点织进去，所以不需要改代码、不需要重启。代价是有性能开销、且增强的类如果被重新定义可能失效。

### 第 8 层｜JIT 分层编译是什么？deopt 是什么？
**答**：JVM 先用 C1 把方法编译成带 profiling 的机器码（快启动），热点方法再交给 C2 做深度优化（`TieredCompilation` 默认开，`TieredStopAtLevel=4` 允许到 C2）。deopt 是已编译代码的前提假设失效（类层次变化、uncommon trap、类型变化）时，回退到解释执行或重新编译；`-XX:+PrintCompilation` 里看到 `made not entrant` 就是它的痕迹。高频 deopt 会拖高 CPU。

### 第 9 层｜容器里的 JVM 该怎么配参数？
**答**：① 不要写死 `-Xmx`，用 `-XX:MaxRAMPercentage=60~70` 留出堆外与系统开销；② 显式 `-XX:MaxDirectMemorySize`（Netty/MinIO 场景尤其）；③ 配 `-XX:+HeapDumpOnOutOfMemoryError` + dump 路径挂载；④ 开 `-XX:+ExitOnOutOfMemoryError` 让编排重启；⑤ 注意 JDK 17 上 `-XX:+UseContainerSupport` 已不被接受，容器感知默认开；CPU 用 `-XX:ActiveProcessorCount`（实测默认 -1，让 JVM 自己按 cgroup 算）。

### 第 10 层｜GC 日志里 Full GC 的原因怎么区分？
**答**：G1 的 Full GC 常见原因：`to-space exhausted`（存活对象放不下，Evacuation 失败）、`Humongous allocation`（大对象分配失败）、`Metadata GC Threshold`（元空间触发）。看到 `Pause Full (G1 Compaction Pause)` 说明已经退化成整堆压缩，属于危险信号，要查内存泄漏或调大堆/调低 IHOP。

### 第 11 层｜怎么区分「内存泄漏」和「堆不够」？
**答**：看 Full GC 后的**残留量**：如果每次 Full GC 后已用堆都降不下来且持续上升，是泄漏；如果 GC 后能降下去但很快又涨满，是流量/缓存太大或堆太小。泄漏要在 dump 里找支配链，堆不够就调堆或做缓存治理。

### 第 12 层（终局）｜线上排查工具到底靠什么内核/JVM 机制？
**答**：`jstack/jmap` 靠 JVM 的 **attach 机制**（`AttachListener`，Unix domain socket `/tmp/.java_pid<pid>`），attach 后执行诊断命令需要**停在 safepoint**——所以抓 dump 会让应用短暂停顿（dump 越大越久），这也是为什么大堆 dump 要谨慎。`Arthas` 额外用 `Instrumentation` + 字节码增强。`async-profiler`/`JFR` 则走采样：JFR 用 JVM 内置事件（低开销），`async-profiler` 在 Linux 上用 `perf_events` + `AsyncGetCallTrace` 拿栈，**不受 safepoint 偏差影响**（这是它比 `jstack` 采样更准的原因）。再往下就是 `ptrace`/`/proc/<pid>` 与内核计数器，一条链从 Java 工具一直通到操作系统。

---

## L5 名词拆解表（"每个名词都拆开"）

| 名词 | 是什么 | 为什么存在 | 面试追问点 |
|---|---|---|---|
| heap dump | 堆快照（hprof 文件） | 离线分析谁占内存 | 为什么 dump 会 STW、大堆怎么办 |
| retained size | 对象被回收后能释放的总大小 | MAT 判断真正大头 | 和 shallow size 的区别 |
| dominator tree | 支配关系树 | 找「谁撑着内存」 | 为什么不是简单的引用链 |
| GC Root Path | 到 GC Roots 的引用链 | 找泄漏源 | 怎么排除弱引用干扰 |
| `jcmd` | 统一诊断命令入口 | 替代 jmap/jstack 的旧命令 | 生产为什么优先 jcmd |
| `nid` / TID | JVM 线程的本地线程号（16 进制） | 和 top 的十进制对上 | 为什么要进制转换 |
| Arthas | 在线诊断工具（attach agent） | 不改代码看运行态 | trace/watch 原理与开销 |
| JFR | JDK 内置低开销事件记录 | 生产级飞行记录 | 与 async-profiler 的差别 |
| Tiered Compilation | C1 + C2 分层编译 | 兼顾启动与峰值性能 | 层级、profiling、TieredStopAtLevel |
| deopt | 优化代码失效回退 | 保证正确性 | `made not entrant` 怎么读 |
| OOMKilled | 容器被内核 OOM Killer 杀 | cgroup 限额兜底 | 为什么没有 OOM 日志 |
| `MaxRAMPercentage` | 按容器限额算最大堆 | 容器里别写死 `-Xmx` | 默认 25，该配多少 |
| `ExitOnOutOfMemoryError` | OOM 后主动退出 | 交给编排重启 | 与僵死进程的取舍 |
| safepoint | 线程统一停下的检查点 | 诊断/GC 需要一致视图 | jstack/dump 为什么要停 |

---

## 代码验证（`OomProbe.java`，JDK 17 编译运行通过）

```java
import java.nio.ByteBuffer;
import java.util.*;

public class OomProbe {
    public static void main(String[] a) {
        String mode = a.length == 0 ? "heap" : a[0];
        try {
            if (mode.equals("heap")) {
                List<long[]> keep = new ArrayList<>();
                while (true) keep.add(new long[1024 * 1024]);          // 8MB/次
            } else if (mode.equals("direct")) {
                List<ByteBuffer> keep = new ArrayList<>();
                while (true) keep.add(ByteBuffer.allocateDirect(1024 * 1024));
            } else if (mode.equals("array")) {
                byte[] b = new byte[Integer.MAX_VALUE];
                System.out.println("allocated " + b.length);
            } else if (mode.equals("thread")) {
                while (true) new Thread(() -> {
                    try { Thread.sleep(60_000); } catch (InterruptedException ignored) { }
                }).start();
            }
        } catch (OutOfMemoryError e) {
            System.out.println("OutOfMemoryError: " + e.getMessage());
        }
    }
}
```

```bash
javac -encoding UTF-8 OomProbe.java

java -Xmx16m OomProbe heap          # OutOfMemoryError: Java heap space
java -XX:MaxDirectMemorySize=8m OomProbe direct   # Cannot reserve ... bytes of direct buffer memory
java -Xmx64m OomProbe array         # Requested array size exceeds VM limit（MAX-2 才会变成 heap space）
java -Xss256k OomProbe thread       # unable to create new native thread（受系统线程上限影响）
```

**实测输出**：
`-Xmx16m` → `OutOfMemoryError: Java heap space`；
`-XX:MaxDirectMemorySize=8m` → `OutOfMemoryError: Cannot reserve 1048576 bytes of direct buffer memory (allocated: 8388608, limit: 8388608)`；
`new byte[Integer.MAX_VALUE]` → `OutOfMemoryError: Requested array size exceeds VM limit`（实测 `Integer.MAX_VALUE - 1` 同样抛它，`- 2` 才变成 heap space）。

配套命令行（实测可用）：

```bash
jcmd <pid> GC.class_histogram     # 等价 jmap -histo:live，但更稳
jcmd <pid> GC.heap_info           # 实测输出：garbage-first heap total/used、region size 2048K、Metaspace used
jcmd <pid> Thread.print           # 等价 jstack，nid 为 16 进制
jcmd <pid> VM.flags               # 看实际生效的 flag（含 G1、压缩指针、堆大小）
java -XX:+PrintFlagsFinal -version | grep MaxRAMPercentage   # 实测默认 25
```

---

## 高频错误（面试官最爱抓的）

| 错误说法 | 正确说法 |
|---|---|
| 「OOM 都是内存泄漏」 | 也可能只是堆/元空间/直接内存配小了，先看 GC 后残留 |
| 「配了 -Xmx 就不会 OOMKilled」 | RSS 还包含元空间、线程栈、直接内存、代码缓存 |
| 「jstack 直接能找到高 CPU 线程」 | nid 是 16 进制，必须先转换 |
| 「OOMKilled 会生成 heap dump」 | 内核直接杀进程，JVM 无机会执行任何处理 |
| 「JDK 17 要加 -XX:+UseContainerSupport」 | 实测该 flag 已被拒绝，容器感知默认开启 |
| 「Arthas 是改代码实现的」 | attach + Instrumentation 字节码增强，无侵入但有开销 |
| 「Full GC 频繁就调大堆」 | 先区分泄漏（GC 后降不下来）与堆不够 |

---

## 关联文件

- 广度版（60 秒能答）：[Java基础与并发](../../03-java/Java基础与并发.md)；[SpringBoot 与后端工程](../../03-java/SpringBoot与后端工程.md)（线程池/连接池配置）
- 同层追问：[垃圾回收 GC](./06-垃圾回收GC.md)（GC 日志与收集器原理）｜[JVM 内存区域](./05-JVM内存区域.md)（对象布局与 TLAB）｜[IO 模型与 NIO](./13-IO模型与NIO.md)（堆外内存与 Netty 泄漏）
- 典型场景：报告平台 跑在 Docker 里，最容易踩的就是「容器限额 512Mi 但 `-Xmx` 写了 512m」导致 OOMKilled——按 `MaxRAMPercentage=60~70` 配并留出堆外；SSE 长连接多时线程栈（`-Xss × 线程数`）会吃掉非堆内存；MinIO 上传下载用直接内存，要配 `MaxDirectMemorySize`；PostgreSQL 连接池耗尽的表现是线程大量 `WAITING`，用 `jstack` + `thread -b` 能直接看到
- 延伸：CPU 100% 的「编译线程吃满」「deopt 频繁」这类现象，在 [ConcurrentHashMap](./12-ConcurrentHashMap.md) 的高并发场景里也常见

> **自测标准**：能说出 8 类 OOM 的 message 与复现命令、`top -Hp` 到 `jstack` 的完整链路（含 nid 进制转换）、容器里为什么会被 OOMKilled 以及三个兜底参数，并跑通 `OomProbe` 的三种模式，算过关。
