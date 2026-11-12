# 新建一个深度追问知识点文件（自动编号 + 生成 L1-L5 骨架）
# 用法：
#   pwsh -File tools/new-note.ps1 -Section java -Title "Spring Bean 作用域"
#   pwsh -File tools/new-note.ps1 -Section distributed -Title "服务熔断状态机"
# 分区名就是 10-deep-dive 下的目录名：java / spring / mysql / redis / middleware /
#   distributed / network / ops / backend-opt / js

param(
    [Parameter(Mandatory = $true)][string]$Section,
    [Parameter(Mandatory = $true)][string]$Title,
    [string]$Depth = 'L5（待填写：终局落在哪一层）'
)

$root = Split-Path -Parent $PSScriptRoot
$dir = Join-Path $root (Join-Path '10-deep-dive' $Section)
if (-not (Test-Path -LiteralPath $dir)) {
    Write-Host ("分区不存在：" + $dir) -ForegroundColor Red
    Write-Host "可用分区：" -NoNewline
    Get-ChildItem -LiteralPath (Join-Path $root '10-deep-dive') -Directory | ForEach-Object { Write-Host (" " + $_.Name) -NoNewline }
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

# 文件名安全化：去掉 Windows 非法字符与空白
$safeTitle = $Title -replace '[\\/:*?"<>|\s]', ''
if ($safeTitle -eq '') { Write-Host "标题里没有可用字符" -ForegroundColor Red; exit 1 }
$fileName = ('{0:D2}-{1}.md' -f $next, $safeTitle)
$filePath = Join-Path $dir $fileName
if (Test-Path -LiteralPath $filePath) { Write-Host ("已存在：" + $filePath) -ForegroundColor Red; exit 1 }

$template = @'
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

### 2.2 <一次完整流程>

```
<时序或数据流>
```

---

## L3 底层层

### 3.1 <源码/内核/协议字段>

- <要点>

### 3.2 <关键数据结构或参数>

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
|  |  |  |  |
|  |  |  |  |
|  |  |  |  |
|  |  |  |  |
|  |  |  |  |
|  |  |  |  |
|  |  |  |  |
|  |  |  |  |
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

$content = $template.Replace('__TITLE__', $Title).Replace('__DEPTH__', $Depth)
[System.IO.File]::WriteAllText($filePath, $content, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ("已创建：" + $filePath) -ForegroundColor Green
Write-Host ''
Write-Host '下一步：'
Write-Host '  1) 按 L1-L5 填内容（追问树至少 10 层，名词表至少 10 行）'
Write-Host '  2) 在 10-deep-dive/00-索引.md 的对应分区表里补一行'
Write-Host '  3) pwsh -File tools/check.ps1     # 自检'
Write-Host '  4) pwsh -File tools/publish.ps1   # 发布'
