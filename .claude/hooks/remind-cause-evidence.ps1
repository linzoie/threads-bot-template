#!/usr/bin/env pwsh
# ============================================================
# remind-cause-evidence.ps1  --  PostToolUse hook (matcher: Edit|Write|MultiEdit)
#   pending-decisions 乙組 #7「發布前先定案」的機械層 A（2026-10-19 提案、2026-11-08 使用者核准全選建議）
#
# 【為什麼存在】session b34c77d2 把「第一版根因」未經實驗就寫進 pending 與 memory，隔天被受控實驗推翻。
# 規則（全域 CLAUDE.md「宣稱就舉證 -> 發布前先定案」）在場也會失效，所以加一道只提醒的機械層：
# 往長期文件寫因果陳述、而陳述附近沒有證據標記時，在寫入完成的下一刻把提醒放到模型眼前。
#
# 【為什麼選 PostToolUse（而不是 PreToolUse）】
#   1) 提醒要「看得到」：additionalContext 緊接在該次寫入的工具結果之後，模型當下就能補寫或改標，
#      不必等下一輪；
#   2) PostToolUse 只在寫入真的成功後才觸發——被 guard-write 的確認框拒絕的寫入不會產生雜訊；
#   3) 同一個 matcher（Edit|Write|MultiEdit）的 after-edit.ps1 已用 PostToolUse additionalContext
#      輸出提醒，欄位形狀在本 repo 內有先例；PreToolUse 同 matcher 已有 guard-write 的授權決定，
#      多一支輸出 additionalContext 的 hook 要多考慮與決定欄位的合併，沒有必要。
#   【未驗證】本 hook 的提醒在真實 session 是否被模型讀到，要等使用者接線後實測（欄位形狀同 after-edit）。
#
# 【觸發條件（三者皆成立才提醒）】
#   a) 寫入目標是長期文件：.governance/pending-decisions.md、任何 memory 資料夾下的 *.md、
#      research-decisions 資料夾下的 *.md、CLAUDE.md、AGENTS.md、.governance/handoff/projects/*.md；
#   b) 這次「新寫入的文字」（Write 的 content、Edit 的 new_string、MultiEdit 各項的 new_string）
#      含窄版觸發詞（下方 TRIGGERS 行，不超過 10 個；前一個字是「不」者視為否定、略過）；
#   c) 該觸發詞前後各約 200 字（字元數，不是行／段／句；待裁決常整條寫成一行）以內，沒有任何證據標記
#      （下方 MARKERS 行，另加 commit 雜湊樣式：7~40 個十六進位字元、至少含一個數字與一個 a-f 字母）。
#   標記整個詞必須落在視窗內（跨過視窗邊界的標記不算）。
#   TRIGGERS: 根因是|原因是|確定是|已證實|證明了|真正原因|root cause is|root cause was
#   MARKERS: 一手|實測|實跑|推測|未驗證|逐字稿|證據|實驗|重現|evidence|verified|measured|hypothesis
#   （上兩行是給人讀的；程式裡是同內容的 base64，避免 Windows PowerShell 5.1 以系統碼頁讀壞中文。
#    測試 test-remind-cause-evidence.ps1 會逐字比對兩者，並逐詞實測行為。）
#
# 【設計：安全網不是閘門】永遠 exit 0、永遠不阻擋、不寫任何狀態檔。任何一步出錯（stdin 壞掉、JSON 壞掉、
# 欄位型別不符、regex 逾時、字串過大）一律安靜放行：降級方向只能是「沒提醒」，不得擋住寫入。
# 殘餘：換掉措辭、或明知故犯寫上標記，都抓不到；誤報率沒有實測【推測】。
# 本檔程式碼只用 ASCII（中文只在註解與 base64 裡），自寫函式一律 Ag2b 前綴。
# ============================================================
$ErrorActionPreference = 'SilentlyContinue'

# stdin is read as raw bytes and decoded as UTF-8 (see after-edit.ps1 for the full reasoning: Console.In
# decodes with the console code page, which corrupts non-ASCII text on a zh-TW machine).
function Read-StdinUtf8 {
    $b = $null
    if ([Console]::IsInputRedirected) {
        try {
            $ms = New-Object System.IO.MemoryStream
            [Console]::OpenStandardInput().CopyTo($ms)
            $b = $ms.ToArray()
        } catch { $b = $null }
    }
    if ($null -ne $b -and $b.Length -gt 0) {
        $start = 0
        if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $start = 3 }
        return [System.Text.Encoding]::UTF8.GetString($b, $start, $b.Length - $start).TrimStart([char]0xFEFF)
    }
    try { return [Console]::In.ReadToEnd() } catch { return '' }
}

# Output: stdout/stderr leave as UTF-8 bytes on the raw handles, never through the console code page (at 950 the
# default writer emits Big5: reason text turns into mojibake and a JSON reason can break). Only when redirected (the
# real hook case); an interactive console keeps its default writer. Any failure keeps the default writer.
function Initialize-HookUtf8Output {
    try {
        if ([Console]::IsOutputRedirected) { $w = New-Object System.IO.StreamWriter([Console]::OpenStandardOutput(), (New-Object System.Text.UTF8Encoding $false)); $w.AutoFlush = $true; [Console]::SetOut($w) }
        if ([Console]::IsErrorRedirected) { $w = New-Object System.IO.StreamWriter([Console]::OpenStandardError(), (New-Object System.Text.UTF8Encoding $false)); $w.AutoFlush = $true; [Console]::SetError($w) }
    } catch { }
}
Initialize-HookUtf8Output

$Ag2bTriggerB64 = '5qC55Zug5pivfOWOn+WboOaYr3znorrlrprmmK985bey6K2J5a+mfOitieaYjuS6hnznnJ/mraPljp/lm6B8cm9vdCBjYXVzZSBpc3xyb290IGNhdXNlIHdhcw=='
$Ag2bMarkerB64 = '5LiA5omLfOWvpua4rHzlr6bot5F85o6o5risfOacqumpl+itiXzpgJDlrZfnqL986K2J5pOafOWvpumpl3zph43nj758ZXZpZGVuY2V8dmVyaWZpZWR8bWVhc3VyZWR8aHlwb3RoZXNpcw=='
$Ag2bMessageB64 = '5o+Q6YaS77yI5Y+q5o+Q6YaS77yM5rKS5pyJ5pOL5a+r5YWl77yJ77ya5L2g5Ymb5a+r6YCy6ZW35pyf5paH5Lu255qE5Zug5p6c6Zmz6L+w77yI5qC55Zug5piv77yP5Y6f5Zug5piv4oCm77yJ5YmN5b6MIDIwMCDlrZflhafmspLmnInorYnmk5rmqJnoqJjvvJvljp/lm6DpgoTmspLpqZforYnvvIzkuI3opoHlr6vmiJDkuovlr6bvvIzoq4voo5zkuIrorYnmk5rvvIjkuIDmiYvlr6bmuKzjgIHlr6bot5HovLjlh7rjgIHpgJDlrZfnqL/miJYgY29tbWl077yJ5oiW5qiZ44CQ5o6o5ris44CR44CC'

$Ag2bWindow = 200                 # chars on each side of the trigger word
$Ag2bMaxChars = 1000000           # larger texts are skipped silently (fail-open)
$Ag2bMaxMatches = 200             # trigger matches examined per write
$Ag2bRegexTimeout = [TimeSpan]::FromSeconds(5)

function Ag2bDecode([string]$b64) {
    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
}

function Ag2bToAsciiJson($obj) {
    $j = $obj | ConvertTo-Json -Depth 6 -Compress
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $j.ToCharArray()) {
        if ([int]$ch -gt 126) { [void]$sb.Append([char]92).Append('u').Append(([int]$ch).ToString('x4')) }
        else { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}

# a) long-lived document? (path separators normalised, case-insensitive)
function Ag2bIsLongTermDoc([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return $false }
    $p = $path.Replace('\', '/')
    $ci = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    if ([regex]::IsMatch($p, '(^|/)\.governance/pending-decisions\.md$', $ci)) { return $true }
    if ([regex]::IsMatch($p, '/memory/[^/]+\.md$', $ci)) { return $true }
    if ([regex]::IsMatch($p, '/research-decisions/[^/]+\.md$', $ci)) { return $true }
    if ([regex]::IsMatch($p, '(^|/)(CLAUDE|AGENTS)\.md$', $ci)) { return $true }
    if ([regex]::IsMatch($p, '/\.governance/handoff/projects/[^/]+\.md$', $ci)) { return $true }
    return $false
}

# collect only the newly written text from tool_input (Write: content, Edit: new_string, MultiEdit: edits[].new_string)
function Ag2bGetNewTexts($toolInput) {
    $list = New-Object System.Collections.Generic.List[string]
    if ($null -eq $toolInput) { return , $list }
    foreach ($name in @('content', 'new_string')) {
        $v = $toolInput.$name
        if ($v -is [string] -and $v.Length -gt 0) { [void]$list.Add($v) }
    }
    $edits = $toolInput.edits
    if ($null -ne $edits -and $edits -isnot [string]) {
        foreach ($e in @($edits)) {
            if ($null -eq $e) { continue }
            $v = $e.new_string
            if ($v -is [string] -and $v.Length -gt 0) { [void]$list.Add($v) }
        }
    }
    return , $list
}

try {
    $raw = Read-StdinUtf8
    if (-not $raw) { exit 0 }
    $data = $raw | ConvertFrom-Json
    if ($null -eq $data) { exit 0 }

    $toolName = "$($data.tool_name)"
    if ($toolName -and $toolName -notmatch '^(Edit|Write|MultiEdit)$') { exit 0 }

    $file = $data.tool_input.file_path
    if (-not $file) { $file = $data.tool_input.path }
    if ($file -isnot [string]) { exit 0 }
    if (-not (Ag2bIsLongTermDoc $file)) { exit 0 }

    $texts = Ag2bGetNewTexts $data.tool_input
    if ($texts.Count -eq 0) { exit 0 }

    $opts = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    $trigWords = (Ag2bDecode $Ag2bTriggerB64).Split('|') | Where-Object { $_ }
    $markWords = (Ag2bDecode $Ag2bMarkerB64).Split('|') | Where-Object { $_ }
    $trigRx = New-Object System.Text.RegularExpressions.Regex((($trigWords | ForEach-Object { [regex]::Escape($_) }) -join '|'), $opts, $Ag2bRegexTimeout)
    $markRx = New-Object System.Text.RegularExpressions.Regex((($markWords | ForEach-Object { [regex]::Escape($_) }) -join '|'), $opts, $Ag2bRegexTimeout)
    # commit-hash shape: 7..40 hex chars, at least one digit and one a-f letter, not embedded in a longer word
    $hashRx = New-Object System.Text.RegularExpressions.Regex('(?<![0-9A-Za-z])(?=[0-9a-f]*[0-9])(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}(?![0-9A-Za-z])', [System.Text.RegularExpressions.RegexOptions]::None, $Ag2bRegexTimeout)
    $negChar = [char]0x4E0D   # the character meaning "not": a trigger right after it is a negation

    $flagged = $false
    foreach ($text in $texts) {
        if ($text.Length -gt $Ag2bMaxChars) { continue }
        $m = $trigRx.Match($text)
        $n = 0
        while ($m.Success -and $n -lt $Ag2bMaxMatches -and -not $flagged) {
            $n++
            $negated = ($m.Index -gt 0 -and $text[$m.Index - 1] -eq $negChar)
            if (-not $negated) {
                $ws = [Math]::Max(0, $m.Index - $Ag2bWindow)
                $we = [Math]::Min($text.Length, $m.Index + $m.Length + $Ag2bWindow)
                $win = $text.Substring($ws, $we - $ws)
                if (-not $markRx.IsMatch($win) -and -not $hashRx.IsMatch($win)) { $flagged = $true }
            }
            $m = $m.NextMatch()
        }
        if ($flagged) { break }
    }
    if (-not $flagged) { exit 0 }

    $o = [ordered]@{ hookSpecificOutput = [ordered]@{ hookEventName = 'PostToolUse'; additionalContext = (Ag2bDecode $Ag2bMessageB64) } }
    [Console]::Out.WriteLine((Ag2bToAsciiJson $o))
    exit 0
} catch {
    exit 0
}
