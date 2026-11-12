# Vue3 原理与对比

> 面试权重：5/5（必考）　|　建议投入：6 天
> 适用场景：Vue 前端岗一/二面、Java 全栈岗前端追问、"你最熟哪个框架、为什么"类对比题

**相关章节**：[JS 核心八股](../01-js/JS核心八股.md)　|　[TypeScript 与类型系统](../01-js/TypeScript与类型系统.md)　|　[HTTP 与浏览器](../05-network/HTTP与浏览器.md)　|　[前端手写题 30 道](../07-algorithm/前端手写题30道.md)　|　[项目复盘与简历](../08-project/项目复盘与简历.md)

---

## 1. Vue3 vs Vue2：五个维度一句话说清

**一句话答案**：Vue3 用 Proxy 重写响应式、组合式 API 重组逻辑、编译期静态提升 + PatchFlag 缩小 diff 范围，同时原生支持 TS 和 tree-shaking。

**原理展开**：
- **响应式**：Vue2 用 `Object.defineProperty` 只能劫持"已存在的属性"，新增 `obj.a = 1`、删除 `delete obj.a`、数组下标 `arr[0] = x` 都监听不到，要配 `$set` 和重写数组 7 个方法；Vue3 `new Proxy(target, handler)` 代理整个对象，`get/set/has/deleteProperty/ownKeys` 全可拦截。
- **代码组织**：Vue2 选项式把 `data/methods/computed` 按类型分堆，一个功能散在四处；Vue3 `<script setup>` 按功能聚合，还能抽成 `usePagination()` 复用，比 mixin 来源清晰、无命名冲突。
- **性能**：Vue3 编译期给动态节点打 PatchFlag（`1 /* TEXT */`），配合静态提升、事件缓存、Block Tree，diff 时跳过静态子树；Vue2 每次全量遍历。
- **体积**：Vue3 运行时 API 可 tree-shaking，`<script setup>` 产物约 34KB（gzip ~13KB）；Vue2 是单体构造，摇不掉。
- **TS**：Vue3 源码 TS 重写，`defineProps/defineEmits` 有完整类型推导；Vue2 配 `vue-class-component` 也只是"勉强能用"。

**面试怎么答（60 秒版）**：Vue3 相对 Vue2 我总结成四块升级。第一是响应式从 defineProperty 换成 Proxy，解决了新增删除属性和数组下标监听不到的问题。第二是组合式 API，把按类型堆放的代码改成按功能聚合，逻辑能抽成组合函数复用。第三是编译优化，静态提升加 PatchFlag 让 diff 只碰动态节点。第四是原生 TS 支持和 tree-shaking，体积更小。所以现在新项目基本直接选 Vue3。

**追问陷阱**：
- 错误："Proxy 性能一定比 defineProperty 好" → 正确：Proxy 是运行时拦截、有额外开销，Vue3 的收益主要来自编译期优化和更细粒度更新，小对象上 Proxy 不一定更快。
- 错误："Vue3 不兼容 Vue2，迁移必死" → 正确：官方给了 `@vue/compat` 兼容构建和迁移指南，真正的大头是老旧 UI 库生态。

---

## 2. 响应式原理：defineProperty 的缺陷 → Proxy 解决什么

**一句话答案**：Vue2 把 data 每个属性改成 getter/setter 来收集依赖；Vue3 用 Proxy 代理整个对象，在 get 里 track、set 里 trigger 完成依赖收集与派发更新。

**原理展开**：
- **Vue2 流程**：`new Vue()` → `observe(data)` 递归遍历每个属性 `defineProperty`；渲染时访问属性触发 getter，把当前 `Watcher` 收进 `Dep.subs`；属性被赋值时 setter 执行 `dep.notify()` → `watcher.update()` → 重新渲染。
- **Vue2 三大硬伤**：
  1. 只能劫持已有属性：新增/删除属性不触发更新（`$set/$delete` 才救得回来）；
  2. 数组索引和 length 不劫持：`arr[0] = x`、`arr.length = 0` 失效，只能重写 `push/pop/shift/unshift/splice/sort/reverse` 兜底；
  3. 初始化递归遍历全部属性，每个属性建一个 Dep，初始化慢、内存高。
- **Vue3 流程**：`reactive(obj)` → `new Proxy`；`get` 里 `track(target, key)` 记录依赖，`set` 里 `trigger(target, key)` 触发更新；代理是懒递归的（访问到哪层代理哪层）。`ref` 用 `RefImpl` 类包一层 `value` 的 getter/setter。
- **依赖存储结构**：`WeakMap<target, Map<key, Set<effect>>>`，target 弱引用，对象被回收时依赖自动释放。
- **effect 分三类**：组件渲染 effect、computed effect（惰性）、watch / watchEffect。

```js
// 手写迷你响应式（面试口述骨架，可直接跑）
let activeEffect = null;
const targetMap = new WeakMap();

function track(target, key) {
  if (!activeEffect) return;
  let depsMap = targetMap.get(target);
  if (!depsMap) targetMap.set(target, (depsMap = new Map()));
  let dep = depsMap.get(key);
  if (!dep) depsMap.set(key, (dep = new Set()));
  dep.add(activeEffect);
}

function trigger(target, key) {
  targetMap.get(target)?.get(key)?.forEach((effect) => effect());
}

function reactive(target) {
  return new Proxy(target, {
    get(obj, key, receiver) {
      track(obj, key);
      const value = Reflect.get(obj, key, receiver);
      return typeof value === 'object' && value !== null ? reactive(value) : value;
    },
    set(obj, key, value, receiver) {
      const ok = Reflect.set(obj, key, value, receiver);
      trigger(obj, key);
      return ok;
    },
  });
}

function effect(fn) {
  activeEffect = fn;
  fn();
  activeEffect = null;
}

const state = reactive({ count: 0 });
effect(() => console.log('count =', state.count)); // 首次打印 count = 0
state.count++;                                     // 打印 count = 1
```

**面试怎么答（60 秒版）**：Vue2 的核心是 Object.defineProperty，初始化时递归遍历 data，把每个属性变成 getter/setter，getter 收集当前 watcher，setter 通知依赖更新。它有三个硬伤：新增删除属性监听不到、数组索引监听不到、递归劫持初始化开销大。Vue3 换成 Proxy 直接代理整个对象，get 里 track 收集、set 里 trigger 触发，新增删除和数组索引都能拦截，而且是访问到才递归。依赖用 WeakMap 到 Map 再到 Set 三级结构存，对象销毁也不泄漏。这就是两者最本质的差别。

**追问陷阱**：
- 错误："Proxy 能监听数组所以 Vue3 重写了 push 等方法" → 正确：Vue3 不重写；push 会访问 length 和索引，Proxy 天然拦截。Vue2 重写方法是因为索引不是 getter 的有效拦截点。
- 错误："defineProperty 原则上不能监听数组" → 正确：技术上是给索引逐个 defineProperty，但代价是遍历所有下标，Vue2 为性能放弃了。
- 错误："getter 收集的是组件实例" → 正确：收集的是渲染 effect（ReactiveEffect 等副作用函数），组件只是一个 effect 的拥有者。

---

## 3. ref 与 reactive：区别和四个坑

**一句话答案**：ref 什么都能包、靠 `.value` 读写；reactive 只能代理对象、直接访问属性；解构丢响应、整体替换失效是 reactive 最大的两个坑。

**原理展开**：
- `ref(1)` 返回 `RefImpl`，内部 `_value` + get/set；值为对象时会用 `toReactive` 转成 Proxy。模板中顶层 ref 自动解包，JS 里必须 `.value`。
- `reactive(obj)` 返回对象的 Proxy，对已是 Proxy 的对象再次调用幂等返回同一个。
- 坑 1 **解构丢响应**：`const { count } = reactive({ count: 0 })` 拿到的是普通数字；用 `toRefs()` / `storeToRefs()` 保持响应。
- 坑 2 **整体替换失效**：`let state = reactive({a:1}); state = reactive({a:2})`，模板引用的还是旧代理；需要整体替换就用 `ref`。
- 坑 3 **只能代理对象**：`reactive(1)` 直接警告并返回原值，基本类型只能用 ref。
- 坑 4 **嵌套 ref**：`reactive({ r: ref(0) })` 里 `state.r` 会自动解包（reactive 的 get 做了 unwrap）；但普通对象 `{ r: ref(0) }` 不解包。
- **shallowRef / shallowReactive / markRaw**：只代理第一层，适合大数组、地图实例、第三方类实例，能显著省性能。

**面试怎么答（60 秒版）**：我一般优先用 ref，因为它什么类型都能包，整体替换也不会丢响应。reactive 适合字段多、结构稳定的对象，直接访问属性更自然。区别在实现上：ref 用 RefImpl 的 getter/setter，值是对象时再转成 Proxy；reactive 就是 Proxy 本身。要注意几点：reactive 解构会丢响应，得配 toRefs；reactive 不能整体替换；模板里顶层 ref 会自动解包，但 JS 代码里要写 .value。团队规范里常见做法是统一 ref，或者 Pinia 里统一 storeToRefs。

**追问陷阱**：
- 错误："ref 性能比 reactive 差" → 正确：基本类型才走 getter/setter，对象同样转 reactive，差异可忽略。
- 错误："reactive 不能代理数组" → 正确：能，而且能监听索引和 length 变化。
- 错误：解构 Pinia / reactive 后说"我明明改了数据" → 正确：解构出来的是快照值，必须 storeToRefs。

---

## 4. 依赖收集与触发：为什么更新是异步的

**一句话答案**：读的时候记住谁在用（track），写的时候通知这些人重跑（trigger）；但重跑不立即执行，而是进调度队列、在微任务里批量 flush，所以 nextTick 能拿到最新 DOM。

**原理展开**：
- **effect 栈**：嵌套场景（组件渲染里用了 computed）需要保存 `activeEffect` 栈，执行完恢复外层，否则依赖会串。
- **Set 去重**：一个 effect 可能依赖多个 key，一个 key 也可能被多个 effect 依赖，用 Set 天然去重。
- **三种调度**：render effect 塞进 `queue` 去重、按 `id` 排序；computed 只标 `dirty`，下次访问才算；watch 走 `scheduler` 异步回调。
- **批量更新**：`Promise.resolve().then(flushJobs)`，同一个 tick 改 10 次数据只会渲染 1 次。
- **nextTick**：本质是 `currentFlushPromise.then(cb)`，等 flush 队列结束再执行，所以能拿到更新后的 DOM。

```js
// 批量更新调度示意
const queue = new Set();
let pending = false;
function queueJob(job) {
  queue.add(job);
  if (pending) return;
  pending = true;
  Promise.resolve().then(() => {
    queue.forEach((j) => j());
    queue.clear();
    pending = false;
  });
}
```

**面试怎么答（60 秒版）**：依赖收集就是"谁读了谁被记下来"。Vue3 在 Proxy 的 get 里 track，把当前 effect 加进这个 key 的 Set；set 里 trigger，遍历 Set 执行。存储结构是 WeakMap 存对象、Map 存 key、Set 存 effect。触发时不直接重新渲染，而是把 render effect 推进调度队列，用微任务批量 flush，同一轮多次修改会去重合并。所以组件更新是异步的，这也是为什么改完数据要 nextTick 才能拿到新 DOM，而且 nextTick 用的是 Promise 微任务，比 setTimeout 早。

**追问陷阱**：
- 错误："set 里直接调 render" → 正确：必须走 scheduler 排队去重，否则一次循环改 10 次就渲染 10 次。
- 错误："nextTick 是 setTimeout 宏任务" → 正确：是微任务 `Promise.then`。
- 错误："computed 依赖变会立即重算" → 正确：只标 dirty，是懒计算。

---

## 5. computed 与 watch / watchEffect

**一句话答案**：computed 是"派生的值"，惰性 + 缓存；watch 是"变化后做副作用"，能拿新旧值；watchEffect 自动收集依赖、立即执行。

**原理展开**：
- **computed**：`ComputedRefImpl` 带 `_dirty`；依赖变化时只把 dirty 置 true，下次 `.value` 才重算，不 dirty 直接返回缓存。
- **watch**：`doWatch(source, cb, options)`，source 支持 ref / reactive / getter / 数组；`deep` 深监听，`immediate` 立即执行一次，`flush: 'pre' | 'post' | 'sync'` 控制时机（默认 pre，组件更新前）。
- **watchEffect**：执行时自动收集依赖，返回 stop 函数，组件卸载自动停止；注意它只收集"本次执行实际用到"的依赖，条件分支里没走到的不会收集。
- **选型**：派生展示值（总价、全名、过滤后列表）→ computed；发请求、操作 DOM、写 localStorage → watch；依赖多、不需要旧值 → watchEffect。

```js
const price = ref(100);
const count = ref(2);
const total = computed(() => price.value * count.value); // 模板 {{ total }}，自动缓存

watch(total, (n, o) => console.log(`总价 ${o} → ${n}`), { immediate: true });

const state = reactive({ keyword: '' });
watch(() => state.keyword, (val) => fetchList(val), { flush: 'post' }); // reactive 字段必须用 getter
```

**面试怎么答（60 秒版）**：computed 是计算属性，本质是带缓存的惰性 effect：依赖没变直接返回缓存，依赖变了只标脏，下次访问才重算，适合从已有状态推导展示值。watch 是监听器，依赖变化后执行回调，能拿到新旧值，默认在组件更新前异步执行，适合发请求、操作 DOM 这类副作用。watchEffect 会自动收集依赖并立即执行一次，适合依赖多又不需要旧值的场景。选择标准就一句话：要一个值用 computed，要做一个动作用 watch。

**追问陷阱**：
- 错误："computed 也能直接赋值" → 正确：默认只读，要写就用 `computed({ get, set })` 显式声明。
- 错误："watch 一个 reactive 对象能监听到内部字段变化" → 正确：默认浅监听，改内部字段要 `deep: true` 或写成 getter。
- 错误：在 computed 里发请求 → 正确：computed 必须是纯函数，副作用放 watch 或 onMounted。

---

## 6. 生命周期：Vue2 → Vue3 对应关系

**一句话答案**：Vue3 把钩子变成 `onXxx` 组合函数在 setup 里调用，`beforeCreate/created` 由 setup 本体替代；父子顺序是父先初始化、子先 mounted、卸载时子先销毁。

**原理展开**：
- **对应关系**：`beforeCreate/created` → 直接写在 `<script setup>` 顶部；`beforeMount → onBeforeMount`、`mounted → onMounted`、`beforeUpdate → onBeforeUpdate`、`updated → onUpdated`、`beforeDestroy → onBeforeUnmount`、`destroyed → onUnmounted`、`activated/deactivated → onActivated/onDeactivated`、`errorCaptured → onErrorCaptured`。
- **挂载顺序**：父 beforeCreate → 父 created → 父 beforeMount → 子 beforeCreate → 子 created → 子 beforeMount → 子 mounted → 父 mounted。
- **卸载顺序**：父 beforeUnmount → 子 beforeUnmount → 子 unmounted → 父 unmounted。
- **组合式优势**：生命周期跟着逻辑走，一个 `useMouse()` 里自带自己的 onMounted 和 onUnmounted，比 mixin 的隐式合并清晰得多。

```js
import { onMounted, onBeforeUnmount, ref } from 'vue';
const el = ref(null);
let timer = null;
onMounted(() => { timer = setInterval(() => console.log('tick'), 1000); });
onBeforeUnmount(() => clearInterval(timer)); // 清理副作用，防内存泄漏
```

**面试怎么答（60 秒版）**：Vue3 的生命周期还是那套流程，只是从选项变成了在 setup 里调用的组合函数。beforeCreate 和 created 被 setup 本身替代，其余就是原名前加 on，比如 onMounted、onUnmounted。执行顺序上父组件先初始化，子组件先 mounted；卸载时子组件先销毁，父组件后销毁。组合式 API 的好处是生命周期可以跟逻辑一起封装进组合函数，比如 useMouse 自己注册自己的清理函数，比 mixin 清晰，也没有命名冲突。

**追问陷阱**：
- 错误："mounted 里一定能拿到子组件 DOM" → 正确：异步组件或 `v-if` 内容要配 nextTick / Suspense。
- 错误：把 clearInterval 写在 onUnmounted 里 → 正确：可以，但 onBeforeUnmount 更早、更安全，能保证清理先于销毁。
- 错误：`<script setup>` 顶层直接 `await` → 正确：组件会变成异步组件，必须在 Suspense 内才能正常渲染。

---

## 7. 虚拟 DOM 与 diff 算法

**一句话答案**：虚拟 DOM 是用 JS 对象描述节点树，diff 是同层比较 + key 复用；Vue3 用 PatchFlag 和最长递增子序列把同层列表 diff 压到接近 O(n)。

**原理展开**：
- **为什么用虚拟 DOM**：减少真实 DOM 操作、跨平台（SSR / 小程序 / 原生）、批量 diff 后只做最小 patch。它不是"一定比原生 DOM 快"，价值在于可维护、可预测、可优化。
- **同层比较**：只比较同一层级，不跨层移动；类型不同直接替换整棵子树；类型相同则复用节点、比属性、比子节点。
- **key 的作用**：同层多子节点 diff 时建立"旧节点 key → 下标"的 Map 找可复用节点；Vue3 子节点 diff 分五步：前序同步 → 后序同步 → 新增 → 删除 → 乱序（最长递增子序列决定谁不动）。
- **为什么不用 index 作 key**：插入/删除/排序后 index 全变，节点被错误复用——输入框内容错位、组件内部状态串、动画异常。index 作 key 基本等于没写 key。
- **反例**：用 `Math.random()` 作 key 会让每次渲染都重建节点，比不写 key 更差。

```html
<!-- 错误：删除第一项后，输入框内容跟着错位 -->
<li v-for="(item, index) in list" :key="index">{{ item.text }}</li>
<!-- 正确：稳定唯一的业务 id -->
<li v-for="item in list" :key="item.id">{{ item.text }}</li>
```

**面试怎么答（60 秒版）**：虚拟 DOM 就是用 JS 对象描述节点树，更新时新旧两棵 vnode 对比，算出最小变更再 patch 到真实 DOM。Vue 的 diff 是同层比较，不跨层移动，所以复杂度从暴力算法的 O(n³) 降到 O(n)。同层列表靠 key 识别"哪个旧节点能复用"，key 必须稳定唯一。用 index 当 key，在插入删除排序时会让节点复用错位，输入框内容和组件状态都会串，所以要用业务 id。Vue3 还加了 PatchFlag，编译时就标出哪些节点是动态的，diff 直接跳过静态部分。

**追问陷阱**：
- 错误："虚拟 DOM 比直接操作 DOM 快" → 正确：不一定，手写 DOM 可以更快；它的价值是可维护性和跨平台。
- 错误："key 只影响性能" → 正确：首先影响正确性（组件状态复用），其次才是性能。
- 错误："diff 会跨层移动节点" → 正确：只同层；跨层移动会被当成"删除 + 新建"。

---

## 8. 模板编译与 render 函数

**一句话答案**：编译分 parse → transform → generate 三步，把 template 变成 render 函数，并在 transform 阶段做静态提升、PatchFlag、事件缓存等编译优化。

**原理展开**：
- **parse**：HTML 解析成 AST；**transform**：处理 `v-if/v-for/插值`，做静态提升、patchFlag 标注、事件缓存；**generate**：生成 `createElementVNode` 调用代码。
- **编译产物**：`<div>{{ msg }}</div>` → `createElementVNode("div", null, toDisplayString(msg), 1 /* TEXT */)`。
- **静态提升**：静态节点提到 render 外只创建一次；**事件缓存**：`cacheHandlers` 让 `@click` handler 复用，避免子组件无谓更新。
- **render / h**：`h('div', props, children)`；选项式里 render 用 `this`，组合式返回 `() => h(...)`。
- **运行时编译 vs 预编译**：`.vue` 文件由 `@vitejs/plugin-vue` 构建期编译，产物只留 render；用 `vue/dist/vue.esm-bundler.js` 才能在浏览器里编译字符串模板，会变慢。

```js
import { h } from 'vue';
export default {
  props: { msg: String },
  render() {
    return h('div', { class: 'box' }, [
      h('span', this.msg),
      h('button', { onClick: () => this.$emit('click') }, '点我'),
    ]);
  },
};
```

**面试怎么答（60 秒版）**：Vue3 的模板编译分三步。parse 把模板解析成 AST；transform 做转换和编译优化，比如静态提升、给动态节点打 PatchFlag、缓存事件 handler；generate 生成 render 函数代码。正因为编译时就能分析出哪些静态哪些动态，运行时 diff 才能这么轻。Vue 是运行时加编译时的混合模式：.vue 文件在构建期就预编译成 render 函数，但也可以引入运行时编译版本在浏览器里编译字符串模板，只是会慢。面试常问的是编译优化从哪来、静态提升解决什么、render 函数和 h 怎么写。

**追问陷阱**：
- 错误："Vue3 不需要虚拟 DOM 了" → 正确：仍需要，编译优化只是缩小 diff 范围，vnode 结构没变（Vapor 模式目前仍是实验性）。
- 错误："模板不如 JSX 灵活" → 正确：模板牺牲一部分灵活换取编译期优化，JSX 灵活但优化靠手写，取舍不同。
- 错误：在选项式 `render()` 里用 setup 变量 → 正确：组合式要 `return () => h(...)` 靠闭包取变量，不能混用 this。

---

## 9. 组件通信全套

**一句话答案**：父传子 props、子传父 emit、跨层 provide/inject、父调子 ref + defineExpose、属性透传 $attrs；Vue3 删了事件总线，兄弟通信优先 Pinia，轻量场景用 mitt。

**原理展开**：
- **props**：单向数据流，子组件不允许直接改（会警告）；改数据要让父组件改。
- **emit**：`defineEmits(['update:modelValue'])`；`v-model` 是 `:modelValue` + `@update:modelValue` 的语法糖，多个 v-model 用 `v-model:title`。
- **provide / inject**：`provide(key, value)` / `inject(key, default)`；注入的值要用 ref/reactive 才响应，只想让下游读就用 `readonly` 包装；适合主题、i18n、表单上下文。
- **$attrs**：没被 props 声明的属性透传；`inheritAttrs: false` + `v-bind="$attrs"` 做二次封装组件（包一层 el-input 最常见）。
- **ref + defineExpose**：父调子方法；`<script setup>` 默认关闭实例暴露，必须显式 `defineExpose({ validate })`。
- **事件总线**：Vue3 移除了 `$on/$off`，轻量场景用 `mitt`，复杂共享状态用 Pinia；官方明确不推荐滥用全局事件。

```js
// 父组件
const formRef = ref(null);
onMounted(() => formRef.value?.validate());

// 子组件（script setup）
function validate() { /* ... */ }
defineExpose({ validate }); // 不写这句，父组件 ref 拿不到 validate
```

**面试怎么答（60 秒版）**：Vue 组件通信按关系分。父子之间 props 下行、emit 上行，v-model 是 modelValue 加 update:modelValue 的语法糖。跨层级用 provide/inject，注意注入的值要保持响应式、必要时用 readonly 限制修改。父组件要调子组件方法，用 ref 加 defineExpose，script setup 里默认是不暴露的。属性透传用 $attrs 加 inheritAttrs:false 做组件二次封装。Vue3 删掉了事件总线 API，兄弟组件优先用 Pinia 共享状态，轻量通信用 mitt。原则只有一条：单向数据流，谁的数据谁负责改。

**追问陷阱**：
- 错误："props 传对象，子组件改内部字段没问题" → 正确：能改（引用共享）但违反单向数据流，排查困难，规范要 emit 或 v-model。
- 错误："provide 一个普通对象，下游会自动响应" → 正确：不会，要 provide ref/reactive 或用 computed 保持联动。
- 错误："Vue3 里还能用 $on/$off 做事件总线" → 正确：已移除，用 mitt 或状态库。

---

## 10. Pinia vs Vuex

**一句话答案**：Pinia 是 Vue3 官方推荐的状态库，砍掉了 mutations 和嵌套 modules，用 setup 写法定义 store，TS 推导完整、天然支持代码分割。

**原理展开**：
- **Vuex 流程**：`state → mutations（同步）→ actions（异步）`，改数据必须 `commit`，模板化重；modules 嵌套还要开命名空间。
- **Pinia 三件套**：state / getters / actions，actions 里直接改 state，同步异步都行；每个 store 独立扁平，可互相引用。
- **写法**：`defineStore('id', setup函数)` 或 options 写法；setup 写法和组件里的组合式 API 完全一致。
- **优势**：TS 推导完整、支持按需加载 store、devtools 时间旅行、SSR 友好、没有 `this` 绑定问题（不能再用 this 互相调用，改用 store 实例）。
- **坑**：直接解构 store 会丢响应（state 是 reactive），要 `storeToRefs`；action 可以直接解构。
- **选型**：新项目直接 Pinia；老 Vuex 项目按 module 平滑拆成多个 store；只有跨组件共享、跨路由保留的状态才进 store。

```js
// stores/user.js
import { defineStore } from 'pinia';
import { computed, ref } from 'vue';

export const useUserStore = defineStore('user', () => {
  const token = ref('');
  const isLogin = computed(() => !!token.value);
  async function login(payload) { token.value = await api.login(payload); }
  function logout() { token.value = ''; }
  return { token, isLogin, login, logout };
});
```

**面试怎么答（60 秒版）**：Pinia 是 Vue3 官方推荐的状态管理，相当于 Vuex 的升级版。核心变化有三点：第一去掉了 mutations，修改数据直接在 actions 里做，同步异步都行；第二去掉了嵌套 modules，每个 store 独立定义、扁平好维护；第三对 TS 支持是原生级别的，类型推导完整。用法上 defineStore 有两种写法，我一般用 setup 函数式，和组件里的组合式 API 保持一致。要注意直接解构 store 会丢响应式，得配 storeToRefs。新项目基本都上 Pinia，老 Vuex 项目按模块迁移。

**追问陷阱**：
- 错误："Pinia 就是 Vuex5 换皮" → 正确：设计上砍掉了 mutations 和模块嵌套，API 更接近组合式 API。
- 错误："store 里的 state 直接解构也能用" → 正确：要 `storeToRefs`，否则拿到的是普通值。
- 错误："所有状态都塞 Pinia" → 正确：只有跨组件共享的才进 store，组件内部状态留在组件里，否则 store 会膨胀。

---

## 11. 路由：hash vs history、守卫、动态路由

**一句话答案**：hash 靠 `#` 后内容变化、不发请求；history 用 pushState 改地址栏、需要服务端 fallback 到 index.html；守卫分全局/路由独享/组件内三类。

**原理展开**：
- **hash**：URL 形如 `#/user/1`，监听 `hashchange`；刷新不会 404，但地址丑、不利于 SEO、和锚点冲突。
- **history**：`createWebHistory`，`pushState/replaceState` 改 URL 不请求，监听 `popstate` 处理前进后退；部署必须配 nginx `try_files $uri $uri/ /index.html`，否则刷新 404。
- **守卫顺序**：全局 `beforeEach` → 路由独享 `beforeEnter` → 组件内 `beforeRouteEnter/beforeRouteUpdate/beforeRouteLeave` → 全局 `beforeResolve` → `afterEach`（改标题、埋点）。
- **动态路由**：`path: '/user/:id'`，用 `route.params.id` 取；同一路由组件复用时（仅参数变化）不会重建，要 `watch(() => route.params.id)` 或 `beforeRouteUpdate` 重新拉数据。
- **权限**：`meta.requiresAuth` + `router.addRoute()` 动态加路由；菜单权限走路由表，按钮权限用自定义指令 `v-permission`。
- **懒加载**：`() => import('./views/Home.vue')` 按路由分包。

```js
router.beforeEach(async (to, from, next) => {
  const userStore = useUserStore();
  if (to.meta.requiresAuth && !userStore.isLogin) {
    next({ path: '/login', query: { redirect: to.fullPath } });
  } else {
    next();
  }
});
```

**面试怎么答（60 秒版）**：hash 和 history 的区别在原理：hash 靠 URL 中 # 后面的部分，变化不触发网络请求，监听 hashchange；history 用 HTML5 pushState 改地址栏，需要服务端把所有路径 fallback 到 index.html，否则刷新会 404。路由守卫分全局、路由独享、组件内三种，最常用的是 beforeEach 做登录鉴权和动态路由 addRoute。动态路由参数变化时组件会被复用，记得 watch route.params 或写 beforeRouteUpdate 重新请求数据。生产上一般用 history 加 nginx fallback，对 SEO 有要求的站点再考虑 SSR。

**追问陷阱**：
- 错误："history 模式刷新 404 是路由 bug" → 正确：服务端没配 fallback，nginx `try_files` 解决。
- 错误：beforeEach 里 `next()` 和 `return` 混用 → 正确：统一一种风格，Vue Router 4 支持返回路由对象/false。
- 错误："路由参数变了组件会重新创建" → 正确：同组件复用，生命周期不会重新走。

---

## 12. Vue3 性能优化常见手段

**一句话答案**：首屏靠懒加载和按需引入，运行态靠 v-once/v-memo/虚拟滚动/shallowRef 减少无效更新，定位问题用 Performance 面板和 devtools，先量化再优化。

**原理展开**：
- **首屏**：路由懒加载、`defineAsyncComponent` + Suspense、UI 库按需引入（unplugin-vue-components）、图片懒加载、`rollup-plugin-visualizer` 分析体积。
- **渲染**：`v-once` 静态内容只渲染一次；`v-memo="[deps]"` 依赖不变跳过子树；长列表用虚拟滚动；大对象用 `shallowRef` / `markRaw` 跳过深层代理；`v-if` 与 `v-show` 按切换频率选。
- **更新**：列表 key 稳定；computed 缓存派生值；拆组件缩小更新范围（一个组件一个渲染 effect，数据变只重渲染相关组件）。
- **网络**：接口合并、缓存、骨架屏、SSR/Nuxt 优化首屏。
- **定位**：Chrome Performance 看 long task、Vue devtools 看组件渲染次数、`app.config.performance = true` 打开组件性能统计。

**面试怎么答（60 秒版）**：Vue3 的性能优化我分三层答。首屏层做路由懒加载、异步组件、UI 库按需引入、图片懒加载，减小首屏包体积。运行层用 v-once、v-memo、虚拟滚动处理长列表，大对象用 shallowRef 避免深层代理，列表 key 稳定，computed 缓存派生值，同时拆组件把更新范围缩小。工程层做分包、CDN、gzip、骨架屏。定位问题用 Performance 面板看长任务和重渲染，Vue devtools 看哪个组件更新最多。核心思路是先量化再优化，不要盲目堆手段。

**追问陷阱**：
- 错误：上来就说"v-if 一定比 v-show 好" → 正确：频繁切换用 v-show，初始不渲染用 v-if，看场景。
- 错误："v-memo 万能" → 正确：依赖数组写错会导致该更新时不更新，是正确性风险。
- 错误：优化不给数据 → 正确：面试官最想听你怎么测的、优化前后差多少。

---

## 13. Vue vs React 核心差异

**一句话答案**：Vue 是"响应式 + 模板编译"的可变数据模型，React 是"不可变数据 + 显式 setState"的函数式模型；Vue 默认优化好、上手快，React 生态大、灵活度高。

**原理展开**：
- **更新机制**：Vue 依赖追踪，数据变了精确定位哪个组件重渲染，优化是自动的；React 靠 setState 触发，默认从该组件往下重新执行 render，要 `memo/useMemo/useCallback` 手动优化（React Compiler 在改善这一点）。
- **数据模型**：Vue 推荐直接改（`ref.value = x`）；React 要求不可变（返回新对象），因为靠引用比较决定是否更新。
- **模板 vs JSX**：Vue 模板有编译期优化，指令语义强；JSX 是 JS 全能力，灵活但没有编译期约束。
- **Hooks 对比**：Vue 组合式 API 和 React Hooks 神似，但 Vue 的 setup 只执行一次，React 函数组件每次渲染都执行——所以 React 有闭包陷阱，Vue 基本没有。
- **生态**：React 有 Next.js、React Native；Vue 有 Nuxt、uni-app。国内中小厂、国企 Vue 占比高，大厂和 RN 场景 React 更多。
- **选型**：看团队熟悉度、招聘难度和生态，没有绝对优劣。

**面试怎么答（60 秒版）**：Vue 和 React 的核心差异在更新模型。Vue 是响应式的，数据变了能精确追踪哪个依赖变化，组件自动重渲染，开发者几乎不用手动优化；React 是不可变数据加 setState，靠引用变化触发，需要 memo、useMemo 手动控制。第二是模板和 JSX：Vue 模板有编译期优化、上手快；JSX 是 JS 全能力，更灵活。第三是组合式 API 和 Hooks 神似但不同，Vue 的 setup 只跑一次，React 函数组件每次渲染都跑，所以 React 有闭包陷阱。选型看团队和招聘，国内 Vue 占比不低，React 在大厂和 RN 场景更强。

**追问陷阱**：
- 错误："Vue 一定比 React 快" → 正确：没有定论，看场景；Vue 默认优化好，React 手动优化上限高。
- 错误："Vue 有响应式就不用管渲染" → 正确：大对象和深层响应式一样有开销，要 shallowRef/markRaw。
- 错误："组合式 API 就是抄 Hooks" → 正确：思路类似但执行机制不同，setup 只执行一次没有闭包问题。

---

## 高频题库

| 题号 | 题目 | 考点 | 答案要点 |
|---|---|---|---|
| Q1 | Vue3 和 Vue2 的核心区别 | 综合 | 响应式 Proxy、组合式 API、编译优化、体积、TS 五条 |
| Q2 | Proxy 相比 defineProperty 解决了什么 | 响应式 | 新增/删除属性、数组索引、懒递归、WeakMap 依赖 |
| Q3 | ref 和 reactive 的区别与选型 | 响应式 API | ref 包任意值 + `.value`；reactive 只对象；优先 ref |
| Q4 | reactive 解构后为什么丢响应 | 响应式坑 | 解构成快照值，用 toRefs/storeToRefs |
| Q5 | Vue3 依赖收集与触发流程 | 响应式原理 | get→track，set→trigger，WeakMap/Map/Set |
| Q6 | 组件更新为什么是异步的 | 调度 | scheduler 队列 + 微任务批量 flush + nextTick |
| Q7 | computed 和 watch 的区别 | 计算属性 | 值 vs 副作用；缓存惰性 vs 回调；pre/post/sync |
| Q8 | computed 缓存的实现原理 | 计算属性 | `_dirty` 标记，依赖变只标脏，访问才重算 |
| Q9 | watch 监听 reactive 对象为何不触发 | watch | 默认浅监听，需 deep 或 getter |
| Q10 | 父子组件生命周期执行顺序 | 生命周期 | 父 beforeMount → 子 mounted → 父 mounted；卸载反向 |
| Q11 | 虚拟 DOM 是什么、有什么优缺点 | vdom | JS 对象描述节点、跨平台、可批量 patch；不保证更快 |
| Q12 | diff 算法流程与 key 的作用 | diff | 同层比较、key 建 Map 复用、五步 diff |
| Q13 | 为什么不能用 index 当 key | diff | 插入删除后索引错位，节点复用导致状态/输入串位 |
| Q14 | PatchFlag 和静态提升解决什么 | 编译优化 | 编译期标注动态节点，diff 跳过静态子树 |
| Q15 | 组件通信有哪些方式 | 组件通信 | props/emit、v-model、provide/inject、ref+expose、$attrs、Pinia |
| Q16 | 组件上 v-model 的实现原理 | 组件通信 | modelValue prop + update:modelValue 事件，可多 v-model |
| Q17 | Pinia 和 Vuex 的区别 | 状态管理 | 去 mutations、扁平 store、TS 推导、storeToRefs |
| Q18 | hash 和 history 路由的区别 | 路由 | hashchange vs pushState + 服务端 fallback |
| Q19 | 路由守卫的执行顺序 | 路由 | beforeEach → beforeEnter → 组件内 → beforeResolve → afterEach |
| Q20 | Vue 和 React 的核心差异 | 对比 | 响应式 vs 不可变 + setState；模板 vs JSX；setup vs Hooks |
| Q21 | Vue3 性能优化手段 | 性能 | 懒加载/按需、v-once/v-memo、虚拟滚动、shallowRef、拆组件 |
| Q22 | provide/inject 如何保持响应式 | 组件通信 | provide ref/reactive/readonly；普通对象不响应 |
