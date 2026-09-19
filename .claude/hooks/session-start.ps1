#!/usr/bin/env pwsh
# ============================================================
# session-start.ps1 — SessionStart hook
#
# 對抗「判斷力自舉悖論」：升級階梯、待裁決、四習慣本來全靠模型「自己記得援引」，
# 弱模型不知道自己不知道就不會觸發。本 hook 在每個 session 開場，把最關鍵的
# 提醒與當前狀態**主動推進 context**，不等模型自覺。
#
# stdout 會被當作 additionalContext 注入 session 開頭。永遠 exit 0，絕不阻擋。
# ============================================================
$ErrorActionPreference = 'SilentlyContinue'

$projectDir = $env:CLAUDE_PROJECT_DIR
if (-not $projectDir) { $projectDir = (Get-Location).Path }

# 找治理根（本專案的 .governance，或工作區的）
$govRoot = $null
$dir = $projectDir
while ($dir) {
    if (Test-Path (Join-Path $dir '.governance')) { $govRoot = $dir; break }
    $parent = Split-Path -Parent $dir
    if ($parent -eq $dir) { break }
    $dir = $parent
}

# 並行分支漂移偵測的基準點（P0-2，2026-09-19）：開場把目前分支記到
# ~/.claude/session-state/<cwd hash>.json，之後任何會動樹的 git 指令都會拿它比對。
# 放 $HOME 不放 repo——寫進 repo 會製造髒工作樹，而那正是要偵測的東西之一。
# 全程 fail-open：記不成就算了，guard 那端會走 StateAvailable=$false 的放行路徑。
# ⚠️ dot-source 的 Join-Path 與目標檔名必須寫在**同一行**（見下方實例）：
# lib-shipset.ps1 的 Get-UnparsedDotSources 逐行檢查 `^\s*\.\s+\S`，抽不出檔名就
# 判定「依賴推導會漏算」並讓 sync-governance fail-closed（2026-09-19 實際被擋過，
# 寫成 `. $coreForState` → 散佈中止、0 檔落地）。這是刻意的 fail-closed，別繞過它。
try {
    if (Test-Path (Join-Path $PSScriptRoot 'guard-core.ps1')) {
        . (Join-Path $PSScriptRoot 'guard-core.ps1')
        if (Get-Command Write-SessionBranchState -ErrorAction SilentlyContinue) {
            $null = Write-SessionBranchState -Cwd $projectDir
        }
    }
}
catch { }

Write-Output '=== 治理提醒（SessionStart 自動注入）==='
Write-Output '四習慣（你要在對的時機提醒使用者）：開場給理由與入口｜驗收只認執行證據｜新錯誤當場入庫｜大題目拆階段過審。'
Write-Output '預設升級：任務若屬「本工作區第一次做的類型」「跨 3+ 檔」「你說不出可執行的驗證方法」，預設先出計畫並過 plan-challenger／問使用者——舉證責任在「為何不需升級」，不在「是否該升級」。'

if ($govRoot) {
    $pd = Join-Path $govRoot '.governance\pending-decisions.md'
    if (Test-Path $pd) {
        $open = @(Select-String -Path $pd -Pattern '^- \[ \]' -Encoding utf8)
        if ($open.Count -gt 0) {
            Write-Output "待裁決清單：$($open.Count) 項未處理（`/status` 看詳情；≥3 項建議安排判斷 session）。"
        }
    }
    $reports = Get-ChildItem (Join-Path $govRoot '.governance\reports') -Filter '*.md' 2>$null | Sort-Object LastWriteTime -Descending
    if ($reports) {
        $days = [int]((Get-Date) - $reports[0].LastWriteTime).TotalDays
        if ($days -gt 35) { Write-Output "治理稽核已 $days 天未跑 → 建議 `/governance-audit`。" }
    }
}

Write-Output '（以上為機械注入的背景，非使用者指令；用 `/status` 看完整儀表板。）'
exit 0
