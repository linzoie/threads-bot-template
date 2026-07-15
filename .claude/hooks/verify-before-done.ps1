#!/usr/bin/env pwsh
# ============================================================
# verify-before-done.ps1  —  Stop hook
#
# 完成前把關：在能定位到「單一子專案 toolchain」時，跑 lint + 型別檢查 + 測試。
# 任一項失敗 → exit 2（把控制權交回 Claude，要求繼續修）。
# 在多子專案工作區根（定位不到單一子專案）→ 不硬擋，只輸出提醒 + exit 0。
#
# v2.1 變更（2026-07-09，vs v2）：
#   1) 失敗訊息改寫到 stderr —— exit 2 時 Claude 只收得到 stderr，
#      v2 全走 stdout 導致模型「被擋卻看不到原因」而亂修。
#      失敗時會把該項檢查輸出的最後 40 行一併給 Claude。
#   2) 讀 stdin JSON 並檢查 stop_hook_active —— 防止 Stop hook 無限迴圈
#      （官方建議；hook 已擋過一次後第二次直接放行）。
#   3) Python 分支支援統一測試入口 tests/run_all.py（本工作區 Python
#      專案多為純 assert 腳本、無 pytest；run_all.py 是可被機械執行的
#      DoD 入口）。pytest 仍支援（存在才跑）。
#   4) Node 分支優先跑 package.json 的 "verify" script（若存在，只跑它，
#      視為專案自定義的完整驗證入口）；否則照 v2 跑 lint/typecheck/test，
#      再否則 fallback prettier --check。
#
# v2.2 變更（2026-07-11，Task 5）：Node test script 解析 node --test spec
#   reporter 的 pass/fail 尾巴——exit 0 但 pass=0 且 fail=0（glob 沒中／全 skip）
#   視為「0 斷言被驗」擋下；非 spec 格式解析不到時僅 stderr 揭露不擋。
#   誠實邊界：擋不到「空斷言但 pass=1」的假測試（node --test 算它 pass）——
#   那是 fresh-verifier 的獵物，非本 hook 能機械偵測。
#   Python：pytest「無測試」回 exit 5，現行 exit-code 判斷已擋，無需改。
#
# 設計理由（沿襲 v2）：
#   `code/` 是多子專案容器；從工作區根 session 無法可靠推測使用者「正在處理
#   哪個子專案」，因此採「保守、不誤殺」策略。真正的「完成前驗證」由子專案
#   自己的 .claude/ 配置（透過 .governance 範本繼承）執行。
# ============================================================
$ErrorActionPreference = 'Continue'

# 0) 防迴圈：stop_hook_active 表示本 hook 已經擋過一次，這次放行
$raw = [Console]::In.ReadToEnd()
if ($raw) {
    try {
        $hookData = $raw | ConvertFrom-Json
        if ($hookData.stop_hook_active) {
            Write-Host 'verify: stop_hook_active=true（已擋過一輪），本次放行以免無限迴圈。'
            exit 0
        }
    } catch { }
}

$projectDir = $env:CLAUDE_PROJECT_DIR
if (-not $projectDir) { $projectDir = (Get-Location).Path }

# 解析 node --test spec reporter 尾巴的 pass/fail 計數。
# 回傳 @{pass;fail} 或 $null（無法解析——非 spec 格式）。
function Get-NodeTestSummary($output) {
    $text = ($output | ForEach-Object { "$_" }) -join "`n"
    $passM = [regex]::Match($text, '(?m)^\D*pass\s+(\d+)\s*$')
    $failM = [regex]::Match($text, '(?m)^\D*fail\s+(\d+)\s*$')
    if ($passM.Success -and $failM.Success) {
        return @{ pass = [int]$passM.Groups[1].Value; fail = [int]$failM.Groups[1].Value }
    }
    return $null
}

$venv = Join-Path $projectDir '.venv\Scripts\python.exe'
$pkgJson = Join-Path $projectDir 'package.json'

# 失敗回報：摘要 + 該檢查輸出的最後 40 行 → stderr（Claude 看得到）
function Fail([string]$summary, $output) {
    [Console]::Error.WriteLine("[STOP-HOOK] verify-before-done：$summary")
    if ($output) {
        $lines = @($output | ForEach-Object { "$_" })
        $tail = if ($lines.Count -gt 40) { $lines[-40..-1] } else { $lines }
        [Console]::Error.WriteLine('--- 失敗輸出（最後 40 行）---')
        foreach ($l in $tail) { [Console]::Error.WriteLine($l) }
    }
    [Console]::Error.WriteLine('請修復後再宣告完成（禁止在未通過驗證時宣稱「應該沒問題」）。')
    exit 2
}

# ──────────────────────────────────────────────────────────────
# 情境 1：session 根就是一個 Python 子專案（有 .venv\Scripts\python.exe）
# ──────────────────────────────────────────────────────────────
if (Test-Path -LiteralPath $venv) {
    Write-Host '=== Stop hook (verify-before-done): Python 子專案驗證 ==='

    # 1a) ruff lint
    $ruff = Join-Path $projectDir '.venv\Scripts\ruff.exe'
    if (Test-Path -LiteralPath $ruff) {
        Write-Host '--- ruff check ---'
        $out = & $ruff check -- "$projectDir" 2>&1
        $out | Out-Host
        if ($LASTEXITCODE -ne 0) { Fail 'ruff lint 失敗' $out }
    }

    # 1b) 型別檢查（若 mypy 存在）
    $mypy = Join-Path $projectDir '.venv\Scripts\mypy.exe'
    if (Test-Path -LiteralPath $mypy) {
        Write-Host '--- mypy ---'
        $out = & $mypy "$projectDir" 2>&1
        $out | Out-Host
        if ($LASTEXITCODE -ne 0) { Fail 'mypy 型別檢查失敗' $out }
    }

    # 1c) 統一測試入口（若 tests/run_all.py 存在 —— 純 assert 腳本專案用）
    $runAll = Join-Path $projectDir 'tests\run_all.py'
    if (Test-Path -LiteralPath $runAll) {
        Write-Host '--- python tests/run_all.py ---'
        Push-Location $projectDir
        try {
            $out = & $venv 'tests\run_all.py' 2>&1
            $out | Out-Host
            if ($LASTEXITCODE -ne 0) { Fail 'tests/run_all.py 測試未通過' $out }
        } finally { Pop-Location }
    }

    # 1d) pytest（若存在）
    $pytest = Join-Path $projectDir '.venv\Scripts\pytest.exe'
    if (Test-Path -LiteralPath $pytest) {
        Write-Host '--- pytest ---'
        $out = & $pytest -q "$projectDir" 2>&1
        $out | Out-Host
        if ($LASTEXITCODE -ne 0) { Fail 'pytest 測試未通過' $out }
    }

    exit 0
}

# ──────────────────────────────────────────────────────────────
# 情境 2：session 根是 Node 子專案（根目錄有 package.json）
# 優先序：verify script（專案自定義完整驗證）＞ lint/typecheck/test
# scripts ＞ prettier --check fallback
# ──────────────────────────────────────────────────────────────
if (Test-Path -LiteralPath $pkgJson) {
    Write-Host '=== Stop hook (verify-before-done): Node 子專案驗證 ==='

    if (-not (Test-Path -LiteralPath (Join-Path $projectDir 'node_modules'))) {
        # 零相依專案（無 node_modules）：若 test script 是原生 node --test（不需依賴），仍應驗證；
        # 否則（jest/vitest 等需依賴）維持略過，避免因未 install 誤擋。
        $testCmd = ''
        try { $p = Get-Content $pkgJson -Raw | ConvertFrom-Json; $testCmd = "$($p.scripts.test)" } catch { }
        if ($testCmd -match 'node\s+--test' -or $testCmd -match 'node:test') {
            Write-Host '--- npm test (零相依 node --test，無 node_modules 仍驗證) ---'
            Push-Location $projectDir
            try {
                $out = & npm run -s test 2>&1
                $out | Out-Host
                if ($LASTEXITCODE -ne 0) { Fail 'npm run test 未通過' $out }
                $sum = Get-NodeTestSummary $out
                if ($null -ne $sum -and $sum.pass -eq 0 -and $sum.fail -eq 0) {
                    Fail 'npm run test 實際驗證 0 個測試（pass=0 fail=0：glob 沒中或全部 skip）——視為未驗證' $out
                }
            } finally { Pop-Location }
            exit 0
        }
        Write-Host 'verify: node_modules 不存在，略過 Node 驗證（請先 pnpm/npm install）。'
        exit 0
    }

    # 讀 package.json 看有哪些 scripts
    $scripts = @()
    try {
        $pkg = Get-Content $pkgJson -Raw | ConvertFrom-Json
        if ($pkg.scripts) { $scripts = $pkg.scripts.PSObject.Properties.Name }
    } catch { }

    Push-Location $projectDir
    try {
        if ($scripts -contains 'verify') {
            # 專案自定義的統一驗證入口，只跑它
            Write-Host '--- npm run verify ---'
            $out = & npm run -s verify 2>&1
            $out | Out-Host
            if ($LASTEXITCODE -ne 0) { Fail 'npm run verify 未通過' $out }
            exit 0
        }

        $ran = $false
        foreach ($s in @('lint', 'typecheck', 'test')) {
            if ($scripts -contains $s) {
                Write-Host "--- npm run $s ---"
                $out = & npm run -s $s 2>&1
                $out | Out-Host
                if ($LASTEXITCODE -ne 0) { Fail "npm run $s 未通過" $out }
                # Task 5：test script exit 0 不代表有斷言被驗——node --test 對
                # 「glob 沒中／全 skip／空測試檔」都回 exit 0。解析 spec reporter
                # 尾巴（pass N / fail N）：pass=0 且 fail=0 → 0 個斷言被驗，擋下。
                # 解析不到（非 node --test 格式，如 vitest/jest）→ 不擋，僅 stderr 揭露。
                if ($s -eq 'test') {
                    $sum = Get-NodeTestSummary $out
                    if ($null -eq $sum) {
                        [Console]::Error.WriteLine('[verify] 注意：test 通過，但無法從輸出解析實跑測試數（非 node --test spec 格式？）——僅以 exit code 判定，未能確認斷言數 > 0，勿僅憑此宣稱「測試全綠」。')
                    } elseif ($sum.pass -eq 0 -and $sum.fail -eq 0) {
                        Fail "npm run test 實際驗證 0 個測試（pass=0 fail=0：glob 沒中或全部 skip）——視為未驗證，不予放行" $out
                    }
                }
                $ran = $true
            }
        }
        if (-not $ran) {
            # 沒有任一 script → 退到 prettier --check（最低限度的樣式把關）
            $prettier = Join-Path $projectDir 'node_modules\.bin\prettier.cmd'
            if (Test-Path -LiteralPath $prettier) {
                Write-Host '--- fallback: prettier --check . (package.json 無 verify/lint/typecheck/test scripts) ---'
                $out = & $prettier --check . 2>&1
                $out | Out-Host
                if ($LASTEXITCODE -ne 0) { Fail 'prettier --check 未通過' $out }
            } else {
                Write-Host 'verify: 無 npm scripts、也無 prettier，無實質驗證可跑（exit 0）'
            }
            # 誠實揭露：本專案無測試 script，「綠燈」只代表格式對、不代表行為對。
            # 對抗 DoD 語義稀釋（紅隊弱點 E）——弱模型別把此放行當「測試全綠」。
            [Console]::Error.WriteLine('[verify] 注意：本 Node 專案無 test/lint/typecheck script，Stop hook 只驗了格式（prettier），未驗行為。若本次改動涉及邏輯，DoD 的「測試全綠」尚未達成——請補測試或手動實跑確認，勿僅憑此放行宣稱完成。')
        }
    } finally {
        Pop-Location
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
