# SpringBoot 与后端工程

> 面试权重：5/5（必考）　|　建议投入：6 天
> 适用场景：Java 后端岗必问模块。中小厂问「你项目里怎么用」，大厂追问「底层怎么实现、为什么这么设计」，`@Transactional` 失效场景几乎 100% 会问。

**模块定位**：本章把 [Java 基础与并发](Java基础与并发.md) 的知识变成工程能力——IoC 的容器本质是 `ConcurrentHashMap`，AOP 靠反射与动态代理，事务靠 `ThreadLocal` 绑定连接。写接口的部分要配合 [MySQL 与 Redis](../04-database/MySQL与Redis.md) 的索引与缓存一起讲才完整；方案层可延伸到 [系统设计入门](../06-system-design/系统设计入门.md) 的幂等与限流；面试包装见 [项目复盘与简历](../08-project/项目复盘与简历.md)。

**使用建议**：面试官问「你项目里怎么用的」时，先给一句话结论，再举自己项目的真实场景（比如「订单接口用 `@Transactional(rollbackFor = Exception.class)`，库存扣减用 `REQUIRES_NEW` 独立事务」）。只背概念不举例是初级和中级的分水岭。

## 1. Spring 解决了什么 & IoC 与 DI

**一句话答案**：Spring 用 IoC 容器接管对象的创建与依赖装配，用 AOP 处理横切逻辑，让业务代码只关心业务；DI 是 IoC 的实现方式。

**原理展开**：
- 没有 Spring 时：`new Service(new Dao(new DataSource()))` 层层硬编码，换实现要改代码，单元测试没法 mock。
- IoC（控制反转）：把「创建对象、管理依赖」的控制权从代码交给容器；DI（依赖注入）是具体手段——构造器注入、setter 注入、字段 `@Autowired`。
- 容器体系：`BeanFactory`（基础容器，默认懒加载）vs `ApplicationContext`（生产用，继承 BeanFactory，多了事件发布、国际化、资源加载、AOP 集成，启动时实例化单例）。
- 三种注入方式取舍：**构造器注入**最推荐（依赖不可变、缺依赖启动就报错、易测试）；setter 适合可选依赖；字段注入代码最短但隐藏依赖、无法 final。
- 注解等价关系：`@Controller`/`@Service`/`@Repository` 本质都是 `@Component`，只是语义分层。
- 注入匹配规则：`@Autowired` 默认按类型，多个候选时按字段名匹配，再用 `@Qualifier`/`@Primary` 指定；`@Resource` 是 JDK 标准、默认按名称。

**面试怎么答（60 秒版）**：Spring 核心就两件事：IoC 和 AOP。IoC 是把对象的创建和依赖装配交给容器，我只需要声明「我需要什么」，不用自己 new，这样实现类可以随时替换，也方便 mock 测试。DI 是 IoC 的具体实现，我项目里主要用构造器注入，依赖更明确、不会出现空注入。AOP 负责日志、事务这类横切逻辑。容器本身是 BeanFactory 和 ApplicationContext 两级，后者功能更全，平时用的都是它。

**追问陷阱**：
- 错误：「IoC 就是依赖注入」→ 正确：IoC 是思想（控制权反转），DI 是实现手段，二者不等价。
- 错误：全程用字段 `@Autowired` → 正确：能说出构造器注入的优势（final、启动即校验、无循环依赖隐患），这是加分点。

## 2. Bean 生命周期

**一句话答案**：实例化 → 属性填充 → Aware 回调 → `BeanPostProcessor` 前置 → 初始化（`@PostConstruct` → `afterPropertiesSet` → `init-method`）→ `BeanPostProcessor` 后置（AOP 代理在这里生成）→ 使用 → 销毁。

**原理展开**：
- 实例化：反射调用构造器创建对象（此时字段还是 null）。
- 属性填充：`populateBean` 注入依赖，循环依赖在这一步暴露。
- Aware 回调：`BeanNameAware`、`BeanFactoryAware`、`ApplicationContextAware` 让 Bean 拿到容器能力。
- `BeanPostProcessor.postProcessAfterInitialization` 是 AOP 生成代理的时机，所以**代理对象替换了原始对象**，这也是同类调用不走代理的根因。
- 销毁：容器关闭时 `@PreDestroy` → `DisposableBean.destroy()` → `destroy-method`；prototype 作用域的 Bean 容器不管理销毁。

**面试怎么答（60 秒版）**：Bean 生命周期大致是：先反射实例化，然后填充属性注入依赖，接着回调各种 Aware 接口，再执行初始化方法——顺序是 @PostConstruct、afterPropertiesSet、init-method，前后各有 BeanPostProcessor 介入，其中后置处理器是 AOP 生成代理的时机，最后放进单例池供使用，容器关闭时执行销毁方法。理解这个流程就能解释两个常考问题：为什么同类方法调用事务失效，因为调用的是原始对象不是代理；为什么 @PostConstruct 里不能保证 AOP 已生效。

**追问陷阱**：
- 错误：把 `BeanPostProcessor` 说成「初始化之后才创建对象」→ 正确：它贯穿初始化前后，后置阶段才生成 AOP 代理。
- 错误：以为 prototype Bean 的 `@PreDestroy` 会执行 → 正确：容器不跟踪 prototype，销毁方法不会调用。

## 3. Bean 作用域

**一句话答案**：默认 `singleton`（容器内唯一），另有 `prototype`（每次获取新建），Web 环境还有 `request`、`session`、`application`、`websocket`。

**原理展开**：
- singleton：容器启动创建（可配 `@Lazy` 延迟），放单例池 `singletonObjects`，全局共享——所以**单例 Bean 必须无状态**，否则并发下数据串号。
- prototype：每次 `getBean` 新建实例，Spring 不缓存也不管理销毁，适合有状态对象。
- Web 作用域：`request` 每次请求一个实例、`session` 每个会话一个、`application` 每个 ServletContext 一个。
- 经典坑：单例 Bean 注入 prototype Bean，只会注入一次，之后拿到的永远是同一个——因为单例只初始化一次。
- 解法：`ObjectProvider<T>` 每次 `getObject()` 新建、`@Lookup` 方法注入、或把 prototype Bean 定义为 scoped proxy。
- 单例的线程安全：Spring 不保证，无状态（只有方法、没有可变成员）才安全；有状态需自己加锁或改用 ThreadLocal。

**面试怎么答（60 秒版）**：Spring Bean 默认是单例，容器里只有一个实例，启动时创建好，所以单例 Bean 必须是无状态的，有成员变量存请求数据就会踩并发问题。prototype 是每次获取都新建，Spring 创建后就不管了，销毁方法也不会调用。Web 环境还有 request 和 session 作用域。有个常见坑是单例里注入 prototype，因为单例只初始化一次，所以永远拿到同一个对象，要用 ObjectProvider 或者 @Lookup 才能每次拿新的。

**追问陷阱**：
- 错误：「单例 Bean 是线程安全的」→ 正确：Spring 只保证创建一次，不保证线程安全，安全与否取决于有没有可变状态。
- 错误：「prototype 一定更好，因为不会串数据」→ 正确：创建和销毁成本高，无状态服务用单例更合适。

## 4. 循环依赖与三级缓存

**一句话答案**：Spring 用三级缓存解决**单例 + setter/字段注入**的循环依赖；构造器注入和 prototype 解决不了，SpringBoot 2.6+ 默认已禁止循环依赖。

**原理展开**：
- 三级缓存：`singletonObjects`（一级，成品 Bean）、`earlySingletonObjects`（二级，提前暴露的半成品）、`singletonFactories`（三级，`ObjectFactory` 工厂）。
- 流程：A 实例化后先把「能生产 A 早期引用的工厂」放进三级 → 填充属性发现依赖 B → 创建 B → B 填充属性需要 A → 从三级缓存调到工厂拿到 A 的早期引用（必要时在这里生成 AOP 代理）→ 放入二级、清掉三级 → B 完成进一级 → A 完成填充，从二级拿到 B 进一级。
- 为什么必须三级而不是两级：如果只有两级，就必须在暴露早期引用时立刻决定是否创建 AOP 代理；用工厂回调 `getEarlyBeanReference` 可以做到「只有真被循环依赖时才提前生成代理」，保证正常 Bean 的代理时机不变。
- 为什么构造器注入解决不了：对象还没实例化完，无法提前暴露任何引用，直接抛 `BeanCurrentlyInCreationException`。
- SpringBoot 2.6+ 默认 `spring.main.allow-circular-references=false`，出现循环依赖直接启动失败；临时可开启，但**正确做法是重构依赖**（抽公共服务、用事件解耦）。
- 其他解法：`@Lazy` 注入代理延迟初始化、改用 setter 注入、`ApplicationContext.getBean()`（不推荐，隐式依赖）。

**面试怎么答（60 秒版）**：Spring 用三级缓存解决循环依赖：一级存成品 Bean，二级存提前暴露的半成品，三级存能生成早期引用的工厂。A 实例化后先把工厂放三级，去注入 B，B 又要 A 时从三级拿到 A 的早期引用，这样循环就断开了。用三级而不是两级是为了延迟决定要不要提前生成 AOP 代理，保证代理时机一致。这套机制只对单例和 setter/字段注入有效，构造器注入因为对象还没创建完所以解决不了，SpringBoot 2.6 之后默认也禁止循环依赖了，应该从设计上拆开。

**追问陷阱**：
- 错误：「三级缓存是为了性能」→ 正确：是为了解决 AOP 代理的创建时机问题（延迟暴露），不是为了快。
- 错误：「Spring 能解决所有循环依赖」→ 正确：构造器注入、prototype 都不行。

## 5. AOP 原理与动态代理

**一句话答案**：AOP 把日志、事务、权限等横切逻辑抽成切面，运行时用动态代理在方法调用前后织入；Spring 用 JDK Proxy（基于接口）和 CGLIB（基于继承）两种方式。

**原理展开**：
- 术语：切面 Aspect、连接点 JoinPoint（可被拦截的方法）、切点 Pointcut（表达式筛选）、通知 Advice（做什么）、织入 Weaving。
- 五种通知：`@Before`、`@After`（finally）、`@AfterReturning`、`@AfterThrowing`、`@Around`（最灵活，能改返回值）。
- JDK 动态代理：目标类必须实现接口，`Proxy.newProxyInstance` 生成实现类，`InvocationHandler.invoke` 里加逻辑。
- CGLIB：通过 ASM 生成目标类的子类并重写方法，所以 `final` 类/方法、`private` 方法无法代理。
- Spring 选择：目标有接口默认 JDK 代理；SpringBoot 2.x 起 `spring.aop.proxy-target-class` 默认 `true`，**统一用 CGLIB**，避免「注入接口拿到代理、注入实现类报错」的问题。
- 失效场景：同类内部方法调用走 `this`（原始对象）不走代理、`private/final/static` 方法、对象不是 Spring 管理的（自己 new）。

**面试怎么答（60 秒版）**：AOP 是把日志、事务、权限这类横切关注点从业务代码里抽出来，用动态代理在方法执行前后织入。Spring 支持两种代理：JDK 动态代理要求目标类实现接口，通过 InvocationHandler 增强；CGLIB 是生成子类重写方法，所以 final 类和 private 方法代理不了。SpringBoot 2.x 默认统一用 CGLIB。理解代理是解释「@Transactional 为什么同类调用失效」的关键，因为内部调用是 this 调用，根本没经过代理。

**追问陷阱**：
- 错误：「AOP 是编译期织入」→ 正确：Spring AOP 是运行期动态代理（AspectJ 才支持编译期/加载期织入）。
- 错误：认为 `@Transactional` 加在 private 方法上有效 → 正确：代理无法增强，直接静默失效。

## 6. AOP 实战：日志与权限

**一句话答案**：自定义注解标在方法上，`@Aspect` 类用 `@Around` 切 `@annotation` 或自定义切点，统一记录耗时、入参、用户、异常——这就是生产环境的操作日志方案。

**原理展开**：
- 三步：定义 `@LogOperation` 注解（可带模块、类型属性）→ 业务方法上标注 → 切面拦截并异步落库。
- 日志切面要记录：方法名、入参、当前登录用户、耗时、成功/失败、异常信息、IP；用 `ThreadLocal` 存当前用户。
- 关键点：日志落库要 `@Async` 或 MQ 异步，否则同步写库拖慢主链路；记录入参要脱敏（手机号、密码）。
- 权限场景一般不单靠 AOP：需要 request 信息时用拦截器 + 自定义注解更自然；AOP 更适合纯方法级校验（如「该用户是否有此数据权限」）。
- 切点表达式：`execution(* com.example.service..*.*(..))`（按包/方法）、`@annotation(xxx)`（按注解）、`@within(xxx)`（按类注解）。
- 顺序控制：多个切面用 `@Order` 决定执行顺序（事务切面默认最低优先级，保证包住业务逻辑）。

```java
@Aspect
@Component
public class LogAspect {
    @Around("@annotation(com.example.log.LogOperation)")
    public Object around(ProceedingJoinPoint pjp) throws Throwable {
        long start = System.currentTimeMillis();
        try {
            return pjp.proceed();
        } finally {
            MethodSignature sig = (MethodSignature) pjp.getSignature();
            log.info("method={} cost={}ms", sig.getName(), System.currentTimeMillis() - start);
        }
    }
}
```

**面试怎么答（60 秒版）**：我项目里的操作日志就是 AOP 做的。先定义一个 @LogOperation 注解，在需要记录的业务方法上标注，然后写一个 @Aspect 切面用 @Around 拦截，环绕里记录方法名、入参、当前用户、耗时和异常，正常或异常都落一条记录。落库我一般做成异步或者发 MQ，避免影响主链路性能，敏感字段要做脱敏。相比在业务代码里手写日志，AOP 的方式业务代码零侵入，加个注解就行。

**追问陷阱**：
- 错误：在切面里直接同步写日志表 → 正确：会拖慢接口，应异步；极端场景 MQ 解耦。
- 错误：用 AOP 做登录校验 → 正确：登录校验依赖 request/拦截链，用拦截器更合适，AOP 拿不到完整请求上下文。

## 7. @Transactional 传播行为

**一句话答案**：`@Transactional` 是 AOP + `DataSourceTransactionManager` 实现的声明式事务，连接通过 `ThreadLocal` 绑定；传播行为默认 `REQUIRED`，七种里最常考 `REQUIRED`、`REQUIRES_NEW`、`NESTED`。

**原理展开**：
- 底层：代理拦截方法 → 事务管理器开启事务 → 从连接池取连接绑到 `ThreadLocal` → 执行 → 提交或回滚；同一线程内多次操作共用同一连接，所以能回滚。
- `REQUIRED`（默认）：有事务就加入，没有就新建；任何一个方法抛异常，整个事务回滚。
- `REQUIRES_NEW`：挂起当前事务，新建独立事务；内层提交或回滚不影响外层——适合「日志落库不受主流程回滚影响」，但会多占一个连接，配置不当易死锁。
- `NESTED`：用数据库 savepoint 实现嵌套，内层回滚到保存点，外层可继续；与 REQUIRES_NEW 的区别是共用同一连接、外层回滚会带上内层。
- 其余四种：`SUPPORTS`（有则加入无则不用）、`NOT_SUPPORTED`（挂起事务、非事务执行）、`MANDATORY`（必须在事务中，否则报错）、`NEVER`（必须无事务，否则报错）。
- 常用属性：`rollbackFor`（默认只回滚 `RuntimeException`/`Error`，受检异常必须显式指定）、`readOnly = true`（只读优化）、`isolation`、`timeout`。

```java
@Service
public class OrderService {
    @Transactional(rollbackFor = Exception.class, propagation = Propagation.REQUIRED)
    public void createOrder(OrderDTO dto) {
        orderMapper.insert(dto.toEntity());
        stockService.deduct(dto.getSkuId(), dto.getCount());   // 默认加入同一事务
        if (dto.getCount() > 100) {
            throw new BizException("单次下单数量超限");         // 运行时异常 → 整体回滚
        }
    }
}
```

**面试怎么答（60 秒版）**：@Transactional 是基于 AOP 的声明式事务，代理在方法前后开启提交事务，连接由事务管理器绑定到 ThreadLocal，所以同一个线程里的多个操作共用一个连接、能一起回滚。传播行为默认是 REQUIRED，有事务就加入、没有就新建。如果内层需要独立提交，比如记日志不能跟着回滚，就用 REQUIRES_NEW，它会挂起外层事务新开一个。NESTED 是用 savepoint 做嵌套回滚，和外层共用一个连接。默认只回滚运行时异常，所以我会显式写 rollbackFor = Exception.class。

**追问陷阱**：
- 错误：「REQUIRES_NEW 和 NESTED 一样」→ 正确：前者独立连接、独立提交，后者 savepoint、共用连接，外层回滚会连带。
- 错误：不写 `rollbackFor` 却抛受检异常 → 正确：默认不回滚，事务静默提交。

## 8. 事务失效的 8 个场景（必考）

**一句话答案**：事务失效本质是「AOP 代理没起作用」或「异常没抛到代理层」——方法非 public、同类内部调用、异常被吞、异常类型不匹配、对象不由 Spring 管理、存储引擎不支持、多线程、传播行为设置不当。

**原理展开**：
- ① 方法不是 `public`：`@Transactional` 只对 public 方法生效（代理拦截不到 private/protected 的语义边界）。
- ② **同类内部调用**：`this.methodB()` 不经过代理，B 上的事务注解完全不生效——最高频考点，解法是注入自身代理、`AopContext.currentProxy()`（需 `exposeProxy=true`）或把方法拆到另一个 Bean。
- ③ 异常被 `try-catch` 吞掉：代理感知不到异常，照常提交。
- ④ 抛受检异常但没配 `rollbackFor`：默认只回滚 `RuntimeException` 和 `Error`。
- ⑤ Bean 不由 Spring 管理：自己 `new` 出来的对象没有代理。
- ⑥ 存储引擎不支持事务：MySQL 的 MyISAM 不支持，必须 InnoDB。
- ⑦ 多线程/异步调用：事务连接绑在 ThreadLocal，新线程拿不到，不在同一事务里（`@Async` 里再操作数据库要自己开事务）。
- ⑧ 传播行为设置不当：`NOT_SUPPORTED`/`NEVER` 会挂起或禁止事务。
- 补充：`final`/`static` 方法（CGLIB 无法重写子类方法）、类本身没加 `@Service` 等注解。

**面试怎么答（60 秒版）**：事务失效我总结成两类原因：要么代理没生效，要么异常没抛出去。代理没生效的典型是同类内部方法调用，this 调用绕过了代理，注解等于没写；还有方法不是 public、Bean 不是 Spring 管理的、方法是 final 或 static。异常没抛出去就是 try-catch 把异常吞了，或者抛的是受检异常但没配 rollbackFor，默认只回滚运行时异常。另外多线程和 @Async 里也拿不到同一个事务。排查时我会先确认调用是不是走了代理，再看异常有没有真的抛到最外层。

**追问陷阱**：
- 错误：「加了 @Transactional 就一定有事务」→ 正确：必须走代理调用，内部调用等于没加。
- 错误：用 `AopContext.currentProxy()` 却没开 `exposeProxy` → 正确：需 `@EnableAspectJAutoProxy(exposeProxy = true)`。

## 9. Spring MVC 请求处理流程

**一句话答案**：请求先过 Filter 进 `DispatcherServlet`，`HandlerMapping` 找到 handler 和拦截器链，`HandlerAdapter` 适配执行、参数解析绑定，返回值经 `HttpMessageConverter` 转 JSON 或 `ViewResolver` 解析视图，最后响应。

**原理展开**：
- 入口：`DispatcherServlet`（本质是 Servlet）的 `doDispatch`。
- 第一步 `getHandler`：`RequestMappingHandlerMapping` 根据 URL + 方法匹配到 `HandlerMethod`，包装成 `HandlerExecutionChain`（含拦截器）。
- 第二步 `getHandlerAdapter`：找到 `RequestMappingHandlerAdapter`。
- 参数绑定：`HandlerMethodArgumentResolver` 负责 `@RequestParam`、`@PathVariable`、`@RequestBody`（`HttpMessageConverter` 反序列化 JSON）、`@Valid` 校验、`HttpServletRequest` 等。
- 执行 Controller 返回 `ModelAndView` 或对象；配置了 `@ResponseBody`/`@RestController` 时由 `RequestResponseBodyMethodProcessor` 走 `HttpMessageConverter` 直接写 JSON，不再走视图解析。
- 拦截器三个时机：`preHandle`（返回 false 中断）、`postHandle`（Controller 执行后、视图渲染前）、`afterCompletion`（请求完成，用于清理 ThreadLocal）。

**面试怎么答（60 秒版）**：请求先经过 Filter 进到 DispatcherServlet，它作为前端控制器去 HandlerMapping 里根据 URL 找到对应的 Controller 方法和拦截器链，再选一个 HandlerAdapter 来执行。执行前由参数解析器把请求参数绑定到方法参数上，比如 @RequestBody 就交给消息转换器反序列化 JSON，同时做参数校验，然后调用 Controller。返回值如果有 @ResponseBody 就由消息转换器直接写 JSON，否则交给视图解析器渲染页面。最后按逆序执行拦截器的后置方法，把响应返回。

**追问陷阱**：
- 错误：把拦截器说成在 Filter 之前 → 正确：Filter 在 Servlet 容器层，先于 DispatcherServlet，拦截器在容器内。
- 错误：以为 `@ResponseBody` 还会走 `ViewResolver` → 正确：直接写响应体，跳过视图解析。

## 10. SpringBoot 自动配置原理

**一句话答案**：`@SpringBootApplication` = `@SpringBootConfiguration` + `@EnableAutoConfiguration` + `@ComponentScan`；自动配置靠 `@EnableAutoConfiguration` 导入选择器读 `AutoConfiguration.imports`（2.7 前是 `spring.factories`），再按 `@Conditional` 条件筛选注册 Bean。

**原理展开**：
- 三段拆解：`@SpringBootConfiguration`（本质是 `@Configuration`，标志配置类）、`@ComponentScan`（默认扫描启动类所在包及子包）、`@EnableAutoConfiguration`（核心）。
- `@EnableAutoConfiguration` = `@AutoConfigurationPackage`（把启动类所在包注册进 `BasePackages`）+ `@Import(AutoConfigurationImportSelector.class)`。
- 选择器负责读取 classpath 下所有 `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`（Spring Boot 2.7+）或旧版 `META-INF/spring.factories`，得到几百个自动配置类的全限定名。
- 条件装配：`@ConditionalOnClass`（classpath 有某类才配）、`@ConditionalOnMissingBean`（用户没定义才配，这是用户配置优先的关键）、`@ConditionalOnProperty`、`@ConditionalOnWebApplication`。
- 典型例子：引入 `spring-boot-starter-web` 后 `DispatcherServletAutoConfiguration`、`JacksonAutoConfiguration` 生效；用户自己定义 `DataSource` 后 `DataSourceAutoConfiguration` 退让。
- 启动流程：`SpringApplication.run` → 准备 `Environment`（加载配置文件/环境变量）→ 创建 `ApplicationContext` → `prepareContext`（注册主类、执行 Initializer）→ `refreshContext`（刷新容器，自动配置在此注册 Bean）→ `afterRefresh` → 执行 `Runner`。

**面试怎么答（60 秒版）**：@SpringBootApplication 其实是三个注解的组合：@SpringBootConfiguration 标记配置类、@ComponentScan 扫描启动类所在包、@EnableAutoConfiguration 负责自动配置。@EnableAutoConfiguration 通过 @Import 导入一个选择器，选择器在启动时读取 classpath 下 jar 里的自动配置类清单，以前是 spring.factories，2.7 之后是 AutoConfiguration.imports 文件，把这些配置类都加载进来。但加载不等于生效，每个自动配置类上都有 @ConditionalOnClass、@ConditionalOnMissingBean 这些条件，只有满足条件才真正注册 Bean，所以用户自己定义了 Bean 就会优先用用户的。

**追问陷阱**：
- 错误：「自动配置是启动时扫描包得到的」→ 正确：是读取固定路径的清单文件，不是扫描。
- 错误：「自动配置类里的 Bean 一定会注册」→ 正确：被 `@ConditionalOnMissingBean` 等条件控制，这也是自定义配置能覆盖默认配置的原因。

## 11. starter 机制与 SPI

**一句话答案**：starter 是「依赖聚合 + 自动配置」的约定，让引入一个依赖就开箱可用；底层封装的是 SPI 思想——框架定义扩展点，jar 提供实现清单。

**原理展开**：
- `spring-boot-starter-web` 这种官方 starter 本身几乎没代码，只是一个 pom 聚合依赖，真正干活的是 `spring-boot-autoconfigure` 里的自动配置类。
- 自定义 starter 标准做法是两个模块：`xxx-spring-boot-starter`（只管依赖）+ `xxx-spring-boot-autoconfigure`（`XxxProperties` + `XxxAutoConfiguration` + imports 清单文件）。
- `XxxProperties` 用 `@ConfigurationProperties(prefix = "xxx")` 接配置，配 `@EnableConfigurationProperties` 或 `@Component`。
- `XxxAutoConfiguration` 用 `@ConditionalOnClass`/`@ConditionalOnMissingBean` 控制生效，向容器注册核心 Bean。
- SPI 的原始形态是 Java 的 `ServiceLoader`：接口 + `META-INF/services/接口全限定名` 文件列出实现类；JDBC 驱动、SLF4J 绑定都是它。
- Spring 的 `spring.factories` 是 key-value 形式的 SPI，`AutoConfiguration.imports` 是它的精简替代；Dubbo 也有自己的 `META-INF/dubbo` SPI。
- 面试价值：能说出「starter 为什么开箱即用」＝ 理解了自动配置 + 条件装配。

**面试怎么答（60 秒版）**：starter 本质是一个依赖 + 一套自动配置的约定。我引一个 starter，它会把相关依赖都带进来，同时 jar 里有自动配置类清单，SpringBoot 启动时读取清单并按条件注册 Bean，所以开箱即用。要自己写一个 starter，一般是两个模块，一个只做依赖聚合，一个放 @ConfigurationProperties 配置类和自动配置类，再在 META-INF 下写清单文件。这个机制和 Java 的 SPI 是一个思路：框架定接口和清单路径，jar 提供实现，SLF4J 绑定日志实现就是这么做的。

**追问陷阱**：
- 错误：「starter 里写了启动类」→ 正确：starter 不含启动类，靠自动配置装配。
- 错误：自己写 starter 时忘记 `@ConditionalOnMissingBean` → 正确：用户无法覆盖默认 Bean，体验差。

## 12. 拦截器 vs 过滤器 vs AOP

**一句话答案**：Filter 在 Servlet 容器层、最先执行、能改 request/response；Interceptor 在 Spring MVC 内、能拿 Handler、适合登录鉴权；AOP 在方法层、能拿参数返回值，适合事务与埋点。

**原理展开**：
- Filter：Servlet 规范组件，`doFilter` 链，早于 `DispatcherServlet`；拿不到 Handler 但能在链路最外层做编码、CORS、XSS 过滤、traceId、请求日志。
- Interceptor：`HandlerInterceptor`，由 `InterceptorRegistry` 注册，能拿 `HandlerMethod`，三个回调点 `preHandle/postHandle/afterCompletion`；适合登录校验、权限、菜单，也常用于清理 ThreadLocal。
- AOP：方法级增强，能拿方法参数、返回值、异常，精确到「哪个类的哪个方法」；适合事务、操作日志、埋点。缺点是不能拦截未进容器的请求（静态资源也拦不到）。
- 执行顺序：Filter → Interceptor.preHandle → AOP（方法前后）→ Controller → AOP 返回 → Interceptor.postHandle → 视图 → afterCompletion → Filter 收尾。
- 选型口诀：处理 HTTP 报文用 Filter，需要知道「哪个 Controller」用 Interceptor，需要知道「哪个方法、参数、返回值」用 AOP。

**面试怎么答（60 秒版）**：三者作用层不同。Filter 是 Servlet 规范的，在 DispatcherServlet 之前执行，能拿到最原始的请求和响应，适合做编码、跨域、请求日志、traceId。Interceptor 是 Spring MVC 的，在 DispatcherServlet 内部、Controller 前后执行，能拿到具体的 Handler，所以登录校验、权限判断用它最合适。AOP 是方法级的，能拿到方法参数和返回值，只对 Spring Bean 的方法生效，事务和操作日志用它。执行顺序就是 Filter 先、然后拦截器、然后 AOP。

**追问陷阱**：
- 错误：「拦截器能拦静态资源」→ 正确：默认会被 `ResourceHttpRequestHandler` 处理，拦截器可配但 AOP 完全拦不到。
- 错误：用 AOP 做登录校验 → 正确：拿不到 request 上下文，用 Interceptor。

## 13. 全局异常处理

**一句话答案**：`@RestControllerAdvice` + `@ExceptionHandler` 统一拦截异常并转成标准响应；按异常类型精确匹配，最后用 `Exception` 兜底，绝不把堆栈返回给前端。

**原理展开**：
- `@RestControllerAdvice` = `@ControllerAdvice` + `@ResponseBody`，作用于所有 Controller（可用 `basePackages` 限定）。
- `@ExceptionHandler` 按异常类型匹配，Spring 会找最近父类的处理方法；越具体的类型优先级越高。
- 常见要处理的异常：自定义 `BizException`、参数校验失败（`MethodArgumentNotValidException`、`BindException`、`ConstraintViolationException`）、`HttpMessageNotReadableException`（JSON 解析失败）、`HttpRequestMethodNotSupportedException`（405）、兜底 `Exception`。
- 返回结构统一：`R<T>`（`code`/`message`/`data`/`traceId`），HTTP 状态码与业务码分离，前端只看业务码。
- 兜底处理里要 `log.error` 打全堆栈（带 traceId），但对外只返回「系统繁忙」。
- 不要用 try-catch 到处兜，异常统一往上抛给 Advice，业务代码只保留重试、降级这类真正需要处理的逻辑。

```java
@RestControllerAdvice
public class GlobalExceptionHandler {
    @ExceptionHandler(BizException.class)
    public R<Void> handleBiz(BizException e) {
        return R.fail(e.getCode(), e.getMessage());
    }
    @ExceptionHandler(MethodArgumentNotValidException.class)
    public R<Void> handleValid(MethodArgumentNotValidException e) {
        String msg = e.getBindingResult().getFieldErrors().stream()
                .map(FieldError::getDefaultMessage).collect(Collectors.joining("; "));
        return R.fail(400, msg);
    }
    @ExceptionHandler(Exception.class)
    public R<Void> handleOther(Exception e) {
        log.error("系统异常", e);
        return R.fail(500, "系统繁忙，请稍后重试");
    }
}
```

**面试怎么答（60 秒版）**：我项目里用 @RestControllerAdvice 加 @ExceptionHandler 做全局异常处理。自定义一个业务异常带错误码，业务代码里直接抛，Advice 里统一转成标准响应结构。参数校验失败单独处理，把字段错误信息拼起来返回。最后有一个 Exception 兜底，记完整堆栈日志但对外只返回「系统繁忙」，避免把堆栈和内部信息暴露出去。这样 Controller 里没有 try-catch，代码干净，前端也能拿到统一的错误格式。

**追问陷阱**：
- 错误：兜底把 `e.getMessage()` 直接返回 → 正确：可能暴露 SQL、内部类名，对外用固定文案 + traceId。
- 错误：在 `@ExceptionHandler` 里又抛异常 → 正确：会走容器默认错误页，等于没处理。

## 14. 参数校验

**一句话答案**：用 `@Valid`/`@Validated` + JSR-303 注解声明约束，对象参数加 `@Validated` 触发校验，失败抛异常由全局处理器统一转成友好提示。

**原理展开**：
- `@Valid`（JSR-303 标准，可嵌套）vs `@Validated`（Spring 提供，支持分组、可标注在类上）。
- 常用约束：`@NotNull`（不为 null）、`@NotBlank`（字符串非空且去空格非空）、`@NotEmpty`（集合/字符串非空）、`@Size`、`@Min/@Max`、`@Pattern`（正则）、`@Email`、`@DecimalMin`。
- 触发条件：`@RequestBody` 参数前加 `@Valid`；普通对象参数加 `@Validated`；方法参数直接写约束注解需类上 `@Validated`。
- 嵌套对象：内层字段要生效，外层字段必须加 `@Valid`；集合元素用 `List<@Valid Item>`。
- 分组校验：定义 `Create`/`Update` 接口，`@Validated(Create.class)` 只校验该组，避免「新增要 id 非空、修改不要」的冲突。
- 快速失败：`@Validated` 默认校验全部字段，可用 `failFast` 配置减少返回量。
- 校验 ≠ 业务校验：格式用注解，唯一性、库存这类必须查库的逻辑放 Service。

**面试怎么答（60 秒版）**：参数校验我用 JSR-303 的注解，对象接收的请求体在 @RequestBody 前加 @Valid，直接在方法参数写约束的话要在类上加 @Validated。常用 @NotNull、@NotBlank、@Size、@Pattern 这些。校验失败会抛 MethodArgumentNotValidException，我在全局异常处理器里统一取出字段错误拼成提示返回，前端可以直接展示。新增和修改字段要求不同时用分组校验。不过校验注解只管格式，像用户名唯一这种要查库的业务校验还是放 Service 里。

**追问陷阱**：
- 错误：「@Valid 和 @Validated 一样」→ 正确：`@Validated` 支持分组且可标在类上，`@Valid` 支持嵌套；两者容易混。
- 错误：嵌套对象不加 `@Valid` → 正确：内层约束静默不生效，是常见 bug。

## 15. RESTful 设计规范与统一响应分页

**一句话答案**：用名词复数表示资源、用 HTTP 方法表达动作、用状态码表达结果；响应统一为 `{code, message, data}`，分页统一为 `{list, total, pageNum, pageSize}`。

**原理展开**：
- URL 设计：资源用名词复数 `/api/v1/users`，层级不超过两层 `/users/{id}/orders`；动作交给方法（GET 查、POST 增、PUT 全量改、PATCH 局部改、DELETE 删）。
- 幂等性：GET/PUT/DELETE 幂等，POST 不幂等——这是设计接口时判断「能否重试」的依据。
- 状态码：200 成功、201 创建、204 无内容、400 参数错、401 未认证、403 无权限、404 不存在、409 冲突、429 限流、500 服务端错。
- 版本：URL 里带 `/v1`，简单直观，比 Header 版本更好排查。
- 统一响应：`code`（业务码）、`message`、`data`、`traceId`（链路追踪）；业务码不要和 HTTP 状态码混用。
- 分层：`Entity`（数据库）→ `DTO`（入参）→ `VO`（出参），绝不直接把 Entity 返回给前端（暴露敏感字段、多表关联循环引用、字段增减影响前端）。
- 分页：`Page<UserVO>` 返回 `list/total/pageNum/pageSize`；MyBatis-Plus 用 `Page` + `PaginationInnerInterceptor`，前端只传 `pageNum/pageSize`，服务端限制 `pageSize` 上限（如 100）防刷。

**面试怎么答（60 秒版）**：RESTful 的核心是「URL 表示资源、HTTP 方法表示动作」。资源用名词复数，比如 /api/v1/users，查询用 GET、新增用 POST、修改用 PUT 或 PATCH、删除用 DELETE，返回用状态码表达结果，成功 200、参数错 400、没权限 403、服务端错 500。响应体我统一成 code、message、data 加 traceId 的结构，前端只判断业务码。分页统一返回 list、total、页码和每页条数，服务端会限制 pageSize 上限防止被刷。

**追问陷阱**：
- 错误：「RESTful 就是 URL 里不要动词」→ 正确：核心是资源 + 标准方法 + 状态码 + 无状态，光去掉动词不算。
- 错误：所有错误都返回 200 + code → 正确：要区分 HTTP 状态码（网关、监控、重试策略都依赖它）。

## 16. 跨域配置

**一句话答案**：跨域是同源策略的限制，服务端要么在响应头加 `Access-Control-Allow-*`，要么用 Nginx/网关统一处理；Spring 里用 `@CrossOrigin` 或全局 `CorsFilter`。

**原理展开**：
- 同源 = 协议 + 域名 + 端口三者完全一致；前端 `localhost:5173` 调后端 `localhost:8080` 就是跨域。
- 简单请求直接发，非简单请求（PUT/DELETE、`Content-Type: application/json`、自定义头）先发 `OPTIONS` 预检。
- 服务端三种写法：`@CrossOrigin` 标在 Controller 上（单接口/类）；`WebMvcConfigurer#addCorsMappings`（全局）；`CorsFilter`（优先级最高，能覆盖拦截器返回的错误响应）。
- 关键坑：`allowCredentials(true)` 时 `allowedOrigins` 不能用 `*`，要写具体来源或改用 `allowedOriginPatterns`——否则浏览器拒绝。
- 生产建议：网关/Nginx 统一加 CORS 头，或前端走同域反向代理（Vite `server.proxy`、Nginx `location /api` 转发），从根上避免跨域。
- 顺带考点：跨域是**浏览器**的限制，用 Postman/服务端调不受影响。

**面试怎么答（60 秒版）**：跨域是浏览器的同源策略造成的，协议、域名、端口有一个不同就算跨域。解决思路是服务端返回 CORS 响应头，告诉浏览器允许哪些来源。Spring 里可以单个接口加 @CrossOrigin，或者配一个全局的 CorsFilter，Filter 优先级更高，能拦住拦截器返回的错误。如果要带 Cookie，allowCredentials 为 true 时 origin 不能写星号。生产上更常用的是 Nginx 反向代理或者网关统一处理，前端走同源路径，从根上就没有跨域问题。

**追问陷阱**：
- 错误：「跨域是服务端拒绝了请求」→ 正确：请求通常已发出并返回，是浏览器拦截了响应。
- 错误：`allowedOrigins("*")` + `allowCredentials(true)` → 正确：非法组合，浏览器会报错。

## 17. 日志与配置管理

**一句话答案**：日志用 SLF4J 门面 + Logback 实现，级别用 INFO、用占位符 `{}` 而非字符串拼接；配置用 `application-{profile}.yml` 分环境 + `@ConfigurationProperties` 批量绑定。

**原理展开**：
- 门面模式：代码只依赖 SLF4J API，底层可换 Logback/Log4j2，SpringBoot 默认 Logback。
- 级别从低到高 `TRACE < DEBUG < INFO < WARN < ERROR`，生产用 INFO，排查问题时临时开 DEBUG（或按包调整）。
- 占位符延迟求值：`log.debug("user={}", user)` 不拼字符串，DEBUG 关闭时零成本；异常对象放最后一个参数且后面不带 `{}`。
- 日志规范：ERROR 打异常堆栈、WARN 打可恢复异常、INFO 打关键业务节点（下单、支付），不要循环里打 INFO。
- 配置优先级（高 → 低）：命令行参数 > `SPRING_APPLICATION_JSON` > 环境变量 > `application-{profile}.yml` > `application.yml`。
- `@ConfigurationProperties(prefix = "app")` 批量绑定到对象（带类型校验、IDE 提示），字段多时优于一堆 `@Value`。
- 敏感配置（数据库密码、密钥）用 Jasypt 加密或配置中心（Nacos）管理，别明文进 Git；日志打印要脱敏。

**面试怎么答（60 秒版）**：日志我统一用 SLF4J 的 API，底层是 SpringBoot 默认的 Logback，这样以后换实现不用改代码。级别线上用 INFO，异常用 ERROR 并带上堆栈，打印变量用占位符而不是字符串拼接，避免不必要的开销。配置方面用 application.yml 加多环境 profile 文件，敏感信息走环境变量或配置中心。配置项多的时候用 @ConfigurationProperties 绑定成一个对象，比到处写 @Value 好维护，也有类型校验。

**追问陷阱**：
- 错误：`log.error("失败" + e.getMessage())` → 正确：丢掉堆栈；正确是 `log.error("失败 orderId={}", id, e)`。
- 错误：把 `@Value` 用在大量配置上 → 正确：可维护性差，用 `@ConfigurationProperties`。

## 18. MyBatis 与 MyBatis-Plus 基础

**一句话答案**：MyBatis 是半自动 ORM，SQL 写在 XML/注解里、结果靠 `resultMap` 映射；MyBatis-Plus 在其上提供 BaseMapper 通用 CRUD、Lambda 条件构造器、分页插件、逻辑删除与自动填充。

**原理展开**：
- MyBatis 核心：`SqlSessionFactory` 解析配置 → `SqlSession` 执行 → `Executor` 处理缓存 → `StatementHandler` 执行 SQL → `ResultSetHandler` 映射结果。
- `#{}` 是预编译占位符（`PreparedStatement` 的 `?`，防 SQL 注入），`${}` 是字符串拼接（只用于动态表名、排序字段，且必须白名单校验）。
- `resultMap` 处理字段与属性不一致；开 `mapUnderscoreToCamelCase` 可自动把 `user_name` 映射到 `userName`。
- 缓存：一级缓存是 `SqlSession` 级（默认开，同一会话重复查询走缓存）；二级缓存是 namespace 级（默认关，多表关联更新易脏，生产慎用）。
- 动态 SQL：`<if>`、`<where>`、`<foreach>`、`<choose>`；批量插入用 `<foreach>` 拼 `values`。
- MyBatis-Plus：`BaseMapper<T>` 提供 CRUD、`IService/ServiceImpl` 提供批量与链式操作、`LambdaQueryWrapper` 用方法引用避免硬编码字段、`PaginationInnerInterceptor` 分页、`@TableLogic` 逻辑删除、`@TableField(fill = FieldFill.INSERT)` 自动填充时间/操作人、`@Version` 乐观锁。
- 性能注意：避免 `select *`、避免 N+1（循环里查单条改成批量 `in`）、大结果集用流式或分页。

**面试怎么答（60 秒版）**：MyBatis 是半自动 ORM，SQL 由我们自己写，它负责参数绑定和结果映射。核心是 SqlSessionFactory 创建 SqlSession，执行时经过 Executor、StatementHandler，最后 ResultSetHandler 把结果映射成对象。SQL 里一律用 #{}，因为它是预编译的能防注入，${} 是字符串拼接，只在动态表名排序这类场景用而且要做白名单。MyBatis-Plus 是在它上面封装了通用 CRUD 和 Lambda 条件构造器，还有分页插件、逻辑删除和自动填充，日常增删改查基本不用写 SQL。

**追问陷阱**：
- 错误：用 `${}` 传用户输入 → 正确：SQL 注入，必须 `#{}`。
- 错误：以为二级缓存能提升性能就无脑开 → 正确：跨 namespace 更新会脏读，生产一般不开。

## 19. 接口幂等与限流入门

**一句话答案**：幂等靠「唯一索引兜底 + token/乐观锁/状态机前置防重」；限流靠「单机令牌桶 + 分布式 Redis+Lua 或 Sentinel」，答题要能说出场景和取舍。

**原理展开**：
- 幂等场景：下单、支付回调、MQ 重复消费、用户连点提交。
- 方案分层：①**数据库唯一索引**是最后一道防线（防并发）；② **token 机制**——先申请 token 存 Redis，提交时 `DEL` 成功才处理（原子性保证只成功一次）；③ **乐观锁版本号**适合更新类；④ **状态机**只允许「待支付 → 已支付」这类合法流转；⑤ 分布式锁适合强一致但重量的场景。
- 关键：先查后插在并发下必然失效，必须依赖唯一索引或 Redis 原子操作。
- 限流算法：固定窗口（简单但有临界突刺）、滑动窗口（精确、内存稍大）、漏桶（恒定速率、削峰）、令牌桶（允许突发，Guava `RateLimiter` 是单机令牌桶）。
- 分布式限流：Redis + Lua 脚本保证「读计数 + 自增 + 设过期」原子；Sentinel 提供 QPS/线程数限流、熔断降级、热点参数限流，生产更常用。
- 网关层：Nginx `limit_req`、Spring Cloud Gateway 的 `RequestRateLimiter`（基于 Redis），把限流挡在业务之前。
- 答题结构：先说什么场景会重复 → 再说唯一索引兜底 → 再说前置的 token/状态机 → 最后提限流保护下游。

**面试怎么答（60 秒版）**：幂等我会分两层讲。数据库层用唯一索引兜底，这是并发下唯一可靠的保证。业务层用 token 机制，提交前先拿一个 token 存 Redis，真正处理时用 DEL 判断是不是第一次，DEL 返回 1 才继续，这样并发只会成功一次；更新类用乐观锁版本号，或者用状态机限制只有特定状态才能流转。限流的话单机用 Guava 的令牌桶，分布式用 Redis 加 Lua 做计数或者上 Sentinel，网关层也可以配。核心思路是：幂等防重复，限流防打崩。

**追问陷阱**：
- 错误：「先 select 再 insert 判重」→ 正确：并发下两个请求都能查到不存在，必须唯一索引或原子操作。
- 错误：把限流和幂等混为一谈 → 正确：幂等是「重复请求结果一致」，限流是「控制请求速率」，两个维度。

### 加分项：深挖到此 · BeanFactoryPostProcessor 与 BeanPostProcessor

- `BeanFactoryPostProcessor`：在**所有 Bean 实例化之前**执行，能改 `BeanDefinition`（比如把某个类的属性改掉、动态注册 Bean）；`ConfigurationClassPostProcessor` 就是它，负责解析 `@Configuration`/`@ComponentScan`/`@Bean`。
- `BeanPostProcessor`：在**每个 Bean 初始化前后**执行，能改 Bean 实例本身；AOP 就是 `AbstractAutoProxyCreator`（一个 BPP）在 `postProcessAfterInitialization` 里生成代理。
- 顺带考点：`@Autowired` 的注入由 `AutowiredAnnotationBeanPostProcessor` 完成，`@PostConstruct` 由 `CommonAnnotationBeanPostProcessor` 完成——都能说出「注解靠后置处理器生效」就是理解了 Spring 扩展点。

### 加分项：深挖到此 · 内嵌 Tomcat 与自动配置的衔接

- SpringBoot 启动时 `SpringApplication.run` 最终 `refreshContext`，`ServletWebServerApplicationContext` 在 `onRefresh` 阶段调用 `ServletWebServerFactory`（默认 `TomcatServletWebServerFactory`）的 `getWebServer` 创建并启动内嵌 Tomcat，所以「jar 包能直接跑」。
- `DispatcherServlet` 不是自动配置里 `new` 的，而是通过 `ServletContextInitializer`（`DispatcherServletRegistrationBean`）注册到 Tomcat 的 ServletContext 上。
- 这也解释了「为什么改了端口只要改 `server.port`」——`ServletWebServerFactoryCustomizer` 读 `ServerProperties` 调 `setPort`。
- 面试可延伸：「SpringBoot 打成的 jar 为什么能 `java -jar` 直接跑」→ 可执行 jar 的 `MANIFEST.MF` 里 `Main-Class` 是 `JarLauncher`，`Start-Class` 才是业务启动类，`LaunchedURLClassLoader` 加载 `BOOT-INF/classes` 与 `BOOT-INF/lib`。

## 高频题库

| 题号 | 题目 | 考点 | 答案要点 |
| --- | --- | --- | --- |
| 1 | Spring 的 IoC 和 DI 是什么？ | 核心思想 | IoC 是把对象创建与依赖管理的控制权交给容器，DI 是注入实现方式；三种注入中构造器最推荐 |
| 2 | BeanFactory 与 ApplicationContext 区别？ | 容器 | 后者继承前者，多了事件、国际化、资源加载、AOP；前者懒加载，后者启动即实例化单例 |
| 3 | Bean 生命周期？ | 容器 | 实例化 → 属性填充 → Aware → BPP 前置 → 初始化三件套 → BPP 后置（生成代理）→ 使用 → 销毁 |
| 4 | 单例 Bean 注入 prototype 会怎样？ | 作用域 | 只注入一次，永远是同一个实例；用 ObjectProvider、@Lookup 或 scoped proxy 解决 |
| 5 | Spring 如何解决循环依赖？ | 三级缓存 | 单例 + setter 注入靠三级缓存提前暴露早期引用；三级是为了延迟生成 AOP 代理；构造器注入无解 |
| 6 | AOP 的底层实现？ | 动态代理 | JDK 动态代理（接口）+ CGLIB（继承子类）；SpringBoot 2.x 默认 CGLIB；final/private 不可代理 |
| 7 | @Transactional 的原理？ | 事务 | AOP 代理 + 事务管理器，连接绑定 ThreadLocal，同线程共用连接才能一起回滚 |
| 8 | 七种事务传播行为？ | 事务 | REQUIRED 默认加入、REQUIRES_NEW 挂起新建、NESTED 用 savepoint、SUPPORTS、NOT_SUPPORTED、MANDATORY、NEVER |
| 9 | @Transactional 什么时候失效？ | 必考 | 非 public、同类 this 调用、异常被吞、受检异常未配 rollbackFor、非 Spring 管理、引擎不支持、多线程、传播设置不当 |
| 10 | 为什么默认只回滚 RuntimeException？ | 事务 | 受检异常通常可预期，显式配 `rollbackFor = Exception.class` 豁免该限制 |
| 11 | Spring MVC 请求处理流程？ | MVC | DispatcherServlet → HandlerMapping → HandlerAdapter → 参数解析 → Controller → 返回值/消息转换 → 视图 → 拦截器回调 |
| 12 | @SpringBootApplication 是哪三个注解？ | 自动配置 | @SpringBootConfiguration、@EnableAutoConfiguration、@ComponentScan |
| 13 | 自动配置原理？ | 自动配置 | @EnableAutoConfiguration 导入选择器，读 imports 清单（旧版 spring.factories），按 @Conditional 条件注册 Bean |
| 14 | 拦截器与过滤器区别？ | Web | Filter 在容器层先执行、能改请求响应；Interceptor 在 MVC 内、能拿 Handler，适合鉴权 |
| 15 | @Valid 与 @Validated 区别？ | 校验 | @Validated 支持分组、可标类上；@Valid 支持嵌套；嵌套字段外层必须加 @Valid |
| 16 | #{} 与 ${} 的区别？ | MyBatis | 前者预编译防注入，后者字符串拼接；动态表名才用 ${} 并做白名单 |
| 17 | 接口幂等怎么做？ | 工程 | 唯一索引兜底 + token 防重 + 乐观锁/状态机 + 分布式锁；先查后插在并发下不可靠 |
| 18 | 限流算法有哪些？ | 工程 | 固定窗口、滑动窗口、漏桶、令牌桶；单机 Guava、分布式 Redis+Lua、Sentinel |

> 本章的数据库细节在 [MySQL 与 Redis](../04-database/MySQL与Redis.md)，项目怎么讲见 [项目复盘与简历](../08-project/项目复盘与简历.md)，被问到系统设计时接 [系统设计入门](../06-system-design/系统设计入门.md)。
