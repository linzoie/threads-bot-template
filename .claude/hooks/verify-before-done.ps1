#!/usr/bin/env pwsh
# ============================================================
# verify-before-done.ps1  —  Stop hook
#
# 完成前把關：在能定位到「單一子專案 toolchain」時，跑 lint + 型別檢查 + 測試。
# 任一項失敗 → exit 2（把控制權交回 Claude，要求繼續修）。
# 在多子專案工作區根（定位不到單一子專案）→ 不硬擋，只輸出提醒 + exit 0。
#
# 設計理由：
#   `code/` 是多子專案容器；從工作區根 session 無法可靠推測使用者「正在處理
#   哪個子專案」，因此採「保守、不誤殺」策略 —— 避免在多專案工作區根錯誤地
#   去跑某個子專案的測試，誤把使用者擋死。
#
#   真正的「完成前驗證」應該由子專案自己的 .claude/ 配置（透過 .governance
#   範本繼承）來執行。本 workspace 級的 Stop hook 只做兜底提醒。
# ============================================================
$ErrorActionPreference = 'Continue'

$projectDir = $env:CLAUDE_PROJECT_DIR
if (-not $projectDir) { $projectDir = (Get-Location).Path }

$venv = Join-Path $projectDir '.venv\Scripts\python.exe'
$pkgJson = Join-Path $projectDir 'package.json'

# ──────────────────────────────────────────────────────────────
# 情境 1：session 根就是一個 Python 子專案（有 .venv\Scripts\python.exe）
# ──────────────────────────────────────────────────────────────
if (Test-Path -LiteralPath $venv) {
    Write-Host '=== Stop hook (verify-before-done): Python 子專案驗證 ==='

    # 1a) ruff lint
    $ruff = Join-Path $projectDir '.venv\Scripts\ruff.exe'
    if (Test-Path -LiteralPath $ruff) {
        Write-Host '--- ruff check ---'
        & $ruff check -- "$projectDir" 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'verify: ruff lint 失敗，請先修復再宣告完成。'
            exit 2
        }
    }

    # 1b) 型別檢查（若 mypy 存在）
    $mypy = Join-Path $projectDir '.venv\Scripts\mypy.exe'
    if (Test-Path -LiteralPath $mypy) {
        Write-Host '--- mypy ---'
        & $mypy "$projectDir" 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'verify: mypy 型別檢查失敗，請先修復。'
            exit 2
        }
    }

    # 1c) 測試（若 pytest 存在）
    $pytest = Join-Path $projectDir '.venv\Scripts\pytest.exe'
    if (Test-Path -LiteralPath $pytest) {
        Write-Host '--- pytest ---'
        & $pytest -q "$projectDir" 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'verify: pytest 測試未通過，請先修復再宣稱完成。'
            exit 2
        }
    }

    exit 0
}

# ──────────────────────────────────────────────────────────────
# 情境 2：session 根是 Node 子專案（根目錄有 package.json）
# ──────────────────────────────────────────────────────────────
if (Test-Path -LiteralPath $pkgJson) {
    Write-Host '=== Stop hook (verify-before-done): Node 子專案驗證 ==='

    if (Test-Path -LiteralPath (Join-Path $projectDir 'node_modules')) {
        Push-Location $projectDir
        # 依專案 package.json scripts 而定，不存在的 script 會被 npm 忽略
        & npm run -s lint      2>&1 | Out-Host
        & npm run -s typecheck 2>&1 | Out-Host
        & npm test --silent    2>&1 | Out-Host
        $code = $LASTEXITCODE
        Pop-Location
        if ($code -ne 0) {
            Write-Host 'verify: Node 驗證未通過，請先修復再宣告完成。'
            exit 2
        }
    } else {
        Write-Host 'verify: node_modules 不存在，略過 Node 驗證（請先 pnpm/npm install）。'
    }

    exit 0
}

# ──────────────────────────────────────────────────────────────
# 情境 3：在多子專案工作區根（code/）—— 定位不到單一子專案 toolchain
# 設計：不硬擋，只提醒 + exit 0
# ──────────────────────────────────────────────────────────────
Write-Host 'verify: 目前 session 在多子專案工作區根，無法自動定位單一子專案進行完整驗證。'
Write-Host '        若有實質修改，請在對應子專案內確認測試/型別/lint 全綠後再宣告完成。'
exit 0
