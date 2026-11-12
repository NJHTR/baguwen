# TypeScript 与类型系统

> 面试权重：4/5（Java 背景必问）　|　建议投入：2 天
> 适用场景：前端/全栈一面、Vue3 + TS 项目面、二面工程化追问；Java 候选人常被问「TS 和 Java 的类型系统像不像」

**怎么用**：TS 面试很少考偏门语法，重点是「你会不会用它写业务、能不能讲清类型和运行时的边界」。本文按面试提问频率排序，每节末的 60 秒稿可直接背。

相关文档：[JS 核心八股](JS核心八股.md) ｜ [Vue3 原理与对比](../02-vue/Vue3原理与对比.md) ｜ [前端手写题 30 道](../07-algorithm/前端手写题30道.md)

## 1. TypeScript 解决了什么问题

**一句话答案**：TS 是 JS 的超集，在编译期做静态类型检查，把字段拼错、参数传错这类错误提前到写代码时暴露，同时提供编辑器补全、跳转和重构能力；类型在运行时会被完全擦除。

**原理展开**：
- 编译期检查 + 类型擦除：`.ts` 经 tsc/esbuild/swc 转成 `.js`，产物里没有类型；`enum`、`namespace`、装饰器元数据是少数有运行时产物的语法。
- 核心价值是「契约」：前后端联调时用接口类型对齐 Java 后端的 DTO，字段改名编译期就报错，而不是线上 500。
- 工程价值：重构安全、自动补全、代码即文档；Vue3 源码整体用 TS 重写，生态的 `.d.ts` 是标配。
- 成本：构建链路更长、类型体操过度会让代码难读、`any` 滥用会让类型形同虚设。
- 常见对比：TS 是结构化类型（鸭子类型），Java 是名义类型，所以 TS 里「长得一样」就算兼容，这点和 Java 差别最大。

```ts
interface User {
  id: number
  name: string
}

function greet(user: User) {
  return `hi ${user.name}`
}

greet({ id: '1', name: 'vue' }) // 编译报错：Type 'string' is not assignable to type 'number'
```

**面试怎么答（60 秒版）**：
TS 是 JS 的超集，最大的价值是在编译期做静态类型检查，把字段拼错、参数类型不对这些错误从运行时提前到编码阶段，同时提供补全和重构能力。它的类型在编译后会被完全擦除，运行时不存在类型信息，所以接口返回的数据仍然要做运行时校验。和 Java 比，TS 是结构化类型，看形状不看名字，Java 是名义类型。我们在 Vue3 项目里用它定义接口类型、组件 props 和事件，联调时字段对不上编译期就能发现，这是最直接的收益。

**追问陷阱**：
- 错误：「TS 会在运行时校验类型」 → 正确：类型擦除，运行时没有校验；接口数据要用类型守卫或 zod 校验。
- 错误：「用了 TS 就不会有 bug」 → 正确：只覆盖类型层面的错误，逻辑错误和 `any` 逃逸仍然存在。
- 错误：「TS 就是给 JS 加注解」 → 正确：它还提供类型推断、泛型、类型运算和工程化约束。

## 2. 基础类型与类型推断

**一句话答案**：基础类型有 `string/number/boolean/null/undefined/symbol/bigint`，加上数组、元组、枚举、字面量和函数类型；变量能推断就不写注解，函数参数、返回值、公共 API 这些推断不出来的地方再手写。

**原理展开**：
- 字面量类型：`let x = 1` 推断为 `number`，`const x = 1` 推断为 `1`；`as const` 让对象/数组保留字面量并只读。
- 数组写 `number[]` 或 `Array<number>`；元组 `[string, number]` 固定位置类型和长度。
- `strictNullChecks` 下 `null/undefined` 不会隐式赋给其他类型，这也是 TS 报错最多的地方。
- 函数类型：参数必填、可选参数 `?` 必须在必填参数后；返回值可推断，公共函数建议显式标注。
- `unknow`/`any` 的区别见第 8 节；`object` 表示非原始类型，不推荐用 `Object`。

```ts
const literal = 1 // 类型 1
let mutable = 1 // 类型 number
const nums: number[] = [1, 2, 3]

function sum(a: number, b = 0): number {
  return a + b
}
const config = { mode: 'dev' } as const // mode: 'dev'，且只读
// config.mode = 'prod' // 报错：readonly
```

**面试怎么答（60 秒版）**：
TS 的基础类型和 JS 的原始类型基本对应，额外有字面量类型、元组和枚举。日常开发里大部分变量不需要写类型注解，TS 会根据初始值推断；但函数参数、返回值、组件 props、接口数据结构这些边界要显式写，因为推断不出来或者会退化成 any。要注意 `let` 和 `const` 的推断不同，`const x = 1` 得到字面量类型 1，`as const` 能让对象和数组也保留字面量并变成只读。开启严格模式后 null 和 undefined 不能随便赋给别的类型。

**追问陷阱**：
- 错误：「每个变量都要写类型」 → 正确：推断足够，写多了反而难维护；公共 API 和函数边界才需要显式。
- 错误：「`null` 的类型是 object」 → 正确：那是 JS 的 `typeof` 行为，TS 里 `null` 是独立类型。
- 错误：「元组和数组没区别」 → 正确：元组固定长度和每个位置的类型，数组是同类型可变长度。
- 错误：「`as const` 是类型断言」 → 正确：是常量断言，不改变运行时值，只是收窄为字面量并加只读。

## 3. interface 与 type

**一句话答案**：两者都能描述对象类型；`interface` 支持声明合并、更适合定义对象契约和类实现，`type` 能表达联合、元组、条件类型等任意类型别名；团队保持一致即可，不必神化某一个。

**原理展开**：
- `interface` 同名声明会自动合并（声明合并），适合扩展第三方库类型；`type` 同名直接报错。
- `interface extends` 继承；`type` 用 `&` 交叉；两者描述对象时几乎等价。
- `type` 能定义联合、交叉、元组、映射类型、条件类型、模板字面量；`interface` 做不到这些。
- `class` 可以 `implements` interface 或对象 type；interface 更适合「对外契约」，type 更适合「内部组合」。
- 索引签名 `[key: string]: unknown` 只能在对象类型里用。

```ts
interface User {
  readonly id: number
  name: string
  tags?: string[]
}
interface User {
  age: number // 声明合并，最终包含 age
}
const u: User = { id: 1, name: 'vue', age: 3 }

type Status = 'idle' | 'loading' | 'success' | 'error' // interface 做不到
type Admin = User & { permissions: string[] } // 交叉扩展
```

**面试怎么答（60 秒版）**：
大多数场景 interface 和 type 可以互换，都能描述对象。区别主要有三个：interface 支持声明合并，同名接口会自动合并，扩展第三方库类型时很有用；interface 能被 class implements，语义上更适合定义对外契约；type 更灵活，可以定义联合类型、元组、条件类型和映射类型，这些 interface 做不了。我一般对象契约用 interface，需要组合或联合就用 type，团队里统一风格比选哪个更重要。

**追问陷阱**：
- 错误：「interface 性能比 type 好」 → 正确：都是编译期类型，运行时完全擦除，没有性能差别。
- 错误：「type 不能描述对象」 → 正确：可以，`type User = { id: number }` 完全合法，只是不能声明合并。
- 错误：「声明合并随便用」 → 正确：同名接口合并容易造成隐式覆盖，一般只为扩展第三方类型。
- 错误：「interface 不能被联合」 → 正确：interface 本身不能被联合，但可以 `type A = X | Y` 组合两个 interface。

## 4. 泛型

**一句话答案**：泛型是类型参数，让函数/接口/类在保持类型安全的前提下复用；调用时由实参推断，或用 `<T>` 显式指定，`extends` 用来约束类型范围。

**原理展开**：
- 泛型的意义是保持类型关联：入参是什么类型，出参就是什么类型，`any` 做不到这一点。
- 函数泛型、接口泛型、类泛型；泛型可以有默认值 `T = string`。
- 约束 `T extends { length: number }` 允许访问 `length`；`K extends keyof T` 配合索引访问 `T[K]` 实现类型安全的取值。
- 泛型只是编译期占位，实例化后擦除，运行时没有 T。
- 过度使用会降低可读性，只有需要「类型关联」时才用。

```ts
function identity<T>(value: T): T {
  return value
}
const n = identity(1) // number

function getProp<T, K extends keyof T>(obj: T, key: K): T[K] {
  return obj[key]
}
const user = { id: 1, name: 'vue' }
const name = getProp(user, 'name') // string

interface ApiResponse<T> {
  code: number
  data: T
  message: string
}
type UserResp = ApiResponse<{ id: number; name: string }>
```

**面试怎么答（60 秒版）**：
泛型就是类型的参数化，目的是复用代码的同时保留类型信息。比如 identity 函数，返回值类型跟着入参走，用 any 就丢了这层关联。泛型可以用在函数、接口、类上，接口泛型在定义接口返回结构时特别常用，比如 ApiResponse<T> 包一层 data。extends 在泛型里是约束，表示类型必须满足某个结构，比如 keyof 约束可以保证取属性名时不会拼错，返回值类型还能精确到具体属性。泛型在编译后会被擦除，运行时不存在。

**追问陷阱**：
- 错误：「泛型是运行时机制」 → 正确：编译期实例化并擦除，产物里没有泛型。
- 错误：「`any` 可以替代泛型」 → 正确：`any` 丢失类型关联，泛型保留「入参类型决定出参类型」。
- 错误：「泛型里的 extends 是类继承」 → 正确：是约束，表示「满足该形状」。
- 错误：「泛型越多越高级」 → 正确：过度抽象增加阅读成本，没有类型关联需求就不要上泛型。

## 5. 联合类型与交叉类型

**一句话答案**：联合 `A | B` 表示「是其中之一」，使用前必须用类型守卫或断言收窄；交叉 `A & B` 表示「同时满足两者」，常用来扩展对象类型。

**原理展开**：
- 联合类型只能访问所有成员共有的属性；要访问分支特有属性必须先收窄。
- 字面量联合可以穷举 `switch`，配合 `never` 做穷尽检查（见第 8 节）。
- 可辨识联合（discriminated union）：每个分支带一个共同的 `kind`/`ok` 字面量字段，switch 时自动收窄，前后端状态机建模最常用。
- 交叉类型合并对象属性；同名属性类型冲突时变成 `never`（不可能存在）。
- `keyof`、索引访问 `T[K]`、`typeof` 是配合联合/交叉的高频操作。

```ts
type Result =
  | { ok: true; data: string }
  | { ok: false; error: string }

function handle(result: Result) {
  if (result.ok) return result.data // 收窄为成功分支
  return result.error // 收窄为失败分支
}

type Base = { id: number }
type WithTime = { createdAt: Date }
type Entity = Base & WithTime // 同时具备两组属性
const one: Entity = { id: 1, createdAt: new Date() }
```

**面试怎么答（60 秒版）**：
联合类型表示满足其中一个，交叉类型表示同时满足。联合类型拿到值之后不能直接访问某个分支独有的属性，要先收窄，收窄方式有 typeof、in、instanceof 和自定义类型守卫。实际项目里最常用的是可辨识联合，用一个 kind 或 ok 字段区分分支，switch 的时候 TS 能自动收窄，配合 never 还能做穷尽检查，新增分支忘了处理会直接编译报错。交叉类型一般用来扩展对象类型，等价于多个 interface 的合并。

**追问陷阱**：
- 错误：「联合类型能访问任意成员的属性」 → 正确：只能访问所有成员共有的，其余报错。
- 错误：「交叉类型是二选一」 → 正确：是同时满足，属性取并集。
- 错误：「`A & B` 冲突时保留 A」 → 正确：冲突属性为 `never`，赋值即报错。
- 错误：「联合类型收窄只能靠断言」 → 正确：优先用 `typeof/in/instanceof` 和字面量判别字段，断言是最后手段。

## 6. 类型断言与类型守卫

**一句话答案**：断言 `as` 只是告诉编译器「我比你清楚」，不做运行时检查和转换；类型守卫用 `typeof/in/instanceof` 或自定义 `x is T` 在运行时判断，并让编译器自动收窄。

**原理展开**：
- 断言的本质是「跳过检查」：断言错了编译器不管，运行时照样崩；`as unknown as T` 双重断言更是把安全性完全交给人。
- 非空断言 `obj!` 只是排除 `null/undefined`，不会让值真的存在。
- 类型守卫函数返回 `pet is Fish`，调用后分支内自动收窄。
- 常见守卫：`typeof`（原始类型）、`in`（属性是否存在）、`instanceof`（类）、字面量判断、`Array.isArray`。
- 更安全的选择：运行时校验库（zod、valibot）或手写守卫；接口返回值用 `unknown` + 守卫最稳。

```ts
type Fish = { swim: () => void }
type Bird = { fly: () => void }

function isFish(pet: Fish | Bird): pet is Fish {
  return 'swim' in pet
}
function move(pet: Fish | Bird) {
  if (isFish(pet)) pet.swim()
  else pet.fly()
}

const el = document.getElementById('app')!
el.innerHTML = '' // 非空断言：我确定元素存在

const raw = JSON.parse('{"a":1}') as { a: number } // 断言不校验，只是跳过检查
```

**面试怎么答（60 秒版）**：
类型断言 as 只是改编译期的类型视角，不做运行时转换也不做检查，所以断言错了运行时照样出问题，`as unknown as T` 这种双重断言更要慎用。非空断言 obj! 同理，只是关掉 null 检查。类型守卫更安全，它自带运行时判断，比如 typeof、in、instanceof，或者自定义一个返回 pet is Fish 的函数，判断之后分支里类型自动收窄。接口返回的数据我一般先用 unknown 接住，再用守卫或 zod 校验，而不是直接 as 成业务类型。

**追问陷阱**：
- 错误：「`as` 能做类型转换，比如 `'1' as number`」 → 正确：只改编译期类型，运行时还是字符串；这种断言本身会被 TS 拒绝，需要双重断言。
- 错误：「非空断言能让值不为空」 → 正确：只是关掉检查，null 依然可能进来。
- 错误：「类型守卫只是语法糖」 → 正确：它携带运行时判断 + 静态收窄，比断言安全得多。
- 错误：「`JSON.parse` 后 TS 能推断结构」 → 正确：返回 `any`（或 `unknown`），必须自己守卫或校验。

## 7. 工具类型

**一句话答案**：工具类型是基于已有类型生成新类型的映射/条件类型，高频的是 `Partial/Required/Pick/Omit/Record/ReturnType`，本质是 `keyof` + 映射 + 条件类型。

**原理展开**：
- `Partial<T>` 全部可选，`Required<T>` 全部必填，`Readonly<T>` 全部只读。
- `Pick<T, K>` 选属性，`Omit<T, K>` 排除属性，`Record<K, V>` 构造字典。
- `ReturnType<F>` 取函数返回值，`Parameters<F>` 取参数元组，`Exclude/Extract/NonNullable` 处理联合。
- 手写核心是映射类型：`{ [K in keyof T]?: T[K] }`；条件类型配 `infer` 可以提取类型。
- 工具类型都是编译期的，没有运行时成本，可放心组合。

```ts
interface User {
  id: number
  name: string
  email: string
}

type PartialUser = Partial<User> // 全部可选
type RequiredUser = Required<User> // 全部必填
type UserPreview = Pick<User, 'id' | 'name'> // 只保留两个字段
type UserWithoutEmail = Omit<User, 'email'> // 排除 email
type UserMap = Record<string, User> // 字典
type GetUserReturn = ReturnType<() => User> // User

type MyPartial<T> = { [K in keyof T]?: T[K] }
type MyPick<T, K extends keyof T> = { [P in K]: T[P] }
```

**面试怎么答（60 秒版）**：
工具类型就是 TS 内置的类型函数，用已有的类型生成新类型。常用的几个：Partial 把所有属性变可选，Required 反过来，Pick 挑字段，Omit 排除字段，Record 用来构造字典，ReturnType 拿函数返回值。它们底层是映射类型加 keyof，比如 Partial 展开就是遍历 keyof T 给每个属性加问号。实际项目里接口 DTO 和表单模型之间转换用得最多，比如表单 Partial、预览 Pick、字典 Record。这些都在编译期完成，运行时没有开销。

**追问陷阱**：
- 错误：「Partial 是递归的」 → 正确：只处理第一层，深层要自定义 `DeepPartial`。
- 错误：「Omit 对联合类型也有效」 → 正确：Omit 直接作用在联合上会丢失分发，通常需要 `DistributiveOmit`。
- 错误：「Record 的键只能是 string」 → 正确：可以是 string/number/symbol 的子集，常用字面量联合。
- 错误：「工具类型会增加运行时包体积」 → 正确：纯编译期，不影响产物。

## 8. unknown、any 与 never

**一句话答案**：`any` 关闭类型检查且会传染；`unknown` 是安全版 any，能接收任意值但使用前必须收窄；`never` 是空类型，表示永不存在，常用于抛错函数和穷尽检查。

**原理展开**：
- `any` 可以赋给任何类型，也能访问任意属性；一处 any 会让下游推断全部失效。
- `unknown` 可以接收任何值，但不能直接使用，必须先 `typeof`/断言/守卫；适合做 API 边界、`catch` 变量、`JSON.parse` 的返回。
- `never` 是所有类型的子类型，可以赋给任何类型；没有值属于 never。
- 典型用途：`function fail(): never` 表示永不正常返回；联合穷举后的 `default` 分支收窄为 never。
- 严格模式相关的 `noImplicitAny` 会把隐式 any 变成报错，逼你补类型。

```ts
let a: any = 1
a.foo.bar() // 编译通过，运行时可能崩

let u: unknown = 1
// u.toFixed() // 编译报错：'u' is of type 'unknown'
if (typeof u === 'number') u.toFixed(2)

type Shape = { kind: 'circle'; r: number } | { kind: 'square'; size: number }
function area(shape: Shape): number {
  switch (shape.kind) {
    case 'circle':
      return Math.PI * shape.r ** 2
    case 'square':
      return shape.size ** 2
    default: {
      const exhaustive: never = shape // 新增分支不处理时这里报错
      return exhaustive
    }
  }
}
```

**面试怎么答（60 秒版）**：
any 是关闭类型检查，可以赋给任何类型、访问任何属性，而且会传染，一处 any 下游全变成 any，所以公共 API 尽量别用。unknown 是安全版，任何值都能赋给它，但用之前必须先收窄，比如 typeof 判断，适合接接口返回和 JSON.parse 的结果。never 是空类型，表示永远不会出现的值，最典型的用法是抛错函数的返回值，还有联合类型穷尽检查：switch 处理完所有分支后 default 里变量会收窄成 never，如果以后新增分支忘了处理，这里就会编译报错。

**追问陷阱**：
- 错误：「unknown 就是 any 换个名字」 → 正确：unknown 不能直接使用，必须收窄，这正是安全性所在。
- 错误：「never 和 void 一样」 → 正确：void 表示没有返回值但函数能正常结束，never 表示永不返回。
- 错误：「用 any 最快最省事」 → 正确：any 掩盖 bug 并传染，边界处用 unknown 更安全。
- 错误：「never 只能当返回值」 → 正确：还能做穷尽检查、过滤联合类型（`Exclude` 的底层）。

## 9. Vue3 + TS 实战

**一句话答案**：组合式 API 里用 `ref<T>()` 标注状态、`defineProps<T>()`/`defineEmits<T>()` 声明组件契约；接口类型集中放 `types.ts`，与 Java 后端字段对齐，模板里靠推断自动补全。

**原理展开**：
- `ref<T>` 返回 `Ref<T>`，脚本里用 `.value`，模板自动解包；需要允许空值要写 `ref<User | null>(null)`。
- 复杂对象用 `reactive<T>`，但它不能整体替换；`ref` 兼容整体替换，团队一般优先 `ref`。
- `defineProps<{...}>()` 编译期展开，配 `withDefaults` 给默认值；`defineEmits<{ change: [value: number] }>()` 是 3.3+ 写法。
- 模板引用元素：`ref<HTMLInputElement | null>(null)`；事件对象写 `(e: MouseEvent)`。

```vue
<script setup lang="ts">
import { ref, computed } from 'vue'

interface User { id: number; name: string; tags?: string[] }

const props = withDefaults(defineProps<{ title: string; count?: number }>(), { count: 0 })
const emit = defineEmits<{ change: [value: number] }>()
const user = ref<User | null>(null)
const displayName = computed(() => user.value?.name ?? '匿名')
const inputRef = ref<HTMLInputElement | null>(null) // 模板引用元素
function onClick() { emit('change', props.count + 1) }
</script>

<template>
  <h3>{{ title }}：{{ displayName }}</h3>
  <input ref="inputRef" @input="onClick" />
</template>
```

**面试怎么答（60 秒版）**：
Vue3 组合式 API 里，状态用 ref 泛型标注，比如 ref<User | null>(null)，注意 strictNullChecks 下如果可能为空必须显式带上 null。组件契约用 defineProps 泛型声明 props，用 withDefaults 给默认值，defineEmits 用元组语法声明事件名和参数类型。接口类型一般单独放在 types 目录，按 Java 后端的 DTO 字段对齐，这样联调时字段改名编译期就能发现。模板里的类型由编译器推断，所以补全和检查都能覆盖到模板。

**追问陷阱**：
- 错误：「`ref<User>(null)` 也行」 → 正确：严格模式下 null 不属于 User，必须 `ref<User | null>(null)`。
- 错误：「解构 props 一定丢响应式」 → 正确：Vue 3.5+ 编译宏下解构仍保持响应式；旧版本用 `toRefs` 或直接 `props.x`。
- 错误：「`reactive` 和 `ref` 等价」 → 正确：`reactive` 不能替换整个对象、不能用于基本类型，按场景选。
- 错误：「`defineProps` 会在运行时校验类型」 → 正确：运行时不做类型校验，报错来自编译器和 IDE。

## 10. tsconfig 关键选项

**一句话答案**：`tsconfig.json` 控制编译目标与严格程度；面试重点记 `strict`（含 `strictNullChecks`/`noImplicitAny`）、`target/module`、`moduleResolution`、`skipLibCheck`、`isolatedModules`、`paths`、`noEmit`。

**原理展开**：
- `strict: true` 是一组严格开关的总闸（`strictNullChecks`、`noImplicitAny`、`strictFunctionTypes` 等），新项目必开。
- `target` 决定降级到哪个 ES 版本（影响可选链等语法是否被转译）；`module`/`moduleResolution` 要匹配打包器，Vite 项目常用 `ESNext` + `Bundler`。
- `esModuleInterop` 让 CJS 模块能默认导入；`skipLibCheck` 跳过 `.d.ts` 内部检查，显著加速。
- `isolatedModules: true` 要求类型导入写 `import type`，因为 esbuild/swc 是单文件转译，不做类型信息分析。
- `paths` 配置 `@/*` 别名，Vite 还需要在 `resolve.alias` 里同步配置；`noEmit` 表示只检查不产物（Vite 负责打包）。

```json
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "isolatedModules": true,
    "noEmit": true,
    "baseUrl": ".",
    "paths": { "@/*": ["src/*"] }
  },
  "include": ["src/**/*.ts", "src/**/*.d.ts", "src/**/*.vue"]
}
```

**面试怎么答（60 秒版）**：
tsconfig 里最该关注的是 strict 总开关，它会打开 strictNullChecks、noImplicitAny 这些检查，新项目必须开，不然 TS 的收益少一半。target 决定编译到哪个 ES 版本，决定语法要不要降级；module 和 moduleResolution 要和构建工具匹配，Vite 项目通常用 ESNext 加 Bundler。skipLibCheck 跳过第三方声明文件检查来提速，isolatedModules 要求类型导入用 import type，因为 esbuild 是单文件转译。paths 配路径别名，但 Vite 里还要同步配 resolve.alias。noEmit 表示 tsc 只做检查，产物交给打包器。

**追问陷阱**：
- 错误：「`strict: true` 就是全部检查」 → 正确：它不包含 `noUncheckedIndexedAccess` 等额外项，需要单独开。
- 错误：「`target` 影响运行时兼容性」 → 正确：只决定产物语法，API 兼容还要靠 polyfill。
- 错误：「配了 `paths` 就完事」 → 正确：打包器/运行时还要配 alias，否则运行时模块解析失败。
- 错误：「`skipLibCheck` 会关闭自己代码的检查」 → 正确：只跳过 `.d.ts` 自身检查，业务代码不受影响。

## 11. 常见报错怎么答

**一句话答案**：面试给一段报错代码，先归类成「类型不匹配、可能为空、隐式 any、属性不存在」四类，再按「收窄 → 补类型 → 断言（最后）」的顺序修，并说明为什么。

**原理展开**：
- TS2322/2345（Type is not assignable）：结构不兼容、缺属性、字面量被收窄；先检查接口字段是否漏写。
- TS18048/2532（possibly undefined）：`null/undefined` 未处理；用可选链、默认值、类型守卫。
- TS2339（Property does not exist）：接口缺字段、联合类型未收窄、索引签名缺失。
- TS7006/7031（implicitly has an 'any' type）：参数没注解且无法推断；补注解或装 `@types/xxx`。
- TS7053（element implicitly has any）：动态键访问对象；用 `Record`、`keyof` 或 `as const`。

```ts
interface User {
  id: number
  name: string
}
function findUser(id: number): User | undefined {
  return id === 1 ? { id: 1, name: 'vue' } : undefined
}
const user = findUser(1)
// console.log(user.name) // TS18048: 'user' is possibly 'undefined'
console.log(user?.name ?? '匿名')

const roleMap: Record<string, number> = { admin: 1, user: 2 }
console.log(roleMap['guest']) // number（运行时是 undefined，注意区别）
```

**面试怎么答（60 秒版）**：
TS 报错我一般先分类。第一类是类型不匹配，比如 string 赋给 number，通常查接口字段或者传参；第二类可能是 undefined，是 strictNullChecks 下最多的一类，用可选链、默认值或者守卫解决；第三类是属性不存在，多半是联合类型没收窄或者接口漏字段；第四类是隐式 any，补注解或者装类型包。修复顺序是先做类型收窄，再补准确类型，最后才用断言，`as any` 和 `@ts-ignore` 要尽量避免，用 `@ts-expect-error` 并写清原因。接口数据不确定就用 unknown 加运行时守卫。

**追问陷阱**：
- 错误：「报错就 `as any`」 → 正确：先用守卫、泛型、准确类型解决，any 会扩散。
- 错误：「类型报错说明 TS 有问题」 → 正确：多数是数据契约或类型定义不一致，是它该抓的问题。
- 错误：「`@ts-ignore` 方便」 → 正确：用 `@ts-expect-error`，问题修好后会自动报错提醒你删掉。
- 错误：「第三方库没类型就不能用」 → 正确：装 `@types/xxx`，或本地写 `.d.ts` 声明模块。

## 加分项：深挖到此

### 加分项：深挖到此 · 类型擦除与「类型为什么运行时不存在」

被追问「TS 类型能不能用来做运行时判断」时，答：不能。TS 遵循类型擦除，所有类型注解、interface、type、泛型在编译后都不存在，所以 `if (x instanceof User)` 或 `x as User` 在运行时拿不到类型信息。需要运行时区分的场景要靠值本身：`instanceof` 看构造函数、`typeof` 看原始类型、可辨识联合靠真实的 `kind` 字段。这也是为什么接口返回数据必须用守卫或 zod 校验——TS 的 `User` 类型只是编译期的约定，后端多返回或少返回字段它管不了。

### 加分项：深挖到此 · 条件类型与 infer 入门

被追问「工具类型的底层」时，答：`ReturnType` 的底层是条件类型加 `infer`：`type ReturnType<T> = T extends (...args: any[]) => infer R ? R : any`，`infer R` 表示「在这个位置推断出一个类型并命名为 R」。同理可以写 `type Unwrap<T> = T extends Promise<infer U> ? U : T` 把 Promise 拆掉，`type ElementOf<T> = T extends (infer E)[] ? E : never` 取数组元素类型。条件类型遇到联合类型会自动分发，这也是工具类型能批量处理多个类型的原因。面试到这一步说明你不只是会用，而是理解类型系统本身。

## 高频题库

| 题号 | 题目 | 考点 | 答案要点 |
| --- | --- | --- | --- |
| 1 | TS 相比 JS 解决了什么问题？ | TS 价值 | 编译期类型检查、契约、补全重构；类型运行时擦除 |
| 2 | TS 和 Java 类型系统区别？ | 结构化 vs 名义 | TS 结构化（看形状），Java 名义（看类名）；泛型擦除也不同 |
| 3 | 类型推断什么时候用？ | 基础类型 | 变量靠推断；函数参数/返回值/公共 API 显式 |
| 4 | interface 和 type 的区别？ | 类型定义 | 声明合并/extends vs 联合/元组/条件；对象描述等价 |
| 5 | 泛型是什么？为什么用它？ | 泛型 | 类型参数化，保持类型关联；`extends` 约束；编译期擦除 |
| 6 | `K extends keyof T` 有什么用？ | 泛型约束 | 保证属性名合法，`T[K]` 精确返回值类型 |
| 7 | 联合类型和交叉类型区别？ | 联合交叉 | `A\|B` 之一，`A&B` 同时满足；冲突属性变 never |
| 8 | 类型断言安全吗？ | 断言 | 不安全，只是跳过检查；优先守卫，双重断言慎用 |
| 9 | 类型守卫怎么实现？ | 类型守卫 | typeof/in/instanceof；自定义 `x is T` 函数 |
| 10 | Partial/Pick/Omit 怎么用？ | 工具类型 | 映射类型生成新类型；表单、预览、DTO 转换场景 |
| 11 | ReturnType 原理？ | 条件类型 | `T extends (...args:any[])=>infer R ? R : any` |
| 12 | any、unknown、never 区别？ | 特殊类型 | any 关闭检查会传染；unknown 安全但需收窄；never 空类型 |
| 13 | never 的实际用途？ | never | 抛错函数返回值、穷尽检查、Exclude 过滤联合 |
| 14 | Vue3 里怎么用 TS？ | Vue3 + TS | ref<T>、defineProps/defineEmits 泛型、withDefaults、事件类型 |
| 15 | strict 包含哪些检查？ | tsconfig | strictNullChecks、noImplicitAny、strictFunctionTypes 等 |
| 16 | TS18048 和 TS2339 怎么修？ | 报错处理 | 空值守卫/可选链；补接口字段或收窄联合类型 |

> 全库导航：[README](../README.md) ｜ [路线图](../00-plan/路线图.md) ｜ 上一篇：[JS 核心八股](JS核心八股.md) ｜ 下一篇：[Vue3 原理与对比](../02-vue/Vue3原理与对比.md) ｜ 相关：[前端手写题 30 道](../07-algorithm/前端手写题30道.md)
