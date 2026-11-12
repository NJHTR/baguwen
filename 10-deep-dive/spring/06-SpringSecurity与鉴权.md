# Spring Security 与鉴权

> 面试权重：4/5　｜　追问深度：**L5（`FilterChainProxy` 过滤器链 / `ProviderManager` 认证 / 投票器 / `SecurityContextHolder` 的 ThreadLocal）**
> 一句话定位：Spring Security 是一条**排在 DispatcherServlet 前面的 Servlet 过滤器链**：前面的过滤器负责建立 `SecurityContext`（谁在请求），后面的 `AuthorizationFilter` 负责判断「这个人能不能访问这个 URL」，而 `@PreAuthorize` 则是把同样的判断做成 AOP 切面塞进方法里。

[返回深度追问索引](../00-索引.md)

## L1 一句话答案（10 秒能说出口）

Servlet 容器只注册了一个 `springSecurityFilterChain`（`DelegatingFilterProxy`），它转到 `FilterChainProxy`，由 `FilterChainProxy` 按 `RequestMatcher` 选出一条 `SecurityFilterChain` 并依次执行约 15 个过滤器：认证类过滤器把 `Authentication` 放进 `SecurityContextHolder`（`ThreadLocal`），授权过滤器（6.x 的 `AuthorizationFilter`）再拿它做决策；认证靠 `ProviderManager` 委托给 `UserDetailsService` + `PasswordEncoder`，方法级鉴权靠 `@PreAuthorize` 生成的 AOP 拦截器。

## L2 原理层：过滤器链 + 认证 + 授权

```java
// 注册入口：只有一个 Filter，剩下全部由 Spring Security 内部编排
@Bean
public FilterRegistrationBean<DelegatingFilterProxy> springSecurityFilterChain() {
    // DelegatingFilterProxy 从 WebApplicationContext 取 beanName="springSecurityFilterChain"
    // 即 FilterChainProxy，再由它分发到各 SecurityFilterChain
}
```

| 序号 | 过滤器（6.x） | 作用 |
|---|---|---|
| 1 | `DisableEncodeUrlFilter` | 禁止 URL 重写携带 session id |
| 2 | `WebAsyncManagerIntegrationFilter` | 把 `SecurityContext` 传播到 `Callable` 异步线程 |
| 3 | `SecurityContextHolderFilter` | 从 `SecurityContextRepository` 载入 context（5.x 为 `SecurityContextPersistenceFilter`） |
| 4 | `HeaderWriterFilter` | 写安全响应头（X-Frame-Options 等） |
| 5 | `CorsFilter` | 跨域预检 |
| 6 | `CsrfFilter` | CSRF token 校验 |
| 7 | `LogoutFilter` | 处理登出 URL |
| 8 | `UsernamePasswordAuthenticationFilter` | 表单登录：取用户名密码做认证 |
| 9 | `DefaultLoginPageGeneratingFilter` | 生成默认登录页 |
| 10 | `BasicAuthenticationFilter` | HTTP Basic 认证 |
| 11 | `RequestCacheAwareFilter` | 认证成功后跳回原请求 |
| 12 | `SecurityContextHolderAwareRequestFilter` | 包装 request，支持 `isUserInRole` 等 |
| 13 | `AnonymousAuthenticationFilter` | 没有认证信息时放入匿名 `Authentication` |
| 14 | `SessionManagementFilter` | 会话并发/固定会话防护（版本相关） |
| 15 | `ExceptionTranslationFilter` | 把认证/授权异常转成 401/403 或跳登录页 |
| 16 | `AuthorizationFilter` | 最终授权判断（5.x 为 `FilterSecurityInterceptor`） |

**认证链路**：

```
UsernamePasswordAuthenticationFilter (AbstractAuthenticationProcessingFilter)
 -> 构造 UsernamePasswordAuthenticationToken(未认证)
 -> AuthenticationManager = ProviderManager
     -> 遍历 List<AuthenticationProvider>，找 supports(Class) 为真的
     -> DaoAuthenticationProvider：UserDetailsService.loadUserByUsername -> PasswordEncoder.matches
     -> 成功 createSuccessAuthentication 返回已认证 Authentication
 -> SecurityContextHolder.getContext().setAuthentication(auth)
 -> SecurityContextRepository.saveContext(...)（Session 模式存 HttpSession；无状态模式不存）
 -> successHandler（默认跳转 / 或返回 JSON）
```

**授权链路（6.x）**：`AuthorizationFilter` 从 `SecurityContextHolder` 取 `Authentication`，交给 `AuthorizationManager`（`RequestMatcherDelegatingAuthorizationManager`，由 `authorizeHttpRequests` 配置出来的映射），每个 `RequestMatcher` 对应一个 `AuthorizationManager`，内部再用 `RoleAuthorizationManager` 等判断；5.x 则是 `FilterSecurityInterceptor` + `AccessDecisionManager`（默认 `AffirmativeBased`）+ 投票器（`WebExpressionVoter`、`RoleVoter`、`AuthenticatedVoter`）——**任一投票器投赞成即通过**。

## L3 底层层：ThreadLocal 上下文 / JWT 无状态 / 方法级切面

### 3.1 `SecurityContextHolder` 的本质

```java
public final class SecurityContextHolder {
    private static SecurityContextHolderStrategy strategy;   // 默认 ThreadLocalSecurityContextHolderStrategy
    // 三种模式：MODE_THREADLOCAL（默认）/ MODE_INHERITABLETHREADLOCAL / MODE_GLOBAL
    public static SecurityContext getContext() { return strategy.getContext(); }
}
```

- 默认把 `SecurityContext` 存在 **`ThreadLocal`** 里，请求结束（`SecurityContextHolderFilter` 的 finally）里 `clearContext()`，防止线程池复用导致上下文串号
- **跨线程必丢**：`@Async`、`CompletableFuture`、手写线程池里的线程没有这个 ThreadLocal，拿到的 context 是空的，`@PreAuthorize` 直接判成匿名
- 解法：`DelegatingSecurityContextExecutor` 包装线程池、`@Async` 配 `DelegatingSecurityContextAsyncTaskExecutor`、或手动把 `Authentication` 作为参数透传；`MODE_INHERITABLETHREADLOCAL` 只对 `new Thread` 子线程有效，线程池仍然无效

### 3.2 JWT 无状态链路

```java
http.csrf(AbstractHttpConfigurer::disable)                                  // 无状态不需要 CSRF
    .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
    .authorizeHttpRequests(a -> a.requestMatchers("/auth/**").permitAll().anyRequest().authenticated())
    .addFilterBefore(jwtFilter, UsernamePasswordAuthenticationFilter.class);
// jwtFilter（OncePerRequestFilter）：解析 Authorization: Bearer xxx
//   -> 校验签名（HMAC/RSA）+ exp + jti 黑名单
//   -> new UsernamePasswordAuthenticationToken(user, null, authorities)
//   -> SecurityContextHolder.getContext().setAuthentication(auth)
```

- **JWT 天生无法主动撤销**：签发后在过期前一直有效，所以登出/踢人要配 **黑名单**（Redis 存 `jti`，TTL = token 剩余有效期）或短有效期 + refresh token 双 token
- `STATELESS` 下 `SecurityContextRepository` 不再往 session 写，但**请求里若已有 session（例如容器/其他组件创建），仍需确认没被读取**
- JWT 里的 `exp` 只是校验字段，服务器时间不同步会导致「刚签发就过期」或「过期还能用」

### 3.3 `@PreAuthorize` 的 AOP 本质

`@EnableMethodSecurity` 通过 `@Import(MethodSecuritySelector)` 注册一组 `Advisor`：6.x 是 `AuthorizationManagerBeforeMethodInterceptor`（实现 `MethodInterceptor` + `PointcutAdvisor`，切点是 `@PreAuthorize` 注解），在方法执行前从 `SecurityContextHolder` 取 `Authentication` 交给 `AuthorizationManager` 判断，拒绝则抛 `AccessDeniedException`。所以它和 `@Transactional` 一样是**代理边界**问题：同类自调用、private 方法同样失效（详见 [AOP 与动态代理](./02-AOP与动态代理.md)）。

## L4 追问树（面试官一路往下问，你能撑到第几层？）

> 规则：从上往下问。**第 1-3 层是应届生必备，第 4-6 层是拉开差距，第 7 层以后是"能答出来就是加分"。**

### 第 1 层｜Spring Security 是怎么生效的？
**答**：容器里只注册一个 `DelegatingFilterProxy`（beanName `springSecurityFilterChain`），它转到 `FilterChainProxy`；后者按 `RequestMatcher` 选一条 `SecurityFilterChain`，依次执行内部约 15 个过滤器，认证与授权都在这些过滤器里完成。

### 第 2 层｜过滤器链里哪些是关键的？
**答**：`SecurityContextHolderFilter`（载入/清理上下文）、认证过滤器（`UsernamePasswordAuthenticationFilter`/`BasicAuthenticationFilter`/自定义 JWT 过滤器）、`AnonymousAuthenticationFilter`（放匿名身份）、`ExceptionTranslationFilter`（异常转 401/403）、`AuthorizationFilter`（最终授权）。顺序不能乱：授权必须最后。

### 第 3 层｜一次用户名密码登录内部发生了什么？
**答**：`UsernamePasswordAuthenticationFilter` 收请求 → 构造未认证的 `Authentication` → `ProviderManager` 遍历 `AuthenticationProvider` → `DaoAuthenticationProvider` 调 `UserDetailsService` 查用户 → `PasswordEncoder.matches` 比对 → 生成已认证 `Authentication` → 放进 `SecurityContextHolder` → `SecurityContextRepository` 保存（Session 模式）/ 返回 token（无状态模式）。

### 第 4 层｜`ProviderManager` 为什么设计成「遍历 Provider」？
**答**：支持多种认证方式共存（数据库密码、LDAP、OAuth2、短信验证码），每种一个 `AuthenticationProvider`，`ProviderManager` 只负责按 `supports()` 找能处理的并委托；还可以配置 `parent` 形成层级。这是策略模式 + 责任链的组合。

### 第 5 层｜`SecurityContextHolder` 存在哪？请求结束会清吗？
**答**：默认存在 `ThreadLocal`（`ThreadLocalSecurityContextHolderStrategy`），`SecurityContextHolderFilter` 在 finally 里 `clearContext()`。不清的话线程池复用会把上一个人的身份带给下一个请求，属于严重的越权漏洞。

### 第 6 层｜`@Async` 里为什么拿不到登录用户？
**答**：`SecurityContext` 在 ThreadLocal 里，异步任务跑在另一个线程。解法：用 `DelegatingSecurityContextExecutor`（或 `DelegatingSecurityContextAsyncTaskExecutor`）包装线程池，它在提交任务时捕获当前 context、执行时设置、结束后清理；也可以把 `Authentication` 当参数传。

### 第 7 层｜Session 和 JWT 无状态的区别？`STATELESS` 到底做了什么？
**答**：Session 模式把 `SecurityContext` 存在服务端 `HttpSession`（靠 JSESSIONID 找回），有状态、要粘性/共享存储；JWT 把身份放进客户端 token，服务端无状态、易水平扩展，但无法主动撤销。`SessionCreationPolicy.STATELESS` 让 `SecurityContextRepository` 变成不存储（`NullSecurityContextRepository`），保证不会为每个请求建 session。

### 第 8 层｜JWT 怎么实现登出/踢人？
**答**：JWT 本身不可撤销，只能：1）黑名单：登出时把 `jti` 写入 Redis，TTL 设为 token 剩余有效期，鉴权过滤器每次都查；2）短有效期 access token + refresh token，刷新时校验用户状态；3）token 版本号：用户表存 `tokenVersion`，改密码/踢人时递增，校验 token 里的版本号是否一致。

### 第 9 层｜授权是怎么投票的？`AffirmativeBased` 是什么？
**答**：5.x 用 `AccessDecisionManager` + `AccessDecisionVoter`：每个投票器对「这个 Authentication 能否访问该 ConfigAttribute」投赞成/反对/弃权，`AffirmativeBased` 只要有一个赞成就通过（`UnanimousBased` 要求全票、`ConsensusBased` 看多数）。6.x 换成 `AuthorizationManager`，但语义等价。

### 第 10 层｜`@PreAuthorize` 为什么有时不生效？
**答**：它是 AOP 切面，只在「经过代理」的调用上生效：同类自调用、`private`/`final` 方法、`this` 直接调用、`@EnableMethodSecurity` 没开、在非 Spring Bean 上都会失效。另外异步线程里因为 ThreadLocal 丢失也会被判定为匿名而拒绝。

### 第 11 层｜401 和 403 分别是谁产生的？
**答**：`ExceptionTranslationFilter` 捕获后面的 `AuthenticationException` 和 `AccessDeniedException`：未认证（或匿名）→ `AuthenticationEntryPoint` 返回 401（表单登录会重定向到登录页）；已认证但权限不足 → `AccessDeniedHandler` 返回 403。所以「401 是没有身份，403 是身份不够」。

### 第 12 层（终局）｜一次带 JWT 的请求完整经过哪些环节？
**答**：Tomcat worker → `DelegatingFilterProxy` → `FilterChainProxy` 选链 → `SecurityContextHolderFilter` 准备空 context → 自定义 JWT 过滤器解析 `Bearer`、验签/exp/黑名单 → 构造 `Authentication` 写入 ThreadLocal → `AnonymousAuthenticationFilter`（已有身份则跳过）→ `ExceptionTranslationFilter` 包住后续 → `AuthorizationFilter` 决策 → 放行到 `DispatcherServlet` → Controller（`@PreAuthorize` 再判一次）→ 返回后逆序出链 → `SecurityContextHolderFilter` finally `clearContext()`。**分水岭：能说出「context 在过滤器里建立、在 finally 清理」和「两层授权（URL 层 + 方法层）」。**

## L5 名词拆解表（每个名词都拆开）

| 名词 | 是什么 | 为什么存在 | 面试追问点 |
|---|---|---|---|
| `DelegatingFilterProxy` | 容器里唯一的 Security 过滤器代理 | 让 Servlet 容器能触发 Spring Bean 过滤器 | beanName 是 `springSecurityFilterChain` |
| `FilterChainProxy` | 多链分发器 | 支持多套安全策略（API/页面/静态资源） | 按 `RequestMatcher` 选链、入口 `springSecurityFilterChain` |
| `SecurityFilterChain` | 一条过滤器链配置 | 不同 URL 用不同规则 | `authorizeHttpRequests` 配置产物 |
| `SecurityContextHolder` | 当前安全上下文持有者 | 让任意代码取到「谁在请求」 | 三种策略、ThreadLocal、必须 clear |
| `SecurityContextRepository` | 上下文的持久化策略 | Session 存储 or 完全无状态 | `HttpSessionSecurityContextRepository` / `Null...` |
| `Authentication` | 认证信息（principal/credentials/authorities） | 统一表达「谁 + 有什么权限」 | 未认证令牌 vs 已认证令牌 |
| `ProviderManager` | 认证管理器实现 | 聚合多种 `AuthenticationProvider` | `supports` 匹配、parent 链 |
| `UserDetailsService` | 用户信息来源 | 把用户存储（DB/Redis）接进来 | `loadUserByUsername`、`UserDetails` 字段 |
| `PasswordEncoder` | 密码编码器 | 不存明文、可升级算法 | `BCrypt`、`matches` 与 `encode` |
| `AuthenticationEntryPoint` | 未认证入口处理 | 决定 401 还是跳登录页 | 前后端分离要返回 JSON |
| `AccessDeniedHandler` | 已认证但无权限 | 决定 403 的返回格式 | 与 EntryPoint 区分 |
| `AccessDecisionManager` / 投票器 | 旧版授权决策 | 可插拔的决策策略 | `AffirmativeBased`、`RoleVoter` |
| `AuthorizationManager` | 6.x 授权抽象 | 替代投票器，更易组合 | `RequestMatcherDelegatingAuthorizationManager` |
| `@PreAuthorize` | 方法级授权注解 | 细粒度到方法/参数 | AOP 本质、自调用失效 |
| `JWT` / `jti` | 无状态令牌 / 令牌唯一 id | 免服务端会话存储 | 不可撤销、黑名单 TTL |
| `STATELESS` | 无状态会话策略 | 避免建 session、便于扩展 | 与 CSRF、CORS 的配合 |

## 代码验证（JDK 单文件可跑：HMAC 签名令牌 + ThreadLocal 上下文跨线程丢失）

```java
// 保存为 SecurityDemo.java：javac SecurityDemo.java && java SecurityDemo
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.concurrent.*;

public class SecurityDemo {
    static final byte[] KEY = "demo-secret-key-please-change".getBytes(StandardCharsets.UTF_8);
    static String sign(String data) throws Exception {
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(KEY, "HmacSHA256"));
        return Base64.getUrlEncoder().withoutPadding().encodeToString(mac.doFinal(data.getBytes(StandardCharsets.UTF_8)));
    }
    static String token(String payload) throws Exception {          // 简化版 JWT：payload.signature
        return Base64.getUrlEncoder().withoutPadding().encodeToString(payload.getBytes(StandardCharsets.UTF_8)) + "." + sign(payload);
    }
    static String verify(String token) throws Exception {           // 验签，失败返回 null
        String[] parts = token.split("\\.");
        if (parts.length != 2) return null;
        String payload = new String(Base64.getUrlDecoder().decode(parts[0]), StandardCharsets.UTF_8);
        return sign(payload).equals(parts[1]) ? payload : null;
    }

    // 模拟 SecurityContextHolder：ThreadLocal
    static final ThreadLocal<String> CONTEXT = new ThreadLocal<>();
    public static void main(String[] args) throws Exception {
        String t = token("{\"sub\":\"yao\",\"role\":\"ADMIN\"}");
        System.out.println("token=" + t);
        System.out.println("验签通过: " + verify(t));
        String tampered = t.substring(0, t.length() - 2) + "xx";    // 改掉签名末尾两个字符
        System.out.println("被篡改: " + verify(tampered));          // null

        CONTEXT.set("yao-ADMIN");                                   // 请求线程建立上下文
        ExecutorService pool = Executors.newSingleThreadExecutor();
        pool.execute(() -> System.out.println("异步线程读 context=" + CONTEXT.get()));   // null，跨线程丢失
        Future<String> f = pool.submit(() -> {                      // 正确做法：显式透传
            CONTEXT.set("yao-ADMIN"); String v = CONTEXT.get(); CONTEXT.remove(); return v;
        });
        System.out.println("透传后异步线程读 context=" + f.get());
        pool.shutdown();
        CONTEXT.remove();                                           // 请求结束必须清理
    }
}
```

```java
// Spring Security 侧等价配置（需 Spring 依赖，示意用）
@Bean
SecurityFilterChain api(HttpSecurity http, JwtFilter jwtFilter) throws Exception {
    return http.csrf(AbstractHttpConfigurer::disable)
        .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
        .authorizeHttpRequests(a -> a.requestMatchers("/auth/login").permitAll()
            .requestMatchers("/admin/**").hasRole("ADMIN").anyRequest().authenticated())
        .exceptionHandling(e -> e.authenticationEntryPoint((req, res, ex) -> res.sendError(401))
                                 .accessDeniedHandler((req, res, ex) -> res.sendError(403)))
        .addFilterBefore(jwtFilter, UsernamePasswordAuthenticationFilter.class)
        .build();
}
```

## 高频错误（面试官最爱抓的）

| 错误说法 | 正确说法 |
|---|---|
| 「Spring Security 是一个拦截器」 | 它是一条 Servlet 过滤器链，在 DispatcherServlet 之前 |
| 「JWT 更适合所有场景」 | JWT 无法主动撤销、体积大；内部系统用 Session + Redis 往往更简单 |
| 「`SecurityContextHolder` 是全局静态变量」 | 底层是 ThreadLocal（默认策略），线程之间不共享 |
| 「异步线程会自动继承登录态」 | 必须用 `DelegatingSecurityContextExecutor` 或显式传参 |
| 「`@PreAuthorize` 和 URL 授权二选一」 | 两层都要：URL 层挡粗粒度，方法层挡细粒度 |
| 「401 和 403 没区别，都是没权限」 | 401 是未认证（没有身份），403 是已认证但权限不足 |
| 「JWT 过期了服务端会主动通知」 | 服务端只做校验，撤销必须靠黑名单/版本号/短有效期 |
| 「STATELESS 下 CSRF 必须开着」 | 无状态 token 鉴权通常关 CSRF；Session 模式必须开 |

## 关联文件

- 上一层（Spring 八股）：[SpringBoot与后端工程](../../03-java/SpringBoot与后端工程.md)
- 同层追问：[SpringMVC 请求链路](./05-SpringMVC请求链路.md)（Filter 链在 MVC 之前）｜[AOP 与动态代理](./02-AOP与动态代理.md)（`@PreAuthorize` 的代理边界）｜[IoC 与 Bean 生命周期](./01-IoC与Bean生命周期.md)｜[事务传播与失效](./03-事务传播与失效.md)
- 底层支撑：[ThreadLocal](../java/11-ThreadLocal.md)（`SecurityContextHolder` 就是它）｜[线程池](../java/08-线程池.md)（异步上下文丢失）
- 典型场景：报告平台的「登录鉴权」用 JWT + Redis 黑名单；SSE 进度推送的异步线程要显式透传用户身份；Docker 沙箱任务调度接口按角色做方法级鉴权
- 速查：[深度追问索引](../00-索引.md)

## 自测标准

- 能画出 `DelegatingFilterProxy -> FilterChainProxy -> 15 个过滤器 -> DispatcherServlet` 的链路
- 能按顺序讲清认证链路（Filter -> ProviderManager -> UserDetailsService -> SecurityContext）
- 能解释 `SecurityContextHolder` 的 ThreadLocal 本质、清理时机、跨线程丢失与解法
- 能说清 JWT 无状态链路、登出黑名单与 Session/Token 混用的坑
- 能说清 401 与 403 的产生位置，以及 `@PreAuthorize` 的 AOP 本质
- L4 讲到第 6 层（ThreadLocal/异步）算及格；讲到第 12 层（完整过滤器链路）算优秀
