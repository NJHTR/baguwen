# 生成 manifest.json —— 页面导航的唯一数据源
# 用法（在仓库根目录）：
#   pwsh -File tools/build-manifest.ps1
# 新增笔记后重跑一次即可，页面无需改代码。

param([string]$Root = (Split-Path -Parent $PSScriptRoot))

$root = (Resolve-Path $Root).Path
$files = Get-ChildItem -LiteralPath $root -Recurse -File -Filter *.md |
    Where-Object { $_.FullName -notmatch '\\\.git\\' -and $_.FullName -notmatch '\\node_modules\\' }

function Get-Section([string]$rel) {
    $p = $rel -replace '\\', '/'
    if ($p -eq 'README.md') { return 'start' }
    if ($p -eq 'MAINTENANCE.md') { return 'start' }
    if ($p -like '00-plan/*') { return 'plan' }
    if ($p -like '10-deep-dive/01-*') { return 'start' }
    if ($p -like '10-deep-dive/00-*') { return 'deep-index' }
    if ($p -like '10-deep-dive/distributed/*') { return 'deep-distributed' }
    if ($p -like '10-deep-dive/network/*') { return 'deep-network' }
    if ($p -like '10-deep-dive/ops/*') { return 'deep-ops' }
    if ($p -like '10-deep-dive/js/*') { return 'deep-js' }
    if ($p -like '10-deep-dive/java/*') { return 'deep-java' }
    if ($p -like '10-deep-dive/spring/*') { return 'deep-spring' }
    if ($p -like '10-deep-dive/mysql/*') { return 'deep-mysql' }
    if ($p -like '10-deep-dive/redis/*') { return 'deep-redis' }
    if ($p -like '10-deep-dive/middleware/*') { return 'deep-middleware' }
    if ($p -like '10-deep-dive/backend-opt/*') { return 'deep-backend' }
    if ($p -like '01-js/*') { return 'breadth-js' }
    if ($p -like '02-vue/*') { return 'breadth-vue' }
    if ($p -like '03-java/*') { return 'breadth-java' }
    if ($p -like '04-database/*') { return 'breadth-db' }
    if ($p -like '05-network/*') { return 'breadth-net' }
    if ($p -like '06-system-design/*') { return 'breadth-design' }
    if ($p -like '07-algorithm/*') { return 'breadth-algo' }
    if ($p -like '08-project/*') { return 'breadth-project' }
    if ($p -like '09-mock/*') { return 'breadth-mock' }
    return 'other'
}

$output = New-Object System.Collections.ArrayList
foreach ($f in $files) {
    $rel = $f.FullName.Substring($root.Length + 1) -replace '\\', '/'
    $text = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
    $lines = ($text -split "`r?`n").Count
    # 标题：取第一个 "# " 开头的行；没有就用文件名
    $title = $null
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^#\s+(.+)$') { $title = $Matches[1].Trim(); break }
    }
    if (-not $title) { $title = [System.IO.Path]::GetFileNameWithoutExtension($rel) }
    # 首段摘要：标题后第一段非空非引用文字，截 90 字
    $summary = ''
    $seenTitle = $false
    foreach ($line in ($text -split "`r?`n")) {
        $t = $line.Trim()
        if (-not $seenTitle) { if ($t -match '^#\s+') { $seenTitle = $true }; continue }
        if ($t -eq '' -or $t -match '^[->|`#\[]' -or $t -match '^\*\*本文件用法') { continue }
        $summary = $t -replace '\*\*', '' -replace '\[([^\]]+)\]\([^)]+\)', '$1'
        if ($summary.Length -gt 90) { $summary = $summary.Substring(0, 90) + '…' }
        break
    }
    [void]$output.Add([pscustomobject][ordered]@{
        path    = $rel
        title   = $title
        lines   = $lines
        section = (Get-Section $rel)
        summary = $summary
    })
}

# 排序：开始 → 计划 → 深度层 → 广度层
$order = @('start','plan','deep-index','deep-js','deep-java','deep-spring','deep-mysql','deep-redis','deep-middleware','deep-distributed','deep-network','deep-ops','deep-backend','breadth-js','breadth-vue','breadth-java','breadth-db','breadth-net','breadth-design','breadth-algo','breadth-project','breadth-mock','other')
$sorted = $output | Sort-Object @{ Expression = { [array]::IndexOf($order, $_.section) } }, @{ Expression = { $_.path } }

$totalLines = ($sorted | ForEach-Object { [int]$_.lines } | Measure-Object -Sum).Sum
$manifest = [ordered]@{
    generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    files       = @($sorted)
    stats       = [ordered]@{
        files = @($sorted).Count
        lines = $totalLines
    }
}

$json = $manifest | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText((Join-Path $root 'manifest.json'), $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Output ("manifest.json 已生成：{0} 个文件，{1} 行" -f @($sorted).Count, $totalLines)
