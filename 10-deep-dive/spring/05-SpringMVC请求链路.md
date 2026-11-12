# SpringMVC 请求链路

> 面试权重：4/5　｜　追问深度：**L5（`DispatcherServlet#doDispatch` / 参数解析器 / Servlet 异步线程模型）**
> 一句话定位：SpringMVC 是一个**前端控制器（Front Controller）**模式：所有请求先到 `DispatcherServlet`，它按 URL 找到 handler（`HandlerMapping`）、找到能执行 handler 的适配器（`HandlerAdapter`）、跑拦截器、绑定参数、执行方法、处理返回值，最后渲染视图或直接把 JSON 写进响应。

[返回深度追问索引](../00-索引.md)

## L1 一句话答案（10 秒能说出口）

请求进来先经过 `Filter` 链到 `DispatcherServlet`，`doDispatch` 依次做：`getHandler`（`HandlerMapping` 返回 handler + 拦截器链）→ `getHandlerAdapter` → `applyPreHandle` → `ha.handle`（参数解析 + 反射执行 + 返回值处理）→ `applyPostHandle` → `processDispatchResult`（异常处理 / 渲染 / `afterCompletion`）。`@ResponseBody` 走 `RequestResponseBodyMethodProcessor`，用 `HttpMessageConverter` 直接写响应体。

## L2 原理层：`doDispatch` 九步

```java
protected void doDispatch(HttpServletRequest request, HttpServletResponse response) throws Exception {
    HandlerExecutionChain mappedHandler = null;
    ModelAndView mv = null;
    Exception dispatchException = null;
    try {
        processedRequest = checkMultipart(request);                 // 1. MultipartResolver 解析文件上传
        mappedHandler = getHandler(processedRequest);               // 2. HandlerMapping：URL -> HandlerExecutionChain
        if (mappedHandler == null) { noHandlerFound(request, response); return; }
        HandlerAdapter ha = getHandlerAdapter(mappedHandler.getHandler());  // 3. 找适配器
        if (!mappedHandler.applyPreHandle(processedRequest, response)) return;  // 4. 拦截器 preHandle，返回 false 直接中断
        mv = ha.handle(processedRequest, response, mappedHandler.getHandler()); // 5. 参数解析 + 执行 + 返回值处理
        applyDefaultViewName(processedRequest, mv);
        mappedHandler.applyPostHandle(processedRequest, response, mv);          // 6. 拦截器 postHandle
    } catch (Exception ex) { dispatchException = ex; }
      catch (Throwable err) { dispatchException = new NestedServletException("Handler dispatch failed", err); }
    processDispatchResult(processedRequest, response, mappedHandler, mv, dispatchException); // 7-9
}
```

第 7-9 步在 `processDispatchResult` 里：处理异常（`HandlerExceptionResolver`）→ 渲染视图（`ViewResolver`）或标记已处理 → `mappedHandler.triggerAfterCompletion(...)` 逆序回调拦截器。

| 组件 | 实现类 | 职责 |
|---|---|---|
| `HandlerMapping` | `RequestMappingHandlerMapping`、`BeanNameUrlHandlerMapping`、`SimpleUrlHandlerMapping`、`RouterFunctionMapping` | URL/请求条件 → handler |
| `HandlerAdapter` | `RequestMappingHandlerAdapter`、`HttpRequestHandlerAdapter`、`SimpleControllerHandlerAdapter` | 用统一方式执行不同类型的 handler |
| `HandlerMethodArgumentResolver` | 约 30 个：`RequestParamMethodArgumentResolver`、`PathVariableMethodArgumentResolver`、`ModelAttributeMethodProcessor`、`RequestResponseBodyMethodProcessor`、`ServletRequestMethodArgumentResolver` | 把 request 变成方法实参 |
| `HandlerMethodReturnValueHandler` | `ModelAndViewMethodReturnValueHandler`、`ViewNameMethodReturnValueHandler`、`RequestResponseBodyMethodProcessor`、`HttpEntityMethodProcessor`、`ResponseBodyEmitterReturnValueHandler`（SSE/流式） | 把返回值变成 ModelAndView 或响应体 |

```java
// 参数解析入口（InvocableHandlerMethod.invokeForRequest -> getMethodArgumentValues）
for (MethodParameter parameter : parameters) {
    HandlerMethodArgumentResolver resolver = resolvers.getArgumentResolver(parameter); // 遍历 list，第一个 supportsParameter 为真
    args[i] = resolver.resolveArgument(parameter, mavContainer, webRequest, binderFactory);
}
// 返回值入口（ServletInvocableHandlerMethod.invokeAndHandle）
returnValueHandlers.handleReturnValue(returnValue, getReturnValueType(returnValue), mavContainer, webRequest);
```

## L3 底层层：映射匹配 / 过滤器与拦截器 / 异步线程模型

### 3.1 URL 是怎么匹配到方法的

`RequestMappingHandlerMapping` 继承 `AbstractHandlerMethodMapping`，初始化时把每个 `@RequestMapping` 方法注册成 `RequestMappingInfo`（包含 path 模式、method、params、headers、consumes、produces 条件），存进 `MappingRegistry`。请求到来时 `lookupHandlerMethod` 先按 URL 直接命中缓存，命中不了再遍历所有 `RequestMappingInfo`，用 `RequestMappingInfo.getMatchingCondition` 逐条件比较，最后按 `compareTo`（更具体的 pattern 优先）排序取最优。所以 **URL 越具体越优先，`/user/{id}` 打不过 `/user/list`**。

### 3.2 `@ResponseBody` 到底怎么输出 JSON

`RequestResponseBodyMethodProcessor` 同时是参数解析器和返回值处理器：`supportsReturnType` 判断方法/类上有 `@ResponseBody`（`@RestController` 是它的组合注解）。返回值阶段 `writeWithMessageConverters`：

1. 由 `ContentNegotiationStrategy`（`HeaderContentNegotiationStrategy` 读 `Accept`，或用 `format` 参数）确定目标媒体类型
2. 遍历 `HttpMessageConverter`（`MappingJackson2HttpMessageConverter`、`StringHttpMessageConverter`、`ByteArrayHttpMessageConverter` 等），找第一个 `canWrite(类型, mediaType)` 的
3. 写响应体，`mavContainer.setRequestHandled(true)` 表示「已处理，不用再找 View」，因此返回 `null` ModelAndView

### 3.3 过滤器（Filter）与拦截器（Interceptor）

| | Filter | Interceptor |
|---|---|---|
| 规范来源 | Servlet 规范（`javax/jakarta.servlet`） | Spring MVC（`HandlerInterceptor`） |
| 执行位置 | `DispatcherServlet` **之前**（容器级） | `DispatcherServlet` **内部**（拿到 handler 之后） |
| 能拿到什么 | 只有 `ServletRequest/Response` | 能拿到 `HandlerMethod`、`ModelAndView` |
| 能改什么 | 可包装 request/response | 只能影响执行流程与模型 |
| 触发时机 | 所有请求（含静态资源） | 仅进入 MVC 的请求 |

执行顺序：`Filter#doFilter 前` → `DispatcherServlet` → `preHandle`（正序）→ Controller → `postHandle`（**逆序**）→ 视图渲染 → `afterCompletion`（逆序）→ `Filter#doFilter 后`。`preHandle` 返回 `false` 会跳过 handler 与后续拦截器，但仍对**已执行过的**拦截器调 `afterCompletion`。

### 3.4 异步请求与 SSE 的线程模型

同步模型：Tomcat 一个请求占一个 worker 线程到响应写完；SSE 长连接下会**耗尽线程池**（`server.tomcat.threads.max` 默认 200），这是 SSE 项目最先踩的坑。

异步：Controller 返回 `Callable` / `DeferredResult` / `SseEmitter` 时，`RequestMappingHandlerAdapter` 通过 `WebAsyncManager` 处理：

```
进入 doDispatch -> 拿到返回值是异步类型
 -> WebAsyncManager.startCallableProcessing / startDeferredResultProcessing
 -> request.startAsync()（Servlet 3.0 AsyncContext）
 -> 把任务提交到 TaskExecutor / 业务线程（SSE 场景：注册到 emitter 的队列）
 -> 立即 return null，Servlet 线程被释放（不再阻塞）
 -> 业务完成后 asyncContext.dispatch() 重新派发到 DispatcherServlet
 -> 第二次进入时 WebAsyncUtils.getAsyncManager(request).hasConcurrentResult() 为真
 -> ServletInvocableHandlerMethod.wrapConcurrentResult 用返回值处理器输出结果
```

- `AsyncContext.setTimeout` 对应 `spring.mvc.async.request-timeout`，超时抛 `AsyncRequestTimeoutException`
- `DeferredResult.onTimeout/onError` 可自定义兜底；`SseEmitter` 就是 `ResponseBodyEmitter` 的 SSE 子类，底层仍走 `ResponseBodyEmitterReturnValueHandler`，靠 `SseEmitter.send()` 不断写 `text/event-stream`
- **连接数不等于线程数**：Tomcat NIO 里长期存活的 SSE 连接占用 socket 与 poller，不占 worker 线程的前提是「写响应不阻塞」；一旦在 emitter 里同步做慢操作，又会退回线程被占住的状态

## L4 追问树（面试官一路往下问，你能撑到第几层？）

> 规则：从上往下问。**第 1-3 层是应届生必备，第 4-6 层是拉开差距，第 7 层以后是"能答出来就是加分"。**

### 第 1 层｜一个 HTTP 请求在 SpringMVC 里怎么走到 Controller？
**答**：容器把请求交给 `DispatcherServlet`（继承 `HttpServlet`）→ `doDispatch`：`getHandler` 拿 handler 和拦截器链 → `getHandlerAdapter` → `preHandle` → `ha.handle` 执行业务 → `postHandle` → `processDispatchResult` 处理异常并渲染。

### 第 2 层｜`doDispatch` 具体哪几步？
**答**：九步：检查 Multipart → 找 handler → 找适配器 → 拦截器 preHandle → 执行 handler（参数解析、反射调用、返回值处理）→ 拦截器 postHandle → 处理异常 → 渲染或标记已处理 → 逆序 afterCompletion。

### 第 3 层｜`HandlerMapping` 和 `HandlerAdapter` 为什么拆成两个？
**答**：职责分离。`HandlerMapping` 只回答「谁来处理」，`HandlerAdapter` 回答「怎么执行这个处理器」。这样支持多种 handler 类型（`@RequestMapping` 方法、`HttpRequestHandler`、`Controller` 接口、函数式路由），每种配一个 adapter，DispatcherServlet 不用写 if-else 分支。

### 第 4 层｜参数是怎么绑定到方法入参的？注解靠什么生效？
**答**：`InvocableHandlerMethod.getMethodArgumentValues` 遍历方法参数，逐个交给 `HandlerMethodArgumentResolverComposite`，取第一个 `supportsParameter` 为真的解析器。`@RequestParam` 由 `RequestParamMethodArgumentResolver` 处理、`@PathVariable` 由 `PathVariableMethodArgumentResolver`、`@RequestBody` 由 `RequestResponseBodyMethodProcessor`、无注解 POJO 由 `ModelAttributeMethodProcessor`。解析器注册顺序在 `RequestMappingHandlerAdapter.getDefaultArgumentResolvers` 里，自定义解析器要排在后面。

### 第 5 层｜`@ResponseBody` 怎么把对象变成 JSON？
**答**：`RequestResponseBodyMethodProcessor` 作为返回值处理器：内容协商定媒体类型 → 遍历 `HttpMessageConverter` 找 `canWrite` 的（`MappingJackson2HttpMessageConverter`）→ 写响应体 → `mavContainer.setRequestHandled(true)`，返回 null ModelAndView，后续不再走 ViewResolver。

### 第 6 层｜过滤器、拦截器执行顺序？分别能拿到什么？
**答**：Filter 在 DispatcherServlet 之前（容器级），Interceptor 在其内部（MVC 级）。顺序：Filter 前 → preHandle 正序 → Controller → postHandle 逆序 → 渲染 → afterCompletion 逆序 → Filter 后。Interceptor 能拿到 `HandlerMethod` 和 `ModelAndView`，Filter 只有 request/response。

### 第 7 层｜`preHandle` 返回 false 会怎样？异常时 `afterCompletion` 还执行吗？
**答**：返回 false 直接中断，不执行 handler 和后续拦截器，DispatcherServlet 直接返回；但**已经执行过 preHandle 的拦截器**会收到 `afterCompletion`（`triggerAfterCompletion` 只回调 `interceptorIndex` 之前的）。handler 抛异常时也会走 `afterCompletion`，所以资源清理放这里最稳。

### 第 8 层｜异常是怎么被 `@ExceptionHandler` 接住的？
**答**：异常先被 `doDispatch` 捕获存进 `dispatchException`，再交给 `processHandlerException` 遍历 `HandlerExceptionResolver`（`ExceptionHandlerExceptionResolver` 找 `@ExceptionHandler` 方法，`ResponseStatusExceptionResolver` 处理 `@ResponseStatus`，`DefaultHandlerExceptionResolver` 处理标准异常），解析成功返回 ModelAndView 并渲染，否则继续往外抛。

### 第 9 层｜Controller 返回 `DeferredResult` 时线程在哪？
**答**：`RequestMappingHandlerAdapter` 交给 `WebAsyncManager`，调用 `request.startAsync()` 拿到 `AsyncContext`，业务任务提交到 `TaskExecutor`；`doDispatch` 立即返回、**Servlet 线程被释放**。业务线程完成后 `asyncContext.dispatch()` 重新派发，第二次进入时用 `wrapConcurrentResult` 输出结果。所以一个慢接口不会占住容器线程，但任务线程池要单独配。

### 第 10 层｜SSE 进度推送的线程模型和普通接口有什么区别？有什么坑？
**答**：SSE 用 `SseEmitter`（`ResponseBodyEmitter` 子类），响应头是 `text/event-stream`，连接长期保持，`ResponseBodyEmitterReturnValueHandler` 不结束响应对应地走异步。坑有三：连接数受 `server.tomcat.max-connections` 限制；超时/心跳（`emitter.send` 失败要移除）；复杂业务不能在写响应时阻塞，否则 worker 线程被占住。

### 第 11 层｜Tomcat 的线程模型是什么？为什么 SSE 不占线程却仍要小心？
**答**：NIO 模型：acceptor 线程接连接 → poller 线程监听读写事件 → 事件就绪交给 worker 线程池执行 `Servlet.service`。SSE 连接在 servlet 线程被释放后由 poller 兜着，只有要写数据时才用线程。但连接占 socket、占内存，且有 `maxConnections` 上限；如果 emitter 的写操作很慢或同步阻塞，仍会拖住工作线程。

### 第 12 层（终局）｜一次 `GET /api/order/1` 从网卡到响应的完整链路？
**答**：网卡 → 内核 socket → Tomcat acceptor/poller 就绪 → worker 线程解析 HTTP 生成 `HttpServletRequest` → `Filter` 链（含编码/CORS/Security）→ `DispatcherServlet.service` → `doDispatch` → `RequestMappingHandlerMapping` 命中 `OrderController#get(1)` + 拦截器 → `RequestMappingHandlerAdapter` → `PathVariableMethodArgumentResolver` 取 `1` → 反射调用 → 返回 `OrderVO` → `RequestResponseBodyMethodProcessor` + Jackson 序列化 → 写响应 → `afterCompletion` → 事务/线程池等资源释放。**分水岭：能说出「handler 匹配缓存 + 更具体的 pattern 优先」和「返回值处理器如何把对象落成字节流」。**

## L5 名词拆解表（每个名词都拆开）

| 名词 | 是什么 | 为什么存在 | 面试追问点 |
|---|---|---|---|
| `DispatcherServlet` | 前端控制器 Servlet | 统一入口，把请求分发给具体 handler | 继承结构、`doService` 与 `doDispatch` 区别 |
| `HandlerMapping` | 请求到 handler 的映射策略 | 支持多种 URL 匹配方式 | `RequestMappingInfo` 条件匹配、优先级 |
| `HandlerExecutionChain` | handler + 拦截器链 | 一个请求可能要经过多个拦截器 | preHandle/postHandle/afterCompletion 顺序 |
| `HandlerAdapter` | 执行 handler 的适配器 | 屏蔽 handler 类型差异 | 三种适配器、`supports` 判断 |
| `@Controller` / `@RestController` | 控制器注解 | 声明式注册 handler | `@RestController` = `@Controller` + `@ResponseBody` |
| `HandlerMethod` | 封装「哪个 bean 的哪个方法」 | 反射执行与参数元数据 | 参数注解、桥接方法 |
| `HandlerMethodArgumentResolver` | 参数解析器 | 把 request 转实参 | 30 个默认解析器、自定义扩展 |
| `HandlerMethodReturnValueHandler` | 返回值处理器 | 决定输出方式（视图/JSON/流） | 与 `HttpMessageConverter` 配合 |
| `@ResponseBody` | 标记方法返回体直接写响应 | 前后端分离的基石 | 走哪个处理器、内容协商 |
| `HttpMessageConverter` | Java 对象与 HTTP body 互转 | 支持 JSON/XML/表单/字节流 | `canWrite` 判断、Jackson 配置 |
| `ContentNegotiationStrategy` | 决定响应媒体类型 | 一套接口支持 JSON/XML | `Accept` 头、`format` 参数 |
| `HandlerExceptionResolver` | 异常解析器链 | 把异常转成统一响应 | `@ExceptionHandler`、优先级 |
| `Filter` / `OncePerRequestFilter` | Servlet 过滤器 | 容器级横切（编码/安全/日志） | 与 Interceptor 区别、执行顺序 |
| `AsyncContext` / `WebAsyncManager` | Servlet 异步支持 | 释放容器线程做慢业务 | `startAsync`、二次 dispatch、超时 |
| `SseEmitter` / `ResponseBodyEmitter` | 流式/长连接响应 | SSE 进度推送 | 心跳、连接管理、与 WebSocket 区别 |

## 代码验证（JDK 单文件可跑：模拟 handler 匹配 + 适配器 + 拦截器链）

```java
// 保存为 MiniMvc.java：javac MiniMvc.java && java MiniMvc
import java.util.*;

public class MiniMvc {
    interface Handler { String handle(); }                       // 模拟 Controller 方法
    static class HandlerExecutionChain {                          // handler + 拦截器
        final Handler handler; final List<String> logs = new ArrayList<>();
        HandlerExecutionChain(Handler h) { this.handler = h; }
        boolean applyPreHandle() { logs.add("preHandle 正序"); return true; }
        void applyPostHandle() { logs.add("postHandle 逆序"); }
        void triggerAfterCompletion() { logs.add("afterCompletion 逆序"); }
    }
    static class MappingRegistry {                                // 模拟 HandlerMapping
        final Map<String, Handler> map = new LinkedHashMap<>();
        void register(String path, Handler h) { map.put(path, h); }
        HandlerExecutionChain getHandler(String path) {            // 精确匹配优先，其次 path 变量
            Handler h = map.get(path);
            if (h == null) for (var e : map.entrySet()) {
                if (e.getKey().contains("{id}") && path.matches(e.getKey().replace("{id}", "\\d+")))
                    { h = e.getValue(); break; }
            }
            return h == null ? null : new HandlerExecutionChain(h);
        }
    }
    public static void main(String[] args) {
        MappingRegistry registry = new MappingRegistry();
        registry.register("/order/list", () -> "{\"list\":[]}");
        registry.register("/order/{id}", () -> "{\"id\":1,\"status\":\"PAID\"}");

        for (String path : List.of("/order/list", "/order/1", "/order/abc")) {
            HandlerExecutionChain chain = registry.getHandler(path);
            if (chain == null) { System.out.println(path + " -> 404"); continue; }
            chain.applyPreHandle();
            String body = chain.handler.handle();                   // 模拟 ha.handle
            chain.applyPostHandle();
            chain.triggerAfterCompletion();
            System.out.println(path + " -> " + body + " | " + chain.logs);
        }
    }
}
```

```java
// Spring 侧等价写法（需 Spring 依赖，示意用）
@RestController
@RequestMapping("/api/order")
public class OrderController {
    @GetMapping("/{id}")
    public OrderVO get(@PathVariable Long id) { return orderService.get(id); }   // 走 RequestResponseBodyMethodProcessor
    @GetMapping(value = "/{id}/progress", produces = MediaType.TEXT_EVENT_STREAM_VALUE)
    public SseEmitter progress(@PathVariable Long id) { ... }                     // 走 ResponseBodyEmitterReturnValueHandler
}
```

## 高频错误（面试官最爱抓的）

| 错误说法 | 正确说法 |
|---|---|
| 「拦截器就是过滤器，只是名字不同」 | Filter 在 Servlet 层、DispatcherServlet 之前；Interceptor 在 MVC 内部，能拿 HandlerMethod |
| 「`preHandle` 返回 false 后什么都不执行」 | 已执行过 preHandle 的拦截器仍会收到 afterCompletion |
| 「`@ResponseBody` 是拦截器实现的」 | 是返回值处理器 `RequestResponseBodyMethodProcessor` 实现的 |
| 「`postHandle` 和 `preHandle` 都是正序」 | preHandle 正序、postHandle 与 afterCompletion 逆序 |
| 「异步请求会占住 Tomcat 线程」 | 异步会释放 Servlet 线程，占的是连接与业务线程池 |
| 「`@RequestMapping` 按声明顺序匹配」 | 按 `RequestMappingInfo` 条件匹配度排序，更具体的 pattern 优先 |
| 「SSE 和 WebSocket 一样是双向的」 | SSE 是单向服务端推送、基于 HTTP 长连接；WebSocket 是全双工 |
| 「参数解析器只有 `@RequestParam` 那一套」 | 默认约 30 个，含 `@RequestBody`、`@ModelAttribute`、`Model`、`ServletRequest` 等 |

## 关联文件

- 上一层（Spring 八股）：[SpringBoot与后端工程](../../03-java/SpringBoot与后端工程.md)
- 同层追问：[IoC 与 Bean 生命周期](./01-IoC与Bean生命周期.md)（`@Controller` 也是 Bean）｜[AOP 与动态代理](./02-AOP与动态代理.md)（拦截器与切面的边界）｜[SpringBoot 自动配置](./04-SpringBoot自动配置.md)（MVC 自动配置来源）｜[Security 与鉴权](./06-SpringSecurity与鉴权.md)（Filter 链在 MVC 之前）
- 底层支撑：[线程池](../java/08-线程池.md)（异步任务的线程从哪来）｜[SpringBoot 自动配置](./04-SpringBoot自动配置.md)（`WebMvcAutoConfiguration`）
- 典型场景：多模态项目的「SSE 流式进度推送」就是 `SseEmitter` + 异步线程池；报告平台的 API 网关层靠 Filter 做 traceId，靠 Interceptor 做权限预检
- 速查：[深度追问索引](../00-索引.md)

## 自测标准

- 能按顺序说出 `doDispatch` 九步，并指出哪一步执行 Controller
- 能画出 Filter 与 Interceptor 的交错执行顺序，并说清 `preHandle` 返回 false 的后果
- 能讲清 `@ResponseBody` 从返回值到 JSON 字节流的完整路径
- 能说清 `DeferredResult`/`SseEmitter` 的异步线程模型，以及 SSE 的坑
- 能解释 URL 匹配的优先级规则与 `RequestMappingInfo` 条件匹配
- L4 讲到第 6 层（过滤器/拦截器）算及格；讲到第 12 层（网卡到响应全链路）算优秀
