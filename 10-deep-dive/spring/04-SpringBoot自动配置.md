# SpringBoot 自动配置

> 面试权重：4/5　｜　追问深度：**L5（`AutoConfigurationImportSelector` / 条件装配 / `AutoConfiguration.imports` / 内嵌 Tomcat 启动）**
> 一句话定位：`@EnableAutoConfiguration` 通过 `@Import(AutoConfigurationImportSelector)` 把 classpath 里所有候选配置类读出来，再用 `@Conditional` 家族按「类在不在、属性开没开、Bean 有没有」筛一遍，剩下的注册成 `BeanDefinition`——**「约定优于配置」的全部实现就是一份清单 + 一堆条件。**

[返回深度追问索引](../00-索引.md)

## L1 一句话答案（10 秒能说出口）

`@SpringBootApplication` = `@SpringBootConfiguration` + `@EnableAutoConfiguration` + `@ComponentScan`；`@EnableAutoConfiguration` 用 `@Import(AutoConfigurationImportSelector)` 去 classpath 读 `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`（2.7 之前是 `spring.factories`），拿到几百个候选自动配置类，再用 `@ConditionalOnClass` / `@ConditionalOnMissingBean` / `@ConditionalOnProperty` 等条件过滤，最终把命中的配置类注册成 Bean；`SpringApplication.run` 则负责准备 `Environment`、创建容器，并在 `onRefresh` 时启动内嵌 Tomcat。

## L2 原理层：三注解拆解 + 条件装配

```java
@SpringBootApplication
├── @SpringBootConfiguration   // 本质是 @Configuration，标记配置类
├── @EnableAutoConfiguration   // 开启自动配置
│     ├── @AutoConfigurationPackage   // 记录主类包名 → AutoConfigurationPackages，供 @EntityScan/MyBatis 用
│     └── @Import(AutoConfigurationImportSelector.class)
└── @ComponentScan             // 扫描当前包及子包
```

| 扩展点接口 | 差别 | 用途 |
|---|---|---|
| `ImportSelector` | 返回要导入的**类全名数组** | 轻量，按条件返回配置类 |
| `DeferredImportSelector` | **延迟**到所有 `@Configuration` 解析完再执行 | 自动配置必须延迟，否则用户配置还没注册就判断 `@ConditionalOnMissingBean` 会错 |
| `ImportBeanDefinitionRegistrar` | 直接**注册 BeanDefinition** | 需要拿到 `BeanDefinitionRegistry` 精确控制（如 `@MapperScan`） |

**`AutoConfigurationImportSelector` 的关键流程**：

```
getAutoConfigurationEntry(metadata)
 ├─ getCandidateConfigurations：ImportCandidates.load(AutoConfiguration.class) 
 │     └─ 读 META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports
 │        （Boot 2.7 之前：SpringFactoriesLoader.loadFactoryNames(EnableAutoConfiguration.class,
 │          从 META-INF/spring.factories 读）
 ├─ removeDuplicates + getExclusions（@SpringBootApplication(exclude=...) / spring.autoconfigure.exclude）
 ├─ fireAutoConfigurationImportEvents（AutoConfigurationImportListener）
 └─ filter：交给 AutoConfigurationImportFilter（OnClassCondition / OnBeanCondition /
            OnWebApplicationCondition）做「快速失败」过滤，避免加载不存在的类
```

**版本演进（必背）**：

| 版本 | 自动配置清单位置 | 说明 |
|---|---|---|
| 1.x ~ 2.6 | `META-INF/spring.factories` 的 `org.springframework.boot.autoconfigure.EnableAutoConfiguration` 键 | 一次读全量，再逐个条件判断，启动慢 |
| 2.7+ | `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports` | 每行一个类名；同时引入 `@AutoConfiguration` 注解 |
| 3.x | 只认 `AutoConfiguration.imports` | `spring.factories` 里的自动配置键**不再生效**（但其他 SPI 扩展点仍用它） |

> 注意区分：`spring.factories` **没有消失**，它仍是 `ApplicationContextInitializer`、`EnvironmentPostProcessor`、`ApplicationListener` 等扩展点的注册方式；只是**自动配置**改用了新文件。

**`@Conditional` 家族**：

| 注解 | 判断 | 典型用法 |
|---|---|---|
| `@ConditionalOnClass` / `OnMissingClass` | classpath 是否有某类 | `@ConditionalOnClass(DataSource.class)` |
| `@ConditionalOnMissingBean` | 容器里**没有**某 Bean 才生效 | 让用户自定义 Bean 覆盖默认配置 |
| `@ConditionalOnBean` / `OnSingleCandidate` | 容器里有某 Bean | 依赖其他自动配置的产物 |
| `@ConditionalOnProperty` | 配置项值匹配 | `havingValue="true"`, `matchIfMissing=true` |
| `@ConditionalOnWebApplication(type=SERVLET)` | 是否 Web 应用 | 只在 Servlet 环境装配 MVC |
| `@ConditionalOnResource` | 资源文件存在 | 有 `logback-spring.xml` 才装配 |
| `@ConditionalOnExpression` | SpEL 表达式 | 复杂组合条件 |
| `@ConditionalOnJava` | JDK 版本 | 兼容不同 JDK 能力 |

**`@ConfigurationProperties` 绑定**：`@EnableConfigurationProperties(XxxProperties.class)` 把 Properties 类注册成 Bean，再由 `ConfigurationPropertiesBindingPostProcessor`（一个 `BeanPostProcessor`）用 `Binder` 把 `Environment` 里的配置按 **relaxed binding**（`my-app.max-size` / `myApp.maxSize` / `MY_APP_MAX_SIZE` 都能绑到 `maxSize`）注入。

## L3 底层层：`SpringApplication.run` 与内嵌 Tomcat

```java
public ConfigurableApplicationContext run(String... args) {
    // 1. 启动监听器：listeners.starting()
    // 2. prepareEnvironment：new Environment → ConfigDataEnvironmentPostProcessor 加载 application.yml
    //    → 激活 profile（application-dev.yml）→ 发布 ApplicationEnvironmentPreparedEvent
    // 3. createApplicationContext：Servlet 环境 → AnnotationConfigServletWebServerApplicationContext
    // 4. prepareContext：注册主类 BeanDefinition、应用 Initializer、发布 ContextPrepared/ContextLoaded
    // 5. refreshContext → AbstractApplicationContext.refresh()
    //    ⑨ onRefresh() → createWebServer() → 重点：启动内嵌 Tomcat
    //    ⑪ finishBeanFactoryInitialization → 实例化所有单例
    // 6. afterRefresh → listeners.started（ApplicationStartedEvent）
    // 7. callRunners（ApplicationRunner / CommandLineRunner）→ listeners.running（ApplicationReadyEvent）
}
```

**内嵌 Tomcat 启动（`ServletWebServerApplicationContext`）**：

```
refresh() 第 ⑨ 步 onRefresh()
 └─ createWebServer()
     ├─ 找 ServletWebServerFactory Bean（默认 TomcatServletWebServerFactory，由 ServletWebServerFactoryAutoConfiguration 提供）
     └─ factory.getWebServer(servletContextInitializers)
         └─ new Tomcat() → 设置端口（server.port）→ TomcatWebServer.initialize() → tomcat.start()
             └─ 此时才真正 bind 端口、启动 acceptor/poller 线程
DispatcherServlet 的注册：DispatcherServletAutoConfiguration 提供 DispatcherServletRegistrationBean
 → 作为 ServletContextInitializer 回调，在 Tomcat 启动过程中被调用 → addServlet 到 ServletContext
```

所以顺序是：**容器 refresh → onRefresh 建 Tomcat（绑端口）→ 继续实例化单例 → finishRefresh**。这也是为什么「端口已监听但 Bean 还没初始化完」是有可能的现象（自定义 `ServletContextInitializer` 里阻塞就能观察到）。

## L4 追问树（面试官一路往下问，你能撑到第几层？）

> 规则：从上往下问。**第 1-3 层是应届生必备，第 4-6 层是拉开差距，第 7 层以后是"能答出来就是加分"。**

### 第 1 层｜`@SpringBootApplication` 由哪些注解组成？
**答**：`@SpringBootConfiguration`（本质 `@Configuration`）+ `@EnableAutoConfiguration` + `@ComponentScan`。`@EnableAutoConfiguration` 里又有 `@AutoConfigurationPackage` + `@Import(AutoConfigurationImportSelector)`。

### 第 2 层｜自动配置的原理？
**答**：`AutoConfigurationImportSelector`（`DeferredImportSelector`）读自动配置清单文件拿到候选配置类全名，经过去重、排除、条件过滤，返回给容器注册成 `BeanDefinition`；配置类内部的 `@Bean` 方法在实例化阶段产出 Bean。

### 第 3 层｜为什么它要 `DeferredImportSelector`？
**答**：必须等用户自己的 `@Configuration`（包括 `@ComponentScan` 扫到的）先注册完，自动配置里的 `@ConditionalOnMissingBean` 才能正确判断「用户有没有自定义」。非延迟的 `ImportSelector` 会在普通配置类之前执行，优先级就反了。

### 第 4 层｜`spring.factories` 和 `AutoConfiguration.imports` 有什么区别？
**答**：2.6 及以前用 `META-INF/spring.factories` 的 `EnableAutoConfiguration` 键，一次加载全量候选；2.7 起改用 `META-INF/spring/...AutoConfiguration.imports`（一行一个类名），并引入 `@AutoConfiguration` 注解；3.x 只认新文件。注意 `spring.factories` 仍用于其他 SPI（Initializer、EnvironmentPostProcessor、Listener）。

### 第 5 层｜`@Conditional` 家族怎么工作？为什么条件判断不会报 `NoClassDefFoundError`？
**答**：条件实现 `Condition.matches()`，由 `ConditionEvaluator` 评估。自动配置会先把候选交给 `AutoConfigurationImportFilter`（`OnClassCondition` 等）做**元数据级快速过滤**——读 `.class` 的注解元数据而不是真正加载类，所以 classpath 上没有 `DataSource` 也不会炸。

### 第 6 层｜`@ConditionalOnMissingBean` 怎么做到「用户 Bean 优先」？
**答**：自动配置类延迟到用户配置解析完之后才执行，此时容器里已有用户注册的 `BeanDefinition`；条件判断发现同类型 Bean 已存在就跳过默认配置。所以自定义只需要自己声明一个同类型 `@Bean`，不需要排除自动配置。

### 第 7 层｜`@ConfigurationProperties` 怎么绑定？什么是 relaxed binding？
**答**：`@EnableConfigurationProperties` 把 Properties 类注册成 Bean，`ConfigurationPropertiesBindingPostProcessor`（`BeanPostProcessor`）在初始化前用 `Binder` 从 `Environment` 取值注入。relaxed binding 指多种写法等价：`my-app.max-size`、`myApp.maxSize`、`MY_APP_MAX_SIZE` 都映射到 `maxSize`，方便环境变量覆盖。

### 第 8 层｜自定义 starter 要写什么？
**答**：两个模块：`xxx-spring-boot-autoconfigure`（`@AutoConfiguration` 配置类 + `@ConditionalOnClass`/`@ConditionalOnMissingBean` + `XxxProperties`）和 `xxx-spring-boot-starter`（只放依赖，聚合）。资源文件 `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports` 里写上配置类全名，别的项目引入 starter 即生效。

### 第 9 层｜内嵌 Tomcat 什么时候启动？DispatcherServlet 什么时候注册？
**答**：`refresh()` 第 ⑨ 步 `onRefresh` → `createWebServer` → `TomcatServletWebServerFactory.getWebServer` → `TomcatWebServer.initialize()` 里 `tomcat.start()` 绑定端口；`DispatcherServlet` 通过 `DispatcherServletRegistrationBean`（`ServletContextInitializer`）在 Tomcat 启动过程中注册到 `ServletContext`。

### 第 10 层｜自动配置之间怎么排序？怎么排除某个自动配置？
**答**：`@AutoConfigureBefore`/`@AutoConfigureAfter`/`@AutoConfigureOrder`，最终由 `AutoConfigurationSorter` 做拓扑排序（无法确定时按类名字母序）。排除：`@SpringBootApplication(exclude = XxxAutoConfiguration.class)` 或配置 `spring.autoconfigure.exclude`。

### 第 11 层｜`application.yml` 是怎么被加载的？profile 怎么生效？
**答**：`prepareEnvironment` 阶段 `ConfigDataEnvironmentPostProcessor`（Spring Boot 2.4+ 的 ConfigData API）按「`application` + 激活的 profile」加载，优先级从高到低：命令行参数 > 环境变量 > `application-{profile}.yml` > `application.yml`；`spring.profiles.active` 可在配置文件/命令行/环境变量里指定。

### 第 12 层（终局）｜从 `main` 到端口可访问，完整流程是什么？
**答**：`main` → `SpringApplication.run` → 推断应用类型 → 创建 `Environment`（加载 yml/profile）→ 创建 `AnnotationConfigServletWebServerApplicationContext` → `prepareContext` 注册主类 → `refresh()`：`BeanFactoryPostProcessor`（解析 `@Configuration`/自动配置）→ 注册 `BeanPostProcessor` → `onRefresh` 创建并启动 Tomcat（**绑定端口**）→ 实例化所有单例（Tomcat 相关 Bean 就绪）→ `finishRefresh` 发布 `ContextRefreshedEvent` → `ApplicationStartedEvent` → 执行 `Runner` → `ApplicationReadyEvent`，此时对外可服务。

## L5 名词拆解表（"每个名词都拆开"）

| 名词 | 是什么 | 为什么存在 | 面试追问点 |
|---|---|---|---|
| `@SpringBootApplication` | 三合一复合注解 | 一个注解完成配置 + 扫描 + 自动配置 | 三个子注解各是什么 |
| `@EnableAutoConfiguration` | 开启自动配置 | 显式引入 `ImportSelector` | `@AutoConfigurationPackage` 的作用 |
| `AutoConfigurationImportSelector` | 读清单 + 过滤 + 返回配置类 | 把「约定」变成可执行的装配 | 为什么是 `DeferredImportSelector` |
| `DeferredImportSelector` | 延迟执行的 ImportSelector | 等用户配置先注册 | 与 `ImportSelector`/`Registrar` 区别 |
| `AutoConfiguration.imports` | 2.7+ 的自动配置清单文件 | 避免全量加载、提升启动速度 | 与 `spring.factories` 的版本差异 |
| `spring.factories` | SPI 注册文件 | 早期唯一的扩展点注册方式 | 现在还剩哪些用途 |
| `@Conditional` | 条件装配元注解 | 按环境决定装不装配 | 家族成员、评估顺序 |
| `AutoConfigurationImportFilter` | 元数据级快速过滤器 | 避免类不存在时加载失败、加速启动 | `OnClassCondition` 原理 |
| `@ConditionalOnMissingBean` | 没有同类型 Bean 才生效 | 实现「用户覆盖默认」 | 与自动配置延迟执行的配合 |
| `@AutoConfiguration` | 2.7+ 的配置类注解 | 表达「这是自动配置」并加约束 | 与 `@Configuration` 区别、排序注解 |
| `@ConfigurationProperties` | 类型安全的配置绑定 | 替代散落的 `@Value` | relaxed binding、校验 `@Validated` |
| `Environment` | 配置与 profile 的抽象 | 统一读取配置来源 | 优先级、`ConfigData` API |
| `ServletWebServerApplicationContext` | Servlet Web 容器上下文 | 管理内嵌 Web 服务器生命周期 | `onRefresh` 建 Tomcat |
| `ServletWebServerFactory` | Web 服务器工厂接口 | 屏蔽 Tomcat/Jetty/Undertow | `TomcatServletWebServerFactory` |

## 代码验证（JDK 单文件可跑：模拟「清单 + 条件过滤」的自动配置）

```java
// 保存为 MiniBoot.java：javac MiniBoot.java && java MiniBoot
import java.util.*;
import java.util.stream.*;

public class MiniBoot {
    interface Condition { boolean matches(Map<String, String> env, Set<String> classpath); }
    record AutoConfig(String name, Condition when) { }

    // 模拟 AutoConfiguration.imports 里的候选（顺序即文件顺序，真实场景会拓扑排序）
    static final List<AutoConfig> CANDIDATES = List.of(
        new AutoConfig("DataSourceAutoConfiguration",
                (env, cp) -> cp.contains("javax.sql.DataSource")),
        new AutoConfig("RedisAutoConfiguration",
                (env, cp) -> cp.contains("redis.clients.jedis.Jedis")),
        new AutoConfig("WebMvcAutoConfiguration",
                (env, cp) -> "true".equals(env.getOrDefault("web.enabled", "true"))));

    public static void main(String[] args) {
        Map<String, String> env = Map.of("web.enabled", "false");      // 模拟 application.yml
        Set<String> classpath = Set.of("javax.sql.DataSource");         // 模拟引入了 JDBC 依赖
        Set<String> alreadyDefinedBeans = Set.of();                     // 模拟用户自定义 Bean

        List<String> matched = CANDIDATES.stream()
                .filter(c -> c.when().matches(env, classpath))
                .map(AutoConfig::name)
                .filter(n -> !alreadyDefinedBeans.contains(n))          // 近似 @ConditionalOnMissingBean
                .collect(Collectors.toList());

        System.out.println("classpath=" + classpath + " env=" + env);
        System.out.println("命中的自动配置=" + matched);
        // 输出：[DataSourceAutoConfiguration] —— 没引 Redis、web 已关闭、用户没覆盖
    }
}
```

## 高频错误（面试官最爱抓的）

| 错误说法 | 正确说法 |
|---|---|
| 「`@SpringBootApplication` 只是 `@Configuration` 的别名」 | 它是三个注解的复合，含自动配置与包扫描 |
| 「自动配置是靠反射扫描所有 jar 的类」 | 读的是清单文件，不扫全盘 |
| 「`spring.factories` 在 Boot 3 完全没用了」 | 自动配置键不用了，其他 SPI 仍用 |
| 「`@ConditionalOnMissingBean` 可以随便加在普通配置类上」 | 它依赖「延迟执行 + 已注册定义」，普通配置类里语义不可靠 |
| 「Boot 默认内嵌 Tomcat 不需要写 servlet 容器配置」 | 需要 `spring-boot-starter-web`，且 `server.port` 等由 `ServerProperties` 绑定 |
| 「自动配置用 `@Import` 直接导入配置类」 | 用 `ImportSelector` 动态返回，且必须延迟 |
| 「`@EnableAutoConfiguration` 能扫到用户 `@Component`」 | 扫包是 `@ComponentScan` 的职责，两者独立 |
| 「排除自动配置只能靠 `exclude` 注解属性」 | 还可以 `spring.autoconfigure.exclude` 配置项 |

## 关联文件

- 上一层（Spring 八股）：[SpringBoot与后端工程](../../03-java/SpringBoot与后端工程.md)（Boot 启动与自动配置）
- 同层追问：[IoC 与 Bean 生命周期](./01-IoC与Bean生命周期.md)（`refresh()` 第 ⑨⑪ 步）｜[AOP 与动态代理](./02-AOP与动态代理.md)｜[事务传播与失效](./03-事务传播与失效.md)
- 典型场景：AI Agent 基础设施里自研 `agent-spring-boot-starter`，用 `@AutoConfiguration` + `@ConditionalOnProperty` 让「是否启用远程工具执行器」可配置——正好是本节内容的落地
- 速查：[深度追问索引](../00-索引.md)

## 自测标准

- 能拆开 `@SpringBootApplication` 的三个注解，并说清 `@EnableAutoConfiguration` 内部
- 能讲清 `AutoConfigurationImportSelector` 的「读清单 → 去重排除 → 条件过滤 → 注册」四步
- 能说出 2.7 / 3.x 的清单文件变化，以及 `spring.factories` 剩余的用途
- 能背 `@Conditional` 家族 ≥6 个成员并说明 `@ConditionalOnMissingBean` 的生效前提
- 能画出内嵌 Tomcat 启动与 `DispatcherServlet` 注册的时序
- L4 讲到第 6 层（`@ConditionalOnMissingBean`）→ 及格；讲到第 12 层（main 到端口可访问）→ 优秀
