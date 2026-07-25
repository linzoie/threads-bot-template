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
# 解析失敗一律 fail-open（exit 0）。core 找不到亦 fail-open（縱深防禦、不 brick；
# Phase 3 會升級為 hash-pin + fail-visible）。
# ============================================================
$ErrorActionPreference = 'SilentlyContinue'

# 1) 讀取 hook 由 stdin 傳入的 JSON
$raw = [Console]::In.ReadToEnd()
if (-not $raw) { exit 0 }
try { $data = $raw | ConvertFrom-Json } catch { exit 0 }

$cmd = $data.tool_input.command
if (-not $cmd) { exit 0 }

# 2) dot-source 共用判定核心（同目錄）。找不到 → fail-open（不 brick agent）。
$corePath = Join-Path $PSScriptRoot 'guard-core.ps1'
if (-not (Test-Path $corePath)) { exit 0 }
. $corePath

# ──────────────────────────────────────────────────────────────
# 以下為 Claude 側呈現層（留在 shim，不進 core）：
#   Write-GovLog（outcome 觀測）、Get-AskFloodPrefix（確認疲乏警示）、
#   Deny/Ask（Claude 特定的 exit code / 巢狀 permissionDecision 輸出）。
# ──────────────────────────────────────────────────────────────

# outcome 觀測（2026-07-11）：把每次 deny/ask 記一行到 ~/.claude/governance-logs（月檔）。
# 全程 fail-open——記 log 失敗絕不影響決策。是 outcome 觀測不是安全邊界。
function Write-GovLog([string]$hook, [string]$decision, [string]$why) {
    try {
        $dir = if ($env:GOVLOG_DIR) { $env:GOVLOG_DIR } else { Join-Path $HOME '.claude\governance-logs' }
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

# 3) 委派共用核心判定，映射到 Claude 輸出
$verdict = Get-GuardVerdict -Command $cmd
switch ($verdict.decision) {
    'deny'  { Deny $verdict.why }
    'ask'   { Ask  $verdict.why }
    default { exit 0 }
}
