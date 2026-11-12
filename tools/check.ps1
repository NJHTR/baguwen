# 本地检查：链接、emoji、隐私词、结构、manifest 新鲜度
# 用法：pwsh -File tools/check.ps1
# 退出码：0 全部通过；1 有失败项

param([switch]$Quiet)

$root = Split-Path -Parent $PSScriptRoot
$fail = 0

function Report([string]$name, [int]$bad, [string]$detail) {
    if ($bad -eq 0) {
        if (-not $Quiet) { Write-Host ("[通过] " + $name) -ForegroundColor Green }
    } else {
        Write-Host ("[失败] " + $name + "  " + $detail) -ForegroundColor Red
        $script:fail = $script:fail + 1
    }
}

$mdFiles = Get-ChildItem -LiteralPath $root -Recurse -File -Filter *.md |
    Where-Object { $_.FullName -notmatch '\\\.git\\|\\_preview\\|\\node_modules\\' }

# ---------- 1. 内部链接 ----------
$badLinks = @()
$linkCount = 0
foreach ($f in $mdFiles) {
    $txt = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
    foreach ($m in [regex]::Matches($txt, '\]\(([^)#\s]+)\)')) {
        $t = $m.Groups[1].Value
        if ($t -match '^[a-z][a-z0-9+.-]*:') { continue }   # 外链
        if ($t -match '[,()]') { continue }                 # 代码里的假链接
        if ($t -notmatch '\.(md|txt|png|jpg|jpeg|svg|json|ps1|js|css|html)$') { continue }   # 非文件路径
        $linkCount = $linkCount + 1
        $p = $t
        if (-not [System.IO.Path]::IsPathRooted($t)) { $p = Join-Path $f.DirectoryName $t }
        if (-not (Test-Path -LiteralPath $p)) {
            $badLinks += ($f.Name + " -> " + $t)
        }
    }
}
Report ("内部链接（共 " + $linkCount + " 条）") $badLinks.Count ($badLinks -join '; ')

# ---------- 2. emoji / 表情符号 ----------
$emojiRe = '[\u2600-\u27BF\u2B00-\u2BFF\uFE0F]|[\uD800-\uDBFF][\uDC00-\uDFFF]'
$badEmoji = @()
foreach ($f in $mdFiles) {
    $txt = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
    if ([regex]::IsMatch($txt, $emojiRe)) { $badEmoji += $f.Name }
}
Report "emoji 符号" $badEmoji.Count ($badEmoji -join ', ')

# ---------- 3. 隐私词 ----------
# 关键词表在 tools/pii-keywords.txt，一行一个；以 re: 开头表示正则
$kwFile = Join-Path $PSScriptRoot 'pii-keywords.txt'
$hits = @()
if (Test-Path -LiteralPath $kwFile) {
    $rules = Get-Content -LiteralPath $kwFile -Encoding UTF8 |
        Where-Object { $_.Trim() -ne '' -and -not $_.TrimStart().StartsWith('#') }
    $scanFiles = Get-ChildItem -LiteralPath $root -Recurse -File |
        Where-Object { $_.Extension -in '.md', '.html', '.js', '.json', '.txt', '.ps1' -and $_.FullName -notmatch '\\\.git\\|\\_preview\\|\\node_modules\\' -and $_.Name -ne 'pii-keywords.txt' }
    foreach ($f in $scanFiles) {
        $txt = try { [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8) } catch { '' }
        foreach ($r in $rules) {
            $rule = $r.Trim()
            if ($rule.StartsWith('re:')) {
                if ([regex]::IsMatch($txt, $rule.Substring(3))) { $hits += ($f.Name + " ~ " + $rule) }
            } else {
                if ($txt.Contains($rule)) { $hits += ($f.Name + " ~ " + $rule) }
            }
        }
    }
}
Report "隐私关键词" $hits.Count ($hits -join '; ')

# ---------- 4. 深度追问文件结构 ----------
$deepFiles = Get-ChildItem -LiteralPath (Join-Path $root '10-deep-dive') -Recurse -File -Filter *.md |
    Where-Object { $_.Name -notmatch '^00-' }
$structBad = @()
foreach ($f in $deepFiles) {
    $txt = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
    $lines = ($txt -split "`r?`n").Count - 1
    $hasL = ($txt.Contains('## L1')) -and ($txt.Contains('## L2')) -and ($txt.Contains('## L3')) -and
            ($txt.Contains('## L4')) -and ($txt.Contains('## L5'))
    $layers = ([regex]::Matches($txt, '(?m)^### 第 \d+ 层')).Count
    if (-not $hasL) { $structBad += ($f.Name + " 缺 L1-L5 之一") }
    elseif ($layers -lt 10) { $structBad += ($f.Name + " 追问层仅 " + $layers) }
    elseif ($lines -lt 100) { $structBad += ($f.Name + " 仅 " + $lines + " 行") }
}
Report ("深度文件结构（" + $deepFiles.Count + " 篇）") $structBad.Count ($structBad -join '; ')

# ---------- 5. manifest 是否覆盖全部 md ----------
$manifestPath = Join-Path $root 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    Report "manifest.json" 1 "文件不存在，请运行 tools/build-manifest.ps1"
} else {
    $man = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $listed = @{}
    foreach ($item in $man.files) { $listed[$item.path] = $true }
    $missing = @()
    foreach ($f in $mdFiles) {
        $rel = $f.FullName.Substring($root.Length + 1) -replace '\\', '/'
        if (-not $listed.ContainsKey($rel)) { $missing += $rel }
    }
    Report ("manifest 覆盖（" + $man.files.Count + " 条）") $missing.Count (($missing | Select-Object -First 5) -join ', ')
}

# ---------- 汇总 ----------
Write-Host ''
if ($fail -eq 0) {
    Write-Host ("检查通过，可以发布。") -ForegroundColor Green
    exit 0
} else {
    Write-Host ("有 " + $fail + " 项未通过，先修再发布。") -ForegroundColor Red
    exit 1
}
