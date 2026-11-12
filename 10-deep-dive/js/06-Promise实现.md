# Promise 手写实现（Promise Implementation）

> 面试权重：5/5　｜　追问深度：**L5（Promises/A+ 规范 + PromiseReactionJob）**
> 一句话定位：Promise 是一个**状态机 + 回调队列**。手写它不是为了造轮子，而是为了证明你理解「then 为什么返回新 Promise」「thenable 怎么同化」「错误如何冒泡」。

**本文件用法**：先看 L2 的链式规则，再对着 L3 的规范内部槽手写一遍。**能默写出 `resolvePromise` 的自引用与 thenable 分支，这题就稳了。**
[返回深度追问索引](../00-索引.md)

---

## L1 一句话答案（10 秒能说出口）

Promise 是只有 `pending → fulfilled / rejected` 单向变化的状态机；`then` 注册回调并返回**新的 Promise**，回调通过微任务异步执行；返回 thenable 会被递归同化，抛错会让派生 Promise 进入 rejected，从而实现链式调用和错误冒泡。

---

## L2 原理层：then 的规则与链式模型

**Promises/A+ 对 `then` 的硬性要求**：
1. `then` 必须返回新 Promise（同一 Promise 无法重置状态，链式靠"新对象"）。
2. `onFulfilled/onRejected` 必须异步执行（规范用平台任务队列，浏览器/Node 里是微任务）。
3. 回调返回值 `x` 要经 `[[Resolve]](promise2, x)` 处理：普通值 → resolve；thenable → 递归同化；抛错 → reject。
4. `then` 可对同一 Promise 多次调用，回调按注册顺序逐个执行。
5. 回调不是函数时透传（值或错误原样传给下一个）。

```js
Promise.resolve(1)
  .then((v) => v + 1) // 返回 2
  .then((v) => { throw new Error('boom') }) // 抛错 → 下游 rejected
  .catch((e) => console.log('捕获', e.message)) // boom
  .finally(() => console.log('finally')) // 不影响结果
```

**链式模型**：

```
p1 ──then(onF)──► p2 ──then(onF)──► p3
      │                │
      └─ 回调返回 v     └─ v 传给下一个 onF
         或抛错 → p2 rejected → 跳过 onF、走下一个 onRejected
```

`catch` 等价 `then(undefined, onRejected)`，`finally` 不改变结果但会等待回调返回的 Promise。

---

## L3 底层层：规范内部槽与 job 队列

### 3.1 规范里 Promise 的四个内部槽

| 内部槽 | 作用 |
|---|---|
| `[[PromiseState]]` | `pending` / `fulfilled` / `rejected` |
| `[[PromiseResult]]` | 敲定值或拒绝原因 |
| `[[PromiseFulfillReactions]]` | pending 时注册的 then 成功回调列表 |
| `[[PromiseRejectReactions]]` | pending 时注册的 then 失败回调列表 |

`resolve` 后状态改一次即锁定，再调用被忽略——这是"不可逆状态机"的规范依据。

### 3.2 then 的真实流程：`PerformPromiseThen`

1. 创建派生 Promise 的 capability（`NewPromiseCapability`，记住它的 resolve/reject）；
2. 若当前 Promise 已敲定：创建 `PromiseReactionJob`，**压入微任务队列**，job 里调用对应 handler，并用 capability 结算派生 Promise；
3. 若还在 pending：把 reaction 记录进 `[[PromiseFulfillReactions]]` / `[[PromiseRejectReactions]]`，等敲定时再逐个入队 job。

所以 `then` 的回调"异步"不是 setTimeout，而是规范定义在 **job queue（浏览器/V8 里就是微任务队列）** 上执行。

### 3.3 thenable 同化与多出来的 tick

`PromiseResolve(C, x)`：如果 `x` 是对象且 `x.then` 可调用，则新建 Promise 并 `EnqueueJob("PromiseResolveThenableJob", ...)`，在这个 job 里调用 `x.then(resolve, reject)`。

- 这解释了 `Promise.resolve(thenable)` 比 `Promise.resolve(1)` **多一个微任务 tick**；
- 也解释了「thenable 的 then 被调用时是异步的」；
- 手写实现里必须用 `called` 标志防止 thenable 重复调用 resolve/reject。

### 3.4 V8 实现

- Promise 实例对应 `JSPromise`，状态和 reaction 链存在对象内；`PromiseReactionJob` 与 `PromiseResolveThenableJob` 是内建（Torque 实现）。
- 两个 job 都通过 `MicrotaskQueue` 执行，所以微任务饥饿同样会阻塞 Promise 链。
- 未处理的 rejected Promise 由 V8/浏览器在微任务清空后检查并触发 `unhandledrejection`。

---

## L4 追问树（面试官一路往下问，你能撑到第几层？）

> 规则：从上往下问。**第 1-3 层必备，第 4-6 层拉开差距，第 7 层以后加分。**

### 第 1 层｜Promise 有哪几种状态？能反悔吗？
**答**：pending、fulfilled、rejected；只能从 pending 单向变一次，之后调用 resolve/reject 都被忽略。

### 第 2 层｜then 为什么返回新 Promise？
**答**：状态不可逆，原 Promise 敲定后不能再变成新的结果；链式调用需要每一步都有独立的状态和结果，所以 then 内部 `NewPromiseCapability` 创建新 Promise。

### 第 3 层｜then 里 return 一个 Promise 会怎样？
**答**：会递归同化：外层的 resolve 收到 thenable 后，等内层 Promise 敲定，再把它的状态和值透传给派生 Promise；链式会自动"扁平化"，不会出现嵌套 Promise 值。

### 第 4 层｜then 回调为什么是异步的？
**答**：规范要求回调进 job queue 执行；浏览器中 job 即微任务，保证回调在同一个同步代码块之后、渲染之前执行，且顺序可预期。

### 第 5 层｜错误怎么冒泡？catch 后面还能 then 吗？
**答**：reject 沿链条向后传递，遇到 onRejected 被消费，否则继续向后；catch 也返回 Promise，所以后面可以继续 then，此时值变成 catch 的返回值。

### 第 6 层｜thenable 是什么？`Promise.resolve(thenable)` 为什么要多一个 tick？
**答**：带 `then` 方法的对象/函数；同化需要先入队 `PromiseResolveThenableJob` 再调用 `then`，所以比普通值多一个微任务。

### 第 7 层｜手写 then 最容易错的地方？
**答**：① 忘记防自引用（`then` 返回自己）；② 没保证只 settle 一次；③ thenable 的 then 可能同步/异步、可能重复调用；④ 回调抛错没转成 reject；⑤ 回调不是函数时没做透传。

### 第 8 层｜手写 all / allSettled / race / any 的差异？
**答**：all 计数 + 结果按索引入位，一败即败，空数组立即 resolve；allSettled 用 then 把每个结果映射成 `{status, value/reason}`；race 第一个敲定就结算；any 第一个成功，全败抛 `AggregateError`。

### 第 9 层｜为什么 `await` 能捕获 rejected Promise？
**答**：`await` 本质对 Promise 调 `PerformPromiseThen` 注册了 reject 续体，续体里用 `throw` 把拒绝原因抛回 async 函数，于是被 try/catch 捕获——不是 await 特殊，是 then 的 reject 分支。

### 第 10 层（终局）｜从 `p.then(f)` 到 `f` 执行，V8 内部发生了什么？
**答**：`PerformPromiseThen` 创建 capability 和 reaction，已敲定则生成 `PromiseReactionJob`；job 被压入 isolate 的 `MicrotaskQueue`。调用栈清空后微任务 checkpoint 取 job，执行 handler `f`，异常或返回值经 capability 的 resolve/reject 结算派生 Promise；返回 thenable 时再入队 `PromiseResolveThenableJob` 继续同化。

---

## L5 名词拆解表（"每个名词都拆开"）

| 名词 | 是什么 | 为什么存在 | 面试追问点 |
|---|---|---|---|
| 状态机 | 有穷状态 + 转移规则 | 保证结果只敲定一次 | 状态不可逆 |
| thenable | 有 `then` 方法的对象 | 兼容第三方/类 Promise 实现 | 同化过程 |
| capability | 一个 Promise 及其 resolve/reject | then 创建派生 Promise 要能结算 | 与 executor 的区别 |
| `[[PromiseState]]` | 规范内部槽 | 定义状态机 | 为什么不能改回 pending |
| PromiseReaction | 注册的回调 + capability 记录 | pending 时暂存回调 | 敲定后如何触发 |
| job queue | 规范的任务队列 | then 回调异步 | 浏览器里是微任务 |
| `PromiseResolveThenableJob` | 同化 thenable 的 job | 兼容 thenable | 多一个 tick |
| `resolvePromise` | 手写的同化函数 | 处理返回值/thenable/自引用 | 循环引用检测 |
| 透传 | 回调不是函数时原值/原错误下传 | 支持 `.catch` 等简写 | `then(null, fn)` |
| 错误冒泡 | reject 沿链向后传 | 集中处理异步错误 | catch 后还能 then |
| `AggregateError` | 多个错误的聚合错误 | `Promise.any` 全败时报告 | any vs race |
| `unhandledrejection` | 未处理拒绝的全局事件 | 兜底未捕获错误 | 如何全局监听 |

---

## 代码验证（打开浏览器控制台逐条跑，验证理解）

```js
// ===== 先手写一个符合 A+ 核心规则的 Promise =====
const PENDING = 'pending', FULFILLED = 'fulfilled', REJECTED = 'rejected'

function resolvePromise(promise, x, resolve, reject) {
  if (promise === x) return reject(new TypeError('循环引用'))
  if (x && (typeof x === 'object' || typeof x === 'function')) {
    let called = false
    try {
      const then = x.then
      if (typeof then === 'function') {
        then.call(
          x,
          (y) => { if (called) return; called = true; resolvePromise(promise, y, resolve, reject) },
          (r) => { if (called) return; called = true; reject(r) },
        )
        return
      }
    } catch (e) {
      if (called) return
      called = true
      return reject(e)
    }
  }
  resolve(x)
}

class MyPromise {
  constructor(executor) {
    this.state = PENDING
    this.value = undefined
    this.handlers = []
    const resolve = (value) => this.settle(FULFILLED, value)
    const reject = (reason) => this.settle(REJECTED, reason)
    try { executor(resolve, reject) } catch (e) { reject(e) }
  }
  settle(state, value) {
    if (this.state !== PENDING) return
    this.state = state
    this.value = value
    this.handlers.splice(0).forEach((h) => queueMicrotask(h))
  }
  then(onFulfilled, onRejected) {
    const next = new MyPromise((resolve, reject) => {
      const run = () => {
        try {
          if (this.state === FULFILLED) {
            resolvePromise(next, onFulfilled ? onFulfilled(this.value) : this.value, resolve, reject)
          } else if (onRejected) {
            resolvePromise(next, onRejected(this.value), resolve, reject)
          } else {
            reject(this.value)
          }
        } catch (e) { reject(e) }
      }
      if (this.state === PENDING) this.handlers.push(run)
      else queueMicrotask(run)
    })
    return next
  }
  catch(onRejected) { return this.then(undefined, onRejected) }
}

// ===== 验证（每段单独运行，一起跑输出会交错） =====
// 1. 链式 + 异步
new MyPromise((resolve) => setTimeout(() => resolve(1), 10))
  .then((v) => v + 1)
  .then((v) => console.log('链式结果', v)) // 链式结果 2

// 2. 错误冒泡 + catch 穿透
new MyPromise((resolve, reject) => reject('boom'))
  .then((v) => v)
  .catch((e) => console.log('错误冒泡', e)) // 错误冒泡 boom

// 3. thenable 同化：then 返回 thenable 会被递归展开
const thenable = { then(resolve) { setTimeout(() => resolve('thenable-ok'), 20) } }
new MyPromise((resolve) => resolve(1)).then(() => thenable).then((v) => console.log('同化结果', v)) // 同化结果 thenable-ok

// 4. 循环引用检测（回调返回派生出的 Promise 自身）
let q
q = new MyPromise((resolve) => resolve(1)).then(() => q)
q.catch((e) => console.log('检测到', e.message)) // 检测到 循环引用

// 5. all / race（用原生包装验证思路）
const myAll = (list) => new Promise((resolve, reject) => {
  const out = new Array(list.length); let done = 0
  if (!list.length) return resolve(out)
  list.forEach((item, i) => Promise.resolve(item).then((v) => {
    out[i] = v
    if (++done === list.length) resolve(out)
  }, reject))
})
myAll([Promise.resolve(1), 2, new Promise((r) => setTimeout(() => r(3), 10))])
  .then((v) => console.log('all', v)) // all [1, 2, 3]
```

---

## 高频错误（面试官最爱抓的）

| 错误说法 | 正确说法 |
|---|---|
| 「then 的回调是 setTimeout 宏任务」 | 是微任务（job queue） |
| 「Promise 可以取消」 | 原生不可取消，用 AbortController/包装 |
| 「then 返回原 Promise」 | 返回新 Promise，状态独立 |
| 「catch 之后的 then 不会执行」 | 会执行，值变为 catch 的返回值 |
| 「Promise.all 结果按完成顺序」 | 按入参顺序，与完成先后无关 |
| 「手写 then 不需要处理返回值」 | 必须经 `resolvePromise` 同化 |

---

## 关联文件

- 上一层（广度）：[JS 核心八股 · Promise](../../01-js/JS核心八股.md)
- 同层追问：[async/await](./03-async-await.md)｜[事件循环](./02-事件循环.md)｜[闭包](./04-闭包.md)
- 引擎层：[V8 内存与垃圾回收](./09-V8内存与GC.md)
- 典型场景：你 Agent 平台的请求封装、SSE 结束回填、接口重试与超时，都建立在这套状态机与 thenable 语义上

> **自测标准**：能不看笔记手写 `then + resolvePromise` 并跑通 5 段验证，算过关；能讲清 `PerformPromiseThen → PromiseReactionJob → 微任务` 的完整链路，算深度达标。
