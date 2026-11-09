#!/usr/bin/env pwsh
# ============================================================
# lib-process-query-stall.ps1  --  LIBRARY (dot-sourced; never wired as a hook, never run directly)
#   pending-decisions 乙組 #10「卡住時 AI 收手（程序查詢逾時）」的判定與記錄邏輯（2026-11-08 使用者核定流程）。
#   2026-11-08 F1「負載合併」：原本是兩支獨立 hook（guard-process-query-stall PreToolUse、record-process-query-stall PostToolUse），
#   每次 Bash／PowerShell 呼叫各多起一支 pwsh（每支約 0.65 秒）。邏輯整支搬到本函式庫，改由「本來每次都會跑」的 hook 呼叫：
#     - Ag2bGuardEval  ： guard-bash.ps1 在原判定之後呼叫（PreToolUse）；guard-process-query-stall.ps1 是呼叫同一個函式的薄殼
#     - Ag2bRecordEval ： record-branch-switch.ps1 的 PostToolUse 路徑呼叫；record-process-query-stall.ps1 是呼叫同一個函式的薄殼，
#                         且仍是 PostToolUseFailure（只在工具失敗時觸發）唯一的接線
#   行為與搬家前逐位元相同（只是搬家）：決策表、整機程序列舉定義、失敗判定、計數與歸零、UNDETERMINED、GovLog 名稱都不變。
#   本檔不讀 stdin、不呼叫 exit、不起 Initialize-HookUtf8Output：函式只回傳字串（ASCII JSON），由呼叫端（已設好 UTF-8 輸出）寫出；
#   唯一的 Console 輸出是 Ag2bTempScopedDir 覆寫被忽略時的一行 ASCII 診斷（stderr）。
#
# 【決策表】（只對「整機程序列舉」；其他指令一律放行、連狀態檔都不讀）
#   本 session 計數 0（或沒有狀態檔）      放行
#   主迴圈、計數 1                          ask：「上次程序查詢逾時，電腦可能卡住；若不重試，建議存檔後重開機」
#                                           使用者按允許＝重試這一次（不另做授權登記檔，避免 AI 自己寫授權檔）；
#                                           這次若成功，記錄端把計數歸零；再失敗就變成計數 2。
#   主迴圈、計數 2 以上                     deny：「已連續逾時，建議存檔後重開機」
#   子代理（stdin 帶 agent_id）、計數 1 以上  deny：要求停手並以 needs_user_machine_action 回傳，交主迴圈在對話裡問
#   子代理分辨依據：guard-bash 的 D5 計數斷路器同樣以 stdin 的 agent_id／subagent_id 非空判定子代理。
#   【未驗證】真實子代理呼叫的 stdin 是否一定帶 agent_id、子代理的 session_id 是否與主迴圈相同（計數靠同一個 session_id 共用）；
#   若分辨不了，結果是子代理被當主迴圈處理＝ask（行為退回「一律 ask」，不會放行）。
#   deny 是 JSON 決定（permissionDecision），離開碼恆 0。與 guard-bash 合併後的優先序：guard-bash 原本的 deny（exit 2）最優先；
#   本層的 deny 蓋過 guard-bash 原本的 ask（等同合併前兩支 hook 並行時 deny 勝過 ask）；其餘 ask 以 guard-bash 自己的為準。
#
# 【整機程序列舉的定義（窄而明確；判定函式只在本檔一份，Ag2bProcQuery 區塊）】
#   算：tasklist（沒有 /FI "PID eq 數字或變數" 篩選）、Get-Process／gps／ps 沒有 -Id（-Pid、-p、-InputObject、--pid 也算單一程序）、
#       Get-CimInstance／gcim／Get-WmiObject／gwmi 查 Win32_Process（含 CIM_Process、Win32_PerfFormattedData_PerfProc_Process、
#       Win32_PerfRawData_PerfProc_Process）且沒有 ProcessId=數字或變數（或 Handle=）篩選、wmic process 與 wmic path win32_process
#       （同上篩選例外）、pslist／pslist64／tlist、Get-Counter 的 Process(*) 計數器、[System.Diagnostics.Process]::GetProcesses()。
#       Get-Process 帶 -Name／-ProcessName 或第一個位置參數是名稱時算 weak 類（查某個程式有沒有在跑，查無是正常結果）。
#   不算（排除）：Get-Process -Id、tasklist /FI "PID eq 數字或變數"、含 with-child／watch-workflow／runaway-watchdog／runaway-poll／
#       runaway-procs 字樣的那一段指令、heredoc 與 here-string 的內文（那是資料不是指令；但 heredoc 的開頭行是直譯器，或接管線
#       進 bash／sh／zsh／pwsh／powershell／cmd 時，內文算指令）、出現在引號字串或指令參數裡的字（grep tasklist、git commit -m 內文）。
#       bash／sh／zsh／pwsh／powershell／cmd 的 -c／-Command／/c／//c 字串、powershell（5.1）不帶旗標的位置參數、iex、
#       timeout／xargs／watch 後面接的指令，都會遞迴解析最多 3 層，雙引號字串裡的 $( ) 也會解析。反引號或反斜線接在空白後面的
#       續行會先接成一行。
#   只排除指令形狀，不改 with-child.mjs 與看門狗本身；它們自己內部起的程序查詢本 hook 看不到（殘餘）。
#   殘餘（字面層看不到，只靠規則）：直譯器內自行列程序（python psutil、node -e）、執行期組字、變數當指令（& $cmd）、
#   pwsh（7）的位置參數（那是 -File 不是指令）、timeout／xargs／watch 以外的前綴程式（例如 stdbuf、setsid）。
#
# 【判定「逾時或失敗」】Claude Code 對失敗的工具呼叫有獨立事件 PostToolUseFailure（證據：golden-tasks/2026-07-30-version-behavior-as-
# security-foundation.md 引二進位內建文件；CHANGELOG 第 3509 行 PostToolUse 與 PostToolUseFailure 輸入都帶 duration_ms）。
# 所以記錄邏輯同時處理 PostToolUse 與 PostToolUseFailure：
#   - 事件是 PostToolUseFailure＝失敗（含非零離開碼、逾時、使用者中斷）。
#   - 【逾時的主要形狀，審查 M1】指令超過工具逾時時，Claude Code 把它自動移到背景，工具回的是「成功」（is_error:false，
#     走 PostToolUse），tool_response 只帶 timedOutAfterMs（大於 0）與 backgroundTaskId，stdout 沒有任何逾時字樣。
#     證據（一手逐字稿，範圍：專案資料夾頂層 179 個 .jsonl）：toolUseResult 帶 timedOutAfterMs 的 135 行、stdout 含逾時字樣的 0 行。
#     所以 tool_response.timedOutAfterMs 大於 0 一律當逾時失敗（marker＝true，strong 與 weak 都計）；
#     只有 backgroundTaskId（或 tool_input.run_in_background）沒有 timedOutAfterMs＝主動轉背景，結果未知：不記、也不歸零。
#     【推測】hook 收到的 tool_response 與逐字稿的 toolUseResult 是同一個物件，本機沒有 hook stdin 一手紀錄，要窗口內正控制。
#   - 事件是 PostToolUse：另外 tool_response 帶 is_error／interrupted 旗標，或回應文字含逾時字樣
#     （timed out、逾時）或 Get-CimInstance :／Get-WmiObject :  這類錯誤開頭，才當失敗。
#   【未驗證】PostToolUseFailure 實際收到的欄位名（error、is_interrupt 等）本機找不到一手逐字稿；本檔對 error、message、is_interrupt、
#   interrupted、tool_response 都做寬容讀取。要窗口內拿真實 stdin 當正控制（見交接說明）。
# 【降低誤報】列舉後面還接管線或分號（例如 tasklist | findstr node）時，非零離開碼可能是 findstr 沒找到而不是列舉失敗：
#   這種「weak」類只有在失敗文字含逾時／中斷字樣或有中斷旗標或 timedOutAfterMs 時才計一次；列舉是整個指令的最後一段或後接 && 的「strong」類，
#   任何失敗都計。殘餘：weak 類真逾時但錯誤文字沒帶字樣，會漏記。
# 【查無不算卡住，審查 M2】Get-Process -Name X 查不到程序時離開碼是 1（失敗事件），但那是「X 沒在跑」的正常結果，不是機器卡住。
#   失敗文字含 Cannot find a process／NoProcessFoundForGivenName／ObjectNotFound／No tasks are running／No Instance(s) Available，
#   且沒有逾時或中斷記號時不計；成功路徑的文字規則也不再認 Get-Process : 開頭。Get-Process 帶名稱篩選算 weak 類，
#   沒有逾時記號的失敗不計。
# 【成功就歸零】計數 1 之後使用者按允許重試，若列舉成功（PostToolUse、非失敗、不是轉背景），把計數歸零，否則之後每次列舉都要使用者按一次。
#   歸零只發生在計數大於 0 且列舉成功時，不會把計數 2 以上歸零（那之後列舉已被擋）。轉背景（backgroundTaskId）不算成功。
#
# 【fail-open 的理由】本層是減負載的提醒層，不是安全邊界（真正的終止類動作由 guard-bash／guard-core 擋）。壞掉的後果只是
# 「少一次提醒」；若這裡 fail-closed，電腦卡住時 hook 自己出錯就會擋住所有程序查詢，連使用者要求的診斷都做不了。
# 所以 stdin／JSON 壞、狀態檔讀不了、regex 逾時、任何例外一律放行（函式回 $null／空字串）；狀態檔存在但讀不了時，
# 在狀態目錄的 procq-undetermined.jsonl 記一行 UNDETERMINED（不是「沒有卡過」，是「無法判定」）。本函式庫自己載入失敗時，
# guard-bash 在 GovLog 記一行 procq-lib-unavailable（可見的 fail-open），record-branch-switch 靜默略過（Post hook 一律不擋工具）。
# 殘餘：機器極卡時 hook 自己啟動也會慢（超時＝fail-open＝退回規則文字）。
#
# 【狀態檔】預設 $HOME\.claude\session-state\procq-stall-<session>.json；PROCQ_STATE_DIR 可覆寫，但只在系統暫存目錄之下
# 才採用且路徑上不得有 reparse point（settings 的 env 區塊是隱性不可信輸入）。內容：schema、session_id、count、first_ts、last_ts、
# last_event、last_class、last_basis；不存指令原文。GovLog 只記計數與類別（hook 名維持 guard-process-query-stall／record-process-query-stall）。
# 殘餘：使用者要解除計數 2 以上的擋下，需自己結束該 session 或自己刪除該狀態檔（agent 不得自行刪）。
#
# MSG_ASK: 上次程序查詢逾時，電腦可能卡住；若不重試，建議存檔後重開機。按允許＝重試這一次；若這次再失敗，之後同類查詢會被直接擋下。
# MSG_DENY_MAIN: 已連續逾時，建議存檔後重開機。本 session 的整台電腦程序查詢已停用；不要改寫指令再試，請在對話裡建議使用者存檔後重開機。
# MSG_DENY_SUB: 本 session 剛有整台電腦程序查詢逾時或失敗，電腦可能卡住；子代理不得自行再查。請停止該項查詢，並以 needs_user_machine_action 回傳（寫明想查什麼、為什麼要查，並提醒主迴圈：若使用者不重試，建議存檔後重開機），交主迴圈在對話裡問使用者；不要改寫指令再試。
# MSG_REMIND1: 【程序查詢卡住】剛才「列出整台電腦程序」的查詢逾時或失敗，電腦可能已經卡住。請立刻停手：不要自己換方法重試、不要再列程序。改在對話裡回報使用者並問：要不要重試？若不重試，建議先存檔再重開機。使用者說重試，下一次同類查詢會跳確認框，按允許才跑一次；你是子代理的話不要自己問，回傳 needs_user_machine_action 交主迴圈問。
# MSG_REMIND2: 【程序查詢連續卡住】整台電腦程序的查詢已連續逾時或失敗（本 session 第 {N} 次），之後同類查詢會被直接擋下。不要改寫指令再試；請在對話裡建議使用者存檔後重開機。你是子代理的話回傳 needs_user_machine_action。
# （上五行是給人讀的；程式裡是同內容的 base64，避免 Windows PowerShell 5.1 以系統碼頁讀壞中文。測試會逐字比對。）
# 本檔程式碼只用 ASCII，自寫函式一律 Ag2b 前綴。
# ============================================================

$Ag2bMsgAskB64 = '5LiK5qyh56iL5bqP5p+l6Kmi6YC+5pmC77yM6Zu76IWm5Y+v6IO95Y2h5L2P77yb6Iul5LiN6YeN6Kmm77yM5bu66K2w5a2Y5qqU5b6M6YeN6ZaL5qmf44CC5oyJ5YWB6Kix77yd6YeN6Kmm6YCZ5LiA5qyh77yb6Iul6YCZ5qyh5YaN5aSx5pWX77yM5LmL5b6M5ZCM6aGe5p+l6Kmi5pyD6KKr55u05o6l5pOL5LiL44CC'
$Ag2bMsgDenyMainB64 = '5bey6YCj57qM6YC+5pmC77yM5bu66K2w5a2Y5qqU5b6M6YeN6ZaL5qmf44CC5pysIHNlc3Npb24g55qE5pW05Y+w6Zu76IWm56iL5bqP5p+l6Kmi5bey5YGc55So77yb5LiN6KaB5pS55a+r5oyH5Luk5YaN6Kmm77yM6KuL5Zyo5bCN6Kmx6KOh5bu66K2w5L2/55So6ICF5a2Y5qqU5b6M6YeN6ZaL5qmf44CC'
$Ag2bMsgDenySubB64 = '5pysIHNlc3Npb24g5Ymb5pyJ5pW05Y+w6Zu76IWm56iL5bqP5p+l6Kmi6YC+5pmC5oiW5aSx5pWX77yM6Zu76IWm5Y+v6IO95Y2h5L2P77yb5a2Q5Luj55CG5LiN5b6X6Ieq6KGM5YaN5p+l44CC6KuL5YGc5q2i6Kmy6aCF5p+l6Kmi77yM5Lim5LulIG5lZWRzX3VzZXJfbWFjaGluZV9hY3Rpb24g5Zue5YKz77yI5a+r5piO5oOz5p+l5LuA6bq844CB54K65LuA6bq86KaB5p+l77yM5Lim5o+Q6YaS5Li76L+05ZyI77ya6Iul5L2/55So6ICF5LiN6YeN6Kmm77yM5bu66K2w5a2Y5qqU5b6M6YeN6ZaL5qmf77yJ77yM5Lqk5Li76L+05ZyI5Zyo5bCN6Kmx6KOh5ZWP5L2/55So6ICF77yb5LiN6KaB5pS55a+r5oyH5Luk5YaN6Kmm44CC'
$Ag2bMsgRemind1B64 = '44CQ56iL5bqP5p+l6Kmi5Y2h5L2P44CR5Ymb5omN44CM5YiX5Ye65pW05Y+w6Zu76IWm56iL5bqP44CN55qE5p+l6Kmi6YC+5pmC5oiW5aSx5pWX77yM6Zu76IWm5Y+v6IO95bey57aT5Y2h5L2P44CC6KuL56uL5Yi75YGc5omL77ya5LiN6KaB6Ieq5bex5o+b5pa55rOV6YeN6Kmm44CB5LiN6KaB5YaN5YiX56iL5bqP44CC5pS55Zyo5bCN6Kmx6KOh5Zue5aCx5L2/55So6ICF5Lim5ZWP77ya6KaB5LiN6KaB6YeN6Kmm77yf6Iul5LiN6YeN6Kmm77yM5bu66K2w5YWI5a2Y5qqU5YaN6YeN6ZaL5qmf44CC5L2/55So6ICF6Kqq6YeN6Kmm77yM5LiL5LiA5qyh5ZCM6aGe5p+l6Kmi5pyD6Lez56K66KqN5qGG77yM5oyJ5YWB6Kix5omN6LeR5LiA5qyh77yb5L2g5piv5a2Q5Luj55CG55qE6Kmx5LiN6KaB6Ieq5bex5ZWP77yM5Zue5YKzIG5lZWRzX3VzZXJfbWFjaGluZV9hY3Rpb24g5Lqk5Li76L+05ZyI5ZWP44CC'
$Ag2bMsgRemind2B64 = '44CQ56iL5bqP5p+l6Kmi6YCj57qM5Y2h5L2P44CR5pW05Y+w6Zu76IWm56iL5bqP55qE5p+l6Kmi5bey6YCj57qM6YC+5pmC5oiW5aSx5pWX77yI5pysIHNlc3Npb24g56ysIHtOfSDmrKHvvInvvIzkuYvlvozlkIzpoZ7mn6XoqaLmnIPooqvnm7TmjqXmk4vkuIvjgILkuI3opoHmlLnlr6vmjIfku6Tlho3oqabvvJvoq4vlnKjlsI3oqbHoo6Hlu7rorbDkvb/nlKjogIXlrZjmqpTlvozph43plovmqZ/jgILkvaDmmK/lrZDku6PnkIbnmoToqbHlm57lgrMgbmVlZHNfdXNlcl9tYWNoaW5lX2FjdGlvbuOAgg=='

function Ag2bGetUtf8 { return (New-Object System.Text.UTF8Encoding $false) }

function Ag2bDecode([string]$b64) { return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) }

function Ag2bToAsciiJson($obj) {
    $j = $obj | ConvertTo-Json -Depth 6 -Compress
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $j.ToCharArray()) {
        if ([int]$ch -gt 126) { [void]$sb.Append([char]92).Append('u').Append(([int]$ch).ToString('x4')) }
        else { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}

# GetFullPath().StartsWith(TEMP) compares strings only and never resolves reparse points: check every existing ancestor.
function Ag2bNoReparseUnderTemp([string]$full, [string]$tmpRoot) {
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

function Ag2bTempScopedDir([string]$envValue, [string]$default) {
    if (-not $envValue) { return $default }
    try {
        $c = [IO.Path]::GetFullPath($envValue)
        $tmp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($c.StartsWith($tmp, [System.StringComparison]::OrdinalIgnoreCase) -and (Ag2bNoReparseUnderTemp $c $tmp)) { return $c }
        [Console]::Error.WriteLine('[procq] ignored state dir override (not under TEMP or via junction)')
        return $default
    } catch {
        [Console]::Error.WriteLine('[procq] ignored state dir override (unparsable path)')
        return $default
    }
}

# $hook is 'guard-process-query-stall' (PreToolUse side) or 'record-process-query-stall' (Post side): the GovLog and UNDETERMINED
# lines keep the names they had when the two sides were separate hooks (tests and the log scanners key on them).
function Ag2bGovLog([string]$hook, [string]$decision, [string]$why) {
    try {
        $dir = Ag2bTempScopedDir $env:GOVLOG_DIR (Join-Path $HOME '.claude\governance-logs')
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $f = Join-Path $dir ('decisions-' + (Get-Date -Format 'yyyy-MM') + '.jsonl')
        $line = @{ ts = (Get-Date -Format 'o'); hook = $hook; decision = $decision; why = $why } | ConvertTo-Json -Compress
        Add-Content -LiteralPath $f -Value $line -Encoding utf8
    } catch { }
}

function Ag2bSafeKey([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return '' }
    $k = $s -replace '[^A-Za-z0-9_.-]', '_'
    $k = $k -replace '\.{2,}', '.'
    $k = $k.Trim('.')
    if ($k.Length -gt 80) { $k = $k.Substring(0, 80) }
    return $k
}

function Ag2bLogUndetermined([string]$hook, [string]$dir, [string]$sid, [string]$reason) {
    try {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $o = [ordered]@{ ts = (Get-Date).ToUniversalTime().ToString('o'); hook = $hook; verdict = 'UNDETERMINED'; session_id = (Ag2bSafeKey $sid); reason = $reason }
        [IO.File]::AppendAllText((Join-Path $dir 'procq-undetermined.jsonl'), (($o | ConvertTo-Json -Compress) + "`n"), (Ag2bGetUtf8))
    } catch { }
}

# state: @{ kind = 'absent' | 'ok' | 'bad'; count = int; first_ts = string }
function Ag2bReadState([string]$file) {
    if (-not (Test-Path -LiteralPath $file)) { return @{ kind = 'absent'; count = 0; first_ts = '' } }
    try {
        $txt = [IO.File]::ReadAllText($file, (Ag2bGetUtf8))
        if ([string]::IsNullOrWhiteSpace($txt)) { return @{ kind = 'bad'; count = 0; first_ts = '' } }
        $j = $txt | ConvertFrom-Json
        $c = 0
        # PowerShell 7 gives every object an intrinsic .Count (an array of 3 "has" count 3, a count-less object "has" count 1):
        # demand a real JSON object that carries its own count property, otherwise the file is bad (guard: fail-open + UNDETERMINED; record: restart at 1 + UNDETERMINED)
        # (full type name on purpose: in Windows PowerShell 5.1 the [pscustomobject] accelerator means PSObject, and every object is one)
        if ($null -eq $j -or $j -isnot [System.Management.Automation.PSCustomObject]) { return @{ kind = 'bad'; count = 0; first_ts = '' } }
        $cp = $j.PSObject.Properties['count']
        if ($null -eq $cp -or -not [int]::TryParse("$($cp.Value)", [ref]$c) -or $c -lt 0 -or $c -gt 100000) { return @{ kind = 'bad'; count = 0; first_ts = '' } }
        # pwsh 7 turns an ISO string into [DateTime] on ConvertFrom-Json (5.1 keeps the string): normalise so both write the same text back
        $ft = ''
        if ($j.first_ts -is [datetime]) { $ft = $j.first_ts.ToUniversalTime().ToString('o') }
        elseif ($j.first_ts -is [datetimeoffset]) { $ft = $j.first_ts.UtcDateTime.ToString('o') }
        else { $ft = "$($j.first_ts)" }
        return @{ kind = 'ok'; count = $c; first_ts = $ft }
    } catch { return @{ kind = 'bad'; count = 0; first_ts = '' } }
}

# ---- BEGIN shared block Ag2bProcQuery (single copy since the F1 merge; test-process-query-stall.ps1 pins that no hook file carries a second one) ----
function Ag2bUnquote([string]$Tok) {
    $t = "$Tok".Trim()
    if ($t.Length -ge 2 -and (($t[0] -eq '"' -and $t[$t.Length - 1] -eq '"') -or ($t[0] -eq "'" -and $t[$t.Length - 1] -eq "'"))) { $t = $t.Substring(1, $t.Length - 2) }
    return $t.Trim()
}
function Ag2bIsSepTok([string]$Tok) { return [regex]::IsMatch($Tok, '^(?:\r?\n|\r|&&|\|\||[;|&(){}])$') }
function Ag2bVerbName([string]$Tok) {
    $u = Ag2bUnquote $Tok
    $bn = @($u -split '[\\/]')[-1]
    if ($null -eq $bn) { return '' }
    return ($bn.ToLowerInvariant() -replace '\.(exe|cmd|bat|com)$', '')
}
# Returns '' (not a machine-wide process listing), 'strong' (the listing is the last stage of the command or is followed by &&,
# so a failure of the call is most likely the listing's own failure) or 'weak' (more commands follow after a pipe or semicolon, so
# a non-zero exit may belong to a downstream filter such as findstr; also Get-Process with a name filter, where "not found" is a normal
# result). Never throws; any internal error returns ''.
function Ag2bProcQueryClass {
    param([string]$Cmd, [int]$Depth = 0)
    try {
        if ([string]::IsNullOrWhiteSpace($Cmd) -or $Cmd.Length -gt 262144 -or $Depth -gt 3) { return '' }
        $to = [TimeSpan]::FromSeconds(3)
        $ic = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        if (-not [regex]::IsMatch($Cmd, 'tasklist|get-process|\bgps\b|\bps\b|get-ciminstance|\bgcim\b|get-wmiobject|\bgwmi\b|wmic|pslist|\btlist\b|getprocesses|get-counter', $ic, $to)) { return '' }
        # heredoc bodies and PowerShell here-string bodies are data, not commands (unless the head line starts a shell interpreter or pipes into one)
        $shellHeadRx = '^\s*(?:[^\s|&;]*[\\/])?(?:bash|sh|zsh|pwsh|powershell|cmd)(?:\.exe)?(?:\s|$)'
        $shellPipeRx = '\|\s*(?:[^\s|&;]*[\\/])?(?:bash|sh|zsh|pwsh|powershell|cmd)(?:\.exe)?\s*$'
        $keep = New-Object System.Collections.Generic.List[string]
        $skipTag = $null
        $skipHere = $null
        foreach ($ln in [regex]::Split($Cmd, '\r?\n')) {
            if ($null -ne $skipTag) { if ($ln.Trim() -eq $skipTag) { $skipTag = $null }; continue }
            if ($null -ne $skipHere) { if ($ln.TrimStart().StartsWith($skipHere)) { $skipHere = $null }; continue }
            [void]$keep.Add($ln)
            $hm = [regex]::Match($ln, '<<-?\s*(["'']?)([A-Za-z_][A-Za-z0-9_]*)\1', 'None', $to)
            if ($hm.Success -and $ln -notmatch '<<<') {
                if (-not ([regex]::IsMatch($ln, $shellHeadRx, $ic, $to) -or [regex]::IsMatch($ln, $shellPipeRx, $ic, $to))) { $skipTag = $hm.Groups[2].Value }
            } elseif ($ln.TrimEnd().EndsWith("@'")) { $skipHere = "'@" }
            elseif ($ln.TrimEnd().EndsWith('@"')) { $skipHere = '"@' }
        }
        $text = ($keep.ToArray() -join "`n")
        # a backtick (PowerShell) or backslash (bash) after a space, then a line break, continues the command on the next line
        $text = [regex]::Replace($text, '[ \t](?:`|\\)\n', ' ', 'None', $to)
        $toks = @([regex]::Matches($text, '"(?:[^"\\]|\\.)*"|''[^'']*''|\r?\n|&&|\|\||[;|&(){}]|[^\s;&|(){}"'']+', 'None', $to) | ForEach-Object { $_.Value })
        $n = $toks.Count
        $prefixWords = @('if', 'elif', 'then', 'else', 'while', 'until', 'do', '!', '-not', 'return', 'time', 'exec', 'command', 'env', 'sudo', 'nohup', 'call', 'builtin', 'nice')
        $singlePidRx = '(?<![A-Za-z])(?:processid|handle)\s*=\s*[''"]?(?:\d+|\$[A-Za-z_{][A-Za-z0-9_}:]*)'
        $fiPidRx = '[/-]fi\s+["'']?\s*pid\s+eq\s+(?:\d+|\$[A-Za-z_{][A-Za-z0-9_}:]*|%[A-Za-z0-9_]+%)'
        $hit = ''
        $atCmd = $true
        $i = 0
        while ($i -lt $n) {
            $t = $toks[$i]
            if (Ag2bIsSepTok $t) { $atCmd = $true; $i++; continue }
            if ($t.Length -ge 2 -and $t[0] -eq '"' -and $t.Contains('$(')) {
                foreach ($sm in [regex]::Matches($t, '\$\(([^)]*)\)', 'None', $to)) {
                    $rr = Ag2bProcQueryClass -Cmd $sm.Groups[1].Value -Depth ($Depth + 1)
                    if ($rr -eq 'strong' -or ($rr -eq 'weak' -and $hit -eq '')) { $hit = $rr }
                }
            }
            if (-not $atCmd) {
                if ($t -eq '=' -or $t.EndsWith('=') -or $t.ToLowerInvariant() -eq 'in') { $atCmd = $true }
                $i++
                continue
            }
            # command position
            $stay = $false
            $vt = $t
            $em = [regex]::Match($t, '^\$?[A-Za-z_][A-Za-z0-9_:]*=(.*)$', 'None', $to)
            if ($em.Success) { $stay = $true; $vt = $em.Groups[1].Value }
            $verb = Ag2bVerbName $vt
            $j = $i + 1
            while ($j -lt $n -and -not (Ag2bIsSepTok $toks[$j])) { $j++ }
            $argv = @()
            if ($j -gt $i + 1) { $argv = @($toks[($i + 1)..($j - 1)]) }
            $segText = ($t + ' ' + ($argv -join ' '))
            $isHit = $false
            $forceWeak = $false
            $code = $null
            $skipSeg = [regex]::IsMatch($segText, 'with-child|watch-workflow|runaway-watchdog|runaway-poll|runaway-procs', $ic, $to)
            if (-not $skipSeg -and $verb -ne '') {
                $joined = (@($argv | ForEach-Object { Ag2bUnquote $_ }) -join ' ')
                if ($verb -eq 'tasklist') {
                    $isHit = -not [regex]::IsMatch($joined, $fiPidRx, $ic, $to)
                } elseif ($verb -eq 'get-process' -or $verb -eq 'gps' -or $verb -eq 'ps') {
                    $isHit = -not [regex]::IsMatch($joined, '(^|\s)-(id|pid|p|inputobject)(:|\s|$)|--pid', $ic, $to)
                    if ($isHit -and $verb -ne 'ps' -and ([regex]::IsMatch($joined, '(^|\s)-(name|processname)(:|\s|$)', $ic, $to) -or [regex]::IsMatch($joined, '^[^-\s]', 'None', $to))) { $forceWeak = $true }
                } elseif ($verb -eq 'get-ciminstance' -or $verb -eq 'gcim' -or $verb -eq 'get-wmiobject' -or $verb -eq 'gwmi') {
                    $isHit = ([regex]::IsMatch($joined, '(?:win32_process|cim_process|win32_perfformatteddata_perfproc_process|win32_perfrawdata_perfproc_process)(?![A-Za-z0-9_])', $ic, $to)) -and -not ([regex]::IsMatch($joined, $singlePidRx, $ic, $to))
                } elseif ($verb -eq 'wmic') {
                    $first = @($argv | ForEach-Object { Ag2bUnquote $_ } | Where-Object { $_ -notmatch '^/' }) | Select-Object -First 1
                    $isHit = (("$first" -ieq 'process') -or [regex]::IsMatch($joined, '(^|\s)path\s+win32_process(?![A-Za-z0-9_])', $ic, $to)) -and -not ([regex]::IsMatch($joined, $singlePidRx, $ic, $to))
                } elseif ($verb -eq 'pslist' -or $verb -eq 'pslist64' -or $verb -eq 'tlist') {
                    $isHit = $true
                } elseif ($verb -eq 'get-counter') {
                    $isHit = [regex]::IsMatch($joined, '[\\]process\(\*\)', $ic, $to)
                } elseif ($verb -match '^\[(?:system\.)?diagnostics\.process\]::getprocesses$') {
                    $isHit = $true
                } elseif ($verb -eq 'iex' -or $verb -eq 'invoke-expression') {
                    if ($argv.Count -ge 1) { $code = (Ag2bUnquote $argv[0]) }
                } elseif ($verb -eq 'timeout' -or $verb -eq 'xargs' -or $verb -eq 'watch') {
                    $q = 0
                    while ($q -lt $argv.Count) {
                        $qa = Ag2bUnquote $argv[$q]
                        if ($qa -match '^-' -or $qa -match '^\d+(\.\d+)?[smhd]?$') { $q++ } else { break }
                    }
                    if ($q -lt $argv.Count) { $code = (@($argv[$q..($argv.Count - 1)] | ForEach-Object { Ag2bUnquote $_ }) -join ' ') }
                } elseif ($verb -eq 'bash' -or $verb -eq 'sh' -or $verb -eq 'zsh' -or $verb -eq 'pwsh' -or $verb -eq 'powershell' -or $verb -eq 'cmd') {
                    $hasFileFlag = $false
                    for ($m = 0; $m -lt $argv.Count; $m++) {
                        $al = (Ag2bUnquote $argv[$m]).ToLowerInvariant()
                        if ($al -match '^-(file|f|encodedcommand|ec|e)$') { $hasFileFlag = $true }
                        $isCodeFlag = $false
                        if ($verb -eq 'cmd') { $isCodeFlag = ($al -eq '/c' -or $al -eq '/k' -or $al -eq '//c' -or $al -eq '//k') }
                        elseif ($verb -eq 'pwsh' -or $verb -eq 'powershell') { $isCodeFlag = ($al -eq '-c' -or $al -eq '-command') }
                        else { $isCodeFlag = [regex]::IsMatch($al, '^-[a-z]*c$') }
                        if ($isCodeFlag -and ($m + 1) -lt $argv.Count) {
                            $restArgs = @($argv[($m + 1)..($argv.Count - 1)])
                            if ($restArgs.Count -eq 1) { $code = (Ag2bUnquote $restArgs[0]) } else { $code = (@($restArgs | ForEach-Object { Ag2bUnquote $_ }) -join ' ') }
                            break
                        }
                    }
                    # Windows PowerShell 5.1 treats an argument without a flag as -Command (pwsh 7 treats it as -File, so it is not code there)
                    if ($null -eq $code -and $verb -eq 'powershell' -and -not $hasFileFlag) {
                        $pm = 0
                        while ($pm -lt $argv.Count) {
                            $pa = (Ag2bUnquote $argv[$pm]).ToLowerInvariant()
                            if ($pa -match '^-(executionpolicy|ep|windowstyle|w|inputformat|outputformat|version|configurationname|workingdirectory)$') { $pm += 2; continue }
                            if ($pa -match '^-') { $pm++; continue }
                            break
                        }
                        if ($pm -lt $argv.Count) { $code = (@($argv[$pm..($argv.Count - 1)] | ForEach-Object { Ag2bUnquote $_ }) -join ' ') }
                    }
                }
            }
            if ($isHit -or $null -ne $code) {
                $cls = 'weak'
                if ($isHit -or $null -ne $code) {
                    $restHasCmd = $false
                    for ($k = $j; $k -lt $n; $k++) { if (-not (Ag2bIsSepTok $toks[$k])) { $restHasCmd = $true; break } }
                    $nextSep = ''
                    if ($j -lt $n) { $nextSep = $toks[$j] }
                    if ((-not $restHasCmd) -or $nextSep -eq '&&') { $cls = 'strong' }
                }
                if ($forceWeak) { $cls = 'weak' }
                $res = ''
                if ($isHit) { $res = $cls }
                if ($null -ne $code) {
                    $inner = Ag2bProcQueryClass -Cmd $code.Replace('\"', '"') -Depth ($Depth + 1)
                    if ($inner -ne '') { if ($cls -eq 'weak') { $inner = 'weak' }; $res = $inner }
                }
                if ($res -eq 'strong' -or ($res -eq 'weak' -and $hit -eq '')) { $hit = $res }
            }
            if ($stay -or ($prefixWords -contains $verb)) { $atCmd = $true } else { $atCmd = $false }
            $i++
        }
        return $hit
    } catch { return '' }
}
# ---- END shared block Ag2bProcQuery ----

function Ag2bTextOf($v, [int]$max) {
    if ($null -eq $v) { return '' }
    $s = ''
    if ($v -is [string]) { $s = $v } else { try { $s = ($v | ConvertTo-Json -Depth 4 -Compress) } catch { $s = '' } }
    if ($null -eq $s) { return '' }
    if ($s.Length -gt $max) { $s = $s.Substring(0, $max) }
    return $s
}

# ------------------------------------------------------------
# PreToolUse side. $data is the parsed hook stdin object (Bash or PowerShell call).
# Returns $null (no opinion) or [pscustomobject]@{ decision = 'ask' | 'deny'; json = '<single-line ASCII JSON>' }.
# Never throws, never writes to the console except the one-line [procq] override diagnostic; the caller writes .json and exits 0.
# ------------------------------------------------------------
function Ag2bGuardEval($data) {
    $ErrorActionPreference = 'SilentlyContinue'
    $hookName = 'guard-process-query-stall'
    try {
        if ($null -eq $data) { return $null }
        $tool = "$($data.tool_name)"
        if ($tool -and $tool -ne 'Bash' -and $tool -ne 'PowerShell') { return $null }
        $cmd = $data.tool_input.command
        if ($cmd -isnot [string]) { return $null }

        # count 0 means complete silence, so the cheap command classification runs first and nothing else is touched for ordinary commands
        $cls = Ag2bProcQueryClass -Cmd $cmd
        if ($cls -ne 'strong' -and $cls -ne 'weak') { return $null }

        $sid = "$($data.session_id)"
        $sidKey = Ag2bSafeKey $sid
        if (-not $sidKey) { return $null }
        $dir = Ag2bTempScopedDir $env:PROCQ_STATE_DIR (Join-Path $HOME '.claude\session-state')
        $file = Join-Path $dir ('procq-stall-' + $sidKey + '.json')
        $st = Ag2bReadState $file
        if ($st.kind -eq 'absent') { return $null }
        if ($st.kind -eq 'bad') {
            Ag2bLogUndetermined $hookName $dir $sid 'state file exists but could not be read or parsed; the listing is allowed (fail-open reminder layer)'
            return $null
        }
        if ($st.count -le 0) { return $null }

        $agent = ''
        foreach ($cand in @("$($data.agent_id)", "$($data.subagent_id)")) { if (-not [string]::IsNullOrWhiteSpace($cand)) { $agent = $cand; break } }

        if ($agent) {
            Ag2bGovLog $hookName 'deny' ('subagent, count=' + $st.count + ' class=' + $cls)
            $o = [ordered]@{ hookSpecificOutput = [ordered]@{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = (Ag2bDecode $Ag2bMsgDenySubB64) } }
            return [pscustomobject]@{ decision = 'deny'; json = (Ag2bToAsciiJson $o) }
        }
        if ($st.count -ge 2) {
            Ag2bGovLog $hookName 'deny' ('main loop, count=' + $st.count + ' class=' + $cls)
            $o = [ordered]@{ hookSpecificOutput = [ordered]@{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = (Ag2bDecode $Ag2bMsgDenyMainB64) } }
            return [pscustomobject]@{ decision = 'deny'; json = (Ag2bToAsciiJson $o) }
        }
        Ag2bGovLog $hookName 'ask' ('main loop, count=1 class=' + $cls)
        $o = [ordered]@{ hookSpecificOutput = [ordered]@{ hookEventName = 'PreToolUse'; permissionDecision = 'ask'; permissionDecisionReason = (Ag2bDecode $Ag2bMsgAskB64) } }
        return [pscustomobject]@{ decision = 'ask'; json = (Ag2bToAsciiJson $o) }
    } catch {
        return $null
    }
}

# ------------------------------------------------------------
# Post side (PostToolUse from record-branch-switch, PostToolUse and PostToolUseFailure from record-process-query-stall).
# $data is the parsed hook stdin object. Returns '' (nothing to say) or a single-line ASCII JSON additionalContext reminder.
# Writes the per-session count file; never throws; the caller writes the returned text and exits 0.
# ------------------------------------------------------------
function Ag2bRecordEval($data) {
    $ErrorActionPreference = 'SilentlyContinue'
    $hookName = 'record-process-query-stall'
    try {
        if ($null -eq $data) { return '' }
        $tool = "$($data.tool_name)"
        if ($tool -and $tool -ne 'Bash' -and $tool -ne 'PowerShell') { return '' }
        $cmd = $data.tool_input.command
        if ($cmd -isnot [string]) { return '' }

        $cls = Ag2bProcQueryClass -Cmd $cmd
        if ($cls -ne 'strong' -and $cls -ne 'weak') { return '' }

        $ev = "$($data.hook_event_name)"
        $evName = 'PostToolUse'
        if ($ev -eq 'PostToolUseFailure') { $evName = 'PostToolUseFailure' }
        $resp = $data.tool_response
        $opt = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        $to = [TimeSpan]::FromSeconds(3)
        $zhTimeout = [string]::Concat([char]0x903E, [char]0x6642)
        $zhTimeout2 = [string]::Concat([char]0x8D85, [char]0x6642)
        $rxAny = New-Object System.Text.RegularExpressions.Regex(('\btime[d]?[ -]?out\b|' + $zhTimeout + '|' + $zhTimeout2 + '|\binterrupt(ed)?\b|\baborted\b|\bcancel(l)?ed\b'), $opt, $to)
        $rxText = New-Object System.Text.RegularExpressions.Regex(('\btimed out\b|' + $zhTimeout + '|(Get-CimInstance|Get-WmiObject)\s*:'), $opt, $to)
        $rxNotFound = New-Object System.Text.RegularExpressions.Regex('Cannot find a process|NoProcessFoundForGivenName|ObjectNotFound|No tasks are running|No Instance\(s\) Available', $opt, $to)
        $rxFalseFlag = New-Object System.Text.RegularExpressions.Regex('"(?:interrupted|is_interrupt|isInterrupt)"\s*:\s*false', $opt, $to)

        $errText = Ag2bTextOf $data.error 20000
        $respText = Ag2bTextOf $resp 300000
        $msgText = Ag2bTextOf $data.message 2000
        # a response object serialised to text carries its own "interrupted":false key; that is not an interruption marker
        $respScan = $rxFalseFlag.Replace($respText, '')

        # M1: a command that outlived the tool timeout comes back as a SUCCESS (is_error false) moved to the background; the only trace is
        # the numeric timedOutAfterMs (and a backgroundTaskId) in tool_response
        $tmoMs = [long]0
        try { $tmoMs = [long]("$($resp.timedOutAfterMs)") } catch { $tmoMs = [long]0 }
        $bgId = "$($resp.backgroundTaskId)"
        $runBg = ($data.tool_input.run_in_background -eq $true)

        $failed = $false
        $marker = $false
        $basis = 'event'
        if ($evName -eq 'PostToolUseFailure') { $failed = $true }
        if ($data.is_interrupt -eq $true -or $data.interrupted -eq $true -or $resp.interrupted -eq $true -or $resp.is_interrupt -eq $true) { $failed = $true; $marker = $true; $basis = 'flag' }
        if (-not [string]::IsNullOrWhiteSpace($errText)) { $failed = $true }
        if ($resp.is_error -eq $true -or $resp.isError -eq $true) { $failed = $true; if ($basis -eq 'event') { $basis = 'flag' } }
        if ($tmoMs -gt 0) { $failed = $true; $marker = $true; $basis = 'timeout-field' }
        if ($failed) {
            if ($rxAny.IsMatch($errText + "`n" + $respScan + "`n" + $msgText)) { $marker = $true }
        } elseif ($rxText.IsMatch($respText) -and -not $rxNotFound.IsMatch($respText)) {
            $failed = $true; $marker = $true; $basis = 'text'
        }

        $sid = "$($data.session_id)"
        $sidKey = Ag2bSafeKey $sid
        $dir = Ag2bTempScopedDir $env:PROCQ_STATE_DIR (Join-Path $HOME '.claude\session-state')
        if (-not $sidKey) {
            if ($failed) { Ag2bLogUndetermined $hookName $dir '' 'no session_id on a failed process listing; stall not recorded' }
            return ''
        }
        $file = Join-Path $dir ('procq-stall-' + $sidKey + '.json')

        if (-not $failed) {
            # moved to the background on purpose (or by a harness that reports only an id): the result is unknown, so neither count nor reset
            if ($bgId -or $runBg) {
                Ag2bGovLog $hookName 'ignored-background' ('class=' + $cls + ' result unknown; counter untouched')
                return ''
            }
            # success: a listing that works again clears a count of 1 (the user allowed one retry and it went through)
            $st = Ag2bReadState $file
            if ($st.kind -eq 'bad') {
                Ag2bLogUndetermined $hookName $dir $sid 'state file unreadable at success time; no reset was done'
            } elseif ($st.kind -eq 'ok' -and $st.count -ge 1 -and $st.count -le 1) {
                $o = [ordered]@{ schema = 1; session_id = $sidKey; count = 0; first_ts = ''; last_ts = (Get-Date).ToUniversalTime().ToString('o'); last_event = $evName; last_class = $cls; last_basis = 'success-reset' }
                [IO.File]::WriteAllText($file, ($o | ConvertTo-Json -Compress), (Ag2bGetUtf8))
                Ag2bGovLog $hookName 'reset' ('count=0 class=' + $cls)
            }
            return ''
        }

        # M2: "process not found" is a normal answer to Get-Process -Name X (exit code 1), not a sign that the machine is stuck
        if (-not $marker -and $rxNotFound.IsMatch($errText + "`n" + $respText + "`n" + $msgText)) {
            Ag2bGovLog $hookName 'ignored-notfound' ('class=' + $cls + ' basis=' + $basis + ' not-found result is not a stall')
            return ''
        }

        if ($cls -eq 'weak' -and -not $marker) {
            Ag2bGovLog $hookName 'ignored-weak' ('class=weak basis=' + $basis + ' no timeout marker; exit code may belong to a downstream filter')
            return ''
        }

        $st = Ag2bReadState $file
        $n = 1
        $first = (Get-Date).ToUniversalTime().ToString('o')
        if ($st.kind -eq 'ok') {
            $n = [Math]::Min($st.count + 1, 99)
            if ($st.first_ts) { $first = $st.first_ts }
        } elseif ($st.kind -eq 'bad') {
            Ag2bLogUndetermined $hookName $dir $sid 'state file unreadable at record time; restarted the count at 1'
        }
        $o = [ordered]@{ schema = 1; session_id = $sidKey; count = $n; first_ts = $first; last_ts = (Get-Date).ToUniversalTime().ToString('o'); last_event = $evName; last_class = $cls; last_basis = $basis }
        try {
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            [IO.File]::WriteAllText($file, ($o | ConvertTo-Json -Compress), (Ag2bGetUtf8))
        } catch {
            Ag2bLogUndetermined $hookName $dir $sid 'could not write the state file; the reminder is still shown'
        }
        Ag2bGovLog $hookName 'recorded' ('count=' + $n + ' class=' + $cls + ' basis=' + $basis + ' marker=' + $marker)

        $msg = ''
        if ($n -ge 2) { $msg = (Ag2bDecode $Ag2bMsgRemind2B64).Replace('{N}', "$n") } else { $msg = (Ag2bDecode $Ag2bMsgRemind1B64) }
        $out = [ordered]@{ hookSpecificOutput = [ordered]@{ hookEventName = $evName; additionalContext = $msg } }
        return (Ag2bToAsciiJson $out)
    } catch {
        return ''
    }
}
