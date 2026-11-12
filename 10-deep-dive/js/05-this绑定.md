# this 绑定（This Binding）

> 面试权重：5/5　｜　追问深度：**L5（Reference 类型 + [[ThisMode]] + V8 CallIC）**
> 一句话定位：`this` 不是"函数自己的属性"，而是**调用表达式**在运行时算出来的。谁调用、怎么调用，决定 `this` 是谁。

**本文件用法**：this 是"看起来会、一写就错"的重灾区。先跑通代码验证，再看 L3 的 Reference 类型——这是「为什么 `(0, obj.fn)()` 会丢 this」的唯一正解。
[返回深度追问索引](../00-索引.md)

---

## L1 一句话答案（10 秒能说出口）

`this` 在**调用时**确定，优先级：`new` > 显式 `call/apply/bind` > 隐式 `obj.fn()` > 默认绑定（严格模式 `undefined`，非严格 `window`）。箭头函数没有自己的 `this`，取定义时外层的 `this`。

---

## L2 原理层：四种绑定与丢失场景

| 绑定类型 | 写法 | `this` 指向 |
|---|---|---|
| 默认绑定 | `fn()` | 严格/模块：`undefined`；非严格：`window` |
| 隐式绑定 | `obj.fn()` | `obj`（只看调用时点号左边是谁） |
| 显式绑定 | `fn.call(o)` / `apply` / `bind` | 指定的第一个参数 |
| new 绑定 | `new Fn()` | 新创建的实例 |
| 词法绑定 | 箭头函数 | 定义时外层的 `this`（无法修改） |

**优先级**：`new` > `bind` > `call/apply` > 隐式 > 默认。

```js
function show() { return this?.name }
const obj = { name: 'vue', show }
console.log(obj.show()) // vue：隐式
const fn = obj.show
console.log(fn()) // undefined：赋值后丢失隐式绑定
console.log(obj.show.call({ name: 'react' })) // react：显式
console.log(obj.show.bind({ name: 'svelte' })()) // svelte：硬绑定
```

```js
function F() { this.x = 1 }
const B = F.bind({ y: 2 })
console.log(new B().x) // 1
console.log(new B().y) // undefined：new 优先级高于 bind，this 是新实例
```

**箭头函数 4 条**：没有自己的 `this`、没有 `arguments`、没有 `prototype`、不能 `new`；`call/apply/bind` 也改不了它。适合回调，不适合做对象方法（`obj.arrow = () => this` 拿到的是外层 this）。

**class 里的坑**：方法默认不是箭头函数，事件回调传出去就丢 `this`；类字段 `handler = () => this.x` 用箭头捕获实例，是 React class 组件时代的经典写法。

---

## L3 底层层：Reference 类型与 `[[ThisMode]]`

### 3.1 规范怎么算 this：先看调用目标是不是 Reference

调用表达式 `CallExpression` 求值时，先对 callee 求值：

- 得到一个 **Reference**（记录 `base`、`referencedName`、`strict`），比如 `obj.fn` 的 `base` 是 `obj`；
- 如果 callee 是 Reference 且 `base` 是对象，则 `this` = `base`（隐式绑定）；
- 如果是 Reference 但 `base` 是环境记录（如全局变量），`this` = `undefined`（严格）或 `window`（非严格）；
- 如果不是 Reference（表达式算出来的值），`this` = `undefined`/`window`。

**这就解释了 `(0, obj.fn)()`**：逗号表达式返回的是 `obj.fn` 的**值**（GetValue 后不再是 Reference），调用时没有 base，隐式绑定丢失。

`super.method()` 在规范里是 **SuperReference**，其 `base` 是 `[[HomeObject]]` 的原型，`this` 保持当前实例——所以 `super` 和 `this` 能同时工作。

### 3.2 函数对象上的 this 状态

- `[[ThisMode]]`：`lexical`（箭头函数）/ `strict` / `global`。
- 普通函数调用时，`OrdinaryCallBindThis` 把 `this` 写进 **Function Environment Record 的 `[[ThisValue]]`**；函数体内每次 `this` 都经 `ResolveThisBinding` → 找到外层最近的 `this` 环境。
- 箭头函数的 `[[ThisMode]]` 是 `lexical`，环境记录里没有 `[[ThisValue]]`，`ResolveThisBinding` 直接沿外层环境找。
- `bind` 创建 **BoundFunctionExoticObject**，内部槽 `[[BoundThis]]`、`[[BoundTargetFunction]]`、`[[BoundArguments]]`；调用时忽略新的 this 参数。`new bound()` 时规范规定**忽略 `[[BoundThis]]`**，用新对象——这就是 new 优先的出处。
- 非严格模式对原始类型 `this` 做 **boxing**（`this` 为 `Number`/`String` 包装对象），严格模式不装箱。

### 3.3 V8 的调用优化

- 函数调用走 **CallIC（Inline Cache）**：根据接收者的 Map 和调用形态缓存一条"怎么调、this 怎么传"的路径；单态时几乎零成本，多态/超态会退化。
- `this` 只是调用约定的一部分，V8 不为它单独分配对象（除了 boxing），所以**不能用 this 判断性能**。真正影响性能的是调用形态是否稳定（同一种方法、同一种接收者形状）。

---

## L4 追问树（面试官一路往下问，你能撑到第几层？）

> 规则：从上往下问。**第 1-3 层必备，第 4-6 层拉开差距，第 7 层以后加分。**

### 第 1 层｜`this` 是什么？什么时候确定？
**答**：`this` 是函数执行时的上下文对象，在**调用时**确定，由调用方式决定，与函数定义位置无关（箭头函数例外）。

### 第 2 层｜四种绑定和优先级？
**答**：默认绑定、隐式绑定 `obj.fn()`、显式 `call/apply/bind`、`new`；优先级 new > bind > call/apply > 隐式 > 默认。

### 第 3 层｜为什么 `const f = obj.fn; f()` 会丢 this？
**答**：调用时没有点号，callee 不再是「base 为 obj 的 Reference」，隐式绑定不成立，走默认绑定（严格 undefined，非严格 window）。

### 第 4 层｜箭头函数为什么改不了 this？能 new 吗？
**答**：箭头函数 `[[ThisMode]]` 为 lexical，没有 `[[ThisValue]]`，`this` 沿外层环境解析；也没有 `[[Construct]]`，不能 new；还没有 `prototype`。

### 第 5 层｜call、apply、bind 的区别？bind 多次会怎样？
**答**：call 立即调用、参数逐个传；apply 立即调用、参数数组；bind 返回新函数不执行。多次 bind 只有第一次生效；bind 后 new 时 this 仍是新实例。

### 第 6 层｜为什么 `(0, obj.fn)()` 会丢 this？
**答**：逗号表达式先对 `obj.fn` 取值，得到函数值而不是 Reference；调用时没有 base，隐式绑定失效。这是 React/Redux 里 `(0, dispatch)(action)` 写法的原因之一。

### 第 7 层｜非严格模式下 `fn.call(1)` 的 this 是什么？
**答**：是 `Number` 包装对象（boxing），不是数字 1；严格模式下才是原始值 1。所以严格模式下用 this 判断类型更可靠。

### 第 8 层｜class 方法、静态方法、字段初始化里的 this 有什么区别？
**答**：实例方法调用时 this 是实例；静态方法 this 是类本身；类字段初始化在构造函数里执行，this 是实例；方法被解构或作为回调传递时同样会丢 this，需 bind 或箭头字段。

### 第 9 层｜Vue2 的 methods 为什么用普通函数，而 Vue3 setup 里不需要？
**答**：Vue2 选项式 API 会把 methods 绑定到组件实例，普通函数的 this 能被框架通过 `bind` 指到实例，模板里 `@click="handler"` 才能访问 `this.xxx`；Vue3 setup 里直接使用闭包变量，不依赖 this。

### 第 10 层（终局）｜V8 执行一次 `obj.fn()`，this 在引擎里怎么传？
**答**：CallIC 先检查接收者形状和调用形态，命中缓存后按固定路径调用：把 `obj` 作为 receiver 传入调用约定（寄存器/参数），被调函数创建执行上下文时，`OrdinaryCallBindThis` 把 receiver 写进 Function Environment Record 的 `[[ThisValue]]`；函数内 `this` 读取走 `ResolveThisBinding`。形状变化会让 CallIC 从单态退化为多态/超态，但 this 语义不变。

---

## L5 名词拆解表（"每个名词都拆开"）

| 名词 | 是什么 | 为什么存在 | 面试追问点 |
|---|---|---|---|
| `this` | 函数调用时的上下文对象 | 让方法能访问所属对象 | 调用时确定而非定义时 |
| Reference 类型 | 规范的「引用」值（base + name） | 区分「取值」与「调用位置」 | `(0,obj.fn)()` 为何丢 this |
| `[[ThisMode]]` | 函数内部槽：lexical/strict/global | 决定 this 解析规则 | 箭头函数为何固定 |
| Function Environment Record | 函数执行环境 | 存 `[[ThisValue]]` 和变量 | 与词法环境的区别 |
| `[[ThisValue]]` | 环境记录里的 this 值 | 支持 this 解析 | 只有非箭头函数才有 |
| BoundFunction | bind 返回的异质对象 | 永久绑定 this/参数 | 多次 bind、new 优先级 |
| `[[BoundThis]]` | BoundFunction 里的 this | 调用时直接使用 | new 时被忽略 |
| lexical this | 箭头函数的 this 解析方式 | 回调保留外层上下文 | 不能 call/bind 修改 |
| boxing | 原始值包装成对象 | 非严格模式兼容历史 | `call(1)` 的 this 类型 |
| strict mode | 严格执行模式 | 禁止静默失败、this 不装箱 | 与 sloppy 的差异 |
| SuperReference | `super.x` 的引用类型 | 支持 super 调用并保留 this | `[[HomeObject]]` |
| `[[HomeObject]]` | 方法所属对象 | super 查找的起点 | class 方法必须用简写 |
| CallIC | V8 调用点内联缓存 | 加速方法调用 | 多态/超态退化 |

---

## 代码验证（打开浏览器控制台逐条跑，验证理解）

```js
// 1. 四种绑定
function who() { return this === undefined ? 'undefined' : this.tag }
const o = { tag: 'obj', who }
console.log(o.who()) // obj
console.log(who.call({ tag: 'call' })) // call
console.log(who.bind({ tag: 'bind' })()) // bind
console.log(who()) // 控制台 sloppy：undefined；严格/模块：'undefined'

// 2. 丢失 this
const user = { tag: 'vue', hi() { return this?.tag } }
const hi = user.hi
console.log(hi()) // undefined
console.log((0, user.hi)()) // undefined（逗号表达式破坏 Reference）
console.log(user.hi.call({ tag: 'react' })) // react

// 3. 箭头函数锁定外层 this
const outer = {
  tag: 'outer',
  normal() { return this.tag },
  arrow: () => this?.tag,
}
console.log(outer.normal()) // outer
console.log(outer.arrow()) // undefined（外层是全局，非严格下 window.tag 未定义）

// 4. bind 多次 / bind 后 new
function F() { this.x = 1 }
const B = F.bind({ y: 2 }).bind({ z: 3 })
console.log(new B().x, new B().y, new B().z) // 1 undefined undefined
console.log(B.call({ y: 99 })) // undefined（call 参数被忽略，F 仍以 {y:2} 为 this 执行）

// 5. 严格 vs 非严格 boxing
function sloppyThis() { return this }
function strictThis() { 'use strict'; return this }
console.log(typeof sloppyThis.call(1), sloppyThis.call(1) instanceof Number) // object true
console.log(strictThis.call(1)) // 1（原始值，不装箱）

// 6. class 字段箭头函数捕获实例
class Button {
  tag = 'btn'
  handle() { return this.tag }
  handleArrow = () => this.tag
}
const btn = new Button()
const h = btn.handle
const a = btn.handleArrow
console.log(h.call({ tag: 'lost' })) // lost（普通方法 this 可被改）
console.log(a()) // btn（箭头字段锁定实例）
```

---

## 高频错误（面试官最爱抓的）

| 错误说法 | 正确说法 |
|---|---|
| 「this 指向函数定义时的对象」 | 由调用方式决定；箭头函数才看定义位置 |
| 「this 指向函数自身」 | 只有 `fn.caller` 这类历史属性才和函数相关 |
| 「箭头函数的 this 可以用 call 改」 | 改不了，lexical this |
| 「bind 能多次覆盖 this」 | 只有第一次 bind 生效 |
| 「非严格模式 `call(1)` 的 this 就是 1」 | 是 Number 包装对象 |
| 「对象方法里的箭头函数 this 是对象」 | 是外层（定义位置）的 this |

---

## 关联文件

- 上一层（广度）：[JS 核心八股 · this](../../01-js/JS核心八股.md)
- 同层追问：[闭包](./04-闭包.md)｜[原型链](./01-原型链.md)｜[ES6 新特性](./07-ES6新特性.md)
- 引擎层：[V8 内存与垃圾回收](./09-V8内存与GC.md)
- 典型场景：Vue2 methods / React class 组件的 `this.handleClick = this.handleClick.bind(this)` 都是这一节的直接应用；Vue3 setup 与 React hooks 则用闭包代替了 this

> **自测标准**：能讲清第 6 层（Reference 类型）并跑通 6 段验证代码，算过关；能说出 `new bound()` 为什么忽略 `[[BoundThis]]`，算深度达标。
