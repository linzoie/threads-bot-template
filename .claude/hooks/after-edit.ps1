#!/usr/bin/env pwsh
# ============================================================
# after-edit.ps1  —  PostToolUse hook (matcher: Edit|Write|MultiEdit)
#
# 對「剛被改動的單一檔案」自動 format / lint：
#   .py            -> ruff check --fix + ruff format
#   .js/.ts/.json… -> prettier --write
#
# v2 變更（vs v1，2026-05-25 升級）：
#   1) 改成從「被改檔案」目錄一層層往上找最近的 .venv / node_modules
#      —— 解決從 code/ 工作區根啟動 session 時，hook 用 $CLAUDE_PROJECT_DIR
#         找不到子專案 toolchain 而對所有子專案靜默無作用的問題。
#   2) matcher 加入 MultiEdit；file_path 抓不到時 fallback 到 .path
#      （MultiEdit 的 stdin JSON 結構未驗證；雙重 fallback 涵蓋兩種常見可能）。
#
# 工具不存在就靜默略過（永遠 exit 0，不阻擋流程）。
# ============================================================
$ErrorActionPreference = 'SilentlyContinue'

# 1) 讀取 hook 由 stdin 傳入的 JSON
$raw = [Console]::In.ReadToEnd()
if (-not $raw) { exit 0 }
try { $data = $raw | ConvertFrom-Json } catch { exit 0 }

# 2) 取得被改檔案路徑（Edit/Write 用 file_path；MultiEdit 可能用 path）
$file = $data.tool_input.file_path
if (-not $file) { $file = $data.tool_input.path }
if (-not $file -or -not (Test-Path -LiteralPath $file)) { exit 0 }

# 3) 從某個起始目錄一層層往上找符合 marker 的檔案，找到即回傳完整路徑
function Find-Up([string]$startDir, [string]$relativeMarker) {
    $dir = $startDir
    while ($dir) {
        $candidate = Join-Path $dir $relativeMarker
        if (Test-Path -LiteralPath $candidate) { return $candidate }
        $parent = Split-Path -Parent $dir
        if ($parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

$fileDir = Split-Path -Parent $file
$ext = [System.IO.Path]::GetExtension($file).ToLower()

# 4) Python -> ruff（找最近的 .venv\Scripts\ruff.exe，再 fallback 全域 ruff）
if ($ext -eq '.py') {
    $ruff = Find-Up $fileDir '.venv\Scripts\ruff.exe'
    if (-not $ruff) {
        if (Get-Command ruff -ErrorAction SilentlyContinue) { $ruff = 'ruff' }
    }
    if (-not $ruff) { Write-Host 'after-edit: ruff 未找到，略過'; exit 0 }
    & $ruff check --fix --quiet -- "$file" 2>&1 | Out-Host
    & $ruff format --quiet -- "$file"      2>&1 | Out-Host
    exit 0
}

# 5) Node / 前端 -> prettier（找最近的 node_modules\.bin\prettier.cmd）
$nodeExts = @('.js', '.mjs', '.cjs', '.ts', '.jsx', '.tsx', '.json',
              '.css', '.scss', '.html', '.md', '.yml', '.yaml')
if ($nodeExts -contains $ext) {
    $prettier = Find-Up $fileDir 'node_modules\.bin\prettier.cmd'
    if (-not $prettier) { Write-Host 'after-edit: prettier 未找到，略過'; exit 0 }
    & $prettier --write --log-level warn -- "$file" 2>&1 | Out-Host
    exit 0
}

exit 0
