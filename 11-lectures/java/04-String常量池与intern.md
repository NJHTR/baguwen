# String 常量池与 intern：字符串到底存在哪，new String 创建几个对象？

> 精讲层级：从「零基础能看懂」到「源码级」，每个名词都拆开
> 阅读时间：约 30 分钟
> 配套速查：[String 与常量池（深度追问）](../../10-deep-dive/java/02-String与常量池.md)
> 返回：[精讲索引](../00-索引.md)

---

## 0. 一句话先讲明白

`String` 是**不可变**类：内部存字符数组（JDK 8 是 `char[]`，JDK 9+ 是 `byte[] + coder`），一旦创建内容不能改。
**字面量**（代码里写死的 `"abc"`）会被放进「**字符串常量池**」，池在 **JDK 7 起位于堆**；`new String("abc")` 一定会在堆上**另建**一个 String 对象，所以 `new String("a") == "a"` 为 `false`。
`intern()` 的语义是：把字符串「登记」进池，返回池里那个引用。

```java
public final class String implements java.io.Serializable, Comparable<String>, CharSequence {
    @Stable private final byte[] value;   // JDK 9+：字符内容（JDK 8 是 char[]）
    private final byte coder;             // 0 = LATIN1（1 字节/字符），1 = UTF16（2 字节/字符）
    private int hash;                     // 惰性缓存的 hashCode
    private boolean hashIsZero;           // 缓存「算出来就是 0」的情况
}
```

先解释三个名词：

| 名词 | 是什么 |
|---|---|
| 不可变（immutable） | 对象创建后内容不能改；所有「修改」都是新建对象 |
| 字符串常量池 | 一块专门存「字面量字符串」的区域，同样的内容只存一份，JDK 7 起在堆里 |
| intern | 一个方法，把字符串登记到常量池并返回池中引用 |

---

## 1. 它解决什么问题（先讲痛点，不讲定义）

### 1.1 如果 String 可变会怎样

假设 `String` 可以原地修改，会立刻出现四个灾难：

1. **当 HashMap 的 key 会失效**：key 的 `hashCode` 依赖内容，内容一改，hash 变了，原来存的桶找不到它，`map.get(key)` 永远返回 null。
2. **线程不安全**：多个线程共享同一个字符串，谁都能改。
3. **无法做常量池共享**：池的前提是「内容永不变化」，否则一个地方改了，全世界都变。
4. **安全漏洞**：类名、文件路径、SQL、密码都是字符串，可变意味着可以在校验之后被改掉（比如 `"/safe/../etc/passwd"`）。

**不可变是 String 所有设计的根基**：只有内容不变，才能安全共享、才能缓存 hash、才能放进常量池。

### 1.2 为什么需要「常量池」

代码里的字符串字面量是**重复度极高**的：`"id"`、`"name"`、`"GET"`、`"utf-8"` 到处出现。如果每次出现都创建一个新对象：

- 内存浪费：同一份内容存 N 份；
- 比较变慢：判断两个字符串相等不能比引用，必须逐字符比。

常量池解决的就是这件事：**同样的字面量只创建一个对象，重复使用同一个引用**。于是判断字面量相等可以直接比引用（`==`），快得多。

---

## 2. 一步步拆开

### 2.1 字符串到底存在哪：三个不同的「池」别混

| 名字 | 存在位置 | 存什么 | 生命周期 |
|---|---|---|---|
| class 文件常量池 | `.class` 文件里 | 字面量、符号引用（名字） | 编译期就固定 |
| 运行时常量池 | 方法区（JDK 8+ 元空间） | 类加载后把 class 常量池搬进内存 | 跟着类走 |
| **字符串常量池（StringTable）** | **堆**（JDK 7 起） | 字符串**对象**本身（严格说是引用表） | 可被 GC 回收 |

**最常见的错误**是把「运行时常量池」和「字符串常量池」当成一回事。实际上：

- 运行时常量池里存的是「这个类的字面量指向哪个字符串对象」这类**元数据**；
- 字符串对象自己躺在堆里，StringTable 记录它们的引用，用于去重查找。

### 2.2 JDK 9 的 `byte[] + coder` 是怎么回事

JDK 8 的 `String` 内部是 `char[]`，**每个字符固定 2 字节**。但现实里绝大多数字符串是 ASCII/LATIN1（英文、数字、URL、JSON 的 key），一个字符只用一个字节就够，`char[]` 白白浪费一半。

JDK 9 的 **Compact Strings（JEP 254）** 改成：

| coder | 编码 | 每字符字节数 | 例子 |
|---|---|---|---|
| 0 | LATIN1 | 1 | `"hi"`、`"user_name"`、`"GET"` |
| 1 | UTF16 | 2 | `"你好"`、emoji、任何 > 0xFF 的字符 |

实测（反射读私有字段）：`"hi"` 的 `coder = 0`、`value.length = 2`；`"你好"` 的 `coder = 1`、`value.length = 4`（4 个字节存 2 个字符）。

**节省多少？** 按 100 个 ASCII 字符算：

```
char[]  : 数组头 16B + 100 × 2B = 216B
byte[]  : 数组头 16B + 100 × 1B = 116B -> 对齐 120B
节省     : 96B，约 44%
```

1000 个字符时：`2016B` vs `1016B`，节省接近 50%。这正是 JDK 9 愿意为它增加「按 coder 分派」复杂度的原因。

### 2.3 `new String("a")` 到底创建几个对象

要分两种情况，取决于**常量池里有没有 `"a"`**：

- **池里没有**：先创建池中那个字符串对象（1 个），`new String` 再创建 1 个 → **2 个 String 对象**；
- **池里已有**：`new String` 只创建 1 个 → **1 个**。

### 2.4 `intern()` 到底做了什么

规则分版本：

| 版本 | 池中存在 equals 相等的字符串 | 池中不存在 |
|---|---|---|
| JDK 6 | 返回池中对象 | 把**内容复制**一份进永久代，返回副本 |
| JDK 7+ | 返回池中对象 | 把**当前对象的引用**放进池，返回 `this` |

JDK 7 的改动省掉了一次内容拷贝，而且让「intern 完立刻丢弃原引用」还安全可用。

### 2.5 `+` 拼接：编译期和运行期完全不是一回事

```java
String a = "ab";                     // 编译期就确定
String b = "a" + "b";                // 编译器直接折叠成 "ab"，指向同一个池对象
String x = "a", y = "b";
String c = x + y;                    // 运行期拼接，生成新对象
```

`javap -c` 看 `c` 那行的字节码（JDK 9+，实测）：

```
invokedynamic #7,  0   // InvokeDynamic #0:makeConcatWithConstants:(...)Ljava/lang/String;
```

JDK 8 是 `new StringBuilder().append(x).append(y).toString()`；JDK 9+ 换成了 **`invokedynamic` + `StringConcatFactory`**（JEP 280）。它第一次执行时生成一个「拼接方法句柄」，之后直接调用，不再创建 StringBuilder。

---

## 3. 完整推导

### 3.1 `==` 结果的推导表

记住一条：**`==` 比的是引用**。哪个对象、在不在池里，决定结果。

| 写法 | `==` 结果 | 原因 |
|---|---|---|
| `"a" == "a"` | true | 同一个池对象 |
| `new String("a") == "a"` | **false** | 堆上新对象 vs 池对象 |
| `new String("a") == new String("a")` | false | 两个堆对象 |
| `new String("a").intern() == "a"` | true | intern 返回池中的 `"a"` |
| `"a" + "b" == "ab"` | true | 编译期常量折叠 |
| `final String f = "a"; (f + "b") == "ab"` | true | final 局部变量是「常量变量」，仍折叠 |
| `String x = "a"; (x + "b") == "ab"` | **false** | 运行期拼接生成新对象 |
| `(x + "b").intern() == "ab"` | true | intern 后拿到池引用 |

表中第 7 行是最容易被问倒的：`final` 修饰的局部变量如果编译期能确定值，属于「常量变量」，参与折叠；没加 `final` 就必须运行期拼接。

### 3.2 一个对象多大：逐字节算

以 64 位 JVM、开启压缩指针（引用 4B、对象头 12B、8 字节对齐）为准：

```
String 对象: 12(头) + 4(value 引用) + 4(hash) + 1(coder) + 1(hashIsZero) = 22 -> 对齐 24 字节
byte[] "hi": 16(数组头：12 头 + 4 长度) + 2 字节 = 18 -> 对齐 24 字节
所以一个 "hi" 字面量 ≈ 24 + 24 = 48 字节
```

### 3.3 为什么常量池在 JDK 7 从永久代搬到堆

JDK 6 的字符串常量池在**永久代**里。永久代有三个特点：大小固定（`-XX:MaxPermSize`）、回收条件苛刻、满了就 `OutOfMemoryError: PermGen space`。

于是出现这种现场：某个接口大量调用 `intern()`（或者加载了大量字符串字面量），永久代被撑爆，但堆里其实很空——**永久代太小且不参与常规 GC**。

JDK 7 把常量池挪到堆，收益有两个：

1. 字符串对象能参与正常的 Minor GC / Full GC，不再占着不可回收的空间；
2. 省去了「永久代要调多大」的调参噩梦（JDK 8 干脆把永久代整体替换成元空间）。

### 3.4 循环拼接为什么 O(n²)

即便 JDK 9+ 用 indy 优化了单次拼接，**循环里 `s += i` 每次都要新建一个 String**（内容越来越长）：

```
第 1 次: 拷贝长度 1
第 2 次: 拷贝长度 2
...
第 n 次: 拷贝长度 n
总拷贝量 ≈ n(n+1)/2
```

n = 10 万时约 `5 × 10^9` 次字符拷贝，慢到不可接受。正确写法是循环外建一个 `StringBuilder`（预设容量），最后 `toString()` 一次。

---

## 4. 极简模型：3 个变量、2 次拼接，手工判 `==`

```java
String a = "hi";          // 池里创建 "hi"，a 指向池对象
String b = new String("hi");  // 堆上新对象，但共享同一个 byte[]（实测 value 数组相同）
String c = a + "!";       // 运行期拼接，产生新对象 "hi!"
```

内存图（文字版）：

```
字符串常量池（堆内）
  "hi"  <──────── a
  "hi!" ？ 不在这里（运行期拼接不会自动入池）

堆
  String@1  "hi"       <── b（value 共享池对象的 byte[]）
  String@2  "hi!"      <── c（新数组，内容 hi!）

判定：
  a == b            -> false（池 vs 堆）
  a.equals(b)       -> true （内容相同）
  b.intern() == a   -> true （intern 后返回池里的 "hi"）
  c == "hi!"        -> false（c 是运行期产物，不在池）
  c.intern() == "hi!" -> true（intern 之后才进池）
```

---

## 5. 为什么这样设计（被否决的四个方案）

**方案 A：让 String 可变（像 `StringBuilder` 那样）。** 否决原因：HashMap 的 key 会失效（hash 变了找不到桶）；无法安全共享；常量池失去意义；类名/路径/密码这类安全敏感字符串可被篡改。**不可变是 String 的立身之本。**

**方案 B：继续用 `char[]`，不做 Compact Strings。** 否决原因：ASCII 场景白白浪费一半内存。实测 100 字符字符串从 216B 降到 120B（省 44%），1000 字符省近 50%；堆占用直接减少 5%~15%（官方 JEP 254 的评估）。代价只是每次操作按 coder 分派一次，非常划算。

**方案 C：把字符串常量池继续放在方法区/永久代。** 否决原因：见 3.3——永久代大小固定、回收差、极易 OOM，而字符串恰恰是最容易膨胀的数据。JDK 7 搬到堆是必然选择。

**方案 D：所有拼接都自动进常量池（自动 intern）。** 否决原因：池会无限膨胀且几乎不可控，等于把临时对象永久化，内存暴涨；而且每次拼接都要查表，性能骤降。**只有显式调用 `intern()` 才入池**，这是「谁需要谁负责」的取舍。

**方案 E：JDK 9 继续用 StringBuilder 拼接。** 否决原因：每次拼接都要分配 StringBuilder + 结果 String 两个对象，还要调用 `append`；换成 `invokedynamic` 后，`StringConcatFactory` 在第一次执行时生成最优拼接逻辑（可能直接用 `byte[]` 组装），减少临时对象、还能被 JIT 内联。

---

## 6. 关键参数为什么是这个值

### 6.1 `hashCode` 为什么乘 31

```java
h = 31 * h + value[i];
```

- 31 是**奇素数**，乘法能较好地打散，不容易产生规律性碰撞；
- `31 * i == (i << 5) - i`，JIT 可以优化成「移位 + 减法」，比通用乘法快；
- 经验值：JDK 作者测过，31 在英文单词集合上的碰撞率低于 33、37、39 等候选值；
- 31 不太大，`hash` 在短字符串上不容易过早溢出（虽然 int 溢出是允许的）。

### 6.2 `hash` 为什么不是 `final`

`hash` 是**惰性缓存**：第一次调用 `hashCode()` 时算出来并写回字段，之后直接返回。如果声明成 `final` 就必须在构造时算，而大量字符串根本不会被当 key 用，白算。并发首次计算可能重复算，但结果一致所以无害（这也是允许它非 final 的原因）。

### 6.3 `coder` 为什么是 `byte` 而不是 `boolean`

只有两个取值（0/1），`boolean` 语义上更贴切，但 `byte` 和 `boolean` 占的空间一样（1 字节），且 `byte` 便于后续扩展（理论上可以加更多编码类型）。另外 `hashIsZero` 也用 1 字节单独标记「hash 真的是 0」的情况，避免和「还没算」混淆。

### 6.4 StringTable 的大小

JDK 17 实测默认 `StringTableSize = 65536`（可用 `-XX:StringTableSize=` 调整）。
它是**哈希表**，所以有哈希冲突：`intern()` 越多、表越小，冲突链越长，`intern()` 越慢。如果业务大量用 `intern()`，可以调大这个值（要求是质数附近效果更好）。

---

## 7. 版本演进

**JDK 6**：`String` 内部 `char[]`；字符串常量池在**永久代**；`intern()` 未命中时**复制内容**进永久代。

**JDK 7**：常量池**搬到堆**；`intern()` 未命中时存**引用**并返回 `this`。

**JDK 8**：永久代被**元空间**取代（常量池仍在堆）；`+` 拼接编译成 `StringBuilder`；默认 `StringTableSize = 60013`。

**JDK 9**：**Compact Strings（JEP 254）**：`char[]` → `byte[] + coder`；`+` 拼接改为 `invokedynamic`（JEP 280）；`StringTableSize` 默认改为 65536。

**JDK 17**：与 JDK 9 基本一致，`coder` 机制沿用；G1 的字符串去重（`-XX:+UseStringDeduplication`，默认关闭）只在 G1 下生效。

**JDK 21**：无结构性变化；同版本引入的字符串模板（String Templates）仍是预览特性，底层拼接依然是 indy。

---

## 8. 亲手验证

```java
import java.lang.reflect.Field;

public class StrProbe {
    public static void main(String[] a) throws Exception {
        Field value = String.class.getDeclaredField("value"); value.setAccessible(true);
        Field coder = String.class.getDeclaredField("coder"); coder.setAccessible(true);
        Field hash = String.class.getDeclaredField("hash"); hash.setAccessible(true);

        String lit = "hi";
        String copy = new String("hi");
        System.out.println("字面量与 new String 共享 value 数组？ " + (value.get(lit) == value.get(copy)));
        System.out.println("coder(hi)=" + coder.getInt(lit) + "，value 长度=" + ((byte[]) value.get(lit)).length);

        String cn = "你好";
        System.out.println("coder(你好)=" + coder.getInt(cn) + "，value 长度=" + ((byte[]) value.get(cn)).length);

        System.out.println("hash 字段初始值=" + hash.getInt(lit));
        System.out.println("调用 hashCode 后 hash 字段=" + (lit.hashCode() == 3329 ? hash.getInt(lit) : -1));

        String heap = new String("a");
        System.out.println("new String(\"a\") == \"a\" -> " + (heap == "a"));
        System.out.println("(new String(\"a\")).intern() == \"a\" -> " + (heap.intern() == "a"));

        String s1 = "a", s2 = "b";
        System.out.println("s1+s2 == \"ab\" -> " + (s1 + s2 == "ab")
                + "，(s1+s2).intern() == \"ab\" -> " + ((s1 + s2).intern() == "ab"));
    }
}
```

```bash
javac -encoding UTF-8 StrProbe.java
java --add-opens java.base/java.lang=ALL-UNNAMED StrProbe

# 看 JDK 9+ 的拼接产物（不是 StringBuilder）
javac -encoding UTF-8 -d out StrProbe.java && javap -c -p out/StrProbe.class | grep makeConcatWithConstants
```

预期输出：

```
字面量与 new String 共享 value 数组？ true
coder(hi)=0，value 长度=2
coder(你好)=1，value 长度=4
hash 字段初始值=0
调用 hashCode 后 hash 字段=3329
new String("a") == "a" -> false
(new String("a")).intern() == "a" -> true
s1+s2 == "ab" -> false，(s1+s2).intern() == "ab" -> true
```

两个值得琢磨的点：

1. **`new String("hi")` 和字面量共享同一个 `byte[]`**（`String(String original)` 直接复用 `original.value`），所以「new String 复制了一份内容」是错的——复制的是**对象**，数组是共享的。
2. `hash` 字段一开始是 0，调用 `hashCode()` 后才被填成 3329，直接证明「惰性缓存」。

---

## 9. 常见误区

| 错误说法 | 正确说法 |
|---|---|
| 「字符串常量池在方法区/元空间」 | JDK 7 起在**堆**里；元空间存的是类元数据 |
| 「`new String("a")` 一定创建 2 个对象」 | 池里没有才是 2 个（池 + 堆）；已有则只创建 1 个 |
| 「`new String` 会复制字符内容」 | 对象是新的，但 JDK 8/9 都**共享**底层数组 |
| 「`intern()` 会把字符串复制进池」 | JDK 7+ 存的是引用并返回 `this`；JDK 6 才复制 |
| 「JDK 9 的 `+` 还是 StringBuilder」 | 编译成 `invokedynamic` + `makeConcatWithConstants` |
| 「循环里 `+=` 有 indy 优化就没事」 | 每次仍新建 String，复杂度 O(n²) |
| 「`String.length()` 就是底层数组长度」 | coder=1（UTF16）时是数组长度的一半 |
| 「常量池里的字符串永远不会被回收」 | JDK 7+ 在堆里，没人引用时可被 GC 回收 |

---

## 10. 连续追问 Q&A

### Q1：String 为什么不可变？怎么实现的？
**答**：`class` 是 final（不能被继承改写行为），`value` 字段是 final 且不提供任何修改方法。不可变换来线程安全、hash 可缓存、常量池可共享、可以做 Map key。**注意**：语言层不可变，但反射改数组内容仍能破坏它。

### Q2：`new String("a")` 创建几个对象？
**答**：池里没有 `"a"` 时创建 2 个（池中一个 + 堆上一个），已有则 1 个。无论如何 `==` 字面量都是 false，因为返回的是堆对象。

### Q3：字符串常量池在 JDK 7 为什么搬到堆里？
**答**：原来在永久代，大小固定、回收条件苛刻，大量 `intern()` 或字符串字面量很容易 `PermGen space` OOM。搬到堆后能参与正常 GC，参数也不用再纠结。

### Q4：`intern()` 在 JDK 6 和 JDK 7 有什么区别？
**答**：命中时都返回池中对象；未命中时 JDK 6 复制内容进永久代并返回副本，JDK 7+ 把当前对象的引用放进池并返回 `this`。

### Q5：`"a" + "b"` 为什么 `== "ab"`？
**答**：编译期常量折叠，`"a"+"b"` 在 class 文件里已经是 `"ab"`，运行时直接指向池里的同一个对象。

### Q6：`final` 局部变量参与拼接为什么也能折叠？
**答**：编译期能确定值的 `final` 局部变量/字段属于「常量变量（constant variable）」，编译器仍然做常量折叠；没加 final 就必须运行期拼接。

### Q7：JDK 9 为什么把 `char[]` 换成 `byte[]`？
**答**：绝大多数字符串是 LATIN1 可表示的，`char[]` 固定 2 字节浪费一半。改成 `byte[] + coder` 后，100 字符的 ASCII 字符串从 216B 降到 120B，省 44%；代价是操作时按 coder 分派。

### Q8：`coder` 的两个值分别代表什么？
**答**：0 = LATIN1（每字符 1 字节），1 = UTF16（每字符 2 字节）。两个 coder 的字符串做拼接/比较时，LATIN1 会「升级」成 UTF16 再操作。

### Q9：`String.hashCode()` 为什么缓存？
**答**：String 是 HashMap 最常用的 key，每次 `get` 都要算 hash；缓存后变成一次字段读取。缓存字段 `hash` 不是 final，因为要惰性计算。

### Q10：循环里拼字符串为什么慢？正确写法？
**答**：每次 `+=` 都新建一个 String 并把已有内容拷贝进去，总拷贝量约 n²/2。正确写法是循环外用 `StringBuilder`（预设容量），最后 `toString()` 一次。

### Q11：字符串常量池里会有重复内容吗？
**答**：不会有「equals 相等的两个对象」共存——池本身就是一个哈希表（StringTable，JDK 17 默认 65536 桶），`intern()` 会先查表。

### Q12：`String` 不可变，那 `substring` 改内容吗？
**答**：不改。`substring` 返回新 String（JDK 7+ 起会复制底层数组，避免老版本「小字符串持有大数组」的内存泄漏问题）。

---

## 11. 一张图总结

```
源代码                     编译期                     运行期（堆）
"hi"  ───────────────►  常量池字面量索引  ────►  StringTable 里登记 "hi"
                                                     │
                                            ┌────────┴─────────┐
                                            ▼                  ▼
                                    String@1（池）        new String("hi")
                                    value ──┐                 │ value 共享
                                            └─────────────────┘（同一个 byte[]）

判定规则：
  字面量 == 字面量          -> true（同一个池对象）
  new String("a") == "a"   -> false（堆 vs 池）
  x.intern() == "a"        -> true（intern 返回池引用）
  "a"+"b" == "ab"          -> true（编译期折叠）
  运行期 x+y               -> 新对象，== 为 false

底层存储：JDK 8  char[]            （每字符 2B）
          JDK 9+ byte[] + coder    （LATIN1 1B / UTF16 2B）
```

---

## 12. 一句话复盘

> String 不可变，所以能安全共享、缓存 hash、进常量池；字面量进池（JDK 7 起池在堆），`new String` 在堆上另建对象但共享底层数组；`intern()` 把字符串登记进池并返回池引用，JDK 6 复制内容、JDK 7+ 存引用。JDK 9 用 `byte[] + coder` 省掉一半 ASCII 内存，`+` 拼接从 StringBuilder 换成 invokedynamic——但循环里 `+=` 依然是 O(n²)。

---

## 13. 自测题（先自己答，再看答案）

**1. `new String("a")` 创建几个对象？`== "a"` 是 true 还是 false？**
答案：池中无 `"a"` 时 2 个（池 + 堆），已有则 1 个；`==` 一定是 false（比的是堆对象和池对象）。

**2. 字符串常量池在 JDK 7 之后位于哪里？**
答案：堆里。JDK 6 在永久代；JDK 8 之后永久代被元空间取代，但常量池仍在堆。

**3. `intern()` 在 JDK 6 与 JDK 7+ 的差别？**
答案：未命中时，JDK 6 复制内容进永久代返回副本；JDK 7+ 存当前对象引用并返回 `this`。

**4. 为什么 `"a"+"b" == "ab"` 为 true，而 `x+y == "ab"` 为 false？**
答案：前者编译期常量折叠，直接指向池对象；后者运行期拼接生成新对象。

**5. JDK 9 的 `byte[] + coder` 省了多少内存？怎么算的？**
答案：100 个 ASCII 字符，`char[]` 需 16+200=216B，`byte[]` 需 16+100=116B（对齐 120B），省约 44%；1000 字符省近 50%。

**6. 一个 `"hi"` 字面量大约占多少字节？**
答案：String 对象 24B（12 头 + 4 value + 4 hash + 1 coder + 1 hashIsZero，对齐 24）+ `byte[]` 24B（16 头 + 2 字节对齐 24）≈ 48B。

---

## 14. 关联文件

- 上一篇精讲：[红黑树与树化](03-红黑树与树化.md)
- 深一层：[String 与常量池](../../10-deep-dive/java/02-String与常量池.md)
- 下一篇精讲：[JVM 内存布局与对象布局](05-JVM内存布局与对象布局.md)（对象头怎么算出来的）
- 相关：[HashMap 底层](../../10-deep-dive/java/01-HashMap.md)（String 是最常用的 key）
- 返回：[精讲索引](../00-索引.md)
