# 维护手册

> 这份文档解决一个问题：**以后怎么安全、可重复地维护这个库。**
> 三条命令覆盖 95% 的场景，剩下的都在「故障排查」里。

---

## 一、一分钟版

```bash
# 1. 写：新建一个知识点骨架（自动编号 + L1-L5 模板）
pwsh -File tools/new-note.ps1 -Section java -Title "Spring Bean 作用域"

# 2. 看：本地起服务预览（改完刷新浏览器即可）
pwsh -File tools/preview.ps1

# 3. 发：自检 -> 生成导航 -> 提交 -> 推送（Pages 约 30 秒后自动重建）
pwsh -File tools/publish.ps1 -Message "docs: 新增 Spring Bean 作用域"
```

发布后打开：**https://njhtr.github.io/baguwen/**

---

## 二、环境要求

| 工具 | 用途 | 是否必需 |
|---|---|---|
| Git | 版本管理与推送 | 必需 |
| PowerShell 5.1+ 或 PowerShell 7 | 运行 `tools/*.ps1` | 必需 |
| Python 3（或 Node/npx） | 本地预览静态页 | 只有预览需要 |
| 浏览器 | 看效果 | 必需 |

> 所有脚本都在 `tools/` 下，纯 PowerShell，没有额外依赖。

---

## 三、四个脚本

| 脚本 | 作用 | 用法 |
|---|---|---|
| `tools/new-note.ps1` | 新建深度追问文件：自动编号、生成 L1-L5 骨架 | `-Section java -Title "标题"` |
| `tools/check.ps1` | 自检：内部链接、emoji、隐私词、结构、manifest 覆盖 | 直接运行 |
| `tools/build-manifest.ps1` | 扫描全部 md，生成 `manifest.json`（站点导航数据） | 直接运行 |
| `tools/publish.ps1` | 一键发布：自检 → manifest → commit → push | `-Message "..."`，`-DryRun` 预览，`-SkipChecks` 跳过自检 |
| `tools/preview.ps1` | 本地预览：生成 manifest + 起静态服务器 | `-Port 8080` |

**自检会拦什么：**

- 内部链接指向不存在的文件
- 任何 emoji / 表情符号
- 隐私关键词（在 `tools/pii-keywords.txt` 配置，含手机号、常见邮箱正则）
- 深度文件缺 L1-L5、追问层不足 10 层、行数过少
- `manifest.json` 没覆盖全部 md（忘记生成时发布出去的页面会缺条目）

---

## 四、三类日常操作

### 场景 A：改已有笔记

1. 直接编辑对应 `.md`
2. `pwsh -File tools/preview.ps1` 看效果（可选）
3. `pwsh -File tools/publish.ps1 -Message "docs: 补充 XXX 第 7 层追问"`

### 场景 B：新增一个知识点

```bash
pwsh -File tools/new-note.ps1 -Section redis -Title "Redis 大 key 治理"
```

然后在提示的路径里填内容，要求：

- L1 一句话答案（十秒能说完）
- L2 原理层 / L3 底层层（落到源码、协议字段、内核）
- L4 追问树 **至少 10 层**，最后一层是终局
- L5 名词拆解表 **至少 10 行**
- 末尾补「代码验证 / 高频错误 / 关联文件 / 自测标准」

写完还要做两件事：

1. 在 `10-deep-dive/00-索引.md` 的对应分区表里**补一行**（否则索引与实际不一致）
2. `pwsh -File tools/publish.ps1`

### 场景 C：改样式或页面功能

| 想改什么 | 改哪个文件 |
|---|---|
| 配色、字号、间距、表格样式 | `assets/style.css` |
| 导航、搜索、目录、路由、主页布局 | `assets/app.js` |
| 页面头部、CDN 引用、meta 信息 | `index.html` |
| 分区名称与顺序 | `assets/app.js` 里的 `SECTIONS` 数组 |
| 分区归属规则（哪个目录算哪个分区） | `tools/build-manifest.ps1` 里的 `Get-Section` |

改完必须重新生成 `manifest.json`（`publish.ps1` 会自动做）。

---

## 五、目录结构

```
.
├─ index.html                 站点入口
├─ assets/
│   ├─ style.css              样式（黑白排版，无渐变/阴影/卡片）
│   └─ app.js                 路由、渲染、搜索、目录
├─ manifest.json              导航数据（机器生成，不要手改）
├─ tools/
│   ├─ build-manifest.ps1     生成导航数据
│   ├─ check.ps1              自检
│   ├─ new-note.ps1           新建知识点
│   ├─ publish.ps1            一键发布
│   ├─ preview.ps1            本地预览
│   └─ pii-keywords.txt       隐私关键词表（自己维护）
├─ 00-plan ~ 09-mock          广度八股与流程（14 篇）
└─ 10-deep-dive/              深度追问层（56 篇 + 索引）
    ├─ 00-索引.md             分区地图与进度
    ├─ java/ spring/ mysql/ redis/ middleware/
    ├─ distributed/ network/ ops/ backend-opt/
    └─ js/                    前端（全栈面试用）
```

### 新增一个深度分区（比如想加 `kubernetes/`）

1. 建目录：`10-deep-dive/kubernetes/`
2. 改 `tools/build-manifest.ps1`：加一行 `if ($p -like '10-deep-dive/kubernetes/*') { return 'deep-kubernetes' }`，并把 `'deep-kubernetes'` 加到 `$order` 数组里
3. 改 `assets/app.js`：在 `SECTIONS` 数组里加 `{ id: 'deep-kubernetes', title: 'Kubernetes' }`
4. `pwsh -File tools/new-note.ps1 -Section kubernetes -Title "Pod 生命周期"`
5. `pwsh -File tools/publish.ps1`

---

## 六、发布流程与原理

```
本地 .md
   │  build-manifest.ps1
   ▼
manifest.json（标题、行数、分区、摘要）
   │  git commit + push
   ▼
GitHub 仓库 main 分支
   │  GitHub Pages（分支部署，根目录）
   ▼
https://njhtr.github.io/baguwen/   ← 浏览器端 marked 渲染 md、app.js 驱动导航
```

- **部署方式**：GitHub Pages，源 = `main` 分支 `/` 根目录，`.nojekyll` 已关掉 Jekyll 处理
- **构建耗时**：推送后约 30 秒自动完成；构建记录在 `https://github.com/NJHTR/baguwen/actions`
- **缓存**：页面每次请求 `manifest.json` 带 `no-cache`，改完刷新就能看到；CDN 的 md 文件可能有几十秒延迟

**注意**：站点是在浏览器里 `fetch` md 文件再渲染的，所以**不能用 `file://` 直接双击打开 `index.html`**（浏览器禁止本地 fetch），必须走 http，例如 `tools/preview.ps1`。

---

## 七、提交身份（重要）

本仓库的提交身份固定为：

```
user.name  = NJHTR
user.email = 144709103+NJHTR@users.noreply.github.com
```

为什么用 noreply：

1. **不暴露真实邮箱**（GitHub 按邮箱归属作者，用真实邮箱会串到另一个账号）
2. **不暴露真实姓名**（提交里会显示 user.name，别写真名）

自查方式：

```bash
git config user.name
git config user.email
git log -1 --format="%an <%ae>"
```

改错了的后果与修复：见「故障排查」第 4 条。

---

## 八、隐私铁律

**这个仓库是公开的，只放通用技术内容。**

| 可以写 | 不要写 |
|---|---|
| 知识原理、代码示例、面试题 | 姓名、手机号、邮箱、微信 |
| 通用项目类型（如「政企系统」「电商平台」） | 真实公司名、客户名、学校名、GPA |
| 脱敏后的业务场景（如「报告查询慢」） | 内部系统域名、真实数据、密钥、账号 |
| 面试方法论 | 简历原文、offer、薪资 |

`tools/check.ps1` 会自动拦 `tools/pii-keywords.txt` 里的词与手机号/邮箱正则。**发现漏网之鱼就往这个文件里加一行。**

个人材料（简历、项目细节、面试记录）建议放在仓库**外面**，例如 `D:\interview-private\`。

---

## 九、故障排查

| 现象 | 原因 | 解决 |
|---|---|---|
| 页面 404 | Pages 没开或分支不对 | 仓库 Settings → Pages → Source 选 `main` / `(root)` |
| 页面能开但没内容 | `manifest.json` 没生成 | `pwsh -File tools/build-manifest.ps1` 后重发 |
| 新加的文件在站点上没有 | manifest 没更新 | 同上，`publish.ps1` 会自动跑 |
| 浏览器控制台 `fetch` 报错 | 用 `file://` 打开 | 改用 `tools/preview.ps1` |
| 推送被拒 `non-fast-forward` | 远端有新提交 | `git pull --rebase` 后再 `tools/publish.ps1` |
| 提交作者显示成别的账号 | 提交邮箱属于另一个 GitHub 账号 | 见下一节第 4 条 |
| 中文文件名链接 404 | 链接里含未编码的中文且大小写不符 | `check.ps1` 会报坏链接，按提示改 |
| Pages 构建失败 | 看 Actions 日志 | 多是 `index.html` 或 `manifest.json` 语法错误 |

### 1. 本地预览端口被占用

```bash
pwsh -File tools/preview.ps1 -Port 8888
```

### 2. 自检误报（隐私词/链接）

- 隐私词误报：把 `tools/pii-keywords.txt` 里对应行删掉或改精确
- 链接误报（代码块里的假链接）：`check.ps1` 已跳过含 `[,()]` 的写法；若仍有，可在该行改链接写法

### 3. 回滚一次发布

```bash
git log --oneline -5            # 找到要回退的提交
git revert <提交号>             # 生成一个反向提交（推荐，保留历史）
pwsh -File tools/publish.ps1 -Message "revert: 回滚 XXX"
```

### 4. 提交作者串号（历史问题）

如果 `git config user.email` 用了别的账号的邮箱，GitHub 会把提交归到那个账号下。修复：

```bash
git config user.name "NJHTR"
git config user.email "144709103+NJHTR@users.noreply.github.com"

# 只改最近一次提交的作者
git commit --amend --reset-author --no-edit

# 需要改写更多提交时，改完强制推送（先确认没有别人协作）
git push --force origin main
```

---

## 十、不要做的事

- **不要手改 `manifest.json`**：它是生成物，下次发布会覆盖
- **不要提交 `_preview/` 里的截图**：已在 `.gitignore` 里
- **不要在 md 里用 emoji**：`check.ps1` 会拦
- **不要用 `file://` 预览**
- **不要 `git push --force` 前不 `git fetch`**：避免覆盖别人的提交（目前只有你自己，但也先 fetch）
- **不要往仓库里放简历、合同、内部资料**

---

## 十一、相关文件

- 总索引：[README](README.md)
- 深度追问地图：[10-deep-dive/00-索引.md](10-deep-dive/00-索引.md)
- 学习节奏：[00-plan/路线图.md](00-plan/路线图.md)
