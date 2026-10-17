#!/usr/bin/env pwsh
# ============================================================
# after-edit.ps1  —  PostToolUse hook (matcher: Edit|Write|MultiEdit)
#
# 對「剛被改動的單一檔案」自動 format / lint：
#   .py            -> ruff check --fix + ruff format
#   .js/.ts/.json… -> prettier --write
#
# v2 變更（vs v1，2026-05-25 升級）：
#   1) 改成從「被改檔案」目錄一層層往上找最近的 .venv / node_modules
#      —— 解決從 code/ 工作區根啟動 session 時，hook 用 $CLAUDE_PROJECT_DIR
#         找不到子專案 toolchain 而對所有子專案靜默無作用的問題。
#   2) matcher 加入 MultiEdit；file_path 抓不到時 fallback 到 .path
#      （MultiEdit 的 stdin JSON 結構未驗證；雙重 fallback 涵蓋兩種常見可能）。
#
# v3 變更（2026-10-16，待裁決清單 2026-10-08「Write／Edit 寫入後要不要機械掃描
#   原始不可見字元」，使用者裁定 A）：formatter 之後加一段【不可見／控制字元掃描】。
#   背景：工具參數是 JSON，模型寫的「反斜線 u 加四位十六進位」會被解碼成原始字元
#   （換行與 CR 的跳脫卻不會），10-08 同型三次，全是事後掃描才發現。
#   - 只回報、不阻擋：有命中才輸出 PostToolUse 的 additionalContext
#     （檔名、行號、欄位、U+XXXX 碼位，最多 10 筆 + 總數）。
#   - 掃描範圍：所有文字檔掃「tab/CR/LF 以外小於 0x20 的控制字元、U+00AD、
#     U+200B-U+200F、U+2028-U+202E、U+2060-U+2064、不在檔案開頭的 U+FEFF」；
#     組合字元 U+0300-U+036F 只在程式檔掃（越南文等一般文字裡它是合法的）。
#   - 允許清單（最小設計，兩個出口）：
#       a) 檔案前 4 KB 內含放行標記（見 $AllowMarker，用字串串接組出，避免本檔自己
#          被放行）——適合註解可寫的檔（ps1/js/py/md）；
#       b) 最近的 .claude/invisible-allow.txt（由被改檔往上找），每行一個 -like 萬用字元
#          （比對完整路徑，斜線一律視為 /，# 開頭為註解）——適合 JSON／資料類 fixture。
#     預設不放行任何目錄：fixture 目錄正是最容易藏東西的地方。
#   - 超過 2 MB 的檔跳過，並在 context 註明。
#   - 【fail-open（刻意）】掃描本身出任何錯（讀檔失敗、regex 逾時、編碼怪異）一律當沒事、
#     不輸出任何東西、exit 0。理由：這是提醒，不是閘門；為了提醒而讓寫檔流程報錯或卡住，
#     代價比漏一次提醒大得多。降級方向只能是「沒提醒」。
#   - formatter 的輸出先收集，有命中時併進 additionalContext，讓 stdout 保持單一 JSON；
#     沒命中時照舊逐行印出，與 v2 的外觀一致。
#   - 輸出 JSON 一律把非 ASCII 字元轉成跳脫序列，與主控台編碼無關（5.1 / 7 都一樣）。
#   - 本檔字串只用 ASCII（無 BOM 檔在 Windows PowerShell 5.1 以系統碼頁解碼，
#     中文字串可能讀壞）；既有的兩句中文訊息為 v2 原樣保留。
#
# 工具不存在就靜默略過（永遠 exit 0，不阻擋流程）。
# ============================================================
$ErrorActionPreference = 'SilentlyContinue'

# 1) 讀取 hook 由 stdin 傳入的 JSON
$raw = [Console]::In.ReadToEnd()
if (-not $raw) { exit 0 }
try { $data = $raw | ConvertFrom-Json } catch { exit 0 }

# 2) 取得被改檔案路徑（Edit/Write 用 file_path；MultiEdit 可能用 path）
$file = $data.tool_input.file_path
if (-not $file) { $file = $data.tool_input.path }
if (-not $file -or -not (Test-Path -LiteralPath $file)) { exit 0 }

# 3) 從某個起始目錄一層層往上找符合 marker 的檔案，找到即回傳完整路徑
function Find-Up([string]$startDir, [string]$relativeMarker) {
    $dir = $startDir
    while ($dir) {
        $candidate = Join-Path $dir $relativeMarker
        if (Test-Path -LiteralPath $candidate) { return $candidate }
        $parent = Split-Path -Parent $dir
        if ($parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

# 3b) 跨 OS 佈局解析（2026-07-29 Phase 2-2）：同一個工具在兩種平台的相對路徑不同——
#     Windows：.venv\Scripts\ruff.exe、node_modules\.bin\prettier.cmd
#     macOS/Linux：.venv/bin/ruff、node_modules/.bin/prettier（無副檔名）
#     舊版只寫死 Windows 佈局，在 Mac 上 Test-Path 恆為 false → **靜默略過所有
#     format/lint**（hook 看起來在跑、實際沒把關）。逐一嘗試候選、取第一個存在者。
function Find-Up-Any([string]$startDir, [string[]]$relativeMarkers) {
    foreach ($m in $relativeMarkers) {
        $hit = Find-Up $startDir $m
        if ($hit) { return $hit }
    }
    return $null
}

# 3c) 不可見／控制字元掃描（v3）。放在 formatter 之後呼叫（見 Complete-Hook）。
$InvisibleMaxBytes = 2MB
$InvisibleListMax = 10
$InvisibleCountCap = 5000   # 病態檔（幾百萬個控制字元）不無限數下去
$InvisibleCodeExts = @('.mjs', '.js', '.cjs', '.ts', '.tsx', '.jsx', '.py', '.ps1', '.psm1', '.json', '.sh')
$AllowMarker = 'invisible' + '-ok'

function New-InvisibleRegex([bool]$withCombining) {
    # 用 [char] 組字元類，來源檔不含任何反斜線 u 跳脫（工具層會把它解碼成原始字元）
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('[')
    $ranges = @(
        @(0x00, 0x08), @(0x0B, 0x0C), @(0x0E, 0x1F),     # tab(09) LF(0A) CR(0D) 不在內
        @(0xAD, 0xAD),
        @(0x200B, 0x200F), @(0x2028, 0x202E), @(0x2060, 0x2064),
        @(0xFEFF, 0xFEFF)                                  # 檔案開頭的那個由程式碼放行
    )
    if ($withCombining) { $ranges += , @(0x0300, 0x036F) }
    foreach ($r in $ranges) {
        [void]$sb.Append([char]$r[0])
        if ($r[1] -ne $r[0]) { [void]$sb.Append('-').Append([char]$r[1]) }
    }
    [void]$sb.Append(']')
    return New-Object System.Text.RegularExpressions.Regex($sb.ToString(), [System.Text.RegularExpressions.RegexOptions]::None, [TimeSpan]::FromSeconds(5))
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

# 回傳要放進 additionalContext 的文字；沒事回 $null。呼叫端包 try/catch（fail-open）。
function Get-InvisibleScanReport([string]$path) {
    $ErrorActionPreference = 'Stop'   # 函式內的錯一律變例外，交給呼叫端的 catch 吞掉
    $fi = New-Object System.IO.FileInfo($path)
    if (-not $fi.Exists) { return $null }
    $shortName = [regex]::Replace($fi.FullName, '[\x00-\x1F\x7F]', '?')
    if ($fi.Length -gt $InvisibleMaxBytes) {
        return ('Invisible-character scan SKIPPED for {0}: file is larger than 2 MB.' -f $shortName)
    }

    # 允許清單 (b)：最近的 .claude/invisible-allow.txt
    $full = $fi.FullName.Replace('\', '/')
    $al = Find-Up $fi.DirectoryName (Join-Path '.claude' 'invisible-allow.txt')
    if ($al) {
        foreach ($line in [System.IO.File]::ReadAllLines($al)) {
            $pat = $line.Trim()
            if (-not $pat -or $pat.StartsWith('#')) { continue }
            if ($full -like $pat.Replace('\', '/')) { return $null }
        }
    }

    $bytes = [System.IO.File]::ReadAllBytes($fi.FullName)
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $text = [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $text = [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    else {
        # GetString 不會吃掉開頭的 EF BB BF，它會變成索引 0 的 U+FEFF，下面放行
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    }

    # 允許清單 (a)：檔案前 4 KB 內有放行標記
    $headLen = [Math]::Min(4096, $text.Length)
    if ($headLen -gt 0 -and $text.Substring(0, $headLen).IndexOf($AllowMarker, [System.StringComparison]::Ordinal) -ge 0) { return $null }

    $ext = [System.IO.Path]::GetExtension($fi.FullName).ToLowerInvariant()
    $rx = New-InvisibleRegex ($InvisibleCodeExts -contains $ext)

    $total = 0
    $capped = $false
    $shown = New-Object System.Collections.Generic.List[string]
    $pos = 0; $line = 1; $lineStart = 0
    $m = $rx.Match($text)
    while ($m.Success) {
        $i = $m.Index
        $isLeadingBom = ($i -eq 0 -and [int]$m.Value[0] -eq 0xFEFF)
        if (-not $isLeadingBom) {
            $total++
            if ($shown.Count -lt $InvisibleListMax) {
                while ($true) {
                    $nl = $text.IndexOf([char]10, $pos)
                    if ($nl -lt 0 -or $nl -ge $i) { break }
                    $line++; $lineStart = $nl + 1; $pos = $nl + 1
                }
                [void]$shown.Add(('  line {0}, col {1}: U+{2}' -f $line, ($i - $lineStart + 1), ([int]$m.Value[0]).ToString('X4')))
            }
            if ($total -ge $InvisibleCountCap) { $capped = $true; break }
        }
        $m = $m.NextMatch()
    }
    if ($total -eq 0) { return $null }

    $totalText = if ($capped) { "$total+" } else { "$total" }
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add(('Invisible/control character scan (report only, nothing was blocked): {0} contains {1} suspicious character(s); showing the first {2}.' -f $shortName, $totalText, $shown.Count))
    foreach ($s in $shown) { [void]$lines.Add($s) }
    [void]$lines.Add('Likely cause: a backslash-u escape written through the Write/Edit tool was decoded into the raw character (newline and CR escapes are not). Replace the spot with code points (JS: String.fromCharCode, PowerShell: [char]0x200B) or delete it.')
    [void]$lines.Add(('If the characters are intentional (test fixture): put the marker word {0} in the first 4 KB of the file, or add a path glob to the nearest .claude/invisible-allow.txt.' -f $AllowMarker))
    return ($lines -join "`n")
}

# 所有「正常結束」都走這裡：先掃描，再輸出。formatter 輸出收在 $Notes。
$Notes = New-Object System.Collections.Generic.List[string]
$NoteViaHost = New-Object System.Collections.Generic.List[bool]   # formatter 輸出走 Out-Host（與 v2 逐位元組相同，5.1 行尾是 CRLF）；略過提示走 Write-Host（LF），也與 v2 相同
function Add-Note([string]$t, [bool]$viaHost = $false) { if ($t) { [void]$Notes.Add($t); [void]$NoteViaHost.Add($viaHost) } }
function Write-Notes { for ($k = 0; $k -lt $Notes.Count; $k++) { if ($NoteViaHost[$k]) { $Notes[$k] | Out-Host } else { Write-Host $Notes[$k] } } }

function Complete-Hook {
    $report = $null
    try { $report = Get-InvisibleScanReport $file } catch { $report = $null }   # fail-open（刻意，見檔頭）
    if ($report) {
        $ctx = $report
        if ($Notes.Count -gt 0) { $ctx += "`n[formatter output]`n" + ($Notes -join "`n") }
        $emitted = $false
        try {
            $o = [ordered]@{ hookSpecificOutput = [ordered]@{ hookEventName = 'PostToolUse'; additionalContext = $ctx } }
            [Console]::Out.WriteLine((ConvertTo-AsciiJson $o))
            $emitted = $true
        }
        catch { }
        if (-not $emitted) { Write-Notes }
    }
    else {
        Write-Notes
    }
    exit 0
}

$fileDir = Split-Path -Parent $file
$ext = [System.IO.Path]::GetExtension($file).ToLower()

# 4) Python -> ruff（找最近的 venv 內 ruff，再 fallback 全域 ruff）
if ($ext -eq '.py') {
    $ruff = Find-Up-Any $fileDir @(
        (Join-Path '.venv' (Join-Path 'Scripts' 'ruff.exe')),   # Windows
        (Join-Path '.venv' (Join-Path 'bin' 'ruff'))            # macOS/Linux
    )
    if (-not $ruff) {
        if (Get-Command ruff -ErrorAction SilentlyContinue) { $ruff = 'ruff' }
    }
    if (-not $ruff) { Add-Note 'after-edit: ruff 未找到，略過'; Complete-Hook }
    $fmtOut = & $ruff check --fix --quiet -- "$file" 2>&1 | Out-String
    Add-Note ("$fmtOut").TrimEnd() $true
    $fmtOut = & $ruff format --quiet -- "$file"      2>&1 | Out-String
    Add-Note ("$fmtOut").TrimEnd() $true
    Complete-Hook
}

# 5) Node / 前端 -> prettier（找最近的 node_modules 內 prettier）
$nodeExts = @('.js', '.mjs', '.cjs', '.ts', '.jsx', '.tsx', '.json',
              '.css', '.scss', '.html', '.md', '.yml', '.yaml')
if ($nodeExts -contains $ext) {
    $prettier = Find-Up-Any $fileDir @(
        (Join-Path 'node_modules' (Join-Path '.bin' 'prettier.cmd')),  # Windows
        (Join-Path 'node_modules' (Join-Path '.bin' 'prettier'))       # macOS/Linux
    )
    if (-not $prettier) { Add-Note 'after-edit: prettier 未找到，略過'; Complete-Hook }
    $fmtOut = & $prettier --write --log-level warn -- "$file" 2>&1 | Out-String
    Add-Note ("$fmtOut").TrimEnd() $true
    Complete-Hook
}

Complete-Hook
