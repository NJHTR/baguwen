# @Transactional 为什么在有些方法上完全不生效？

> 精讲层级：从「零基础能看懂」到「源码级」，每个名词都拆开
> 阅读时间：约 40 分钟
> 配套速查：[事务传播与失效（深度追问）](../../10-deep-dive/spring/03-事务传播与失效.md)
> 返回：[精讲索引](../00-索引.md)

---

## 0. 一句话先讲明白

`@Transactional` 不是魔法，它只是 **AOP 的一个切面**：Spring 给 Bean 生成一个代理，代理在方法调用前后插一段「开事务 / 提交或回滚」的代码。所以它生效的前提非常苛刻：

1. 你调用的必须是**代理对象**（`this` 不是代理，同类自调用就失效）
2. 方法必须**能被代理拦截**（`private`/`final`/`static` 不行）
3. 异常必须**能被拦截器看到**（被 catch 吞掉就不回滚）
4. 事务资源必须**在同一条线程**上（连接是绑在 `ThreadLocal` 里的，换线程就没了）

四条任何一条不满足，注解就变成一行注释。

---

## 1. 痛点背景：为什么这件事必须搞懂

### 1.1 一个典型事故

```java
@Service
public class OrderService {
    @Transactional
    public void approve(Long id) {
        orderMapper.updateStatus(id, "APPROVED");   // 数据成功
        this.writeAudit(id);                        // 内部调用，抛异常
    }
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void writeAudit(Long id) { auditMapper.insert(id); }
}
```

出问题时的现象通常是两种：

- 审批状态改成功了，审计日志没写进去（因为 `writeAudit` 的 `REQUIRES_NEW` 没生效，跟着外层一起提交）
- 审计日志写失败，整个审批被回滚了（因为异常确实抛到了外层事务）

**看起来注解写了，实际上行为完全不是预期的**——这就是「事务失效」这四个字的真实代价。

### 1.2 先解释三个名词

| 名词 | 是什么 | 为什么重要 |
|---|---|---|
| AOP 代理（proxy） | Spring 在 Bean 外面套的一层对象，方法调用先经过它，再进真实对象 | 事务拦截器就是挂在这一层 |
| 代理边界（proxy boundary） | 「进入代理」到「离开代理」这段区间 | 只有跨过边界的方法调用才触发切面 |
| 事务管理器（`PlatformTransactionManager`） | 负责开/提交/回滚事务的组件 | 它才是真正和数据库打交道的人 |

### 1.3 一个数字：代理边界有多「窄」

设一个 `@Transactional` 方法 `approve()` 内部调用了 4 个带注解的方法：其中 `this.methodA()`、`this.methodB()` 在边界内但没跨过代理，注解不生效；只有跨 Bean 的 `otherBean.methodC()` 和老老实实走代理的外部调用才真正开启/加入事务。**一次业务调用里 4 个注解、可能只有 2 个生效**——失效从来不是「注解坏了」，而是「调用没跨过代理边界」。

---

## 2. 逐步拆解：AOP 本质、连接绑定、七种传播

### 2.1 `@Transactional` 的 AOP 本质

```java
// 概念上的等价代码（Spring 内部就是用 MethodInterceptor 做的）
public Object invoke(MethodInvocation invocation) throws Throwable {
    TransactionStatus status = transactionManager.getTransaction(attr);   // 开或加入事务
    try {
        Object result = invocation.proceed();                             // 执行业务方法
        transactionManager.commit(status);                                // 正常返回 -> 提交
        return result;
    } catch (Throwable ex) {
        if (rollbackOn(ex)) transactionManager.rollback(status);           // 符合规则 -> 回滚
        else transactionManager.commit(status);                            // 不符合 -> 提交并继续抛
        throw ex;
    }
}
```

真实的实现类是 `TransactionInterceptor`（实现了 `MethodInterceptor`），它在 `invokeWithinTransaction` 里完成上面这段逻辑。

**关键点**：事务拦截器只能拦截「从代理对象进来的调用」。任何绕过代理的调用都拿不到事务。

### 2.2 连接是怎么绑定到线程的

事务能生效，靠的是「同一个线程里的多次数据库操作共用一个连接」。Spring 用 `TransactionSynchronizationManager` 实现：

```java
public abstract class TransactionSynchronizationManager {
    private static final ThreadLocal<Map<Object, Object>> resources = ...;   // key = DataSource
    private static final ThreadLocal<Boolean> actualTransactionActive = ...;
    public static void bindResource(Object key, Object value) { ... }        // 开事务时绑定 ConnectionHolder
    public static Object getResource(Object key) { ... }                     // DAO 取连接时查这里
    public static Object unbindResource(Object key) { ... }                  // 事务结束时解绑
}
```

**执行链**：

```
代理开启事务
  -> DataSourceTransactionManager.doBegin()
      -> connection = dataSource.getConnection()
      -> connection.setAutoCommit(false)          ← 真正开启事务
      -> bindResource(dataSource, new ConnectionHolder(connection))
业务方法里的 DAO
  -> DataSourceUtils.getConnection(dataSource)
      -> 先查 ThreadLocal 有没有绑定 -> 有就复用同一个连接
方法返回
  -> commit() -> 解绑 + 恢复 autoCommit + 归还连接池
```

**由此可以推出三个失效原因**：换线程（ThreadLocal 没了）、绕过代理（拦截器没执行，连接没绑定）、手写 `new` 对象（没有代理）。

### 2.3 七种传播行为逐条

**传播行为（propagation）**回答的是同一个问题：**当前已经有一个事务了，这个新方法该怎么办？**

| 传播 | 外层有事务 | 外层无事务 | 一句话 |
|---|---|---|---|
| `REQUIRED`（默认） | 加入同一个事务 | 新建事务 | 最常见；内层失败会拖垮外层 |
| `REQUIRES_NEW` | 挂起外层，新建独立事务 | 新建事务 | 内层失败不影响外层；占两个连接 |
| `SUPPORTS` | 加入 | 以非事务方式执行 | 跟着调用方走 |
| `NOT_SUPPORTED` | 挂起外层，非事务执行 | 非事务执行 | 明确声明「我不要事务」 |
| `MANDATORY` | 加入 | 抛异常 | 强制要求调用方已有事务 |
| `NEVER` | 抛异常 | 非事务执行 | 严禁在事务里被调用 |
| `NESTED` | 创建 savepoint（子事务） | 新建事务 | 内层回滚到保存点，外层可继续 |

**重点区分 `REQUIRES_NEW` 和 `NESTED`**：

| | `REQUIRES_NEW` | `NESTED` |
|---|---|---|
| 物理事务 | 2 个（独立提交/回滚） | 1 个（靠 savepoint） |
| 连接数 | 2 个 | 1 个 |
| 内层失败 | 外层不受影响 | 回滚到 savepoint，外层可继续提交剩下的 |
| 依赖 | 无特殊依赖 | 依赖 JDBC savepoint（数据库驱动要支持） |
| 风险 | 连接池耗尽、死锁 | savepoint 持有锁，长事务风险 |

---

## 3. 完整推导：一次调用到底发生了什么

### 3.1 正常路径的时序

```
调用方（拿到的是代理）
  ├─ TransactionInterceptor.invoke
  │    ├─ getTransaction：查 ThreadLocal 有无 ConnectionHolder
  │    │     ├─ 没有 -> doBegin：取连接、setAutoCommit(false)、绑定 ThreadLocal
  │    │     └─ 有且 REQUIRED -> 返回「加入」状态
  │    ├─ invocation.proceed() ──► 业务方法（DAO 复用 ThreadLocal 里的连接）
  │    └─ 正常返回 commit / 抛异常 rollbackOn 判定后回滚或提交
```

### 3.2 自调用为什么失效（时序推导）

```
proxy.approve()                 目标对象.approve()
   │                                 │
   ├─ 拦截器：开事务 TX-1            │
   ├─ proceed() ───────────────────► │
   │                                 ├─ orderMapper.update(...)    ← 用 TX-1 的连接
   │                                 ├─ this.audit()              ← 直接调用，没有代理
   │                                 │    └─ audit() 内部的注解根本没人读
   │                                 └─ 返回
   ├─ 提交 TX-1
```

**根因一句话**：`this` 指向目标对象，不是代理对象。代理边界只存在于「外部调用代理」的那一刻，对象内部的自调用天然在边界内、却又没有经过拦截器。

### 3.3 `REQUIRES_NEW` 的挂起时序

```
外层 TX-1 已绑定连接 C1
  -> 内层方法 REQUIRES_NEW
      -> suspend()：把 C1 从 ThreadLocal 解绑，放进 SuspendedResourcesHolder（不还池！）
      -> doBegin()：从连接池取 C2，绑定
      -> 内层提交/回滚 -> 解绑 C2 -> 还池
      -> resume()：把 C1 重新绑回 ThreadLocal
外层继续使用 C1
```

**数字结论**：`REQUIRES_NEW` 执行期间，这个线程同时占用 **2 个数据库连接**。如果线程池 100、连接池 20，就会出现「线程都在等连接」的死锁式排队。

### 3.4 提交时机：为什么事务内发消息会出问题

提交发生在**业务方法返回之后**。所以：

```
方法内：  更新订单 -> 发 MQ 消息 -> 返回
消费者：  可能先收到消息 -> 查订单 -> 查不到（还没提交）
```

正确姿势：`TransactionSynchronization.afterCommit()` 里发消息，或用事务消息/本地消息表。

---

## 4. 极简模型：两个 Bean、一条代理边界

场景：`OrderService.approve()` 调用 `AuditService.log()`，两个方法都有 `@Transactional`。

| 时刻 | 代码位置 | 是否在代理内 | 事务状态 |
|---|---|---|---|
| 1 | 外部调用 `orderService.approve()` | 是（进代理） | 开 TX-1 |
| 2 | `approve()` 内 `auditService.log()` | 是（跨 Bean，进代理） | 按传播决定：加入 TX-1 或新建 |
| 3 | `approve()` 内 `this.audit()` | **否**（同一对象内） | 无新事务，也没有拦截 |
| 4 | `approve()` 内 `new AuditService().log()` | **否**（不是 Spring Bean） | 完全没有事务 |
| 5 | `approve()` 内 `executor.submit(() -> audit())` | **否**（换了线程） | ThreadLocal 为空，另起事务或没有 |

**结论**：只有第 1、2 种在代理边界内。第 3、4、5 就是三种最常见的失效场景——它们看起来都「调用了带注解的方法」。

---

## 5. 为什么这样设计：四个被否决的方案

### 5.1 方案一：全用编程式事务（`TransactionTemplate`）

- 做法：`transactionTemplate.execute(status -> { ... })` 手工包住业务代码
- 优点：边界清晰，绝不失效，粒度完全可控
- 否决原因：样板代码多；业务代码侵入事务基础设施；`execute` 里抛异常才回滚，容易漏。Spring 的取舍是「声明式为主、编程式为辅」。

### 5.2 方案二：让 Spring 框架自动检测自调用

- 设想：代理内部记录「当前线程正在执行哪个 Bean 的方法」，`this` 调用也走拦截器
- 否决原因：`this` 是 JVM 层面的对象引用，无法在运行时被替换成代理；要实现只能改字节码（AspectJ LTW），带来不可预期的开销与调试困难。Spring 选择「明确边界」而不是「偷偷拦截」。

### 5.3 方案三：把 `@Transactional` 只放在接口方法上

- 优点：JDK 动态代理只认接口，看起来「对齐」
- 否决原因：官方建议注解放**实现类**；接口注解在实现类覆写方法没加注解时容易歧义，且「哪些方法有事务」不直观。Spring 6 更推荐「类上放 + 方法上按需覆写」。

### 5.4 方案四：全面改用 AspectJ 编译期/加载期织入

- 优点：没有代理边界，自调用、`private` 方法都能织入
- 否决原因：需要编译器插件或 `-javaagent`，构建链路复杂、栈帧更深；Spring 默认运行时代理。AspectJ 适合大型项目统一织入，不适合作为默认方案。

---

## 6. 关键参数为什么是这个值

| 参数 | 默认值 | 为什么 |
|---|---|---|
| `propagation` | `REQUIRED` | 大多数业务是「要么一起成功、要么一起失败」，加入现有事务最符合直觉 |
| `isolation` | `DEFAULT` | 跟随数据库默认隔离级别（MySQL 是 RR），避免框架强加一个与 DB 不一致的级别 |
| `rollbackFor` | 空（只回滚 `RuntimeException`/`Error`） | 见下方说明 |
| `readOnly` | `false` | 默认不知道是读还是写；只读提示要显式声明 |
| `timeout` | `-1`（不超时） | 超时是 `Statement.setQueryTimeout`，语句级，不同数据库行为不一致，默认不启用 |

**为什么默认只回滚运行时异常**：Java 的受检异常（checked exception）在语义上表示「调用方可以处理的可预期情况」，Spring 认为这种情况不一定要回滚整个事务（业务上可能想「记录失败但保留其他操作」）。而 `RuntimeException`/`Error` 通常代表程序缺陷或不可恢复错误，必须回滚。这个约定是历史设计，很多团队会直接统一改成 `rollbackFor = Exception.class`。

---

## 7. 版本演进

| 版本 | 变化 | 影响 |
|---|---|---|
| Spring 4.x / 5.x（Boot 1.x） | `proxyTargetClass` 默认 false，有接口用 JDK 动态代理 | 只代理接口方法，`private`/类方法不生效更明显 |
| Spring Boot 2.x 起 | `AopAutoConfiguration` 默认 `spring.aop.proxy-target-class=true` | 默认 CGLIB 类代理，能代理类方法 |
| Spring 5.x | `@Transactional` 可标注在类/方法/接口 | 类级注解作为默认值 |
| Spring Framework 6.0 / Boot 3.x | 类代理下放宽到 `protected` 与包可见方法（`public` 仍是最稳的） | 非 `public` 方法失效的边界变窄，但 `private`/`final` 仍不行 |
| Spring 6.0 / Boot 3.x | 基线 Java 17；`javax.*` 换 `jakarta.*` | 事务管理器实现不变，但依赖升级要同步 |

**面试表述**：Spring 5 时代「非 public 方法一定失效」；Spring 6 + CGLIB 之后，`protected`/包可见方法在类代理下可以被拦截，但 `private`、`final`、`static` 依然不行——**最稳的写法仍然是 public 方法**。

---

## 8. 亲手验证：八种失效场景逐个复现

### 8.1 八种失效场景总表

| # | 场景 | 最小复现代码（关键行） | 根因 | 修法 |
|---|---|---|---|---|
| 1 | 同类自调用 | `this.audit();` | 没跨代理边界 | 注入自身代理/拆 Bean/`AopContext` |
| 2 | `private` 方法 | `@Transactional private void m()` | 代理无法覆写 | 改 public 或抽到别的 Bean |
| 3 | `final` 方法/类 | `@Transactional public final void m()` | CGLIB 无法覆写 final | 去掉 final |
| 4 | 非 public（JDK 代理） | 接口方法外的实现方法 | JDK 代理只认接口方法 | Boot 默认 CGLIB，或改 public |
| 5 | 异常类型不匹配 | 抛 `IOException`（受检） | 默认只回滚 `RuntimeException` | `rollbackFor = Exception.class` |
| 6 | 异常被吞掉 | `try { ... } catch (Exception e) { log.error(...) }` | 拦截器看不到异常 | 别吞，或手动 `TransactionAspectSupport.currentTransactionStatus().setRollbackOnly()` |
| 7 | 多线程/异步 | `executor.submit(() -> dao.insert())` | 连接绑定在 ThreadLocal，换线程丢失 | 显式事务模板/在子线程内自开事务 |
| 8 | 对象不受 Spring 管理 | `new OrderService().approve()` | 没有代理 | 从容器取 Bean |
| 9 | 数据库引擎不支持 | MySQL `MyISAM` 表 | 引擎本身没有事务 | 改 `InnoDB` |

### 8.2 场景 1：同类自调用

```java
@Service
public class OrderService {
    @Transactional
    public void approve(Long id) {
        orderMapper.updateStatus(id, "APPROVED");
        this.audit(id);                   // 错误：this 是目标对象，不是代理
    }
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void audit(Long id) { auditMapper.insert(id); }
}
```

**修法 A：注入自身代理（必须加 `@Lazy` 防循环依赖）**

```java
@Service
public class OrderService {
    @Lazy @Autowired private OrderService self;      // 拿到的是代理
    @Transactional
    public void approve(Long id) {
        orderMapper.updateStatus(id, "APPROVED");
        self.audit(id);                               // 正确：跨过代理边界
    }
}
```

**修法 B：`AopContext.currentProxy()`（需要 `exposeProxy=true`）**

```java
@EnableAspectJAutoProxy(exposeProxy = true)   // 启动类或配置类上
// ...
((OrderService) AopContext.currentProxy()).audit(id);
```

`AopContext` 内部是一个 `ThreadLocal`：代理在进入方法前把「当前代理」放进去，方法结束后恢复。所以它**只在本线程的这次调用栈里有效**，异步线程里取不到。

**修法 C：拆到另一个 Bean**（最干净，推荐）。

### 8.3 场景 2、3、4：方法本身不可代理

```java
@Service
public class BadService {
    @Transactional private void privateMethod() { }              // 失效：代理看不到
    @Transactional public final void finalMethod() { }           // 失效：CGLIB 不能覆写 final
    @Transactional public static void staticMethod() { }         // 失效：静态方法不属于对象
}
```

**原因**：代理是「子类覆写」或「接口实现」，这三种方法都无法被覆写。修法：改成 `public` 非 `final` 的实例方法，或把逻辑移到另一个 Bean。

### 8.4 场景 5：异常类型不匹配

```java
@Transactional                                  // 默认只回滚 RuntimeException
public void importFile() throws IOException { orderMapper.insert(...); throw new IOException("文件损坏"); }
@Transactional(rollbackFor = Exception.class)   // 正确：显式声明
public void importFile2() throws IOException { ... }
```

### 8.5 场景 6：异常被吞掉

```java
@Transactional
public void approve(Long id) {
    try {
        orderMapper.updateStatus(id, "APPROVED");
        auditService.log(id);                    // 抛异常
    } catch (Exception e) {
        log.error("审计失败，忽略", e);           // 吞掉了：拦截器认为成功 -> 提交
    }
}
```

修法：要么别吞（让异常冒泡），要么在 catch 里显式标记回滚：`TransactionAspectSupport.currentTransactionStatus().setRollbackOnly();`

### 8.6 场景 7：多线程

```java
@Transactional
public void approve(Long id) {
    orderMapper.updateStatus(id, "APPROVED");
    executor.submit(() -> auditMapper.insert(id));   // 子线程：ThreadLocal 里没有事务资源
}
```

子线程的 `DataSourceUtils.getConnection` 拿不到外层连接，要么新开一个（如果子线程方法有注解且有代理），要么走自动提交——**外层回滚不会影响子线程已经写入的数据**。

### 8.7 场景 8：对象不受 Spring 管理

`new OrderService().approve(1L)` 拿到的是普通对象，没有代理，注解全部失效；正确做法是从容器取：`applicationContext.getBean(OrderService.class)`。

### 8.8 用纯 JDK 复刻「代理边界」与「异常规则」

下面这段代码不依赖 Spring，用 `java.lang.reflect.Proxy` + 自定义注解，把自调用、受检异常、跨线程三种失效演示出来：

```java
import java.io.IOException;
import java.lang.annotation.*;
import java.lang.reflect.*;

public class TxDemo {
    @Retention(RetentionPolicy.RUNTIME) @interface Tx { }

    interface OrderApi { void approve(); void throwChecked() throws IOException; }

    static class OrderService implements OrderApi {
        static final ThreadLocal<String> TX = new ThreadLocal<>();
        static int committed = 0, rolledBack = 0;

        @Tx public void approve() {
            TX.set("TX-approve");
            System.out.println("approve: 开启事务 " + TX.get());
            this.audit();                               // 自调用：不经过代理
            TX.remove();
        }
        @Tx public void audit() {
            System.out.println("audit: 事务标记 = " + TX.get() + "（自调用不复用拦截器）");
        }
        @Tx public void throwChecked() throws IOException {
            TX.set("TX-checked");
            throw new IOException("文件损坏");           // 受检异常
        }
    }

    @SuppressWarnings("unchecked")
    static <T> T proxy(T target, Class<T> api) {
        return (T) Proxy.newProxyInstance(api.getClassLoader(), new Class<?>[]{api},
            (p, method, args) -> {
                Method impl = target.getClass().getMethod(method.getName(), method.getParameterTypes());
                boolean tx = impl.isAnnotationPresent(Tx.class);
                if (tx) { OrderService.TX.set("TX-" + method.getName()); System.out.println("[代理] 开启 " + OrderService.TX.get()); }
                try {
                    Object r = impl.invoke(target, args);
                    if (tx) { System.out.println("[代理] 提交"); OrderService.committed++; OrderService.TX.remove(); }
                    return r;
                } catch (InvocationTargetException e) {
                    Throwable cause = e.getCause();
                    boolean rollback = cause instanceof RuntimeException || cause instanceof Error;
                    if (tx) {
                        System.out.println("[代理] " + (rollback ? "回滚" : "提交（受检异常默认不回滚）"));
                        if (rollback) OrderService.rolledBack++; else OrderService.committed++;
                        OrderService.TX.remove();
                    }
                    throw cause;
                }
            });
    }

    public static void main(String[] args) throws Exception {
        OrderApi service = proxy(new OrderService(), OrderApi.class);
        System.out.println("--- 场景 1：自调用 ---");
        service.approve();                       // 只有一个「开启」，audit 的注解没生效

        System.out.println("--- 场景 2：受检异常 ---");
        try { service.throwChecked(); } catch (IOException e) { System.out.println("调用方捕获: " + e.getMessage()); }
        System.out.println("committed=" + OrderService.committed + ", rolledBack=" + OrderService.rolledBack);

        System.out.println("--- 场景 3：换线程 ---");
        new Thread(() -> System.out.println("子线程事务标记 = " + OrderService.TX.get())).start();
        Thread.sleep(100);
    }
}
```

预期输出：

```
--- 场景 1：自调用 ---
[代理] 开启 TX-approve
approve: 开启事务 TX-approve
audit: 事务标记 = TX-approve（自调用不复用拦截器）
[代理] 提交
--- 场景 2：受检异常 ---
[代理] 开启 TX-throwChecked
[代理] 提交（受检异常默认不回滚）
调用方捕获: 文件损坏
committed=2, rolledBack=0
--- 场景 3：换线程 ---
子线程事务标记 = null
```

**观察点**：`audit()` 的 `@Tx` 完全没有被拦截（没打印「开启 TX-audit」）；受检异常导致「提交」而不是「回滚」；子线程的 `ThreadLocal` 是空的。

---

## 9. 常见误区

| 错误说法 | 正确说法 |
|---|---|
| 「加了 `@Transactional` 就一定回滚」 | 受检异常默认不回滚，要 `rollbackFor` |
| 「同类调用也会生效」 | 自调用不走代理，必须注入自身/拆 Bean/`AopContext` |
| 「`REQUIRES_NEW` 和 `NESTED` 一样」 | 前者两个物理事务、两个连接；后者一个事务 + savepoint |
| 「事务提交在方法内部」 | 提交在方法返回之后、代理返回之前 |
| 「`readOnly=true` 就不能写」 | 只是提示，写仍可能成功，且不保证性能收益 |
| 「多线程里的事务会跟着外层回滚」 | ThreadLocal 绑定，子线程是独立事务（或没有事务） |
| 「`private` 方法加注解也能生效」 | 代理无法覆写 private；Spring 6 也只放宽到 protected/包可见 |
| 「`@Transactional` 可以放在接口上」 | 建议放实现类；类级注解 + 方法级覆写最稳妥 |

---

## 10. 连续追问 Q&A

### Q1：`@Transactional` 的底层是什么？

AOP 代理 + `TransactionInterceptor`（`MethodInterceptor`）。拦截器在方法前 `getTransaction`（开或加入事务），正常返回 `commit`，异常按 `rollbackOn` 决定回滚还是提交。

### Q2：事务连接是怎么被同一个线程共享的？

`DataSourceTransactionManager.doBegin` 里把 `ConnectionHolder` 绑定到 `TransactionSynchronizationManager` 的 `ThreadLocal`（key 是 `DataSource`）。同一线程里的 DAO 通过 `DataSourceUtils.getConnection` 查到这个 holder 并复用连接。事务结束时解绑、恢复 `autoCommit`、归还连接池。

### Q3：`REQUIRED` 和 `REQUIRES_NEW` 的区别？

`REQUIRED` 外层有事务就加入（同一个物理事务、同一个连接），内层抛异常外层也回滚；`REQUIRES_NEW` 挂起外层、新建独立事务（第二个连接），内层提交/回滚不影响外层。代价是并发下多占连接，可能死锁。

### Q4：`NESTED` 的 savepoint 是怎么实现的？

进入内层时 `conn.setSavepoint()` 得到 `Savepoint`，内层异常时 `conn.rollback(savepoint)` 回到保存点，外层仍可提交剩余操作。物理上还是一个事务、一个连接。依赖 JDBC 驱动的 savepoint 支持。

### Q5：为什么 `AopContext.currentProxy()` 能拿到代理？有什么限制？

开启 `exposeProxy=true` 后，代理在 `invoke` 开头把自身放进 `AopContext` 的 `ThreadLocal`，方法结束恢复。限制：① 必须显式开启；② 只在本线程本次调用栈内有效，异步线程取不到；③ 有少量额外开销。

### Q6：同类调用为什么不能直接改成 `AopContext` 就完事？

`AopContext` 能用，但它是「代码里显式依赖 AOP 基础设施」，可读性和可测性都变差。更推荐把被调方法拆到独立的 Bean 里（跨 Bean 调用天然走代理），或者用编程式事务明确边界。

### Q7：`@Transactional` 加在类上和加在方法上有什么区别？

类级注解相当于给所有 public 方法一个默认事务属性，方法级注解可覆盖（包括改传播、改 `rollbackFor`）。两者同时存在时方法级优先。

### Q8：为什么事务默认只回滚 `RuntimeException`？

Spring 的设计约定：受检异常代表「可预期的业务情况」，调用方可以处理；`RuntimeException`/`Error` 代表程序缺陷或不可恢复错误，必须回滚。实战中建议显式 `rollbackFor = Exception.class`，避免受检异常导致的「数据不一致但事务提交」。

### Q9：事务超时真的能中断事务吗？

不能硬中断。`timeout` 最终落到 `Statement.setQueryTimeout`，只能让慢 SQL 抛超时异常，进而触发回滚；对已经拿到的行锁、长事务占用的 undo，需要数据库参数（如 `innodb_lock_wait_timeout`）配合。

### Q10：为什么在事务里发 MQ 消息会导致「消息先到、数据后到」？

提交发生在方法返回后，而发送消息发生在方法内。消费者可能在提交前就收到消息并查库，查不到数据。解法：`TransactionSynchronization.afterCommit()` 里发、事务消息（半消息 + 回查）、或本地消息表 + 补偿。

### Q11：`@Transactional` 和 `@Async` 一起用会怎样？

`@Async` 会把方法丢到另一个线程执行，`@Transactional` 的连接绑定在**提交线程**的 ThreadLocal 上，换线程后事务上下文丢失，异步方法内部要么没有事务，要么按自身注解新开事务。所以不要依赖「异步方法继承外层事务」，要显式设计。

---

## 11. 一张图总结

```
外部调用 orderService.approve()
   │
   ▼
[代理] TransactionInterceptor
   ├─ 开事务：doBegin -> setAutoCommit(false) -> bind ThreadLocal(DataSource -> ConnectionHolder)
   ├─ 执行业务（DAO 通过 DataSourceUtils 复用同一个连接）
   ├─ 正常返回 -> commit -> 解绑 -> 恢复 autoCommit -> 还连接
   └─ 抛异常 -> rollbackOn? 回滚 : 提交

失效的四个方向：
 1. 没跨代理：this.audit()、private、final、new 出来的对象
 2. 异常没被看到：被 catch 吞掉
 3. 异常类型不符：受检异常默认不回滚
 4. 换了线程：ThreadLocal 里没有事务资源
```

---

## 12. 一句话复盘

> `@Transactional` = 代理 + `TransactionInterceptor` + `ThreadLocal` 连接绑定；它能生效的前提是「调用跨过代理边界、方法可被覆写、异常能冒泡到拦截器、且在同一条线程上」。八种失效本质上是这四条前提被破坏的不同方式，所以排查时先问：这次调用经过代理了吗？异常出来了吗？还是同一条线程吗？

---

## 13. 自测题（先自己答，再看答案）

**1. 同一个类里 `a()` 调用 `b()`，两者都有 `@Transactional`，事务会开几次？**

答案：一次（只开 `a()` 的）。`b()` 是 `this` 调用，不经过代理，拦截器没执行。若 `b()` 声明了 `REQUIRES_NEW`，不会产生新事务。

**2. 事务方法抛 `IOException`，默认会回滚吗？怎么改？**

答案：不会。默认只回滚 `RuntimeException`/`Error`。加 `@Transactional(rollbackFor = Exception.class)` 即可。

**3. 一个 `REQUIRES_NEW` 方法执行期间，这个线程占几个数据库连接？**

答案：2 个。外层连接被挂起（不归还池），内层新取一个连接，内层结束后恢复外层。

**4. 为什么 `private` 方法上的 `@Transactional` 不生效？**

答案：代理是「子类覆写（CGLIB）」或「接口实现（JDK）」，`private` 方法既不能被覆写也不能出现在接口里，拦截器没有插入点。

**5. 事务方法里 `try/catch` 吞掉异常，会怎样？**

答案：拦截器看不到异常，认为方法成功，于是提交。需要显式 `setRollbackOnly()` 或让异常冒泡。

**6. 在 `@Transactional` 方法里 `executor.submit(...)`，子线程的数据操作会随外层回滚吗？**

答案：不会。事务连接绑定在提交线程的 ThreadLocal 上，子线程没有这个上下文，是独立的事务（或没有事务）。

---

## 14. 关联文件

- 深一层（追问树 + 源码细节）：[事务传播与失效](../../10-deep-dive/spring/03-事务传播与失效.md)
- 同层精讲：[循环依赖与三级缓存](02-Spring循环依赖与三级缓存.md)
- 相关精讲：[线程池执行流程](../java/07-线程池执行流程.md)（`@Async` 与线程切换）、[volatile 与内存屏障](../java/09-volatile与内存屏障.md)（ThreadLocal 可见性）
- 返回：[精讲索引](../00-索引.md)
