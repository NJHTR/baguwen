# async/await 与执行顺序

> 面试权重：5/5　｜　追问深度：**L5（V8 可挂起函数 + 微任务续跑）**
> 一句话定位：`async/await` 是 Promise 的语法糖 + 协程。它没让 JS 变多线程，只是把 `await` 之后的代码打包成微任务，等 Promise 敲定后再执行。

**本文件用法**：先跑通代码验证里的 4 段代码，再看 L2。**输出顺序题是面试第一关，L3 的编译产物和 V8 实现是第二关。**
[返回深度追问索引](../00-索引.md)

---

## L1 一句话答案（10 秒能说出口）

`async` 函数一定返回 Promise；`await` 等待一个 thenable，把它转成 Promise 并注册回调，然后**让出执行权**，`await` 之后的代码作为微任务在 Promise 敲定后继续执行——本质是 generator + 自驱动执行器 + Promise 的语法糖。

---

## L2 原理层：语义、执行顺序与错误边界

### 2.1 三条核心语义

1. **调用即执行**：`asyncFn()` 被调用后，函数体同步执行到第一个 `await`（或 `return`/抛错）。
2. **await 让出**：若值是 Promise/thenable，则等待其敲定；若是普通值，用 `Promise.resolve` 包装后也会让出一个微任务 tick。
3. **返回值包装**：`return x` → `Promise.resolve(x)`；抛错 → rejected Promise，可被调用方 `catch`。

```js
async function f() {
  console.log('A') // 同步
  await 1 // 让出，后续进微任务
  console.log('B')
  return 2
}
f().then((v) => console.log('C', v))
console.log('D')
// 输出：A D B C 2
```

### 2.2 并发与串行（项目里最常踩）

```js
// 串行：总耗时 = 两个请求之和（约 5s）
async function serial() {
  const a = await requestA()
  const b = await requestB()
  return a + b
}
// 并发：总耗时 = 最慢的那个（约 3s）
async function parallel() {
  const [a, b] = await Promise.all([requestA(), requestB()])
  return a + b
}
```

> 报告平台聚合多数据源时，串行 `await` 是典型性能坑；但注意「有依赖才串行」，无脑 `Promise.all` 会让错误处理变复杂。

### 2.3 错误边界：`try/catch` 只覆盖 await 链

```js
async function bad() {
  try {
    setTimeout(() => {
      throw new Error('异步回调里的错')
    }, 0)
  } catch (e) {
    console.log('捕获不到', e) // 永远不会执行
  }
}
```

`try/catch` 只能捕获**同一条 Promise 链**上的 rejection：`await` 的 Promise rejected、或 await 之后的同步代码抛错。宏任务回调、事件回调里的异常不在链上。

---

## L3 底层层：从 generator 协程到 V8 可挂起函数

### 3.1 本质：generator + 自驱动执行器

手写一个 `asyncToGenerator` 就能看清机制：

```js
function asyncToGenerator(genFn) {
  return function (...args) {
    const gen = genFn.apply(this, args)
    return new Promise((resolve, reject) => {
      function step(method, arg) {
        let res
        try {
          res = gen[method](arg)
        } catch (e) {
          return reject(e)
        }
        const { value, done } = res
        if (done) return resolve(value)
        Promise.resolve(value).then(
          (v) => step('next', v),
          (e) => step('throw', e),
        )
      }
      step('next')
    })
  }
}
```

`await x` 在底层近似 `yield x` + 执行器在 `x` 敲定后调用 `gen.next()`/`gen.throw()`。

### 3.2 V8 里的真实实现

- 编译器把 `async` 函数编译成**可挂起的 resumable function**：每个 `await` 是一个挂起点，函数状态（局部变量、续体）存在堆上的 async function object 里，而不是一直占着调用栈。
- `await` 编译后调用内建 `AsyncFunctionAwait`：先 `PromiseResolve` 把值同化成 Promise，再 `PerformPromiseThen` 注册 resolve/reject 续体。
- Promise 敲定时，续体作为 **microtask** 被调度，恢复执行；所以 `await` 不会阻塞线程，只是"让出"。
- 挂起期间如果一直等不到敲定（比如网络不返回），函数对象和闭包变量会一直可达，这是内存泄漏的常见源头。

### 3.3 编译产物差异：polyfill 会多几个 tick

- 现代目标（ES2017+）：`async/await` 原样保留，由引擎实现。
- 旧目标（ES5）：TypeScript 生成 `__awaiter` + `__generator`，Babel 用 `regenerator-runtime`，本质都是 generator 状态机 + Promise。
- **polyfill 版本比原生多一次或多次微任务**，所以「为什么我本地输出顺序和别人的不一样」经常是构建目标不同导致的。

### 3.4 与事件循环的衔接

- 每个 `await` 至少产生一个微任务；连续 `await` 会产生多个 tick，顺序上表现为"每个 await 后面插一个微任务"。
- 微任务清空后才渲染：`await` 链很长时，虽然不阻塞线程，但会推迟渲染时机；大量并发 await 的微任务洪峰要留意。

---

## L4 追问树（面试官一路往下问，你能撑到第几层？）

> 规则：从上往下问。**第 1-3 层必备，第 4-6 层拉开差距，第 7 层以后加分。**

### 第 1 层｜`async/await` 的本质是什么？
**答**：Promise 的语法糖 + generator 协程：`await` 挂起函数、注册 then 回调，后续代码作为微任务恢复执行。

### 第 2 层｜为什么 `async` 函数一定返回 Promise？
**答**：规范规定 async 函数返回 `PromiseResolve(返回值)`；即使函数体同步执行完，调用方拿到的也是 Promise，这保证了调用方可以统一用 then/catch 处理。

### 第 3 层｜`await` 后面的代码什么时候执行？
**答**：作为一个微任务，在被 await 的 Promise 敲定后、当前宏任务的微任务清空阶段执行；普通值也会被包成 `Promise.resolve`，同样让出一个 tick。

### 第 4 层｜`await` 一个非 Promise 值会发生什么？
**答**：`PromiseResolve` 把它包装成已 fulfilled 的 Promise，然后注册 then —— 所以还是会"异步一下"：代码不会在 await 处同步继续，而是进微任务队列。

### 第 5 层｜`try/catch` 能捕获哪些错误？为什么捕获不到 `setTimeout` 里的？
**答**：只能捕获当前 async 执行链上的 rejection 和同步抛错；`setTimeout` 回调属于另一个宏任务，不在 Promise 链上，异常会走全局 `window.onerror`。

### 第 6 层｜串行 `await` 和 `Promise.all` 差多少？什么场景必须串行？
**答**：串行总耗时是各请求之和，`Promise.all` 是所有并发后取最慢；有数据依赖（后一个请求要用前一个结果）时必须串行。无依赖时用 `Promise.all`，但要注意一个失败全失败，需要容错就用 `Promise.allSettled`。

### 第 7 层｜`for await...of` 的原理是什么？
**答**：异步迭代器协议：对象实现 `[Symbol.asyncIterator]`，`next()` 返回 Promise<{ value, done }>；`for await` 每次等待 next 敲定再循环，适合 SSE/流式响应逐块处理，天然带背压。

### 第 8 层｜`return await promise` 和 `return promise` 有区别吗？
**答**：在 `try/catch/finally` 里有区别：`return await p` 会把 p 的 rejection 纳入本函数的 try/catch；`return p` 直接返回 Promise，外层 catch 捕获不到本函数内的错误处理逻辑。没有 try/catch 时多一个 tick，没有实际收益。

### 第 9 层｜`async` 函数能 `new` 吗？`this` 怎么确定？async 箭头函数呢？
**答**：不能 `new`（没有 `[[Construct]]`）。`this` 与普通函数一致，由调用方式决定；async 箭头函数的 this 取词法作用域。所以 `obj.method = async function () { this }` 里，取决于调用方式。

### 第 10 层（终局）｜V8 到底怎么执行 async 函数？
**答**：编译期把函数拆成带挂起点的 resumable function；`await` 调用 `AsyncFunctionAwait` → `PromiseResolve` 同化 + `PerformPromiseThen` 注册续体；挂起时局部状态存到堆上 async function object；Promise 敲定后，续体作为 microtask 被 V8 的 `MicrotaskQueue` 执行，恢复函数并接着跑。整个过程是单线程协作式调度，没有线程切换。

---

## L5 名词拆解表（"每个名词都拆开"）

| 名词 | 是什么 | 为什么存在 | 面试追问点 |
|---|---|---|---|
| async function | 返回 Promise 的函数 | 统一异步返回类型 | 能否 new、this 规则 |
| await | 挂起 + 等待 thenable | 让异步代码像同步 | 是否阻塞线程、microtask 几层 |
| thenable | 带 then 方法的对象 | 兼容第三方 Promise 类库 | 同化过程、额外 tick |
| 协程（coroutine） | 可挂起/恢复的执行单元 | 用同步写法表达异步 | 与线程/进程区别 |
| generator | `function*` + `yield` 状态机 | async 的底层原型 | next/throw/return |
| resumable function | V8 内部对 async 函数的实现 | 挂起时释放调用栈 | 状态存在哪 |
| continuation | 挂起点之后的续体 | 敲定后从哪继续跑 | 存储位置、内存影响 |
| `AsyncFunctionAwait` | V8 内建，实现 await | 把挂起与 Promise 接通 | 与 PerformPromiseThen 关系 |
| `__awaiter`/`__generator` | TS 降级 helper | 兼容旧 runtime | 与原生差异（tick 数） |
| regenerator-runtime | Babel 的 async 运行时 | 浏览器不支持 async 时降级 | 包体积、执行顺序差异 |
| 异步迭代器 | `Symbol.asyncIterator` 协议 | 流式/分页数据遍历 | for await、背压 |
| 背压（backpressure） | 消费速度限制生产速度 | 防止内存爆掉 | SSE 流式处理 |
| AbortController | 取消 fetch/流 | async 本身不可取消 | 取消后 Promise 的状态 |

---

## 代码验证（打开浏览器控制台逐条跑，验证理解）

```js
// 注意 以下每段单独粘贴运行；一起跑时所有同步代码先执行完，输出会交错
// 1. 基础顺序：同步 → await 后续 → 调用方 then
async function f() {
  console.log('f-start')
  await null
  console.log('f-after-await')
}
f()
Promise.resolve().then(() => console.log('caller-then'))
console.log('sync-end')
// 输出：f-start sync-end f-after-await caller-then（await 续体先入微任务队列）

// 2. 连续 await 产生多个 tick
async function g() {
  console.log(1)
  await null
  console.log(2)
  await null
  console.log(3)
}
g()
console.log(4)
// 输出：1 4 2 3

// 3. 串行 vs 并发（用 setTimeout 模拟请求）
const delay = (ms, tag) => new Promise((r) => setTimeout(() => { console.log(tag); r(tag) }, ms))
async function serial() {
  const t = performance.now()
  await delay(100, 'a'); await delay(100, 'b')
  console.log('串行约', Math.round(performance.now() - t), 'ms') // 约 200ms
}
async function parallel() {
  const t = performance.now()
  await Promise.all([delay(100, 'c'), delay(100, 'd')])
  console.log('并发约', Math.round(performance.now() - t), 'ms') // 约 100ms
}
serial().then(parallel)

// 4. 异步迭代器：模拟逐块读取（SSE 流式处理的最小模型）
async function* chunks() {
  for (const part of ['data:', 'hello', '\n\n']) {
    await new Promise((r) => setTimeout(r, 20))
    yield part
  }
}
async function consume() {
  for await (const part of chunks()) console.log('收到分块', JSON.stringify(part))
}
consume()
```

---

## 高频错误（面试官最爱抓的）

| 错误说法 | 正确说法 |
|---|---|
| 「await 会阻塞主线程」 | 只是让出执行权，后续代码走微任务 |
| 「async 函数里所有代码都异步」 | 第一个 await 之前是同步执行的 |
| 「await 非 Promise 值不会异步」 | 仍会包成 Promise.resolve，让出一个 tick |
| 「try/catch 能捕获所有异步错误」 | 只能覆盖同一条 Promise 链 |
| 「for 循环里 await 更快」 | 串行更慢，无依赖时应并发 |
| 「async 函数可以用 new 调用」 | 没有 `[[Construct]]`，不能 new |

---

## 关联文件

- 上一层（广度）：[JS 核心八股 · Promise 与事件循环](../../01-js/JS核心八股.md)
- 同层追问：[事件循环](./02-事件循环.md)｜[Promise 手写实现](./06-Promise实现.md)｜[闭包](./04-闭包.md)
- 引擎层：[V8 内存与垃圾回收](./09-V8内存与GC.md)
- 典型场景：你的 AI Agent 进度流用 `fetch + ReadableStream` 或 SSE，`for await` 逐块消费 + `AbortController` 取消，正好覆盖 L2 全部知识点

> **自测标准**：4 段验证代码输出全部答对，能把第 6 层讲清，算过关；能画出 generator 执行器和 V8 resumable function 的对应关系，算深度达标。
