#!/usr/bin/env pwsh
# ============================================================
# detect-language-drift.ps1  —  Stop hook（與 verify-before-done／detect-unread-claim 併掛，互不影響）
#
# 2026-10-10：「回覆語言漂移」偵測。
#
# 【要治什麼】使用者要求所有溝通一律繁體中文，規則已寫在全域 CLAUDE.md、AGENTS.md、
# memory communication_language——**規則層已到頂**，仍復發 5 次（09-29×2、10-08、10-10×2）：
#   - 長鏈工具呼叫後中途短句先變英文，最後整份報告跟著變英文；
#   - 剛讀完英文文件／系統訊息／中英夾雜的計畫，輸出語言被輸入語言帶走。
# 兩種形狀都是「當下沒檢索到規則」，再寫一條文字規則沒有邊際效益 → 改機械檢查。
#
# 【檢查兩個範圍】
#   A. 本回合最後一則訊息（last_assistant_message）：英文單字 >= 最少字數（預設 40）且
#      中文字數 < 英文單字數 × 比例（預設 1.0）→ 擋。
#   B. 本回合**所有**給使用者看的文字段落（含工具呼叫之間的進度短句；2026-10-10 第二版加入，
#      第一版上線當天就被使用者抓到中途短句全是英文）：從 transcript_path 讀檔尾，往回收集
#      主 session（非 subagent）的助理文字段落，直到碰到上一則使用者訊息或通知為止。
#      每段英文單字 >= 段落最少字數（預設 8）且中文字數 < 英文單字數 × 比例 → 擋。
#   兩者都先去掉不算敘述的部分：``` 與 ~~~ 程式碼區塊、`行內程式碼`、> 引用區塊、網址、
#   Markdown 連結目標、Windows／Unix 路徑——這些本來就是英文或逐字引用的原文。
#
# 【fail-safe：不確定一律放行】解析失敗、拿不到訊息或 transcript、讀檔逾時 → 只做能做的部分，
#   其餘放行。這支是品質提醒，不是安全閘門；寧可漏抓，不可讓每一回合都卡住。
#   stop_hook_active 為真（本輪已被某個 Stop hook 擋過一次）→ 放行，避免無限迴圈。
#   B 的時間預算（預設 3 秒）與讀檔上限（檔尾 4 MB）超過就停止收集，只判斷已收集到的段落。
#
# 【誠實邊界——本檔抓不到什麼】（不得從註解移除）
#   1. 擋下時英文那幾段**已經顯示給使用者**：效果是「立刻補一份繁中版」，不是事前攔截。
#   2. 少於段落最少字數（預設 8 個英文單字）的英文句單段不判；但完全沒有中文、3 字以上的短句
#      會累計，合計 >= 20 個英文單字或 >= 3 段就擋（攻擊驗證腿 T09b 後加入）。
#   3. 本回合中途若插入使用者的新訊息或背景通知，那之前的段落不在 B 的範圍內。
#      通知刻意當邊界：通知會開啟新的一輪，若不切斷，上一輪已擋過、已補中文的英文會被重複指控。
#   3b. 最後一則若含一定比例中文（中文字 >= 英文單字 × 0.3）且英文不到 40 字，不判——
#      帶檔名與指令的中文短訊息不能被誤擋（攻擊驗證腿 F01）。
#   3c. 超過 1MB 的單行不解析；超過 20 萬字元的文字只量前 20 萬字元（效能，攻擊驗證腿 P03／P04）。
#   3d. 只數英文單字：日文假名、簡體中文的漂移不在射程內。
#   4. transcript 是非同步寫入，最後一兩段可能還沒落地——最後一則由 A 補上。
#   5. 整段英文若全部寫成引用區塊（> 開頭）會被當成引用而漏抓。
#   6. 使用者明確要求英文時會誤擋一次：設 LANG_DRIFT_DISABLE=1，或在回覆說明一句後繼續
#      （stop_hook_active 讓下一輪放行）。
#
# 環境變數（測試與調整用）：LANG_DRIFT_DISABLE、LANG_DRIFT_MIN_WORDS、LANG_DRIFT_RATIO、
#   LANG_DRIFT_BLOCK_MIN_WORDS、LANG_DRIFT_CUM_WORDS、LANG_DRIFT_SCAN_SEC、LANG_DRIFT_TAIL_BYTES
# ============================================================
$ErrorActionPreference = 'Stop'

function Get-Narrative([string]$s) {
    $t = $s
    $t = [regex]::Replace($t, '(?s)```.*?(```|$)', ' ')
    $t = [regex]::Replace($t, '(?s)~~~.*?(~~~|$)', ' ')
    $t = [regex]::Replace($t, '`[^`]*`', ' ')
    # 引用區塊（> 開頭的行）是逐字引用的原文（英文條款、官方文件），不是敘述語言。
    # 2026-10-10 回放 258 則真實回覆時唯一的誤報就是這個形狀（中文回覆引用一大段英文條款）。
    $t = [regex]::Replace($t, '(?m)^[ \t]*>.*$', ' ')
    $t = [regex]::Replace($t, '\]\([^)]*\)', '] ')
    $t = [regex]::Replace($t, '(?i)\b(https?|file|ftp)://\S+', ' ')
    $t = [regex]::Replace($t, '(?i)\b[a-z]:[\\/][^\s，。、；：）)」』]*', ' ')
    $t = [regex]::Replace($t, '(?<![A-Za-z0-9])(~|\.{1,2})?/[A-Za-z0-9_.~-]+(/[A-Za-z0-9_.~-]+)+', ' ')
    # 沒加反引號的相對路徑（src/hook/parse.mjs）與帶副檔名的檔名（detect-language-drift.ps1）
    # ——2026-10-10 攻擊驗證腿 F01：中文短訊息只提兩個檔名就被當成英文。
    $t = [regex]::Replace($t, '(?<![A-Za-z0-9/])[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+', ' ')
    $t = [regex]::Replace($t, '(?i)(?<![A-Za-z0-9])[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*\.(ps1|psm1|mjs|cjs|js|ts|tsx|jsx|json|jsonc|jsonl|md|py|sh|sql|ya?ml|toml|txt|html|css|csv|log|ini|env|lock|xml)(?![A-Za-z0-9])', ' ')
    return $t
}
$script:MaxMeasureChars = 200000
function Measure-Lang([string]$s) {
    # 超大文字先截斷再跑正規表示式（攻擊腿 P03：5MB 單一訊息 3–10 秒）
    if ($s.Length -gt $script:MaxMeasureChars) { $s = $s.Substring(0, $script:MaxMeasureChars) }
    $t = Get-Narrative $s
    $en = [regex]::Matches($t, '(?<![A-Za-z])[A-Za-z]{2,}(?![A-Za-z])').Count
    $zh = [regex]::Matches($t, '[\p{IsCJKUnifiedIdeographs}\p{IsCJKUnifiedIdeographsExtensionA}]').Count
    return @{ en = $en; zh = $zh }
}
function Read-EnvInt([string]$name, [int]$default) {
    $v = [Environment]::GetEnvironmentVariable($name)
    if ($v -match '^[0-9]{1,8}$') { return [int]$v }
    return $default
}

# 收集本回合主 session 的助理文字段落（由新到舊），碰到上一則使用者訊息／通知就停。
# 「使用者訊息」＝type user、非 isMeta、內容是字串或含 tool_result 以外的區塊。
function Get-TurnTexts([string]$path, [int]$tailBytes, [double]$budgetSec) {
    $texts = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $texts }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $start = [Math]::Max(0, $fs.Length - $tailBytes)
        $null = $fs.Seek($start, [IO.SeekOrigin]::Begin)
        $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
        $chunk = $sr.ReadToEnd()
    } finally { $fs.Dispose() }
    $lines = $chunk -split "`n"
    $first = if ($start -gt 0) { 1 } else { 0 }   # 從檔案中間開始讀時，第一行可能不完整
    for ($i = $lines.Count - 1; $i -ge $first; $i--) {
        if ($sw.Elapsed.TotalSeconds -gt $budgetSec) { break }
        $line = $lines[$i]
        if ($line.Length -lt 2) { continue }
        # 超過 1MB 的單行（巨大工具輸出）不解析：解析成本不受時間預算管（攻擊腿 P04c／P04k）。
        # 工具結果行本來就不是邊界，略過不影響判斷；極端情況下漏掉的只是一行。
        if ($line.Length -gt 1000000) { continue }
        if ($line -notmatch '"type"\s*:\s*"(user|assistant)"') { continue }
        try { $o = $line | ConvertFrom-Json -Depth 64 } catch { continue }
        if ($o.isSidechain -eq $true) { continue }
        $content = $o.message.content
        if ($o.type -ne 'user' -and $o.type -ne 'assistant') { continue }   # 攻擊腿 T13：其他 type 夾帶子字串
        if ($o.type -eq 'user') {
            if ($o.isMeta -eq $true) { continue }
            if ($content -is [string]) { break }
            $blocks = @($content)
            $onlyResults = $true
            foreach ($b in $blocks) { if ("$($b.type)" -ne 'tool_result') { $onlyResults = $false; break } }
            if ($blocks.Count -gt 0 -and -not $onlyResults) { break }
            continue
        }
        # 系統合成的訊息（API 錯誤、額度用盡）不是模型寫的敘述（攻擊腿 T14）
        if ($o.isApiErrorMessage -eq $true -or "$($o.message.model)" -eq '<synthetic>') { continue }
        if ($content -is [string]) { $texts.Add($content); continue }   # 攻擊腿 T01：content 是字串
        foreach ($b in @($content)) {
            if ("$($b.type)" -eq 'text' -and $b.text -is [string]) { $texts.Add($b.text) }
        }
    }
    return $texts
}

try {
    if ($env:LANG_DRIFT_DISABLE -eq '1') { exit 0 }

    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { exit 0 }
    if ($raw.Length -gt 0 -and [int]$raw[0] -eq 0xFEFF) { $raw = $raw.Substring(1) }   # 攻擊腿 S01：stdin 帶 BOM
    $data = $raw | ConvertFrom-Json

    if ($data.stop_hook_active -eq $true) { exit 0 }

    $minWords = Read-EnvInt 'LANG_DRIFT_MIN_WORDS' 40
    $blockMin = Read-EnvInt 'LANG_DRIFT_BLOCK_MIN_WORDS' 8
    $tailBytes = Read-EnvInt 'LANG_DRIFT_TAIL_BYTES' 4194304
    $scanSec = Read-EnvInt 'LANG_DRIFT_SCAN_SEC' 3
    $ratio = 1.0
    if ($env:LANG_DRIFT_RATIO -match '^[0-9]{1,2}([.][0-9]{1,3})?$') { $ratio = [double]$env:LANG_DRIFT_RATIO }

    $findings = New-Object System.Collections.Generic.List[string]

    # A) 最後一則訊息：長的用整則門檻；短的（不到整則門檻）也要過段落門檻——
    #    否則「最後一則是一句短英文」會兩邊都漏（回放本 session 時發現：B 為了不重複判斷而跳過最後一則）。
    $msg = "$($data.last_assistant_message)"
    if (-not [string]::IsNullOrWhiteSpace($msg)) {
        $m = Measure-Lang $msg
        # 短的最後一則只在「幾乎沒有中文」時才用段落門檻；含中文的仍走整則門檻
        # （攻擊腿 F01：「已修改 X 並通過 Y。」這類中文短訊息帶識別字曾被誤擋）。
        $limit = if ($m.en -ge $minWords) { $minWords } elseif ($m.zh -lt ($m.en * 0.3)) { $blockMin } else { [int]::MaxValue }
        if ($m.en -ge $limit -and $m.zh -lt ($m.en * $ratio)) {
            $findings.Add("最後一則回覆（英文單字 $($m.en) 個、中文字 $($m.zh) 個）")
        }
    }

    # B) 本回合所有文字段落（含中途短句）
    $cumMin = Read-EnvInt 'LANG_DRIFT_CUM_WORDS' 20
    $turn = @()
    try { $turn = @(Get-TurnTexts "$($data.transcript_path)" $tailBytes $scanSec) } catch { $turn = @() }
    $flagged = 0
    $pureEnWords = 0; $pureEnBlocks = 0; $firstPure = $null
    foreach ($t in $turn) {
        if ($msg -and $t.Trim() -eq $msg.Trim()) { continue }   # 最後一則已由 A 判斷
        $m = Measure-Lang $t
        if ($m.en -ge $blockMin -and $m.zh -lt ($m.en * $ratio)) {
            $flagged++
            if ($flagged -le 3) {
                $snip = ($t -replace '\s+', ' ').Trim()
                if ($snip.Length -gt 70) { $snip = $snip.Substring(0, 70) + '…' }
                $findings.Add("中途短句：「$snip」")
            }
        } elseif ($m.zh -eq 0 -and $m.en -ge 3) {
            # 每段都不到段落門檻、但完全沒有中文的英文短句：累計（攻擊腿 T09b：12 句 5–7 字全放行）
            $pureEnWords += $m.en; $pureEnBlocks++
            if (-not $firstPure) { $firstPure = ($t -replace '\s+', ' ').Trim() }
        }
    }
    if ($flagged -gt 3) { $findings.Add("（另有 $($flagged - 3) 段中途短句也是英文）") }
    if ($pureEnWords -ge $cumMin -or $pureEnBlocks -ge 3) {
        $snip = if ($firstPure.Length -gt 70) { $firstPure.Substring(0, 70) + '…' } else { $firstPure }
        $findings.Add("另有 $pureEnBlocks 段很短的純英文中途句（合計英文單字 $pureEnWords 個），例如「$snip」")
    }

    if ($findings.Count -eq 0) { exit 0 }

    # 命中 → exit 2，stderr 回饋給模型（官方：Stop 的 exit 2 讓模型繼續，stderr 成為回饋）
    $lines = @('[language-drift] 本回合有給使用者看的文字是英文：')
    foreach ($f in $findings) { $lines += "  - $f" }
    $lines += @(
        '',
        '使用者要求所有溝通一律使用繁體中文（全域 CLAUDE.md「溝通語言」、memory communication_language，已復發多次）。',
        '請補一則繁體中文說明再結束：',
        '  - 若是最後一則回覆：完整改寫成繁中，開頭一句說明「上一則誤用英文，以下是繁中版」；',
        '  - 若是中途短句：用中文簡述那幾句講了什麼（重要資訊不可只留在英文裡）；',
        '  - 程式碼、指令、檔名、網址、識別字維持原文；英文介面名稱保留原文並在括號附中文。',
        '',
        '（若使用者在本 session 明確要求用英文，說明一句即可結束——下一輪不會再擋。）'
    )
    [Console]::Error.WriteLine(($lines -join "`n"))
    exit 2
} catch {
    exit 0
}
