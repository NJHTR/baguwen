# Java 基础与并发

> 面试权重：5/5（必考）　|　建议投入：7 天
> 适用场景：所有 Java 后端岗的一/二面。集合、并发、JVM 是大厂硬门槛；中小厂更爱问 String、异常、反射这些「你到底用没用过」的问题。

**模块定位**：本章是 [SpringBoot 与后端工程](SpringBoot与后端工程.md) 的地基——Bean 容器本质是个 `ConcurrentHashMap`，`@Transactional` 靠 `ThreadLocal` 绑定数据库连接；JVM 与 GC 和 [MySQL 与 Redis](../04-database/MySQL与Redis.md) 一起构成「性能优化」的两条腿；并发控制思路可直接迁移到 [系统设计](../06-system-design/系统设计入门.md) 的库存扣减与限流。

**使用建议**：先背「一句话答案」拿分 → 用「原理展开」补细节扛追问 → 用「60 秒版」开口练 → 用「追问陷阱」自查。卡壳时永远先给结论，再等面试官追问方向。

## 1. 面向对象三大特性与设计原则

**一句话答案**：封装藏细节、继承做复用、多态「编译看左边、运行看右边」；设计上守 SOLID，最常被问的是接口与抽象类的取舍。

**原理展开**：
- 封装：`private` 字段 + getter/setter，把「怎么存」与「怎么用」解耦，改内部实现不破坏调用方。
- 继承：`extends` 单继承、`super` 调父类；Java 不支持类多继承，但接口可多实现。
- 多态成立三条件：有继承或实现关系、子类重写父类方法、父类引用指向子类对象。
- 分派机制：重载是**编译期静态分派**（看参数编译期类型），重写是**运行期动态分派**（看实际类型，靠虚方法表）。
- 接口 vs 抽象类：接口是「能做什么」的契约，可多实现，JDK8 起有 `default/static` 方法；抽象类是「是什么」的半成品模板，单继承，可有构造器与实例字段。
- SOLID：单一职责、开闭（对扩展开放对修改关闭）、里氏替换（子类能透明替换父类）、接口隔离（小接口优于胖接口）、依赖倒置（依赖抽象不依赖实现）。
- 另两条：合成复用（优先组合而非继承）、迪米特法则（少暴露、少依赖）。

**面试怎么答（60 秒版）**：三大特性是封装、继承、多态。封装把状态藏起来只暴露行为；继承复用父类能力，Java 只支持单继承，所以更推崇组合优于继承；多态让同一调用在不同对象上有不同表现，条件是继承、重写、父类引用指向子类对象，它靠虚方法表在运行期分派，是框架「面向接口编程」的基础。设计上我一般守单一职责和开闭原则，接口定义契约、抽象类提供骨架。

**追问陷阱**：
- 错误：说「重载也是多态」→ 正确：重载属于编译期静态分派，不算运行时多态；所以「重载能否按返回值区分」答案是**不能**。
- 错误：说「继承越多复用越好」→ 正确：继承让子类耦合父类实现细节，优先组合，这是合成复用原则。

## 2. == vs equals vs hashCode

**一句话答案**：`==` 比基本类型值、比引用地址；`equals` 默认也比地址、按业务重写后比值；两者必须成对重写，否则对象进不了哈希容器的桶。

**原理展开**：
- `Object.equals` 源码就是 `return (this == obj)`；`String`、`Integer`、`Date` 等值类型重写成了内容比较。
- 契约：`equals` 相等则 `hashCode` 必须相等；`hashCode` 相等 `equals` 未必相等（允许冲突，越少越好）。
- 只重写 `equals` 不重写 `hashCode`：两个「相等」的对象 hash 不同、落到不同桶，`HashMap.get` 取不到，`HashSet` 去重失效。
- 包装类缓存：`IntegerCache` 缓存 `-128~127`，`Integer a=127,b=127` 时 `a==b` 为 true、`128` 为 false；比值一律 `equals`。
- 重写 `hashCode` 常用 `Objects.hash(f1, f2)` 或 `31 * result + field`；选 31 因它是奇素数冲突少，且 `31*i == (i<<5)-i` 可被 JIT 优化。
- 判断题：`new String("a") == new String("a")` 为 false（堆上两个对象）；`new String("a").intern() == "a"` 为 true。
- 工程习惯：实体类用 Lombok `@Data`/`@EqualsAndHashCode` 自动成对生成，但要注意只对业务主键字段比较。

**面试怎么答（60 秒版）**：`==` 对基本类型比值，对引用比地址。`equals` 是 Object 的方法，默认等价于 `==`，业务类会重写成按关键字段比较。两者有契约：`equals` 相等则 `hashCode` 必须相等，所以必须一起重写，否则对象放进 HashMap 或 HashSet 会出现「存进去了却取不出来」。另外包装类有缓存区间，`==` 比较包装类结果不可靠，判值一律用 `equals`。

**追问陷阱**：
- 错误：把契约反过来，说「hashCode 相等 equals 就相等」→ 正确：不成立，哈希冲突本来就允许。
- 错误：用 `==` 比 `Integer` 后认为「Java 有 bug」→ 正确：是自动装箱缓存导致，明确说「比值用 equals」。

## 3. String / StringBuilder / StringBuffer 与字符串常量池

**一句话答案**：String 不可变、字面量进字符串常量池；频繁拼接用 StringBuilder（非线程安全、快），多线程共享同一个才用 StringBuffer。

**原理展开**：
- 不可变的实现：类 `final`、字段 `final`、不提供修改方法；JDK8 是 `private final char[] value`，JDK9+ 改 `byte[] value + byte coder` 省内存。
- 不可变换来三件事：线程安全、`hash` 可缓存（HashMap 定位快）、可安全共享（常量池复用）。
- 字符串常量池：JDK7 起从方法区移到**堆**（`StringTable`）；`"a"` 先查池，有则复用、无则创建。
- `new String("a")` 至少创建 1 个对象（池中已有）或 2 个（池 + 堆），返回的是堆对象，所以 `==` 为 false。
- `intern()` 把堆中字符串尝试放入池并返回池引用，是「`==` 是否为 true」类题目的钥匙。
- 循环里 `s += i` 每次 `new StringBuilder` 再 `toString`，复杂度 O(n²)；正确写法是循环外建一个 `StringBuilder`，预设容量。
- `StringBuilder` 默认容量 16，扩容 `(oldCap << 1) + 2`；`StringBuffer` 在方法上加 `synchronized`，有锁开销，属于老代码。

**面试怎么答（60 秒版）**：String 是不可变类，所以线程安全、能缓存 hash，但每次「修改」都是新建对象。字面量放在字符串常量池里复用，`new String` 会在堆上另建对象。因此频繁拼接要用 StringBuilder，它内部是可扩容字符数组、不保证线程安全；StringBuffer 对它加了锁，现在基本只出现在老代码里。JDK9 之后底层从 char[] 换成了 byte[] 加编码标记，为了省内存。

**追问陷阱**：
- 错误：「String 不可变所以拼接一定慢」→ 正确：编译期常量折叠不慢，慢的是循环里对变量反复 `+=`。
- 错误：说常量池在方法区 → 正确：JDK7 后在堆，JDK8 方法区实现为元空间（本地内存）。

## 4. 集合框架总览与 ArrayList vs LinkedList

**一句话答案**：`Collection` 下分 List（有序可重复）、Set（去重）、Queue（队列），Map 独立成体系；ArrayList 查快，LinkedList 头尾增删快但定位慢，实践中几乎只用 ArrayList + ArrayDeque。

**原理展开**：
- 体系：`List`（ArrayList / LinkedList / CopyOnWriteArrayList）、`Set`（HashSet / LinkedHashSet / TreeSet）、`Queue`（ArrayDeque / PriorityQueue）；`Map` 不继承 Collection，有 HashMap / LinkedHashMap / TreeMap / ConcurrentHashMap。
- Set 去重靠 `hashCode + equals`（HashSet）或比较器（TreeSet）；Map 键唯一。
- ArrayList 底层 `Object[] elementData`，默认容量 10（首次 add 才分配），扩容 `oldCap + (oldCap >> 1)` 即 **1.5 倍**，靠 `Arrays.copyOf` 复制。
- ArrayList 随机访问 O(1)、尾部追加均摊 O(1)；中间 `add(index, e)` 要 `System.arraycopy` 搬移，O(n)。
- LinkedList 是双向链表，每节点多两个指针；`get(index)` 按 index 与 size/2 比较决定从头还是从尾遍历，仍是 O(n)。
- 「LinkedList 插入快」是半错：找位置本身 O(n)，只有已持有节点引用（如迭代器）时才 O(1)。
- fail-fast：迭代时用 `modCount` 检测结构性修改，被外部改过就抛 `ConcurrentModificationException`；应改用 `iterator.remove()`。`CopyOnWriteArrayList`/`ConcurrentHashMap` 属于 fail-safe，不抛 CME 但读到的是弱一致快照。
- 其他坑：`Arrays.asList()` 返回固定长度 List 不能 add；`List.of()` 不可变；`subList()` 是视图不是拷贝。

**面试怎么答（60 秒版）**：集合分两大类，Collection 下面有 List、Set、Queue，Map 是独立的。ArrayList 是数组实现，查得快、尾部加得快，中间插删要移动元素，扩容是 1.5 倍复制，所以已知大小时最好指定初始容量。LinkedList 是双向链表，理论上插删快，但定位是 O(n)，还有额外指针和缓存不友好，真实业务里基本用 ArrayList，需要队列时用 ArrayDeque。另外遍历时删除元素要小心 fail-fast，会抛 ConcurrentModificationException，应该用迭代器的 remove。

**追问陷阱**：
- 错误：「ArrayList 扩容是 2 倍」→ 正确：是 1.5 倍（`oldCap + (oldCap >> 1)`），HashMap 才是 2 倍。
- 错误：「LinkedList 查询慢所以一无是处」→ 正确：它实现了 Deque，做栈/队列头尾操作 O(1)，但和 ArrayDeque 比仍不推荐。

## 5. HashMap 底层原理

**一句话答案**：JDK8 是「数组 + 链表 + 红黑树」，用扰动后的 hash 定位桶；链表长度 ≥8 且容量 ≥64 才树化；容量默认 16、负载因子 0.75、扩容翻倍；它**线程不安全**。

**原理展开**：
- 结构：`Node<K,V>[] table`，懒初始化，首次 put 才 `resize()` 到 16。
- 哈希扰动：`hash = (h = key.hashCode()) ^ (h >>> 16)`，把高 16 位异或到低位；因为桶下标只用低几位，不扰动会丢掉高位差异。
- put 流程：算 hash → `(n-1) & hash` 定位桶 → 桶空直接放 → 桶首 key 相同则覆盖 → 树节点走树插入 → 否则**尾插**链表。
- 树化条件：链表长度 ≥ `TREEIFY_THRESHOLD(8)` **且** `table.length >= MIN_TREEIFY_CAPACITY(64)`，否则只扩容；节点数降到 6 才退化回链表（留缓冲防频繁转换）。
- 扩容：阈值 `threshold = capacity * loadFactor(0.75)`，容量翻倍；JDK8 rehash 优化——`(e.hash & oldCap) == 0` 留原下标 j，否则移到 `j + oldCap`，不用重算 hash。
- **为什么容量是 2 的幂**：`hash & (n-1)` 只在 n 为 2 的幂时等价于 `hash % n`，位运算更快；且扩容时元素只会「留原位或 +oldCap」，迁移逻辑极简。
- **为什么线程不安全**：并发 put 互相覆盖丢数据、`++size` 非原子导致 size 不准；JDK7 头插在并发扩容时会形成**环形链表**让 `get` 死循环（JDK8 改尾插修掉死循环，但仍不安全）。
- 其他特性：允许一个 null key（hash 取 0，落 0 号桶）和多个 null value；遍历顺序不保证；`LinkedHashMap` 用双向链表维护插入/访问顺序，可做 LRU。JDK7→8 三处差异：加红黑树、头插改尾插、扩容改高位判断。

**面试怎么答（60 秒版）**：JDK8 的 HashMap 是数组加链表加红黑树。put 时先对 hashCode 做高低 16 位异或扰动，再和数组长度减一做与运算定位桶；桶空就放，冲突就挂到链表尾部，链表到 8 且数组容量到 64 就转红黑树，防止极端情况退化成 O(n)。元素数超过容量乘 0.75 就翻倍扩容，利用 2 的幂让元素只可能留在原位或后移一个旧容量，非常高效。它不支持并发，多个线程 put 会丢数据，多线程要用 ConcurrentHashMap。

**追问陷阱**：
- 错误：「链表到 8 就转红黑树」→ 正确：还要求数组长度 ≥64，否则优先扩容。
- 错误：说「JDK8 改尾插就线程安全了」→ 正确：只解决了死循环，覆盖写和 size 错乱仍在。
- 错误：「HashMap 不能放 null」→ 正确：能放 null key 和 null value；`Hashtable`/`ConcurrentHashMap` 才不允许（并发下无法区分「不存在」与「值为 null」）。

## 6. ConcurrentHashMap 原理

**一句话答案**：JDK8 抛弃 Segment 分段锁，改成「CAS 放空桶 + synchronized 锁单个桶头 + 多线程协助扩容」，读操作无锁（volatile 读）。

**原理展开**：
- JDK7：`Segment[]` 分段锁，每个 Segment 继承 `ReentrantLock`，默认 16 段 = 并发度 16，锁粒度太粗。
- JDK8 结构：`Node[] table`，锁粒度细到单个桶；并发度约等于桶数量。
- put 流程：表未初始化先 `initTable()`（CAS 抢 `sizeCtl`）→ 桶为空用 CAS 放入 → 桶首 hash 为 `MOVED(-1)` 说明在扩容，当前线程 `helpTransfer` 帮忙 → 否则 `synchronized (f)` 锁桶头，链表尾插/树插/覆盖。
- 扩容：`transfer` 支持多线程分工迁移，迁完的桶放 `ForwardingNode` 标记，读线程遇到会去新表找。
- size 统计：`baseCount + CounterCell[]` 分片计数（思想同 `LongAdder`），避免所有线程 CAS 同一个值；`size()` 是近似值。
- get 完全无锁：`tabAt` 是 volatile 读，配合 Node 的 `volatile V val` 保证可见性。
- 不允许 null key/value：并发下 `get` 返回 null 无法区分「键不存在」和「值为 null」。

**面试怎么答（60 秒版）**：JDK7 的 ConcurrentHashMap 用 Segment 分段锁，并发度等于段数；JDK8 把它简化成 Node 数组，锁粒度细到单个桶：桶空时 CAS 直接放，桶非空时只 synchronized 锁这个桶的头节点，其他桶不受影响，所以并发度约等于桶数。扩容允许多个线程一起迁移，用 ForwardingNode 做标记。读操作不加锁，靠 volatile 保证可见性。size 用 baseCount 加分片计数数组来减少竞争。

**追问陷阱**：
- 错误：「还是用分段锁」→ 正确：JDK8 已移除 Segment，源码里只是保留兼容声明。
- 错误：「CHM 一定比 HashMap 慢」→ 正确：读几乎无额外开销，只有写有 CAS/synchronized 成本；并发下远好于 `Collections.synchronizedMap` 的一大把锁。

## 7. 异常体系与 try-with-resources

**一句话答案**：`Throwable` 下分 `Error`（不可恢复）和 `Exception`（受检 + 非受检）；`finally` 一定执行，`try-with-resources` 自动按逆序关闭 `AutoCloseable`。

**原理展开**：
- 体系：`Throwable` → `Error`（`OutOfMemoryError`、`StackOverflowError`，业务不该 catch）/ `Exception` → 受检异常（`IOException`、`SQLException`，编译期强制处理）+ `RuntimeException`（`NPE`、`IllegalArgumentException`，编程错误）。
- 易混对比：`NoClassDefFoundError` 是类加载失败（Error），`ClassNotFoundException` 是 `Class.forName` 找不到（受检 Exception）。
- `finally` 在 `return` 之前执行，但 `finally` 里的 `return` 会**覆盖** try 的返回值并吞掉异常——明确禁止；`System.exit()`、JVM 崩溃时不执行 finally。
- try-with-resources：资源实现 `AutoCloseable`，编译器生成 finally 里按**声明逆序** close，close 抛的异常挂成 suppressed（`getSuppressed()`），不会覆盖主异常。
- 性能：异常开销主要在建栈轨迹，别用异常做流程控制；大 try 包住所有逻辑会掩盖问题。
- 规范：捕获后要么处理、要么包装成业务异常抛，禁止 `catch (Exception e) {}` 静默吞掉（配 `@Transactional` 时会静默提交）。
- 自定义异常：继承 `RuntimeException` 并带业务 code，交给全局异常处理器统一转响应。

```java
try (Connection conn = ds.getConnection();
     PreparedStatement ps = conn.prepareStatement(SQL)) {
    ps.setLong(1, userId);
    ps.executeUpdate();
} catch (SQLException e) {          // 关闭时的异常会挂到 suppressed
    throw new BizException("扣减库存失败", e);
}
```

**面试怎么答（60 秒版）**：Throwable 分 Error 和 Exception，Error 是虚拟机层面不可恢复的问题，比如 OOM，业务不该捕获；Exception 又分受检和非受检，受检必须显式处理，运行时异常多是编程错误。finally 一定会执行，除非 JVM 退出，但不要在 finally 里 return，会覆盖返回值。资源释放我优先用 try-with-resources，它要求资源实现 AutoCloseable，编译后会自动按逆序关闭，还能把关闭时的异常挂成 suppressed，比手写 finally 更不容易漏异常。

**追问陷阱**：
- 错误：「finally 一定会执行」→ 正确：`System.exit()`、JVM 崩溃、进程被 kill 时不执行。
- 错误：「catch 了异常事务也会回滚」→ 正确：正相反，`@Transactional` 只有异常抛到代理层才回滚，吞异常会静默提交。
- 错误：在 finally 里 `return` → 正确：覆盖 try 返回值并吞异常，直接判负分。

## 8. 泛型与类型擦除

**一句话答案**：Java 泛型只在编译期检查，编译后擦除为 `Object` 或上界，运行时没有泛型信息——这就是「类型擦除」。

**原理展开**：
- 擦除规则：`List<String>` 与 `List<Integer>` 运行时都是 `List`；`T` 擦成 `Object`，`T extends Number` 擦成 `Number`。
- 后果：不能 `new T()`、不能 `T.class`、不能 `new T[]`、不能 `instanceof List<String>`、类的静态成员不能用类级泛型参数。
- 桥接方法：擦除后子类 `compareTo(MyType)` 与父类 `compareTo(Object)` 签名不一致，编译器自动生成 bridge 方法保证多态调用正确。
- 通配符 PECS：`? extends T` 是「生产者」只能读（编译器不知道具体子类型，写不进去）；`? super T` 是「消费者」能写，但读出来只是 Object。
- 为什么擦除：兼容 JDK5 之前的字节码，`List` 与 `List<String>` 共用同一份类，老代码不用改。
- 框架怎么拿泛型：通过 `ParameterizedType` 反射父类上声明的真实类型，Jackson 的 `TypeReference`、MyBatis 的泛型 Mapper 都这么干。
- 泛型方法：`<T> T get(Class<T> clazz)` 把 Class 传进去绕过「不能 `T.class`」的限制。

**面试怎么答（60 秒版）**：Java 泛型是编译期特性，本质是类型擦除，`List<String>` 和 `List<Integer>` 在运行时是同一个类，所以不能 new 泛型对象、不能取泛型 Class、不能建泛型数组。擦除是为了兼容 JDK5 之前的代码。擦除还会带来桥接方法来维持多态。使用时通配符遵循 PECS：extends 用于只读的生产者，super 用于只写的消费者。

**追问陷阱**：
- 错误：「泛型能保证运行时类型安全」→ 正确：它把类型检查提前到编译期，运行时仍可能因擦除有隐患。
- 错误：分不清 `List<Object>` 与 `List<?>` → 正确：前者只能放 Object，后者是未知类型的只读视图；`List<String>` 可赋给 `List<?>` 但不能赋给 `List<Object>`。

## 9. 反射与应用场景

**一句话答案**：反射是运行时获取类信息并操作对象的能力；框架靠它实现「配置即代码」，代价是性能损耗与封装破坏。

**原理展开**：
- 获取 `Class` 三种方式：`User.class`、`user.getClass()`、`Class.forName("com.x.User")`（会触发类初始化）。
- 常用 API：`getDeclaredFields/Methods/Constructors`（含私有）、`setAccessible(true)` 关安全检查、`newInstance()`、`Method.invoke(obj, args)`。
- 框架中的真实用途：Spring 扫描注解并反射实例化 Bean / 注入依赖；MyBatis 把 `ResultSet` 反射映射成实体；JDBC 用 `Class.forName` 加载驱动；Jackson 序列化读写字段。
- 注解本身不自带行为，只有靠反射（或编译期 APT）读取才有意义——这是「注解原理」的标准答法。
- 缺点：性能（查找与安全检查开销，`setAccessible` 后 JIT 可优化但仍有差距）、绕过编译期检查、破坏封装、JDK9 模块化后需 `opens` 授权。
- 优化：缓存 `Method`/`Field` 对象避免每次查找，Spring 的 `ReflectionUtils` 就在做这件事。
- 替代方案：编译期注解处理器（Lombok、MapStruct）零运行时开销，但只能生成代码、不能改运行期行为。

**面试怎么答（60 秒版）**：反射是程序运行时动态获取类结构并调用它的能力，核心是 Class 对象，可以拿到构造器、方法、字段，甚至访问私有成员。它的价值在于框架的通用性：Spring 靠它实例化 Bean 和注入属性，MyBatis 靠它把查询结果映射成实体，我们自己的业务代码几乎不直接写反射。代价是性能比直接调用差、绕过了编译期检查、也破坏了封装，所以业务代码里一般用注解配合框架来间接使用。

**追问陷阱**：
- 错误：「反射性能极差」→ 正确：有额外开销但被框架缓存后可控，`setAccessible(true)` 也能缩小差距。
- 错误：只会说「反射能拿私有方法」→ 正确：必须能举框架场景，并说出「注解靠反射生效」。

## 10. JVM 内存区域

**一句话答案**：线程私有的是程序计数器、虚拟机栈、本地方法栈；线程共享的是堆和方法区（JDK8 用元空间实现，在本地内存）。

**原理展开**：
- 程序计数器：当前字节码行号，唯一不会 OOM 的区域。
- 虚拟机栈：栈帧含局部变量表、操作数栈、动态链接、返回地址；递归过深抛 `StackOverflowError`（是 Error 不是 OOM）。
- 本地方法栈：服务 native 方法；直接内存：`DirectByteBuffer`（NIO/Netty 用），不受堆参数限制但受物理内存限制。
- 堆：对象实例主战场，分 `Eden : S0 : S1 : Old` 默认 8:1:1，新生代占堆 1/3；`-Xms/-Xmx` 控制大小。
- 方法区：存类元信息、常量、静态变量；JDK7 是永久代 → JDK8 换元空间（`Metaspace`，本地内存，`-XX:MaxMetaspaceSize`），解决永久代容易 OOM 的问题。
- 四类 OOM：堆 OOM（对象太多/泄漏）、Metaspace OOM（动态生成类过多，反射/字节码增强/热部署）、直接内存 OOM、`GC overhead limit exceeded`。
- JDK8 细节：字符串常量池在**堆**，静态变量随 Class 对象在堆（元空间里只有类元数据）。

**面试怎么答（60 秒版）**：JVM 运行时内存分线程私有和共享两类。私有的有程序计数器、虚拟机栈、本地方法栈，计数器不会 OOM，栈会因递归过深 StackOverflow。共享的是堆和方法区：堆放对象，分新生代和老年代，新生代又是 Eden 加两个 Survivor；方法区在 JDK8 用元空间实现，直接把类元数据放本地内存，避免了永久代容易 OOM 的问题。另外还有一块直接内存，NIO 的堆外缓冲区用，不受堆参数限制。

**追问陷阱**：
- 错误：说「方法区就是永久代」→ 正确：JDK8 已移除永久代改元空间，且在本地内存不在堆里。
- 错误：混淆栈溢出与堆溢出 → 正确：递归是 `StackOverflowError`，不停 new 对象是 `OutOfMemoryError: Java heap space`。

## 11. 类加载与双亲委派

**一句话答案**：类加载分加载、验证、准备、解析、初始化五步；双亲委派是「先让父加载器加载，父加载不了才自己加载」，保证核心类安全与不重复加载。

**原理展开**：
- 过程：加载（读字节码生成 Class 对象）→ 验证（字节码合法）→ **准备（static 变量赋零值，`static final` 常量直接赋终值）**→ 解析（符号引用转直接引用）→ 初始化（执行 `<clinit>`，真正赋代码里的值）。
- 初始化触发时机：`new`、访问静态字段/方法、反射、子类初始化先初始化父类、启动类 main。
- 三层加载器：`Bootstrap`（加载 `java.*`）、`Platform`（原 Ext，`javax.*` 等）、`App`（classpath，自己的代码）；自定义加载器重写 `findClass` 即可。
- 双亲委派的价值：安全（自己写个 `java.lang.String` 不会被加载，防核心类被篡改）、避免重复加载。
- 打破场景：JDBC SPI（接口在父加载器、实现在 classpath，靠 `Thread.currentThread().getContextClassLoader()`）、Tomcat 各 WebApp 独立加载器（隔离与热部署）、OSGi 模块化。
- 判断「两个类是否相同」：类加载器 + 全限定名都相同，否则即使同名也 `instanceof` 为 false。
- 与 SpringBoot 的关系：`LaunchedURLClassLoader` 加载 fat jar 里的 BOOT-INF，也是自定义类加载器的实战案例。

**面试怎么答（60 秒版）**：类加载分加载、验证、准备、解析、初始化，准备阶段只给静态变量赋零值，真正的赋值在初始化阶段的 clinit 里。双亲委派是加载类时先委派父加载器，父加载器找不到才自己加载，好处是避免核心类被篡改、也避免重复加载。打破它的典型场景是 JDBC 的 SPI，因为接口在父加载器、实现在 classpath，需要线程上下文类加载器。判断两个类是否相等必须类加载器相同。

**追问陷阱**：
- 错误：「准备阶段就给 static 变量赋代码里的值」→ 正确：准备阶段赋零值，代码值在初始化阶段赋。
- 错误：只会背定义 → 正确：要能说出打破场景（SPI/Tomcat）与「类加载器不同则类不同」的后果。

## 12. 垃圾回收（GC）

**一句话答案**：用可达性分析从 GC Roots 找活对象，按分代假说把新生代用复制算法、老年代用标记整理，主流收集器是 G1。

**原理展开**：
- 可达性分析：从 GC Roots（虚拟机栈引用、静态变量、常量、JNI 引用、活动线程）出发遍历引用链，不可达即可回收；不用引用计数（解决不了循环引用）。
- 引用强度：强 > 软（内存不足才回收，适合做缓存）> 弱（下次 GC 必回收，`ThreadLocalMap` 的 key）> 虚（回收前通知）。
- 分代假说：绝大多数对象朝生夕死，熬过多次 GC 的才进老年代；新生代用复制算法（Eden 与两个 Survivor 8:1:1，只浪费 10%）。
- 老年代标记清除（有碎片）或标记整理（无碎片但移动对象）；CMS 用标记清除所以有碎片问题。
- 晋升老年代条件：年龄到 `-XX:MaxTenuringThreshold`（默认 15）、大对象直接进、动态年龄判断（Survivor 中同龄对象总和超一半）、Survivor 放不下。
- 收集器演进：Serial（单线程）→ ParNew/Parallel（多线程，吞吐优先）→ CMS（并发标记清除，低停顿但有碎片、有 Concurrent Mode Failure）→ G1（Region 分区，可预测停顿，JDK9 默认）→ ZGC（超低停顿）。
- `System.gc()` 只是建议；`finalize()` 已废弃，别依赖它清理资源。

**面试怎么答（60 秒版）**：JVM 用可达性分析判断对象是否存活，从 GC Roots 出发遍历引用链，不可达就可以回收，这样能解决循环引用。回收按分代来：新生代对象多死得快，用复制算法，Eden 和两个 Survivor 按 8 比 1 比 1，只浪费一小块；老年代存活率高，用标记清除或标记整理，标记清除有内存碎片。对象熬过一定次数 GC 会晋升老年代。现在主流是 G1，把堆分成 Region，能设定目标停顿时间，JDK9 之后是默认收集器。

**追问陷阱**：
- 错误：「GC Roots 是堆里的对象」→ 正确：Roots 在堆外（栈、静态区、常量、JNI），引用链从堆外指向堆内。
- 错误：「Minor GC 会清理老年代」→ 正确：只清新生代；频繁 Full GC 要排查大对象、内存泄漏、元空间膨胀。
- 错误：「finalize 能保证对象被清理」→ 正确：不保证、不推荐，用 try-with-resources 或 Cleaner。

## 13. 线程创建与状态

**一句话答案**：创建方式有继承 Thread、实现 Runnable、实现 Callable+FutureTask、线程池四种；状态有 NEW、RUNNABLE、BLOCKED、WAITING、TIMED_WAITING、TERMINATED 六种。

**原理展开**：
- 优先实现 `Runnable`/`Callable`：Java 单继承，实现接口还能继承别的类，且任务与执行解耦。
- `Callable` 有返回值、能抛受检异常，配 `Future.get()` 拿结果（会阻塞，建议带超时）。
- `start()` 才启动新线程（JVM 调 native `start0`），直接 `run()` 只是普通方法调用。
- 状态流转：`NEW` → `start()` → `RUNNABLE` → 竞争锁失败 `BLOCKED` / `wait()`、`join()`、`park()` 进 `WAITING` / `sleep(n)`、`wait(n)` 进 `TIMED_WAITING` → `TERMINATED`。
- `wait()` 释放锁、必须在 synchronized 内、属于 Object；`sleep()` 不释放锁、属于 Thread 静态方法；`notify` 唤醒一个、`notifyAll` 唤醒全部。
- 中断是**协作式**：`interrupt()` 只设置标志，阻塞方法抛 `InterruptedException`；`stop()` 已废弃（留下不一致状态）。
- 守护线程：`setDaemon(true)`，主线程结束即退出，GC 线程就是守护线程。

**面试怎么答（60 秒版）**：创建线程推荐实现 Runnable 或 Callable 再交给线程池，因为 Java 单继承，实现接口更灵活，Callable 还能拿返回值。start 才会真正开线程，run 只是普通调用。线程有六种状态，从 NEW 到 RUNNABLE，竞争锁会进 BLOCKED，调 wait 或 join 进 WAITING，sleep 进 TIMED_WAITING，最后 TERMINATED。wait 会释放锁且必须在 synchronized 块里，sleep 不释放锁。停止线程用 interrupt 做协作式中断，不要用已废弃的 stop。

**追问陷阱**：
- 错误：「WAITING 和 BLOCKED 是一回事」→ 正确：BLOCKED 专指等 synchronized 监视器锁；WAITING 是 wait/join/park 的主动等待。
- 错误：以为 `interrupt()` 会立刻停线程 → 正确：只设标志，需线程自己检查或阻塞方法响应。

## 14. 线程池七大参数与执行流程

**一句话答案**：七大参数是核心线程数、最大线程数、空闲存活时间、时间单位、工作队列、线程工厂、拒绝策略；执行顺序是「核心线程 → 队列 → 非核心线程 → 拒绝」。

**原理展开**：
- 执行流程（`ThreadPoolExecutor.execute`）：线程数 < corePoolSize 直接建核心线程跑 → 否则入队列 → 队列满且 < maximumPoolSize 建非核心线程 → 还满则执行拒绝策略。
- 队列选择：`ArrayBlockingQueue`（有界，推荐）、`LinkedBlockingQueue`（默认无界，OOM 隐患）、`SynchronousQueue`（不存元素，配大 max 做弹性）、`PriorityBlockingQueue`、`DelayQueue`（延时任务）。
- 四种拒绝策略：`AbortPolicy`（默认，抛 `RejectedExecutionException`）、`CallerRunsPolicy`（调用线程自己跑，天然反压限流）、`DiscardPolicy`（静默丢弃，最危险）、`DiscardOldestPolicy`（丢队首腾位置）。
- 为什么不用 `Executors`：`newFixedThreadPool`/`newSingleThreadExecutor` 用无界队列可能 OOM；`newCachedThreadPool` 最大线程数是 `Integer.MAX_VALUE` 可能创建海量线程。必须手写 `ThreadPoolExecutor`。
- 线程数经验公式：CPU 密集 N+1；IO 密集 2N 或 N×(1+等待时间/计算时间)；最终以压测为准。
- 关闭与异常：`shutdown()` 不接新任务、跑完队列；`shutdownNow()` 中断并返回未执行任务。`submit` 的异常被 `Future` 吞掉，不 `get()` 就静默丢失；`execute` 才交给 `UncaughtExceptionHandler`。
- 线程命名：自定义 `ThreadFactory` 给线程起名，排查日志时才知道是哪个池。

```java
ThreadPoolExecutor pool = new ThreadPoolExecutor(
        4,                                  // corePoolSize
        8,                                  // maximumPoolSize
        60L, TimeUnit.SECONDS,              // 非核心线程空闲存活
        new ArrayBlockingQueue<>(200),      // 有界队列，防 OOM
        r -> new Thread(r, "order-pool-" + r.hashCode()),
        new ThreadPoolExecutor.CallerRunsPolicy());   // 反压不丢任务
```

**面试怎么答（60 秒版）**：线程池七个参数：核心线程数、最大线程数、空闲存活时间、时间单位、工作队列、线程工厂、拒绝策略。提交任务时先看核心线程满没满，没满就建核心线程；满了进队列；队列满且没到最大线程数就建非核心线程；再满就触发拒绝策略。不建议用 Executors 的快捷方法，因为它用的是无界队列或无限大线程数，容易 OOM，生产上都是手写 ThreadPoolExecutor 并自定义线程名和拒绝策略。核心线程默认不回收，可以配置 allowCoreThreadTimeOut。

**追问陷阱**：
- 错误：「先创建最大线程再排队」→ 正确：顺序是核心 → 队列 → 非核心 → 拒绝，答错顺序是硬伤。
- 错误：「CallerRunsPolicy 会丢任务」→ 正确：不丢，它让提交线程自己执行，代价是阻塞调用方。
- 错误：「submit 会抛异常」→ 正确：异常包在 `Future` 里，不 `get()` 就静默丢失。

## 15. synchronized 与 Lock 的区别

**一句话答案**：synchronized 是 JVM 关键字、自动释放、非公平、不可中断；Lock 是 API（`ReentrantLock`），要 finally 手动释放，但支持公平、可中断、tryLock 超时、多 Condition。

**原理展开**：
- synchronized 三种用法：修饰实例方法（锁 this）、静态方法（锁 Class 对象）、代码块（锁指定对象），字节码是 `monitorenter` + 两个 `monitorexit`。
- JDK6 后锁升级：无锁 → 偏向锁（同一线程重入免 CAS，JDK15 后废弃）→ 轻量级锁（CAS 自旋，适合短暂竞争）→ 重量级锁（`ObjectMonitor`，竞争线程进 wait set 被 park，有用户态/内核态切换）。
- `ReentrantLock` 基于 AQS：`lock()/unlock()` 必须成对，`unlock` 放 finally；`lockInterruptibly()` 可响应中断；`tryLock(timeout)` 拿不到就放弃，避免死锁。
- `Condition`：一个 Lock 可有多个条件队列，生产者/消费者各自 `await/signal`，比 `wait/notifyAll` 精确，避免惊群。
- 相同点：都可重入、都保证可见性（synchronized 靠 JMM 的 monitorenter/exit 内存语义，Lock 靠 AQS 的 volatile state + CAS）。
- 选型：优先 synchronized（锁消除/偏向锁让低竞争下性能很好）；需要超时、可中断、公平、多条件唤醒时用 `ReentrantLock`；读多写少用 `ReentrantReadWriteLock`。
- 死锁四条件：互斥、持有并等待、不可剥夺、循环等待；排查用 `jstack` 看 BLOCKED 与「Found one Java-level deadlock」。

**面试怎么答（60 秒版）**：synchronized 是 JVM 层面的关键字，自动加锁释放，抛异常也会释放，JDK6 之后有偏向锁、轻量级锁、重量级锁的升级，低竞争下性能不差。Lock 是 JDK 的接口，常用 ReentrantLock，必须自己 finally 释放，换来的是更细的控制：可以公平锁、可以 lockInterruptibly 响应中断、可以 tryLock 超时避免死锁、可以用 Condition 做多条件队列。所以一般优先 synchronized，需要这些高级能力时再换 ReentrantLock。

**追问陷阱**：
- 错误：「synchronized 一定比 Lock 慢」→ 正确：JDK6 优化后低竞争下 synchronized 甚至更快，别一概而论。
- 错误：「ReentrantLock 是公平锁」→ 正确：默认非公平，`new ReentrantLock(true)` 才公平；非公平吞吐更高。
- 错误：`unlock` 不放 finally → 正确：抛异常会永久占用锁。

## 16. volatile 与可见性

**一句话答案**：volatile 保证**可见性**和**有序性**（禁止指令重排），但**不保证原子性**。

**原理展开**：
- 可见性：写 volatile 变量立即刷回主存并让其他 CPU 缓存行失效，读强制从主存取，本质是插入内存屏障（`StoreStore`、`LoadLoad`、`LoadStore`、`StoreLoad`）。
- 有序性：禁止指令重排，最典型是 DCL 单例必须加 volatile，禁止「分配内存 → 初始化 → 赋引用」中后两步重排导致别人拿到半成品对象。
- 不保证原子性：`i++` 是「读-改-写」三步，多线程同时执行仍丢更新，要 `AtomicInteger` 或 `synchronized`。
- 适用场景：状态标志位（`volatile boolean running`）、DCL 单例、一次性安全发布不可变对象。
- 对比：`synchronized` 原子 + 可见 + 有序；`volatile` 只给可见 + 有序，换来无锁低开销。
- 常见 bug：`while (!flag) {}` 死循环——线程看不到别人改的 flag，加 volatile 或建立 happens-before 关系即可。
- DCL 单例写法：`private static volatile Singleton INSTANCE;` + 双重 null 判断 + `synchronized (Singleton.class)`。

**面试怎么答（60 秒版）**：volatile 解决的是 JMM 里的可见性和有序性。可见性是写操作立即刷主存、读操作强制读主存，靠内存屏障实现；有序性是禁止指令重排，最典型的就是双重检查锁单例，不加 volatile 可能把赋引用重排到初始化之前，别的线程会拿到没初始化完的对象。但它不保证原子性，像 i++ 这种读改写复合操作，多线程下还是要用 AtomicInteger 或者 synchronized。

**追问陷阱**：
- 错误：「volatile 保证线程安全」→ 正确：只保证可见性与有序性，`count++` 依然不安全。
- 错误：写 DCL 单例漏 volatile → 正确：必考题眼，要讲清楚三条指令的重排风险。

## 17. ThreadLocal 与内存泄漏

**一句话答案**：ThreadLocal 给每个线程一份独立副本；数据存在 `Thread.threadLocals` 的 `ThreadLocalMap` 里，key 是弱引用、value 是强引用，线程池场景**必须手动 `remove()`**。

**原理展开**：
- 结构：`Thread` 内部有 `ThreadLocalMap`，key 是 ThreadLocal 对象的弱引用，value 是强引用；数据其实是「线程持有」，不是「ThreadLocal 持有」。
- 为什么 key 用弱引用：ThreadLocal 对象没人用了可以被回收；但 value 的强引用链是 Thread → ThreadLocalMap → Entry → value，线程不死 value 就回收不了。
- 内存泄漏：线程池里线程复用且长期存活，不 `remove()` 就残留上一个请求的数据，既泄漏又导致**脏数据串号**（A 用户数据被 B 用户读到）。
- 正确写法：`try { ... } finally { threadLocal.remove(); }`。
- 应用：`@Transactional` 把数据库连接绑在 ThreadLocal 上；用户上下文（`UserContextHolder`）传 userId；`SimpleDateFormat` 非线程安全，可用 ThreadLocal 或换 `DateTimeFormatter`。
- `InheritableThreadLocal` 可传给子线程，但线程池复用线程时不保证传递，要传上下文建议用阿里 `TransmittableThreadLocal`。
- 为什么不用 `Map<Thread, Object>`：线程销毁后 key 无法自动清理，取自己那份数据还得同步，性能和泄漏都更差。

**面试怎么答（60 秒版）**：ThreadLocal 提供线程本地变量，每个线程访问同一个 ThreadLocal 时拿到的是自己那份副本，数据实际存在 Thread 内部的 ThreadLocalMap 里。它的 key 是弱引用、value 是强引用，所以 ThreadLocal 对象能被回收，但 value 会跟着线程一起活着。在线程池里线程长期复用，如果不 remove，既会内存泄漏，也会让下一个请求读到上一个请求的数据，所以必须 try-finally 里 remove。Spring 的事务就是用它把连接绑定到当前线程的。

**追问陷阱**：
- 错误：「ThreadLocal 数据存在 ThreadLocal 里」→ 正确：存在 Thread 的 ThreadLocalMap 里，ThreadLocal 只是 key，方向反了是常见错误。
- 错误：只在拦截器里 `set` 不 `remove` → 正确：线程池复用会串数据，必须 finally remove。
- 错误：「弱引用就不会泄漏」→ 正确：泄漏点是 value 的强引用，弱引用只让 key 能被回收。

## 18. CAS 与 ABA 问题

**一句话答案**：CAS 是「比较并交换」的原子指令，`AtomicInteger` 的底层；三大问题——ABA、自旋开销、只保一个变量。

**原理展开**：
- 原理：`Unsafe.compareAndSwapInt(obj, offset, expect, update)`，汇编层是 `lock cmpxchg`，保证比较+写入原子；Java 9+ 推荐 `VarHandle`。
- 自旋：失败就重试，无锁但高竞争下 CPU 空转；JDK8 的 `LongAdder` 用分段累加（`Cell[]`）分散竞争，比 `AtomicLong` 快。
- ABA 问题：值从 A→B→A，CAS 以为没变过。解决：`AtomicStampedReference`（加版本号）或 `AtomicMarkableReference`（加布尔标记）。
- 只保一个变量：要保多个用 `AtomicReference<T>` 包不可变对象，或直接加锁。
- 应用：并发计数器、无锁栈/队列、状态机 CAS 更新、数据库乐观锁（`update ... set version = version + 1 where version = ?`）。
- 与 synchronized 的取舍：冲突少、临界区短用 CAS（无锁不挂起）；冲突多、逻辑复杂用锁，否则自旋浪费 CPU。
- 实现注意：CAS 配合 `volatile` 字段才有意义，否则读到的期望值本身可能是脏数据。

**面试怎么答（60 秒版）**：CAS 是比较并交换，有三个操作数：内存值、期望值、新值，只有内存值等于期望值才更新，整个操作由 CPU 的 lock cmpxchg 指令保证原子性，Java 里通过 Unsafe 调用它。它无锁、不挂起线程，所以轻量。但有三个问题：ABA 问题，值改了又改回来察觉不到，用 AtomicStampedReference 加版本号解决；高竞争时自旋耗 CPU，可以用 LongAdder 分散热点；只能保证一个变量，多个变量要用 AtomicReference 或者直接加锁。

**追问陷阱**：
- 错误：「CAS 是纯 Java 实现的」→ 正确：原子性靠 CPU 指令 + JNI/Unsafe，Java 层只是封装。
- 错误：只会背 ABA 定义 → 正确：要举「链表节点被回收复用」「余额先扣后加」的后果，并给出 `AtomicStampedReference` 方案。

## 19. AQS 简述

**一句话答案**：AQS 是 `AbstractQueuedSynchronizer`，用一个 `volatile int state` 表示同步状态，配一个 CLH 双向队列管理排队线程，`ReentrantLock`、`Semaphore`、`CountDownLatch` 都基于它。

**原理展开**：
- 模板方法：`tryAcquire/tryRelease`（独占）、`tryAcquireShared/tryReleaseShared`（共享）由子类实现，排队逻辑 AQS 已经写死。
- 独占模式：`acquire` 先 `tryAcquire`（内部 CAS 改 state），失败则包装成 Node 入队，再 `LockSupport.park()` 挂起；`release` 成功后 `unpark` 唤醒后继。
- `ReentrantLock` 的 state 就是重入次数：当前线程已持有时 state+1，释放减到 0 才算真正释放。
- 公平 vs 非公平：非公平在 `tryAcquire` 里直接 CAS 抢、不管队首有没有人（可能插队），吞吐高但极端下会饥饿；公平先 `hasQueuedPredecessors()` 检查。
- 共享模式：`Semaphore` 的 state 是许可数，`CountDownLatch` 的 state 是倒计数，减到 0 唤醒所有等待者。
- AQS 队列是 CLH 的变体：自旋 + park 结合，既省 CPU 又能及时被唤醒。
- 延伸：`ReentrantReadWriteLock` 把 state 高低 16 位分别当读锁、写锁计数，是「一个 int 拆两半」的经典用法。

**面试怎么答（60 秒版）**：AQS 是并发包里的同步器框架，核心是一个 volatile 的 int 状态和一个 CLH 双向队列。子类只需要实现 tryAcquire 和 tryRelease 这样的模板方法来定义「什么算获取成功」，获取失败后入队、park 挂起的逻辑 AQS 已经写好了。ReentrantLock 用它实现重入，state 就是重入次数；Semaphore 和 CountDownLatch 用的是共享模式，state 分别是许可数和倒计数。公平锁和非公平锁的区别就在 tryAcquire 里是否检查队列前面有没有人在等。

**追问陷阱**：
- 错误：「AQS 队列是纯自旋的 CLH」→ 正确：改成了自旋 + park 的变体，避免 CPU 空转。
- 错误：分不清 state 含义 → 正确：它是子类自定义语义（重入次数/许可数/计数），AQS 只当整数用。

### 加分项：深挖到此 · JMM、内存屏障与 happens-before

面试官问「你能再深入点吗」时，从「并发 bug 到底怎么产生的」切进去：

- JMM 抽象出主内存（线程共享）与工作内存（线程副本），线程改副本再同步回主存 → 可见性问题；编译器/CPU 为性能重排指令 → 有序性问题。
- happens-before 是 JMM 给程序员的可见性承诺：程序顺序规则、volatile 写先于后读、解锁先于后加锁、`Thread.start()` 先于子线程动作、`join()` 后于线程结束、传递性；满足它就不必额外同步。
- 四种内存屏障：`LoadLoad`、`StoreStore`、`LoadStore`、`StoreLoad`（最重，volatile 写后插入）；`synchronized` 的 monitorenter/exit 也插屏障，所以它不只互斥还保证可见。
- 说清楚「DCL 为什么要 volatile」= 已掌握重排；能说「happens-before 是给程序员的规则而非 CPU 指令」= 真懂。

### 加分项：深挖到此 · 对象内存布局与 JIT 优化

- 对象布局：对象头（Mark Word 存 hash/GC 年龄/锁标志，Class Pointer 指向类元数据，数组还有长度）+ 实例数据 + 8 字节对齐填充；开启指针压缩 `-XX:+UseCompressedOops` 后引用 4 字节。
- Mark Word 是锁升级的关键：偏向锁存线程 ID，轻量级锁存指向栈中 Lock Record 的指针，重量级锁存 Monitor 指针。
- JIT 三个高频优化：**逃逸分析**（对象没逃出方法可栈上分配）、**标量替换**（对象拆成字段放寄存器）、**锁消除**（不可能竞争的锁直接去掉，如方法内 `new Object()` 加 synchronized）。
- 对应面试题：「为什么局部变量不需要同步」「偏向锁/轻量级锁的意义」「`while(!flag)` 为什么死循环」——最后一题用可见性 + volatile 收尾。

## 高频题库

| 题号 | 题目 | 考点 | 答案要点 |
| --- | --- | --- | --- |
| 1 | HashMap 的 put 流程？ | 集合原理 | 扰动 hash → `(n-1)&hash` 定位 → 空桶直接放 → 同 key 覆盖 → 树节点走树插 → 否则尾插链表 → 超阈值树化或扩容 |
| 2 | 为什么 HashMap 容量是 2 的幂？ | 位运算 | `hash & (n-1)` 等价取模且更快；扩容时元素只留原位或 +oldCap |
| 3 | HashMap 为什么线程不安全？ | 并发 | 并发 put 覆盖丢数据、size 不准；JDK7 头插并发扩容成环导致 get 死循环 |
| 4 | HashMap 与 ConcurrentHashMap 区别？ | 并发集合 | 一个不安全一个安全；JDK8 CHM 用 CAS + synchronized 锁桶 + 协助扩容，读无锁 |
| 5 | `==` 与 equals 的区别？ | 基础 | `==` 比值或地址，equals 默认比地址、重写后比值；重写 equals 必须重写 hashCode |
| 6 | 为什么重写 equals 要重写 hashCode？ | 契约 | equals 相等则 hash 必须相等，否则哈希容器存进去取不出来 |
| 7 | String 为什么不可变，好处是什么？ | 字符串 | final 类 + final 数组 + 无修改方法；换来线程安全、hash 可缓存、常量池复用 |
| 8 | ArrayList 与 LinkedList 区别？ | 集合 | 数组 vs 双向链表；随机读 O(1) vs O(n)；ArrayList 扩容 1.5 倍 |
| 9 | 遍历集合时删除元素为什么抛异常？ | 集合 | fail-fast，modCount 被外部修改抛 ConcurrentModificationException，用 iterator.remove |
| 10 | 受检异常与非受检异常区别？ | 异常 | 受检编译期强制处理，非受检是 RuntimeException；`@Transactional` 默认只回滚非受检 |
| 11 | try-with-resources 原理？ | 异常 | 资源实现 AutoCloseable，编译后逆序自动 close，关闭异常挂 suppressed |
| 12 | 泛型擦除是什么，有什么限制？ | 泛型 | 编译后擦为 Object 或上界；不能 new T、取 T.class、建泛型数组；桥接方法保多态 |
| 13 | 反射的用途与代价？ | 反射 | 框架用来实例化/注入/映射/解析注解；代价是性能与封装破坏 |
| 14 | JVM 内存区域划分？ | JVM | 私有：PC、虚拟机栈、本地方法栈；共享：堆、方法区（JDK8 元空间） |
| 15 | 双亲委派是什么，为什么需要？ | 类加载 | 先委派父加载器；防核心类被篡改、避免重复加载；SPI 用 TCCL 打破 |
| 16 | 如何判断对象可以回收？ | GC | 可达性分析，GC Roots 含栈引用、静态变量、常量、JNI 引用 |
| 17 | 新生代为什么用复制算法？ | GC | 朝生夕死、存活少，复制成本低且无碎片；8:1:1 只浪费 10% |
| 18 | 线程池七个参数与执行流程？ | 线程池 | core/max/keepAlive/unit/queue/factory/handler；核心 → 队列 → 非核心 → 拒绝 |
| 19 | 为什么不推荐 Executors？ | 线程池 | 无界队列或无限线程数导致 OOM；应手写 ThreadPoolExecutor 并命名线程 |
| 20 | synchronized 与 Lock 区别？ | 并发 | 关键字自动释放 / API 手动释放；Lock 支持公平、中断、超时、多 Condition |
| 21 | volatile 能保证什么，不能保证什么？ | 并发 | 保证可见性与有序性，不保证原子性；DCL 单例必须加 |
| 22 | ThreadLocal 为什么会内存泄漏？ | 并发 | key 弱引用 value 强引用，线程池复用不 remove 就残留；finally 里 remove |
| 23 | CAS 有什么问题？ | 并发 | ABA（版本号解决）、自旋开销（LongAdder）、单变量（AtomicReference） |
| 24 | AQS 的原理？ | 并发 | volatile state + CLH 队列 + 模板方法；ReentrantLock 的 state 是重入次数 |

> 练完本章，去 [SpringBoot 与后端工程](SpringBoot与后端工程.md) 看这些能力怎么被框架用起来；性能优化的另一半在 [MySQL 与 Redis](../04-database/MySQL与Redis.md)。时间有限时，优先保证第 1、3、5、14、16、18、20、21、22 题能张口就来。
