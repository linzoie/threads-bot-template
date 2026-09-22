#!/usr/bin/env pwsh
# ============================================================
# guard-dispatch-taint.ps1  —  PreToolUse hook (matcher: ^(Agent|Workflow)$)
#   ——「派工斷路器」的**判定腿**（記錄腿是 record-security-warning.ps1）
#
# 【為什麼存在】2026-09-19 事故的完整鏈條：
#   (1) subagent 用 `taskkill /F /IM chrome.exe` 殺光 75 個程序
#   (2) harness 在 workflow 結果標了 "SECURITY WARNING: ... may violate security policy"
#   (3) 肇事 agent 自己寫了 "I cannot undo it. I'm stopping further blanket process-kills"
#   (4) **主迴圈看到警告後照樣繼續派工**
# 斷的是 (3)→(4) 這一段：訊號存在、但沒有任何機械後果。本檔補上那個後果——
# 看到 taint 就在**下一次派工前**停一次，把警告原文放到使用者眼前。
#
# 【為什麼是 ask，永遠不是 deny】誤判成本不對稱：
#   - 漏提醒＝可能再殺一次使用者的程序（不可回復，09-19 已經發生過一次）
#   - 誤擋＝打斷工作流，且會訓練人反射性點「准」（信任損耗，也不可回復）
# ask 兩邊都保得住：停得下來，也留得下人工放行的路。本檔永遠不回 deny，
# 由 test-dispatch-taint.ps1 機械釘住。
#
# 【為什麼只問一次】「提示一次 → 使用者選擇繼續就清掉」抄自 guard-core 的
# Test-BranchDrift pending 設計。理由相同：同一個 taint 若每次派工都問，
# 使用者三次之後就會學會無視它——那比沒有守門更糟。
# 狀態機（以 prompted_for 對比最新 entry 的 ts 為唯一主鍵）：
#   無 taint 檔                         → 放行，無輸出
#   有 entries 且 prompted_for ≠ 最新ts → ask，並把 prompted_for 寫成最新 ts
#   有 entries 且 prompted_for = 最新ts → 使用者看過且選擇繼續 → **刪檔**，放行
#   之後若又進來新 entry（新 ts）       → 再問一次（不是永久靜音）
# ⚠️ 與分支漂移的差異：那邊「答否」可以靠切回原分支表達，所以留著基準線；
#    這邊沒有等價的「回到乾淨狀態」動作，所以第二次進來一律視為使用者選擇繼續。
#    代價是：使用者答「否」之後如果**自己**再派一次工，不會再被問。
#    這是刻意的——答否的正確後果是「你不要派」，不是「工具幫你擋」。
#
# 【fail-open 是刻意的】狀態檔缺失／損壞／讀不到 → 放行且無輸出。
# 這是安全網不是閘門（memory components-not-alternatives）。做成閘門會在狀態檔
# 還沒建立的第一個 session 就擋死所有派工，那比沒有守門更糟。
# ============================================================
$ErrorActionPreference = 'SilentlyContinue'

# 2026-09-22：GetFullPath().StartsWith(TEMP) 只比字串、不解析 reparse point——%TEMP% 內一個
# junction（mklink /J）就能把守門狀態／log 導到 TEMP 外藏起來。逐層檢查既存祖先，任一是
# reparse point（junction／symlink）即拒。junction 必須存在才能轉向，故只查既存鏈就夠；讀不到＝fail-closed。
function Test-NoReparseUnderTemp([string]$full, [string]$tmpRoot) {
    $stop = $tmpRoot.TrimEnd('\', '/')
    $p = $full
    while ($p -and $p.StartsWith($stop, [System.StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $p) {
            try {
                if ((Get-Item -LiteralPath $p -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
            } catch { return $false }
        }
        $parent = [IO.Path]::GetDirectoryName($p)
        if (-not $parent -or $parent -eq $p) { break }
        $p = $parent
    }
    return $true
}

function Write-GovLog([string]$hook, [string]$decision, [string]$why) {
    try {
        $dir = Join-Path $HOME '.claude\governance-logs'
        if ($env:GOVLOG_DIR) {
            try {
                $c = [IO.Path]::GetFullPath($env:GOVLOG_DIR)
                $tr = [IO.Path]::GetFullPath(([IO.Path]::GetTempPath()))
                if ($c.StartsWith($tr, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-NoReparseUnderTemp $c $tr)) { $dir = $c }
            } catch { }
        }
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $f = Join-Path $dir ('decisions-' + (Get-Date -Format 'yyyy-MM') + '.jsonl')
        $line = @{ ts = (Get-Date -Format 'o'); hook = $hook; decision = $decision; why = $why } | ConvertTo-Json -Compress
        Add-Content -Path $f -Value $line -Encoding utf8
    } catch { }
}

# 與 record-security-warning.ps1 同一套解析（兩支必須看同一個檔，否則記了卻讀不到）
function Get-TaintStateDir {
    $default = Join-Path $HOME '.claude\session-state'
    if (-not $env:TAINT_STATE_DIR) { return $default }
    try {
        $c = [IO.Path]::GetFullPath($env:TAINT_STATE_DIR)
        $tmp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($c.StartsWith($tmp, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-NoReparseUnderTemp $c $tmp)) { return $c }
        # ASCII 標記見 record-security-warning.ps1 同段註解（5.1 OEM 碼頁）
        [Console]::Error.WriteLine("[taint] ignored TAINT_STATE_DIR (not under TEMP or via junction) 忽略：$env:TAINT_STATE_DIR")
        return $default
    } catch {
        [Console]::Error.WriteLine('[taint] ignored TAINT_STATE_DIR (unparsable path) 忽略')
        return $default
    }
}

# ── ts 正規化：本檔的「問過沒」全靠字串比對，所以必須先消掉解譯器差異 ──
# 實測（2026-09-20）：'{"ts":"2026-09-20T00:00:01.1000000Z"}' | ConvertFrom-Json
#   pwsh 7 → [DateTime]，而 "$dt" 的預設 render 是**秒級**：同一秒內的兩筆會變成
#            同一個字串 → 第二筆被當成「已經問過」，靜默刪檔不發問（fail-open 到錯的方向）
#   5.1    → [String]，原樣保留
# 也就是說同一個檔在兩個解譯器下判定相反。正規化成 UTC 的 round-trip 格式之後
# 兩邊一致、且小數位不丟（實測 naive 比對 False → 正規化後 True，且三輪往返穩定）。
# **不能只靠寫入端加後綴**：舊版寫的檔、別的 agent 寫的檔都可能是純 ISO，
# 讀取端自己要站得住（test-dispatch-taint.ps1 §A9 用舊格式檔案機械釘住）。
function ConvertTo-TsKey($v) {
    if ($null -eq $v) { return '' }
    if ($v -is [datetime]) { return $v.ToUniversalTime().ToString('o') }
    if ($v -is [datetimeoffset]) { return $v.UtcDateTime.ToString('o') }
    return "$v"
}
function ConvertTo-NormalEntry($e) {
    return [pscustomobject][ordered]@{
        ts         = (ConvertTo-TsKey $e.ts)
        hook_event = "$($e.hook_event)"
        agent_id   = "$($e.agent_id)"
        snippet    = "$($e.snippet)"
    }
}

# stdin 一律當 UTF-8 讀（理由同 record-security-warning.ps1：5.1 重導向 stdin 走 OEM 碼頁）
function Read-StdinUtf8 {
    try {
        $sin = [Console]::OpenStandardInput()
        if ($null -eq $sin) { return '' }
        $sr = New-Object System.IO.StreamReader($sin, (New-Object System.Text.UTF8Encoding $false))
        try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
    } catch {
        try { return [Console]::In.ReadToEnd() } catch { return '' }
    }
}

function Get-SafeSessionKey([string]$sid) {
    if ([string]::IsNullOrWhiteSpace($sid)) { return 'no-session' }
    $s = $sid -replace '[^A-Za-z0-9_.-]', '_'
    $s = $s -replace '\.{2,}', '.'
    $s = $s.Trim('.')
    if ([string]::IsNullOrWhiteSpace($s)) { return 'no-session' }
    if ($s.Length -gt 80) { $s = $s.Substring(0, 80) }
    return $s
}

# 本檔唯一的輸出形式。格式與 guard-bash.ps1 的 Ask 完全一致（巢狀 hookSpecificOutput），
# 離開碼 0——PreToolUse 的 2 是 deny，本檔永遠不用。
function Ask([string]$why) {
    Write-GovLog 'guard-dispatch-taint' 'ask' $why
    $out = @{
        hookSpecificOutput = @{
            hookEventName            = 'PreToolUse'
            permissionDecision       = 'ask'
            permissionDecisionReason = $why
        }
    } | ConvertTo-Json -Depth 5 -Compress
    [Console]::Out.WriteLine($out)
    exit 0
}

$stateDir = Get-TaintStateDir

$raw = Read-StdinUtf8
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
$data = $null
try { $data = $raw | ConvertFrom-Json } catch { exit 0 }
if ($null -eq $data) { exit 0 }

$f = $null
try {
    $key = Get-SafeSessionKey "$($data.session_id)"
    $f = Join-Path $stateDir ("taint-$key.json")
} catch { exit 0 }

if (-not (Test-Path -LiteralPath $f)) { exit 0 }

$j = $null
try { $j = [IO.File]::ReadAllText($f) | ConvertFrom-Json } catch { exit 0 }   # 改壞的檔 → fail-open
if ($null -eq $j) { exit 0 }

# @() 強制成陣列：單元素時 ConvertFrom-Json 會給 PSCustomObject 而非陣列，
# 不包 @() 的話 .Count 在 5.1 會是 $null，整段判定會靜默跳過（＝守門消失）。
$entries = @()
try {
    $entries = @($j.entries |
        Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace("$($_.ts)") } |
        ForEach-Object { ConvertTo-NormalEntry $_ })
} catch { exit 0 }
if ($entries.Count -eq 0) { exit 0 }

$latest = $entries[$entries.Count - 1]
$latestTs = "$($latest.ts)"                      # 已由 ConvertTo-NormalEntry 正規化
$prompted = ConvertTo-TsKey $j.prompted_for      # 兩邊要走同一條正規化才比得對

if ($prompted -eq $latestTs) {
    # 使用者上次看過這一筆、這次仍然要派工 ＝ 選擇繼續 → 清掉，不再重複問
    try { [IO.File]::Delete($f) } catch { }
    Write-GovLog 'guard-dispatch-taint' 'cleared' "使用者已就 $latestTs 選擇繼續 → 清除 taint"
    exit 0
}

# 先把 prompted_for 寫回去，再發問。順序是刻意的：
# 寫失敗時最多多問一次（噪音），寫成功但發問失敗不可能（Ask 最後一步才 exit）。
try {
    $out = [ordered]@{
        session_id   = "$($j.session_id)"
        entries      = @($entries)
        prompted_for = $latestTs
    }
    [IO.File]::WriteAllText($f, ($out | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
} catch { }

$snippet = "$($latest.snippet)"
if ($snippet.Length -gt 300) { $snippet = $snippet.Substring(0, 300) }
$agent = "$($latest.agent_id)"
$agentTxt = if ([string]::IsNullOrWhiteSpace($agent)) { '' } else { "（$agent）" }

$why = '⚠️ 派工斷路器：上一次派工留下了安全警告／自承破壞的訊號，但**還沒有人看過**。' +
    "來源 hook：$($latest.hook_event)$agentTxt，時間 $latestTs。" +
    "原文片段：「$snippet」。" +
    '2026-09-19 實例：harness 標了 SECURITY WARNING、肇事 agent 自己寫了 "I cannot undo it"，' +
    '而主迴圈照樣繼續派工——那一次殺掉了使用者 75 個程序（含真實瀏覽器）。' +
    '繼續派工前請先確認：上一支 agent 做了什麼、有沒有需要先收拾的機器狀態、' +
    '這次的 prompt 有沒有把「不得按名稱殺程序」之類的硬規則寫進去。' +
    '若確認可以繼續，按准即可——**本次確認後不會再重複問同一筆**。'

Ask $why
