# JS 核心八股

> 面试权重：5/5（必考）　|　建议投入：3 天
> 适用场景：一面 JS 基础轮、二面原理追问、前端手写题前置；Vue 项目面几乎必问闭包与事件循环

**怎么用**：先背「一句话答案」，再读「原理展开」，然后用「60 秒版」出声讲一遍；「追问陷阱」面试前扫一眼，防止答对第一层被第二层问倒。

相关文档：[TypeScript 与类型系统](TypeScript与类型系统.md) ｜ [前端手写题 30 道](../07-algorithm/前端手写题30道.md) ｜ [Vue3 原理与对比](../02-vue/Vue3原理与对比.md)

## 1. 作用域与变量提升

**一句话答案**：作用域是变量的可访问范围；`var` 提升到函数/全局作用域顶部并初始化为 `undefined`，`let/const` 也提升但不初始化，声明前访问进入暂时性死区（TDZ），抛 ReferenceError。

**原理展开**：
- JS 是词法作用域：变量属于**定义位置**所在的作用域，与调用位置无关。
- 编译阶段登记声明：函数声明整体提升、可提前调用；`var` 只提升声明、赋 `undefined`；`let/const/class` 登记但不初始化。
- 块级作用域是最近一对 `{}`；`var` 在循环里只有一个共享绑定，`let` 每轮新建绑定（闭包经典题的根因）。
- 未声明的变量在非严格模式下会被隐式挂到全局，这是内存泄漏和全局污染的来源。

```js
console.log(a) // undefined：var 提升
var a = 1
// console.log(b) // ReferenceError: Cannot access 'b' before initialization
let b = 2
foo() // 函数声明整体提升，可提前调用
function foo() { console.log('hoisted') }
```

**面试怎么答（60 秒版）**：
JS 只有词法作用域，变量在哪个函数或块里定义就属于哪个作用域。`var` 和函数声明在编译阶段提升，`var` 提升后是 `undefined`，函数声明可以整体提前调用。`let/const` 也会提升但不会初始化，从块开始到声明语句之间叫暂时性死区，访问会抛 ReferenceError，`typeof` 也一样。`var` 没有块级作用域，`let/const` 有，这也是循环里的闭包要用 `let` 的原因。

**追问陷阱**：
- 错误：「`let` 没有提升」 → 正确：绑定已创建但未初始化，TDZ 内访问报错。
- 错误：「`var` 写在函数里就是全局变量」 → 正确：是函数作用域；只有省略关键字赋值才隐式创建全局变量。
- 错误：「提升是代码被挪到最上面」 → 正确：是编译阶段登记声明，赋值语句仍在原位置。

## 2. 闭包

**一句话答案**：闭包是函数与它定义时词法环境的组合，让函数在外部执行时仍能访问原作用域的变量，常用于封装私有变量和保存状态。

**原理展开**：
- 每次调用外层函数创建新执行上下文；内层函数被返回或被回调保存后，通过作用域链持有外层变量，外层上下文不销毁。
- 用途：私有计数器、模块模式、防抖节流、柯里化、Vue3 组合函数。
- `for + setTimeout` 经典题：`var` 版本所有回调共享同一个 `i`，循环同步跑完时 `i` 已是 3，打印 `3 3 3`。
- 三种修复：改用 `let`（每轮新绑定）、IIFE 拷贝当前值、把 `i` 当 `setTimeout` 第三个参数传入。

```js
for (var i = 0; i < 3; i++) setTimeout(() => console.log(i), 0) // 3 3 3
for (let j = 0; j < 3; j++) setTimeout(() => console.log(j), 0) // 0 1 2

function createCounter() {
  let count = 0 // 外部无法直接访问
  return { inc: () => ++count, get: () => count }
}
const counter = createCounter()
counter.inc(); counter.inc()
console.log(counter.get()) // 2
```

**面试怎么答（60 秒版）**：
闭包就是函数加上它定义时的词法环境。内层函数引用了外层变量，并作为返回值或回调被外部保留，外层作用域就不会销毁，变量一直存在。它可以做私有变量、缓存、防抖节流和函数式编程。闭包不是内存泄漏，只是延长了变量生命周期，不需要时清理引用即可。经典题 `for + setTimeout` 里 `var` 共享同一个变量所以打印三个 3，换 `let` 每轮新绑定就是 0、1、2。

**追问陷阱**：
- 错误：「闭包一定内存泄漏」 → 正确：泄漏是「不再需要却仍被全局或长生命周期对象引用」，比如定时器没清、缓存无上限。
- 错误：「循环里闭包捕获的是会变的 `i`」 → 正确：准确说是 `var` 捕获同一个绑定，`let` 每次迭代生成独立绑定。
- 错误：「内层函数读到的是值的副本」 → 正确：读的是活引用，可读也可写。

## 3. this 四种绑定与箭头函数

**一句话答案**：`this` 在调用时由调用方式决定，优先级 `new` > 显式 `call/apply/bind` > 隐式 `obj.fn()` > 默认绑定；箭头函数没有自己的 `this`，取定义时外层的 `this`。

**原理展开**：
- 默认绑定：独立调用 `fn()`，非严格模式指向 `window`，严格模式/ES Module/class 内是 `undefined`。
- 隐式绑定：`obj.fn()` 指向 `obj`；把方法赋给变量再调用会丢失绑定。
- 显式绑定：`call(thisArg, ...args)`、`apply(thisArg, argsArray)` 立即执行；`bind(thisArg)` 返回永久绑定的新函数，多次 `bind` 只有第一次生效。
- `new` 绑定指向新实例，优先级高于 `bind`；箭头函数无 `this/arguments/prototype`、不能 `new`、`this` 改不了。

```js
function show() { console.log(this.name) }
const obj = { name: 'vue', show }
obj.show() // vue：隐式绑定
const fn = obj.show
fn() // 严格模式 this=undefined 抛错；非严格下打印 undefined
show.call({ name: 'react' }) // react
show.bind({ name: 'svelte' })() // svelte

const obj2 = {
  name: 'vue',
  tags: [1, 2],
  init() { return this.tags.map(() => this.name) }, // 箭头函数继承 init 的 this
}
console.log(obj2.init()) // ['vue', 'vue']
```

**面试怎么答（60 秒版）**：
`this` 是函数调用时确定的，不是定义时。普通调用指向全局或 undefined，对象方法调用指向对象，`call/apply/bind` 手动指定，`new` 调用指向新实例；优先级是 new 最高，其次显式绑定，再隐式绑定，最后默认绑定。箭头函数没有自己的 this，定义时就锁定外层 this，所以适合做回调，但不能当构造函数。Vue2 选项式 API 的 methods 用普通函数，就是为了 this 指向组件实例。

**追问陷阱**：
- 错误：「箭头函数能用 `arguments`」 → 正确：没有，用剩余参数 `(...args)`。
- 错误：「`call` 能改箭头函数的 this」 → 正确：改不了，箭头函数的 this 由词法环境锁定。
- 错误：「`bind` 会立即执行」 → 正确：`bind` 只返回新函数，`call/apply` 才立即执行。

## 4. 原型链与 Class

**一句话答案**：每个对象内部有 `[[Prototype]]` 指向原型对象，访问属性时沿原型一路查到 `null`，这条链就是原型链；`class` 是构造函数加原型链的语法糖。

**原理展开**：
- 三角关系：`实例.__proto__ === 构造函数.prototype`，`构造函数.prototype.constructor === 构造函数`。
- 查找顺序：自有属性 → 原型 → 原型的原型 → … → `Object.prototype` → `null`，找不到返回 `undefined`。
- `instanceof` 沿原型链判断 `Ctor.prototype` 是否在链上；`Object.create(null)` 创建无原型对象。
- `new` 四步：创建空对象 → 链接原型 → 执行构造函数（`this` 指向新对象）→ 返回对象；构造函数返回对象时用它，否则返回新对象。
- `class` 方法在 `prototype` 上且不可枚举、默认严格模式、必须 `new`；`extends` 同时建立构造函数的原型链（静态继承）和 `prototype` 的原型链。

```js
function Animal(name) { this.name = name }
Animal.prototype.speak = function () { return `${this.name} 叫` }

class Dog extends Animal {
  constructor(name) { super(name); this.kind = 'dog' }
  speak() { return super.speak() + '（汪）' }
}
const dog = new Dog('旺财')
console.log(dog.speak()) // 旺财 叫（汪）
console.log(dog instanceof Animal) // true
console.log(Object.getPrototypeOf(Dog.prototype) === Animal.prototype) // true
console.log(Object.getPrototypeOf(Dog) === Animal) // true：静态继承
```

**面试怎么答（60 秒版）**：
原型链就是对象找属性的链路。每个函数都有 prototype，用 new 创建实例时实例的原型指向它，prototype 自己又继承 Object.prototype，一条链到 null 为止，instanceof 就是沿这条链判断。class 不是新机制，是原型继承的语法糖，区别是 class 方法不可枚举、默认严格模式、不能当普通函数调用。new 的过程是创建对象、链接原型、执行构造函数、返回对象。

**追问陷阱**：
- 错误：「`class` 是新的继承模型」 → 正确：底层还是原型链，`Object.getPrototypeOf` 能看到同样的结构。
- 错误：「`__proto__` 是标准属性」 → 正确：规范推荐 `Object.getPrototypeOf/setPrototypeOf`，`__proto__` 只是历史访问器。
- 错误：「`instanceof` 判断类型最准」 → 正确：跨 iframe 或改原型会失准，优先 `Array.isArray`、`Object.prototype.toString.call`。

## 5. 事件循环 Event Loop

**一句话答案**：JS 单线程执行，每轮先跑同步代码，再清空**整个**微任务队列，然后取一个宏任务，循环往复，中间穿插渲染。

**原理展开**：
- 微任务：`Promise.then/catch/finally`、`await` 之后的代码、`queueMicrotask`、`MutationObserver`。
- 宏任务：整个 `<script>`、`setTimeout/setInterval`、I/O、UI 事件回调、`postMessage`。
- 渲染时机：微任务清空后浏览器才可能执行 `requestAnimationFrame`、布局和绘制；长微任务会阻塞渲染。
- 浏览器和 Node 不同：Node 分 timers/poll/check 等阶段，且 `process.nextTick` 优先于 Promise；面试默认只说浏览器。
- `await` 右侧表达式同步执行，`await` 之后的代码相当于 `.then` 回调进微任务；`setTimeout(fn, 0)` 嵌套 5 层后最小延迟约 4ms。

```js
console.log('1')
setTimeout(() => console.log('2'), 0)
Promise.resolve().then(() => console.log('3'))
console.log('4') // 输出：1 4 3 2

async function async1() {
  console.log('async1 start')
  await async2() // async2 同步执行
  console.log('async1 end') // 进微任务
}
async function async2() { console.log('async2') }
console.log('script start')
async1()
new Promise((resolve) => { console.log('promise1'); resolve() })
  .then(() => console.log('promise2'))
console.log('script end')
// script start → async1 start → async2 → promise1 → script end → async1 end → promise2
```

**面试怎么答（60 秒版）**：
JS 是单线程，靠事件循环调度。同步代码在调用栈执行完，然后清空微任务队列，再执行一个宏任务，如此循环。微任务包括 Promise 回调、await 后面的代码、queueMicrotask，宏任务包括 setTimeout、事件回调、I/O。所以同样是 0 延迟，setTimeout 永远排在 Promise.then 后面。async 函数里 await 之前的代码同步执行，await 之后相当于注册了 then 回调进入微任务。浏览器在每轮微任务后找机会渲染，Node 的事件循环阶段和浏览器不同，面试要区分开。

**追问陷阱**：
- 错误：「`setTimeout(fn, 0)` 会立刻插队」 → 正确：它是最低优先级宏任务，必须等同步代码和所有微任务跑完。
- 错误：「宏任务先执行、微任务后执行」 → 正确：每一轮宏任务后都会清空微任务，Promise 总能插到下一个 setTimeout 之前。
- 错误：「`new Promise` 的回调是异步的」 → 正确：executor 同步执行，只有 then 回调进微任务。
- 错误：「`requestAnimationFrame` 是宏任务」 → 正确：它由浏览器在渲染前调度，不属于宏任务队列。

## 6. Promise

**一句话答案**：Promise 是异步结果的状态机，只有 pending → fulfilled/rejected 单向变化；`then` 返回新 Promise 支持链式调用，错误沿链冒泡直到被 `catch` 捕获。

**原理展开**：
- 状态只能改一次，`resolve/reject` 之后再调用被忽略；`resolve` 一个 Promise 会等待它敲定。
- `then` 回调返回普通值包装成 fulfilled，返回 Promise 则等待，抛错转为 rejected；回调不是函数时透传。
- `.catch` 等价 `.then(undefined, onRejected)`；`.finally` 不改变结果，回调返回 Promise 时会等待。
- 组合方法：`all` 全部成功才成功、一败即败；`allSettled` 等全部结束并返回状态；`race` 第一个敲定即敲定；`any` 第一个成功、全败抛 `AggregateError`。
- 未处理的 rejection 触发 `unhandledrejection`，项目里要全局兜底；Promise 不能取消，要配合 `AbortController`。

```js
function myAll(promises) {
  return new Promise((resolve, reject) => {
    const list = Array.from(promises)
    const results = new Array(list.length)
    let done = 0
    if (list.length === 0) return resolve(results)
    list.forEach((p, i) => {
      Promise.resolve(p).then((value) => {
        results[i] = value
        if (++done === list.length) resolve(results)
      }, reject)
    })
  })
}
function myAllSettled(promises) {
  return Promise.all(Array.from(promises).map((p) =>
    Promise.resolve(p).then(
      (value) => ({ status: 'fulfilled', value }),
      (reason) => ({ status: 'rejected', reason }),
    ),
  ))
}
function myRace(promises) {
  return new Promise((resolve, reject) => {
    Array.from(promises).forEach((p) => Promise.resolve(p).then(resolve, reject))
  })
}
```

**面试怎么答（60 秒版）**：
Promise 内部有三种状态，pending、fulfilled、rejected，只能从 pending 单向变一次。then 返回一个新 Promise，所以能链式写，回调里返回值会被包一层，抛错会进入下一个 catch，异步错误也能像同步 try/catch 一样集中处理。all 是全部成功才成功、有一个失败就失败，allSettled 把成功失败都收集起来，race 取最快结束的。它解决了回调地狱和错误无法集中处理的问题，但本身不能取消，真正取消要配合 AbortController。

**追问陷阱**：
- 错误：「Promise 是异步的，所以 `new Promise` 里的代码也异步」 → 正确：executor 同步执行，只有回调走微任务。
- 错误：「`Promise.all` 的结果顺序和完成先后一致」 → 正确：结果按入参顺序排列，和谁先完成无关。
- 错误：「`catch` 之后后续 then 不执行」 → 正确：catch 也返回 Promise，后面的 then 继续执行，值变成 catch 的返回值。
- 错误：「`finally` 的返回值能改变结果」 → 正确：返回值被忽略，只有抛错或返回 rejected Promise 会覆盖。

## 7. 深浅拷贝

**一句话答案**：浅拷贝只复制第一层引用（展开运算符、`Object.assign`），嵌套对象仍共享；深拷贝递归复制每一层，优先用 `structuredClone`，`JSON.parse(JSON.stringify())` 有大量坑。

**原理展开**：
- 浅拷贝：`{ ...obj }`、`Object.assign({}, obj)`、`arr.slice()`，第二层起仍是同一引用。
- 手写深拷贝要处理 Date、RegExp、Map/Set、Symbol 键，循环引用用 `WeakMap` 记录已拷贝对象。
- JSON 的坑：函数/`undefined`/Symbol 键丢失；Date 变 ISO 字符串；`NaN/Infinity` 变 `null`；RegExp 变 `{}`；Map/Set 变 `{}`；循环引用抛错。
- `structuredClone` 支持 Date、Map、Set、ArrayBuffer、循环引用；不支持函数、DOM 节点、Symbol，遇到抛 `DataCloneError`。
- 不可变数据场景更推荐结构共享（immer），而不是每次深拷贝。

```js
const source = { date: new Date('2024-01-01'), fn: () => 1, nan: NaN, re: /a/g, nested: { a: 1 } }
const jsonClone = JSON.parse(JSON.stringify(source))
console.log(jsonClone.date) // '2024-01-01T00:00:00.000Z'
console.log(jsonClone.fn) // undefined
console.log(jsonClone.nan) // null
console.log(jsonClone.re) // {}

const { fn, ...rest } = source // 先去掉函数，否则 structuredClone 抛错
const safeClone = structuredClone(rest)
safeClone.nested.a = 2
console.log(source.nested.a) // 1：真正的深拷贝
```

**面试怎么答（60 秒版）**：
浅拷贝只复制第一层，嵌套对象还是同一个引用，展开运算符和 Object.assign 都是浅拷贝。深拷贝要递归复制所有层级，还要处理循环引用，可以用 WeakMap 记录已拷贝的对象。实际项目优先用 structuredClone，它支持 Date、Map、Set 和循环引用，但遇到函数会抛错。JSON 那套只能当临时方案，会丢函数和 undefined，Date 变字符串，NaN 变 null，循环引用直接报错。数据结构不可变时用 immer 的结构共享比深拷贝更合适。

**追问陷阱**：
- 错误：「`JSON.parse(JSON.stringify())` 是万能深拷贝」 → 正确：只能处理纯 JSON 数据，其余全有坑。
- 错误：「展开运算符是深拷贝」 → 正确：只浅拷贝一层。
- 错误：「深拷贝越彻底越好」 → 正确：大对象深拷贝有性能和内存成本，业务上经常只需要不可变更新。
- 错误：「structuredClone 支持函数」 → 正确：不支持，克隆函数抛 `DataCloneError`。

## 8. 垃圾回收与内存泄漏

**一句话答案**：引擎用可达性分析（标记清除）从根对象出发标记可达对象，回收不可达的；内存泄漏是仍有引用指向不再需要的对象，导致它无法被回收。

**原理展开**：
- 根对象包括全局对象、当前调用栈、闭包引用；从根遍历不到的对象就是垃圾。
- V8 分代回收：新生代 Scavenge 复制算法（存活少、回收快），老生代标记-清除/标记-整理，配合增量标记减少卡顿。
- 引用计数（早期 IE）处理不了循环引用，现代引擎不再用它做主策略。
- 常见泄漏：意外全局变量、定时器没清、事件监听没移除、闭包持有大对象、缓存不设上限、游离 DOM、用 Map 存对象键。
- `WeakMap/WeakSet` 的键是弱引用，键对象被回收时条目自动释放，适合做节点元数据缓存。

```js
function startSafe() {
  const bigData = new Array(1e6).fill('*')
  const timer = setInterval(() => console.log(bigData.length), 1000)
  return () => clearInterval(timer) // 组件卸载时调用
}
```

**面试怎么答（60 秒版）**：
现代浏览器用标记清除，从 window、调用栈这些根出发做可达性分析，遍历不到的对象就回收。V8 还分新生代和老生代，新生代复制算法回收快，老生代用标记清除和整理。内存泄漏不是垃圾没被回收，而是我们无意中让不再需要的对象一直可达，常见的有没清的定时器、没移除的监听、闭包持有大对象、缓存没有上限、已经移除的 DOM 还被变量引用。排查可以用 DevTools 的 Memory 面板拍堆快照对比。写 Vue 或 React 时，卸载时清理定时器和监听就是最基本的习惯。

**追问陷阱**：
- 错误：「闭包一定会泄漏」 → 正确：闭包正常结束就随作用域回收；泄漏是因为外部一直持有它。
- 错误：「手动 GC 能解决」 → 正确：业务代码无法主动触发 GC，只能断开引用、清理资源。
- 错误：「WeakMap 的键是普通引用」 → 正确：是弱引用，这正是它和 Map 的关键区别。

## 9. ES6+ 高频特性

**一句话答案**：解构和展开简化取值合并；`?.` 和 `??` 解决嵌套取值与「0/空串被误判」；`Proxy` 拦截对象操作（Vue3 响应式基础）；`Symbol` 提供唯一键和迭代协议；`Reflect` 提供对象操作的标准语义。

**原理展开**：
- 解构默认值只在值为 `undefined` 时生效（`null` 不命中），支持重命名、嵌套、剩余运算符。
- `?.` 短路：左边是 `null/undefined` 时整体返回 `undefined`；`??` 只对 `null/undefined` 兜底，保留 `0`、`''`、`false`。
- `Proxy` 能拦截 13 种操作（get/set/has/deleteProperty/ownKeys 等），Vue3 用 get 收集依赖、set 触发更新；`Reflect` 常配合 Proxy 保证 `receiver` 语义正确。
- `Symbol` 是原始类型，每次 `Symbol()` 都唯一，`Symbol.for` 走全局注册表；`Symbol.iterator` 让对象可被 `for...of` 和展开。
- 迭代器协议：实现 `[Symbol.iterator]()` 返回带 `next()` 的迭代器，`next()` 返回 `{ value, done }`。

```js
const user = { name: 'vue', age: 0, address: { city: '杭州' } }
const { name, age = 18, address: { city } = {} } = user
console.log(user?.address?.city ?? '未填写') // 杭州
console.log(user.age ?? 18) // 0；用 || 会得到 18

const target = { name: 'vue' }
const proxy = new Proxy(target, {
  get(obj, key, receiver) {
    return key in obj ? Reflect.get(obj, key, receiver) : 'not found'
  },
})
console.log(proxy.name, proxy.age) // vue not found

const iterable = {
  [Symbol.iterator]() {
    let i = 0
    return { next: () => (i < 3 ? { value: i++, done: false } : { value: undefined, done: true }) }
  },
}
console.log([...iterable]) // [0, 1, 2]
```

**面试怎么答（60 秒版）**：
ES6 之后最常问的是几个语法糖和底层机制。解构可以带默认值、重命名和嵌套；可选链在中间层为空时短路返回 undefined；空值合并只对 null 和 undefined 兜底，不会把 0 和空串当空。Proxy 是元编程，可以拦截对象的读写，Vue3 的响应式就用它替代了 Vue2 的 defineProperty。Symbol 是唯一的原始值，常用作内部键和迭代协议 Symbol.iterator。Reflect 把对象操作标准化，配合 Proxy 使用。

**追问陷阱**：
- 错误：「`??` 和 `||` 一样」 → 正确：`||` 会把 `0`、`''`、`false` 都当空值，`??` 只认 `null/undefined`。
- 错误：「Proxy 能拦截一切」 → 正确：只能拦截对象层面操作，不能拦截变量赋值，`===` 也不走 trap。
- 错误：「`Symbol` 是字符串」 → 正确：是原始类型，不能隐式拼字符串，需要 `String(sym)`。
- 错误：「可选链可以随便用」 → 正确：`obj?.a.b` 只保护 `a`，后面 `.b` 仍需保证；注意构建工具转译。

## 10. DOM 事件流与事件委托

**一句话答案**：事件流分捕获、目标、冒泡三阶段，`addEventListener` 默认在冒泡阶段触发；事件委托利用冒泡把子元素事件交给父元素监听，减少监听数量并支持动态元素。

**原理展开**：
- 完整顺序：`window` → `document` → 祖先链（捕获）→ `target`（目标）→ 祖先链（冒泡）→ `window`。
- `stopPropagation()` 阻止继续传播；`stopImmediatePropagation()` 还阻止同元素后续监听；`preventDefault()` 阻止默认行为（跳转、提交）。
- 委托写法：父元素监听，通过 `e.target.closest('li')` 找真实目标；`e.currentTarget` 是绑定监听的元素，`e.target` 是实际点击的元素。
- 不冒泡的事件不能委托：`scroll`、`focus/blur`（用捕获或 `focusin/focusout`）、`mouseenter/mouseleave`。
- 第三个参数支持 `{ capture, once, passive }`；滚动监听加 `passive: true` 避免阻塞滚动。

```html
<ul id="list">
  <li data-id="1">A</li>
  <li data-id="2">B</li>
</ul>
<script>
  document.getElementById('list').addEventListener('click', (event) => {
    const li = event.target.closest('li')
    if (!li) return
    console.log('点击了', li.dataset.id) // 动态新增的 li 同样生效
  })
  // 捕获阶段：第三个参数为 true
  document.addEventListener('click', (e) => console.log('capture', e.target), true)
</script>
```

**面试怎么答（60 秒版）**：
事件流是捕获、目标、冒泡三个阶段，事件从 window 往下传到目标再冒回来。addEventListener 默认在冒泡阶段触发，第三个参数传 true 就是捕获阶段。stopPropagation 阻止传播，preventDefault 阻止默认行为，两者不要混。事件委托就是把监听绑在父级，利用冒泡拿到 e.target，再用 closest 找到具体子元素，好处是只注册一个监听、动态新增的元素也自动生效，列表和表格里非常常用。注意 scroll、focus 这类不冒泡的事件不能委托。

**追问陷阱**：
- 错误：「`stopPropagation` 能阻止链接跳转」 → 正确：那是 `preventDefault` 的职责。
- 错误：「`e.target` 就是绑定监听的元素」 → 正确：那是 `currentTarget`，`target` 是实际触发者。
- 错误：「事件委托能代理所有事件」 → 正确：不冒泡的事件不行，需换捕获或专用事件。
- 错误：「同一个回调可以重复注册」 → 正确：同一元素、同一类型、同一回调（同捕获相位）会去重，但不同匿名函数会重复。

## 11. 数组高频 API 与 sort 坑

**一句话答案**：`map` 一对一返回新数组，`filter` 过滤，`forEach` 无返回值，`reduce` 聚合任意结构；`sort` 默认按字符串字典序且原地修改，数字排序必须传比较函数。

**原理展开**：
- 会改变原数组：`push/pop/shift/unshift/splice/sort/reverse/fill`；不改变：`map/filter/slice/concat/flat/flatMap/toSorted`。
- `map` 回调 `(item, index, array)`，`reduce` 回调 `(acc, cur, index, array)`；不给初值时第一项当初始值、从第二项开始遍历。
- `sort` 默认把元素转字符串比较，`[10, 9, 1].sort()` 得到 `[1, 10, 9]`；比较函数返回负数表示 `a` 在前。
- ES2019 起 `sort` 稳定；ES2023 提供不改变原数组的 `toSorted`，注意兼容性。
- 手写场景：`reduce` 实现 map/统计/分组，`Set` 去重，`flat(Infinity)` 扁平化，随机打乱用 Fisher-Yates 而不是 `sort(() => Math.random() - 0.5)`。

```js
const nums = [10, 9, 1, 3]
console.log([...nums].sort()) // [1, 10, 3, 9]：字符串字典序
console.log([...nums].sort((a, b) => a - b)) // [1, 3, 9, 10]
console.log([1, 2, 3].map(parseInt)) // [1, NaN, NaN]：map 把 index 当进制传入

const orders = [{ id: 1, amount: 20 }, { id: 2, amount: 5 }, { id: 3, amount: 10 }]
console.log(orders.reduce((sum, o) => sum + o.amount, 0)) // 35
const byId = orders.reduce((acc, o) => { acc[o.id] = o; return acc }, {})
const sorted = [...orders].sort((a, b) => b.amount - a.amount)

const map = (arr, fn) => arr.reduce((acc, cur, i) => { acc.push(fn(cur, i, arr)); return acc }, [])
console.log(map([1, 2], (n) => n * 2)) // [2, 4]
console.log([...new Set([1, 2, 2, 3])]) // [1, 2, 3]
console.log([1, [2, [3]]].flat(Infinity)) // [1, 2, 3]
```

**面试怎么答（60 秒版）**：
这几个的区别是：map 一对一映射返回新数组，filter 过滤返回新数组，forEach 只遍历没有返回值也不能 break，reduce 可以把数组聚合成任何东西，比如求和、分组，甚至实现 map。要注意哪些方法改原数组，push、splice、sort、reverse 都会改。sort 最大的坑是默认按字符串排序，所以 10 会排在 9 前面，数字排序一定要传比较函数，而且 sort 是原地修改，不想动原数组就先复制。map(parseInt) 那个经典题也是因为 map 会把索引当第二个参数传给 parseInt。

**追问陷阱**：
- 错误：「`forEach` 里 `return` 能跳出循环」 → 正确：不能，只跳过当前回调；提前结束用 `some/every` 或 `for...of` + `break`。
- 错误：「`sort` 返回新数组」 → 正确：原地排序并返回同一引用。
- 错误：「`sort(() => Math.random() - 0.5)` 洗牌够用」 → 正确：分布不均匀，正确做法是 Fisher-Yates。
- 错误：「`filter` 可以顺手改元素」 → 正确：能改但语义上不推荐，修改用 `map`。

## 加分项：深挖到此

### 加分项：深挖到此 · 从执行上下文看提升与闭包

被追问「提升到底提升到哪」时，答：每次函数调用创建执行上下文，里面有变量环境（var、函数声明）、词法环境（let/const）和 `this` 绑定。编译阶段对 `var` 登记并赋 `undefined`，对 `let` 只登记不初始化，所以 TDZ 访问抛错。闭包能存活，是因为内层函数的作用域链指向外层上下文，外层上下文被引用就不出栈销毁。再深一层，V8 把闭包变量存在堆上的 Context 对象里，所以函数返回后依然可访问。

### 加分项：深挖到此 · 微任务与渲染时机

被追问「微任务会不会阻塞渲染」时，答：会。浏览器在宏任务和其后微任务全部清空后才可能进入渲染：`requestAnimationFrame` 回调 → 样式计算 → 布局 → 绘制 → 合成。如果微任务里死循环或一直自我链式 `Promise.then`，页面完全卡住。反过来，把大量 DOM 操作放进同一个微任务批次，浏览器只渲染一次，比每改一次样式就强制同步布局高效。面试再深会问「任务队列和渲染帧的关系」，答到这个边界就够拿分。

## 高频题库

| 题号 | 题目 | 考点 | 答案要点 |
| --- | --- | --- | --- |
| 1 | var、let、const 的区别？ | 作用域与提升 | var 函数作用域可重复声明；let/const 块级、TDZ、不可重复声明；const 绑定不变但对象属性可改 |
| 2 | 什么是暂时性死区？ | TDZ | 块内 let/const 声明前不可访问，报 ReferenceError；`typeof` 也会抛 |
| 3 | 循环里 setTimeout 为什么都打印最后一个值？ | 闭包 + var | var 共享同一绑定；改 let / IIFE / 传参 |
| 4 | 闭包是什么？用在哪？ | 闭包 | 函数 + 词法环境；私有变量、防抖节流、柯里化、模块模式 |
| 5 | 闭包会造成内存泄漏吗？ | 内存 | 不会自动泄漏；不再需要仍被引用才是泄漏 |
| 6 | this 的四种绑定和优先级？ | this | new > call/apply/bind > obj.fn() > 默认；箭头函数取外层 |
| 7 | 箭头函数和普通函数区别？ | 箭头函数 | 无 this/arguments/prototype，不能 new，不能改 this |
| 8 | 原型链是什么？ | 原型 | 对象沿 `__proto__` 查找属性直到 null；instanceof 沿链判断 |
| 9 | new 操作符做了什么？ | new | 创建对象、链接原型、执行构造函数、返回对象 |
| 10 | class 和 ES5 继承的区别？ | Class | 语法糖；方法不可枚举、严格模式、必须 new、super 语义 |
| 11 | 宏任务和微任务有哪些？ | 事件循环 | 宏：script/setTimeout/事件/I/O；微：then/await 后代码/queueMicrotask |
| 12 | 一段 async/await 代码输出什么？ | 事件循环 | 同步部分先跑，await 后进微任务，then 按注册顺序 |
| 13 | Promise 的三种状态？ | Promise | pending/fulfilled/rejected，单向不可逆，结果只能敲定一次 |
| 14 | 手写 Promise.all 的思路？ | Promise | 计数 + 结果数组按索引存，一败即败，空数组立即 resolve |
| 15 | Promise.all 和 allSettled 区别？ | Promise | all 一败即败；allSettled 等全部并返回 status/value/reason |
| 16 | 深拷贝有哪些实现？ | 深浅拷贝 | 递归 + WeakMap；structuredClone；JSON 的坑要列出来 |
| 17 | JSON 深拷贝有什么问题？ | 深浅拷贝 | 丢函数/undefined/Symbol，Date 变字符串，NaN 变 null，循环引用报错 |
| 18 | 什么是内存泄漏？怎么排查？ | GC | 不可达对象无法回收；定时器/监听/闭包/游离 DOM；DevTools 堆快照 |
| 19 | 可选链和空值合并的区别？ | ES6+ | `?.` 防空值访问；`??` 只对 null/undefined 兜底 |
| 20 | Proxy 和 defineProperty 区别？ | ES6+ | Proxy 拦截整个对象、支持新增属性/数组/Map；defineProperty 只能劫持已存在属性 |
| 21 | 事件流三个阶段？ | DOM 事件 | 捕获 → 目标 → 冒泡；addEventListener 第三参数控制相位 |
| 22 | 事件委托是什么？优点？ | DOM 事件 | 父级监听 + e.target/closest；减少监听、支持动态元素 |
| 23 | map、forEach、filter、reduce 区别？ | 数组 API | 返回值/是否改原数组/能否中断/适用场景 |
| 24 | sort 排序 10 和 9 为什么错？ | 数组 API | 默认转字符串字典序；传 `(a,b)=>a-b`；原地修改 |
| 25 | 数组去重和扁平化怎么写？ | 数组 API | `[...new Set(arr)]`；`flat(Infinity)`；reduce 递归 |

> 全库导航：[README](../README.md) ｜ [路线图](../00-plan/路线图.md) ｜ 下一篇：[TypeScript 与类型系统](TypeScript与类型系统.md) ｜ 相关：[前端手写题 30 道](../07-algorithm/前端手写题30道.md) ｜ [Vue3 原理与对比](../02-vue/Vue3原理与对比.md)
