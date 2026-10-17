#!/usr/bin/env pwsh
# ============================================================
# guard-monitor-loop.ps1  —  PreToolUse hook (matcher: ^Monitor$)
#
# 【為什麼存在】待裁決清單 2026-10-16「監看迴圈要自帶存活上限」（使用者裁定 A）。
# 事故（session cacba4b1 一手）：上一棒用 Monitor 跑無上限 while true 監看兩支
# workflow 的 transcript；Monitor 每 30 分鐘到期就重新 arm，而 Windows 上 Monitor 到期
# 與 TaskStop 都收不掉 bash 迴圈，10-15 16:28-19:48 累積 8 組（16 個 bash），workflow
# 早已結束，每組每 20 分推一次 STALL，凌晨同一分鐘 6 則 Telegram。
#
# 【做什麼】讀 tool_input.command；偵測「無上限迴圈形狀」且「從迴圈起點往後沒有任何
# 自我終止條件」時，輸出 PreToolUse 的 additionalContext 提醒（風險＋處方）。
#   - 形狀：while true / while : / while [ 1 ] / while (( 1 )) / while sleep N /
#     until false / for (( ; ; )) 等（大小寫、空白、多行、heredoc 內都算；整段文字掃）。
#   - 自我終止條件（B3 修正後；只有下列才算，單純提到 SECONDS / date +%s 不算）：
#       (a) 時間比較寫在迴圈條件裡：while / until 到 do 之間同時有 SECONDS（或 EPOCHSECONDS、
#           date +%s）與比較運算（-lt -gt == 等；< > 只在 (( )) 或 [[ ]] 裡算，外面的是重導向）；
#       (b) 迴圈範圍內（起點到配對的 done）位於指令位置的 exit / return，或屬於該迴圈本身的
#           break（內層迴圈自己的 break 不算外層出口）；
#       (c) 外層 timeout N / with-child 的 --timeout=N（N 不為 0）包住整個迴圈：wrapper 結尾到迴圈起點
#           之間，不得有引號外的指令分隔符（; && || | & 換行）；heredoc 起始行的換行例外；
#           迴圈位於 wrapper 的引號字串或 heredoc 本體內也算被包住。
#     迴圈內只是把 SECONDS 或時間戳印出來、或算年齡後只印訊息而沒有出口，不算有上限
#     （2026-10-15 事故的 STALL 監看迴圈就是這種形狀）。
#   - 指令若執行腳本檔（bash x.sh、sh x.sh、source x.sh、./x.sh 等）且檔案可讀、
#     小於 256 KB，連腳本內容一起檢查（補待裁決條目寫的殘餘）。外層有 timeout 包著
#     腳本時視為已有上限——同一個腳本名在指令裡每一次以候選身分出現都要被包住才算
#     （timeout 10 shellcheck x.sh && bash x.sh 要提醒）。只往下看一層，不遞迴。
#   - ws 模式沒有 command，直接放行。
#
# 【只提醒、絕不 deny 或 ask】這是提醒，不是閘門：誤擋一個合法監看的代價（打斷工作、
# 訓練人忽略 hook）大於漏一次提醒。降級方向只能是「沒提醒」。
#
# 【fail-open（刻意）】stdin 空、JSON 壞、regex 逾時、腳本讀取失敗等任何一步出錯，
# 一律靜默 exit 0。本檔壞掉的唯一後果是沒有提醒，絕不會阻擋 Monitor。
#
# 【已知殘餘（刻意不處理，寫明以免被當成已涵蓋）】
#   - 只看文字形狀：迴圈在別的語言（python -c 的 while True）、動態組出的指令
#     （eval、變數拼接）、腳本再呼叫腳本（第二層）看不到。
#   - 證據是文字比對，不是控制流分析：字串或 heredoc 資料裡位於指令位置的 exit/break/return
#     也會被算成證據；引號、heredoc 的辨識是近似解析（$'..'、巢狀指令替換、反引號內的引號
#     不處理）；wrapper 與迴圈之間若有 ( ) { } 之類的群組，只看分隔符，不追括號。
#   - 迴圈條件的時間比較只做存在性判斷（有 SECONDS/date +%s 且有比較運算），不驗證方向。
#   - 腳本路徑只處理字面路徑（可展開 ~、$HOME、環境變數、/c/ 與 /tmp 形式）。
#   - 腳本名只要在指令裡出現在沒被包住的位置就會提醒，不分是不是執行位置：
#     ls x.sh && timeout 600 bash x.sh 也會提醒（方向安全的誤報）。
#   - 指令只掃前 256 KB；超過的部分看不到。整體分析有 8 秒預算，超過就放行（fail-open），
#     所以極端長或病態的指令是否提醒依機器速度而定。
#   - (( a << b )) 的算術位移會被當成 heredoc 標記，之後的文字被當成 heredoc 本體（近似解析）。
#   - timeout -k N 0 這類寫法：-k 的數字 N 會被當成時長（旗標帶數值只認字母開頭的值），所以視為有上限。
#   - 右括號後的 exit／break／return 只要同一行後面接 ;; 就算出口，字串或 heredoc 裡的這種形狀也算。
#
# 本檔字串只用 ASCII：無 BOM 檔在 Windows PowerShell 5.1 以系統碼頁解碼，中文字串會讀壞；
# stdin 以 UTF-8 位元組自行解碼，輸出 JSON 把非 ASCII 轉成跳脫序列，與主控台編碼無關。
# ============================================================
# 'Stop'：任何例外（含 regex 逾時）都落到最外層 catch 然後放行；SilentlyContinue 會讓逾時的
# NextMatch() 被吞掉、while 迴圈原地空轉。
$ErrorActionPreference = 'Stop'

function Read-StdinUtf8 {
    $ms = New-Object System.IO.MemoryStream
    [Console]::OpenStandardInput().CopyTo($ms)
    $b = $ms.ToArray()
    $start = 0
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $start = 3 }
    return [System.Text.Encoding]::UTF8.GetString($b, $start, $b.Length - $start)
}

function ConvertTo-AsciiJson($obj) {
    $j = $obj | ConvertTo-Json -Depth 6 -Compress
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $j.ToCharArray()) {
        if ([int]$ch -gt 126) { [void]$sb.Append([char]92).Append('u').Append(([int]$ch).ToString('x4')) }
        else { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}

try {
    $raw = Read-StdinUtf8
    if (-not $raw) { exit 0 }
    $data = $raw | ConvertFrom-Json
    if ($data.tool_name -and $data.tool_name -ne 'Monitor') { exit 0 }   # 防禦性；matcher 理論上只送 Monitor
    $cmd = $data.tool_input.command
    if ($null -eq $cmd -or $cmd -isnot [string] -or -not $cmd.Trim()) { exit 0 }   # ws 模式沒有 command
    $MaxScan = 262144
    if ($cmd.Length -gt $MaxScan) { $cmd = $cmd.Substring(0, $MaxScan) }

    $to = [TimeSpan]::FromSeconds(3)
    $ci = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Multiline
    $cs = [System.Text.RegularExpressions.RegexOptions]::Multiline

    # 迴圈形狀（不分大小寫）。引號用 x22 / x27 表示，避免 PowerShell 引號跳脫。
    # 關鍵字前不得接 \w $ . - /（排除 xwhile、$while、--while、a/while 這類非關鍵字位置）。
    $lead = '(?<![\w$.\-/])'
    $q = '[\x22\x27]?'
    $loopDefs = @(
        @{ name = 'while-true'; pat = $lead + 'while\s+(?:true|:|/(?:usr/)?bin/true)(?![\w-])' },
        @{ name = 'while-literal-test'; pat = $lead + 'while\s+(?:test\s+' + $q + '[A-Za-z0-9_]+' + $q + '|\[\[?\s*' + $q + '[A-Za-z0-9_]+' + $q + '\s*\]\]?)(?![\w-])' },
        @{ name = 'while-tautology'; pat = $lead + 'while\s+\[\[?\s*([\x22\x27]?)([A-Za-z0-9_]+)\1\s*(?:=|==|-eq)\s*\1\2\1\s*\]\]?' },
        @{ name = 'while-arith-1'; pat = $lead + 'while\s*\(\(\s*1\s*\)\)' },
        @{ name = 'while-not-false'; pat = $lead + 'while\s+!\s*(?:false|/(?:usr/)?bin/false)(?![\w-])' },
        @{ name = 'while-sleep'; pat = $lead + 'while\s+sleep(?![\w-])' },
        @{ name = 'until-false'; pat = $lead + 'until\s+(?:false|/(?:usr/)?bin/false)(?![\w-])' },
        @{ name = 'until-arith-0'; pat = $lead + 'until\s*\(\(\s*0\s*\)\)' },
        @{ name = 'for-empty-cond'; pat = $lead + 'for\s*\(\([^;()]*;\s*;[^()]*\)\)' }
    )
    $loopRx = @()
    foreach ($d in $loopDefs) { $loopRx += , @($d.name, (New-Object System.Text.RegularExpressions.Regex($d.pat, $ci, $to))) }

    # 自我終止證據（分大小寫：SECONDS 是 bash 的大寫變數；exit/break/return 只認小寫）
    #   body 證據（exit / return / 屬於該迴圈的 break）：必須落在「該迴圈起點 ~ 配對的 done」之間
    #     才算（迴圈前面的 exit 1、迴圈後面的 exit 0 都不算：無上限迴圈永遠走不到 done 後面）。
    #   條件時間比較：SECONDS / EPOCHSECONDS / date +%s 單獨出現不算證據（可能只是被印出來）；
    #     只有寫在迴圈條件（起點到 do 之間）並且帶比較運算時才算。迴圈內用它算年齡的，
    #     真正的出口要靠 exit / break / return 來證明。
    #   wrapper 證據（timeout 指令、with-child 的 --timeout）：出現在迴圈起點「之前」，且 wrapper 結尾
    #     到迴圈之間沒有引號外的指令分隔符，才算外層包住；迴圈裡面的 timeout 5 curl 只是單次呼叫
    #     逾時，不是迴圈壽命；迴圈前面另一個指令的 timeout 10 git fetch 也不是。
    $timePats = @(
        '\b(?:SECONDS|EPOCHSECONDS|EPOCHREALTIME)\b',
        'date\s+[\x22\x27]?\+%s'
    )
    #   case 分支 q) exit 0;; 與 a) break;; 的出口在 ) 後面（B4 驗證 X46／X51）：右括號後的出口只在
    #   同一行後面接著 ;; 時才算（V1 驗證：無條件認 ) 會讓 echo "$(date) exit"、(cd x && ls) exit 被當成出口而漏報）。
    $anyPats = @(
        '(?:^|[;&|({]|\b(?:then|do|else|elif))[ \t]*(?:exit|return)(?![\w-])',
        '\)[ \t]*(?:exit|return)(?![\w-])(?=[^\n;]*;;)'
    )
    $breakPat = '(?:^|[;&|({]|\b(?:then|do|else|elif))[ \t]*break(?![\w-])|\)[ \t]*break(?![\w-])(?=[^\n;]*;;)'
    #   timeout 的時長必須含非零數字：GNU timeout 的 0 代表不限時（B4 驗證 X02）；with-child --timeout=0 同理不算。
    $wrapPats = @(
        '(?<![\w$.\-/])timeout\s+(?:-{1,2}[A-Za-z][\w=-]*\s+(?:[A-Za-z]\w*\s+)?)*(?=[\d.]*[1-9])[\d.]+[smhd]?\b',
        '--timeout[= ]\s*0*[1-9]'
    )
    $timeRx = @(); foreach ($p in $timePats) { $timeRx += New-Object System.Text.RegularExpressions.Regex($p, $cs, $to) }
    # 比較運算：-lt 等、== !=、兩側是空白的跳脫 \< \>（grep '\<SECONDS\>' 的字邊界不算，V1b 驗證 VB19）；裸 < > 只在 (( )) 或 [[ ]] 裡才算比較（外面的是重導向，
    # while sleep 5 && echo $SECONDS > /tmp/s; do 的 > 不是比較，B4 驗證 X04）。(( )) 內允許一層巢狀括號
    # （(( $(date +%s) < end )) 是常見寫法），[[ ]] 可以跨行（V1 驗證 M12／M04／M02／M05）。
    $cmpRx = New-Object System.Text.RegularExpressions.Regex('(?<![\w-])-(?:lt|le|gt|ge|eq|ne)(?![\w-])|[!=]=|(?<=\s)\\[<>](?=\s)|\(\((?:[^()]|\([^()]*\))*[<>](?:[^()]|\([^()]*\))*\)\)|\[\[(?:(?!\]\])[\s\S])*[<>](?:(?!\]\])[\s\S])*\]\]', $cs, $to)
    $doRx = New-Object System.Text.RegularExpressions.Regex('(?:^|(?<=[;&|(){\s]))do(?![\w-])', $ci, $to)
    $anyRx = @(); foreach ($p in $anyPats) { $anyRx += New-Object System.Text.RegularExpressions.Regex($p, $cs, $to) }
    $breakRx = New-Object System.Text.RegularExpressions.Regex($breakPat, $cs, $to)
    $wrapRx = @(); foreach ($p in $wrapPats) { $wrapRx += New-Object System.Text.RegularExpressions.Regex($p, $cs, $to) }
    # 分隔符與引號的掃描 token：跳脫、單引號串、雙引號串、heredoc 標記（<<WORD，不含 <<<）、換行、| || && & ;
    $tokRx = New-Object System.Text.RegularExpressions.Regex('\\[\s\S]|\x27[^\x27]*(?:\x27|\z)|\x22(?:\\[\s\S]|[^\x22\\])*(?:\x22|\z)|(?<!<)<<(?!<)-?[ \t]*([\x22\x27]?)([A-Za-z_][A-Za-z0-9_]*)\1|\r?\n|\|\|?|&&|&|;', $cs, $to)
    $openRx = New-Object System.Text.RegularExpressions.Regex('(?:^|[;&|(){]|\b(?:do|then|else))[ \t]*(?:while|until|for|select)(?![\w-])', $cs, $to)
    $doneRx = New-Object System.Text.RegularExpressions.Regex('(?:^|[;&|(){]|\n)[ \t]*done(?![\w-])', $cs, $to)
    $commentRx = New-Object System.Text.RegularExpressions.Regex('(?:^|(?<=[ \t]))#.*$', $cs, $to)

    function Remove-Comments([string]$t) { return $commentRx.Replace($t, '') }

    # 找「從 start 開始的迴圈」配對的 done。回傳 @{ end = done 的位置（找不到＝字串長度）; events = 範圍內的開/關事件（依位置排序）}
    function Get-LoopInfo([string]$text, [int]$start) {
        $events = New-Object System.Collections.Generic.List[object]
        $s1 = [Math]::Min($start + 1, $text.Length)
        $om = $openRx.Match($text, $s1)
        while ($om.Success) { [void]$events.Add([pscustomobject]@{ i = $om.Index; d = 1 }); $om = $om.NextMatch() }
        $dm = $doneRx.Match($text, $s1)
        while ($dm.Success) { [void]$events.Add([pscustomobject]@{ i = $dm.Index; d = -1 }); $dm = $dm.NextMatch() }
        $sorted = @($events | Sort-Object i)   # 元素是物件而非陣列：單一事件時才不會被管線攤平
        $depth = 1   # 起點的那個迴圈本身
        $end = $text.Length
        $inRange = New-Object System.Collections.Generic.List[object]
        foreach ($ev in $sorted) {
            $depth += $ev.d
            if ($depth -le 0) { $end = [int]$ev.i; break }
            [void]$inRange.Add($ev)
        }
        return [pscustomobject]@{ end = $end; events = $inRange.ToArray() }   # @($list) 在 PowerShell 會踩 Argument types do not match
    }

    $budget = [System.Diagnostics.Stopwatch]::StartNew()

    # 一個「層級」= text 的 [lo, hi) 區間。掃出該層的引號串 / heredoc 本體（spans）與引號外的指令
    # 分隔符位置（seps）。層級依 lo:hi 快取。spans 依起點排序、互不重疊。
    $levelCache = @{}
    function Get-Level([string]$text, [int]$lo, [int]$hi) {
        $ck = [string]$lo + ':' + [string]$hi
        if ($levelCache.ContainsKey($ck)) { return $levelCache[$ck] }
        $spanList = New-Object System.Collections.Generic.List[object]
        $sepList = New-Object System.Collections.Generic.List[int]
        $pos = $lo
        $hdDelim = $null
        while ($pos -lt $hi) {
            $tm = $tokRx.Match($text, $pos)
            if (-not $tm.Success -or $tm.Index -ge $hi) { break }
            if ($budget.ElapsedMilliseconds -gt 8000) { throw 'time budget exceeded' }
            $tv = $tm.Value
            $tEnd = $tm.Index + $tm.Length
            $c0 = [int]$tv[0]
            if ($c0 -eq 92) { $pos = $tEnd; continue }   # 反斜線跳脫（含反斜線接換行的折行）
            if ($c0 -eq 34 -or $c0 -eq 39) {
                $closed = ($tv.Length -ge 2 -and [int]$tv[$tv.Length - 1] -eq $c0 -and $tEnd -le $hi)
                $se = [Math]::Min($tEnd, $hi)
                $ile = $se; if ($closed) { $ile = $se - 1 }
                [void]$spanList.Add([pscustomobject]@{ s = $tm.Index; e = $se; ls = ($tm.Index + 1); le = [Math]::Max($tm.Index + 1, $ile) })
                $pos = $se; continue
            }
            if ($c0 -eq 60) { $hdDelim = $tm.Groups[2].Value; $pos = $tEnd; continue }   # heredoc 標記：本體從下一個換行之後開始
            if ($c0 -eq 10 -or $c0 -eq 13) {
                if ($null -ne $hdDelim) {
                    # heredoc 起始行的換行不是分隔符；本體到單獨一行的結尾標記為止（整段當成一個 span）
                    $restText = ''
                    if ($tEnd -lt $hi) { $restText = $text.Substring($tEnd, $hi - $tEnd) }
                    $dm2 = [System.Text.RegularExpressions.Regex]::Match($restText, '(?m)^[ \t]*' + [System.Text.RegularExpressions.Regex]::Escape($hdDelim) + '[ \t]*\r?$', $cs, $to)
                    $bEnd = $hi
                    if ($dm2.Success) { $bEnd = $tEnd + $dm2.Index + $dm2.Length }
                    [void]$spanList.Add([pscustomobject]@{ s = $tEnd; e = $bEnd; ls = $tEnd; le = $bEnd })
                    $hdDelim = $null
                    $pos = $bEnd; continue
                }
                [void]$sepList.Add($tm.Index); $pos = $tEnd; continue
            }
            if ($c0 -eq 38 -and $tv.Length -eq 1) {
                # 單獨的 &：2>&1 / >&2 / &> 是重導向，不是背景符號
                $pv = 0; if ($tm.Index -gt $lo) { $pv = [int]$text[$tm.Index - 1] }
                $nx = 0; if ($tEnd -lt $hi) { $nx = [int]$text[$tEnd] }
                if ($pv -eq 62 -or $pv -eq 60 -or $nx -eq 62) { $pos = $tEnd; continue }
            }
            [void]$sepList.Add($tm.Index)
            $pos = $tEnd
        }
        $spanArr = $spanList.ToArray()
        $startList = New-Object System.Collections.Generic.List[int]
        foreach ($spItem in $spanArr) { [void]$startList.Add([int]$spItem.s) }
        $lvObj = [pscustomobject]@{ spans = $spanArr; starts = $startList.ToArray(); seps = $sepList.ToArray() }
        $levelCache[$ck] = $lvObj
        return $lvObj
    }

    # 在已排序的 int 陣列裡找最後一個 <= x 的索引（找不到回 -1）
    function Find-LastLe([int[]]$arr, [int]$x) {
        $lowI = 0; $highI = $arr.Length - 1; $res = -1
        while ($lowI -le $highI) {
            $midI = ($lowI + $highI) -shr 1
            if ($arr[$midI] -le $x) { $res = $midI; $lowI = $midI + 1 } else { $highI = $midI - 1 }
        }
        return $res
    }

    function Find-SpanAt($lvObj, [int]$idx) {
        $k = Find-LastLe $lvObj.starts $idx
        if ($k -ge 0 -and $idx -lt $lvObj.spans[$k].e) { return $lvObj.spans[$k] }
        return $null
    }

    # wrapper（[wIdx, wEnd) 是 wrapper 命中的範圍）是否包住位置 tgtIdx 的指令？
    #   同層：wEnd 到「目標所在位置」之間沒有引號外的分隔符。
    #   目標在某個引號串 / heredoc 本體內：以該串的起點為目標位置（串內的分隔符屬於被包住的子命令，
    #   例如 timeout 1700 bash -c 'echo a; while true; ...' 仍然整個被 timeout 包住）。
    #   wrapper 與目標在同一個串內：下降到該串的內容再判斷。wrapper 在不含目標的串內：只是字串，不算。
    function Test-WrapperCovers([string]$text, [int]$wIdx, [int]$wEnd, [int]$tgtIdx) {
        $lo = 0; $hi = $text.Length
        for ($lvl = 0; $lvl -lt 8; $lvl++) {
            $lvObj = Get-Level $text $lo $hi
            $wSpan = Find-SpanAt $lvObj $wIdx
            $tSpan = Find-SpanAt $lvObj $tgtIdx
            if ($null -ne $wSpan -and $null -ne $tSpan -and [object]::ReferenceEquals($wSpan, $tSpan)) { $lo = $wSpan.ls; $hi = $wSpan.le; continue }
            if ($null -ne $wSpan) { return $false }
            $effective = $tgtIdx
            if ($null -ne $tSpan) { $effective = $tSpan.s }
            if ($effective -lt $wEnd) { return $false }
            $sepArr = $lvObj.seps
            $ki = Find-LastLe $sepArr ($wEnd - 1)   # 最後一個 < wEnd 的分隔符；下一個才是候選
            if ($ki + 1 -lt $sepArr.Length -and $sepArr[$ki + 1] -lt $effective) { return $false }
            return $true
        }
        return $false
    }

    # 文字裡全部 wrapper 命中（依位置排序，每個樣式最多 200 個）
    function Get-WrapMatches([string]$text) {
        $wl = New-Object System.Collections.Generic.List[object]
        foreach ($we in $wrapRx) {
            $wm = $we.Match($text); $wn = 0
            while ($wm.Success -and $wn -lt 200) { [void]$wl.Add([pscustomobject]@{ i = $wm.Index; e = ($wm.Index + $wm.Length) }); $wn++; $wm = $wm.NextMatch() }
        }
        $arr = @($wl | Sort-Object i)
        return , $arr
    }

    function Test-AnyWrapperCovers([string]$text, $wraps, [int]$tgtIdx) {
        foreach ($w in $wraps) {
            if ($w.i -ge $tgtIdx) { break }
            if ($budget.ElapsedMilliseconds -gt 8000) { throw 'time budget exceeded' }
            if (Test-WrapperCovers $text $w.i $w.e $tgtIdx) { return $true }
        }
        return $false
    }

    # 迴圈條件（起點到 do 之間）是否帶時間比較
    function Test-HeaderTimeBound([string]$text, [int]$loopIdx) {
        $hm = $doRx.Match($text, $loopIdx)
        $hEnd = $text.Length
        if ($hm.Success) { $hEnd = $hm.Index }
        $header = $text.Substring($loopIdx, $hEnd - $loopIdx)
        if (-not $cmpRx.IsMatch($header)) { return $false }
        foreach ($tr in $timeRx) { if ($tr.IsMatch($header)) { return $true } }
        return $false
    }

    # 對一段文字找「無上限迴圈且沒有自我終止證據」；回傳形狀名稱清單（去重）
    #   exit／return 在迴圈範圍內任何深度都算；break 只算屬於這個迴圈本身的（巢狀的內層迴圈
    #   自己的 break 只跳出內層，不算外層的出口）；時間比較只認迴圈條件；wrapper 要真的包住迴圈。
    function Find-Unbounded([string]$text) {
        $levelCache.Clear()   # 層級快取以 lo:hi 為鍵，換一段文字就必須清掉
        $found = New-Object System.Collections.Generic.List[string]
        $anyIdx = New-Object System.Collections.Generic.List[int]
        foreach ($e in $anyRx) { $mm = $e.Match($text); while ($mm.Success) { [void]$anyIdx.Add($mm.Index); $mm = $mm.NextMatch() } }
        $brkIdx = New-Object System.Collections.Generic.List[int]
        $mm = $breakRx.Match($text); while ($mm.Success) { [void]$brkIdx.Add($mm.Index); $mm = $mm.NextMatch() }
        $wraps = Get-WrapMatches $text
        foreach ($pair in $loopRx) {
            $m = $pair[1].Match($text)
            $iter = 0
            while ($m.Success -and -not $found.Contains($pair[0]) -and $iter -lt 200) {
                $iter++
                if ($budget.ElapsedMilliseconds -gt 8000) { throw 'time budget exceeded' }   # 病態輸入：放棄分析、放行
                $covered = (Test-HeaderTimeBound $text $m.Index)
                if (-not $covered) { $covered = (Test-AnyWrapperCovers $text $wraps $m.Index) }
                if (-not $covered) {
                    $info = Get-LoopInfo $text $m.Index
                    foreach ($bi in $anyIdx) { if ($bi -ge $m.Index -and $bi -le $info.end) { $covered = $true; break } }
                    if (-not $covered) {
                        foreach ($bi in $brkIdx) {
                            if ($bi -lt $m.Index -or $bi -gt $info.end) { continue }
                            $depth = 1
                            foreach ($ev in $info.events) { if ($ev.i -lt $bi) { $depth += $ev.d } else { break } }
                            if ($depth -le 1) { $covered = $true; break }
                        }
                    }
                }
                if (-not $covered) { [void]$found.Add($pair[0]) }
                $m = $m.NextMatch()
            }
        }
        return , $found
    }

    # 從指令文字找腳本檔候選（只往下一層）。回傳每一次「以候選身分出現」的 token 與它在指令裡的位置
    # （t = 去掉外層引號的 token，i = 去引號後第一個字元的位置）：同一個腳本名出現兩次時，wrapper 判斷
    # 要逐次做（只看第一次會讓 timeout 10 shellcheck x.sh && bash x.sh 漏報，B4 驗證抓到）。
    # 不同腳本名最多 8 個；token 全部掃完（不設 token 上限：上限之後的出現位置會看不到，V1 驗證 SB03），
    # 只靠 8 秒預算兜底（超過＝放行，與整體 fail-open 一致）。
    function Get-ScriptCandidates([string]$c) {
        $out = New-Object System.Collections.Generic.List[object]
        $names = New-Object System.Collections.Generic.List[string]
        $interp = '^(?:.*[/\\])?(?:bash|sh|zsh|dash|ksh|source|\.)$'
        $prev = $false
        $nTok = 0
        $tm = [regex]::Match($c, '[^\s;&|()<>`]+')
        while ($tm.Success) {
            $nTok++
            if (($nTok -band 255) -eq 0 -and $budget.ElapsedMilliseconds -gt 8000) { throw 'time budget exceeded' }
            $t0 = $tm.Value
            $t = $t0.Trim([char]34, [char]39)
            if ($t) {
                $ti = $tm.Index + ($t0.Length - $t0.TrimStart([char]34, [char]39).Length)
                $isFlag = $t.StartsWith('-')
                $isCand = $false
                if ($prev -and -not $isFlag) { $isCand = $true; $prev = $false }
                elseif ($t -match '(?i)\.sh$') { $isCand = $true }
                if ($t -match $interp) { $prev = $true }
                elseif ($isFlag -and $t -match '^-[A-Za-z]*c[A-Za-z]*$') { $prev = $false }   # bash -c '...' 是內嵌腳本
                elseif (-not $isFlag) { $prev = $false }
                if ($isCand) {
                    if (-not $names.Contains($t) -and $names.Count -lt 8) { [void]$names.Add($t) }
                    if ($names.Contains($t)) { [void]$out.Add([pscustomobject]@{ t = $t; i = $ti }) }
                }
            }
            $tm = $tm.NextMatch()
        }
        return , $out
    }

    function Resolve-ScriptPath([string]$tok, [string]$cwd) {
        $p = $tok
        $homeDir = [Environment]::GetFolderPath('UserProfile')
        if ($p -eq '~' -or $p.StartsWith('~/') -or $p.StartsWith('~\')) { $p = $homeDir + $p.Substring(1) }
        $p = [regex]::Replace($p, '\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?', {
                param($mm)
                $v = [Environment]::GetEnvironmentVariable($mm.Groups[1].Value)
                if ($null -eq $v -or $v -eq '') { $script:unresolved = $true; return '' }
                return $v
            })
        if ($script:unresolved) { return $null }
        if ($p -match '[*?{}$`\[\]]') { return $null }
        $isWin = ([System.IO.Path]::DirectorySeparatorChar -eq [char]92)
        if ($isWin) {
            $mm2 = [regex]::Match($p, '^/([A-Za-z])(?:/(.*))?$')
            if ($mm2.Success) { $p = $mm2.Groups[1].Value.ToUpper() + ':\' + ($mm2.Groups[2].Value -replace '/', '\') }
            elseif ($p -match '^/tmp(?:/|$)') { $p = (Join-Path ([System.IO.Path]::GetTempPath()) ($p.Substring(4).TrimStart('/'))) }
            elseif ($p.StartsWith('/')) { return $null }
        }
        if (-not [System.IO.Path]::IsPathRooted($p)) {
            if (-not $cwd) { $cwd = (Get-Location).Path }
            $p = Join-Path $cwd $p
        }
        return [System.IO.Path]::GetFullPath($p)
    }

    $findings = New-Object System.Collections.Generic.List[string]

    $cmdText = Remove-Comments $cmd
    $inline = Find-Unbounded $cmdText
    foreach ($s in $inline) { [void]$findings.Add(('inline command: ' + $s)) }

    $cands = Get-ScriptCandidates $cmdText
    $doneToks = New-Object System.Collections.Generic.List[string]
    foreach ($cd in $cands) {
        $tok = $cd.t
        if ($doneToks.Contains($tok)) { continue }
        [void]$doneToks.Add($tok)
        $path = $null
        try { $script:unresolved = $false; $path = Resolve-ScriptPath $tok ([string]$data.cwd) } catch { $path = $null }
        if (-not $path) { continue }
        if (-not [System.IO.File]::Exists($path)) { continue }
        $fi = New-Object System.IO.FileInfo($path)
        if ($fi.Length -gt 262144) { continue }
        # 外層包了 timeout 視為已有上限：wrapper 要出現在腳本名稱之前，且中間沒有引號外的指令分隔符
        # （timeout 10 git fetch; bash x.sh 的 timeout 只管 git fetch，不管腳本）。
        # 這個腳本名「每一次」以候選身分出現都要被包住才算：timeout 10 shellcheck x.sh && bash x.sh
        # 的第一次被包住、第二次（真正執行的那次）沒有。代價：ls x.sh && timeout 600 bash x.sh 也會提醒
        # （方向安全的已知誤報，測試 K04 登記）。
        #   只比對同名的出現（-cne）：別的腳本沒被包住，不影響這一支是否被包住。
        $wrapped = $true
        $levelCache.Clear()
        $wl = Get-WrapMatches $cmdText
        foreach ($oc in $cands) {
            if ($oc.t -cne $tok) { continue }
            if ($oc.i -le 0 -or -not (Test-AnyWrapperCovers $cmdText $wl $oc.i)) { $wrapped = $false; break }
        }
        if ($wrapped) { continue }
        $body = Remove-Comments ([System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($path)))
        foreach ($s in (Find-Unbounded $body)) {
            $shown = [regex]::Replace($path, '[\x00-\x1F\x7F]', '?')
            [void]$findings.Add(('script file ' + $shown + ': ' + $s))
        }
    }

    if ($findings.Count -eq 0) { exit 0 }

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('Monitor loop reminder (report only, nothing was blocked): this Monitor command contains an unbounded loop with no self-terminating condition after it.')
    foreach ($f in $findings) { [void]$lines.Add('  - ' + $f) }
    [void]$lines.Add('Risk: on Windows neither Monitor expiry nor TaskStop kills the bash loop. Each re-arm starts another copy, so loops pile up after the watched job is long gone (2026-10-15: 8 groups, 16 bash loops, repeated STALL pushes, 6 Telegram messages in one minute).')
    [void]$lines.Add('Fix: make the loop carry its own lifetime cap, for example while [ $SECONDS -lt 1680 ]; do ...; done, or (( SECONDS > 1680 )) && break inside the loop; exit when the watched PID or job ends (kill -0 $pid || break); wrap long runs in timeout N. Do not rely on re-arming to keep a watcher alive, and check for old watchers before re-arming.')
    $out = [ordered]@{ hookSpecificOutput = [ordered]@{ hookEventName = 'PreToolUse'; additionalContext = ($lines -join "`n") } }
    [Console]::Out.WriteLine((ConvertTo-AsciiJson $out))
    exit 0
}
catch {
    exit 0   # fail-open（刻意，見檔頭）
}
