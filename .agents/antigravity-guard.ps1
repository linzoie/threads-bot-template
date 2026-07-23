#!/usr/bin/env pwsh
# ============================================================
# antigravity-guard.ps1 — Antigravity PreToolUse 守門（run_command）
#
# 角色：Antigravity 沒有 Claude Code 的 PowerShell guard 層。這支是「最小 deny
#       清單」——只攔**不可逆/災難級**指令，不試圖複製整套 guard-bash（那是
#       「不做完整 adapter」的裁定）。真正的機密地板走 git pre-commit
#       （install-git-hooks.ps1）；本檔是危險指令的補充攔截層。
#
# 契約（實測 2026-07-24，見 .governance/agent-verify/hooks-test/）：
#   stdin JSON：{ "toolCall": { "name":"run_command",
#                 "args": { "CommandLine":"..." } }, "stepIdx":N, ... }
#   stdout JSON：{ "decision":"allow|deny|ask|force_ask", "reason":"..." }
#   （扁平 decision，與 Claude Code 巢狀 permissionDecision 不同）
#
# 一律寫 hook-calls.log 於本檔同目錄，用途是區分兩種失敗：
#   (a) log 空 = hook 沒被呼叫（Antigravity workspace 未登記／接線問題）
#   (b) log 有但沒擋 = 契約欄位不符（檢查 raw）
#
# 由 sync-governance.ps1 從 project-template/.agents/ 推送到各子專案 .agents/。
# 本檔需存為 UTF-8 BOM（PS 5.1 相容）。
# ============================================================
$ErrorActionPreference = 'SilentlyContinue'

$logPath = Join-Path $PSScriptRoot 'hook-calls.log'
function Write-HookLog([string]$m) {
    try { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m" | Add-Content -Path $logPath -Encoding utf8 } catch {}
}
function Deny([string]$reason) {
    Write-HookLog "DECISION=deny: $reason"
    Write-Output (@{ decision = 'deny'; reason = $reason } | ConvertTo-Json -Compress)
    exit 0
}
function Allow { Write-Output '{}'; exit 0 }

$raw = [Console]::In.ReadToEnd()
if (-not $raw) { Write-HookLog 'CALLED but stdin EMPTY'; Allow }
Write-HookLog "CALLED stdin=$($raw.Length)bytes"

try { $data = $raw | ConvertFrom-Json } catch { Write-HookLog "PARSE-FAIL: $($_.Exception.Message)"; Allow }

$cmd = $data.toolCall.args.CommandLine
if (-not $cmd) { Write-HookLog 'NO-COMMANDLINE（欄位名可能與契約不符——見 raw）'; Allow }
Write-HookLog "PARSED cmd='$cmd' stepIdx=$($data.stepIdx)"

# ── 金絲雀（保留供部署後實測 hook 真的有生效）──
if ($cmd -match 'CANARY-DELETE-7731') {
    Deny 'antigravity-guard：偵測到測試金絲雀 CANARY-DELETE-7731，已攔截（守門生效）'
}

# ── DENY 級：不可逆／災難級（比照 guard-bash DENY tier，最小集）──
# 1) 遞迴強制刪除
if ($cmd -match '(^|[\s;&|])rm\s+(-[a-zA-Z]*\s+)*-[a-zA-Z]*r[a-zA-Z]*f|(^|[\s;&|])rm\s+(-[a-zA-Z]*\s+)*-[a-zA-Z]*f[a-zA-Z]*r') {
    Deny 'antigravity-guard：rm -rf 遞迴強制刪除，請由使用者本人於終端機執行'
}
if ($cmd -match 'Remove-Item\b[^\n]*-Recurse|Remove-Item\b[^\n]*-Force[^\n]*-Recurse|\bri\b[^\n]*-Recurse') {
    Deny 'antigravity-guard：Remove-Item -Recurse 遞迴刪除，請由使用者本人執行'
}
# 2) git 破壞性
if ($cmd -match 'git\s+push\b[^\n]*(--force|\s-f\b)') {
    Deny 'antigravity-guard：git push --force 會覆寫遠端歷史，請由使用者本人確認後執行'
}
if ($cmd -match 'git\s+reset\s+--hard') {
    Deny 'antigravity-guard：git reset --hard 會丟棄未提交變更，請由使用者本人確認'
}
if ($cmd -match 'git\s+clean\s+(-[a-zA-Z]*\s+)*-[a-zA-Z]*f[a-zA-Z]*d|git\s+clean\s+(-[a-zA-Z]*\s+)*-[a-zA-Z]*d[a-zA-Z]*f') {
    Deny 'antigravity-guard：git clean -fd 會刪未追蹤檔，請由使用者本人確認'
}
if ($cmd -match 'git\s+branch\s+-D\b') {
    Deny 'antigravity-guard：git branch -D 強制刪分支，請由使用者本人確認'
}
# 3) 磁碟／系統級破壞
if ($cmd -match '\bdd\s+if=|\bmkfs\b|\bformat\s+[A-Za-z]:|>\s*/dev/sd') {
    Deny 'antigravity-guard：磁碟級破壞指令，一律由使用者本人執行'
}
# 4) 管到 shell 執行遠端腳本（供應鏈風險）
if ($cmd -match '(curl|wget|iwr|Invoke-WebRequest|iex|Invoke-Expression)\b[^\n]*(\||；|;)\s*(sh|bash|pwsh|powershell|iex|Invoke-Expression)') {
    Deny 'antigravity-guard：下載內容直接餵 shell 執行，供應鏈風險，請人工審視'
}
# 5) 讀機密外洩（配合機密不外流原則）
if ($cmd -match '(cat|type|Get-Content|gc)\b[^\n]*\.credentials\.json|(cat|Get-Content|gc)\b[^\n]*auth\.json|printenv\b|Get-ChildItem\s+Env:') {
    Deny 'antigravity-guard：讀取憑證/環境機密，請人工確認用途'
}

Write-HookLog 'DECISION=(none) 放行'
Allow