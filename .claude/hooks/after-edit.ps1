#!/usr/bin/env pwsh
# ============================================================
# after-edit.ps1  —  PostToolUse hook (matcher: Edit|Write)
#
# 對「剛被改動的單一檔案」自動 format / lint：
#   .py            -> ruff check --fix + ruff format
#   .js/.ts/.json… -> prettier --write
# 工具不存在時安靜略過（永遠 exit 0，格式化失敗不阻擋流程）。
# 設計原則：只跑「快」的；完整測試交給 CI / 手動。
# ============================================================
$ErrorActionPreference = 'SilentlyContinue'

# 1) 讀取 hook 由 stdin 傳入的 JSON
$raw = [Console]::In.ReadToEnd()
if (-not $raw) { exit 0 }
try { $data = $raw | ConvertFrom-Json } catch { exit 0 }

$file = $data.tool_input.file_path
if (-not $file -or -not (Test-Path -LiteralPath $file)) { exit 0 }

$projectDir = $env:CLAUDE_PROJECT_DIR
if (-not $projectDir) { $projectDir = (Get-Location).Path }

$ext = [System.IO.Path]::GetExtension($file).ToLower()

# 2) Python 檔 -> ruff
if ($ext -eq '.py') {
    $ruff = $null
    $venvRuff = Join-Path $projectDir '.venv\Scripts\ruff.exe'
    if (Test-Path -LiteralPath $venvRuff) {
        $ruff = $venvRuff
    } elseif (Get-Command ruff -ErrorAction SilentlyContinue) {
        $ruff = 'ruff'
    }
    if (-not $ruff) { Write-Host 'after-edit: ruff 未安裝，略過'; exit 0 }
    & $ruff check --fix --quiet -- "$file" 2>&1 | Out-Host
    & $ruff format --quiet -- "$file"      2>&1 | Out-Host
    exit 0
}

# 3) Node / 前端檔 -> prettier
$nodeExts = @('.js', '.mjs', '.cjs', '.ts', '.jsx', '.tsx', '.json',
              '.css', '.scss', '.html', '.md', '.yml', '.yaml')
if ($nodeExts -contains $ext) {
    $prettier = Join-Path $projectDir 'node_modules\.bin\prettier.cmd'
    if (-not (Test-Path -LiteralPath $prettier)) {
        Write-Host 'after-edit: prettier 未安裝，略過'; exit 0
    }
    & $prettier --write --log-level warn -- "$file" 2>&1 | Out-Host
    exit 0
}

exit 0