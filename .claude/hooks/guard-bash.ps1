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

# 2026-09-22：StartsWith(TEMP) 不解析 reparse point——%TEMP% 內一個 junction 就能把 log 導到 TEMP 外。
# 逐層檢查既存祖先，任一是 reparse point（junction／symlink）即拒（讀不到＝fail-closed）。
function Test-NoReparseUnderTemp([string]$full, [string]$tmpRoot) {
    $stop = $tmpRoot.TrimEnd('\', '/'); $p = $full
    while ($p -and $p.StartsWith($stop, [System.StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $p) { try { if ((Get-Item -LiteralPath $p -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false } } catch { return $false } }
        $parent = [IO.Path]::GetDirectoryName($p); if (-not $parent -or $parent -eq $p) { break }; $p = $parent
    }
    return $true
}

# outcome 觀測（2026-07-11）：把每次 deny/ask 記一行到 ~/.claude/governance-logs（月檔）。
# 全程 fail-open——記 log 失敗絕不影響決策。是 outcome 觀測不是安全邊界。
function Write-GovLog([string]$hook, [string]$decision, [string]$why) {
    try {
        # 2026-07-31：env 重導向限 TEMP（settings 的 env 區塊是隱性不可信輸入，防守門 log 被導走）；2026-09-22 補 junction 解析
        $dir = Join-Path $HOME '.claude\governance-logs'
        if ($env:GOVLOG_DIR) { try { $c = [IO.Path]::GetFullPath($env:GOVLOG_DIR); $tr = [IO.Path]::GetFullPath(([IO.Path]::GetTempPath())); if ($c.StartsWith($tr, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-NoReparseUnderTemp $c $tr)) { $dir = $c } } catch { } }
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $f = Join-Path $dir ('decisions-' + (Get-Date -Format 'yyyy-MM') + '.jsonl')
        $line = @{ ts = (Get-Date -Format 'o'); hook = $hook; decision = $decision; why = $why } | ConvertTo-Json -Compress
        Add-Content -Path $f -Value $line -Encoding utf8
    } catch { }
}

# ── 2026-10-10 D5：終止類 deny 的 PreToolUse 計數斷路器（spec 2026-10-10-termination-guard-redesign.md v0.3）──
# 同一 (session_id, agent_id) 第二次撞到終止類 deny（不論措辭）就寫一筆 taint 到與 record-security-warning
# 同一份狀態檔，guard-dispatch-taint 下次派工會問一次。主迴圈（stdin 沒有 agent_id）不計入。
# 狀態目錄解析與 record-security-warning 的 Get-TaintStateDir 同一套（TAINT_STATE_DIR 只認 TEMP 且拒 junction）。
# 全程 fail-open：計數失敗絕不影響 deny 本身（deny 先於計數，計數在 exit 2 之前最後做）。
function Get-TaintStateDirForBash {
    $default = Join-Path $HOME '.claude\session-state'
    if (-not $env:TAINT_STATE_DIR) { return $default }
    try {
        $c = [IO.Path]::GetFullPath($env:TAINT_STATE_DIR)
        $tmp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($c.StartsWith($tmp, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-NoReparseUnderTemp $c $tmp)) { return $c }
        return $default
    } catch { return $default }
}
function Get-SafeKeyForBash([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return '' }
    $k = $s -replace '[^A-Za-z0-9_.-]', '_'; $k = $k -replace '\.{2,}', '.'; $k = $k.Trim('.')
    if ($k.Length -gt 80) { $k = $k.Substring(0, 80) }
    return $k
}
# ts 正規化：與 record-security-warning.ps1／guard-dispatch-taint.ps1 的 ConvertTo-TsKey 同一份（階段 1 審查 minor-7）。
# 重寫既有 entries 時，pwsh 7 會把舊格式的純 ISO ts 讀成 [DateTime]，再序列化就悄悄改掉主鍵。
function ConvertTo-TsKeyForBash($v) {
    if ($null -eq $v) { return '' }
    if ($v -is [datetime]) { return $v.ToUniversalTime().ToString('o') }
    if ($v -is [datetimeoffset]) { return $v.UtcDateTime.ToString('o') }
    return "$v"
}
function Write-TerminationDenyCount([string]$why) {
    try {
        $agentId = ''
        foreach ($cand in @("$($data.agent_id)", "$($data.subagent_id)")) { if (-not [string]::IsNullOrWhiteSpace($cand)) { $agentId = $cand; break } }
        if (-not $agentId) { return }   # 主迴圈不計
        $sidKey = Get-SafeKeyForBash "$($data.session_id)"; if (-not $sidKey) { $sidKey = 'no-session' }
        $agentKey = Get-SafeKeyForBash $agentId
        $dir = Get-TaintStateDirForBash
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $counter = Join-Path $dir "termdeny-$sidKey-$agentKey.txt"
        $n = 0
        if (Test-Path -LiteralPath $counter) { $raw = (Get-Content -LiteralPath $counter -Raw).Trim(); if ($raw -match '^\d+$') { $n = [int]$raw } }
        $n++
        Set-Content -LiteralPath $counter -Value "$n" -Encoding utf8
        [Console]::Error.WriteLine("  [D5] 本 agent 第 $n 次撞到終止類 deny（第 2 次起寫 taint，下次派工會問使用者）")
        if ($n -lt 2) { return }
        $f = Join-Path $dir "taint-$sidKey.json"
        $entries = @(); $prompted = ''
        if (Test-Path -LiteralPath $f) {
            try { $j = [IO.File]::ReadAllText($f) | ConvertFrom-Json
                  if ($null -ne $j) { $entries = @($j.entries | Where-Object { $null -ne $_ } | ForEach-Object { [pscustomobject][ordered]@{ ts = (ConvertTo-TsKeyForBash $_.ts); hook_event = "$($_.hook_event)"; agent_id = "$($_.agent_id)"; snippet = "$($_.snippet)" } }); $prompted = (ConvertTo-TsKeyForBash $j.prompted_for) } } catch { $entries = @(); $prompted = '' }
        }
        $ts = (Get-Date).ToUniversalTime().ToString('o') + '#' + ([guid]::NewGuid().ToString('N').Substring(0, 4))
        $entry = [pscustomobject][ordered]@{ ts = $ts; hook_event = 'PreToolUse-deny'; agent_id = $agentId; snippet = "機器狀態類指令（終止／登記目錄／EncodedCommand）第 $n 次被守門擋下（guard-bash D5 計數；類別：$why）" }
        $entries = @($entries) + @($entry)
        if ($entries.Count -gt 50) { $entries = @($entries[($entries.Count - 50)..($entries.Count - 1)]) }
        $out = [ordered]@{ session_id = "$($data.session_id)"; entries = @($entries); prompted_for = $prompted }
        [IO.File]::WriteAllText($f, ($out | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding $false))
    } catch { }
}

function Deny([string]$why) {
    Write-GovLog 'guard-bash' 'deny' $why
    [Console]::Error.WriteLine("[BLOCKED] guard 攔截危險指令：$why")
    if ($why -match '程序終止|with-child 登記目錄|WITH_CHILD_DIR') {
        # 2026-10-10 機器狀態類（spec v0.3 D1／R1；三類都計入 D5）：不回顯指令原文（memory safety-classifier-cuts-payload-echo），
        # 結語依類別印改道說明（階段 1 審查 nit-12：R1 與 EncodedCommand 原本共用終止類結語，不對題）。
        [Console]::Error.WriteLine("  （此類指令原文不回顯；長度 $($cmd.Length) 字元）")
        if ($why -match 'with-child 登記目錄|WITH_CHILD_DIR') {
            [Console]::Error.WriteLine("  登記目錄只能由 node .governance/bin/with-child.mjs run 寫入（之後由使用者親手 adopt）。要讀登記：ls／cat／Get-Content 不帶重導向即可；要改登記內容或換目錄：在對話裡說明理由請使用者裁定。")
        } elseif ($why -match 'EncodedCommand') {
            [Console]::Error.WriteLine("  改走明碼：把指令寫進 .ps1 以 -File 執行，或直接用 -Command 明碼（守門看得到內容才能判定）。")
        } else {
            [Console]::Error.WriteLine("  只是要提到這些字（commit 訊息／搜尋／文件）：改用 Grep／Read 工具，或先把文字寫進檔案再以 git commit -F、add-guard-case -CommandFile、-File 傳入，指令行不含這些字。")
            [Console]::Error.WriteLine("  真的要終止程序：唯一合法路徑是 node .governance/bin/with-child.mjs stop <pid>（只對本 session 登記過的 PID）。要動不是你起的程序：在對話裡向使用者說明（程序名、PID、StartTime、理由、不動會怎樣）並等文字回覆；子 agent 則停止該項工作並回傳 needs_user_machine_action 欄位。不要改寫指令繞過本規則。")
        }
        Write-TerminationDenyCount $why
    } else {
        [Console]::Error.WriteLine("  指令內容：$cmd")
        [Console]::Error.WriteLine("  此類指令一律由使用者本人於終端機手動執行，不由 Claude 代行。")
    }
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
# 4b) 並行分支漂移（P0-2，2026-09-19）
#     只在 core 判定為 pass 時才查：deny/ask 本來就會停下來，不需要疊第二層，
#     也省掉不必要的 git 呼叫（Test-IsTreeMutatingGit 是純字串比對，微秒級；
#     真正有成本的 git rev-parse 只在它命中時才跑）。
#     **全程 fail-open**：Get-BranchDriftVerdict 內部任何一步取不到都回 pass。
if ($verdict.decision -eq 'pass' -and
    (Get-Command Test-IsTreeMutatingGit -ErrorAction SilentlyContinue) -and
    (Test-IsTreeMutatingGit -Command $cmd)) {
    $drift = Get-BranchDriftVerdict -Command $cmd
    if ($null -ne $drift -and $drift.decision -eq 'ask') { Ask $drift.why }
}

switch ($verdict.decision) {
    'deny'  { Deny $verdict.why }
    'ask'   { Ask  $verdict.why }
    'pass'  { exit 0 }
    default { FailVisible "guard-core 回傳未知判定值 '$($verdict.decision)'" }
}
