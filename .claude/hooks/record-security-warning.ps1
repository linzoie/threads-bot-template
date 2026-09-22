#!/usr/bin/env pwsh
# ============================================================
# record-security-warning.ps1
#   PostToolUse hook (matcher: ^(Agent|Workflow|TaskOutput)$)
#   ＋ SubagentStop hook (matcher: 空)
#   ——「派工斷路器」的**記錄腿**（判定腿是 guard-dispatch-taint.ps1）
#
# 【為什麼存在】2026-09-19 事故：一支 subagent 用 `taskkill /F /IM chrome.exe`
# 殺光 75 個程序（含使用者真實瀏覽器）。事後查 workflow 結果，harness **早就標了**
#   "SECURITY WARNING: This subagent performed actions that may violate security
#    policy. Reason: [Interfere With Workloads]"
# 而肇事 agent 自己也寫了 "I cannot undo it. I'm stopping further blanket
# process-kills"。兩個訊號都在眼前，**主迴圈看到警告後照樣繼續派工**。
#
# 失效點不在偵測（harness 已經偵測到了），在**訊號的下游沒有任何機械後果**：
# 警告只是一段文字，混在幾千行工具輸出裡，讀過就過去了。這是 memory
# precaution-needs-live-trigger 的形狀——知道規則 ≠ 在對的時機執行檢查。
# 所以本檔把「看到警告」固化成**持久化的 taint 狀態**，由 guard-dispatch-taint
# 在**下一次派工前**把它擋在眼前問一次。
#
# 【設計：安全網不是閘門】
# 本檔永遠不阻擋、不改變任何工具的結果（PostToolUse／SubagentStop 本來就在事後）。
# 它唯一的作用是寫一個狀態檔。任何一步失敗都 exit 0 且不寫（fail-open）——
# 壞掉的後果是「下一次派工不會被問」，退回本檔不存在時的現行行為，
# 絕不會變成「擋住工作」或「看起來檢查過了」。
#
# 【為什麼 taint 只提示一次】見 guard-dispatch-taint.ps1 檔頭。簡言之：
# 重複發問會訓練人無視守門（確認疲乏，信任損耗不可回復），比沒有守門更糟。
#
# 【刻意不做的事】
# - 不讀 tool_input：警告是 harness 對**執行結果**的判定。若掃 tool_input，
#   任何在 prompt 裡談論這次事故的派工（例如本任務自己）都會自我 taint，
#   那是噪音不是訊號。test-dispatch-taint.ps1 §攻擊 2 機械釘住這一點。
# - 不做語意判斷：hook 是同步阻塞的，只能做字串比對。
# - 不 deny：本檔根本沒有 deny 的能力（PostToolUse 階段工具已經跑完了）。
#
# 【已知射程限制（誠實登記）】
# 背景 Workflow 的結果是走 task-notification 回到主迴圈，**不經過 PostToolUse**，
# 所以本檔看不到它的 SECURITY WARNING。實際覆蓋到的是：前景 Agent／Workflow 的
# PostToolUse、TaskOutput（背景任務結果被主迴圈讀取時）、以及 SubagentStop 的自承句型。
# 登記過的漏洞是設計決策，沒登記的才是盲點。
# ============================================================
$ErrorActionPreference = 'SilentlyContinue'

# ──────────────────────────────────────────────────────────────
# 0) 共用小工具（與 guard-bash.ps1 同款；本檔刻意不 dot-source guard-core，
#    因為那會讓「core 壞掉」連帶讓記錄腿失效——兩層應該各自獨立降級）
# ──────────────────────────────────────────────────────────────

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

# outcome 觀測。全程 fail-open——記 log 失敗絕不影響任何事。
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

# state 目錄解析。預設 $HOME\.claude\session-state（與分支漂移狀態檔同一個目錄慣例）。
# TAINT_STATE_DIR **只在 %TEMP% 之下才採用**——settings 的 env 區塊是隱性不可信輸入，
# 不限制的話等於開一條「把守門狀態導到別處」的靜默失效路徑（同 GOVLOG_DIR 的理由）。
# 拒絕時印一行 stderr：靜默忽略會讓測試與使用者都分不清「忽略了」與「採用了」。
function Get-TaintStateDir {
    $default = Join-Path $HOME '.claude\session-state'
    if (-not $env:TAINT_STATE_DIR) { return $default }
    try {
        $c = [IO.Path]::GetFullPath($env:TAINT_STATE_DIR)
        $tmp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($c.StartsWith($tmp, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-NoReparseUnderTemp $c $tmp)) { return $c }
        # ASCII 標記是刻意的：5.1 的 Console.OutputEncoding 是 OEM 碼頁，純中文訊息在
        # 擷取輸出時會變亂碼，測試就只能斷言「有沒有 stderr」而驗不到「是哪一種 stderr」。
        [Console]::Error.WriteLine("[taint] ignored TAINT_STATE_DIR (not under TEMP or via junction) 忽略：$env:TAINT_STATE_DIR")
        return $default
    } catch {
        [Console]::Error.WriteLine('[taint] ignored TAINT_STATE_DIR (unparsable path) 忽略')
        return $default
    }
}

# session_id → 安全檔名。三種路徑字元（../、冒號、反斜線）都會被打成底線。
# 額外把連續的點折成單一點：避免 'taint-' + '..' + '.json' 這種看起來像遍歷的檔名。
function Get-SafeSessionKey([string]$sid) {
    if ([string]::IsNullOrWhiteSpace($sid)) { return 'no-session' }
    $s = $sid -replace '[^A-Za-z0-9_.-]', '_'
    $s = $s -replace '\.{2,}', '.'
    $s = $s.Trim('.')
    if ([string]::IsNullOrWhiteSpace($s)) { return 'no-session' }
    if ($s.Length -gt 80) { $s = $s.Substring(0, 80) }
    return $s
}

# ── ts 正規化（與 guard-dispatch-taint.ps1 同一份；理由見該檔同名函式）──
# 本檔每次 append 都會把**既有的** entries 整個重寫回去。若不正規化，pwsh 7 讀進來的
# 舊 ts 會是 [DateTime]，ConvertTo-Json 會把它重新序列化成帶本地時區的格式 →
# 既有 entry 的 ts 在每次 append 時悄悄變樣，而那正是 guard 判斷「問過沒」的主鍵。
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

# 一律用帶 timeout 的 regex（禁止巢狀量詞）：1 MB 的 tool_response 不能讓 hook 卡住。
function New-Rx([string]$pattern) {
    return [regex]::new(
        $pattern,
        ([System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant),
        [TimeSpan]::FromSeconds(2))
}

# stdin 一律當 UTF-8 讀。**不可**用 `[Console]::In.ReadToEnd()`（其他 hook 的慣例）：
# 在 Windows PowerShell 5.1 底下，重導向的 Console.In 用的是主控台輸入碼頁（zh-TW 機器
# 常是 950），UTF-8 的中文位元組會被靜默解成亂碼 → 本檔的中文句型（殺光／誤殺／終止）
# 永遠配不到，而外觀與「沒命中」一模一樣（memory experiment-needs-positive-control 的形狀）。
# Antigravity 走 5.1，所以這不是假想情境。StreamReader 的這個建構子預設會偵測 BOM。
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

function Get-Snippet([string]$text, [int]$index, [int]$len) {
    try {
        $start = $index - 80
        if ($start -lt 0) { $start = 0 }
        $take = 300
        if ($start + $take -gt $text.Length) { $take = $text.Length - $start }
        $s = $text.Substring($start, $take)
        # 控制字元→空白：snippet 會被塞進 JSON 與 ask 訊息，換行會把版面打爛
        # \p{Cc}（Unicode 控制字元類別）不用 backslash-u 字面值：那會被工具層折成真的控制位元組，
        # 讓整個檔案被 grep/rg 當成 binary（memory subagent-code-raw-control-byte）。
        $s = ($s -replace '\p{Cc}', ' ')
        $s = ($s -replace '\s{2,}', ' ').Trim()
        if ($s.Length -gt 300) { $s = $s.Substring(0, 300) }
        return $s
    } catch { return '' }
}

# ──────────────────────────────────────────────────────────────
# 1) 讀 stdin（壞輸入一律 fail-open）
#    ⚠️ 環境變數的檢查刻意放在**解析之前**：這樣「TAINT_STATE_DIR 指到 TEMP 外」
#    的告警與「這次有沒有命中」互相獨立，測試才驗得到忽略訊息而不必真的寫檔。
# ──────────────────────────────────────────────────────────────
$stateDir = Get-TaintStateDir

$raw = Read-StdinUtf8
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
$data = $null
try { $data = $raw | ConvertFrom-Json } catch { exit 0 }
if ($null -eq $data) { exit 0 }

$evt = "$($data.hook_event_name)"

# ──────────────────────────────────────────────────────────────
# 2) 依事件分流，取出「要搜尋的語料」
# ──────────────────────────────────────────────────────────────
$corpus = ''
$sourceKind = ''

function ConvertTo-SearchText($v) {
    if ($null -eq $v) { return '' }
    if ($v -is [string]) { return $v }
    try { return ($v | ConvertTo-Json -Depth 20 -Compress) } catch { return "$v" }
}

if ($evt -eq 'SubagentStop') {
    $sourceKind = 'SubagentStop'
    $lam = ConvertTo-SearchText $data.last_assistant_message
    if ([string]::IsNullOrWhiteSpace($lam)) { $corpus = $raw } else { $corpus = $lam }
}
elseif ($evt -eq 'PostToolUse') {
    $sourceKind = 'PostToolUse'
    $corpus = ConvertTo-SearchText $data.tool_response
}
else {
    # hook_event_name 缺失時的防禦性推斷（欄位是版本行為、不是契約）
    if ($null -ne $data.tool_response) { $sourceKind = 'PostToolUse'; $corpus = ConvertTo-SearchText $data.tool_response }
    elseif ($null -ne $data.last_assistant_message) { $sourceKind = 'SubagentStop'; $corpus = ConvertTo-SearchText $data.last_assistant_message }
    else { exit 0 }
}

if ([string]::IsNullOrWhiteSpace($corpus)) { exit 0 }

# ──────────────────────────────────────────────────────────────
# 3) 比對
#    PostToolUse：harness 自己標的警告（權威訊號，單一條件即可）
#    SubagentStop：agent 的自承句型（弱訊號，**必須**同時出現殺程序類詞，
#                  否則 "cannot undo" 這種到處都有的句子會製造假 taint）
# ──────────────────────────────────────────────────────────────
$hit = $null
try {
    if ($sourceKind -eq 'PostToolUse') {
        $rx = New-Rx 'SECURITY\s+WARNING|may\s+violate\s+security\s+policy'
        $m = $rx.Match($corpus)
        if ($m.Success) { $hit = $m }
    }
    else {
        $rxAdmit = New-Rx 'cannot\s+undo|killed\s+all|terminated\s+all|blanket\s+process[\s-]?kill|殺光|誤殺'
        $m = $rxAdmit.Match($corpus)
        if ($m.Success) {
            # 2026-09-21 驗證腿抓到的真誤判：舊 pattern 'kill' 無字邊界，'skills'／'skilled'／'killed nothing' 這類
            # 日常詞配上 "cannot undo" 就誤 taint（4/4 中）。修法兩件：①殺程序詞加 \b 字邊界並枚舉詞形；
            # ②只在自承句前後 200 字元的視窗內找，不掃整份訊息（收尾摘要常常同時提到「不可逆」與「kill 掉自己的 dev server」，
            #   兩者相隔很遠時不該算同一件事）。中文不用單獨的「終止」「程序」（太常見），改要求「終止…程序」相鄰。
            $ws = [Math]::Max(0, $m.Index - 200)
            $we = [Math]::Min($corpus.Length, $m.Index + $m.Length + 200)
            $window = $corpus.Substring($ws, $we - $ws)
            $rxKill = New-Rx '\b(taskkill|tskill|pkill|killall|stop-process|kill(ed|ing|s)?|terminat(e|ed|ing))\b|終止.{0,6}程序|程序.{0,6}終止|殺光|誤殺'
            if ($rxKill.IsMatch($window)) { $hit = $m }
        }
    }
} catch { exit 0 }   # regex timeout 等例外一律 fail-open

if ($null -eq $hit) { exit 0 }

# ──────────────────────────────────────────────────────────────
# 4) 寫 taint（append）
# ──────────────────────────────────────────────────────────────
try {
    $sid = "$($data.session_id)"
    $key = Get-SafeSessionKey $sid
    if (-not (Test-Path -LiteralPath $stateDir)) { $null = New-Item -ItemType Directory -Path $stateDir -Force }
    $f = Join-Path $stateDir ("taint-$key.json")

    $agentId = ''
    foreach ($cand in @(
            "$($data.agent_id)", "$($data.subagent_id)", "$($data.agent_type)",
            "$($data.tool_input.agent_id)", "$($data.tool_input.subagent_type)",
            "$($data.tool_input.name)", "$($data.tool_name)")) {
        if (-not [string]::IsNullOrWhiteSpace($cand)) { $agentId = $cand; break }
    }
    if ($agentId.Length -gt 120) { $agentId = $agentId.Substring(0, 120) }

    $entries = @()
    $prompted = ''
    if (Test-Path -LiteralPath $f) {
        try {
            $j = [IO.File]::ReadAllText($f) | ConvertFrom-Json
            if ($null -ne $j) {
                # @() 強制成陣列：單元素時 ConvertFrom-Json 會給 PSCustomObject 而不是陣列
                # ConvertTo-NormalEntry：把既有 ts 釘成字串，避免重寫時被時區格式改掉
                $entries = @($j.entries | Where-Object { $null -ne $_ } | ForEach-Object { ConvertTo-NormalEntry $_ })
                $prompted = ConvertTo-TsKey $j.prompted_for
            }
        } catch {
            # 檔案被手動改壞 → 當成沒有歷史，重新開一份（fail-open：寧可少一筆歷史，
            # 也不要因為舊檔壞掉而讓這次的警告完全不被記錄）
            $entries = @()
            $prompted = ''
        }
    }

    # ── ts 的 '#'＋亂數後綴是**刻意的**，不是裝飾（2026-09-20 突變驗證抓到）──
    # ts 是 guard-dispatch-taint 判斷「這一筆問過沒」的唯一主鍵，所以它必須
    # (a) 跨行程原樣往返、(b) 每筆唯一。純 ISO 字串兩條都不成立：
    #   實測 '{"ts":"2026-09-20T14:04:44.1234567Z"}' | ConvertFrom-Json
    #     pwsh 7 → [DateTime]，"$_" render 成 '09/20/2026 14:04:44'（**秒級，丟掉 7 位小數**）
    #     5.1    → [String]，原樣
    #   ⇒ 兩個解譯器對同一個檔的解讀不同；更糟的是 pwsh 7 底下**同一秒內的兩筆警告
    #     會 render 成同一個字串** → 第二筆被當成「已經問過」而靜默清掉 taint。
    #     那正是斷路器最該響的情境（失控的 agent 會連續噴警告）。
    # 加了 '#xxxx' 之後字串不再像日期 → 兩邊都保持 [String] 原樣往返，且逐筆唯一。
    # test-dispatch-taint.ps1 §A9 用「同一秒內兩筆」機械釘住這個回歸。
    $ts = (Get-Date).ToUniversalTime().ToString('o') + '#' + ([guid]::NewGuid().ToString('N').Substring(0, 4))
    if ($entries.Count -gt 0) {
        # 防禦性：後綴已經保證唯一，這只是最後一道（亂數理論上可能撞）
        $lastTs = "$($entries[$entries.Count - 1].ts)"
        if ($lastTs -eq $ts) { $ts = $ts + '1' }
    }

    $entry = [ordered]@{
        ts         = $ts
        hook_event = $sourceKind
        agent_id   = $agentId
        snippet    = (Get-Snippet $corpus $hit.Index $hit.Length)
    }
    $entries = @($entries) + @([pscustomobject]$entry)
    # 成長上限：只留最近 50 筆。taint 的用途是「最新那筆要不要問」，
    # 舊筆只有稽核價值；無上限會讓一個長 session 的狀態檔無限膨脹。
    if ($entries.Count -gt 50) { $entries = @($entries[($entries.Count - 50)..($entries.Count - 1)]) }

    $out = [ordered]@{
        session_id   = $sid
        entries      = @($entries)
        prompted_for = $prompted
    }
    # -Depth 6 足夠（entries 是扁平物件陣列）；5.1 的 ConvertTo-Json 預設 Depth 2 會把
    # entries 內容吐成型別名稱字串，必須顯式指定。
    [IO.File]::WriteAllText($f, ($out | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))

    Write-GovLog 'record-security-warning' 'taint' "$sourceKind 命中；session=$key；entries=$($entries.Count)"
    [Console]::Error.WriteLine('[dispatch-taint] TAINTED — 派工斷路器偵測到安全警告／自承破壞訊號，已記錄 taint：下一次派 Agent／Workflow 前會先問你一次。')
    [Console]::Error.WriteLine("  來源：$sourceKind" + $(if ($agentId) { "（$agentId）" } else { '' }))
    [Console]::Error.WriteLine("  片段：$($entry.snippet)")
} catch { }

exit 0
