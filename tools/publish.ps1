# 一键发布：自检 -> 生成 manifest -> 提交 -> 推送（Pages 自动重建）
# 用法：
#   pwsh -File tools/publish.ps1                      # 自动生成提交信息
#   pwsh -File tools/publish.ps1 -Message "docs: 新增 X"   # 自定义提交信息
#   pwsh -File tools/publish.ps1 -DryRun              # 只看会提交什么，不真提交
#   pwsh -File tools/publish.ps1 -SkipChecks          # 跳过自检（不推荐）

param(
    [string]$Message = '',
    [switch]$DryRun,
    [switch]$SkipChecks
)

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

# 1) 先重新生成导航数据（自检会核对 manifest 是否覆盖全部 md）
& (Join-Path $PSScriptRoot 'build-manifest.ps1') | Out-Null
Write-Host '[完成] manifest.json 已更新'

# 2) 自检
if (-not $SkipChecks) {
    & (Join-Path $PSScriptRoot 'check.ps1')
    if ($LASTEXITCODE -ne 0) {
        Write-Host ''
        Write-Host '自检未通过，已中止发布。修完再跑一次，或加 -SkipChecks 强行发布。' -ForegroundColor Red
        exit 1
    }
}

# 3) 检查是否有变更
$changes = git status --porcelain
if (-not $changes) {
    Write-Host '没有任何变更，无需发布。' -ForegroundColor Yellow
    exit 0
}

# 4) 提交信息
if ($Message -eq '') {
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
    $Message = 'docs: 更新笔记 ' + $stamp
}

if ($DryRun) {
    Write-Host ''
    Write-Host '=== 将要提交的变更 ===' -ForegroundColor Cyan
    $changes
    Write-Host ''
    Write-Host ('提交信息：' + $Message) -ForegroundColor Cyan
    Write-Host '（DryRun 模式，未真正提交与推送）'
    exit 0
}

# 5) 提交并推送（正常时静默，失败时打印 git 原始输出）
git add -A 2>&1 | Out-Null
$commitOut = git commit -q -m $Message 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host '提交失败，请检查 git 状态。' -ForegroundColor Red
    $commitOut
    exit 1
}
$pushOut = git push origin main 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host '推送失败：检查网络与 GitHub 凭据。' -ForegroundColor Red
    $pushOut
    exit 1
}

Write-Host ''
Write-Host '发布完成。' -ForegroundColor Green
Write-Host '  Pages 约 30 秒后自动重建：https://njhtr.github.io/baguwen/'
Write-Host '  构建状态：https://github.com/NJHTR/baguwen/actions'
