# HashMap 扩容机制：为什么扩容后不用重新算 hash？

> 精讲层级：从「零基础能看懂」到「源码级」，每个名词都拆开
> 阅读时间：约 30 分钟
> 配套速查：[HashMap 底层（深度追问）](../../10-deep-dive/java/01-HashMap.md)
> 返回：[精讲索引](../00-索引.md)

---

## 0. 一句话先讲明白

元素数超过「容量 × 0.75」时，HashMap 把容量翻倍，然后把每个桶的元素分成两队：一队留在原下标，一队移到「原下标 + 旧容量」。判断只看一个 bit：`(e.hash & oldCap) == 0`。所以扩容不用重新调用 `hashCode()`，也不用取模。

```java
final Node<K,V>[] resize() {
    int oldCap = table.length;
    int newCap = oldCap << 1;                  // 容量翻倍
    // ……分配 newTab 后逐个桶迁移：
    //   (e.hash & oldCap) == 0  -> 放进 lo 链，落到 newTab[j]
    //   否则                     -> 放进 hi 链，落到 newTab[j + oldCap]
}
```

三个名词先解释掉：

| 名词 | 是什么 |
|---|---|
| 容量 capacity | `table` 数组长度，一定是 2 的幂，默认 16 |
| 阈值 threshold | 触发扩容的元素数上限 = 容量 × 0.75（默认 12） |
| 桶 bucket | `table[i]` 这个位置，里面可能挂链表或红黑树 |

---

## 1. 它解决什么问题（先讲痛点，不讲定义）

容量固定不变的话，元素一多，每个桶的链表就越来越长，查询从 O(1) 退化成 O(n)；靠红黑树兜底也只是 O(log n)，而且 `TreeNode` 占两倍内存，全表树化纯属浪费。所以必须扩容——把容量翻倍，让元素重新散开。

**真正的难点不是「分配更大的数组」，而是「每个元素搬到哪个新位置」。** 朴素做法是重算：

```java
int newIndex = hash & (newCapacity - 1);
```

这条路的代价：① 每个元素都要重新算下标；② 算完之后元素落在哪个桶是彻底重新分布的，链表没法整段拼接；③ JDK 7 为了防哈希碰撞攻击还引入了 `hashSeed`（哈希种子），扩容时要按开关重新算 `hash`，复杂且收益有限，JDK 8 直接删掉了。

于是设计目标变成一句话：**能不能只用一个 bit 就判断元素去哪，而不是重算整个下标？** 能，而且只需要一次按位与。

---

## 2. 一步步拆开：resize 到底做了什么

### 2.1 谁触发扩容

`putVal` 最后一步：

```java
if (++size > threshold)   // 注意是「大于」不是「大于等于」
    resize();
```

默认容量 16、阈值 12：放入第 13 个元素时 `13 > 12`，触发扩容。

### 2.2 四段逻辑

**第一段，算新容量和新阈值。** 正常路径是 `newCap = oldCap << 1`、`newThr = oldThr << 1`；已经到 `MAXIMUM_CAPACITY` 就设 `threshold = Integer.MAX_VALUE` 并不再扩容。

这里有个容易迷惑的点：**数组还没分配时，`threshold` 被临时用来存初始容量**。所以 `new HashMap<>(100)` 不会立刻分配数组，而是把 100 经 `tableSizeFor` 变成 128 存进 `threshold`，第一次 put 才按它分配。

**第二段，分配新数组**：`Node<K,V>[] newTab = new Node[newCap]; table = newTab;`

**第三段，逐个桶迁移**：空桶跳过；单节点直接算 `newTab[e.hash & (newCap-1)]`；红黑树桶走 `TreeNode.split`；链表桶拆成 lo/hi 两段。

**第四段，拆链表（核心）：**

```java
Node<K,V> loHead = null, loTail = null;      // 留原位
Node<K,V> hiHead = null, hiTail = null;      // 移到 j + oldCap
do {
    next = e.next;
    if ((e.hash & oldCap) == 0) {            // 重点：只看这一位
        if (loTail == null) loHead = e; else loTail.next = e;
        loTail = e;
    } else {
        if (hiTail == null) hiHead = e; else hiTail.next = e;
        hiTail = e;
    }
} while ((e = next) != null);
if (loTail != null) { loTail.next = null; newTab[j] = loHead; }
if (hiTail != null) { hiTail.next = null; newTab[j + oldCap] = hiHead; }
```

### 2.3 一张图看懂拆链

```
迁移前（oldCap=16，桶 j=1）
table[1] -> A(=0) -> B(=16) -> C(=0) -> D(=16) -> E(=0) -> null
           注释：(=k) 表示 e.hash & oldCap 的值

按 bit4 分两队（JDK 8 尾插，各自保持原顺序）：
  lo: A -> C -> E        落到 newTab[1]
  hi: B -> D             落到 newTab[1 + 16] = newTab[17]

迁移后（newCap=32）
newTab[1]  -> A -> C -> E -> null
newTab[17] -> B -> D -> null
```

**顺序没变**，这点在 JDK 7 死循环那节会用到。

---

## 3. 完整推导：为什么只有两种可能

### 3.1 数学

设旧容量 `n = 2^k`（16 = 2^4，k=4），旧掩码 `n-1` 是 k 个 1；新容量 `2n`，掩码 `2n-1` 是 k+1 个 1。两者只差**第 k 位**：

```
n-1   = 0000...0000 1111     (k=4)
2n-1  = 0000...0001 1111     (低 5 位全 1)
                 ↑ 多出来的第 4 位，数值正好是 n = 16
```

所以：

```
i' = (hash & (n-1)) | (hash & n)
   = i + (hash & n == 0 ? 0 : n)
```

即 **`hash & n == 0` 留原位，否则移到原位 + n**。代码里的 `oldCap` 就是 n。

### 3.2 数字验证

`oldIdx = h & 15`，`newIdx = h & 31`：

| hash | 低 5 位 | oldIdx | h & 16 | newIdx | 结论 |
|---|---|---|---|---|---|
| 1 | `00001` | 1 | 0 | 1 | 留原位 |
| 17 | `10001` | 1 | 16 | 17 | +16 |
| 33 | `00001` | 1 | 0 | 1 | 留原位 |
| 15 | `01111` | 15 | 0 | 15 | 留原位 |
| 16 | `10000` | 0 | 16 | 16 | +16 |
| 31 | `11111` | 15 | 16 | 31 | +16 |

`h & 16` 非 0 的，新下标都正好比原下标大 16。

### 3.3 概率推论

桶内元素的 hash 在第 k 位上近似独立均匀，所以约一半留原位、一半移走。原来长 L 的链表，扩容后两条链期望长度都是 **L/2**。**这就是扩容有意义的数学原因：一次扩容把最坏链表长度砍半。**

### 3.4 均摊复杂度

容量翻倍时，总搬迁量是等比数列：`16 + 32 + 64 + ... + n = 2n - 16 ≈ 2n`。插入 n 个元素总搬迁不超过 2n 次，均摊到每次 put 就是 O(1)。对比 ArrayList 的 1.5 倍扩容总复制量约 3n，所以 2 倍扩容在「均摊搬迁」上更省。

---

## 4. 极简模型：容量 4 → 8 的手工推演

```
oldCap = 4 -> mask = 0b011（看低 2 位）
newCap = 8 -> mask = 0b111（看低 3 位）
多出来的是 bit2，数值 4
```

桶 `j=2` 里挂了三个 hash：6、10、14。

```
hash=6  = 0b0110   6 & 3 = 2   6 & 4 = 4  -> 移到 2+4 = 6
hash=10 = 0b1010  10 & 3 = 2  10 & 4 = 0  -> 留在 2
hash=14 = 0b1110  14 & 3 = 2  14 & 4 = 4  -> 移到 2+4 = 6
```

结果：`newTab[2] = 10`、`newTab[6] = 6 -> 14`。
再验算一遍 `6 & 7 = 6`、`14 & 7 = 6`、`10 & 7 = 2`，与推导一致。**位数越少越容易手算，结论和大表相同。**

---

## 5. 为什么这样设计（被否决的四个方案）

**方案 A：每次扩容重算下标（JDK 7 的做法）。** JDK 7 的 `transfer` 里是 `int i = indexFor(e.hash, newCapacity);`。否决原因：每个元素多一次运算；重算后分布完全重来，无法整段拼接；还要配合 `hashSeed` 做可选的 hash 重算，复杂度高。

**方案 B：扩容 1.5 倍（像 ArrayList）。** 否决原因最硬：① 1.5 倍后容量不再是 2 的幂，`hash & (n-1)` 立刻失效，只能用 `% n`；② 掩码不是「旧掩码多一个 1」，元素可能落到任意桶，必须重算；③ 「只差一位」的规律不存在了。**1.5 倍省空间，2 倍省 CPU**，而 HashMap 的定位比 ArrayList 的顺序访问频繁得多。

**方案 C：像 Redis 那样渐进式 rehash。** Redis 维护两张表、每次操作顺带搬一个桶。否决原因：HashMap 不是并发容器，扩容期间本就不该有别的线程访问，一次性搬完的停顿只是「这一次 put 慢一点」；引入双表状态会让每次读写都要判断「在旧表还是新表」，复杂度和 bug 风险不划算。

**方案 D：不扩容，靠红黑树兜底。** 既然桶长了会树化，那全树化行不行？否决：`TreeNode` 内存翻倍；O(log n) 比 O(1) 慢；树化解决的是极端碰撞（恶意构造 hash），不是正常增长。**树化是兜底，扩容才是常态。**

---

## 6. 关键参数为什么是这个值

### 6.1 为什么容量是 2 的幂

`hash & (n-1)` 只在 n 为 2 的幂时等价于 `hash % n`，位运算比除法快；`n-1` 是全 1 掩码，分布均匀；扩容时新旧掩码只差一位，迁移可用一个 bit 判断。三条缺一不可。

### 6.2 为什么阈值是 0.75

阈值 = 容量 × 0.75。太高（如 1.0）链表变长、查询变慢；太低（如 0.5）空间浪费一半、扩容更频繁。0.75 是时空折中；从概率上看，负载因子 0.75 时桶内元素数期望约 0.5，链长到 8 的概率是 6e-8 量级（下一篇详解）。

### 6.3 为什么初始容量是 16

16 是最小的「足够用」的 2 的幂：默认阈值 12，小 Map 往往一次扩容都不用；再小（8）稍大业务字典就要扩两次；再大（32）小 Map 浪费内存。这是基于「绝大多数 HashMap 实例都很小」的经验取值。

### 6.4 为什么最大容量是 `1 << 30`

`1 << 31` 是负数（int 符号位），当容量会导致 `oldCap << 1` 变负、数组分配报错；`capacity × 0.75` 也会溢出。取 2^30 = 1073741824 后，阈值最大 805306368，int 装得下；到顶后 `resize` 走 `threshold = Integer.MAX_VALUE` 分支，等于永不扩容。

### 6.5 为什么 `tableSizeFor` 向上取 2 的幂

传 100 实际得到 128。做法是先 `cap - 1`（避免传 16 时被推到 32），再五次 `n |= n >>> 1/2/4/8/16` 把最高位后面全填 1，最后 +1。

---

## 7. 版本演进

**JDK 7**：`transfer` 三特征——重算下标、头插、可选的 hash 重算（`hashSeed` 机制）。头插是并发成环的根源。

**JDK 8**：改成一个 bit 判断去留、尾插 + lo/hi 两段拼接、树桶用 `TreeNode.split`（拆完某边 ≤6 就退化成链表），删掉 `hashSeed`。

**JDK 9 / 17**：扩容算法未变。相关变化只有 `String` 内部改成 `byte[] + coder`（影响 key 的 hashCode 计算，不影响扩容）、偏向锁逐步废弃（与 HashMap 无关但常一起问）。

**JDK 21**：依然没变，亮点（虚拟线程、分代 ZGC）都在更上层。**所以「扩容机制」这个问题，JDK 8 的答案到 21 都成立。**

---

## 8. 亲手验证

### 8.1 观察容量与阈值

```java
import java.lang.reflect.Field;
import java.util.*;

public class ResizeProbe {
    static Object[] table(HashMap<?, ?> m) throws Exception {
        Field f = HashMap.class.getDeclaredField("table");
        f.setAccessible(true);
        return (Object[]) f.get(m);
    }
    static int threshold(HashMap<?, ?> m) throws Exception {
        Field f = HashMap.class.getDeclaredField("threshold");
        f.setAccessible(true);
        return f.getInt(m);
    }
    public static void main(String[] args) throws Exception {
        HashMap<Integer, Integer> m = new HashMap<>();
        System.out.println("首次 put 前：table=" + (table(m) == null ? "null" : table(m).length));
        for (int i = 1; i <= 40; i++) {
            m.put(i, i);
            if (i == 1 || i == 12 || i == 13 || i == 24 || i == 25) {
                System.out.printf("放入 %2d 个后：capacity=%d，threshold=%d%n",
                        i, table(m).length, threshold(m));
            }
        }
    }
}
```

```bash
javac -encoding UTF-8 ResizeProbe.java
java --add-opens java.base/java.util=ALL-UNNAMED ResizeProbe
```

预期输出（重点看 12→13、24→25）：

```
首次 put 前：table=null
放入  1 个后：capacity=16，threshold=12
放入 12 个后：capacity=16，threshold=12
放入 13 个后：capacity=32，threshold=24
放入 24 个后：capacity=32，threshold=24
放入 25 个后：capacity=64，threshold=48
```

### 8.2 复现 JDK 7 头插成环

一个线程精确模拟两个线程的交错：线程 1 执行完 `next = e.next` 挂起，线程 2 完整迁移，线程 1 再恢复。

```java
import java.util.IdentityHashMap;

public class RingDemo {
    static class Entry {
        final int hash; Entry next;
        Entry(int hash, Entry next) { this.hash = hash; this.next = next; }
        public String toString() { return "E" + hash; }
    }
    static String dump(Entry head) {
        StringBuilder sb = new StringBuilder();
        IdentityHashMap<Entry, Boolean> seen = new IdentityHashMap<>();
        for (Entry p = head; p != null; p = p.next) {
            sb.append(p).append(" -> ");
            if (seen.put(p, Boolean.TRUE) != null)
                return sb.append("(回到 ").append(p).append("，成环)").toString();
        }
        return sb.append("null").toString();
    }
    public static void main(String[] args) {
        // hash=1 与 33 的低 5 位相同，容量 16 和 32 下都落同一个桶
        Entry A = new Entry(1, null), B = new Entry(33, null);
        A.next = B;
        Entry[] oldTable = new Entry[16];
        oldTable[1] = A;

        Entry e = oldTable[1];
        Entry next = e.next;                       // 线程1 在这里挂起
        System.out.println("[线程1] 挂起：e=" + e + "，next=" + next);

        Entry[] t2 = new Entry[32];                // 线程2 完整迁移（头插）
        for (Entry x = oldTable[1]; x != null; ) {
            Entry nx = x.next;
            int i = x.hash & 31;
            x.next = t2[i];
            t2[i] = x;
            x = nx;
        }
        System.out.println("[线程2] 迁移完成，桶1 = " + dump(t2[1]));

        Entry[] t1 = new Entry[32];                // 线程1 恢复
        while (e != null) {
            int i = e.hash & 31;
            e.next = t1[i];
            t1[i] = e;
            e = next;
            if (e != null) next = e.next;
        }
        System.out.println("[线程1] 恢复后自己的桶1 = " + dump(t1[1]));
    }
}
```

预期输出：

```
[线程1] 挂起：e=E1，next=E33
[线程2] 迁移完成，桶1 = E33 -> E1 -> null
[线程1] 恢复后自己的桶1 = E1 -> E33 -> E1 -> (回到 E1，成环)
```

**逐帧解释**：线程 2 头插完把顺序反转成 `B -> A`，即 `B.next = A`。线程 1 恢复后手里还是 `e=A, next=B`：先 `A.next=null`、`t1[i]=A`；再 `e=B`，重取 `next=B.next` 得到 **A**（线程 2 写的）；然后 `B.next=A`、`t1[i]=B`；最后 `e=A`，重取 `next=A.next=null`，执行 `A.next=t1[i]=B`。于是 `A -> B -> A` 成环。之后任何命中该桶的 `get()` 都会死循环、CPU 打满。

---

## 9. 常见误区

| 错误说法 | 正确说法 |
|---|---|
| 「扩容要重新计算每个 key 的 hashCode」 | 不用，`Node.hash` 缓存了扰动后的值，只看 `& oldCap` |
| 「扩容后所有元素都换桶」 | 约一半留原位、一半移到 `原下标 + 旧容量` |
| 「HashMap 扩容是 1.5 倍」 | 2 倍；1.5 倍是 ArrayList |
| 「size 等于容量时才扩容」 | 是 `size > threshold`（默认 12 就触发） |
| 「2 倍是为了省空间」 | 是为了保持 2 的幂、让迁移只差一位 |
| 「JDK 8 扩容也成环」 | 尾插不成环，但并发 put 仍会覆盖丢数据 |
| 「初始容量传 100 就是 100」 | `tableSizeFor` 向上取 2 的幂，实际 128 |
| 「扩容是渐进的」 | HashMap 一次性搬完；渐进式 rehash 是 Redis 的做法 |

---

## 10. 连续追问 Q&A

### Q1：为什么新下标只可能是「原下标」或「原下标 + 旧容量」？
**答**：容量是 2 的幂。旧掩码 k 个 1，新掩码 k+1 个 1，只多第 k 位；第 k 位为 0 下标不变，为 1 就加上 2^k（正好是旧容量）。

### Q2：为什么判断式是 `& oldCap` 而不是 `& newCap`？
**答**：要看的是第 k 位。`oldCap = 2^k` 的二进制恰好只有第 k 位为 1，`e.hash & oldCap` 直接取出该位；`newCap = 2^(k+1)` 取的是还没参与定位的更高位。

### Q3：会不会出现三个元素分到三个桶？
**答**：不会。一次扩容只多一位参与寻址，一个旧桶最多分裂成两个新桶；除非容量一次翻四倍。

### Q4：扩容时 `e.hash` 从哪来？
**答**：`Node` 有 `final int hash`，存的是 `put` 时算好的扰动值；扩容只读它，不碰 `key.hashCode()`，所以自定义 hashCode 再慢也不影响扩容。

### Q5：为什么扩容用尾插？
**答**：头插会把链表顺序反转，这正是并发成环的根源；尾插保持原顺序、不成环，代价是多遍历一次链表，但链表通常很短。

### Q6：红黑树桶怎么迁移？
**答**：`TreeNode.split` 同样按 `(e.hash & bit)` 分成 lo/hi 两组，各组装成一棵树；某组节点数 ≤ `UNTREEIFY_THRESHOLD`（6）就退化回链表。

### Q7：扩容会影响遍历顺序吗？
**答**：会。顺序取决于元素在 `table` 中的位置，一半元素换了桶。所以不能依赖 HashMap 的遍历顺序，需要顺序就用 `LinkedHashMap`。

### Q8：怎样减少扩容次数？
**答**：预估容量并显式传入，注意会被向上取 2 的幂。要放 1000 个元素，应传 `(int)(1000 / 0.75) + 1 = 1334`，得到容量 2048、阈值 1536，一次都不扩容（JDK 的 `putMapEntries` 就是这么算的）。

### Q9：扩容和树化谁先触发？
**答**：看不同条件。树化看单桶链表长度 ≥8 且容量 ≥64；扩容看全表 `size > threshold`。链表到 8 但容量 <64 时，`treeifyBin` 会先扩容而不是树化。

### Q10：JDK 7 成环需要什么条件？
**答**：两个线程同时扩容同一张表、有元素被迁到同一桶、且线程 1 恰好在 `next = e.next` 之后被打断。所以是竞态而非必然，这也是它难排查的原因。

### Q11：为什么不改成渐进式扩容？
**答**：HashMap 不是并发容器，扩容时不该有并发访问；一次性 O(n) 均摊下来仍是 O(1)。渐进式要维护双表和迁移游标，每次操作都要判断 key 在哪张表，复杂度不划算。

---

## 11. 一张图总结

```
size > threshold ?
      │
      ▼
  resize(): newCap = oldCap << 1，newThr = oldThr << 1
      │
      ├── 空桶           -> 跳过
      ├── 单节点         -> newTab[e.hash & (newCap-1)] = e
      ├── 红黑树桶       -> TreeNode.split（≤6 退化）
      └── 链表桶         -> 按 (e.hash & oldCap) 拆成 lo / hi
                             lo -> newTab[j]          （原顺序）
                             hi -> newTab[j + oldCap] （原顺序）

  核心：不重算 hashCode、不重算 hash、不取模，只看一个 bit；
        总搬迁量 ≈ 2n -> put 均摊 O(1)。
```

---

## 12. 一句话复盘

> 扩容 = 容量翻倍 + 每个桶按 `hash & oldCap` 分成两队，0 留原位、1 移到 `原位 + oldCap`。因为容量永远是 2 的幂，新旧掩码只差一位，所以既不用重算 hash 也不用取模；选 2 倍而不是 1.5 倍，正是为了让「只差一位」成立。JDK 8 从头插改尾插，消除了成环，但并没有让 HashMap 变成线程安全。

---

## 13. 自测题（先自己答，再看答案）

**1. 容量 16，某元素原下标 7，什么条件下新下标是 23？**
答案：`hash & 16 != 0`，即第 4 位为 1，新下标 = 7 + 16 = 23。

**2. 默认构造的 HashMap 放第几个元素触发第一次扩容？**
答案：第 13 个。容量 16、阈值 12，`13 > 12` 触发。

**3. 扩容会重新调用 `hashCode()` 吗？为什么？**
答案：不会。`Node` 的 `final int hash` 缓存了扰动值，扩容只读它。

**4. 为什么是 2 倍而不是 1.5 倍？**
答案：2 倍保持 2 的幂，`& (n-1)` 继续有效，新旧掩码只差一位，迁移可用一个 bit 判断并整段拼接；1.5 倍会破坏 2 的幂，只能取模且必须重算。

**5. 复述 JDK 7 成环的关键步骤。**
答案：线程 1 在 `next = e.next` 后挂起；线程 2 头插迁移导致顺序反转、写下 `B.next = A`；线程 1 恢复后按头插继续，写下 `A.next = B`，形成 `A -> B -> A`，遍历该桶死循环。

**6. 初始容量传 100，实际容量和阈值？**
答案：`tableSizeFor(100) = 128`，阈值 128 × 0.75 = 96。

---

## 14. 关联文件

- 上一篇精讲：[HashMap 的 hash() 为什么要做高低 16 位异或扰动](01-HashMap-hash扰动.md)
- 深一层：[HashMap 底层](../../10-deep-dive/java/01-HashMap.md)
- 下一篇精讲：[红黑树与树化：为什么阈值是 8 和 64](03-红黑树与树化.md)
- 并发替代品：[ConcurrentHashMap](../../10-deep-dive/java/12-ConcurrentHashMap.md)
- 返回：[精讲索引](../00-索引.md)
