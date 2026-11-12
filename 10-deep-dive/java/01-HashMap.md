# HashMap 底层（数组 + 链表 + 红黑树）

> 面试权重：5/5　｜　追问深度：**L5（JDK 源码 + 字节码 + 缓存行）**
> 一句话定位：「复杂度 O(1)」只是结论，真正被追问的是**扰动函数、2 的幂、8/64/6 三个阈值、split 高低位拆分、JDK7 成环**这五件事。答不出这五个，就是「背过八股」。

**本文件用法**：从 L1 往下读，每读完一层合上书自问自答。**停在答不出的那一层，就是你的真实水平线。**
[返回深度追问索引](../00-索引.md)

---

## L1 一句话答案（10 秒能说出口）

JDK 8 的 HashMap 是 `Node[] table`（数组）+ 链表 + 红黑树：`hash()` 把 hashCode 高低 16 位异或做扰动，用 `(n-1) & hash` 定位桶；冲突挂链表，链表长到 8 且容量 ≥64 才树化；元素数超过 `容量 × 0.75` 就翻倍，扩容时用 `e.hash & oldCap` 把桶拆成高位/低位两条链。

---

## L2 原理层：一次 put 到底做了什么

```
put(k, v)
  ├─ hash = (h = k.hashCode()) ^ (h >>> 16)        // ① 扰动
  ├─ i = (n - 1) & hash                            // ② 桶定位（n = table.length）
  ├─ table[i] == null  → 直接放 new Node           // ③ 空桶，O(1)
  ├─ 桶首 key 相同     → 覆盖 value，返回旧值      // ④ 命中
  ├─ 桶首是 TreeNode   → putTreeVal（红黑树插入）  // ⑤ 树桶
  └─ 否则遍历链表尾插  → 插入后若 binCount >= 7    // ⑥ 链表 → 可能树化
         └─ treeifyBin：容量 < 64 只 resize，否则树化
  └─ ++size > threshold → resize()                 // ⑦ 扩容
```

**三组必须背准的数字**（JDK 8 `HashMap.java` 常量区）：

| 常量 | 值 | 作用域 |
|---|---|---|
| `DEFAULT_INITIAL_CAPACITY` | `1 << 4` = 16 | 首次 put 时分配 |
| `DEFAULT_LOAD_FACTOR` | `0.75f` | 阈值 = cap × 0.75 |
| `TREEIFY_THRESHOLD` | 8 | 链表转树的触发线 |
| `UNTREEIFY_THRESHOLD` | 6 | **split 时**子链 ≤6 就退化回链表 |
| `MIN_TREEIFY_CAPACITY` | 64 | 小于它只扩容，不树化 |

---

## L3 底层层：源码逐行

### 3.1 扰动函数：为什么是 `h ^ (h >>> 16)`

```java
static final int hash(Object key) {
    int h;
    return (key == null) ? 0 : (h = key.hashCode()) ^ (h >>> 16);
}
```

桶定位只用 `(n-1) & hash`，**低 4 位（n=16 时）决定一切**。如果两个 key 的 hashCode 只有高 16 位不同（比如 `a<<16` 与 `b<<16`），不扰动就会挤在同一个桶。把高 16 位异或到低位，等于让高位也参与定位。

注意 `h >>> 16` 是**无符号右移**：负数 hashCode 也能被摊平，避免 `-1` 这种值扰动后仍是全 1 导致极端分布。

### 3.2 桶定位：`(n-1) & hash` 与容量必须是 2 的幂

`hash & (n-1)` 只在 n 为 2 的幂时**等价于** `hash % n`，而位运算比取模快一个量级。更关键的是扩容：

- n 从 16 变 32 时，`n-1` 从 `01111` 变 `11111`，只是**多了一个高位**。
- 所以元素的新下标只有两种可能：`hash & 16 == 0` → 留在原位 `j`；否则 → `j + 16`（= `j + oldCap`）。
- 这就是为什么不需要重算 `hash % newCap`。

`tableSizeFor` 负责把任意 initialCapacity 向上取到 2 的幂（`Integer.highestOneBit` + 位移填充）。

### 3.3 treeifyBin：8 与 64 的真实语义

```java
// putVal 的链表尾插分支
if ((e = p.next) == null) {
    p.next = newNode(hash, key, value, null);
    if (binCount >= TREEIFY_THRESHOLD - 1)  // binCount 从 0 起，-1 for 1st
        treeifyBin(tab, hash);
    break;
}
// treeifyBin
if (tab == null || (n = tab.length) < MIN_TREEIFY_CAPACITY)
    resize();                                // 容量不够 → 只扩容
else
    ... 把整条链换成 TreeNode 双向链再 treeify
```

**实测结论（JDK 17，反射读 `table[i]`）**：桶内第 1~8 个元素都是 `Node`，**插入第 9 个元素时**才变成 `TreeNode`。因为 `binCount` 从 0 开始、判断的是 `>= 7`，「链表到 8 就转树」是被简化过的说法——准确说是**「下一次插入就要到 8 以上时」触发**。

为什么是 8：源码注释给了泊松分布——哈希均匀时单桶出现 k 个元素的概率是 `e^-0.5 × 0.5^k / k!`，k=8 时约 **6e-8**（一千万次不到一次）。也就是说树化基本只在「有人恶意构造 hashCode」时才发生，所以 TreeNode 占两倍空间可以接受。

为什么是 64：容量小时碰撞多是因为**桶太少**，扩容比树化便宜（一次扩容 O(n) 但只做一次，树化/退化会反复震荡）；且 `resize` 时空表无法树化。**退化阈值 6 而不是 8**，是留一个缓冲带，避免 8↔7 反复切换。

### 3.4 resize / split：高低位链表拆分

```java
Node<K,V> loHead = null, loTail = null, hiHead = null, hiTail = null;
do {
    next = e.next;
    if ((e.hash & oldCap) == 0) {           // 高位为 0 → 留原位
        if (loTail == null) loHead = e; else loTail.next = e;
        loTail = e;
    } else {                                 // 高位为 1 → 移到 j + oldCap
        if (hiTail == null) hiHead = e; else hiTail.next = e;
        hiTail = e;
    }
} while ((e = next) != null);
newTab[j] = loHead;            // 低位链原地
newTab[j + oldCap] = hiHead;   // 高位链偏移 oldCap
```

**实测**：cap=16 时 hash=1 与 hash=17 都在 1 号桶；扩容到 32 后 `1 & 16 = 0` 留 1 号桶，`17 & 16 = 16` 移到 `1+16=17` 号桶。

JDK 8 的 split 是**尾插 + 保持相对顺序**，这是它和 JDK 7 最本质的差别之一；红黑树桶则走 `TreeNode.split`，若子链 ≤ `UNTREEIFY_THRESHOLD` 就 `untreeify`。

### 3.5 JDK 7 头插为什么成环（必考）

JDK 7 `transfer` 是**头插**（`e.next = newTable[i]; newTable[i] = e;`），并发扩容时成环：

```
初始：table[i] = A → B → null
线程1 执行到 Entry next = e.next 后挂起（e=A, next=B）
线程2 完成 transfer，头插导致顺序反转 → 新表 = B → A → null
线程1 恢复：A.next=null → 表=A；e=B → B.next=A → 表=B→A；e=A → A.next=B ← 环
之后 get() 一个不存在的 key，遍历这条环就死循环，CPU 100%
```

JDK 8 改成尾插 + 高低位拆分后**不会成环**，但依然线程不安全：并发 put 会互相覆盖（`tab[i] = newNode` 非原子）、`++size` 丢失更新、扩容期间读到旧表。**「修好了死循环 ≠ 线程安全」是区分背题和理解的分水岭。**

**顺带一个空间账**：`Node` = 对象头 12B + `hash` 4B + `key`/`value`/`next` 三个压缩引用各 4B = **32 字节**；`TreeNode` 多出 `parent/left/right/prev/red`，约两倍——这就是「不到万不得已不树化」的空间理由。

---

## L4 追问树（面试官一路往下问，你能撑到第几层？）

> 规则：从上往下问。**第 1-3 层是应届生必备，第 4-7 层拉开差距，第 8 层以后是加分。**

### 第 1 层｜HashMap 的底层结构是什么？
**答**：JDK 8 是数组 + 链表 + 红黑树。数组是 `Node[] table`，懒初始化到 16；冲突先挂链表，链表过长且容量够就转红黑树把最坏 O(n) 降到 O(log n)；元素数超过 `cap × 0.75` 翻倍扩容。

### 第 2 层｜为什么 JDK 8 要引入红黑树，而不继续用纯链表？
**答**：链表的查找是 O(n)。正常哈希下链表很短，但一旦 hashCode 分布差（或被人构造恶意 key 做哈希碰撞攻击），单桶可能挂几千个节点，退化成 O(n)。红黑树保证最坏 O(log n)，且插入/删除的旋转次数有上界（最多 3 次旋转）。源码注释明确说这是为了「performance degrades gracefully under malicious usages」。

### 第 3 层｜为什么是 8？为什么还要 64？
**答**：8 来自泊松分布——哈希均匀时单桶 8 个元素的概率约 6e-8，树化几乎不会误触发，而 TreeNode 占两倍空间，所以门槛设高。64 是另一道闸：容量小于 64 说明是「桶太少」导致的碰撞，扩容能摊薄，比树化更划算，所以 `treeifyBin` 先 `resize()`。

### 第 4 层｜「链表长度到 8 就转红黑树」这句话对吗？
**答**：不严谨。源码是 `binCount >= TREEIFY_THRESHOLD - 1`，`binCount` 从 0 开始数，实际是**插入第 9 个节点时**才调用 `treeifyBin`；我反射验证过，桶内 8 个元素时还是 `Node`，第 9 个才变 `TreeNode`。另外还要求 `table.length >= 64`。

### 第 5 层｜退化阈值为什么是 6，而且它在哪生效？
**答**：`UNTREEIFY_THRESHOLD = 6` 主要用于 **`TreeNode.split`（扩容拆分）**：拆出来的子链 ≤6 就 untreeify 成普通链表。留 8→6 的缓冲带是为了防止在 7/8 之间反复树化-退化震荡。注意：`remove` 走的 `removeTreeNode` 是按**树的形状**判断「太小了」就退化，不是直接比 6——这也是很多人答错的地方。

### 第 6 层｜为什么容量必须是 2 的幂？initialCapacity=10 会怎样？
**答**：两个原因：`(n-1) & hash` 只在 2 的幂时等价于 `hash % n`，位运算更快；扩容时元素只可能留在原位或 +oldCap，不用重算 hash。传 10 会被 `tableSizeFor` 向上取成 16——所以「initialCapacity 传 10 实际是 16」。

### 第 7 层｜扩容时元素怎么迁移？为什么不重算 hash？
**答**：把桶里链表拆成两条：`(e.hash & oldCap) == 0` 的留在 `j`，否则移到 `j + oldCap`。因为新容量 = 2×旧容量，`n-1` 只多一位高位，旧 hash 的那一位决定去留。这是 JDK 8 相对 JDK 7「重新计算下标」的核心优化，实测 hash=1 留原位、hash=17 移到 17 号桶。

### 第 8 层｜负载因子为什么是 0.75？
**答**：时间与空间的折中。源码注释说 0.75 是「a good tradeoff between time and space costs」：太高（如 1）则冲突概率与链表变长，查询退化；太低（如 0.5）则数组浪费一半空间且扩容更频繁。0.75 时「桶的期望元素数 ≈ 0.5」也正好是泊松分布参数取 0.5 的由来。

### 第 9 层｜JDK 7 的并发死循环是怎么产生的？JDK 8 修好了吗？
**答**：JDK 7 扩容用头插，两个线程同时 transfer 时，A 线程执行到 `next = e.next` 挂起，B 线程完成扩容把链反转；A 恢复后继续头插，最终把 `A.next = B`、`B.next = A` 连成环，之后 get 不到就死循环。JDK 8 改成尾插 + 高低位拆分，**环没有了**，但依然线程不安全：`tab[i] = newNode` 和 `++size` 都不是原子的，并发会覆盖丢数据 → 并发场景必须 `ConcurrentHashMap`。



### 第 10 层（终局）｜`(n-1) & hash` 在字节码和 CPU 层是什么？
**答**：源码 `int i = (n - 1) & hash` 编译成字节码 `isub`（n-1）+ `iand`（与），两条指令，无函数调用、无分支——我 `javap` 验证过 `indexFor(int n, int hash) { return (n - 1) & hash; }` 就是 `isub; iand`。到 CPU 层是一次 ALU 运算（1 cycle），JIT 还能把后续的数组访问 `tab[i]` 的边界检查（`aastore`/`aaload` 的 bounds check）在证明 `i < n` 后消除。这就是为什么 HashMap 的定位几乎「零成本」——**不是哈希快，是把取模换成了位与**。

---

## L5 名词拆解表（"每个名词都拆开"）

| 名词 | 是什么 | 为什么存在 | 面试追问点 |
|---|---|---|---|
| `table` | `Node<K,V>[]`，桶数组 | 用下标直接寻址 | 为什么懒初始化到首次 put |
| `threshold` / `loadFactor` | 扩容阈值 = cap × 0.75 | 提前触发扩容，避免链表过长 | 首次 put 后是 12，不是 16 |
| `Node` | 链表节点（hash/key/value/next） | 存键值 + 维持冲突链 | 32 字节怎么算出来的 |
| `TreeNode` | 红黑树节点，带 parent/left/right/prev/red | 最坏 O(log n) | 为什么还保留 `next`（便于 untreeify/遍历） |
| `hash()` | 扰动函数 `h ^ h>>>16` | 让高位参与低位定位 | 不扰动会怎样 |
| `tableSizeFor` | 把 initialCapacity 向上取 2 的幂 | 保证 `(n-1)&hash` 成立 | 传 10 实际是多少 |
| `treeifyBin` | 链表 → 树的转换入口 | 带 64 容量门槛 | 为什么先 resize |
| `split` | 扩容时拆高低位链表 / 拆树 | O(1) 迁移不重算 hash | `e.hash & oldCap` 的含义 |
| `modCount` | 结构性修改计数器 | 迭代时检测并发修改（fail-fast） | 与 CME 的关系 |
| `DEFAULT_INITIAL_CAPACITY` | 默认桶数 16 | 首次 put 才分配 | 为什么不是 8 或 32 |
| `resize` | 扩容 + 迁移 | 控制链表长度、摊还插入成本 | 为什么是 2 倍而不是 1.5 倍 |
| 头插法 | JDK 7 的插入方式 | 插入无需遍历 | 并发成环的根因 |
---

## 代码验证（复制到 `HashMapProbe.java`，编译后逐条看输出）

```java
import java.lang.reflect.Field;
import java.util.*;

public class HashMapProbe {
    static final class K {                      // 所有 key 的 hashCode 都 = 1，强制撞桶
        final int id;
        K(int id) { this.id = id; }
        @Override public int hashCode() { return 1; }
        @Override public boolean equals(Object o) { return o instanceof K && ((K) o).id == id; }
    }
    static Object[] table(HashMap<?, ?> m) throws Exception {
        Field f = HashMap.class.getDeclaredField("table"); f.setAccessible(true);
        return (Object[]) f.get(m);
    }

    public static void main(String[] args) throws Exception {
        HashMap<String, Integer> m = new HashMap<>();
        System.out.println(table(m) == null ? "首次 put 前 table 为 null（懒初始化）" : "?");
        m.put("a", 1);
        System.out.println("cap=" + table(m).length);   // 16
        for (int i = 1; i <= 12; i++) m.put("k" + i, i);
        System.out.println("cap=" + table(m).length);   // 32（第 13 个元素触发扩容）

        HashMap<K, Integer> t = new HashMap<>(64);          // 容量先到 64
        t.put(new K(0), 0);
        int idx = (table(t).length - 1) & 1;                // hash=1 → 桶 1
        for (int i = 1; i <= 10; i++) {
            t.put(new K(i), i);
            Object bin = table(t)[idx];
            System.out.println("插入第 " + (i + 1) + " 个 → " + bin.getClass().getSimpleName());
            // 第 9 个开始是 TreeNode
        }
    }
}
```

```bash
javac HashMapProbe.java
java --add-opens java.base/java.util=ALL-UNNAMED HashMapProbe
# JDK 17 起 java.util 不默认开放反射，读 table/threshold 必须加 --add-opens
```

**预期输出**：`16,12` → `32,24`；撞桶元素 1~8 是 `Node`，第 9 个变 `TreeNode`。

---

## 高频错误（面试官最爱抓的）

| 错误说法 | 正确说法 |
|---|---|
| 「链表到 8 就转红黑树」 | 第 9 个节点插入时触发 treeifyBin，且要求容量 ≥64 |
| 「退化阈值 6 用于 remove」 | 6 主要用在 split 拆树；remove 按树形状判断退化 |
| 「JDK 8 改尾插就线程安全了」 | 只是不成环，覆盖写和 size 错乱仍在，并发必须用 CHM |
| 「扩容会重新计算 hash 和下标」 | JDK 8 只判断 `e.hash & oldCap`，留原位或 +oldCap |
| 「initialCapacity=10 就是 10」 | `tableSizeFor` 向上取 2 的幂 → 实际 16 |

---

## 关联文件

- 广度版（60 秒能答）：[Java基础与并发](../../03-java/Java基础与并发.md) 的 HashMap / ConcurrentHashMap
- 同层追问：[集合体系](./03-集合体系.md)｜[String 与常量池](./02-String与常量池.md)（key 常用 String，hash 计算相关）
- 典型场景：Spring 的 `DefaultSingletonBeanRegistry.singletonObjects` 就是 `ConcurrentHashMap`；你实习项目里用 `Map<String, LocalCache>` 做热点字典时，必须用 `ConcurrentHashMap` 而不能用 `HashMap`——这就是这页知识的直接落点

> **自测标准**：能把 L4 讲到第 9 层（JDK 7 成环 + JDK 8 为何仍不安全），并现场跑通 `HashMapProbe` 解释每个数字，算过关。
