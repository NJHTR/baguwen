# AOP 与动态代理

> 面试权重：5/5　｜　追问深度：**L5（`AnnotationAwareAspectJAutoProxyCreator` / JDK Proxy vs CGLIB / FastClass / 自调用失效根因）**
> 一句话定位：Spring AOP 是**运行时代理**——一个 `BeanPostProcessor` 在 Bean 初始化后，如果命中切点，就用 JDK Proxy 或 CGLIB 生成一个包装对象替换原 Bean；所有通知最终被组织成一条 `MethodInterceptor` 责任链。

[返回深度追问索引](../00-索引.md)

## L1 一句话答案（10 秒能说出口）

`@EnableAspectJAutoProxy` 通过 `@Import(AspectJAutoProxyRegistrar)` 注册 `AnnotationAwareAspectJAutoProxyCreator`（一个 `BeanPostProcessor`）；它在 `postProcessAfterInitialization` 里判断 Bean 是否命中切点，命中则用 `ProxyFactory` 生成代理（有接口默认 JDK 动态代理，`proxyTargetClass=true` 用 CGLIB），把通知织成 `MethodInterceptor` 链。**自调用失效是因为 `this` 指向原对象，不走代理。**

## L2 原理层：从注解到代理创建

```java
@EnableAspectJAutoProxy(proxyTargetClass = true, exposeProxy = true)   // 两个开关都要会
```

```
@EnableAspectJAutoProxy
 └─ @Import(AspectJAutoProxyRegistrar.class)              // ImportBeanDefinitionRegistrar
     └─ AopConfigUtils.registerAspectJAnnotationAutoProxyCreatorIfNecessary(registry)
         └─ 注册 beanName = "internalAutoProxyCreator"
            class = AnnotationAwareAspectJAutoProxyCreator
                    ├─ extends AspectJAwareAdvisorAutoProxyCreator
                    ├─ implements BeanPostProcessor / SmartInstantiationAwareBeanPostProcessor
                    │             / BeanFactoryAware / Ordered
                    └─ order = Ordered.LOWEST_PRECEDENCE（最后包装，避免被别的 BPP 改坏）
```

创建代理的调用链：

```
postProcessAfterInitialization(bean, beanName)
 └─ wrapIfNecessary：① 是否已代理/基础设施 Bean → 跳过
                     ② getAdvicesAndAdvisorsForBean：findCandidateAdvisors（解析 @Aspect）
                        + findAdvisorsThatCanApply（ClassFilter + MethodMatcher 切点匹配）
                     ③ 有 Advisor → createProxy
 └─ ProxyFactory#getProxy
     ├─ proxyTargetClass=false 且有接口 → JdkDynamicAopProxy（InvocationHandler）
     └─ 否则                              → ObjenesisCglibAopProxy（Enhancer 子类）
```

| | JDK 动态代理 | CGLIB |
|---|---|---|
| 前提 | 目标**必须实现接口** | 目标类**不能是 final**，方法不能 final/private |
| 原理 | `Proxy.newProxyInstance` 生成实现同接口的类，`InvocationHandler.invoke` 里反射调用 | `Enhancer` 生成**子类**，覆写方法，`MethodInterceptor.intercept` 里调 `MethodProxy.invokeSuper` |
| 调用开销 | 反射（`Method.invoke`），较慢 | `FastClass` 按方法索引直接调用，较快 |
| 代理范围 | 只能代理接口方法 | 可代理类方法（含无接口的类） |
| 依赖 | JDK 自带 | 内嵌 CGLIB（Spring 5.2 起 `spring-core` 自带 repackaged） |

**Spring Boot 的默认**：`AopAutoConfiguration` 里 `spring.aop.proxy-target-class` 默认 **true** ⇒ 默认走 CGLIB。所以「有接口用 JDK」只是 Spring Framework 的 `proxyTargetClass=false` 时的规则，Boot 项目里默认已经是 CGLIB。

**CGLIB 的 `FastClass`**：传统反射 `method.invoke` 要解析方法、装箱、权限检查；CGLIB 为每个类生成一个 `FastClass`，内部是 `switch(index)` 或直接调用，用 `methodProxy.invokeSuper` 时按索引定位，避免反射开销。

**拦截器链**：`Advisor` = `Pointcut` + `Advice`；`Advice` 在运行时被包装成 `MethodInterceptor`（`@Before` → `MethodBeforeAdviceInterceptor` 等）。`ReflectiveMethodInvocation.proceed()` 用 `currentInterceptorIndex` 索引递归调用下一个拦截器，最后调目标方法——**经典责任链**，`@Around` 的 `proceed()` 就是这条链的推进器。

## L3 底层层：自调用失效与 `AopContext`

```java
@Service
public class OrderService {
    public void create() {
        this.log();          // 错误：走原对象，不经过代理 ⇒ 切面失效
        // ((OrderService) AopContext.currentProxy()).log();   // 正确：需要 exposeProxy=true
    }
    @Loggable public void log() { }
}
```

**根因**：代理对象持有目标对象，调用 `orderService.log()` 时进的是代理 → 拦截器链 → 目标对象。但目标对象内部 `this.log()` 的 `this` 是**目标对象**，直接走原生方法，根本没经过代理。**AOP 的边界就是「方法进入代理对象的那一次调用」**，内部调用没有新的边界。

| 解法 | 原理 | 注意 |
|---|---|---|
| `AopContext.currentProxy()` | `proxyFactory.setExposeProxy(true)`，代理在调用前把 `this` 放入 `AopContext` 的 `ThreadLocal` | 有 ThreadLocal 开销；异步线程里取不到 |
| 注入自己 `@Lazy OrderService self` | 注入的是代理对象，`self.log()` 走代理 | 必须 `@Lazy` 防循环依赖 |
| 拆到另一个 Bean | 跨 Bean 调用天然走代理 | 最干净，推荐 |
| AspectJ 编译期/加载期织入 | 直接改字节码，没有代理边界问题 | 需要 `-javaagent` 或 LTW，Spring AOP 默认不用 |

**`exposeProxy` 的底层**：`JdkDynamicAopProxy.invoke` 里若有 `this.advised.exposeProxy`，则 `AopContext.setCurrentProxy(proxy)`（`ThreadLocal`），finally 恢复旧值。所以它和 `ThreadLocal` 是一套东西——**换线程就丢**。

> 循环依赖时 AOP 代理的生成走另一条路：`getEarlyBeanReference` 提前创建代理并记录到 `earlyProxyReferences`，`postProcessAfterInitialization` 发现已记录就直接返回，避免二次代理（详见 [IoC 与 Bean 生命周期](./01-IoC与Bean生命周期.md)）。

## L4 追问树（面试官一路往下问，你能撑到第几层？）

> 规则：从上往下问。**第 1-3 层是应届生必备，第 4-6 层是拉开差距，第 7 层以后是"能答出来就是加分"。**

### 第 1 层｜Spring AOP 的原理？
**答**：运行时代理。`AnnotationAwareAspectJAutoProxyCreator` 是 `BeanPostProcessor`，在 Bean 初始化后判断是否命中切点，命中就生成代理对象替换原 Bean，通知被组织成 `MethodInterceptor` 责任链。

### 第 2 层｜JDK 动态代理和 CGLIB 有什么区别？
**答**：JDK 代理**基于接口**，生成实现同接口的类，`InvocationHandler.invoke` 里反射调目标；CGLIB **基于继承**，`Enhancer` 生成子类覆写方法，用 `FastClass` 索引调用、比反射快，但 final 类/方法代理不了。

### 第 3 层｜Spring 怎么选？Boot 默认是哪个？
**答**：`proxyTargetClass=false`（默认）时有接口用 JDK，无接口用 CGLIB；`proxyTargetClass=true` 强制 CGLIB。Spring Boot 的 `AopAutoConfiguration` 把 `spring.aop.proxy-target-class` 默认设为 true ⇒ **Boot 项目默认走 CGLIB**。

### 第 4 层｜为什么 JDK 动态代理必须基于接口？
**答**：JDK 生成的代理类已经 `extends Proxy`，Java 单继承，所以只能再 `implements` 目标接口来获得方法签名；代理类内部把调用转发给 `InvocationHandler`。没有接口就没有可实现的签名集合，只能换 CGLIB 继承目标类。

### 第 5 层｜CGLIB 的 `FastClass` 解决什么问题？
**答**：普通反射 `Method.invoke` 每次都要做方法解析、参数装箱、访问检查。`FastClass` 为类生成一个索引表，`MethodProxy.invokeSuper` 按 `index` 直接调用对应方法（近似 `switch`/直接调用），把反射开销降到接近普通调用。

### 第 6 层｜切点怎么匹配？拦截器链怎么串起来？
**答**：切点 = `ClassFilter` + `MethodMatcher`，`findAdvisorsThatCanApply` 先按类过滤再按方法匹配。命中的 `Advisor` 转成 `MethodInterceptor` 列表，`ReflectiveMethodInvocation.proceed()` 维护一个索引，逐个调下一个拦截器，最后执行目标方法——递归责任链。

### 第 7 层｜为什么同类方法自调用 AOP 会失效？
**答**：因为 `this` 是**目标对象**，不是代理对象。切面织入点在「进入代理」的那一刻，内部 `this.xxx()` 直接调原方法，绕过了整条拦截器链。同理 `@Transactional`/`@Async`/`@Cacheable` 全是这个原因失效。

### 第 8 层｜`AopContext.currentProxy()` 怎么拿到的代理？
**答**：开启 `exposeProxy=true` 后，代理在 `invoke` 开头把自身放进 `AopContext` 的 `ThreadLocal`，`currentProxy()` 就是 `get()` 出来。生命周期是一次代理方法调用（finally 恢复），**所以换线程或事务提交后就取不到了**。

### 第 9 层｜多个切面的顺序怎么控制？
**答**：`@Order`/`Ordered`/`@Priority`。`@Before` 顺序：order 小的先执行；`@After`/`@AfterReturning` 顺序相反（像栈）。同一个 `@Aspect` 内的多个通知默认按定义顺序。order 相同则行为不确定，必须显式指定。

### 第 10 层｜`@Transactional` 和 AOP 什么关系？为什么它也会失效？
**答**：`@Transactional` 就是 AOP：`TransactionInterceptor`（`MethodInterceptor`）拦截方法，在 `invokeWithinTransaction` 里开启/提交事务。失效场景与自调用同源：自调用、private/final 方法、对象不是 Spring 管理的 Bean、异常类型不匹配等。

### 第 11 层｜Spring AOP 和 AspectJ 的区别？
**答**：Spring AOP 是**运行时代理**，只支持方法级切点，只能拦截 Spring Bean 的外部调用，有代理边界问题，但零配置依赖；AspectJ 是**字节码织入**（编译期/加载期），支持字段/构造器切点，无自调用失效，但需要额外编译器或 `-javaagent`。Spring 只是「借用了 AspectJ 的注解和切点表达式语法」。

### 第 12 层（终局）｜一次被代理的方法调用，完整栈是什么样？
**答**：`orderService.create()`（引用类型是代理）→ `JdkDynamicAopProxy.invoke`（或 CGLIB 子类的 `intercept`）→ 取 `advised` 里的拦截器链 → `ReflectiveMethodInvocation.proceed()` 依次执行 `@Before` → `@Around` 前半 → 反射/`invokeSuper` 调**目标对象**方法 → `@Around` 后半 → `@AfterReturning`/`@After` → 返回。**分水岭：能说出「代理对象 → 拦截器链 → 目标对象」这条边界，以及 `this` 为什么跳不过去。**

## L5 名词拆解表（"每个名词都拆开"）

| 名词 | 是什么 | 为什么存在 | 面试追问点 |
|---|---|---|---|
| `@EnableAspectJAutoProxy` | 开启注解式 AOP 的开关 | 显式引入代理创建器 | 两个属性 `proxyTargetClass`/`exposeProxy` |
| `AspectJAutoProxyRegistrar` | `ImportBeanDefinitionRegistrar` | 用代码注册 `internalAutoProxyCreator` | 注册的 beanName 和类名 |
| `AnnotationAwareAspectJAutoProxyCreator` | 核心 `BeanPostProcessor` | 在 Bean 初始化后自动加代理 | 继承结构、`order` 值 |
| `wrapIfNecessary` | 判断并包装的入口 | 统一在这里决定是否代理 | 跳过条件（已代理、基础设施 Bean） |
| `ProxyFactory` | 代理工厂 | 把「选 JDK 还是 CGLIB」封装成一个开关 | `proxyTargetClass` 的传递 |
| `JdkDynamicAopProxy` | `InvocationHandler` 实现 | 基于接口的最小代理 | 为什么必须接口 |
| `ObjenesisCglibAopProxy` | CGLIB 代理实现 | 代理无接口的类 | final 类/方法限制 |
| `Enhancer` / `FastClass` | CGLIB 的字节码增强器 / 快速调用索引 | 生成子类并降低反射开销 | 方法索引、`invokeSuper` |
| `Advisor` / `Advice` | 切点 + 通知 | 把「在哪切」和「切了做什么」分开 | `PointcutAdvisor`、通知转拦截器 |
| `MethodInterceptor` | AOP 联盟的环绕接口 | 所有通知最终统一成它 | `proceed()` 与责任链 |
| `ReflectiveMethodInvocation` | 拦截器链的推进器 | 递归调用链上的下一个 | `currentInterceptorIndex` |
| `AopContext` | 暴露当前代理的 `ThreadLocal` 容器 | 解决自调用 + `exposeProxy` | 异步线程取不到 |
| 自调用失效 | 同类内部调用绕过代理 | 解释所有「注解不生效」 | 4 种解法 |
| 织入（weaving） | 把切面逻辑插入目标的过程 | 区分运行时代理 vs 字节码织入 | Spring AOP / AspectJ LTW 区别 |

## 代码验证（JDK 单文件可直接跑，演示代理边界与自调用失效）

```java
// 保存为 AopDemo.java：javac AopDemo.java && java AopDemo
import java.lang.reflect.*;

interface OrderService { void create(); void log(); }

class OrderServiceImpl implements OrderService {
    public void create() { System.out.println("  执行业务 create"); this.log(); }   // 错误：自调用
    public void log()    { System.out.println("  执行业务 log"); }
}

public class AopDemo {
    @SuppressWarnings("unchecked")
    static <T> T proxy(T target, Class<T> iface) {
        return (T) Proxy.newProxyInstance(iface.getClassLoader(), new Class<?>[]{iface},
            (p, m, args) -> {
                System.out.println("[切面] 进入 " + m.getName());       // 模拟 @Before
                Object r = m.invoke(target, args);                     // 调目标对象
                System.out.println("[切面] 离开 " + m.getName());       // 模拟 @After
                return r;
            });
    }
    public static void main(String[] args) {
        OrderService proxy = proxy(new OrderServiceImpl(), OrderService.class);
        System.out.println("① 外部调用 create()（走代理）:");
        proxy.create();     // 只有 create 的 enter/leave，log 的 enter/leave 不出现 → 自调用失效
        System.out.println("② 外部直接调 log()（走代理）:");
        proxy.log();        // 有 enter/leave
    }
}
```

## 高频错误（面试官最爱抓的）

| 错误说法 | 正确说法 |
|---|---|
| 「Spring AOP 默认用 CGLIB 因为性能好」 | Boot 默认 CGLIB 是因为**无接口也能代理**；Framework 默认 `proxyTargetClass=false` |
| 「JDK 代理不需要接口也能用」 | JDK 动态代理必须基于接口（代理类已继承 `Proxy`） |
| 「CGLIB 能代理 final 方法」 | final 类/方法无法被子类覆写，代理不了 |
| 「自调用加个 `synchronized` 就好」 | 自调用问题是代理边界，必须走代理或织入 |
| 「`AopContext.currentProxy()` 随时随地可用」 | 需 `exposeProxy=true`，且只在本线程调用栈内有效 |
| 「AOP 在实例化时生成代理」 | 在 `postProcessAfterInitialization`（或循环依赖 `getEarlyBeanReference`） |
| 「Spring AOP 支持字段切点」 | 只支持方法级；字段/构造器切点是 AspectJ 的能力 |
| 「多个切面按声明顺序必执行」 | 要显式 `@Order`，否则顺序不确定 |

## 关联文件

- 上一层（Spring 八股）：[SpringBoot与后端工程](../../03-java/SpringBoot与后端工程.md)（AOP / 动态代理 / 事务）
- 同层追问：[IoC 与 Bean 生命周期](./01-IoC与Bean生命周期.md)（代理生成时机）｜[事务传播与失效](./03-事务传播与失效.md)｜[SpringBoot 自动配置](./04-SpringBoot自动配置.md)
- 典型场景：AI Agent 基础设施里「工具调用日志切面 + 耗时监控切面」就用 `@Aspect` + `@Around`；异步任务里取代理要显式透传，不能依赖 `AopContext`
- 速查：[深度追问索引](../00-索引.md)

## 自测标准

- 能背出 `@EnableAspectJAutoProxy` → `AspectJAutoProxyRegistrar` → `internalAutoProxyCreator` 这条链
- 能说清 JDK Proxy 与 CGLIB 的原理、限制与选择规则，以及 Boot 的默认值
- 能解释 `FastClass` 与 `MethodProxy.invokeSuper` 的作用
- 能画出「代理对象 → 拦截器链 → 目标对象」的调用边界
- 能讲清自调用失效根因与 4 种解法，以及 `exposeProxy` 的 `ThreadLocal` 实现
- L4 讲到第 7 层（自调用）→ 及格；讲到第 12 层（完整调用栈）→ 优秀
