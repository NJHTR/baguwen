# Spring 为什么要用三级缓存解决循环依赖？

> 精讲层级：从「零基础能看懂」到「源码级」，每个名词都拆开
> 阅读时间：约 35 分钟
> 配套速查：[IoC 与 Bean 生命周期（深度追问）](../../10-deep-dive/spring/01-IoC与Bean生命周期.md)
> 返回：[精讲索引](../00-索引.md)

---

## 0. 一句话先讲明白

循环依赖就是 A 依赖 B、B 又依赖 A。Spring 的做法是「**先造出半成品，提前暴露引用**」：

1. A 实例化完（但属性还是空）之后，**立刻**把一个「能产出 A（或 A 的代理）的工厂」放进三级缓存 `singletonFactories`
2. 填充 A 的属性时发现需要 B，去创建 B
3. B 填充属性时发现需要 A，从三级缓存拿到 A 的半成品（或代理），放进二级缓存
4. B 创建完成；A 拿到 B，完成自己的初始化

**为什么要三个缓存而不是两个**：因为「要不要给 A 生成 AOP 代理」这件事必须延迟到「真的有人提前来拿 A」时才能决定。三级缓存里放的是 `ObjectFactory`（工厂），只有被调用时才通过 `getEarlyBeanReference` 决定「给原对象还是给代理」，从而保证「正常 Bean 的代理只在初始化后生成一次」。

---

## 1. 痛点背景：循环依赖到底难在哪

### 1.1 先看一个最小循环

```java
@Service
public class AService {
    @Autowired private BService bService;    // A 需要 B
}

@Service
public class BService {
    @Autowired private AService aService;    // B 需要 A
}
```

如果没有特殊处理，创建 A 的逻辑会是：

```
createBean(A) -> 需要 B -> createBean(B) -> 需要 A -> createBean(A) -> 需要 B -> ...
```

**无限递归**。所以 Spring 必须做两件事：

1. 检测「在创建中」的 Bean，避免真的递归下去（`isSingletonCurrentlyInCreation`）
2. 提供一条「拿到半成品」的旁路，让递归在某一层提前返回

### 1.2 先解释三个名词

| 名词 | 是什么 | 为什么重要 |
|---|---|---|
| 三级缓存 | 三个 `Map`：`singletonObjects`（成品）、`earlySingletonObjects`（半成品）、`singletonFactories`（产出半成品的工厂） | 循环依赖的全部机制都在这三个 Map 里 |
| 提前暴露（early exposure） | 在 Bean 初始化完成之前，就把它的引用（或代理）交给别的 Bean | 打破递归的关键 |
| 初始化（initialize） | 属性填充之后，执行 `@PostConstruct`、`InitializingBean`、`init-method` 等 | 「实例化」和「初始化」是两件事，循环依赖利用的正是这个时间差 |

### 1.3 一个数字：为什么不能等初始化完再暴露

`createBean` 的主要阶段和时间占比（典型业务 Bean）：

| 阶段 | 内容 | 大致占比 |
|---|---|---|
| 实例化 | 推断构造器 + 反射 `new` | 20% |
| 属性填充 | `@Autowired` / `@Value` 注入 | 30% |
| 初始化 | Aware 回调、`@PostConstruct`、`init-method`、AOP 代理 | 50% |

如果把「暴露引用」放在初始化之后，那 A 必须等 B 完成，B 又必须等 A 完成——**死锁**。所以必须在「实例化完成、属性填充之前」这个窗口把引用挂出去，这是唯一的窗口期。

---

## 2. 逐步拆解：三个 Map 与两个钩子

### 2.1 三级缓存的字段定义

```java
public class DefaultSingletonBeanRegistry {
    // 一级：完整的单例 Bean（成品）
    private final Map<String, Object> singletonObjects = new ConcurrentHashMap<>(256);
    // 二级：提前暴露的半成品（已经实例化，可能还没填充完属性）
    private final Map<String, Object> earlySingletonObjects = new ConcurrentHashMap<>(16);
    // 三级：产出半成品的工厂（延迟决定是否生成 AOP 代理）
    private final Map<String, ObjectFactory<?>> singletonFactories = new HashMap<>(16);

    // 正在创建中的 Bean 名字集合，用于循环依赖检测与「提前暴露」判断
    private final Set<String> singletonsCurrentlyInCreation =
            Collections.newSetFromMap(new ConcurrentHashMap<>(16));
}
```

### 2.2 `getSingleton` 的三级查找

```java
protected Object getSingleton(String beanName, boolean allowEarlyReference) {
    Object singletonObject = this.singletonObjects.get(beanName);           // 1. 先查成品
    if (singletonObject == null && isSingletonCurrentlyInCreation(beanName)) {
        singletonObject = this.earlySingletonObjects.get(beanName);         // 2. 再查半成品
        if (singletonObject == null && allowEarlyReference) {
            synchronized (this.singletonObjects) {
                ObjectFactory<?> singletonFactory = this.singletonFactories.get(beanName);  // 3. 最后查工厂
                if (singletonFactory != null) {
                    singletonObject = singletonFactory.getObject();          // 重点：调用工厂产出
                    this.earlySingletonObjects.put(beanName, singletonObject); // 升级到二级
                    this.singletonFactories.remove(beanName);                 // 工厂用完即删
                }
            }
        }
    }
    return singletonObject;
}
```

**注意第 3 步的 `getObject()`**：它不是简单地返回原对象，而是调用 `AbstractAutoProxyCreator.getEarlyBeanReference`——这里才会决定「要不要提前创建 AOP 代理」。

### 2.3 实例化后立刻注册工厂

```java
// AbstractAutowireCapableBeanFactory.doCreateBean
protected Object doCreateBean(String beanName, RootBeanDefinition mbd, Object[] args) {
    // 1. 实例化（此时对象已存在，但字段都是默认值）
    Object bean = createBeanInstance(mbd, beanName, args);
    // 2. 判断是否需要提前暴露：单例 + 允许循环依赖 + 正在创建中
    boolean earlySingletonExposure = (mbd.isSingleton() && this.allowCircularReferences
            && isSingletonCurrentlyInCreation(beanName));
    if (earlySingletonExposure) {
        addSingletonFactory(beanName, () -> getEarlyBeanReference(beanName, mbd, bean));
    }
    // 3. 属性填充（在这里可能触发循环依赖，去创建别的 Bean）
    populateBean(beanName, mbd, bean);
    // 4. 初始化（Aware -> @PostConstruct -> init-method -> AOP 代理）
    Object exposedObject = initializeBean(beanName, bean, mbd);
    return exposedObject;
}
```

### 2.4 `getEarlyBeanReference`：决定「提前代理」的钩子

```java
// AbstractAutoProxyCreator
public Object getEarlyBeanReference(String beanName, RootBeanDefinition mbd, Object bean) {
    Object exposedObject = bean;
    if (!mbd.isSynthetic() && hasInstantiationAwareBeanPostProcessors()) {
        if (shouldProxy(beanName, mbd)) {          // 是否命中切点
            exposedObject = wrapIfNecessary(bean, beanName, mbd);   // 提前创建 AOP 代理
            this.earlyProxyReferences.put(beanName, bean);          // 记录：已经提前代理过
        }
    }
    return exposedObject;
}
```

之后 `postProcessAfterInitialization` 里会检查 `earlyProxyReferences`：**如果已经提前代理过，就不再重复代理**，直接返回原引用。这保证了「一个 Bean 只会被代理一次」。

### 2.5 完整流程：A 与 B 的循环

```
1. createBean(A)
2. 实例化 A（A.bService = null）
3. addSingletonFactory("A", () -> getEarlyBeanReference(A))     ← 三级缓存有了 A
4. populateBean(A)：发现需要 B -> getBean(B)
5. createBean(B)
6. 实例化 B（B.aService = null）
7. addSingletonFactory("B", ...)                                ← 三级缓存有了 B
8. populateBean(B)：发现需要 A -> getSingleton("A")
      -> 一级没有、二级没有 -> 三级拿到工厂 -> getObject()
      -> getEarlyBeanReference 判断：A 要不要代理？
         不要 -> 返回原半成品 A
         要   -> 提前创建代理 A_proxy（记录 earlyProxyReferences）
      -> 放入二级缓存，删除三级工厂
9. B 拿到 A，完成属性填充与初始化 -> 放入一级缓存
10. 回到 A：拿到 B，完成属性填充与初始化
11. A 放入一级缓存（若第 8 步已提前代理，这里不再重复代理）
```

**关键数字**：整个过程中 A 被「创建」了 **1 次**，但引用被「提前取用」了 **1 次**（在第 8 步）；`singletonFactories` 里的工厂在最坏情况下被调用 1 次，然后立即删除。

---

## 3. 完整推导：为什么必须三级，二级行不行

### 3.1 先假设「只有一级缓存」

加锁串行化创建，遇到循环依赖时：

- A 创建中（未完成），B 来拿 A，一级缓存里没有 A
- B 只能等 A 完成，A 在等 B → **死锁**

所以必须允许「拿半成品」。

### 3.2 假设「只有一级 + 二级缓存」

思路：A 实例化完就直接把 A 放进二级缓存（`earlySingletonObjects`），B 来拿时直接返回 A。

问题出在 **AOP 代理**：

```
如果 A 命中切面，B 拿到的应该是「A 的代理」还是「A 的原对象」？
```

- 如果二级缓存放的是**原对象**：B 拿到原对象 A，之后 A 在初始化后生成了代理 A_proxy，但 B 手里还是原对象 ⇒ **B 调用 A 的方法不走代理，切面失效**（事务/日志全丢）。
- 如果二级缓存放的是**代理**：代理必须在「实例化后」立刻生成，也就是提前创建。可绝大多数 Bean 没有循环依赖，它们本应在初始化后（`postProcessAfterInitialization`）统一生成代理——**两条路径不一致**，会出现「有的 Bean 提前代理、有的延后代理」，代理链、`@Order`、多切面顺序都可能错乱。

**结论**：二级缓存无法同时满足「没有循环依赖时不提前代理」和「有循环依赖时给代理」这两个要求。必须引入一个**延迟决策**的机制——这就是三级缓存（工厂）。

### 3.3 三级的本质：把「决定」装进一个函数

```java
// 二级缓存存的是「对象」，放进去的那一刻就必须决定是原对象还是代理
earlySingletonObjects.put("A", ???);   // 此时代理还没生成，无法决定

// 三级缓存存的是「函数」，被调用时才决定
singletonFactories.put("A", () -> getEarlyBeanReference(...));   // 延迟到需要时
```

用函数代替值，就得到了「按需代理」的能力。**这就是三级缓存的全部理由。**

### 3.4 构造器注入的循环依赖为什么救不了

```java
@Service
public class AService {
    public AService(BService bService) { }   // 构造器注入
}
@Service
public class BService {
    public BService(AService aService) { }   // 构造器注入
}
```

时序：

```
createBean(A)
  -> createBeanInstance(A)：需要 B 作为构造参数 -> getBean(B)
      -> createBeanInstance(B)：需要 A 作为构造参数 -> getBean(A)
          -> A 正在创建中，三级缓存里还没有 A 的工厂（工厂在实例化之后才注册！）
          -> 抛 BeanCurrentlyInCreationException
```

**根因**：`addSingletonFactory` 发生在 `createBeanInstance` **之后**，而构造器注入必须在 `createBeanInstance` **期间**就拿到依赖。所以这个窗口根本不存在，三级缓存救不了。

### 3.5 其他作用域

| 场景 | 能否解决 | 原因 |
|---|---|---|
| 单例 + 字段/setter 注入 | 能 | 有「实例化后、初始化前」的窗口 |
| 单例 + 构造器注入 | 不能 | 工厂注册晚于构造器解析 |
| 原型（prototype） | 不能 | 原型 Bean 不缓存，每次都新建，没有「提前暴露」的概念 |
| `@Async`/`@Transactional` 的代理 Bean 互相依赖 | 能，但要留意代理提前生成 | `getEarlyBeanReference` 会提前代理 |
| 单例 + `@Lazy` | 能 | 注入的是延迟解析的代理，实际调用时才 `getBean` |

---

## 4. 极简模型：两个 Bean、三个 Map 的内容变化

只看三个 Map 和两个 Bean（A、B 互相依赖）：

| 时刻 | 动作 | 一级 `singletonObjects` | 二级 `earlySingletonObjects` | 三级 `singletonFactories` | 说明 |
|---|---|---|---|---|---|
| t0 | 开始 | {} | {} | {} | 空 |
| t1 | 实例化 A | {} | {} | {A: 工厂} | 工厂闭包捕获半成品 A |
| t2 | A 填充属性，创建 B | {} | {} | {A: 工厂} | |
| t3 | 实例化 B | {} | {} | {A: 工厂, B: 工厂} | |
| t4 | B 要 A，查三级 | {} | {} | {A: 工厂, B: 工厂} | 触发 A 的工厂 |
| t5 | A 的工厂执行 | {} | {A: 半成品（或代理）} | {B: 工厂} | 工厂删除，升级到二级 |
| t6 | B 完成，入一级 | {B} | {A: 半成品} | {} | B 的工厂用完删除 |
| t7 | A 拿到 B，完成初始化 | {A, B} | {} | {} | A 覆盖二级，最终成品 |

**观察点**：二级缓存里的 A 在 t5 出现、t7 消失（被成品覆盖）。所以二级缓存的生命周期是「临时」的，不是长期存储。

---

## 5. 为什么这样设计：四个被否决的方案

### 5.1 方案一：只允许一级缓存，遇到循环依赖直接报错

- 优点：语义最简单，绝不会有半成品外泄
- 否决原因：现实项目里循环依赖非常常见（服务层互相引用、工具类互相依赖），一刀切报错会让框架不可用。Spring 选择「默认支持（历史上）+ 新版本默认禁止 + 提供开关」。

### 5.2 方案二：只有两级缓存（对象级提前暴露）

- 优点：少一个 Map，实现更简单
- 否决原因：见 3.2——对象一旦放进二级缓存就无法再决定「是否代理」，导致 AOP 代理时机不一致或 B 拿到未代理的原对象。

### 5.3 方案三：构造器注入也提前暴露（先 `allocateInstance` 再反射填字段）

- 设想：用 `Unsafe.allocateInstance` 绕过构造器先造对象，再注入
- 否决原因：绕过构造器会跳过初始化逻辑（字段校验、不变式），违背 Java 语义；而且构造器注入的语义就是「依赖必须在构造时可用」，绕过它等于把构造器注入退化成字段注入。Spring 选择「诚实报错 + 让用户改设计」。

### 5.4 方案四：用「空对象占位」再替换字段

- 设想：先放一个占位对象到缓存，等真正对象准备好再替换引用
- 否决原因：其他 Bean 已经持有占位对象的引用，替换只能改缓存里的值，改不了别人手里的引用（Java 没有引用级替换）。除非用动态代理包装，但那就是现在的「提前代理」方案了。

---

## 6. 关键参数为什么是这个值

| 参数/字段 | 值 | 为什么 |
|---|---|---|
| `singletonObjects` 初始容量 | 256 | 典型应用单例数量几百，256 是经验值，减少扩容 |
| `earlySingletonObjects` 初始容量 | 16 | 循环依赖是少数情况，用小的初始容量 |
| `singletonFactories` 初始容量 | 16 | 同上；用 `HashMap` 而非 `ConcurrentHashMap`，因为访问在 `synchronized` 块内 |
| `allowCircularReferences` | Spring 默认 `true`；**Spring Boot 2.6+ 默认 `false`** | 循环依赖是设计问题，框架选择「默认帮你拦住」 |
| 检测集合 `singletonsCurrentlyInCreation` | 并发 Set | 用 `ConcurrentHashMap.newKeySet` 实现，支持并发标记 |

**为什么工厂缓存用 `HashMap` 而不是 `ConcurrentHashMap`**：因为它只在 `synchronized (this.singletonObjects)` 块内被读写，锁已经保证了安全，用 `HashMap` 更省。这是一个「锁保护代替并发容器」的典型取舍。

---

## 7. 版本演进

| 版本 | 变化 | 影响 |
|---|---|---|
| Spring 3.x / 4.x | 三级缓存机制定型（`singletonFactories` + `getEarlyBeanReference`） | 字段注入循环依赖可以解决 |
| Spring 4.3 | 构造器注入单构造器时可省略 `@Autowired` | 构造器循环依赖的报错更常见 |
| Spring Boot 1.x / 2.x 早期 | 默认 `allowCircularReferences = true` | 循环依赖静默通过 |
| Spring Boot 2.6 | 默认改为 `false`，需要显式 `spring.main.allow-circular-references=true` 才允许 | 启动时直接 `BeanCurrentlyInCreationException`，强制改设计 |
| Spring Framework 6.x / Boot 3.x | 同上（默认禁止）；基线 Java 17 | 与 Boot 2.6+ 行为一致 |
| Spring 6 | `@Configuration` 类代理默认 `proxyBeanMethods=false`（lite 模式） | 减少 `@Configuration` 之间的循环依赖 |

**面试表述**：Spring 从「默默帮你解决」转向「默认禁止、让你改设计」。这不是功能退化，而是工程态度的转变——循环依赖几乎总是分层或职责划分的问题。

---

## 8. 亲手验证

### 8.1 用纯 JDK 复刻三级缓存

下面这段代码不依赖 Spring，用三个 `Map` 完整复刻循环依赖的解决过程：

```java
import java.util.*;

public class CircularDemo {
    // 一级：成品
    static final Map<String, Object> L1 = new HashMap<>();
    // 二级：半成品
    static final Map<String, Object> L2 = new HashMap<>();
    // 三级：工厂（延迟决定给原对象还是代理）
    static final Map<String, java.util.function.Supplier<Object>> L3 = new HashMap<>();
    // 模拟 AOP：需要代理的 Bean
    static final Set<String> PROXY_BEANS = Set.of("AService");

    static class AService { BService b; public String toString() { return "AService(b=" + b + ")"; } }
    static class AServiceProxy extends AService { public String toString() { return "AService$Proxy(b=" + b + ")"; } }
    static class BService { AService a; public String toString() { return "BService(a=" + (a == null ? "null" : a.getClass().getSimpleName()) + ")"; } }

    // 模拟 getEarlyBeanReference：命中切点则提前创建代理（这里用子类模拟 CGLIB 代理）
    static Object earlyReference(String name, Object raw) {
        if (PROXY_BEANS.contains(name)) {
            System.out.println("  [getEarlyBeanReference] " + name + " 命中切面 -> 提前生成代理");
            return new AServiceProxy();
        }
        return raw;
    }

    static Object getSingleton(String name) {
        if (L1.containsKey(name)) return L1.get(name);                 // 1 级
        if (L2.containsKey(name)) return L2.get(name);                 // 2 级
        if (L3.containsKey(name)) {                                    // 3 级
            Object early = L3.get(name).get();
            L2.put(name, early);
            L3.remove(name);
            System.out.println("  提前暴露 " + name + " -> " + early.getClass().getSimpleName());
            return early;
        }
        return null;
    }

    static Object getBean(String name) {
        Object exist = getSingleton(name);
        if (exist != null) return exist;
        System.out.println("创建 " + name);
        Object bean = name.equals("AService") ? new AService() : new BService();
        L3.put(name, () -> earlyReference(name, bean));                // 实例化后立刻暴露工厂
        if (bean instanceof AService as) as.b = (BService) getBean("BService");
        if (bean instanceof BService bs) bs.a = (AService) getBean("AService");
        Object exposed = L2.containsKey(name) ? L2.get(name) : bean;   // 已提前代理 -> 用代理作成品
        L3.remove(name); L2.remove(name); L1.put(name, exposed);       // 初始化完成 -> 一级
        return exposed;
    }

    public static void main(String[] args) {
        Object a = getBean("AService");
        System.out.println("最终 A（一级缓存）的类型 = " + a.getClass().getSimpleName());
        System.out.println("L1 = " + L1.keySet() + ", L2 = " + L2.keySet() + ", L3 = " + L3.keySet());
    }
}
```

预期输出：

```
创建 AService
创建 BService
  [getEarlyBeanReference] AService 命中切面 -> 提前生成代理
  提前暴露 AService -> AServiceProxy
最终 A（一级缓存）的类型 = AServiceProxy
L1 = [BService, AService], L2 = [], L3 = []
```

**观察点**：B 拿到的 A 是「代理」而不是原对象（因为 A 命中切面）；最终 `L2`、`L3` 都清空，说明缓存只是临时的。

### 8.2 构造器循环依赖必然失败

```java
public class ConstructorCircularDemo {
    static class AService { AService(BService b) { } }
    static class BService { BService(AService a) { } }

    public static void main(String[] args) {
        try {
            // 模拟 Spring：构造 A 需要 B，构造 B 需要 A，工厂永远没机会注册
            System.out.println("尝试构造 AService -> 需要 BService");
            new AService(new BService(null));   // 真实 Spring 会在 getBean 里检测到"正在创建"并抛异常
        } catch (Exception e) {
            System.out.println("失败: " + e.getClass().getSimpleName());
        }
        System.out.println("结论：构造器注入的循环依赖无法用三级缓存解决，需要 @Lazy 或改字段注入");
    }
}
```

预期输出：

```
尝试构造 AService -> 需要 BService
结论：构造器注入的循环依赖无法用三级缓存解决，需要 @Lazy 或改字段注入
```

### 8.3 真实 Spring 的最小配置（需要 Spring 依赖）

```java
// 允许循环依赖（Boot 2.6+ 默认是 false）
// application.yml:
// spring:
//   main:
//     allow-circular-references: true

// 推荐写法：用 @Lazy 打破环
@Service
public class AService {
    @Lazy @Autowired private BService bService;   // 注入代理，首次调用才真正 getBean
}
```

---

## 9. 常见误区

| 错误说法 | 正确说法 |
|---|---|
| 「三级缓存是为了性能」 | 是为了**延迟决定是否生成 AOP 代理** + 解决循环依赖 |
| 「两级缓存就够了，三级多余」 | 两级无法在「对象已暴露」时再决定代理 |
| 「构造器循环依赖也能解决」 | 救不了，抛 `BeanCurrentlyInCreationException` |
| 「缓存里的 Bean 是完整的」 | 二级/三级里是**半成品**（属性未填充） |
| 「提前暴露的对象一定等于最终 Bean」 | 命中切面时，提前暴露的是**代理**，与最终对象不同 |
| 「Spring Boot 默认允许循环依赖」 | Boot 2.6+ 默认禁止，需要显式开启 |
| 「原型作用域也能三级缓存」 | 原型不缓存，不参与此机制 |
| 「三级缓存里的都是原对象」 | 三级里是 `ObjectFactory`，调用后可能返回代理 |

---

## 10. 连续追问 Q&A

### Q1：三级缓存各自存什么？

一级 `singletonObjects`：完整成品；二级 `earlySingletonObjects`：提前暴露的半成品（可能已被代理）；三级 `singletonFactories`：`ObjectFactory` 工厂，调用时才决定返回原对象还是代理。

### Q2：为什么必须三级，二级为什么不行？

二级只能存「对象」，放进去的瞬间就要决定「给原对象还是代理」。但代理本应在初始化后统一生成，提前决定会破坏代理时机的一致性；三级存「工厂」，把决定延迟到真正被提前引用时，从而兼顾「正常 Bean 不提前代理」和「循环依赖时可给代理」。

### Q3：`getEarlyBeanReference` 是谁、什么时候调用的？

由 `AbstractAutoProxyCreator` 实现。它在三级缓存的工厂被 `getObject()` 时调用，负责判断 Bean 是否命中切点，命中则提前创建 AOP 代理并记录到 `earlyProxyReferences`。

### Q4：为什么最终不会重复代理？

`postProcessAfterInitialization` 里会检查 `earlyProxyReferences` 是否已有该 beanName：有就说明已经提前代理过，直接返回原引用，不再 `wrapIfNecessary`。

### Q5：构造器注入为什么救不了？

三级缓存的工厂在 `createBeanInstance` **之后**才注册；构造器注入必须在 `createBeanInstance` **期间**拿到依赖，此时缓存里什么都没有，于是再次触发 `createBean`，检测到「正在创建」就抛异常。

### Q6：怎么破构造器循环依赖？

四种：① 改成字段/setter 注入；② 参数上加 `@Lazy`（注入延迟代理）；③ `@PostConstruct` 里用 `ApplicationContext.getBean` 手动赋值；④ 重构拆环。根本解法是④。

### Q7：Spring Boot 2.6 为什么要默认禁止循环依赖？

循环依赖几乎总是职责划分问题（服务互相调用、工具类互引），会带来：启动顺序不确定、AOP 代理时机复杂、单测难写、潜在的性能与内存问题。默认禁止等于「把问题暴露在启动时」，而不是让它在运行期悄悄埋雷。

### Q8：`@Async` 和 `@Transactional` 的 Bean 互相依赖会怎样？

它们本身会被 AOP 代理。如果形成循环，`getEarlyBeanReference` 会提前生成代理，B 拿到的是代理（而不是原对象），这通常没问题；但要小心「代理里再注入依赖」导致的二次循环，以及 `@Async` 在代理上调用才会异步的语义。

### Q9：原型（prototype）Bean 的循环依赖怎么处理？

原型 Bean 不进入三级缓存（每次都新建），所以循环依赖直接无限递归/栈溢出，Spring 会抛 `BeanCurrentlyInCreationException`。原型 + 循环依赖属于明确不支持。

### Q10：`@Lazy` 为什么能打破循环？

`@Lazy` 注入的是一个**延迟解析的代理**，创建 B 时只是把代理放进去，真正调用 B 的方法时才触发 `getBean(B)`。于是创建 A 的过程中不需要真的把 B 造出来，环被打断。

### Q11：循环依赖的场景下，事务/AOP 会不会失效？

不会，但要注意：B 拿到的是 A 的**代理**（如果 A 命中切面），调用 A 的方法会走代理，切面正常生效。真正会失效的是「拿到原对象」的场景——比如 A 命中切面但第三方提前拿到的不是代理，那说明缓存路径被绕过了。

---

## 11. 一张图总结

```
getBean(A)
  │
  ├─ 查一级（成品）          miss
  ├─ 查二级（半成品）        miss
  ├─ 查三级（工厂）          miss
  ├─ 实例化 A（字段为空）
  ├─ 三级缓存放入 A 的工厂   ← 提前暴露的窗口
  ├─ 填充 A 的属性 -> 需要 B -> getBean(B)
  │     ├─ 实例化 B，三级放入 B 的工厂
  │     ├─ 填充 B 的属性 -> 需要 A -> getSingleton(A)
  │     │     └─ 三级命中 -> 调工厂 -> getEarlyBeanReference
  │     │           ├─ 命中切面 -> 提前创建 A 的代理
  │     │           └─ 未命中   -> 返回原半成品
  │     │        -> 放入二级，删除三级
  │     └─ B 完成 -> 一级
  ├─ A 拿到 B，完成初始化（若已提前代理则不再代理）
  └─ A 放入一级（成品）

三个 Map：三级（工厂，延迟决策）→ 二级（半成品，临时）→ 一级（成品，长期）
```

---

## 12. 一句话复盘

> 循环依赖的解法是「实例化后、初始化前」这个窗口把引用提前暴露；而「是否要生成 AOP 代理」必须延迟决定，所以暴露的不是对象而是工厂（三级缓存），真正被引用时才通过 `getEarlyBeanReference` 决定给原对象还是代理，用过即降级到二级、最终收敛到一级。构造器注入因为「工厂注册晚于构造器解析」而无解，Spring Boot 2.6 起干脆默认禁止，逼你改设计。

---

## 13. 自测题（先自己答，再看答案）

**1. 三级缓存的三个 Map 分别存什么？为什么工厂缓存用 `HashMap` 而不是并发容器？**

答案：一级成品、二级半成品、三级 `ObjectFactory`。工厂缓存只在 `synchronized (singletonObjects)` 块内访问，锁已保证安全，所以用更轻的 `HashMap`。

**2. 为什么二级缓存不够？**

答案：二级存对象，放入时就必须决定「原对象还是代理」；而代理应在初始化后统一生成，提前决定会破坏代理时机一致性。三级存工厂，把决定延迟到真正被提前引用时。

**3. 构造器注入的循环依赖为什么解决不了？**

答案：三级缓存的工厂在 `createBeanInstance` 之后才注册，而构造器注入必须在实例化期间拿到依赖，此时缓存为空，再次 `getBean` 就检测到「正在创建」并抛 `BeanCurrentlyInCreationException`。

**4. 命中切面的 A，在循环依赖里 B 拿到的是原对象还是代理？**

答案：代理。B 触发三级缓存的工厂，`getEarlyBeanReference` 会提前创建代理并记录到 `earlyProxyReferences`，后续不再重复代理。

**5. Spring Boot 2.6 之后默认禁止循环依赖，怎么开启？**

答案：`spring.main.allow-circular-references=true`。但更好的做法是用 `@Lazy`、拆 Bean 或重构依赖来消除环。

**6. `@Lazy` 为什么能解决构造器循环依赖？**

答案：`@Lazy` 注入的是延迟解析的代理，构造时只是把代理放进去，真正调用时才触发 `getBean`，从而在构造阶段不需要真实依赖，环被打断。

---

## 14. 关联文件

- 深一层（追问树 + 源码细节）：[IoC 与 Bean 生命周期](../../10-deep-dive/spring/01-IoC与Bean生命周期.md)
- 同层精讲：[Spring 事务失效](01-Spring事务失效.md)
- 相关精讲：[synchronized 锁升级](../java/08-synchronized锁升级.md)（同步块与 Spring 单例的线程安全）、[线程池执行流程](../java/07-线程池执行流程.md)（异步线程与上下文丢失）
- 返回：[精讲索引](../00-索引.md)
