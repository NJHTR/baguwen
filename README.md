# 全栈 Web 开发面试知识库

> **以后端为主**的全栈面试备战资料库
> 主线技术栈：**Java + Spring Boot + MySQL + Redis + Kafka**，前端 Vue3 / ES6 补齐
> 建立日期：2026-11-12　|　状态：持续积累中

## 在线阅读（推荐）

**https://njhtr.github.io/baguwen/**

站点提供：左侧分类导航、关键词搜索（按 `/` 聚焦）、文内目录与滚动高亮、代码复制、上/下一篇串联。纯黑排版，无装饰元素。

> **新增笔记后怎么更新站点**：在仓库根目录执行 `pwsh -File tools/build-manifest.ps1` 重新生成 `manifest.json`，然后 `git add -A && git commit && git push`，Pages 会自动重新发布。
> 站点文件：`index.html`（入口）、`assets/style.css` + `assets/app.js`（样式与逻辑）、`manifest.json`（导航数据，机器生成）。

---

## 一、这个库是什么

一份**以后端为主**的面试资料：把 Java、Spring、MySQL、Redis、消息中间件、分布式、网络与运维这些常被追问的领域，拆成「一个知识点一个文件」，每个文件从一句话答案逐层追问到源码层。

| 维度 | 说明 |
|---|---|
| 覆盖范围 | 后端为主，前端只保留全栈面试确实会被问到的部分 |
| 内容形态 | 广度八股 14 篇 + 深度追问 55 篇，每篇含追问树与名词拆解表 |
| 使用目标 | 能答第一层不够，目标是**接得住连问十层** |
| 维护方式 | 纯 Markdown + 一个静态站点，新增笔记后重新生成 manifest 即可 |
| 无关内容 | 不放任何个人信息、简历内容与个人经历 |

**核心判断**：面试的胜负点不是"背得比别人多"，而是 **"项目讲得清楚 + 基础八股不翻车 + 手写题能写出来"**。系统设计只需到"能聊"的程度，不必到大厂高级岗深度。

---

## 二、怎么用这个库（三种用法）

### 用法 A：系统学习（日常，每天 1-2 小时）
按 [路线图](00-plan/路线图.md) 的顺序走，一个目录一个目录过。
每学完一个知识点，合上文件，**用自己的话口述一遍"60 秒版"**，说不出来就回去重读。

### 用法 B：查漏补缺（面试前 3 天）
只翻每个文件开头的 `> 面试权重` 和末尾的 `## 高频题库` 表格。
表格里的「答案要点」记不住 → 回到正文找对应知识点。

### 用法 C：模拟对练（每周 1-2 次）
打开 [模拟面试题库与流程](09-mock/模拟面试题库与流程.md)，让我（AI 面试官）按真实流程提问、追问、打分。
**这是所有准备动作里性价比最高的一项**——因为面试是"说"出来的，不是"看"出来的。

---

## 三、目录索引

| 目录 / 文件 | 内容 | 面试权重 | 建议投入 |
|---|---|---|---|
| [00-plan/路线图.md](00-plan/路线图.md) | 分阶段学习计划、每日任务表、进度追踪 | — | 先读 |
| [MAINTENANCE.md](MAINTENANCE.md) | **维护手册**：写 / 检查 / 发布 / 部署流程，脚本说明，故障排查 | — | 维护时看 |
| [01-js/JS核心八股.md](01-js/JS核心八股.md) | 闭包、this、原型链、事件循环、Promise、深浅拷贝、GC、ES6+、事件流 | 5/5 | 5 天 |
| [01-js/TypeScript与类型系统.md](01-js/TypeScript与类型系统.md) | 泛型、interface vs type、类型守卫、工具类型、Vue3 + TS 实战 | 5/5 | 2 天 |
| [02-vue/Vue3原理与对比.md](02-vue/Vue3原理与对比.md) | 响应式原理、ref/reactive、diff、生命周期、组件通信、Pinia、Vue vs React | 5/5 | 5 天 |
| [03-java/Java基础与并发.md](03-java/Java基础与并发.md) | 集合、HashMap、JVM、GC、线程池、synchronized、volatile、CAS、AQS | 5/5 | 6 天 |
| [03-java/SpringBoot与后端工程.md](03-java/SpringBoot与后端工程.md) | IoC/AOP、Bean 生命周期、事务传播、自动配置、MVC 流程、RESTful | 5/5 | 4 天 |
| [04-database/MySQL与Redis.md](04-database/MySQL与Redis.md) | B+ 树索引、事务隔离、MVCC、锁、SQL 优化、Redis 场景、缓存三件套 | 5/5 | 5 天 |
| [05-network/HTTP与浏览器.md](05-network/HTTP与浏览器.md) | HTTP 版本、缓存、CORS、Cookie/JWT、URL 到渲染、XSS/CSRF | 5/5 | 3 天 |
| [06-system-design/系统设计入门.md](06-system-design/系统设计入门.md) | 设计题答题框架、高频题（短链/秒杀/排行榜/消息推送） | 5/5 | 3 天 |
| [07-algorithm/算法路线与高频模板.md](07-algorithm/算法路线与高频模板.md) | 零基础 8 周刷题路线、十大专题模板、LeetCode 高频题 | 5/5 | 持续 |
| [07-algorithm/前端手写题30道.md](07-algorithm/前端手写题30道.md) | 防抖节流、深拷贝、Promise、bind、LRU 等 30 道 | 5/5 | 持续 |
| [08-project/项目复盘与简历.md](08-project/项目复盘与简历.md) | STAR 讲项目、简历模板、追问防守清单、亮点包装 | 5/5 | 3 天 |
| [09-mock/模拟面试题库与流程.md](09-mock/模拟面试题库与流程.md) | 真实面试流程、题库、评分表、对练脚本 | — | 每周 |
| **[10-deep-dive/00-索引.md](10-deep-dive/00-索引.md)** | **深度追问层：56 个知识点一人一文件，L1 到 HotSpot / InnoDB / 内核 / 协议逐层追问** | 5/5 | 第二轮 |
| [10-deep-dive/java/](10-deep-dive/java/) + [spring/](10-deep-dive/spring/) | 后端主战场：Java 底层 14 篇、Spring 6 篇 | 5/5 | 持续 |
| [10-deep-dive/mysql/](10-deep-dive/mysql/) + [redis/](10-deep-dive/redis/) | 存储层：MySQL 6 篇、Redis 5 篇 | 5/5 | 持续 |
| [10-deep-dive/distributed/](10-deep-dive/distributed/) + [network/](10-deep-dive/network/) + [ops/](10-deep-dive/ops/) | 分布式事务与一致性、TCP/TLS、Linux 排查与可观测性 | 4/5 | 第三轮 |

---

## 四、优先级排序（时间不够时按这个砍）

```
第一梯队（必拿分，砍不掉）
  Spring 事务与 IoC  >  HashMap 与集合  >  MySQL 索引与事务  >  Redis 缓存三件套
  >  线程池与并发  >  MyBatis 原理  >  项目复盘表达

第二梯队（拉开差距）
  JVM 与 GC  >  MySQL 三个日志与主从  >  Kafka 三件套  >  SpringMVC 请求链路
  >  SpringSecurity  >  TCP 与 TLS  >  分布式事务与限流  >  手写题前 15 道

第三梯队（锦上添花）
  CAP 与 Raft  >  Linux 性能排查  >  可观测性  >  分库分表  >  多级缓存
  >  ConcurrentHashMap 与 NIO  >  前端 JS 深度  >  LeetCode 简单题
```

> **一句话策略**：先保证"任何一场面试都不会因为基础题答不上来而挂"，再考虑拉开差距。

---

## 五、三阶段总览

| 阶段 | 目标 | 时长 | 交付物 |
|---|---|---|---|
| **阶段一：地基** | 后端三块（Java/Spring/存储）过第一遍，每题能说 60 秒 | 6-8 周 | 本库通读一遍 + 每章口述录音 |
| **阶段二：项目 + 手写** | 项目能扛 20 分钟深挖；手写题闭卷写出来 | 4 周 | 简历终稿 + 30 道手写题闭卷通过 |
| **阶段三：实战演练** | 模拟面试 10 场以上，形成肌肉记忆 | 持续 | 模拟面试评分表稳定 80 分以上 |

详见 [路线图](00-plan/路线图.md)。

---

## 六、进度追踪

> 每完成一项打 `[x]`，日期写后面。

### 前端
- [ ] JS 核心八股 通读 + 口述
- [ ] TypeScript 类型系统 通读
- [ ] Vue3 原理 通读 + 能画出响应式流程图
- [ ] HTTP 与浏览器 通读 + 能一条线讲完 URL 到渲染
- [ ] 手写题 1-15（基础档）闭卷
- [ ] 手写题 16-30（进阶档）闭卷

### 后端
- [ ] Java 集合与 HashMap 原理
- [ ] JVM 内存模型 + GC
- [ ] 并发（线程池/synchronized/volatile/CAS）
- [ ] Spring IoC + AOP + Bean 生命周期
- [ ] Spring 事务传播与失效场景
- [ ] SpringBoot 自动配置 + MVC 流程
- [ ] MySQL 索引与 B+ 树
- [ ] MySQL 事务隔离与 MVCC
- [ ] Redis 数据结构与缓存三件套

### 综合
- [ ] 系统设计框架 + 2 道高频题
- [ ] 项目 STAR 稿定稿（能讲 3 分钟版 / 10 分钟版）
- [ ] 简历终稿
- [ ] 算法简单题 60 道
- [ ] 模拟面试 第 1 场
- [ ] 模拟面试 第 5 场
- [ ] 模拟面试 第 10 场

### 深度追问层（56 个知识点，见 [10-deep-dive/00-索引.md](10-deep-dive/00-索引.md)）
- [x] Java 底层 14 篇（HashMap/String/集合/泛型反射/JVM/GC/类加载/线程池/synchronized/volatile-CAS-AQS/ThreadLocal/ConcurrentHashMap/NIO/JVM调优）
- [x] Spring 6 篇（IoC/AOP/事务/自动配置/MVC 链路/Security）
- [x] MySQL 6 篇（B+树/MVCC/锁/SQL优化/三大日志/分库分表）
- [x] Redis 5 篇（编码/持久化/缓存三件套/分布式锁/多级缓存）
- [x] 消息与中间件 7 篇（Kafka×3/MyBatis/SSE/WebSocket/Docker）
- [x] 分布式 3 篇（分布式事务/CAP与Raft/限流熔断）
- [x] 网络协议 2 篇（TCP/TLS）
- [x] 运维与可观测 2 篇（Linux 排查/可观测性）
- [x] 后端优化 2 篇（接口优化/异步削峰）
- [x] 前端 JS/ES6 9 篇（全栈补齐用）
- [ ] 每个文件能讲到 L4 追问树的第 7 层以上

---

## 七、使用约定

1. **本库所有文件都是"面试口播导向"**：每知识点含「一句话答案 / 原理展开 / 60 秒版 / 追问陷阱」四段。
2. **不要只读不练**：每个知识点读完后必须合上书口述，这是唯一能转化为面试能力的方式。
3. **项目是最高优先级**：面试官 50% 的时间在问项目。项目讲不好，八股全对也过不了。
4. **算法从零开始不丢人**：目标是 LeetCode 简单题稳定 + 中等题常见套路，不是刷 500 题。
5. 有疑问的地方在文件里标注 `> 待确认待确认`，模拟面试时集中问。

---

## 八、相关文件

- 学习计划：[00-plan/路线图.md](00-plan/路线图.md)
- 项目与简历：[08-project/项目复盘与简历.md](08-project/项目复盘与简历.md)
- 模拟面试：[09-mock/模拟面试题库与流程.md](09-mock/模拟面试题库与流程.md)
