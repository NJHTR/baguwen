# IoC 容器与 Bean 生命周期

> 面试权重：5/5　｜　追问深度：**L5（`refresh()` 十二步 / 三级缓存 / `getEarlyBeanReference`）**
> 一句话定位：IoC 容器就是一个「先把类的描述（`BeanDefinition`）读进来，再按描述造对象、塞依赖、跑回调」的工厂；`refresh()` 是它的启动脚本，**三级缓存**是为了在「造到一半就要被别人用」时能提前把半成品（或代理）交出去。

[返回深度追问索引](../00-索引.md)

## L1 一句话答案（10 秒能说出口）

IoC 把「对象怎么创建、依赖谁」的控制权从代码里反转给容器：容器扫描/解析出 `BeanDefinition` 注册到 `BeanFactory`，`refresh()` 里先跑 `BeanFactoryPostProcessor` 加工定义，再实例化所有非懒加载单例（`finishBeanFactoryInitialization`），每个 Bean 走「实例化 → 属性填充 → Aware → 初始化前后（`BeanPostProcessor`）→ 使用 → 销毁」，`@Transactional`/AOP 的代理就是在**初始化后置处理**里生成的。

## L2 原理层：`refresh()` 十二步与两个后置处理器

```java
public void refresh() {
 ① prepareRefresh();                       // 记录启动时间、校验必需属性、初始化占位符
 ② ConfigurableListableBeanFactory bf = obtainFreshBeanFactory();  // 创建/刷新 BeanFactory
 ③ prepareBeanFactory(bf);                 // 加 ApplicationContextAwareProcessor、依赖解析器
 ④ postProcessBeanFactory(bf);             // 子类扩展（Web 容器在这里加 ServletContext 相关）
 ⑤ invokeBeanFactoryPostProcessors(bf);    // 重点：改 BeanDefinition（@Configuration 的 CGLIB 增强在此）
 ⑥ registerBeanPostProcessors(bf);         // 重点：注册 BeanPostProcessor（此时只实例化 BPP 本身）
 ⑦ initMessageSource();                    // 国际化
 ⑧ initApplicationEventMulticaster();      // 事件广播器
 ⑨ onRefresh();                            // 重点：内嵌 Tomcat 就是在这一步创建并启动的
 ⑩ registerListeners();                    // 注册 ApplicationListener
 ⑪ finishBeanFactoryInitialization(bf);    // 重点：实例化所有剩余非懒加载单例，Bean 生命周期全在这
 ⑫ finishRefresh();                        // 发布 ContextRefreshedEvent、启动 Lifecycle 组件
}
```

| | `BeanFactoryPostProcessor` | `BeanPostProcessor` |
|---|---|---|
| 作用对象 | **`BeanDefinition`（元数据）** | **Bean 实例** |
| 时机 | 实例化之前（步骤 ⑤） | 每个 Bean 初始化前后（步骤 ⑥ 注册，⑪ 生效） |
| 典型实现 | `ConfigurationClassPostProcessor`（解析 `@Configuration`/`@ComponentScan`/`@Import`）、`PropertySourcesPlaceholderConfigurer` | `AutowiredAnnotationBeanPostProcessor`（`@Autowired`）、`CommonAnnotationBeanPostProcessor`（`@PostConstruct`）、`AnnotationAwareAspectJAutoProxyCreator`（AOP 代理） |
| 能否改 Bean | 不能，只能改「怎么造 Bean」 | 能，可直接替换/包装 Bean（返回代理） |

**`BeanDefinition`** = 一个 Bean 的「图纸」：`beanClassName`、`scope`、`lazyInit`、`dependsOn`、构造器参数、属性值、`initMethodName`、`autowireMode`、`isPrimary` 等。来源：XML、注解扫描（`ClassPathBeanDefinitionScanner`）、`@Bean` 方法、`@Import`、`BeanDefinitionRegistryPostProcessor` 手动注册。

**Bean 生命周期全流程**：

```
createBeanInstance（推断构造器 → 反射 new）
  → populateBean（@Autowired / @Value 注入，AutowiredAnnotationBeanPostProcessor）
  → invokeAwareMethods（BeanNameAware / BeanFactoryAware / ApplicationContextAware）
  → BeanPostProcessor.postProcessBeforeInitialization   // @PostConstruct 在这里被 CommonAnnotationBPP 调用
  → InitializingBean.afterPropertiesSet（若有）
  → init-method（@Bean(initMethod=...)）
  → BeanPostProcessor.postProcessAfterInitialization    // 重点：AOP 代理在这里生成
  → 放入 singletonObjects，对外可用
  → 销毁：@PreDestroy → DisposableBean.destroy → destroy-method
```

## L3 底层层：三级缓存与 `getEarlyBeanReference`

```java
// DefaultSingletonBeanRegistry
private final Map<String, Object> singletonObjects        = new ConcurrentHashMap<>(256); // ① 一级：成品
private final Map<String, Object> earlySingletonObjects   = new ConcurrentHashMap<>(16);  // ② 二级：半成品
private final Map<String, ObjectFactory<?>> singletonFactories = new HashMap<>(16);      // ③ 三级：工厂

protected Object getSingleton(String beanName, boolean allowEarlyReference) {
    Object singleton = singletonObjects.get(beanName);                    // ①
    if (singleton == null && isSingletonCurrentlyInCreation(beanName)) {
        singleton = earlySingletonObjects.get(beanName);                  // ②
        if (singleton == null && allowEarlyReference) {
            ObjectFactory<?> f = singletonFactories.get(beanName);         // ③
            if (f != null) { singleton = f.getObject();
                earlySingletonObjects.put(beanName, singleton);
                singletonFactories.remove(beanName); }
        }
    }
    return singleton;
}
```

**循环依赖的解决链**（A 依赖 B，B 又依赖 A）：

```
createBean A → 实例化 A（此时 A 的属性还是 null）
  → 把 A 的 ObjectFactory 放入三级缓存（AbstractAutowireCapableBeanFactory#doCreateBean 的 addSingletonFactory）
  → populateBean A：发现需要 B → getBean B
      → 实例化 B → 三级缓存放入 B 的工厂
      → populateBean B：发现需要 A → getSingleton("A") 
          → 一级没有 → 二级没有 → 三级拿到工厂并 getObject() → 得到 A（可能是代理）
          → 放入二级缓存，删除三级 → B 拿到 A
      → B 初始化完成 → 放入一级缓存
  → A 拿到 B，完成属性填充与初始化 → 放入一级缓存
```

**为什么必须三级，不能只有两级？** 因为「是否要提前生成 AOP 代理」这件事必须**延迟到真的发生循环依赖时**才能决定：

- 三级缓存里放的是 `ObjectFactory`，它的 `getObject()` 会调用 `getEarlyBeanReference(beanName, mbd, bean)`（`AbstractAutoProxyCreator` 实现）——**只有别人提前来拿，才会在这里提前创建代理**，并记进 `earlyProxyReferences`
- 如果只有二级缓存，就得在放入二级缓存的那一刻直接决定「给原对象还是给代理」。而正常（无循环依赖）的 Bean 代理是在 `postProcessAfterInitialization` 生成的；两种路径不一致会让「Bean 是否被代理、代理几次」不可控
- AOP 的 `getEarlyBeanReference` 与后置处理里的 `wrapIfNecessary` 通过 `earlyProxyReferences` 去重，保证**同一个 Bean 只被代理一次**

**构造器注入的循环依赖为什么救不了**：`addSingletonFactory` 发生在**实例化之后**，而构造器注入必须在 `createBeanInstance` 阶段就拿到依赖 ⇒ A 的工厂还没进三级缓存，B 来要 A 时只能再触发 `createBean A`，检测到 A 已在创建中 ⇒ 抛 `BeanCurrentlyInCreationException`。解法：改 setter/字段注入、`@Lazy`（注入代理延迟解析）、`@PostConstruct` 里手动赋值、或重构掉环。

> Spring Boot 2.6+ 默认**禁止循环依赖**（`spring.main.allow-circular-references=false`），启动即报错——官方态度很明确：环是设计问题。

## L4 追问树（面试官一路往下问，你能撑到第几层？）

> 规则：从上往下问。**第 1-3 层是应届生必备，第 4-6 层是拉开差距，第 7 层以后是"能答出来就是加分"。**

### 第 1 层｜什么是 IoC？`refresh()` 干了什么？
**答**：IoC 是把对象的创建与依赖装配交给容器。`refresh()` 十二步：准备上下文 → 建 `BeanFactory` → 跑 `BeanFactoryPostProcessor`（加工 `BeanDefinition`）→ 注册 `BeanPostProcessor` → 初始化消息源/事件广播器 → `onRefresh()`（启动内嵌 Tomcat）→ 注册监听器 → **实例化所有非懒加载单例** → 发布 `ContextRefreshedEvent`。

### 第 2 层｜`BeanDefinition` 是什么？什么时候注册进去的？
**答**：Bean 的元数据图纸（类名、scope、构造参数、属性、init/destroy 方法、是否 primary/lazy）。注册时机：`refresh()` 第 ⑤ 步的 `ConfigurationClassPostProcessor` 解析 `@Configuration` 时把扫描到的 `@Component`、`@Bean`、`@Import` 全部注册成 `BeanDefinition`。

### 第 3 层｜`BeanFactoryPostProcessor` 和 `BeanPostProcessor` 区别？
**答**：前者加工**定义**（实例化之前，改「怎么造」），后者加工**实例**（初始化前后，可直接替换成代理）。`@Configuration` 的 CGLIB 增强靠前者，`@Autowired`/`@PostConstruct`/AOP 靠后者。

### 第 4 层｜Bean 生命周期完整顺序？
**答**：实例化 → 属性填充 → Aware 回调（`BeanNameAware`/`BeanFactoryAware`/`ApplicationContextAware`）→ `postProcessBeforeInitialization`（含 `@PostConstruct`）→ `afterPropertiesSet` → `init-method` → `postProcessAfterInitialization`（AOP 代理）→ 使用 → `@PreDestroy` → `destroy` → `destroy-method`。

### 第 5 层｜`@PostConstruct` 是谁调用的？Aware 接口呢？
**答**：`@PostConstruct` 由 `CommonAnnotationBeanPostProcessor`（一个 `BeanPostProcessor`）在 `postProcessBeforeInitialization` 里通过 `InitDestroyAnnotationBeanPostProcessor` 反射调用；`ApplicationContextAware` 由 `ApplicationContextAwareProcessor` 处理，`BeanNameAware`/`BeanFactoryAware` 由 `AbstractAutowireCapableBeanFactory.invokeAwareMethods` 直接调。

### 第 6 层｜循环依赖怎么解决的？为什么需要三级缓存？
**答**：三级缓存：`singletonObjects`（成品）、`earlySingletonObjects`（半成品）、`singletonFactories`（`ObjectFactory`）。实例化后先把工厂放进三级缓存，别人提前来拿时通过 `getEarlyBeanReference` 拿到「可能已被代理」的半成品。三级而不是两级，是为了**把「是否生成代理」延迟到真正发生循环依赖时**，保证代理生成时机与正常路径一致且只代理一次。

### 第 7 层｜`getEarlyBeanReference` 做了什么？
**答**：它在 `AbstractAutoProxyCreator` 里实现：判断当前 Bean 是否命中切面，命中则**提前**创建 AOP 代理，并把 `beanName` 记入 `earlyProxyReferences`；后续 `postProcessAfterInitialization` 看到已记录就不再重复代理，直接返回原引用。这就是「二级缓存要放什么」的答案——它需要先知道要不要代理。

### 第 8 层｜构造器注入的循环依赖为什么救不了？
**答**：三级缓存的 `ObjectFactory` 是在**实例化之后**才放入的（`doCreateBean` 里先 `createBeanInstance` 再 `addSingletonFactory`）；构造器注入必须在实例化阶段就拿到依赖，此时工厂还没进缓存 ⇒ 再次 `createBean` 触发「正在创建」检测 ⇒ `BeanCurrentlyInCreationException`。

### 第 9 层｜怎么破构造器循环依赖？
**答**：① 字段/setter 注入（改成实例化后填充）；② `@Lazy` 注在参数上，注入一个延迟解析的代理；③ `@PostConstruct` 里手动通过 `ApplicationContext.getBean` 赋值；④ 更根本的是重构，把环拆成单向依赖。Spring Boot 2.6+ 默认直接禁止循环依赖，先报错再让你改设计。

### 第 10 层｜单例 Bean 是线程安全的吗？
**答**：不是。单例只保证**一个实例**，不保证**状态安全**。无状态 Bean（Controller/Service 只放依赖）安全；有可变成员变量就有并发问题，需要 `ThreadLocal`、局部变量、不可变对象或加锁。这是「Spring 单例」最常见的错误认知。

### 第 11 层｜`BeanFactory` 和 `ApplicationContext` 区别？`FactoryBean` 呢？
**答**：`BeanFactory` 是最底层容器（懒加载，`getBean` 才创建）；`ApplicationContext` 继承它并加上事件、国际化、资源加载、`BeanPostProcessor` 自动注册，且默认**预实例化**单例。`FactoryBean` 是「造 Bean 的 Bean」，`getBean("&name")` 拿工厂本身，`getBean("name")` 拿 `getObject()` 产物（MyBatis 的 `MapperFactoryBean` 就是典型）。

### 第 12 层（终局）｜执行 `getBean("userService")` 的完整调用链？
**答**：`DefaultListableBeanFactory.getBean` → `doGetBean`：先查三级缓存 → 无则 `createBean`（合并 `BeanDefinition`、`resolveBeforeInstantiation` 让 `InstantiationAwareBeanPostProcessor` 有机会短路）→ `doCreateBean`：`createBeanInstance`（构造器推断 + 反射）→ `addSingletonFactory` 提前暴露 → `populateBean`（`@Autowired`）→ `initializeBean`（Aware → BPP before → init 方法 → BPP after 生成代理）→ `addSingleton` 放入一级缓存 → 销毁时注册 `DisposableBeanAdapter`。**分水岭：能说清「短路钩子 `resolveBeforeInstantiation`」和「代理在 BPP after 生成」。**

## L5 名词拆解表（"每个名词都拆开"）

| 名词 | 是什么 | 为什么存在 | 面试追问点 |
|---|---|---|---|
| `BeanDefinition` | Bean 的元数据（类名/scope/构造参数/属性） | 把「定义」与「实例」分离，支持动态注册 | 来源渠道、`RootBeanDefinition` 合并 |
| `BeanFactory` | 最底层容器接口 | 只负责造 Bean，职责最小 | 与 `ApplicationContext` 区别 |
| `ApplicationContext` | 增强容器（事件/国际化/资源） | 一站式应用上下文 | 预实例化、`refresh()` 在哪 |
| `refresh()` | 容器启动的模板方法 | 把启动流程固定为 12 个可扩展步骤 | 各步作用，尤其 ⑤⑥⑨⑪ |
| `BeanFactoryPostProcessor` | 加工 `BeanDefinition` 的扩展点 | 在实例化前改「怎么造」 | 与 BPP 的区别、`@Configuration` 增强 |
| `BeanPostProcessor` | 加工 Bean 实例的扩展点 | 统一实现注入/AOP/生命周期回调 | 注册时机、`postProcessBefore` vs `After` |
| 三级缓存 | `singletonObjects` / `earlySingletonObjects` / `singletonFactories` | 解决单例字段注入循环依赖 | 为什么三级、存的是什么 |
| `ObjectFactory` | 三级缓存里放的工厂（函数式） | 延迟决定「给原对象还是代理」 | `getEarlyBeanReference` |
| `getEarlyBeanReference` | 提前创建 AOP 代理的钩子 | 循环依赖时也要拿到代理对象 | `earlyProxyReferences` 去重 |
| `BeanCurrentlyInCreationException` | 「Bean 正在创建」异常 | 检测无法解决的循环 | 构造器注入为什么触发 |
|  Aware 接口 | `BeanNameAware` / `BeanFactoryAware` / `ApplicationContextAware` | 让 Bean 拿到容器信息 | 谁调用、顺序在哪 |
| `InitializingBean` / `@PostConstruct` | 初始化回调 | 依赖注入完成后做初始化 | 两者顺序、谁触发 |
| `DisposableBean` / `@PreDestroy` | 销毁回调 | 释放连接/线程池 | 单例销毁时机、原型不管 |
| `FactoryBean` | 造 Bean 的工厂 Bean | 集成第三方对象（MyBatis Mapper） | `&` 前缀、`getObject` |

## 代码验证（JDK 单文件可直接跑，复刻三级缓存逻辑）

```java
// 保存为 CacheDemo.java：javac CacheDemo.java && java CacheDemo
import java.util.*;
import java.util.function.Supplier;

public class CacheDemo {
    static final Map<String, Object> L1 = new HashMap<>();                    // singletonObjects
    static final Map<String, Object> L2 = new HashMap<>();                    // earlySingletonObjects
    static final Map<String, Supplier<Object>> L3 = new HashMap<>();          // singletonFactories

    static class AService { BService b; }
    static class BService { AService a; }

    static Object getBean(String name) {
        if (L1.containsKey(name)) return L1.get(name);           // ① 成品
        if (L2.containsKey(name)) return L2.get(name);           // ② 半成品
        if (L3.containsKey(name)) {                              // ③ 工厂（提前暴露）
            Object early = L3.get(name).get();
            L2.put(name, early); L3.remove(name);
            System.out.println("  提前暴露 " + name + " 给调用方");
            return early;
        }
        Object bean = "AService".equals(name) ? new AService() : new BService();
        L3.put(name, () -> bean);                                // addSingletonFactory：实例化后立刻暴露
        if (bean instanceof AService as) as.b = (BService) getBean("BService");
        if (bean instanceof BService bs) bs.a = (AService) getBean("AService");
        L3.remove(name); L2.remove(name); L1.put(name, bean);    // 初始化完成 → 进一级缓存
        return bean;
    }

    public static void main(String[] args) {
        AService a = (AService) getBean("AService");
        System.out.println("A.b 非空: " + (a.b != null));
        System.out.println("B.a 与 A 是同一对象（循环依赖被解开）: " + (a.b.a == a));
    }
}
```

## 高频错误（面试官最爱抓的）

| 错误说法 | 正确说法 |
|---|---|
| 「三级缓存是为了性能」 | 是为了**延迟决定是否生成代理** + 解决循环依赖 |
| 「二级缓存就够，Spring 多此一举」 | 两级无法在「提前引用」时正确生成 AOP 代理 |
| 「构造器注入也能循环依赖」 | 救不了，抛 `BeanCurrentlyInCreationException` |
| 「`BeanPostProcessor` 能改 `BeanDefinition`」 | 那是 `BeanFactoryPostProcessor` 的活 |
| 「`@PostConstruct` 是 Spring 注解，由 Spring 直接调」 | 是 `CommonAnnotationBeanPostProcessor` 反射调用 |
| 「单例 Bean 是线程安全的」 | 只保证一个实例，不保证状态并发安全 |
| 「AOP 代理在实例化时生成」 | 在 `postProcessAfterInitialization`（或循环依赖时 `getEarlyBeanReference`） |
| 「`refresh()` 第 11 步才开始建容器」 | 容器本身在第 ② 步就有了，第 ⑪ 步是**实例化单例** |

## 关联文件

- 上一层（Spring 八股）：[SpringBoot与后端工程](../../03-java/SpringBoot与后端工程.md)（IoC / Bean 生命周期 / 循环依赖）
- 同层追问：[AOP 与动态代理](./02-AOP与动态代理.md)｜[事务传播与失效](./03-事务传播与失效.md)｜[SpringBoot 自动配置](./04-SpringBoot自动配置.md)
- 底层支撑：[volatile、CAS 与 AQS](../java/10-volatile-CAS-AQS.md)（容器里大量 `ConcurrentHashMap` + `ThreadLocal`）
- 典型场景：AI Agent 基础设施里「工具执行器按类型注册成 Bean」，正是 `BeanFactoryPostProcessor` + `@Component` 扫描的典型用法
- 速查：[深度追问索引](../00-索引.md)

## 自测标准

- 能按顺序背出 `refresh()` 十二步，并指出哪三步最关键（⑤⑥⑪）
- 能说清两种后置处理器的区别与各自典型实现
- 能画出 Bean 生命周期全流程图，并把 `@PostConstruct`、AOP 代理放到正确位置
- 能画出三级缓存 + 循环依赖的调用链，并解释「为什么必须三级」
- 能解释构造器循环依赖为什么救不了，以及 `@Lazy` 为什么能救
- L4 讲到第 8 层（构造器注入）→ 及格；讲到第 12 层（`getBean` 全链路）→ 优秀
