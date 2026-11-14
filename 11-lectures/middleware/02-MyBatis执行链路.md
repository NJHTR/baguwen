# MyBatis 执行链路：一行 mapper 调用，是怎么变成 ResultSet 的？

> 精讲层级：从「零基础能看懂」到「源码方法级」，每个名词都在第一次出现时拆开
> 阅读时间：约 35 分钟
> 配套速查：[MyBatis 原理（深度追问）](../../10-deep-dive/middleware/04-MyBatis原理.md)
> 返回：[精讲索引](../00-索引.md)

---

## 0. 一句话先讲明白

`userMapper.selectById(1L)` 这一行调用，背后是一台"翻译机器"在工作：**Mapper 接口没有实现类**，MyBatis 用 JDK 动态代理给它造了一个代理对象；代理把"方法调用"翻译成"要执行哪条 SQL"（`MappedStatement`），交给 `SqlSession`；`SqlSession` 再交给 `Executor`（先查一级/二级缓存），缓存不命中才创建 `StatementHandler` 去创建 JDBC 的 `PreparedStatement`，由 `ParameterHandler` 把 `#{}` 参数按类型塞进去，执行完 `ResultSetHandler` 把结果集映射成对象。整条链的核心是**把"方法名 + 参数"变成"SQL + 参数绑定 + 结果映射"**。

---

## 1. 先讲痛点：为什么不能直接写 JDBC

### 1.1 名词先解释

| 名词 | 一句话解释 |
|---|---|
| ORM | Object-Relational Mapping，对象与关系表的映射；把「一行数据」和「一个对象」对应起来 |
| JDBC | Java 访问数据库的标准 API，最底层，需要手写 SQL、手动取结果、手动关资源 |
| 动态代理 | 运行时生成一个实现某接口的类，方法调用都被转发到一个统一的 `invoke` 方法（JDK 的 `Proxy` + `InvocationHandler`） |
| `SqlSession` | MyBatis 的"一次会话"，持有连接、事务、缓存，非线程安全 |
| `PreparedStatement` | JDBC 的预编译语句，SQL 里用 `?` 占位，参数单独设置，能防注入且可复用执行计划 |
| SQL 注入 | 把用户输入当 SQL 语法拼进语句，改变原意（例如让 `where` 恒真、union 出其他表） |

### 1.2 纯 JDBC 的样板代码长什么样

```java
Connection conn = null; PreparedStatement ps = null; ResultSet rs = null;
try {
    conn = dataSource.getConnection();
    ps = conn.prepareStatement("SELECT id, name, age FROM user WHERE id = ?");
    ps.setLong(1, id);
    rs = ps.executeQuery();
    User user = null;
    if (rs.next()) {
        user = new User();
        user.setId(rs.getLong("id")); user.setName(rs.getString("name")); user.setAge(rs.getInt("age"));
    }
    return user;
} finally {
    if (rs != null) try { rs.close(); } catch (SQLException ignored) {}
    if (ps != null) try { ps.close(); } catch (SQLException ignored) {}
    if (conn != null) try { conn.close(); } catch (SQLException ignored) {}
}
```

痛点：

1. **样板代码占 80%**：连接、关闭、异常处理每个方法重复一遍，容易漏关导致连接泄漏；
2. **结果映射手写**：字段一多就是几十行 `rs.getXxx`；
3. **SQL 与代码耦合**：SQL 散落在 Java 字符串里，改 SQL 要重新编译；
4. **动态条件难写**：`if (name != null) sql += " and name = ?"` 这种拼接既丑又容易出错。

### 1.3 为什么选"半自动 ORM"

| 方案 | 代表 | 优点 | 痛点 |
|---|---|---|---|
| 全自动 ORM | Hibernate / JPA | 对象即表，CRUD 几乎零 SQL | 复杂查询生成的 SQL 不可控、优化困难、N+1 隐蔽 |
| 半自动 ORM | MyBatis | SQL 自己写、映射框架做 | 要会写 SQL，但控制了执行计划 |
| 纯 JDBC | 原生 | 完全可控、无魔法 | 样板代码地狱 |
| 纯 SQL 构建器 | JOOQ 等 | 类型安全 | 学习成本、生态 |

MyBatis 的取舍：**把"控制权"留给开发者（SQL 自己写），把"重复劳动"交给框架（参数绑定、结果映射、资源管理）**。

---

## 2. 逐步拆解：从接口调用到 ResultSet

### 2.1 第一阶段：启动时把配置解析成 `Configuration`

```
SqlSessionFactoryBuilder.build(inputStream)
  └── XMLConfigBuilder.parse()
        ├── 解析 mybatis-config.xml → settings/typeHandlers/plugins/environments
        ├── 解析 mapper XML → 每条 <select>/<insert> 变成 MappedStatement
        │     key = namespace + "." + id（如 com.demo.UserMapper.selectById）
        └── MapperRegistry.addMapper(UserMapper.class)
              → 登记「接口 → MapperProxyFactory」的映射
```

- **`Configuration`**：全局唯一，装着所有 `MappedStatement`、缓存、插件、类型处理器；
- **`MappedStatement`**：一条 SQL 的完整描述——SQL 文本（`SqlSource`）、参数映射、结果映射（`ResultMap`）、是否用缓存（`useCache`）、是否清缓存（`flushCache`）、超时时间等。

### 2.2 第二阶段：`getMapper()` 生成动态代理

```java
// 简化自 MapperRegistry.getMapper → MapperProxyFactory.newInstance
public <T> T getMapper(Class<T> type, SqlSession sqlSession) {
    return knownMappers.get(type).newInstance(sqlSession);   // 内部：Proxy.newProxyInstance
}
// newProxyInstance(mapperInterface.getClassLoader(), new Class[]{mapperInterface},
//                  new MapperProxy<>(sqlSession, mapperInterface, methodCache));
```

从这一刻起，`userMapper` 不是 `UserMapper` 的实现类，而是一个 **JDK 动态代理对象**。所有方法调用都会进入 `MapperProxy.invoke`。

### 2.3 第三阶段：`MapperProxy` → `MapperMethod` 分派

```java
// MapperProxy.invoke（简化）
public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
    if (Object.class.equals(method.getDeclaringClass())) {
        return method.invoke(this, args);         // toString/hashCode/equals 直接放行
    }
    return cachedMapperMethod(method).execute(sqlSession, args);
}
```

`MapperMethod` 有两个核心成员：

- **`SqlCommand`**：`statementId`（接口全限定名 + 方法名）+ `SqlCommandType`（SELECT/INSERT/UPDATE/DELETE/FLUSH）；
- **`MethodSignature`**：方法返回类型、参数名、是否带 `RowBounds`（MyBatis 的逻辑分页参数）、是否带 `ResultHandler`。

`execute()` 根据命令类型分派到 `SqlSession` 的不同方法：

| 命令类型 | 调用的 SqlSession 方法 | 返回值处理 |
|---|---|---|
| SELECT，返回集合 | `selectList` | 直接返回 List |
| SELECT，返回单个 | `selectOne` | 结果多于 1 条抛 `TooManyResultsException` |
| INSERT | `insert` | 影响行数，转成方法返回类型 |
| UPDATE / DELETE | `update` / `delete` | 同上 |
| 返回 void | - | 不取结果 |

### 2.4 第四阶段：`SqlSession` → `Executor`

```java
// DefaultSqlSession.selectOne
public <T> T selectOne(String statement, Object parameter) {
    List<T> list = this.selectList(statement, parameter);
    if (list.size() == 1) return list.get(0);
    if (list.size() > 1) throw new TooManyResultsException(...);
    return null;
}

// selectList
return executor.query(ms, wrapCollection(parameter), rowBounds, Executor.NO_RESULT_HANDLER);
```

`Executor` 有四个实现，按 `executorType` 选择：

| 实现 | 行为 | 适用 |
|---|---|---|
| `SimpleExecutor` | 每次查询新建 `Statement` | 默认 |
| `ReuseExecutor` | 按 SQL 文本复用 `Statement` | 同 SQL 高频重复 |
| `BatchExecutor` | `addBatch` 攒批，`flushStatements` 时执行 | 批量写 |
| `CachingExecutor` | 装饰器，外面再包一层二级缓存 | `cacheEnabled=true` 且 mapper 配了 `<cache/>` |

### 2.5 第五阶段：两层缓存

```java
// CachingExecutor.query（二级缓存，namespace 级）
if (ms.isUseCache() && cache != null) {
    Object cached = tcm.getObject(cache, key);      // TransactionalCacheManager
    if (cached != null) return cached;
}
// 未命中 → 交给 delegate（BaseExecutor）继续；BaseExecutor 再查一级缓存 localCache
```

- **一级缓存**：同一个 `SqlSession` 内、`CacheKey` 相同就命中；`CacheKey` 由 statementId + SQL 文本 + 参数 + RowBounds + 环境等组成。
- **二级缓存**：跨 `SqlSession`、同一个 namespace 生效，但结果要等事务 `commit` 才真正写入（`TransactionalCache` 机制）。

### 2.6 第六阶段：`StatementHandler` / `ParameterHandler` / `ResultSetHandler`

```java
// SimpleExecutor.doQuery（简化）
StatementHandler handler = configuration.newStatementHandler(...);  // 插件在这里包装
stmt = handler.prepare(connection, transaction.getTimeout());        // 创建 PreparedStatement
handler.parameterize(stmt);                                          // 给 ? 设参数
return handler.query(stmt, resultHandler);                           // 执行 + 映射
```

三个 Handler 的职责：

| 对象 | 职责 | 典型实现 |
|---|---|---|
| `StatementHandler` | 创建/执行 `PreparedStatement`，处理分页与超时 | `RoutingStatementHandler` 按 statementType 路由到 Simple/Prepared/Callable |
| `ParameterHandler` | 把参数对象按 `TypeHandler`（Java 类型与 JDBC 类型的转换器）设置到 `?` 上（**索引从 1 开始**） | `DefaultParameterHandler` |
| `ResultSetHandler` | 把 `ResultSet` 按 `ResultMap` 映射成对象/集合 | `DefaultResultSetHandler` |

### 2.7 `#{}` 与 `${}`：注入原理可复现

**`#{}`**：解析 SQL 时把 `#{name}` 替换成 `?`，并生成一条参数映射（参数名、JDBC 类型、TypeHandler）。执行时用 `PreparedStatement.setXxx(i, value)` 设置——**参数永远被当作"值"，不参与 SQL 语法解析**。

**`${}`**：解析 SQL 时把 `${name}` 直接**字符串替换**进 SQL 文本，然后才交给数据库解析。参数被当作"SQL 语法的一部分"。

可复现实验（假设表 `account(id, owner, balance)`）：

```xml
<!-- 错误写法：值拼接 -->
<select id="findByOwner" resultType="Account">
  SELECT id, owner, balance FROM account WHERE owner = '${owner}'
</select>
<!-- 正确写法：值占位 -->
<select id="findByOwnerSafe" resultType="Account">
  SELECT id, owner, balance FROM account WHERE owner = #{owner}
</select>
```

调用 `findByOwner("' OR '1'='1")` 后，实际执行的 SQL 变成：

```sql
SELECT id, owner, balance FROM account WHERE owner = '' OR '1'='1'
```

`WHERE` 恒为真，**返回全表所有账户**；更恶意的输入还可以用 `union select` 拼接出别的表数据。而 `#{}` 版本的执行日志是：

```
Preparing: SELECT id, owner, balance FROM account WHERE owner = ?
Parameters: ' OR '1'='1(String)
```

参数整段被当作字符串值，查不到对应记录，SQL 结构不变。

> 唯一必须用 `${}` 的地方是**动态标识符**：表名、列名、`ORDER BY` 字段。此时必须用白名单校验，例如把前端传入的排序字段映射成枚举，绝不直接拼用户输入。

### 2.8 一级缓存与二级缓存的生效条件

**一级缓存（SqlSession 级，默认开）**

- 生效：同一个 SqlSession、同一个 `MappedStatement`、参数相同（`CacheKey` 相等）；
- 失效：执行任意 INSERT/UPDATE/DELETE（`flushCache=true` 会清空该 namespace 的缓存）、`commit`/`rollback`、手动 `clearCache()`、配置 `localCacheScope=STATEMENT`（每条语句后清空）。

**二级缓存（namespace 级，默认不生效）**

- 生效条件：`cacheEnabled=true`（默认 true）+ mapper XML 里写 `<cache/>` + 实体可序列化（默认可读写的缓存需要）；
- 写入时机：`TransactionalCache` 会先把结果攒在 `entriesToAddOnCommit`，**事务提交时才真正刷进缓存**，回滚则丢弃——防止"查出来但事务回滚"的脏数据被别的会话读到；
- 失效：该 namespace 的任何增删改默认清空整个 namespace 缓存。

---

## 3. 完整推导：把链路和代价算出来

### 3.1 推导一：一次查询经过多少层调用

从 `userMapper.selectById(1L)` 到 JDBC 执行，数一数调用层数（简化）：

| 序号 | 层 | 类/方法 |
|---|---|---|
| 1 | 代理 | `MapperProxy.invoke` |
| 2 | 分派 | `MapperMethod.execute` |
| 3 | 会话 | `DefaultSqlSession.selectOne` |
| 4 | 会话 | `DefaultSqlSession.selectList` |
| 5 | 二级缓存 | `CachingExecutor.query` |
| 6 | 一级缓存 | `BaseExecutor.query` |
| 7 | 查库 | `SimpleExecutor.doQuery` |
| 8 | 语句 | `PreparedStatementHandler.query` |
| 9 | 设参 | `DefaultParameterHandler.setParameters` |
| 10 | 映射 | `DefaultResultSetHandler.handleResultSets` |

一次用户调用约穿过 **10 层**，其中真正的 JDBC 动作只在第 8~10 层。缓存命中时只到第 6 层就返回。

### 3.2 推导二：预编译与参数数量

一条 SQL 有 n 个 `#{}` 参数，`DefaultParameterHandler` 会调用 n 次 `setXxx`。以 `INSERT INTO user(name, age, email) VALUES (#{name}, #{age}, #{email})` 为例：n = 3，JDBC 参数索引是 1、2、3（**不是 0**，这是常见 bug 来源）。

预编译的收益：`PreparedStatement` 的 SQL 文本是固定的，数据库可以缓存"SQL → 执行计划"，重复执行时省掉解析与优化。按每次硬解析约 0.1~1 毫秒估算，同一条 SQL 执行 1 万次：

```
无预编译（${} 导致 SQL 每次都不同）：10000 × 0.1ms = 1000ms
有预编译（#{}）：解析一次，其余复用 → 解析开销约 0.1ms
```

差三个数量级，这也是 `${}` 除了注入之外的第二个大坑。

### 3.3 推导三：缓存能省多少 SQL

假设接口 QPS 1000，其中 90% 是重复查询（同样的 statementId + 参数）：

```
无缓存：1000 次 SQL/秒
一级缓存有效（同一会话内重复，比如一个请求内查两次）：仍要跨请求，跨会话无效
二级缓存命中 80%：DB 压力 = 1000 × (1 - 0.8) = 200 次 SQL/秒
```

反过来说，缓存配置错误（比如多表 join 的 namespace 互不知道对方更新）会让 200 次"该查库"的请求读到旧值——**省下的 800 次 SQL，换来的是数据不一致风险**，所以生产要权衡。

---

## 4. 极简模型：用 5 个角色演一遍

把 10 层压成 5 个角色：

1. **前台（Mapper 代理）**：只负责接单，把"客人要什么"翻译成"点菜单编号"；
2. **分派员（MapperMethod）**：看菜单编号判断是"查"还是"改"，转给后厨；
3. **后厨（SqlSession/Executor）**：先看备菜台（缓存）有没有现成的，没有才开火；
4. **配菜员（ParameterHandler）**：把食材（参数）按配方（TypeHandler）放进对应的格子（`?`）；
5. **装盘员（ResultSetHandler）**：把做好的菜（ResultSet）按摆盘图（ResultMap）装成客人要的样子（对象）。

用 30 行伪代码模拟这个模型：

```java
interface UserMapper { User selectById(Long id); }

class MiniProxy implements InvocationHandler {
    public Object invoke(Object p, Method m, Object[] args) {
        String sql = "SELECT * FROM user WHERE id = ?";   // 本该由 MappedStatement 提供
        try (PreparedStatement ps = conn.prepareStatement(sql)) {
            ps.setLong(1, (Long) args[0]);                // 参数绑定
            try (ResultSet rs = ps.executeQuery()) {
                return rs.next() ? mapUser(rs) : null;    // 结果映射
            }
        }
    }
}
// 使用：UserMapper mapper = (UserMapper) Proxy.newProxyInstance(..., new MiniProxy());
```

这 30 行就是 MyBatis 的核心思想：**代理接住调用 → 找到 SQL → 绑参 → 执行 → 映射**。真实框架只是把每一步做得可配置、可扩展（缓存、插件、动态 SQL、类型处理）。

---

## 5. 为什么这样设计：被否决的方案

### 5.1 方案 A：不用动态代理，每个 DAO 写实现类

- 做法：`UserMapperImpl implements UserMapper`，每个方法手写 JDBC
- 否决原因：样板代码回到 JDBC 时代；接口一多，维护成本爆炸；而且"方法名 → SQL"的映射关系还是得手写死

### 5.2 方案 B：全自动 ORM（Hibernate 风格）

- 做法：只写实体和注解，SQL 框架生成
- 否决原因：复杂查询（多表、窗口函数、优化器 hint）生成的 SQL 难控制；性能问题难定位；团队要懂框架的方言。MyBatis 选择"SQL 归你，映射归我"

### 5.3 方案 C：SQL 全写注解（`@Select`），不要 XML

- 优点：少一个文件
- 否决原因：动态 SQL（`<if>`/`<foreach>`）用注解写会变成字符串拼接灾难；复杂映射（association/collection）注解表达力差。所以注解只适合简单语句

### 5.4 一句话取舍

| 方案 | 开发效率 | SQL 可控性 | 安全 | 结论 |
|---|---|---|---|---|
| 纯 JDBC | 低 | 最高 | 取决于写法 | 教学/极简场景 |
| MyBatis | 高 | 高 | `#{}` 默认安全 | 主流选择 |
| Hibernate/JPA | 最高 | 低 | 高 | 简单 CRUD 场景 |
| 注解式 MyBatis | 高 | 中 | 同 MyBatis | 简单语句 |

---

## 6. 关键参数为什么是这个值

### 6.1 `localCacheScope = SESSION`（默认）

- SESSION：一级缓存跨整个会话有效，减少同会话重复查询；
- STATEMENT：每条语句后清空，等价于关掉一级缓存。
- 默认 SESSION 是为了性能，但**长会话（比如一个 HTTP 请求一个会话）里读到的可能是旧值**；对一致性要求高的场景改 STATEMENT。

### 6.2 `cacheEnabled = true`（默认）

- 控制**二级缓存**的总开关，但还要 mapper 里写 `<cache/>` 才真正启用；
- 也就是说默认"允许但未启用"，这是很多"以为开了二级缓存其实没开"的原因。

### 6.3 `flushCache` / `useCache`

- `<select useCache="false">`：这条查询不进二级缓存（比如实时性要求高的数据）；
- `<insert/update/delete flushCache="true">`（默认）：执行后清空缓存，防止读到旧值；
- 注意：一级缓存不受 `useCache` 控制，只受 `flushCache` 与作用域控制。

### 6.4 `defaultExecutorType = SIMPLE`

- SIMPLE 每次新建 Statement，最稳；REUSE 复用 Statement（同 SQL 快，但状态管理复杂）；BATCH 适合批量写。
- 批量写场景必须显式用 `ExecutorType.BATCH`，并注意 `flushStatements()` 时机与自增主键回填的限制。

### 6.5 `defaultStatementTimeout`（默认无超时）

- 不设超时，慢 SQL 会一直占着连接，拖垮连接池；生产建议按接口设 3~10 秒，并与数据库侧 `max_execution_time` 双保险。

### 6.6 `mapUnderscoreToCamelCase = false`（默认）

- 默认关闭，意味着 `user_name` 不会自动映射到 `userName`；开启后省掉大量 `resultMap`，但要求数据库命名规范。

---

## 7. 版本演进

### 7.1 MyBatis 3.x 时间线

| 版本 | 变化 | 影响 |
|---|---|---|
| 3.0（2010） | 从 iBatis 更名，全面重写为注解/XML + 动态代理 | 当前架构定型 |
| 3.2 | 支持 `@SelectProvider` 等注解 SQL | 简单动态 SQL 可不用 XML |
| 3.4 | 增强 `Cursor`、`@Flush` | 流式查询与批处理体验改善 |
| 3.5 | 支持 Java 8 日期类型、Optional 返回、更多类型处理器 | 现代 Java 适配 |
| 3.5.13+ | 修复若干安全与兼容问题，支持 JDK 17 运行 | 新 JDK 可用 |
| 3.6（预览/规划） | 更现代的 API 与 JDK 适配 | 见官方仓库 |

### 7.2 与 Spring 集成

- `MyBatis-Spring` 提供 `SqlSessionTemplate`：内部用动态代理 + ThreadLocal 把 `SqlSession` 绑定到当前线程，**解决 SqlSession 非线程安全**的问题；
- `MapperScannerConfigurer` 扫描接口，注册成 Spring Bean（本质还是 MapperProxy）；
- Spring Boot 的 `mybatis-spring-boot-starter` 把 `SqlSessionFactory` 自动装配好。

### 7.3 JDK 版本相关

- 动态代理基于 `java.lang.reflect.Proxy`，JDK 8~21 行为一致；JDK 16+ 的强封装会影响反射访问某些内部类，MyBatis 3.5.6+ 做了适配；
- 记录类（record）作为参数/返回类型需要较新的 MyBatis 版本支持。

### 7.4 MyBatis-Plus 的演进

- 在 MyBatis 之上加了通用 CRUD、条件构造器、分页插件；
- 注意：它仍然是 MyBatis，`#{}`/`${}`、缓存、插件链的规则全部适用。

---

## 8. 亲手验证：日志、缓存、注入三组实验

> 说明：以下在 Spring Boot 3 + MyBatis 3.5 + MySQL 8 / H2 环境验证；不同版本日志格式略有差异，以实际输出为准。

### 8.1 打开 SQL 日志，观察完整链路

```yaml
mybatis:
  configuration:
    log-impl: org.apache.ibatis.logging.stdout.StdOutImpl
    local-cache-scope: session
```

调用一次查询，预期输出：

```
==>  Preparing: SELECT id, name, age FROM user WHERE id = ?
==> Parameters: 1(Long)
<==      Total: 1
```

这对应第 2.6 节的 `prepare` → `setParameters` → `handleResultSets`。

### 8.2 验证一级缓存：同一会话查两次

```java
try (SqlSession session = sqlSessionFactory.openSession()) {
    UserMapper mapper = session.getMapper(UserMapper.class);
    mapper.selectById(1L);   // 第一次：打印 Preparing/Parameters/Total
    mapper.selectById(1L);   // 第二次：无任何 SQL 日志
}
```

预期：第二次查询**没有任何 SQL 日志**。把两条语句放进两个 `openSession()`，则会打印两次——说明一级缓存是会话级的。

### 8.3 验证二级缓存：跨会话

```xml
<!-- UserMapper.xml -->
<cache/>   <!-- 默认 readWrite、LRU、512 个引用 -->
```

```java
// 会话 1
try (SqlSession s1 = factory.openSession()) {
    s1.getMapper(UserMapper.class).selectById(1L);   // 发 SQL
    s1.commit();                                     // 提交后才写入二级缓存
}
// 会话 2
try (SqlSession s2 = factory.openSession()) {
    s2.getMapper(UserMapper.class).selectById(1L);   // 命中二级缓存，无 SQL
}
```

注意：**不 commit 直接 close，第二次仍会发 SQL**，因为 `TransactionalCache` 没提交。这是验证"提交后才写缓存"的关键实验。

### 8.4 复现 SQL 注入（在测试库上做）

```xml
<select id="findByOwnerUnsafe" resultType="Account">
  SELECT id, owner, balance FROM account WHERE owner = '${owner}'
</select>
<select id="findByOwnerSafe" resultType="Account">
  SELECT id, owner, balance FROM account WHERE owner = #{owner}
</select>
```

```java
System.out.println(unsafe.findByOwnerUnsafe("' OR '1'='1").size());  // 预期：全表行数
System.out.println(safe.findByOwnerSafe("' OR '1'='1").size());      // 预期：0
```

日志会显示不安全写法把整段 payload 拼进 SQL；安全写法只有 `?` 占位。

---

## 9. 常见误区

| 错误说法 | 正确说法 |
|---|---|
| 「一级缓存默认关闭，要手动开」 | 一级缓存默认开启（`localCacheScope=SESSION`），只是同一会话才有意义 |
| 「二级缓存默认开启，配个 `<cache/>` 就行」 | 还要 `cacheEnabled=true`（默认已开）+ 实体可序列化；且默认是多表场景有脏读风险 |
| 「SqlSession 可以做成单例注入」 | 非线程安全，Spring 下用 `SqlSessionTemplate`（ThreadLocal 绑定） |
| 「`#{}` 万能，所有地方都用它」 | 动态表名/列名/`ORDER BY` 必须用 `${}`，但要用白名单；值用 `#{}` |
| 「一级缓存返回的是新对象」 | 返回的是缓存里的**同一个 List/对象引用**，调用方修改元素会污染缓存 |
| 「缓存命中率越高越好」 | 多表 join 的 namespace 互相不知道更新，命中越高越可能读到旧数据 |
| 「动态代理会调用接口默认实现」 | 走 `MapperProxy` 统一分派，接口 `default` 方法需要特别处理（3.5+ 支持有限） |
| 「插入后自增主键靠返回值」 | 要 `useGeneratedKeys="true" keyProperty="id"`，JDBC 回填到参数对象 |
| 「插件可以拦截 SqlSession」 | 只能拦 Executor/StatementHandler/ParameterHandler/ResultSetHandler 四类对象 |

---

## 10. 连续追问 Q&A

### Q1：`userMapper` 到底是什么对象？

是 `MapperProxyFactory` 生成的 JDK 动态代理对象。它的类名类似 `jdk.proxy2.$Proxy123`，实现了 `UserMapper` 接口，所有方法调用都转发到 `MapperProxy.invoke`。

### Q2：方法名怎么和 SQL 的 id 对上？

`MappedStatement` 的 id = 接口全限定名 + `.` + 方法名，`MapperMethod` 构造 `SqlCommand` 时用 `method.getDeclaringClass().getName() + "." + method.getName()` 拼出来。所以接口名或方法名改了，XML 里的 namespace/id 必须同步改，否则启动时报 `BindingException`。

### Q4：一级缓存和二级缓存的 key 一样吗？

本质都用 `CacheKey`，但作用域不同：一级在 `SqlSession`（更准确说在 `Executor`）里，二级在 `CachingExecutor` 里；二级键还包含 namespace。两个会话的一级缓存互不可见。

### Q5：为什么二级缓存要"提交后才写"？

如果查询后立即写入，而事务随后回滚，这条数据在数据库里根本不存在，别的会话读到就是脏数据。`TransactionalCache` 把写缓存的请求攒到 `commit` 时统一执行，`rollback` 时丢弃，保证缓存与数据库的可见性一致。

### Q6：一级缓存什么时候会读到旧数据？

同一个 SqlSession 里：先查询（缓存了结果），然后**另一个会话**改了数据库并提交，本会话再查同样的 SQL，仍会命中旧缓存。长事务/长会话场景要小心，必要时把 `localCacheScope` 改成 `STATEMENT` 或主动 `clearCache()`。

### Q7：为什么用 `PreparedStatement` 能防注入？

因为 SQL 结构在预编译时就固定了，参数通过协议单独发送给数据库，数据库只把它当值。无论参数里有什么引号、关键字、注释符，都不会改变已解析好的语法树。

### Q8：`${}` 在哪些场景非用不可？怎么保证安全？

动态表名（分表）、动态列名、`ORDER BY`/`LIMIT` 的字段部分。安全做法：把前端输入映射到固定枚举（白名单），绝不直接拼接；必要时用正则校验只允许 `[a-zA-Z_][a-zA-Z0-9_]*`。

### Q9：MyBatis 的插件是怎么挂到这条链上的？

`Configuration` 创建四大对象时调用 `interceptorChain.pluginAll(target)`，用 `Plugin.wrap` 生成动态代理。所以插件能拦 Executor（缓存前后）、StatementHandler（SQL 生成与执行）、ParameterHandler（设参）、ResultSetHandler（映射），形成"洋葱式"代理链。

### Q10：多个插件谁先执行？

`pluginAll` 按配置顺序依次包装：`t = p1.plugin(t); t = p2.plugin(t);`，后注册的在外层，调用时**先进入、后返回**。分页插件与 SQL 日志插件顺序不对，可能导致日志里看到的 SQL 与实际执行不一致。

### Q12：MyBatis 与 Spring 的事务怎么协作？

`SqlSessionTemplate` 把 `SqlSession` 绑定到当前线程；Spring 事务开启时，`SqlSession` 使用同一个 `Connection`，事务提交/回滚会同步 `SqlSession`（commit/rollback），并清空一级缓存。所以**事务边界与 SqlSession 生命周期要对齐**，否则会出现"提交了但缓存没清"或反之的问题。

---

## 11. 一张图总结

```
userMapper.selectById(1L)
   │
   ├─ MapperProxy.invoke           （动态代理：接住方法调用）
   │     └─ MapperMethod.execute   （SqlCommand 判断 SELECT/INSERT/...）
   │           └─ SqlSession.selectOne / selectList
   │                 └─ CachingExecutor.query      ← 二级缓存（namespace，提交后才写）
   │                       └─ BaseExecutor.query   ← 一级缓存（SqlSession，CacheKey）
   │                             └─ queryFromDatabase
   │                                   ├─ StatementHandler.prepare   → PreparedStatement
   │                                   ├─ ParameterHandler.setParameters → ? 赋值
   │                                   └─ ResultSetHandler.handleResultSets → 对象
   │
   └─ 返回 User

   #{}  → 变成 ?，预编译，值不参与语法（防注入）
   ${}  → 字符串直拼，参与语法（可注入，仅用于标识符 + 白名单）
```

---

## 12. 一句话复盘

> Mapper 接口靠 JDK 动态代理获得"实现"：`MapperProxy` 把方法翻译成 statementId，`MapperMethod` 分派动作，`SqlSession/Executor` 管缓存与执行，三个 Handler 分别负责建语句、设参数、映射结果。`#{}` 走预编译所以安全，`${}` 进语法所以危险；一级缓存是会话级、默认开，二级缓存是 namespace 级、提交后才写、多表场景慎用。

---

## 13. 自测题（先自己答，再看答案）

**1. `userMapper` 是哪个类的实例？方法调用最终进入哪个方法？**
答案：`MapperProxyFactory` 用 `Proxy.newProxyInstance` 生成的 JDK 动态代理对象；调用进入 `MapperProxy.invoke`，再转 `MapperMethod.execute`。

**2. 一级缓存和二级缓存分别在什么时候生效？**
答案：一级缓存同一 `SqlSession` + 相同 `CacheKey` 生效，默认 `SESSION` 作用域；二级缓存同一 namespace 跨会话生效，需要 `<cache/>` + `cacheEnabled=true`，且结果在事务 commit 后才写入。

**3. 为什么 `#{}` 能防 SQL 注入？**
答案：`#{}` 被编译成 `?` 占位符，参数通过 `PreparedStatement.setXxx` 单独传给数据库，只被当作值，不参与 SQL 语法解析。

**4. 一段 `${owner}` 的 mapper，传入 `' OR '1'='1` 会发生什么？**
答案：SQL 变成 `WHERE owner = '' OR '1'='1'`，条件恒真，返回全表数据；恶意输入还可以 `union select` 读取其他表。

**5. 为什么二级缓存在 `commit` 前不生效？用实验怎么验证？**
答案：`TransactionalCache` 把结果攒到 `entriesToAddOnCommit`，只有 commit 才刷入真正的缓存；实验：会话 1 查询后不 commit 直接 close，会话 2 再查同一条会重新发 SQL。

---

## 14. 关联文件

- 深一层（追问树 + 源码细节）：[MyBatis 原理](../../10-deep-dive/middleware/04-MyBatis原理.md)
- 相关精讲：[Kafka 零拷贝](./01-Kafka零拷贝.md)｜[TCP 三次握手四次挥手](../network/01-TCP三次握手四次挥手.md)
- 数据库侧原理：[MySQL 与 Redis（速查）](../../04-database/MySQL与Redis.md)
- 返回：[精讲索引](../00-索引.md)
