# String 与字符串常量池（String & Constant Pool）

> 面试权重：5/5　｜　追问深度：**L5（HotSpot StringTable + G1 String Dedup）**
> 一句话定位：`String` 是 Java 里唯一被 JVM 特殊照顾的类——常量池、`intern()`、压缩存储（coder）、字符串去重，四层机制叠在同一个类上。面试从 `==` 一路追到「常量池在哪个内存区域」，答错一步就露底。

**本文件用法**：从 L1 往下读，每读完一层合上书自问自答。**停在答不出的那一层，就是你的真实水平线。**
[返回深度追问索引](../00-索引.md)

---

## L1 一句话答案（10 秒能说出口）

`String` 是不可变类（JDK 9 起底层是 `byte[] value + byte coder`），字面量进堆里的字符串常量池；`new String("a")` 会在堆上另建对象，所以 `==` 为 false；`intern()` 把字符串尝试放进常量池并返回池中引用；运行期 `+` 拼接在 JDK 9+ 编译成 `invokedynamic makeConcatWithConstants`，不是 StringBuilder。

---

## L2 原理层：不可变 + 常量池 + 拼接，三条线

### 2.1 不可变的三层含义

```java
public final class String {                       // ① 类 final，不能被继承改写行为
    @Stable
    private final byte[] value;                   // ② 字段 final，引用不可变
    private final byte coder;                     // ③ JDK9+：0=LATIN1, 1=UTF16
    private int hash;                             // ④ 惰性缓存 hashCode
}
```

不可变收益：线程安全（无状态可自由共享）、`hashCode` 可缓存（做 HashMap key 快）、常量池可复用同一对象、可作为 `switch`/注解参数等编译期常量。

### 2.2 `==` 结果的记忆表（必须能秒判）

| 写法 | `==` 结果 | 原因 |
|---|---|---|
| `"a" == "a"` | true | 同一常量池对象 |
| `new String("a") == "a"` | **false** | 堆上新对象 vs 池中对象 |
| `new String("a").intern() == "a"` | true | intern 返回池中引用 |
| `"a" + "b" == "ab"` | true | 编译期常量折叠 |
| `s1 + s2 == "ab"`（局部变量） | **false** | 运行期拼接生成新对象 |
| `final String fa = "a"; fa + "b" == "ab"` | true | final 局部变量是「常量变量」，参与折叠 |

### 2.3 字符串常量池（StringTable）在哪

- JDK 6：永久代（PermGen）里，池满会 `PermGen space OOM`。
- **JDK 7 起：移到堆**。原因是永久代太小、`intern()` 大量使用时极易 OOM；挪到堆后能被 GC 正常回收，也能和普通对象统一管理。
- JDK 8 起永久代被元空间取代，但字符串常量池**仍在堆中**（很多人答成「在元空间」，错）。

---

## L3 底层层：coder、intern、indy 拼接、去重

### 3.1 JDK 9 的压缩字符串：`char[]` → `byte[] + coder`

JDK 8 的 `char[]` 每字符固定 2 字节，纯 ASCII 也浪费一半。JDK 9 的 **Compact Strings（JEP 254）** 改成：

| coder | 编码 | 每字符 | 适用 |
|---|---|---|---|
| 0 | LATIN1 | 1 字节 | 所有字符 ≤ 0xFF（ASCII、西欧字母） |
| 1 | UTF16 | 2 字节 | 含中文等 BMP 外/大于 0xFF 的字符 |

**实测（反射读私有字段）**：`"hi"` → `coder=0`、`value.length=2`；`"你好"` → `coder=1`、`value.length=4`。也就是说中文串的字节数组长度是字符数的 2 倍——这是「`String.length()` 返回字符数、`getBytes().length` 返回字节数」的底层原因。

`StringLatin1` / `StringUTF16` 是两个内部工具类，分别实现 `indexOf`/`compareTo`/`toUpperCase` 等，`coder` 决定走哪个。拼接、`substring` 时如果两种 coder 混合，会升级成 UTF16。

### 3.2 `intern()` 的真实语义（JDK 7+ 与 JDK 6 不同）

```
intern() 执行流程（JDK 7+）：
  1. 在 StringTable 里查 equals 相等的字符串
  2. 命中  → 返回池中那个对象（注意：不是 this）
  3. 未命中 → 把【this 的引用】放进池，返回 this
```

JDK 6 的区别：未命中时是把字符数组**复制**一份进永久代，返回复制品；JDK 7+ 直接存堆上对象的引用，省一次拷贝。

**实测**：`new String("a").intern() == "a"` → `true`；而 `new String("a") == new String("a").intern()` → `false`（因为 `"a"` 字面量早就进池了，intern 返回的是池里那个，不是 `new` 出来的）。

### 3.3 `+` 拼接的编译产物：JDK 8 与 JDK 9+ 完全不同

```java
String concat(String a, String b) { return a + b; }
```

**JDK 8**：编译成 `new StringBuilder().append(a).append(b).toString()`，一次拼接一次分配。
**JDK 9+**：编译成 `invokedynamic #x: makeConcatWithConstants`（JEP 280），由 `StringConcatFactory` 在**首次执行时**生成最优的拼接 MethodHandle，之后直接调用——不再经过 StringBuilder。

**实测 `javap -c`**：

```
static java.lang.String concat(java.lang.String, java.lang.String);
   2: invokedynamic #7,  0   // InvokeDynamic #0:makeConcatWithConstants:(...)Ljava/lang/String;
```

但**循环里** `s += i` 仍然糟糕：每次迭代都产生一个新 String + 新对象，复杂度 O(n²)。正确写法是循环外一个 `StringBuilder`（预设容量），最后 `toString()` 一次。

### 3.4 G1 的 String Deduplication（去重，不是去重对象）

- 开关：`-XX:+UseStringDeduplication`，**只有 G1 支持**，默认关闭（`-XX:+PrintFlagsFinal` 实测 `UseStringDeduplication = false {default}`）。
- 它去重的是**底层的 `byte[]`**，不是 String 对象：多个内容相同的 String 各自是不同对象，但可以共享同一个 byte[]。
- 原理：G1 在 Young GC 时把「age 达到 `-XX:StringDeduplicationAgeThreshold`（默认 3）」的 String 放进队列，后台线程对队列里的 String 两两算 hash 并比较，若内容相同就把 `value` 指针指向同一个 byte[]（需要改 `value` 引用，所以这一步要 STW 或安全点）。
- 适用：大量重复长字符串（日志、JSON 报文、地区名）。代价是额外的 hash 计算与内存占用，**不适合短字符串**。

### 3.5 为什么 `hashCode` 能缓存

`String.hash` 是普通 int 字段，首次计算后写入，之后直接返回。HashMap 定位时对 String key 反复调 `hashCode()`，缓存让它变成一次字段读。这也是「String 适合作 Map key」的原因之一。**但这也意味着 `hash` 字段不是 final——并发首次计算可能重复算，结果一致所以无害。**

---

## L4 追问树（面试官一路往下问，你能撑到第几层？）

> 规则：从上往下问。**第 1-3 层是应届生必备，第 4-6 层拉开差距，第 7 层以后是加分。**

### 第 1 层｜String 为什么不可变？
**答**：`class` 是 final 不能被继承改写，`value` 是 final 字段且不提供任何修改方法；JDK 9 后是 `byte[]` + coder。不可变换来线程安全、hashCode 可缓存、常量池可共享、可安全做 Map key。

### 第 2 层｜不可变是不是绝对的？反射能改吗？
**答**：不是绝对的。用 `Field.setAccessible(true)` 反射改 `value` 数组内容，或者用 `Unsafe` 直接写内存，都能改（`value` 字段本身 final，但数组元素不是）。JDK 17 模块化后改 java.base 的私有字段需要 `--add-opens java.base/java.lang=ALL-UNNAMED`。面试标准答法是「语言层面不可变，但反射/Unsafe 可以破坏——Java 的不可变是约定不是安全边界」。

### 第 3 层｜`new String("a")` 创建几个对象？
**答**：取决于常量池里有没有 `"a"`。没有则是 2 个（池中一个 + 堆上一个），已有则 1 个（只创建堆对象）。注意 `new String("a")` 这个 `"a"` 参数本身就要先保证池里存在，所以**永远不会少于 1 个**。

### 第 4 层｜字符串常量池到底在哪个内存区域？
**答**：JDK 6 在永久代；**JDK 7 起挪到堆**；JDK 8 永久代被元空间取代，但常量池仍在堆。很多人的错误答案是「方法区/元空间」——那存的是类元数据，不是一个东西。

### 第 5 层｜JDK 7 为什么把常量池从永久代移到堆？
**答**：永久代大小固定（`-XX:MaxPermSize`），`intern()` 用量大时极易 `OutOfMemoryError: PermGen space`；而且永久代的回收效率低、触发条件苛刻。移到堆后字符串能被正常的 Minor GC 回收，也省去了「永久代调多大」这个运维难题。

### 第 6 层｜`intern()` 在 JDK 6 和 JDK 7+ 有什么区别？
**答**：命中时都返回池中已有对象。未命中时，JDK 6 会把字符内容**复制**一份到永久代并返回副本；JDK 7+ 直接把当前对象的**引用**放进池并返回 `this`。后者省一次拷贝，也让「intern 后立即丢弃原引用」更安全。

### 第 7 层｜`"a"` + `"b"` 在编译期就合并了，那 `final String` 参与拼接呢？
**答**：`final` 修饰的**局部变量/字段**如果编译期能确定值，就属于「常量变量（constant variable）」，编译器仍然折叠。所以 `final String fa = "a"; String ab = fa + "b";` 得到的 `ab` 直接指向池里的 `"ab"`（实测 `==` 为 true）。变数不是 final 或值来自方法调用，就只能运行期拼接。

### 第 8 层｜为什么 JDK 9 要把 `char[]` 换成 `byte[]` + coder？
**答**：Java 里绝大多数字符串是 LATIN1 可表示的（英文、数字、URL、JSON key）。`char[]` 固定 2 字节/字符，纯 ASCII 浪费一半内存。改成 `byte[]` + `coder` 后，LATIN1 字符串堆占用减半、缓存命中率提升，堆整体小 5%~15%。代价是每次操作要按 coder 分派（`StringLatin1`/`StringUTF16`），并要处理两种 coder 混合时的升级。

### 第 9 层｜JDK 9+ 的 `+` 用 invokedynamic，那是不是比 StringBuilder 快？循环里能放心用吗？
**答**：对于**固定个数的少量拼接**，indy 版本由 `StringConcatFactory` 生成一次 MethodHandle，之后免去 StringBuilder 的创建开销，通常更快。但循环里 `s += i` 每次迭代仍要创建一个新的 String，indy 优化不掉 O(n²) 的复制——所以循环内必须显式用 `StringBuilder`。JDK 21 的字符串模板（String Templates）也只是语法糖，仍是 preview。

### 第 10 层（终局）｜HotSpot 里 `intern()` 和 StringTable 到底是什么？
**答**：`StringTable` 是 HotSpot 里的一个**原生哈希表**（C++ 实现，`StringTable::lookup` / `intern`），条目是 `oop`（堆对象引用），用 `OopStorage` 管理弱引用根，所以池里的字符串如果没人引用可以被 GC 清掉（否则就是内存泄漏）。`String.intern()` 是 `native` 方法，落到 `StringTable::intern(String, TRAPS)`：先按 hash 与 equals 查，命中直接返回对应 oop；未命中则把当前 oop 插表并返回。G1 的字符串去重则是在这个表之外，另起一个 `DedupQueue` + 后台线程比 `byte[]`，只把 `value` 指向同一个数组——两者都不是「合并 String 对象」。

---

## L5 名词拆解表（"每个名词都拆开"）

| 名词 | 是什么 | 为什么存在 | 面试追问点 |
|---|---|---|---|
| `value` | `byte[]`（JDK9+）/ `char[]`（JDK8-） | 存字符内容 | 为什么改成 byte[] |
| `coder` | 0=LATIN1 / 1=UTF16 | 标记 value 的编码，省内存 | 两个 coder 混合拼接会怎样 |
| Compact Strings | JEP 254 的压缩存储 | ASCII 串堆占用减半 | 与 `-XX:-CompactStrings` 的关系 |
| `hash` | 惰性缓存的 hashCode | Map key 高频调用 | 为什么不是 final |
| StringTable | HotSpot 的原生哈希表 | 存放「规范化」的字符串 | 在堆还是元空间 |
| `intern()` | native 方法，规范化入池 | 让相等字符串共享一份 | JDK6 与 JDK7+ 的差别 |
| 常量池 / 运行时常量池 | class 文件常量池在运行期的形态 | 字面量与符号引用 | 它和 StringTable 不是一回事 |
| 常量折叠 | 编译期算出 `"a"+"b"` | 减少运行时开销 | final 局部变量也折叠 |
| `makeConcatWithConstants` | JEP 280 的 indy 拼接引导方法 | 免去 StringBuilder 临时对象 | JDK 8 与 JDK 9+ 产物差异 |
| `StringBuilder` | 可变字符序列（非线程安全） | 循环拼接 | 预设容量、扩容规则 |
| String Deduplication | G1 的 `byte[]` 去重 | 大量重复长字符串省内存 | 只支持 G1、要去重的不是对象 |
| OopStorage | HotSpot 管理 oop 弱引用的容器 | 让 StringTable 条目可被 GC | 池中字符串何时能被回收 |

---

## 代码验证（`StringProbe.java`，JDK 17 编译运行通过）

```java
import java.lang.reflect.Field;

public class StringProbe {
    public static void main(String[] args) throws Exception {
        String lit = "a";
        String heap = new String("a");
        System.out.println("new String(\"a\") == \"a\"      -> " + (heap == lit));            // false
        System.out.println("heap == heap.intern()          -> " + (heap == heap.intern()));   // false
        System.out.println("heap.intern() == \"a\"          -> " + (heap.intern() == lit));    // true

        String ab1 = "ab";
        String ab2 = "a" + "b";              // 编译期折叠
        final String fa = "a";
        String ab3 = fa + "b";               // final 常量变量，仍折叠
        String s1 = "a", s2 = "b";
        String ab4 = s1 + s2;                // 运行期 indy 拼接
        System.out.println("\"ab\" == \"a\"+\"b\"          -> " + (ab1 == ab2));             // true
        System.out.println("\"ab\" == fa+\"b\"            -> " + (ab1 == ab3));              // true
        System.out.println("\"ab\" == s1+s2             -> " + (ab1 == ab4));              // false
        System.out.println("(s1+s2).intern() == \"ab\"  -> " + (ab4.intern() == ab1));       // true

        // 反射看 coder 与底层字节数组长度
        Field coder = String.class.getDeclaredField("coder");
        coder.setAccessible(true);
        Field value = String.class.getDeclaredField("value");
        value.setAccessible(true);
        String en = "hi", cn = "你好";
        System.out.println("coder(\"hi\")=" + coder.getInt(en) + " bytes=" + ((byte[]) value.get(en)).length);  // 0 / 2
        System.out.println("coder(cn)=" + coder.getInt(cn) + " bytes=" + ((byte[]) value.get(cn)).length);      // 1 / 4
    }
}
```

```bash
javac -encoding UTF-8 StringProbe.java
java --add-opens java.base/java.lang=ALL-UNNAMED StringProbe

# 看 JDK 9+ 的拼接产物（不是 StringBuilder）
javac -encoding UTF-8 -d out StringProbe.java && javap -c -p out/StringProbe.class | grep -A2 "String concat"
# 或自己写一个 String c = a + b; 的方法后 javap，应看到 invokedynamic makeConcatWithConstants
```

---

## 高频错误（面试官最爱抓的）

| 错误说法 | 正确说法 |
|---|---|
| 「String 不可变所以一定安全，反射也改不了」 | 反射/Unsafe 能改字节数组内容，语言层不可变 ≠ 安全边界 |
| 「字符串常量池在方法区/元空间」 | JDK 7 起在**堆**里；元空间放的是类元数据 |
| 「`intern()` 会把字符串复制到池里」 | JDK 7+ 存的是引用并返回 this；JDK 6 才复制 |
| 「JDK 9 的 `+` 还是 StringBuilder」 | 编译成 `invokedynamic makeConcatWithConstants` |
| 「循环里用 `+` 有 indy 优化没问题」 | 循环仍是 O(n²)，必须显式 StringBuilder |
| 「String 的 `length()` 就是底层数组长度」 | coder=UTF16 时是数组长度的一半 |
| 「G1 字符串去重会合并 String 对象」 | 只是让 `value` 指向同一个 byte[]，对象还是多个 |

---

## 关联文件

- 广度版（60 秒能答）：[Java基础与并发](../../03-java/Java基础与并发.md) 的 String / 常量池小节
- 同层追问：[HashMap 底层](./01-HashMap.md)（String 是最常用 key，`hashCode` 缓存直接受益）｜[集合体系](./03-集合体系.md)
- 典型场景：Spring Boot 项目里 `@Value("${app.name}")` 的配置值、`application.yml` 的 key、MyBatis 的 SQL 字符串、日志模板都在吃这一页的知识；接口里大量 JSON 字段名都是 LATIN1，Compact Strings 直接决定堆占用
- 面试延伸：字符串常量池的设计可直接对比 [Redis 的 SDS](../../04-database/MySQL与Redis.md)（二进制安全 + 预分配）

> **自测标准**：能讲清「JDK 7 常量池为什么搬到堆」「intern 在 JDK 6/7+ 的差异」「`+` 在 JDK 8 与 9+ 的产物不同」，并跑通 `StringProbe` 的 9 行输出，算过关。
