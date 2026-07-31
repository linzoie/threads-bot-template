#!/usr/bin/env pwsh
# ============================================================
# guard-bash.ps1 — PreToolUse hook（matcher: Bash|PowerShell）
#                  Claude Code adapter（薄 shim over guard-core.ps1）
#
# v4（2026-07-25，Option 3 三家守門對等）：**判定邏輯全數下沉共用核心
#   guard-core.ps1**（`Get-GuardVerdict`，含 cmd 正規化 caret/黏連旗標/%VAR%/
#   verb-anywhere）。本檔只剩 Claude 側 I/O 與可觀測性：讀 stdin、把 core 回的
#   verdict 映射成 Claude 的 exit code / 巢狀 permissionDecision、Write-GovLog、
#   ask-flood 前綴。Antigravity/Codex adapter 各自呼叫同一 core → 三家守同一套
#   判定（cmd 正規化含在 core，不再各家漂移）。
#
# 三級處置（decision 由 core 回）：
#   - deny：exit 2 + stderr（災難級、不可逆）
#   - ask ：permissionDecision "ask"（使用者「破壞性／難復原一律先問」清單）
#   - pass：exit 0
#
# stdin 解析失敗一律 fail-open（exit 0）——沒有指令可判，不是防護失效。
#
# **core 載入失敗＝fail-visible ASK，不是 fail-open**（2026-07-26 紅隊實測後改）：
#   舊版只用 `Test-Path` 判斷 core 在不在，而且 $ErrorActionPreference='SilentlyContinue'
#   會吞掉 dot-source 的錯誤 → core「存在但壞掉」時 Get-GuardVerdict 未定義、$verdict 為
#   $null、switch 落到 default → **exit 0 放行一切**。實測 core 語法錯／無函式／0 byte
#   三種情境下 `rm -rf /` 全部被放行（見 .governance/tests/test-core-degraded.ps1）。
#   現在改成：載入失敗或判定無效 → 走 Fail-Visible（permissionDecision "ask" + 顯眼理由
#   + GovLog），使用者一定看得到。用 ask 不用 deny 的理由：guard-bash 掛在全域，deny
#   會讓整台機器所有指令都被硬擋（brick）；ask 停得下來又留得下人工放行的路。
# ============================================================
$ErrorActionPreference = 'SilentlyContinue'

# 1) 讀取 hook 由 stdin 傳入的 JSON
$raw = [Console]::In.ReadToEnd()
if (-not $raw) { exit 0 }
try { $data = $raw | ConvertFrom-Json } catch { exit 0 }

$cmd = $data.tool_input.command
if (-not $cmd) { exit 0 }

# 2) 共用判定核心的載入移到下方「3)」——必須在 Deny/Ask/Fail-Visible 函式定義之後，
#    載入失敗才有辦法用 Ask 通報使用者（舊版在此處 exit 0，正是靜默 fail-open 的成因）。
$corePath = Join-Path $PSScriptRoot 'guard-core.ps1'

# ──────────────────────────────────────────────────────────────
# 以下為 Claude 側呈現層（留在 shim，不進 core）：
#   Write-GovLog（outcome 觀測）、Get-AskFloodPrefix（確認疲乏警示）、
#   Deny/Ask（Claude 特定的 exit code / 巢狀 permissionDecision 輸出）。
# ──────────────────────────────────────────────────────────────

# outcome 觀測（2026-07-11）：把每次 deny/ask 記一行到 ~/.claude/governance-logs（月檔）。
# 全程 fail-open——記 log 失敗絕不影響決策。是 outcome 觀測不是安全邊界。
function Write-GovLog([string]$hook, [string]$decision, [string]$why) {
    try {
        # 2026-07-31：env 重導向限 TEMP（settings 的 env 區塊是隱性不可信輸入，防守門 log 被導走）
        $dir = Join-Path $HOME '.claude\governance-logs'
        if ($env:GOVLOG_DIR) { try { $c = [IO.Path]::GetFullPath($env:GOVLOG_DIR); if ($c.StartsWith([IO.Path]::GetFullPath(([IO.Path]::GetTempPath())), [System.StringComparison]::OrdinalIgnoreCase)) { $dir = $c } } catch { } }
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $f = Join-Path $dir ('decisions-' + (Get-Date -Format 'yyyy-MM') + '.jsonl')
        $line = @{ ts = (Get-Date -Format 'o'); hook = $hook; decision = $decision; why = $why } | ConvertTo-Json -Compress
        Add-Content -Path $f -Value $line -Encoding utf8
    } catch { }
}

function Deny([string]$why) {
    Write-GovLog 'guard-bash' 'deny' $why
    [Console]::Error.WriteLine("[BLOCKED] guard 攔截危險指令：$why")
    [Console]::Error.WriteLine("  指令內容：$cmd")
    [Console]::Error.WriteLine("  此類指令一律由使用者本人於終端機手動執行，不由 Claude 代行。")
    exit 2
}

# flooding 偵測：同一 session 短時間內 ask 過密 → 加警示前綴，對抗確認疲乏
# （arXiv:2606.08919）。全程 best-effort——任何錯誤回空字串，絕不影響 ask 決策本身。
function Get-AskFloodPrefix {
    try {
        $sid = $data.session_id
        if (-not $sid) { $sid = 'no-session' }
        $sid = ($sid -replace '[^A-Za-z0-9_.-]', '_')
        $stateDir = $env:GUARD_ASK_STATE_DIR
        if (-not $stateDir) { $stateDir = Join-Path ([IO.Path]::GetTempPath()) 'claude-guard-ask' }
        if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
        $threshold = if ($env:GUARD_ASK_THRESHOLD) { [int]$env:GUARD_ASK_THRESHOLD } else { 8 }
        $windowMin = if ($env:GUARD_ASK_WINDOW_MIN) { [double]$env:GUARD_ASK_WINDOW_MIN } else { 30 }
        $file = Join-Path $stateDir "$sid.txt"
        $nowTicks = [DateTime]::UtcNow.Ticks
        $cutoff = [DateTime]::UtcNow.AddMinutes(-$windowMin).Ticks
        $stamps = @()
        if (Test-Path $file) {
            $stamps = @(Get-Content $file | Where-Object { $_.Trim() -match '^\d+$' } |
                ForEach-Object { [long]$_ } | Where-Object { $_ -ge $cutoff })
        }
        $stamps += $nowTicks
        if ($stamps.Count -ge $threshold) {
            Set-Content -Path $file -Value '' -Encoding utf8   # 警示後重置（警一次不連環警）
            return "⚠️ 本 session 近 $windowMin 分鐘內第 $($stamps.Count) 次確認框——留意 rubber-stamp 疲乏，逐字讀這一條再決定，別反射性同意。 "
        }
        Set-Content -Path $file -Value ($stamps -join "`n") -Encoding utf8
        return ''
    } catch { return '' }
}

function Ask([string]$why) {
    Write-GovLog 'guard-bash' 'ask' $why
    $reason = (Get-AskFloodPrefix) + "使用者硬規則「破壞性／難復原動作一律先問」：$why。請確認後再放行。"
    $out = @{
        hookSpecificOutput = @{
            hookEventName            = 'PreToolUse'
            permissionDecision       = 'ask'
            permissionDecisionReason = $reason
        }
    } | ConvertTo-Json -Depth 5 -Compress
    [Console]::Out.WriteLine($out)
    exit 0
}

# Fail-Visible：判定核心不可用時的通報路徑。**絕不 exit 0**——那是舊版的靜默 fail-open。
# 用 Ask 而非 Deny：guard-bash 也掛在全域 ~/.claude，Deny 會讓整台機器所有指令被硬擋。
function FailVisible([string]$why) {
    Write-GovLog 'guard-bash' 'core-unavailable' $why
    Ask "⚠️ guard 判定核心不可用（$why）——**本次指令未經安全判定**。請先修復：跑 ``pwsh .governance/bin/governance-doctor.ps1`` 查漂移、``pwsh .governance/bin/sync-governance.ps1`` 重新散佈。在修好之前，請自行確認這條指令安全"
}

# 3) 載入共用判定核心並硬斷言（三道，缺一都會退回靜默放行）
#    (a) 檔案存在  (b) dot-source 沒拋錯（try/catch，不靠 SilentlyContinue 吞）
#    (c) Get-GuardVerdict 真的被定義出來（語法壞掉/空檔時檔案在、函式不在）
if (-not (Test-Path $corePath)) { FailVisible '找不到 guard-core.ps1' }
try { . $corePath } catch { FailVisible "guard-core.ps1 載入失敗：$($_.Exception.Message)" }
if (-not (Get-Command Get-GuardVerdict -ErrorAction SilentlyContinue)) {
    FailVisible 'guard-core.ps1 已載入但未定義 Get-GuardVerdict（檔案可能損毀或被截斷）'
}

# 4) 委派判定，映射到 Claude 輸出
$verdict = Get-GuardVerdict -Command $cmd
# (d) 判定結果本身也要驗——core 內部若拋錯被吞，可能回 $null 或缺 decision 欄位
if ($null -eq $verdict -or -not $verdict.decision) { FailVisible 'guard-core 回傳無效判定（null 或缺 decision 欄位）' }
switch ($verdict.decision) {
    'deny'  { Deny $verdict.why }
    'ask'   { Ask  $verdict.why }
    'pass'  { exit 0 }
    default { FailVisible "guard-core 回傳未知判定值 '$($verdict.decision)'" }
}
