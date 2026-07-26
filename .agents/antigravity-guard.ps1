#!/usr/bin/env pwsh
# ============================================================
# antigravity-guard.ps1 — Antigravity PreToolUse 守門（run_command）
#                         Antigravity adapter（薄 shim over guard-core.ps1）
#
# v2（2026-07-26，Option 3 三家守門對等 Phase 2）：**判定邏輯下沉到共用核心
#   guard-core.ps1**（`Get-GuardVerdict`）。本檔只剩 Antigravity 側 I/O：
#   讀 stdin、金絲雀、把 core 回的 verdict 映射成 Antigravity 的扁平 decision
#   JSON、寫 hook-calls.log。Claude（guard-bash.ps1）／Codex 各自呼叫同一 core
#   → 三家守同一套判定（cmd 正規化 caret／黏連旗標／%VAR%／verb-anywhere、
#   殼包裹展開全含在 core，不再各家漂移）。
#
# 契約（實測 2026-07-24，見 .governance/agent-verify/hooks-test/）：
#   stdin JSON：{ "toolCall": { "name":"run_command",
#                 "args": { "CommandLine":"..." } }, "stepIdx":N, ... }
#   stdout JSON：{ "decision":"allow|deny|ask|force_ask", "reason":"..." }
#   （扁平 decision，與 Claude Code 巢狀 permissionDecision 不同）
#
# 輸出映射（core -> Antigravity）：
#   deny -> {"decision":"deny", ...}
#   ask  -> {"decision":"force_ask", ...}   ← 強制每次確認，不吃「本 session 記住」
#   pass -> {}                              ← 維持現狀，刻意不輸出 "allow"
#
# **core 不可用＝fail-degraded，不是 fail-open、也不是 brick**（2026-07-26 血的教訓）：
#   同一天發生兩次 fail-open——(a) sync 全域清單漏列共用檔，薄殼載不到核心，全機防護
#   靜默歸零；(b) 薄殼只用 Test-Path 檢查核心「在不在」，沒檢查「能不能用」，core 語法錯／
#   無函式／0 byte 時 $ErrorActionPreference='SilentlyContinue' 吞掉錯誤、判定變 null、
#   落到 default 分支 → 放行一切（實測災難級指令三種降級情境全被放行）。
#   共同結構＝**驗證了防護「存在」，沒驗證防護「有效」**。
#   本檔的四道硬斷言（見下方「3)」）逐一堵死該結構，任一不成立都走 Invoke-Degraded。
#
#   為什麼是「降級」而不是 fail-closed？Antigravity 每次 run_command 都會跑這支，
#   硬 deny 會鎖死 agent（不能工作＝使用者會直接關掉守門，比放行更糟）；完全放行則
#   等於防護歸零。折衷＝退回本檔自留的最小 deny 清單（至少擋災難級），並且：
#     - 命中時 reason 明白標示「判定核心不可用、目前是降級模式」（使用者看得到）
#     - 每次都寫一行 CORE-UNAVAILABLE 進 hook-calls.log（事後查得到）
#   降級行為由 .governance/tests/test-adapter-parity.ps1 機械釘住，防未來重構退回 fail-open。
#
# 一律寫 hook-calls.log 於本檔同目錄，用途是區分兩種失敗：
#   (a) log 空 = hook 沒被呼叫（Antigravity workspace 未登記／接線問題）
#   (b) log 有但沒擋 = 契約欄位不符（檢查 raw）
#
# 由 sync-governance.ps1 從 project-template/.agents/ 推送到各子專案 .agents/。
# **相依 ../.claude/hooks/guard-core.ps1**（同專案內的兄弟目錄，兩者都在版控、
# 都由 sync-governance.ps1 散佈）。
# 本檔需存為 UTF-8 BOM（PS 5.1 相容）；Antigravity 走 Windows PowerShell 5.1，
# 不得使用 7-only 語法（??、?.、三元運算子）。
# ============================================================
$ErrorActionPreference = 'SilentlyContinue'

$logPath = Join-Path $PSScriptRoot 'hook-calls.log'
function Write-HookLog([string]$m) {
    # 遮罩（2026-07-26 紅隊 F5）：本 log 逐字記錄完整指令列，指令內嵌的 token／金鑰會落地成
    # 明文。.agents/.gitignore 已排除 *.log（實測 sync 會散佈該 .gitignore），所以不會進版控，
    # 但本機明文仍是殘餘。遮常見的憑證形狀；遮罩失敗不得影響記錄本身（全程 best-effort）。
    try {
        $m = $m -replace '(?i)(--?(?:token|api[-_]?key|password|passwd|secret|auth)[=:\s]+)\S+', '$1<REDACTED>'
        $m = $m -replace '(?i)(Authorization:\s*Bearer\s+)\S+', '$1<REDACTED>'
        $m = $m -replace '(?i)\b(gh[pousr]_[A-Za-z0-9]{10,}|sk-[A-Za-z0-9]{10,}|xox[baprs]-[A-Za-z0-9-]{10,})\b', '<REDACTED>'
        $m = $m -replace '(?i)((?:token|key|secret|password)"\s*:\s*")[^"]+', '$1<REDACTED>'
    } catch {}
    try { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m" | Add-Content -Path $logPath -Encoding utf8 } catch {}
}
function Deny([string]$reason) {
    Write-HookLog "DECISION=deny: $reason"
    Write-Output (@{ decision = 'deny'; reason = $reason } | ConvertTo-Json -Compress)
    exit 0
}
function ForceAsk([string]$reason) {
    Write-HookLog "DECISION=force_ask: $reason"
    Write-Output (@{ decision = 'force_ask'; reason = $reason } | ConvertTo-Json -Compress)
    exit 0
}
function Allow { Write-Output '{}'; exit 0 }

# ──────────────────────────────────────────────────────────────
# 輸入層：契約解析失敗＝**fail-visible，不是 fail-open**（2026-07-26 紅隊打穿後改）
#
# 舊版所有「取不到指令」的路徑都直接 Allow。紅隊實測 22 種畸形 stdin，**8 種帶著
# 災難級指令被放行**——包含 **BOM 前綴**（Windows 上 .NET 預設常帶 BOM，觸發條件很現實）、
# JSON 截斷、非 JSON、欄位缺失／為 null／改名。失效結構與當天那兩次 fail-open 一模一樣：
# 契約一漂移，全機守門靜默歸零，唯一證據是沒人看的 log 行。
#
# 現在改成 ForceAsk：指令內容不明就交回使用者判斷。用 force_ask 而非 deny 的理由同檔頭
# ——這支每次 run_command 都跑，deny 會鎖死 agent；force_ask 停得下來又留得下人工放行的路，
# 且忽略「Always Allow」快取、不會被一次點擊靜默白名單。
# ──────────────────────────────────────────────────────────────
$raw = [Console]::In.ReadToEnd()
if (-not $raw) {
    Write-HookLog 'CALLED but stdin EMPTY'
    ForceAsk '⚠️ antigravity-guard 收到空的 stdin —— 無法取得指令內容，本次未經安全判定。這通常代表 hook 契約已漂移，請檢查 .agents/hooks.json 與 Antigravity 版本'
}
# BOM 剝除：Windows 上 .NET 寫出的 UTF-8 常帶 BOM，ConvertFrom-Json 會因此 parse 失敗
$raw = $raw -replace "^﻿", ''
Write-HookLog "CALLED stdin=$($raw.Length)bytes"

try { $data = $raw | ConvertFrom-Json } catch {
    Write-HookLog "PARSE-FAIL: $($_.Exception.Message)"
    ForceAsk "⚠️ antigravity-guard 無法解析 stdin JSON（$($_.Exception.Message)）—— 無法取得指令內容，本次未經安全判定。請檢查 hook 契約是否漂移"
}

# [string] 強制轉型：紅隊實測 CommandLine 為**陣列**時（如 ["rm","-rf","/"]），
# 不轉型會讓後續 [string] 參數綁定失敗 → verdict null → **謊報 CORE-UNAVAILABLE**
# （core 其實健康，害人去追不存在的 sync 漂移）→ 降級清單對陣列逐元素比對 → 全數未命中 → 放行。
$cmd = [string]$data.toolCall.args.CommandLine
if (-not $cmd) {
    Write-HookLog 'NO-COMMANDLINE（欄位名可能與契約不符——見 raw）'
    ForceAsk '⚠️ antigravity-guard 在 stdin JSON 裡找不到 toolCall.args.CommandLine —— 無法取得指令內容，本次未經安全判定。欄位名可能已與契約不符'
}
Write-HookLog "PARSED cmd='$cmd' stepIdx=$($data.stepIdx)"

# ── 金絲雀（保留供部署後實測 hook 真的有生效）──
# 刻意留在 shim、且擺在呼叫 core **之前**：下沉到 core 就失去「Antigravity 這一側的
# 接線是否生效」的證明能力（core 綠不代表 Antigravity 真的有呼叫到這支）。
# 金絲雀字串對 core 而言只是無害 echo，不會被 core 攔截。
if ($cmd -match 'CANARY-DELETE-7731') {
    Deny 'antigravity-guard：偵測到測試金絲雀 CANARY-DELETE-7731，已攔截（守門生效）'
}

# ──────────────────────────────────────────────────────────────
# 降級用最小 deny 清單（core 不可用時的唯一防線）
#   ＝ 本檔 v1 的自含規則原樣保留，只擋不可逆／災難級。
#   唯一與 v1 的差異：legacy format 改為錨定段首（v1 的 `\bformat\s+[A-Za-z]:`
#   會誤殺 `dotnet format C:\repo\x.sln`——實測該字串含 "format C:"）。
#   注意：這裡**刻意不追求與 core 對等**。它是急難用的粗網，不是第二套判定；
#   要改判定請改 core（三家共同受益），改這裡只會重建 per-adapter 分歧。
# ──────────────────────────────────────────────────────────────
$degradedDeny = @(
    @{ rx = '(^|[\s;&|])rm\s+(-[a-zA-Z]*\s+)*-[a-zA-Z]*r[a-zA-Z]*f|(^|[\s;&|])rm\s+(-[a-zA-Z]*\s+)*-[a-zA-Z]*f[a-zA-Z]*r'
       why = 'rm -rf 遞迴強制刪除' },
    @{ rx = 'Remove-Item\b[^\n]*-Recurse|Remove-Item\b[^\n]*-Force[^\n]*-Recurse|\bri\b[^\n]*-Recurse'
       why = 'Remove-Item -Recurse 遞迴刪除' },
    @{ rx = 'git\s+push\b[^\n]*(--force|\s-f\b)'; why = 'git push --force（覆寫遠端歷史）' },
    @{ rx = 'git\s+reset\s+--hard';               why = 'git reset --hard（丟棄未提交變更）' },
    @{ rx = 'git\s+clean\s+(-[a-zA-Z]*\s+)*-[a-zA-Z]*f[a-zA-Z]*d|git\s+clean\s+(-[a-zA-Z]*\s+)*-[a-zA-Z]*d[a-zA-Z]*f'
       why = 'git clean -fd（刪未追蹤檔）' },
    @{ rx = 'git\s+branch\s+-D\b';                why = 'git branch -D（強制刪分支）' },
    @{ rx = '\bdd\s+if=|\bmkfs\b|>\s*/dev/sd|format-volume|clear-disk|initialize-disk'
       why = '磁碟級破壞指令' },
    @{ rx = '(^|[;&|])\s*format(\.com)?\s+(/\S+\s+)*[A-Za-z]:\\?(\s|$)'; why = 'legacy format <磁碟>:（格式化整顆磁碟）' },
    @{ rx = '(curl|wget|iwr|Invoke-WebRequest|iex|Invoke-Expression)\b[^\n]*(\||；|;)\s*(sh|bash|pwsh|powershell|iex|Invoke-Expression)'
       why = '下載內容直接餵 shell 執行（供應鏈風險）' },
    @{ rx = '(cat|type|Get-Content|gc)\b[^\n]*\.credentials\.json|(cat|Get-Content|gc)\b[^\n]*auth\.json|printenv\b|Get-ChildItem\s+Env:'
       why = '讀取憑證/環境機密' }
)

function Invoke-Degraded([string]$why) {
    Write-HookLog "CORE-UNAVAILABLE: $why"
    foreach ($p in $degradedDeny) {
        if ($cmd -imatch $p.rx) {
            Deny "【降級模式：判定核心不可用】antigravity-guard 無法載入共用判定核心（$why），目前僅以最小 deny 清單把關：$($p.why)。請由使用者本人執行，並盡快修復：pwsh .governance/bin/governance-doctor.ps1（查漂移）／pwsh .governance/bin/sync-governance.ps1（重新散佈）"
        }
    }
    # 最小清單未命中 → **force_ask，不是放行**（2026-07-26 紅隊打穿後改）。
    #
    # 舊版在這裡 Allow。紅隊實測：core 缺席時掃 19 條 core=deny 的指令，**8 條溜過**——
    # 包含 `rd /s /q %USERPROFILE%`、`rmdir /s /q C:\`、`rm --recursive --force /`，
    # 其中兩條**正是 BEFORE 對照組 #1 與 #5，也就是這次改動存在的理由，一降級就原地復活**。
    #
    # 結構性修法：不去追求「降級清單夠密」（那是永遠追不完的軍備競賽，而且太密會在 core
    # 掛掉時鎖死 agent），改成**未命中就交回使用者判斷**。這樣降級清單只決定「deny 還是 ask」，
    # 不再決定「擋還是放」——安全性不再依賴那份清單的完整度。
    #
    # 代價：core 不可用期間每條指令都會跳確認框。這是刻意的——降級應該罕見，而那個摩擦
    # 正是「立刻去修」的壓力；靜默放行則會讓防護歸零而沒人知道（當天已發生兩次）。
    Write-HookLog "DEGRADED-ASK（最小清單未命中，本次指令未經完整判定）cmd='$cmd'"
    ForceAsk "⚠️【降級模式：判定核心不可用】antigravity-guard 無法載入共用判定核心（$why），本次指令**未經完整安全判定**。最小 deny 清單未命中不代表安全——請自行確認這條指令，並盡快修復：pwsh .governance/bin/governance-doctor.ps1（查漂移）／pwsh .governance/bin/sync-governance.ps1（重新散佈）"
}

# ──────────────────────────────────────────────────────────────
# 3) 載入共用判定核心 + 四道硬斷言
#    (a) 檔案存在
#    (b) dot-source 包 try/catch（不靠 SilentlyContinue 吞——那正是 fail-open 的成因）
#    (c) Get-Command Get-GuardVerdict 真的查得到（語法壞掉／被截斷時檔案在、函式不在）
#    (d) 回傳的 verdict 非 null 且有 decision 欄位（core 內部拋錯被吞會回 null）
#    任一不成立 → Invoke-Degraded，絕不靜默放行。
# ──────────────────────────────────────────────────────────────
$corePath = Join-Path $PSScriptRoot '..\.claude\hooks\guard-core.ps1'

if (-not (Test-Path $corePath)) { Invoke-Degraded '找不到 guard-core.ps1' }
# `$null = . $corePath`：吞掉 core 若不慎輸出的裸字串，同時保住 dot-source 的作用域語義
# （紅隊實測：core 多一行裸輸出就會讓 shim 吐出 `DEBUG: ...{"decision":...}`——判定正確但
#  不是合法 JSON，輸出契約毀掉；實測此寫法 visible=True，函式仍載入本作用域）。
try { $null = . $corePath } catch { Invoke-Degraded "guard-core.ps1 載入失敗：$($_.Exception.Message)" }
if (-not (Get-Command Get-GuardVerdict -ErrorAction SilentlyContinue)) {
    Invoke-Degraded 'guard-core.ps1 已載入但未定義 Get-GuardVerdict（檔案可能損毀或被截斷）'
}

# ── 4) 委派判定，映射到 Antigravity 輸出 ──
$verdict = Get-GuardVerdict -Command $cmd
if ($null -eq $verdict -or -not $verdict.decision) { Invoke-Degraded 'guard-core 回傳無效判定（null 或缺 decision 欄位）' }

switch ($verdict.decision) {
    'deny'  { Deny "antigravity-guard：$($verdict.why)。此類指令一律由使用者本人於終端機執行" }
    'ask'   { ForceAsk "使用者硬規則「破壞性／難復原動作一律先問」：$($verdict.why)。請確認後再放行" }
    'pass'  { Write-HookLog 'DECISION=(none) 放行'; Allow }
    default { Invoke-Degraded "guard-core 回傳未知判定值 '$($verdict.decision)'" }
}