# 本地预览：先生成 manifest，再起一个静态服务器
# 用法：pwsh -File tools/preview.ps1            （默认 8080 端口）
#       pwsh -File tools/preview.ps1 -Port 8888
# 停止：Ctrl + C

param(
    [int]$Port = 8080,
    [string]$PythonPath = ''
)

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

& (Join-Path $PSScriptRoot 'build-manifest.ps1') | Out-Null

Write-Host ''
Write-Host ('预览地址：http://127.0.0.1:' + $Port + '/') -ForegroundColor Green
Write-Host '按 Ctrl + C 停止'
Write-Host ''

# 1) 显式指定优先
if ($PythonPath -ne '' -and (Test-Path -LiteralPath $PythonPath)) {
    & $PythonPath -m http.server $Port --bind 127.0.0.1
    exit $LASTEXITCODE
}
# 2) PATH 里的 python / python3
$python = Get-Command python -ErrorAction SilentlyContinue
if ($python) {
    & python -m http.server $Port --bind 127.0.0.1
    exit $LASTEXITCODE
}
$python3 = Get-Command python3 -ErrorAction SilentlyContinue
if ($python3) {
    & python3 -m http.server $Port --bind 127.0.0.1
    exit $LASTEXITCODE
}
# 3) Windows 常见安装位置
$candidates = @()
$candidates += (Get-ChildItem "$env:LOCALAPPDATA\Programs\Python" -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'python.exe' })
$candidates += 'C:\Python312\python.exe', 'C:\Python311\python.exe', 'C:\Python310\python.exe'
foreach ($c in $candidates) {
    if ($c -and (Test-Path -LiteralPath $c)) {
        & $c -m http.server $Port --bind 127.0.0.1
        exit $LASTEXITCODE
    }
}

$npx = Get-Command npx -ErrorAction SilentlyContinue
if ($npx) {
    Write-Host '未找到 python，改用 npx serve' -ForegroundColor Yellow
    & npx --yes serve -l $Port .
    exit $LASTEXITCODE
}

Write-Host '没有找到 python / python3 / npx，无法启动本地服务器。' -ForegroundColor Red
Write-Host '可以安装 Python，或直接用线上站点预览。'
exit 1
