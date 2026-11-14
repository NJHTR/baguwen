# 新建知识点文件（自动编号 + 生成骨架）
# 两种模式：
#   -Area deep     -> 10-deep-dive/<分区>/  （速查 + 追问树，L1-L5 结构）
#   -Area lecture  -> 11-lectures/<分区>/   （教材式精讲，14 节结构）
#
# 用法：
#   pwsh -File tools/new-note.ps1 -Section java -Title "Spring Bean 作用域"
#   pwsh -File tools/new-note.ps1 -Area lecture -Section mysql -Title "B+树索引"

param(
    [Parameter(Mandatory = $true)][string]$Section,
    [Parameter(Mandatory = $true)][string]$Title,
    [ValidateSet('deep', 'lecture')][string]$Area = 'deep',
    [string]$Depth = 'L5（待填写：终局落在哪一层）'
)

$root = Split-Path -Parent $PSScriptRoot
if ($Area -eq 'lecture') {
    $baseDir = Join-Path $root '11-lectures'
} else {
    $baseDir = Join-Path $root '10-deep-dive'
}
$dir = Join-Path $baseDir $Section
if (-not (Test-Path -LiteralPath $dir)) {
    Write-Host ("分区不存在：" + $dir) -ForegroundColor Red
    Write-Host ("可用分区（" + $Area + "）：") -NoNewline
    Get-ChildItem -LiteralPath $baseDir -Directory | ForEach-Object { Write-Host (" " + $_.Name) -NoNewline }
    Write-Host ''
    exit 1
}

# 计算下一个编号
$maxNo = 0
Get-ChildItem -LiteralPath $dir -File -Filter *.md | ForEach-Object {
    if ($_.Name -match '^(\d+)-') {
        $n = [int]$Matches[1]
        if ($n -gt $maxNo) { $maxNo = $n }
    }
}
$next = $maxNo + 1

# 文件名安全化
$safeTitle = $Title -replace '[\\/:*?"<>|\s]', ''
if ($safeTitle -eq '') { Write-Host "标题里没有可用字符" -ForegroundColor Red; exit 1 }
$fileName = ('{0:D2}-{1}.md' -f $next, $safeTitle)
$filePath = Join-Path $dir $fileName
if (Test-Path -LiteralPath $filePath) { Write-Host ("已存在：" + $filePath) -ForegroundColor Red; exit 1 }

$deepTemplate = @'
# __TITLE__

> 面试权重：_/5　｜　追问深度：**__DEPTH__**
> 一句话定位：<一句话说清它是什么、为什么会被问、答不上来会暴露什么>
> 返回：[深度追问索引](../00-索引.md)

---

## L1 一句话答案（十秒能说出口）

<15-40 字，能直接说出口的结论>

---

## L2 原理层

### 2.1 <机制/流程>

- <要点>

---

## L3 底层层

### 3.1 <源码/内核/协议字段>

- <要点>

---

## L4 追问树

### 第 1 层｜<面试官第一问>
**答**：<一句话 + 展开>

### 第 2 层｜<顺着往下问>
**答**：

### 第 3 层｜
**答**：

### 第 4 层｜
**答**：

### 第 5 层｜
**答**：

### 第 6 层｜
**答**：

### 第 7 层｜
**答**：

### 第 8 层｜
**答**：

### 第 9 层｜
**答**：

### 第 10 层（终局）｜<终极追问>
**答**：<落到源码/内核/协议字段>

---

## L5 名词拆解表

| 名词 | 是什么 | 为什么存在 | 面试追问点 |
|---|---|---|---|
|  |  |  |  |

---

## 代码验证

```java
// 可直接编译运行的最小片段
```

---

## 高频错误

| 错误说法 | 正确说法 |
|---|---|
|  |  |

---

## 关联文件

- [深度追问索引](../00-索引.md)
- [README](../../README.md)

---

## 自测标准

<什么程度算过关：能从 L1 讲到第几层、能跑通哪段代码>
'@

$lectureTemplate = @'
# __TITLE__

> 精讲层级：从「零基础能看懂」到「源码级」，每个名词都拆开
> 阅读时间：约 25 分钟
> 返回：[精讲索引](../00-索引.md)

---

## 0. 一句话先讲明白

<先用一段话说清它是什么、解决什么问题，并附上关键源码>

---

## 1. 它解决什么问题（先讲痛点）

<不要先给定义，先讲「没有它会发生什么」>

---

## 2. 一步步拆开

### 2.1 <第一步>

<源码逐行 + 图示>

---

## 3. 完整推导

<把「为什么有效」算出来：二进制、字节数、概率、时序>

---

## 4. 极简模型

<把规模缩小：4 位整数 / 3 个节点 / 2 张表>

---

## 5. 为什么这样设计

### 5.1 被否决的方案 A
- 做法：
- 为什么否决：

### 5.2 被否决的方案 B
- 做法：
- 为什么否决：

---

## 6. 关键参数为什么是这个值

<阈值、容量、超时、重试次数等，逐个解释来历>

---

## 7. 版本演进

| 版本 | 变化 | 影响 |
|---|---|---|

---

## 8. 亲手验证

```java
// 可直接编译运行
```

**预期输出：**

```
<输出片段>
```

---

## 9. 常见误区

| 错误说法 | 正确说法 |
|---|---|
|  |  |
|  |  |
|  |  |
|  |  |
|  |  |
|  |  |

---

## 10. 连续追问 Q&A

### Q1
<先给答案，再解释>

### Q2

### Q3

### Q4

### Q5

### Q6

### Q7

### Q8

### Q9

### Q10

---

## 11. 一张图总结

```
<ASCII 图>
```

---

## 12. 一句话复盘

> <把整篇压成一句话>

---

## 13. 自测题

**1. <问题>**
答案：

**2. <问题>**
答案：

**3. <问题>**
答案：

**4. <问题>**
答案：

**5. <问题>**
答案：

---

## 14. 关联文件

- 深一层（追问树 + 源码细节）：[对应深度追问](../../10-deep-dive/)
- 返回：[精讲索引](../00-索引.md)
'@

if ($Area -eq 'lecture') {
    $content = $lectureTemplate.Replace('__TITLE__', $Title)
} else {
    $content = $deepTemplate.Replace('__TITLE__', $Title).Replace('__DEPTH__', $Depth)
}

[System.IO.File]::WriteAllText($filePath, $content, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ("已创建：" + $filePath) -ForegroundColor Green
Write-Host ''
Write-Host '下一步：'
if ($Area -eq 'lecture') {
    Write-Host '  1) 按 14 节填内容（380-600 行；术语首现即解释；≥2 个被否决方案；Q&A ≥10 问）'
    Write-Host '  2) 在 11-lectures/00-索引.md 里补一行'
} else {
    Write-Host '  1) 按 L1-L5 填内容（追问树至少 10 层，名词表至少 10 行）'
    Write-Host '  2) 在 10-deep-dive/00-索引.md 的对应分区表里补一行'
}
Write-Host '  3) pwsh -File tools/check.ps1     # 自检'
Write-Host '  4) pwsh -File tools/publish.ps1   # 发布'
