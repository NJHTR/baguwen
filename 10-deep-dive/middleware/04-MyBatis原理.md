# MyBatis 原理（SqlSession / Executor / 动态代理 / 缓存 / 插件）

> 面试权重：5/5　｜　追问深度：**L5（MapperProxy 源码调用链 / 四大对象代理链 / CacheKey）**
> 一句话定位：MyBatis 是"把 JDBC 模板代码抽掉、把 SQL 还给你"的半自动 ORM。所有魔法都在一条链上：**`Configuration` 持有 `MappedStatement` → Mapper 接口靠 `MapperProxy` 动态代理转发 → `SqlSession` 委派 `Executor` → `StatementHandler` 建 PreparedStatement → `ParameterHandler` 设参 → `ResultSetHandler` 映射结果**，插件就在这四类对象外面套 JDK 动态代理。

**本文件用法**：先记熟 L2 的调用链一张图（面试 80% 的问题挂在这张图上），再逐层追问源码。
[返回深度追问索引](../00-索引.md)

---

## L1 一句话答案（10 秒能说出口）

`SqlSessionFactoryBuilder` 解析 XML 得到 `Configuration`，`SqlSessionFactory` 用它创建 `SqlSession`（内含 `Executor`）。调用 Mapper 接口时，`MapperProxy` 用 JDK 动态代理把方法转成 `MapperMethod.execute()`，按 `SqlCommand` 决定调 select/insert/update/delete；`SqlSession` 委托 `Executor` 查一二级缓存，未命中走 `StatementHandler` 建 `PreparedStatement`、`ParameterHandler` 用 `#{}` 安全设参、`ResultSetHandler` 映射结果。插件（`Interceptor`）在创建这四类对象时用 `Plugin.wrap` 逐层包代理。

---

## L2 原理层：一条 SQL 的完整链路

### 2.1 组件与创建顺序

```
mybatis-config.xml ─► SqlSessionFactoryBuilder.build()
                        └── XMLConfigBuilder.parse() ─► Configuration
                              ├── settings / typeHandlers / plugins / environments
                              ├── mappers 扫描 ─► MapperRegistry（接口 → MapperProxyFactory）
                              └── mapper XML ─► Map<String, MappedStatement>
SqlSessionFactory.openSession()
  └── Configuration.newExecutor()
        ├── SimpleExecutor / ReuseExecutor / BatchExecutor
        ├── cacheEnabled 时外层包 CachingExecutor（二级缓存）
        └── InterceptorChain.pluginAll(executor)   ← 插件在此套代理
```

### 2.2 执行时序（背这张图）

```
mapper.getUserById(1L)
 └─ MapperProxy.invoke：Object 方法直接反射，否则 MapperMethod.execute
     ├─ SqlCommand：statementId = 接口全名 + 方法名，commandType = SELECT
     ├─ MethodSignature：返回 List/Map/void、是否 RowBounds/ResultHandler
     └─ SELECT → sqlSession.selectOne → CachingExecutor(二级缓存)
          └─ BaseExecutor.query → localCache(一级缓存)
               └─ queryFromDatabase → StatementHandler.prepare
                    → ParameterHandler.setParameters → ps.execute()
                    → ResultSetHandler.handleResultSets → List<T>
```

- 四种 `Executor`：`SimpleExecutor`（每次新建 Statement）、`ReuseExecutor`（按 SQL 复用 Statement）、`BatchExecutor`（`addBatch` 攒批）、`CachingExecutor`（装饰器，二级缓存）；`Configuration` 全局唯一，存 `mappedStatements`、`resultMaps`、`caches`、`typeHandlerRegistry`、`interceptorChain`、`mapperRegistry`。
- `MappedStatement`：一条 SQL 的全部信息——`sqlSource`、`statementType`、`resultMaps`、`keyGenerator`、`useCache`、`flushCache`、`timeout`。

### 2.3 `#{}` vs `${}`（SQL 注入必考）

| | `#{}` | `${}` |
|---|---|---|
| 底层 | 生成 `?`，`PreparedStatement.setXxx()` 设参 | 字符串直接拼进 SQL 文本 |
| 安全 | **防注入**（参数被当数据） | **有注入风险**（参数被当语法） |
| 类型 | 走 `TypeHandler` 转换 | 原样拼，靠 `toString()` |
| 场景 | 所有参数值 | 动态表名/列名/order by 字段（必须白名单） |

```xml
<!-- 正确：安全：值是 ? -->
<select id="findByName" resultType="User">SELECT * FROM user WHERE name = #{name}</select>
<!-- 注意 只能白名单校验后的标识符 -->
<select id="findByOrder" resultType="User">
  SELECT * FROM user
  <choose>
    <when test="orderBy == 'age'">ORDER BY age</when>
    <otherwise>ORDER BY id</otherwise>
  </choose>
</select>
```

### 2.4 一级缓存（SqlSession 级）

- 位置：`BaseExecutor.localCache`（`PerpetualCache`，HashMap），默认 `localCacheScope=SESSION`。
- 命中条件：**同一 SqlSession + 同一 statementId + 同一 SQL + 同一参数 + 同一 RowBounds + 同一 Environment**，即 `CacheKey` 相等。
- 失效：`commit()/rollback()`、任意增删改（`flushCache=true` 清整个 localCache）、`clearCache()`、`localCacheScope=STATEMENT`。
- 坑：**脏读**（别的会话改了库，本会话提交前仍读旧值）；缓存的是 `List` 引用本身，业务改元素会污染缓存；分页/动态 SQL 让 `CacheKey` 变化，命中率下降。

### 2.5 二级缓存（namespace 级，跨 SqlSession）

- 开启：mapper 里写 `<cache/>` + 实体可序列化（默认 `readWrite`）。
- 架构：`CachingExecutor` → `TransactionalCacheManager` → 每个 namespace 一个 `TransactionalCache`（装饰 `PerpetualCache`）。
- **`TransactionalCache` 为什么存在**：查询结果先攒在 `entriesToAddOnCommit`，**只有事务 commit 才真正写进缓存**，回滚则丢弃；否则未提交的脏数据会被其他会话读到。
- **脏读风险（生产建议关）**：① 多表 join 只清自己 namespace；② 多 namespace 写同一张表不联动；③ 集群下各节点本地缓存不一致。建议 `cacheEnabled=false`，只读字典表用 `readOnly=true`，跨节点用 Redis 实现 MyBatis `Cache` 接口。

### 2.6 插件机制：四大对象 + 洋葱模型

```java
@Intercepts({@Signature(type = Executor.class, method = "query",
    args = {MappedStatement.class, Object.class, RowBounds.class, ResultHandler.class})})
public class SqlCostInterceptor implements Interceptor {
    public Object intercept(Invocation invocation) throws Throwable {
        long start = System.nanoTime();
        try { return invocation.proceed(); }               // 放行到内层
        finally { if (System.nanoTime() - start > 500_000_000L) log.warn("SLOW SQL"); }
    }
    public Object plugin(Object target) { return Plugin.wrap(target, this); }
    public void setProperties(Properties p) { }
}
```

- 能拦：`Executor`、`StatementHandler`、`ParameterHandler`、`ResultSetHandler`；**拦不到 `SqlSession` 与 `MapperProxy`**。
- `InterceptorChain.pluginAll` 按配置顺序 `target = interceptor.plugin(target)`，**后注册的在外层 → 进入时先执行、返回时后执行**（洋葱模型）。PageHelper 分页插件与 SQL 日志插件顺序不对会改坏 SQL。

### 2.7 延迟加载与主键回填

- `lazyLoadingEnabled=true` + `aggressiveLazyLoading=false`（3.x 默认）：访问 `association`/`collection` 属性才发子查询，靠 JAVASSIST/CGLIB 生成实体代理拦截 getter；`aggressive=true` 时访问任意方法就加载全部懒加载属性（易 N+1）。
- `useGeneratedKeys="true" keyProperty="id"`：MySQL 自增走 JDBC `getGeneratedKeys()` 回填；Oracle 用 `<selectKey order="BEFORE">SELECT seq.NEXTVAL FROM dual</selectKey>`；批量取回主键受限。

---

## L3 底层层：MapperProxy 与动态 SQL 编译

### 3.1 Mapper 接口为什么能直接调用（无实现类）

```java
// MapperRegistry.getMapper → MapperProxyFactory.newInstance
return (T) Proxy.newProxyInstance(mapperInterface.getClassLoader(),
        new Class[]{mapperInterface}, new MapperProxy<>(sqlSession, mapperInterface, methodCache));
// MapperProxy.invoke
if (Object.class.equals(method.getDeclaringClass())) return method.invoke(this, args);
return cachedMapperMethod(method).execute(sqlSession, args);
```

`MapperMethod` 由 `SqlCommand`（statementId + 类型）与 `MethodSignature`（返回类型、参数、RowBounds/ResultHandler）组成；INSERT/UPDATE/DELETE 返回影响行数并按方法返回类型转换。

### 3.2 动态 SQL 与 OGNL

- `<if test="...">`、`<where>`、`<set>`、`<trim>`、`<foreach>`、`<choose>`、`<bind>` 在解析期被 `SqlSourceBuilder` 处理成 `BoundSql`（SQL 文本 + `ParameterMapping` 列表）；`#{}` → `?`，`${}` 由 `TextSqlNode` 运行时直接替换。
- `test` 用 **OGNL** 表达式：`null` 判断要注意 `!= null and != ''`；**数字与字符串比较**（`'1' == 1`）在 OGNL 里可能恒真/恒假，字符串要写 `"1"`；`<foreach>` 的 `collection` 名与 `@Param` 要对应。

---

## L4 追问树（面试官一路往下问，你能撑到第几层？）

> 规则：第 1-3 层必备，4-6 层拉开差距，7 层以后是加分。

### 第 1 层｜MyBatis 和 JDBC、Hibernate 的区别？
**答**：JDBC 是模板代码地狱（连接、Statement、结果映射全靠手写）；Hibernate 是全自动 ORM（SQL 自动生成、难优化）；MyBatis 是**半自动**：SQL 你写、映射它做，保有优化控制力又省样板代码，适合互联网场景。

### 第 2 层｜一次查询的完整调用链？
**答**：Mapper 方法 → `MapperProxy.invoke` → `MapperMethod.execute` → `SqlSession.selectOne` → `CachingExecutor`（二级缓存）→ `BaseExecutor.query`（一级缓存）→ `SimpleExecutor.doQuery` → `StatementHandler.prepare` + `ParameterHandler.setParameters` → `PreparedStatement.execute` → `ResultSetHandler.handleResultSets` → 返回对象。

### 第 3 层｜Mapper 接口没有实现类，为什么能调用？
**答**：解析 `<mapper>` 时把接口注册到 `MapperRegistry`，`getMapper()` 用 **JDK 动态代理**生成实现：`MapperProxy` 实现 `InvocationHandler`，`invoke` 里按方法签名得到 `statementId`（接口全限定名+方法名），再调 `MapperMethod.execute` 分派到 `SqlSession` 的 select/insert/update/delete。

### 第 4 层｜`MapperMethod` 怎么知道该调 select 还是 insert？
**答**：`SqlCommand` 从 `MappedStatement.getSqlCommandType()` 拿 SELECT/INSERT/UPDATE/DELETE/FLUSH；`MethodSignature` 记录返回类型：返回 `List` 走 `selectList`、返回单对象走 `selectOne`（多于 1 条抛 `TooManyResultsException`）、`void` 不取结果、`Optional` 会包装。

### 第 5 层｜`#{}` 和 `${}` 的区别？SQL 注入怎么发生？
**答**：`#{}` 编译成 `?` 用 `PreparedStatement` 设参，参数永远当**数据**；`${}` 直接字符串替换，参数被当**语法**——`WHERE name='${name}'` 传 `' OR '1'='1` 就变成永真。唯一该用 `${}` 的是动态表名/列名/排序字段，且必须白名单枚举。

### 第 6 层｜一级缓存什么时候失效？有什么坑？
**答**：默认 SqlSession 级。失效：commit/rollback、任意增删改（清整个 localCache）、`clearCache()`、`localCacheScope=STATEMENT`。坑：同会话内读到别人已改的数据（脏读）；缓存 List 引用，业务改元素污染缓存；长会话尤其危险。

### 第 7 层｜二级缓存怎么实现？`TransactionalCache` 为什么要"提交后才写"？
**答**：`CachingExecutor` 包在 `BaseExecutor` 外，namespace 级缓存（`PerpetualCache` + `TransactionalCache` 装饰）。查询结果先放 `entriesToAddOnCommit`，`commit()` 才刷进真正缓存、`rollback()` 丢弃——否则事务回滚后这条数据根本不存在，别的会话会读到脏数据。

### 第 8 层｜为什么生产环境建议关二级缓存？
**答**：按 namespace 失效，多表 join 不知道别的表被改了；多节点是本地缓存、数据不一致；更新只能整 namespace 清空、命中率低；还要实体可序列化。所以要么 `cacheEnabled=false`，要么只给只读字典表开，跨节点用 Redis 实现 `Cache`。

### 第 9 层｜插件机制怎么实现的？能拦什么？
**答**：`Interceptor` + `@Intercepts/@Signature` 声明拦截点；创建四大对象时 `interceptorChain.pluginAll(target)` 调 `Plugin.wrap` 返回 **JDK 动态代理**，代理 `invoke` 里签名匹配就调 `intercept(Invocation)`，否则 `invocation.proceed()`。能拦 Executor/StatementHandler/ParameterHandler/ResultSetHandler，拦不到 SqlSession/MapperProxy。

### 第 10 层｜多个插件的执行顺序？
**答**：洋葱模型。`pluginAll` 按配置顺序依次包：`t = p1.wrap(t); t = p2.wrap(t);`，**p2 在最外层、先进入后返回**；`proceed()` 向内传递。分页、SQL 日志、多租户插件常同时存在，顺序会影响最终 SQL，真实事故来源。

### 第 11 层｜延迟加载怎么实现？`useGeneratedKeys` 怎么回填主键？
**答**：延迟加载给实体生成代理（JAVASSIST/CGLIB）拦截关联属性 getter，首次访问才查；`aggressiveLazyLoading=true` 时任意方法触发全量加载，容易 N+1。主键回填：`useGeneratedKeys` 让 JDBC 带 `RETURN_GENERATED_KEYS`，插入后 `getGeneratedKeys()` 写回参数对象；Oracle 无自增用 `selectKey` 预生成。

### 第 12 层（终局）｜从 `mapper.getUser()` 到返回对象，代理链在哪几处生效？
**答**：① `MapperProxy`（JDK 代理，注册时创建）拦截接口方法 → `MapperMethod.execute`；② `CachingExecutor` 是 `Executor` 装饰器（非插件），先查二级缓存；③ 插件代理在 `newExecutor` 时由 `pluginAll` 套在 `Executor` 外，所以 `@Signature(type=Executor.class)` 能看到原始参数与结果；④ `BaseExecutor.doQuery` 创建 `StatementHandler` 时又 `pluginAll` 一次，故 StatementHandler 插件更内层；⑤ `ParameterHandler`/`ResultSetHandler` 由 StatementHandler 创建，再各自 `pluginAll`。**四类对象各套一层代理 = 四个切入点，`proceed()` 逐层向内，任一层异常沿链回传，计时/日志插件必须放 finally。**

---

## L5 名词拆解表（每个名词都拆开）

| 名词 | 是什么 | 为什么存在 | 面试追问点 |
|---|---|---|---|
| `SqlSessionFactory` | 全局工厂（单例） | 创建 SqlSession、持有 Configuration | 与 Configuration 关系 |
| `SqlSession` | 一次会话，**非线程安全** | 会话级缓存/事务/执行入口 | Spring 下 SqlSessionTemplate 如何保证安全 |
| `Executor` | Simple/Reuse/Batch + Caching | 缓存、批处理、语句复用策略 | `executorType` 怎么配、批量为何快 |
| `StatementHandler` | 创建/执行 PreparedStatement | 隔离 JDBC 语句细节 | Routing 三种实现、分页插件切入点 |
| `ParameterHandler` | 按 TypeHandler 把参数设进 `?` | `#{}` 的落地点 | 为什么能防注入 |
| `ResultSetHandler` | ResultSet → 对象/集合 | 自动映射 + resultMap | 下划线转驼峰、嵌套映射 |
| `Configuration` / `MappedStatement` | 全局元数据容器 / 一条 SQL 描述 | 语句 id → SQL/缓存策略 | `useCache`、`flushCache` 的影响 |
| `MapperProxy` / `MapperMethod` | 接口动态代理 / 方法分派器 | 免写实现类、把方法翻译成 SqlSession 动作 | Object 方法为何特殊处理 |
| `CacheKey` | 一级缓存键（statementId+SQL+参数+RowBounds） | 保证"同样查询"才命中 | 分页/动态 SQL 为何降低命中率 |
| `TransactionalCache` | 提交才写入的缓存装饰器 | 防回滚后脏数据进二级缓存 | entriesToAddOnCommit |
| `Interceptor`/`Plugin.wrap` | 插件与代理包装 | 无侵入扩展四大对象 | 洋葱顺序、能拦/不能拦什么 |

---

## 代码验证

```xml
<!-- 1) 全局配置：关二级缓存、一级缓存缩到 STATEMENT -->
<settings>
  <setting name="cacheEnabled" value="false"/>
  <setting name="localCacheScope" value="STATEMENT"/>
  <setting name="lazyLoadingEnabled" value="true"/>
  <setting name="aggressiveLazyLoading" value="false"/>
</settings>

<!-- 2) 同一 statementId 下 #{} 与 ${} 对比 -->
<select id="search" resultType="User">
  SELECT id, name, age FROM user
  WHERE name LIKE CONCAT('%', #{keyword}, '%')
  <if test="orderBy != null and orderBy != ''">
    ORDER BY ${orderBy}     <!-- 只能白名单校验后的字段名 -->
  </if>
</select>
```

```java
// 3) 一级缓存验证：同一 SqlSession 两次相同查询只发一条 SQL
try (SqlSession session = sqlSessionFactory.openSession()) {
    UserMapper mapper = session.getMapper(UserMapper.class);
    mapper.getById(1L);                    // 发 SQL
    mapper.getById(1L);                    // 命中 localCache，不发 SQL
    mapper.updateAge(1L, 20);              // flushCache 清空 localCache
    mapper.getById(1L);                    // 重新发 SQL
}

// 4) 注册插件（Java 配置）
@Bean
public ConfigurationCustomizer slowSqlCustomizer() {
    return cfg -> cfg.addInterceptor(new SqlCostInterceptor());
}
```

```sql
-- 验证 #{} 防注入：MyBatis 日志里应是 ?
-- Preparing: SELECT id FROM user WHERE name = ?  /  Parameters: 张三(String)
```

---

## 高频错误（面试官最爱抓的）

| 错误说法 | 正确说法 |
|---|---|
| 「SqlSession 线程安全，可注入成单例」 | 非线程安全，Spring 用 `SqlSessionTemplate`（ThreadLocal + 代理） |
| 「二级缓存默认开启」 | `cacheEnabled=true` 但需 mapper 写 `<cache/>` 才生效 |
| 「二级缓存安全，团队都在用」 | 多表/多 namespace 脏读风险高，生产一般关或只读表用 |
| 「`#{}` 和 `${}` 只是写法不同」 | `?` 预编译 vs 字符串拼接；`${}` 有注入风险 |
| 「一级缓存就是 Map，没坑」 | 缓存对象/List 引用，业务改元素会污染缓存 |
| 「插件能拦 SqlSession」 | 只能拦 Executor/StatementHandler/ParameterHandler/ResultSetHandler |
| 「插件按配置顺序执行」 | 洋葱模型，后注册的在外层先执行 |

---

## 关联文件

- 数据库索引与事务：[MySQL与Redis](../../04-database/MySQL与Redis.md)
- Spring 集成与事务边界：[SpringBoot与后端工程](../../03-java/SpringBoot与后端工程.md)
- 项目落点：报告平台的 PostgreSQL 数据访问层（一级缓存/批量插入/动态 SQL 都是真实场景）

> **自测标准**：能白板画出 MapperProxy → Executor → StatementHandler → ResultSetHandler 全链路、能说清 `#{}` 与 `${}` 底层差异、能解释二级缓存为何"提交后才写"、能说出插件四点切入与洋葱顺序，算过关。
