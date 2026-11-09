#!/usr/bin/env pwsh
# ============================================================
# session-start.ps1 — SessionStart hook
#
# 對抗「判斷力自舉悖論」：升級階梯、待裁決、四習慣本來全靠模型「自己記得援引」，
# 弱模型不知道自己不知道就不會觸發。本 hook 在每個 session 開場，把最關鍵的
# 提醒與當前狀態**主動推進 context**，不等模型自覺。
#
# stdout 會被當作 additionalContext 注入 session 開頭。永遠 exit 0，絕不阻擋。
# ============================================================
$ErrorActionPreference = 'SilentlyContinue'

$projectDir = $env:CLAUDE_PROJECT_DIR
if (-not $projectDir) { $projectDir = (Get-Location).Path }

# 找治理根（本專案的 .governance，或工作區的）
$govRoot = $null
$dir = $projectDir
while ($dir) {
    if (Test-Path (Join-Path $dir '.governance')) { $govRoot = $dir; break }
    $parent = Split-Path -Parent $dir
    if ($parent -eq $dir) { break }
    $dir = $parent
}

# 並行分支漂移偵測的基準點（P0-2，2026-09-19）：開場把目前分支記到
# ~/.claude/session-state/<cwd hash>.json，之後任何會動樹的 git 指令都會拿它比對。
# 放 $HOME 不放 repo——寫進 repo 會製造髒工作樹，而那正是要偵測的東西之一。
# 全程 fail-open：記不成就算了，guard 那端會走 StateAvailable=$false 的放行路徑。
# ⚠️ dot-source 的 Join-Path 與目標檔名必須寫在**同一行**（見下方實例）：
# lib-shipset.ps1 的 Get-UnparsedDotSources 逐行檢查 `^\s*\.\s+\S`，抽不出檔名就
# 判定「依賴推導會漏算」並讓 sync-governance fail-closed（2026-09-19 實際被擋過，
# 寫成 `. $coreForState` → 散佈中止、0 檔落地）。這是刻意的 fail-closed，別繞過它。
$branchBaseline = ''
try {
    if (Test-Path (Join-Path $PSScriptRoot 'guard-core.ps1')) {
        . (Join-Path $PSScriptRoot 'guard-core.ps1')
        if (Get-Command Write-SessionBranchState -ErrorAction SilentlyContinue) {
            $branchBaseline = "$(Write-SessionBranchState -Cwd $projectDir)"
        }
    }
}
catch { }

# ── P1-6 規則載入金絲雀：留下「這個 session 有讀到規則」的證據 ─────────
# 【為什麼】2026-07-24→09-14 有七週，Codex 與 Antigravity 從未載入 code/AGENTS.md
# （它們的 repo 根是最近的 .git，子專案裡讀不到工作區層），**沒有任何人知道**。
# 修法 09-14 落地，但接線是一次性驗證——工具會自動更新、config 會被覆蓋、
# 新建的 repo 一定沒有 .codex-root。這個 marker 就是那個持續驗證。
#
# ⚠️ **這幾行的寫法是實測出來的，別「整理」它**（2026-09-20，五種形式逐一實測）：
# lib-shipset.ps1 的 Get-DotSourceTargets 只要看到「引號字串裡含路徑分隔符 ＋ .ps1」
# 就會把該檔拉進全域 ship-set，**連用 & 呼叫都會中招**；而改成單一變數的 dot-source
# 又會被 Get-UnparsedDotSources 判成「抽不出目標」。兩者都是 fail-closed：
# sync 的閉包斷言會擋下整批散佈（零檔案落地），doctor 全域段會多兩個 ERROR。
# 唯一兩邊都乾淨的形式＝**分兩段 Join-Path 組路徑 ＋ 用 & 呼叫**（下面這四行）。
$markScript = ''
try {
    if ($govRoot) {
        $govBin = Join-Path $govRoot '.governance'
        $govBin = Join-Path $govBin 'bin'
        $markScript = Join-Path $govBin 'mark-loaded.ps1'
        if (Test-Path $markScript) { & $markScript -Tool claude | Out-Null } else { $markScript = '' }
    }
}
catch { $markScript = '' }

# Output: stdout/stderr leave as UTF-8 bytes on the raw handles, never through the console code page (at 950 the
# default writer emits Big5: reason text turns into mojibake and a JSON reason can break). Only when redirected (the
# real hook case); an interactive console keeps its default writer. Any failure keeps the default writer.
# (Write-Output / Write-Host / Out-Host all follow [Console]::SetOut, measured under chcp 950 in pwsh 7 and 5.1.)
function Initialize-HookUtf8Output {
    try {
        if ([Console]::IsOutputRedirected) { $w = New-Object System.IO.StreamWriter([Console]::OpenStandardOutput(), (New-Object System.Text.UTF8Encoding $false)); $w.AutoFlush = $true; [Console]::SetOut($w) }
        if ([Console]::IsErrorRedirected) { $w = New-Object System.IO.StreamWriter([Console]::OpenStandardError(), (New-Object System.Text.UTF8Encoding $false)); $w.AutoFlush = $true; [Console]::SetError($w) }
    } catch { }
}
Initialize-HookUtf8Output

Write-Output '=== 治理提醒（SessionStart 自動注入）==='
# 分支基準的**活體正控**（2026-09-20，Fable delta §5 #3）：並行漂移偵測的 pass 路徑
# 完全靜音——hook 若沒生效、或狀態檔寫不出來，保護會**靜默消失且沒有任何訊號**。
# 這一行讓「今天這個 session 到底有沒有保護」從「要去查才知道」變成開場就看得到。
if ($branchBaseline) {
    Write-Output "分支基準已記：$branchBaseline（別的 session 在同一棵樹上切分支時，你下一條 git 指令會被提醒）"
} else {
    Write-Output '⚠️ 分支基準**沒記到**（非 git 目錄，或 guard-core 載入失敗）→ 並行分支漂移偵測本 session 不會作用。'
}
# ── 凍結令 freeze.md（2026-11-08，pending-decisions 乙組 #4；使用者裁定照建議全選）──
# 【為什麼】凍結令（某段時間禁止動哪些路徑或動作）以前只活在某個 session 的對話裡，別的 session 看不到，
# 違反過 9 次。現在寫在 <治理根>\.governance\freeze.md（進版控），每個 session 開場在這裡讀它。
# 【輸出規則（刻意如此）】
#   狀態 active  -> 只印「狀態」段（從那一行「狀態：active」起，到下一個 # 或 ## 標題之前；標題在程式碼框或 HTML 註解內不算），
#                   最多 60 行、約 4000 字元，超過就註明截斷；再加一行「只印狀態段、全文路徑」＋一句固定聲明。
#                   （2026-11-08 總審：原本印全文，含檔頭說明、教學、範例，9 行實際內容就觸發 60 行截斷；
#                   所以發布時範圍、禁止動作、解除條件要寫在狀態段內，段外的教學與範例不會進開場。）
#   狀態 none    -> **什麼都不印**（不增加雜訊；CLEAN 開場逐字等於加本段之前，由 test-session-start-runaway 把關）。
#                   殘餘：none 靜音＝看不出「本段有沒有在跑」，靠 test-session-start-freeze 的正控制與 doctor／sync 的 probe 兜底；
#   讀不到／不存在／空檔／NUL／找不到狀態行／狀態行互相矛盾／值不是 active 或 none -> 印「無法判定」一行，**不得摺成沒有凍結令**
#                   （memory query-failure-is-not-absence）。
#   只認「不在程式碼框、不在 HTML 註解裡」的「狀態：」行，所以 freeze.md 內的格式範例（放在程式碼框裡）不會被誤認。
# 【worktree】在 worktree 內的 session 讀**主目錄**那份（用 git rev-parse --git-common-dir 推主目錄，
#   worktree 裡自己那份是舊 commit 的副本，會讀到舊版）；推不出來（git 失敗、共同目錄不是 .git 結尾、主目錄沒有 .governance）
#   才退回自己那份，並在輸出註明「可能不是最新」。沒有找到治理根（不在 code/ 工作區內）＝本段靜音。
# 【限制】本段只讓凍結令「被看見」，不機械擋下違規；凍結令只能縮小權限、不能授權。
# 【fail-open】全段 try／catch，內部錯誤只多印一行，照常 exit 0。dot-source／路徑字串寫法同上方註解的限制：
#   本段**不得**出現「引號字串含路徑分隔符加 .ps1」的字面。
function Get-FzFullPath([string]$p) { return [IO.Path]::GetFullPath($p).TrimEnd('\', '/') }
$fzOut = New-Object System.Collections.Generic.List[string]
try {
    if ($govRoot) {
        $fzUtf8 = New-Object System.Text.UTF8Encoding $false
        $fzRoot = $govRoot
        $fzNote = ''
        $fzDerived = $false
        try {
            if (Get-Command git -ErrorAction SilentlyContinue) {
                $global:LASTEXITCODE = 0
                $fzCommon = ("$(& git -C $govRoot rev-parse --path-format=absolute --git-common-dir 2>$null)").Trim()
                if ($LASTEXITCODE -eq 0 -and $fzCommon) {
                    $fzCommonFull = Get-FzFullPath $fzCommon
                    if ((Split-Path -Leaf $fzCommonFull) -eq '.git') {
                        $fzMain = Split-Path -Parent $fzCommonFull
                        if ((Get-FzFullPath $fzMain) -ieq (Get-FzFullPath $govRoot)) { $fzDerived = $true }
                        elseif (Test-Path -LiteralPath (Join-Path $fzMain '.governance') -PathType Container) {
                            $fzRoot = $fzMain
                            $fzDerived = $true
                            $fzNote = '；本 session 在 worktree 內，讀的是主目錄那份'
                        }
                    }
                }
            }
        } catch { }
        if (-not $fzDerived) { $fzNote = '；推不出主目錄（git 失敗或不是標準 worktree 結構），讀的是這個目錄自己那份，可能不是最新' }

        $fzFile = Join-Path (Join-Path $fzRoot '.governance') 'freeze.md'
        $fzProblem = ''
        $fzText = ''
        $fzByteCut = $false
        if (-not (Test-Path -LiteralPath $fzFile -PathType Leaf)) { $fzProblem = 'freeze.md 不存在' }
        else {
            $fzFs = $null
            try {
                $fzFs = New-Object System.IO.FileStream($fzFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                $fzCap = 65536
                $fzBuf = New-Object byte[] $fzCap
                $fzGot = 0
                while ($fzGot -lt $fzCap) {
                    $fzK = $fzFs.Read($fzBuf, $fzGot, $fzCap - $fzGot)
                    if ($fzK -le 0) { break }
                    $fzGot += $fzK
                }
                $fzByteCut = ($fzFs.Length -gt $fzGot)
                if ([Array]::IndexOf($fzBuf, [byte]0, 0, $fzGot) -ge 0) { $fzProblem = 'freeze.md 含 NUL 位元組（不是文字檔）' }
                else { $fzText = $fzUtf8.GetString($fzBuf, 0, $fzGot).TrimStart([char]0xFEFF) }
            }
            catch { $fzProblem = 'freeze.md 讀不到（被鎖住或沒有權限）' }
            finally { if ($fzFs) { $fzFs.Dispose() } }
            if (-not $fzProblem -and [string]::IsNullOrWhiteSpace($fzText)) { $fzProblem = 'freeze.md 是空的' }
        }

        $fzLines = @()
        $fzStat = ''
        if (-not $fzProblem) {
            $fzLines = @($fzText -split "`r?`n")
            $fzVals = New-Object System.Collections.Generic.List[string]
            $fzFence = $false
            $fzCom = $false
            $fzStatIdx = -1
            for ($fzI = 0; $fzI -lt $fzLines.Count; $fzI++) {
                $fzLn = $fzLines[$fzI]
                if ($fzCom) { if ($fzLn.Contains('-->')) { $fzCom = $false }; continue }
                if ($fzLn -match '^\s*(```|~~~)') { $fzFence = -not $fzFence; continue }
                if ($fzFence) { continue }
                if ($fzLn.TrimStart().StartsWith('<!--')) { if (-not $fzLn.Contains('-->')) { $fzCom = $true }; continue }
                if ($fzLn -match '^\s*(?:[-*]\s+)?(?:狀態|status)\s*[:：]\s*(\S+)\s*$') {
                    if ($fzStatIdx -lt 0) { $fzStatIdx = $fzI }
                    $fzVals.Add($Matches[1].ToLowerInvariant())
                }
            }
            $fzDistinct = @($fzVals | Select-Object -Unique)
            if ($fzDistinct.Count -eq 0) { $fzProblem = '找不到「狀態：active」或「狀態：none」那一行' }
            elseif ($fzDistinct.Count -gt 1) { $fzProblem = '有多個互相矛盾的狀態行' }
            elseif (@('active', 'none') -notcontains $fzDistinct[0]) { $fzProblem = '狀態值不認得（只認 active 或 none）' }
            else { $fzStat = $fzDistinct[0] }
        }

        if ($fzProblem) {
            $fzOut.Add("【凍結令】無法判定（$fzProblem；$fzFile$fzNote）——不等於沒有凍結令。動根 repo 的治理檔、建或刪 worktree、推送或合併之前，先在對話裡問使用者有沒有生效的凍結令。")
        }
        elseif ($fzStat -eq 'active') {
            $fzMaxLines = 60
            $fzMaxChars = 4000
            $fzBody = New-Object System.Collections.Generic.List[string]
            $fzChars = 0
            $fzCut = $false
            # 只取「狀態」段：從第一個真正的狀態行起，到下一個 # 或 ## 標題前（程式碼框、HTML 註解內的標題不算）。
            $fzSec = New-Object System.Collections.Generic.List[string]
            $fzSecFence = $false
            $fzSecCom = $false
            for ($fzJ = $fzStatIdx; $fzJ -lt $fzLines.Count; $fzJ++) {
                $fzSl = $fzLines[$fzJ]
                if ($fzJ -gt $fzStatIdx) {
                    if ($fzSecCom) { $fzSec.Add($fzSl); if ($fzSl.Contains('-->')) { $fzSecCom = $false }; continue }
                    if ($fzSl -match '^\s*(```|~~~)') { $fzSec.Add($fzSl); $fzSecFence = -not $fzSecFence; continue }
                    if ($fzSecFence) { $fzSec.Add($fzSl); continue }
                    if ($fzSl.TrimStart().StartsWith('<!--')) { $fzSec.Add($fzSl); if (-not $fzSl.Contains('-->')) { $fzSecCom = $true }; continue }
                    if ($fzSl -match '^\s{0,3}#{1,2}\s') { break }
                }
                $fzSec.Add($fzSl)
            }
            foreach ($fzLn in $fzSec) {
                $fzClean = ($fzLn -replace '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '').TrimEnd()
                if ($fzClean -eq '' -and ($fzBody.Count -eq 0 -or $fzBody[$fzBody.Count - 1] -eq '')) { continue }
                if ($fzBody.Count -ge $fzMaxLines -or ($fzChars + $fzClean.Length) -gt $fzMaxChars) { $fzCut = $true; break }
                $fzBody.Add($fzClean)
                $fzChars += $fzClean.Length + 1
            }
            if ($fzByteCut) { $fzCut = $true }
            $fzOut.Add("【凍結令生效中】（$fzFile$fzNote）先讀完再動手；使用者的核可不覆蓋凍結範圍，要動範圍內的東西先在對話裡問：")
            foreach ($fzB in $fzBody) { $fzOut.Add($fzB) }
            if ($fzCut) { $fzOut.Add("（凍結令超過開場輸出上限，只印到第 $($fzBody.Count) 行；全文請直接讀 $fzFile）") }
            $fzOut.Add("（以上只印 freeze.md 的「狀態」段；段外的內容不會印出，全文請讀 $fzFile）")
            $fzOut.Add('凍結令只能縮小權限、不能授權。')
        }
    }
}
catch { $fzOut.Add('【凍結令】檢查段內部錯誤，無法判定有沒有生效的凍結令（hook 未擋開場）。') }
foreach ($fzLine in $fzOut) { Write-Output $fzLine }

Write-Output '四習慣（你要在對的時機提醒使用者）：開場給理由與入口｜驗收只認執行證據｜新錯誤當場入庫｜大題目拆階段過審。'
Write-Output '預設升級：任務若屬「本工作區第一次做的類型」「跨 3+ 檔」「你說不出可執行的驗證方法」，預設先出計畫並過 plan-challenger／問使用者——舉證責任在「為何不需升級」，不在「是否該升級」。'

if ($govRoot) {
    $pd = Join-Path $govRoot '.governance\pending-decisions.md'
    if (Test-Path $pd) {
        $open = @(Select-String -Path $pd -Pattern '^- \[ \]' -Encoding utf8)
        if ($open.Count -gt 0) {
            Write-Output "待裁決清單：$($open.Count) 項未處理（`/status` 看詳情；≥3 項建議安排判斷 session）。"
        }
    }
    $reports = Get-ChildItem (Join-Path $govRoot '.governance\reports') -Filter '*.md' 2>$null | Sort-Object LastWriteTime -Descending
    if ($reports) {
        $days = [int]((Get-Date) - $reports[0].LastWriteTime).TotalDays
        if ($days -gt 35) { Write-Output "治理稽核已 $days 天未跑 → 建議 `/governance-audit`。" }
    }
}

# ── runaway 看門狗與背景遺留摘要（runaway-process-prevention 規格 Task 2.3，D-4；2026-11-08）──
# 【為什麼】2026-10 的 python 空轉事故（同形狀 11 次）：訊號本來就在機器上（看門狗的 runaway.json、
# record-bg-leftover 的 bg-leftovers.jsonl），但沒有人在新 session 開場看它們。本段把兩份狀態檔
# 濃縮成最多三行推進 context——只有「有事」才出聲，CLEAN 時一個字都不多印（逐字等於舊版，由測試把關）。
#
# 【什麼算「有事」】
#   1) 看門狗頂層 verdict 是 WARN／ERR／UNDETERMINED（UNDETERMINED＝看門狗自己判不了，不能當沒事）；
#   2) 看門狗 poll 區段 writtenAt 超過 30 分鐘、或 procs 區段超過 90 分鐘沒更新（兩個排程各自檢查，
#      因為頂層 writtenAt 任一區段寫入都會更新，會蓋掉另一個排程停掉的事實；最後一次 CLEAN 不代表現在 CLEAN）；
#   3) runaway.json 不存在／讀不到／JSON 壞／欄位缺或時間異常、poll／procs 區段缺或不是物件或時間異常
#      ——一律印「無法判定」，不得摺成沒事
#      （memory query-failure-is-not-absence）；
#   4) 有「未處理遺留」＝bg-leftovers.jsonl 裡 ts 晚於已讀指標、且在最近 14 天內的紀錄。
#
# 【未處理遺留的定義與已讀指標】本摘要是 record-bg-leftover 紀錄目前唯一確定的消費者
# （2026-11-08 使用者裁定：即時注入通道暫緩到 M6 實測）。每筆遺留只提醒一次：印出之後把
# 「已提醒到哪一筆的 ts」寫進同目錄的 bg-leftovers-seen.json（小檔，只存一個時間戳）；
# 下次只計 ts 比它新的。指標檔不在或壞掉＝當作從沒提醒過（只受 14 天窗口限制，不會倒出全部歷史）。
# **絕不刪除、改寫 bg-leftovers.jsonl 本身**。
# 殘餘：①SessionStart 也會在 resume／compact 觸發，被提醒過的遺留之後不再提醒，靠使用者與
# 全域規則（子代理回報 backgroundLeftovers、轉述前做終態查詢）兜底；②同一 session 內新留下的遺留
# 不會即時出現，要等下一次 SessionStart；③14 天以前的紀錄不再提醒，要查請直接讀 jsonl。
#
# 【不印命令列】只印判定字、整數、截短的 ID（限英數底線連字號）與時間；reasons／command 一律不印。
# 【狀態目錄】預設 $HOME\.claude\session-state；測試用 BG_LEFTOVER_STATE_DIR 覆寫，與 record-bg-leftover
# 同規則：只在系統暫存目錄之下才採用，路徑上不得有 reparse point（settings 的 env 是隱性不可信輸入）。
# 殘餘（與 record-bg-leftover 相同）：暫存目錄以 GetTempPath() 為準，而 TEMP 本身也能被同一份 settings env 覆寫，
# 同時設 TEMP 與 BG_LEFTOVER_STATE_DIR 即可把讀取與已讀指標寫入導到任意目錄；影響只限「本段讀到什麼、指標寫到哪」。
# 【fail-open】任何一步失敗都不擋開場：讀檔失敗印「無法判定」，連本段自己出錯也只多印一行，照常 exit 0。
function Test-RaNoReparseUnderTemp([string]$full, [string]$tmpRoot) {
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
function Get-RaStateDir {
    $default = Join-Path $HOME '.claude\session-state'
    if (-not $env:BG_LEFTOVER_STATE_DIR) { return $default }
    try {
        $c = [IO.Path]::GetFullPath($env:BG_LEFTOVER_STATE_DIR)
        $tmp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($c.StartsWith($tmp, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-RaNoReparseUnderTemp $c $tmp)) { return $c }
    } catch { }
    return $default
}
# ConvertFrom-Json 在 pwsh 7 會把 ISO 字串轉成 DateTime，在 5.1 保持字串：兩種都收；解析不了回 $null
function ConvertTo-RaTime($v) {
    try {
        if ($null -eq $v) { return $null }
        if ($v -is [datetime]) { return (New-Object System.DateTimeOffset -ArgumentList $v.ToUniversalTime()) }
        if ($v -is [string]) {
            $dto = [DateTimeOffset]::MinValue
            if ([DateTimeOffset]::TryParse($v, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$dto)) { return $dto }
        }
    } catch { }
    return $null
}
# 陣列取個數、數字取值、其他（含 $null）算 0；上限截斷避免異常大值洗版
function Get-RaCount($v) {
    try {
        if ($null -eq $v) { return 0 }
        if ($v -is [array]) { return [Math]::Min(@($v).Count, 99999) }
        if ($v -is [int] -or $v -is [long] -or $v -is [double]) { return [int][Math]::Max(0, [Math]::Min([double]$v, 99999)) }
    } catch { }
    return 0
}
function Get-RaVerdict($v) {
    $s = "$v"
    if (@('CLEAN', 'WARN', 'ERR', 'UNDETERMINED') -contains $s) { return $s }
    return '?'
}
function Format-RaTime([DateTimeOffset]$t) { return $t.UtcDateTime.ToString('yyyy-MM-dd HH:mm') + 'Z' }

$raOut = New-Object System.Collections.Generic.List[string]
$raPointerFile = ''
$raPointerValue = ''
try {
    $raDir = Get-RaStateDir
    $raNow = [DateTimeOffset]::UtcNow
    $raUtf8 = New-Object System.Text.UTF8Encoding $false
    $raWdLine = ''
    $raLfLine = ''

    # (a) 看門狗
    $wdFile = Join-Path $raDir 'runaway.json'
    $wd = $null
    $wdProblem = ''
    if (-not (Test-Path -LiteralPath $wdFile -PathType Leaf)) { $wdProblem = 'runaway.json 不存在' }
    else {
        try { $wd = ([IO.File]::ReadAllText($wdFile, $raUtf8)) | ConvertFrom-Json -ErrorAction Stop }
        catch { $wd = $null; $wdProblem = 'runaway.json 讀不到或 JSON 壞掉' }
        if (-not $wdProblem -and ($null -eq $wd -or $wd -isnot [System.Management.Automation.PSCustomObject])) { $wd = $null; $wdProblem = 'runaway.json 內容空白或不是物件' }
    }
    $wdVerdict = ''
    $wdAge = 0
    $staleParts = New-Object System.Collections.Generic.List[string]
    if ($wd) {
        $wdVerdict = Get-RaVerdict $wd.verdict
        if ($wdVerdict -eq '?') { $wdProblem = 'verdict 欄位缺或不認得' }
        $wdT = ConvertTo-RaTime $wd.writtenAt
        if (-not $wdProblem) {
            if ($null -eq $wdT) { $wdProblem = 'writtenAt 欄位缺或無法解析' }
            else {
                $wdAge = [int][Math]::Floor(($raNow - $wdT).TotalMinutes)
                if ($wdAge -lt -5) { $wdProblem = 'writtenAt 在未來（時鐘異常）' }
            }
        }
        # 【逐區段新鮮度（Task 2.3 修正 M1）】頂層 writtenAt 在 poll 或 procs 任何一個寫入時都會被看門狗的 saveState 更新，
        # 所以頂層永遠跟著較勤快的 poll（每 5 分鐘）保持新鮮，會蓋掉 procs（每 30 分鐘）停掉的事實。
        # 因此 poll、procs 各自檢查自己的 writtenAt，門檻依各自排程：poll 30 分鐘（排程 PT5M 的 6 倍）、
        # procs 90 分鐘（排程 PT30M 的 3 倍）。區段缺少、不是物件、時間缺或異常＝無法判定，不得摺成沒事。
        # 頂層超過 30 分鐘只在兩個區段都沒被判過期時才補報（頂層晚於區段不可能由看門狗寫出，屬異常檔）。
        if (-not $wdProblem) {
            foreach ($raSpec in @(@('poll', 30), @('procs', 90))) {
                $secName = $raSpec[0]
                $secLimit = [int]$raSpec[1]
                $sec = $wd.$secName
                if ($sec -isnot [System.Management.Automation.PSCustomObject]) { $wdProblem = "$secName 區段缺或不是物件"; break }
                $secT = ConvertTo-RaTime $sec.writtenAt
                if ($null -eq $secT) { $wdProblem = "$secName 區段的 writtenAt 缺或無法解析"; break }
                $secAge = [int][Math]::Floor(($raNow - $secT).TotalMinutes)
                if ($secAge -lt -5) { $wdProblem = "$secName 區段的 writtenAt 在未來（時鐘異常）"; break }
                if ($secAge -gt $secLimit) { $staleParts.Add("$secName 區段已 $secAge 分鐘沒更新（超過 $secLimit）") }
            }
        }
        if (-not $wdProblem -and $staleParts.Count -eq 0 -and $wdAge -gt 30) { $staleParts.Add("整體已 $wdAge 分鐘沒更新（超過 30）") }
    }
    if ($wdProblem) {
        $raWdLine = "⚠️ runaway 看門狗：無法判定（$wdProblem）——不等於沒事，看門狗可能沒在跑。"
    }
    elseif ($staleParts.Count -gt 0 -or $wdVerdict -ne 'CLEAN') {
        $head = "判定 $wdVerdict"
        if ($wdVerdict -eq 'UNDETERMINED') { $head = '判定 UNDETERMINED（看門狗自己判不了，不是沒事）' }
        if ($staleParts.Count -gt 0) { $head = ($staleParts -join '；') + "（最後一次判定 $wdVerdict，看門狗可能停了，不能當作現在沒事）" }
        $detail = ''
        if ($wdVerdict -ne 'CLEAN') {
            $pv = '?'; $sv = '?'; $al = 0; $ud = 0; $sp = 0; $orp = 0
            if ($wd.poll -is [System.Management.Automation.PSCustomObject]) { $pv = Get-RaVerdict $wd.poll.verdict; $al = Get-RaCount $wd.poll.alertCount; $ud = Get-RaCount $wd.poll.undeterminedCount }
            if ($wd.procs -is [System.Management.Automation.PSCustomObject]) { $sv = Get-RaVerdict $wd.procs.verdict; $ud += (Get-RaCount $wd.procs.undeterminedCount); $sp = Get-RaCount $wd.procs.spins; $orp = Get-RaCount $wd.procs.orphans }
            $detail = "（poll=$pv procs=$sv；警示 $al、無法判定 $ud、空轉 $sp 支、孤兒 $orp 支）"
        }
        $raWdLine = "⚠️ runaway 看門狗：$head$detail"
    }

    # (b) 未處理背景遺留
    $lfFile = Join-Path $raDir 'bg-leftovers.jsonl'
    $raPointerFile = Join-Path $raDir 'bg-leftovers-seen.json'
    if (Test-Path -LiteralPath $lfFile -PathType Leaf) {
        $lines = $null
        try {
            if ((Get-Item -LiteralPath $lfFile -Force -ErrorAction Stop).Length -gt 16777216) { throw 'too-large' }
            $lines = @([IO.File]::ReadAllLines($lfFile, $raUtf8))
        } catch { $lines = $null }
        if ($null -eq $lines) {
            $raLfLine = '⚠️ bg-leftovers.jsonl 讀不到或過大（無法判定有沒有未處理的背景遺留）。'
        }
        else {
            $lower = $raNow.AddDays(-14)
            try {
                if (Test-Path -LiteralPath $raPointerFile -PathType Leaf) {
                    $pj = ([IO.File]::ReadAllText($raPointerFile, $raUtf8)) | ConvertFrom-Json -ErrorAction Stop
                    $pt = ConvertTo-RaTime $pj.seenThrough
                    if ($null -ne $pt -and $pt -gt $lower -and $pt -le $raNow.AddMinutes(5)) { $lower = $pt }
                }
            } catch { }
            $n = 0; $tc = 0; $claimed = 0; $bad = 0
            $maxT = $null
            $ids = New-Object System.Collections.Generic.List[string]
            foreach ($ln in $lines) {
                if ([string]::IsNullOrWhiteSpace($ln)) { continue }
                $row = $null
                try { $row = $ln | ConvertFrom-Json -ErrorAction Stop } catch { $row = $null }
                if ($null -eq $row -or $row -isnot [System.Management.Automation.PSCustomObject]) { $bad++; continue }
                $t = ConvertTo-RaTime $row.ts
                if ($null -eq $t -or $t -gt $raNow.AddMinutes(5)) { $bad++; continue }
                if ($t -le $lower) { continue }
                $n++
                $tasksV = $row.tasks
                if ($null -ne $tasksV) {
                    foreach ($tk in @($tasksV)) {
                        $tc++
                        if ($ids.Count -lt 3 -and $tk -is [System.Management.Automation.PSCustomObject]) {
                            $sid = ("$($tk.id)" -replace '[^A-Za-z0-9_-]', '')
                            if ($sid.Length -gt 16) { $sid = $sid.Substring(0, 16) }
                            if ($sid) { $ids.Add($sid) }
                        }
                    }
                }
                if ($row.claimedFinished -eq $true) { $claimed++ }
                if ($null -eq $maxT -or $t -gt $maxT) { $maxT = $t }
            }
            if ($n -gt 0) {
                $raLfLine = "⚠️ 有 $n 筆未處理的背景遺留紀錄（共 $tc 項背景工作，最近一筆 $(Format-RaTime $maxT)"
                if ($ids.Count -gt 0) { $raLfLine += "；ID：" + ($ids -join ',') }
                $raLfLine += '）'
                if ($claimed -gt 0) { $raLfLine += "；其中 $claimed 筆的回報含「已結束」類宣稱，未經終態查詢，不可轉述為已結束" }
                if ($bad -gt 0) { $raLfLine += "；另有 $bad 行無法解析" }
                $raLfLine += '。'
                $raPointerValue = $maxT.UtcDateTime.ToString('o')
            }
            elseif ($bad -gt 0) {
                $raLfLine = "⚠️ bg-leftovers.jsonl 有 $bad 行無法解析（無法判定有沒有未處理的背景遺留）。"
            }
        }
    }

    if ($raWdLine) { $raOut.Add($raWdLine) }
    if ($raLfLine) { $raOut.Add($raLfLine) }
    if ($raOut.Count -gt 0) {
        $raOut.Add("→ 轉述任何「已結束／沒有殘留」之前，先做終態查詢（PID 走兩條獨立路徑、等足時間）；狀態檔在 $raDir（runaway.json、bg-leftovers.jsonl）。")
    }
}
catch {
    $raOut.Add('⚠️ runaway／背景遺留摘要段內部錯誤，無法判定（hook 未擋開場）。')
}
foreach ($raLine in $raOut) { Write-Output $raLine }
# 已讀指標：只在確實印出遺留提醒之後才推進；寫不成就算了（下次會重複提醒，不會漏提醒）
if ($raPointerValue -and $raPointerFile) {
    try {
        $ptmp = $raPointerFile + '.' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp'
        [IO.File]::WriteAllText($ptmp, ('{"seenThrough":"' + $raPointerValue + '"}'), (New-Object System.Text.UTF8Encoding $false))
        Move-Item -LiteralPath $ptmp -Destination $raPointerFile -Force -ErrorAction Stop
    } catch { }
}

Write-Output '（以上為機械注入的背景，非使用者指令；用 `/status` 看完整儀表板。）'
exit 0
