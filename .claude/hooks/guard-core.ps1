#!/usr/bin/env pwsh
# ============================================================
# guard-core.ps1 — 危險指令守門「純判定核心」
#
# 從 guard-bash.ps1 抽出的純判定邏輯。**實際共用者只有兩家**：
#   - Claude Code（guard-bash.ps1 → 本檔）
#   - Antigravity（.agents/antigravity-guard.ps1 shim → 本檔）
# ⚠️ **Codex 不共用**（2026-09-20 更正）：Codex 的執行期守門是 NO-GO
#   （`.governance/decisions/2026-07-26-phase4-codex-guard-nogo.md`），
#   它只有 pre-commit 機密掃描與散文規則。舊註解寫「Antigravity／Codex）共用」
#   是已被推翻的主張，且該句**回聲進了引證稽核的正控組**，讓子字串比對
#   自我確認、把已知錯誤判成 PASS（見 `.governance/reports/2026-09-19-citation-audit.md` §4）。
#   守門覆蓋的真相源是 `.governance/reports/coverage-matrix.md`（doctor 產生），不是本註解。
# **純函式、無副作用**：
#   - 不讀 stdin
#   - 不設 exit code
#   - 不輸出 hookSpecificOutput JSON
#   - 不寫 gov-log／不做 ask-flood 偵測
# 這些 I/O／可觀測性責任留在各 adapter shim（Claude 側見 guard-bash.ps1）。
#
# 對外唯一入口：
#   Get-GuardVerdict -Command <string>
#     -> @{ decision = 'deny' | 'ask' | 'pass'; why = <string> }
#
# 注意：'allow' 只存在於 Get-DeleteClassification 內部（安全刪除目標，
# 例如 node_modules），**不是**終結值——安全刪除仍要繼續往下掃描同一段
# 指令是否還有其他 DENY/ASK 樣式（例如「安全刪除 && 強推」不能因為前段
# 安全就整串放行）。
#
# Task 2（2026-07-25）：從 guard-bash.ps1 v3 完整移入判定邏輯（刪除分類、
# denyPatterns、askPatterns、inline 機密/env 特例），每個 Deny/Ask 呼叫點
# 改成 return（不 exit）。cmd 正規化（caret 剝除／黏連旗標／%VAR% disaster／
# verb-anywhere）尚未加入，於 task 3-6 逐條補上。
# ============================================================

# ──────────────────────────────────────────────────────────────
# 遞迴刪除指令的目標分級（posix rm 與 PowerShell 刪除家族）
#   回傳 'deny' / 'ask' / 'allow' / $null（此段落非刪除指令或非遞迴）
#   'allow' 非終結值——呼叫端仍要繼續掃描同一段指令的其他 DENY/ASK 樣式。
# ──────────────────────────────────────────────────────────────
function Get-DeleteClassification {
    param([string]$segment)

    $t = $segment.Trim().Trim('(', ')').Trim()
    # 剝除逃逸前綴到真正動詞（2026-07-11 紅隊實測穿透後擴充 A2a）：迴圈到穩定，讓
    # `env rm`/`timeout 5 rm`/`\rm`/`eval "rm …"`/`FOO=bar rm` 都露出 rm。
    # 殘留（已知漏、待 AST 層）：base64 解碼後執行、變數間接 `r=rm;$r`、printf|sh。
    $prev = $null
    while ($t -ne $prev) {
        $prev = $t
        $t = $t.Trim().Trim('(', ')').Trim()
        $t = $t -replace '^\w+=("[^"]*"|''[^'']*''|\S*)\s+', ''                                  # FOO=bar
        $t = $t -replace '^(sudo|nohup|time|command|exec|env|busybox|toybox|stdbuf\s+\S+|nice(\s+-n\s+-?\d+)?)\s+', ''  # 裸 wrapper（busybox/toybox applet 前綴：2026-09-14 golden 抽測抓到）
        $t = $t -replace '^timeout(\s+(-{1,2}\S+|\d+[smhd]?))*\s+', ''                            # timeout [flags/時長…] cmd
        $t = $t -replace '^\\(?=\w)', ''                                                          # \rm -> rm
        $t = $t -replace '^(["''])([^"'']*?[\\/]s?bin[\\/]\w+(\.exe)?)\1(?=\s|$)', '$2'             # "C:/…/usr/bin/rm.exe" -rf → 先脫外層引號（2026-09-14 Windows 路徑變體，路徑含空白必帶引號）
        $t = $t -replace '^(?:[A-Za-z]:)?(?:[\\/][^\\/]*?)*?[\\/]s?bin[\\/](?=\w)', ''                # /bin/rm、/usr/bin/rm、/sbin/…、/c/Program Files/Git/usr/bin/rm、C:\…\usr\bin\rm.exe -> rm（2026-09-14 golden 抽測抓到：絕對路徑動詞直接放行）
        if ($t -imatch '^eval\s+') {                                                              # eval "rm …" -> rm …
            $t = ($t -replace '^eval\s+', '').Trim()
            if ($t -match '^"(.*)"$') { $t = $Matches[1] }
            elseif ($t -match "^'(.*)'$") { $t = $Matches[1] }
        }
    }
    $isPosixRm = $t -imatch '^rm(\.exe)?\s'
    $isPsRm    = $t -imatch '^(remove-item|ri|rd|rmdir|del|erase)\s'
    if (-not ($isPosixRm -or $isPsRm)) { return $null }

    $tokens = ($t -split '\s+') | Select-Object -Skip 1
    $flags = @(); $targets = @()
    $skipNext = $false
    foreach ($tok in $tokens) {
        if ($skipNext) { $targets += $tok.Trim('"', "'"); $skipNext = $false; continue }
        if ($tok -imatch '^-(path|literalpath)$') { $skipNext = $true; continue }
        if ($tok -match '^-') { $flags += $tok; continue }
        # cmd 式旗標（/s /q）只在 PS 刪除家族視為旗標；posix rm 的 / 開頭是絕對路徑
        if ($isPsRm -and $tok -match '^/[a-zA-Z]{1,2}$') { $flags += $tok; continue }
        $targets += $tok.Trim('"', "'")
    }
    $flagStr = $flags -join ' '

    # 遞迴判定：posix 的 -r/-R（含合併旗標）/--recursive；PS 的 -Recurse；cmd 的 /s
    $recursive = $false
    if ($isPosixRm) { $recursive = $flagStr -cmatch '-[a-zA-Z]*[rR]' -or $flagStr -imatch '--recursive' }
    if ($isPsRm)    { $recursive = $flagStr -imatch '-rec' -or $flagStr -imatch '(^|\s)/s(\s|$)' }
    if (-not $recursive) { return $null }

    if ($targets.Count -eq 0) { return 'ask' }

    $safeNames = '^(node_modules|dist|build|out|coverage|__pycache__|\.pytest_cache|\.ruff_cache|\.mypy_cache|\.cache|\.next|\.turbo|\.parcel-cache)$'
    $allSafe = $true
    foreach ($g in $targets) {
        $gg = $g
        if ($gg.Length -gt 1) { $gg = $gg.TrimEnd('/', '\'); if ($gg.Length -eq 0) { $gg = $g } }
        # 災難級目標：根目錄、家目錄、磁碟根（含 git-bash 的 /c）、整個目前目錄
        if ($gg -match '^(/|~|\$HOME|\$env:USERPROFILE|[A-Za-z]:|/[A-Za-z]|/\*|\*|\.|\.\.)$') { return 'deny' }
        if ($gg -imatch '^(/c/users/[^/]+|[A-Za-z]:\\users\\[^\\]+)[/\\]?$') { return 'deny' }
        # cmd 正規化 3/4（2026-07-25）：cmd 執行期把 %VAR% 展開成家目錄/磁碟根，但分類器靜態
        # 看到的是字面 token，會誤降成 ask。把已知高危環境變數視為 disaster（不降級）。
        if ($gg -imatch '^%(USERPROFILE|HOMEPATH|HOMEDRIVE|SystemDrive|SystemRoot|windir|PUBLIC|ALLUSERSPROFILE|ProgramData|ProgramFiles)%') { return 'deny' }
        if ($gg -imatch '^\$env:(USERPROFILE|HOMEPATH|SystemDrive|SystemRoot|windir)') { return 'deny' }
        $base = ($gg -split '[\\/]')[-1]
        $inScratchpad = $gg -imatch 'Temp[\\/]claude'
        if (-not (($base -imatch $safeNames) -or $inScratchpad)) { $allSafe = $false }
    }
    if ($allSafe) { return 'allow' }
    return 'ask'
}

# ──────────────────────────────────────────────────────────────
# Get-GuardVerdictSingle — 單層判定（不展開殼包裹）。
# 對外入口是檔尾的 Get-GuardVerdict（= 本函式 + 殼內層展開比較），呼叫端不受影響。
# ──────────────────────────────────────────────────────────────
function Get-GuardVerdictSingle {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Command
    )

    $cmd = $Command

    # A1（2026-07-11）：換行/CR 正規化成分隔符——防「echo hi<換行>rm -rf /」這類換行切段繞過
    # （categorical fix：讓換行後的段落照常被逐段錨定檢查）。已知取捨：heredoc/字串字面內的
    # 危險指令「文字」會被誤判 DENY（低頻可接受，非 bug）。
    $cmd = $cmd -replace '[\r\n]+', ' ; '

    # cmd 正規化 1/4（2026-07-25）：caret 剝除——cmd.exe 逃逸字元，讓 `de^l`/`rmdi^r` 這類
    # 逐字元插入 ^ 的動詞混淆繞法露出真正動詞。全域套用；112 案回歸語料中無 ^ 出現，
    # 對既有判定零影響（唯一取捨同 A1：字面內容含 ^ 的低頻情境，可接受）。
    $cmd = $cmd -replace '\^', ''

    # cmd 正規化 2/4（2026-07-25）：黏連旗標拆開——cmd 允許 `/s/q` 黏寫，會讓遞迴旗標 /s
    # 逃過分類器的 `(^|\s)/s(\s|$)` 偵測。插空白 /s/q -> /s /q（只影響刪除分類器餵入；
    # 112 語料無黏連旗標，零影響）。
    $cmd = $cmd -replace '(/[a-zA-Z])(?=/)', '$1 '

    # ──────────────────────────────────────────────────────
    # 2) 以 ; && || | 及單一 & 切段，逐段檢查刪除指令
    # （2026-07-24：補單一 & 繞法——`echo hi & rm -rf /` 在 bash（背景符）與 cmd（串接符）下都會執行，
    #  原 splitter 漏切單 &，使 echo 前綴把整段當非刪除放行。&(?!&) 只切單 &、不誤切 &&；
    #  denyPatterns 對整串 $cmd 比對故不受影響，本切段只餵刪除分類器。）
    # ──────────────────────────────────────────────────────
    $segments = [regex]::Split($cmd, '\s*(?:;|&&|\|\||\||&(?!&))\s*')
    foreach ($seg in $segments) {
        $cls = Get-DeleteClassification $seg
        if ($cls -eq 'deny') { return @{ decision = 'deny'; why = "遞迴刪除根目錄／家目錄／整個目前目錄（$($seg.Trim())）" } }
        if ($cls -eq 'ask')  { return @{ decision = 'ask';  why = "遞迴刪除檔案／目錄（$($seg.Trim())）" } }
        # 'allow'（安全目標）與 $null（非刪除）都繼續往下檢查其他樣式
    }

    # 2026-10-02（webfetch-preapproval spec §2「自我核准的縫」；2026-10-02 修補簡報
    # R-M1 修正）：claude-guard-webfetch 目錄（WebFetch 預放行檔＋既有 session dedup
    # state 共用）只准 guard-mcp.ps1 本身與使用者在終端親手執行的
    # .governance/bin/preapprove-webfetch.ps1 碰——這兩者都不經過本 hook（guard-core
    # 只管 Bash/PowerShell 工具呼叫）。agent 殼裡沒有合法理由寫入或代跑該腳本。
    #
    # 【R-M1 修正前的洞】原版兩條規則分別是「指令任何位置含讀取動詞才放行，否則
    # 一律 deny」與「指令字面含 preapprove-webfetch.ps1 就一律 deny」。實測這兩條
    # 誤殺大量日常治理指令：`git add/commit/diff …preapprove-webfetch.ps1`、
    # `Get-Content .../preapprove-webfetch.ps1`（讀原始碼）、
    # `rg -n claude-guard-webfetch .governance`、
    # `Select-String -Path $env:TEMP/claude-guard-webfetch/...`、
    # `Get-Content …\x.txt 2>$null`（`>` 被當成寫入動詞）、`(Get-Item …).Length`
    # （Get-Item 不在讀取動詞白名單）全部被誤擋。
    #
    # 【修法】兩條規則改成只認「形狀」，不是「含有字面字串就處置」：
    #   - 腳本名規則只擋「呼叫形狀」：指令字面含 preapprove-webfetch 這個子字串
    #     **且**該處位於呼叫位置（段首或殼分隔符之後緊接 pwsh/powershell、呼叫
    #     運算子 & 後接空白、dot-source 的 . 後接空白或路徑分隔符，或指令含
    #     -File 旗標）。只是「提到」這個檔名（git add/commit/diff、Get-Content
    #     讀原始碼、rg/Select-String 搜尋）不構成呼叫形狀，放行。
    #   - 目錄規則只擋「寫入形狀」：明確的寫入動詞／API（Set-Content、Out-File、
    #     Add-Content、New-Item、Copy-Item／copy／cp、Move-Item、Rename-Item、
    #     Clear-Content、Set-ItemProperty、mklink、Tee-Object／tee、touch、
    #     python 的 open(、[IO.File]::Write*、(Get-Item …).LastWriteTime=），
    #     或重導向的**目標**本身含這個目錄字面（`2>$null` 這類 stderr 丟棄不算
    #     寫入——目標是 `$null`，不含目錄字面，天然就不會比對到）。沒有寫入
    #     形狀＝放行，即使指令字面提到這個目錄（讀取／列舉／搜尋／查屬性都是
    #     合法診斷用途）。
    #
    # 【F3，已知限制，明文記錄，不是沒寫好】字串比對結構上擋不住「執行期才組出
    # 字面字串」的繞法：變數/字串拼接（$a+$b、Join-Path 拼目錄名、bash
    # `$a-$b`）、萬用字元（`?`／`*` 取代字元讓字面不連續）、base64 等編碼、
    # Get-ChildItem 萬用字元取腳本物件後再呼叫。這些攻擊在這一層**不會出現**
    # 「claude-guard-webfetch」或「preapprove-webfetch」這兩個連續子字串，沒有
    # 東西可比對——這是這一層（Bash/PowerShell 工具呼叫的靜態字面比對）設計射程
    # 的邊界，不是規則寫漏。真正的防線在
    # .governance/bin/preapprove-webfetch.ps1 本身的互動式閘門（F5：非 TTY 或
    # 輸入/輸出被重導一律拒絕且不寫檔）——agent 殼呼叫腳本時 stdin/stdout 一定是
    # 重導的，就算字面比對被繞過，腳本自己仍會拒絕執行。已固化進
    # guard-cases.jsonl 的 webfetch-preapprove-bypass-* 案例裡，字面抓不到的那些
    # expect 標為 pass 並在 note 寫明此限制，不留假紅燈也不假裝擋得住。
    #
    # 【F3 措辭修正，2026-10-03 修補簡報 fix-3】上一段「真正的防線在 F5」只對
    # 「繞過這一層、但最終仍跑進 preapprove-webfetch.ps1 本體」的案例（腳本名
    # 拆字串拼接／bash glob／Get-ChildItem 取物件再呼叫）成立——這些繞法會
    # 真的執行到那支腳本，F5 互動式閘門攔得住。但另外四條直接把寫入動作對準
    # claude-guard-webfetch 目錄字面的繞法（目錄名拼接、bash 變數拼接、萬用
    # 字元、base64 編碼路徑）根本不經過那支腳本，F5 對它們沒有意義——這四條
    # 「直接寫入該目錄沒有結構性防線（同帳號程序本就能寫），此層只是摩擦＋
    # 稽核」，殘餘風險由 never-dedup 安全網與 12 小時上限兜底。另外，F5 本身的
    # 測試逃生口（GUARD_PREAPPROVE_TEST_MODE）已限制為非預設目錄且帶 testmode
    # 標記（F9／F12：2026-10-03 fix-3b 補上 reparse point／8.3 短名的路徑層
    # 檢查，以及 guard-mcp.ps1 讀檔時的內容層標記兜底——review-3 實測一個名字
    # 無害的 junction 就能讓 F9 的純字串比對通過、卻把檔案實際寫進真實預設
    # 目錄，詳見 preapprove-webfetch.ps1 的 F12 註解），否則該逃生口本身也會
    # 是一條能被 agent 殼（繞過這一層字串比對後）觸發的旁路。逐條措辭見
    # guard-cases.jsonl 與 .governance/specs/2026-10-02-webfetch-preapproval.md
    # 「2026-10-03 fix-3／fix-3b」段。
    #
    # 【F13，同輪 review-3b 補】覆寫目錄葉名含萬用字元字元類（[ ] * ?）的繞法——
    # 路徑層由 preapprove-webfetch.ps1 的 Test-SafeTestStateDir 直接拒收該字元類，
    # 寫入層所有可用 -LiteralPath 的 cmdlet 已全部改用；這兩層同樣都在腳本本體
    # 內，不經過本 hook，與上面 F12 同理不是這一層的射程。
    $wfInvokeShapeRx = '(^|;|&&|\|\||\||&)\s*(pwsh|powershell)(\.exe)?\b' +
                        '|(^|;|&&|\|\||\||&)\s*&(?=\s)' +
                        '|(^|;|&&|\|\||\||&)\s*\.(?=[\s\\/])' +
                        '|-File\b'
    if (($cmd -imatch 'preapprove-webfetch') -and ($cmd -imatch $wfInvokeShapeRx)) {
        return @{ decision = 'deny'; why = 'preapprove-webfetch.ps1 只准使用者在終端親手執行，agent 殼裡沒有合法理由代跑該腳本（會自我核准 WebFetch 預放行清單）' }
    }

    if ($cmd -imatch 'claude-guard-webfetch') {
        $wfWriteVerbRx = '\b(set-content|out-file|add-content|new-item|copy-item|move-item|rename-item|clear-content|set-itemproperty|mklink|tee|cp|copy|touch)\b' +
                         '|\[io\.file\]::write\w*' +
                         '|\bopen\s*\(' +
                         '|\(get-item[^)]*\)\.lastwritetime\s*='
        $wfRedirectToDirRx = '>{1,2}\s*[^;&|\r\n]*?claude-guard-webfetch'
        if (($cmd -imatch $wfWriteVerbRx) -or ($cmd -imatch $wfRedirectToDirRx)) {
            return @{ decision = 'deny'; why = 'claude-guard-webfetch 目錄（WebFetch 預放行檔）偵測到寫入形狀（寫入動詞／API 或重導向目標落在此目錄），只准使用者在終端親手執行 .governance/bin/preapprove-webfetch.ps1 寫入' }
        }
    }

    # ──────────────────────────────────────────────────────
    # 3) DENY 樣式：災難級、不可逆
    # ──────────────────────────────────────────────────────
    $denyPatterns = @(
        @{ rx = 'git\s+push\b[^;&|]*(--force(?!-with-lease)\b|\s-f\b)'; why = 'git push --force / -f（覆蓋遠端歷史；如有需要請改 --force-with-lease 並經使用者確認）' },
        @{ rx = 'git\s+push\b[^;&|]*\s\+\S+';       why = 'git push refspec 強推（+branch 等同 --force）' },
        @{ rx = '\bDROP\s+(TABLE|DATABASE|SCHEMA)\b'; why = 'SQL DROP（破壞性結構操作）' },
        @{ rx = '\bTRUNCATE\s+TABLE\b';             why = 'SQL TRUNCATE（清空資料表）' },
        @{ rx = '\bmkfs(\.|\s)';                    why = '格式化檔案系統' },
        @{ rx = '\bdd\s+[^;&|]*of=/dev/';           why = 'dd 直接寫入磁碟裝置' },
        @{ rx = 'format-volume|clear-disk|initialize-disk'; why = 'PowerShell 磁碟格式化／清除' },
        # 2026-07-26（Antigravity adapter 對等化）：以下三條原本只存在於 .agents/antigravity-guard.ps1
        # 的自含 deny 清單。把該檔改成薄 shim 之前必須先補進 core，否則這些指令會從「現行 deny」
        # 退化成「完全放行」（實測 pass，見交接紀錄）。補進 core 而非 shim ＝ 三家 adapter 共同受益。
        #
        # (1) legacy `format <碟>:`（cmd 的格式化指令；core 原本只認 format-volume/clear-disk）。
        #     **必須錨定段首**：不錨定會誤殺 `dotnet format C:\repo\x.sln`（實測該字串含 "format C:"）。
        #     `[A-Za-z]:\\?(\s|$)` 要求磁碟代號就是整個目標——後面接路徑（C:\repo\…）即不命中。
        @{ rx = '(^|[;&|])\s*format(\.com)?\s+(/\S+\s+)*[A-Za-z]:\\?(\s|$)'; why = 'legacy format <磁碟>:（格式化整顆磁碟）' },
        # (2) 重導直接寫入區塊裝置（core 原本只認 `dd … of=/dev/`，一般 `> /dev/sda` 完全放行）。
        #     只列真實區塊裝置名，故 `> /dev/null`／`/dev/stdout`／`/dev/tty` 不受影響。
        @{ rx = '>>?\s*/dev/(sd[a-z]|hd[a-z]|vd[a-z]|xvd[a-z]|nvme\d|mmcblk\d|disk\d)'; why = '重導直接寫入區塊裝置（毀磁碟）' },
        # (3) Windows 原生裸磁碟路徑（`of=\\.\PhysicalDrive0`）——posix `/dev/` 在 Windows 的對應寫法。
        @{ rx = '\bdd\b[^;&|]*of=\\\\[.?]\\physicaldrive'; why = 'dd 直接寫入 Windows 實體磁碟（\\.\PhysicalDriveN）' },
        @{ rx = ':\(\)\s*\{\s*:\s*\|\s*:';          why = 'fork bomb' },
        # 機密外洩（2026-07-11 依社群研究補；deny 級連 --dangerously-skip-permissions 都擋得住）：
        # 把機密檔上傳到網路——幾乎無正當日常用途
        @{ rx = '(curl|wget|iwr|invoke-webrequest)\b[^;&|]*(-T\s|--upload-file|-d\s*@|--data(-binary|-raw|-urlencode)?[= ]@|-F\s+[^;&|]*@)[^;&|]*(\.env|\.pem|\.key|id_rsa|id_ed25519|credentials|\.pfx|secrets?\.(json|ya?ml))'; why = '把機密檔（.env/私鑰/憑證）上傳到網路' }
    )
    foreach ($p in $denyPatterns) {
        if ($cmd -imatch $p.rx) { return @{ decision = 'deny'; why = $p.why } }
    }

    # cmd 正規化 4/4（2026-07-25）：verb-anywhere——cmd 刪除家族(rmdir/rd/del/erase)含 /s 遞迴
    # 但動詞不在段首（如 `for /d %i in (...) do rd /s /q %i`，段首是 for，分類器錨定段首動詞會漏）。
    # 目標經迴圈/變數展開靜態不可判定，保守升 ask（deny 已於上方 denyPatterns 先行，故此處只補 ask）。
    # 段首即為刪除動詞者（如 `rd /s /q node_modules`）不在此列——那些已由 Get-DeleteClassification 正確處理。
    foreach ($seg in $segments) {
        $st = $seg.Trim()
        if ($st -inotmatch '^(rmdir|rd|del|erase)\b' `
                -and $st -imatch '\b(rmdir|rd|del|erase)\b' `
                -and $st -imatch '(^|\s)/s(\s|$)') {
            return @{ decision = 'ask'; why = "cmd 刪除家族含 /s 遞迴、動詞非段首（目標經迴圈/展開靜態不可判定）（$st）" }
        }
    }

    # ──────────────────────────────────────────────────────
    # 4) ASK 樣式：使用者「先問」清單 → 強制確認框
    # ──────────────────────────────────────────────────────

    # SQL 整表刪除：DELETE FROM 無 WHERE（2026-07-11 紅隊實測穿透後補）
    if ($cmd -imatch '\bDELETE\s+FROM\b' -and $cmd -inotmatch '\bWHERE\b') {
        return @{ decision = 'ask'; why = 'DELETE FROM 無 WHERE 條件（整表刪除）' }
    }

    # 機密讀取/傾印（2026-07-11 依社群研究補）：讀機密檔或傾印含 token 的環境變數。
    # 這些有正當除錯用途（故用 ask 不用 deny），但輸出可能進 log/被截圖外流，先問。
    # .env.example / .sample / .template / .pub 是公開範本，豁免。
    if ($cmd -imatch '(^|[\s;&|])(cat|type|bat|less|more|head|tail|get-content|gc)\b[^;&|]*\.env\b' `
            -and $cmd -inotmatch '\.env\.(example|sample|template)\b') {
        return @{ decision = 'ask'; why = '讀取 .env（可能含 token／金鑰，輸出恐外流）' }
    }
    # 2026-07-26 裁決：補 auth.json（各家 CLI 的 OAuth token 慣用檔名，如 ~/.codex/auth.json），
    # **維持 ask 不升 deny**——同組機密（.env／私鑰／credentials）都是 ask，只升一條會造成
    # 「同類風險兩種處置」的內部不一致，那正是 policy 分岔的起點。deny 的摩擦成本也被低估：
    # deny 是硬擋、連 --dangerously-skip-permissions 都繞不過，除錯時只能改 hook，而「養成改
    # hook 的習慣」比偶爾多按一次確認危險得多。
    # 註：`\bauth\.json` 的 \b 不會誤命中 oauth.json（o 與 a 之間無詞界）。
    if ($cmd -imatch '(^|[\s;&|])(cat|type|bat|get-content|gc)\b[^;&|]*(id_rsa|id_ed25519|id_ecdsa|\.pem\b|\.pfx\b|\.p12\b|(?<!\.pub)\.key\b|credentials[^;&|]*\.json|\bauth\.json|secrets?\.(json|ya?ml|toml))' `
            -and $cmd -inotmatch '\.(pub|example|sample|template)\b') {
        return @{ decision = 'ask'; why = '讀取私鑰／憑證／機密檔（輸出恐外流）' }
    }
    if ($cmd -imatch '\bprintenv\b' -or $cmd -imatch '(get-childitem|gci|ls|dir)\s+env:' -or $cmd -imatch '\benv\s*$') {
        return @{ decision = 'ask'; why = '傾印全部環境變數（可能含 token／金鑰）' }
    }
    if ($cmd -imatch '(echo|write-output|write-host)\s+["'']?\$(\{)?(env:)?\w*(TOKEN|SECRET|KEY|PASSWORD|PASSWD|APIKEY|API_KEY|CREDENTIAL)') {
        return @{ decision = 'ask'; why = 'echo 含機密的環境變數（輸出恐外流）' }
    }

    # A2b（2026-07-11；2026-07-25 擴充 Windows 殼）：殼包裹破壞性指令 → ASK（保守：不遞迴
    # 解析內層引號，僅偵測「殼包裹旗標」與破壞性動詞共現。巢狀/base64/變數間接為已知殘留）。
    #
    # 2026-07-25 紅隊實測補洞：原規則的殼清單只有 posix（bash/sh/zsh/dash），**Windows 上最
    # 自然的兩個殼完全漏掉**，導致災難級指令直接穿透（實測 `cmd /c rm -rf /`、
    # `powershell -c "Remove-Item -Recurse -Force <家目錄>"` 皆為 pass 完全放行）。破壞性動詞
    # 清單同樣只有 posix 形式，補上 Windows 刪除家族與 Remove-Item。
    # 殘餘（明文保留，待裁決）：本規則刻意不遞迴展開內層，故 wrapper 仍會把 deny 級降為 ask
    # （`cmd /c rm -rf /` → ask 而非 deny）。要消除降級需遞迴展開後重判，屬設計語義變更。
    $a2bShell = '\b(ba|z|da)?sh\s+-[a-z]*c\b' +
                '|\bcmd(\.exe)?\s+(/[a-z0-9:]+\s+)*/[ck]\b' +
                '|\b(powershell|pwsh)(\.exe)?\s+(-\w+(\s+\S+)?\s+)*-(c|command)\b'
    $a2bDestructive = '\brm\s+-[a-zA-Z]*[rf]|\brm\s+--(recursive|force)\b' +
                      '|\bmkfs(\.|\s)|\bdd\s+[^;&|]*of=/dev/|\bDROP\s+(TABLE|DATABASE|SCHEMA)\b|:\(\)\s*\{\s*:' +
                      '|\bremove-item\b[^;&|]*\s-(recurse|force)' +
                      '|\b(rmdir|rd|del|erase)\b[^;&|]*\s/s\b'
    if ($cmd -imatch $a2bShell -and $cmd -imatch $a2bDestructive) {
        return @{ decision = 'ask'; why = '殼包裹（bash/sh/cmd/powershell -c）疑似破壞性指令（保守攔截，請確認內層安全）' }
    }

    # A3（2026-07-11）：讀機密 × 送網路 組合 → ASK（精確 curl 上傳已在 DENY 段；此處補
    # scp/rsync/python/node/--post-file/http.server 等非 curl 管道。排除 curl/wget 下載目標
    # `-o/-O/--output/>` 免誤殺「下載存成 .pem/.key」）。heuristic 故用 ASK 不用 DENY。
    $a3secret   = '\.env\b|\.pem\b|(?<!\.pub)\.key\b|id_rsa|id_ed25519|credentials|\.pfx\b|secrets?\.(json|ya?ml)'
    $a3send     = '\b(scp|rsync|nc|ncat|telnet)\b|--post-file|\bhttp\.server\b|-m\s+http\.server|\b(python[0-9.]*|node|php|ruby)\b[^;&|]*(requests|urllib|urlopen|http\b|fetch|socket|net/http)'
    $a3download = '\b(curl|wget)\b[^;&|]*(-o\b|-O\b|--output\b|>)'
    if ($cmd -imatch $a3secret -and $cmd -imatch $a3send -and $cmd -inotmatch $a3download) {
        return @{ decision = 'ask'; why = '疑似把機密檔（.env/私鑰/憑證）送出網路（scp/rsync/python/wget --post-file 等）' }
    }

    # git restore：只有「純 --staged（不含 --worktree）」是安全的取消暫存
    if ($cmd -imatch 'git\s+restore\b') {
        $isStagedOnly = ($cmd -imatch '--staged') -and ($cmd -inotmatch '--worktree')
        if (-not $isStagedOnly) { return @{ decision = 'ask'; why = 'git restore（會丟棄工作區未提交的修改）' } }
    }

    $askPatterns = @(
        @{ rx = 'git\s+reset\s+[^;&|]*--hard';        why = 'git reset --hard（丟棄未提交的修改）' },
        @{ rx = 'git\s+checkout\s+(--\s|\.(\s|$))';   why = 'git checkout -- / .（丟棄工作區未提交的修改）' },
        @{ rx = 'git\s+clean\b[^;&|]*-[a-z]*[fdxX]';  why = 'git clean（刪除未追蹤檔案）' },
        @{ rx = 'git\s+branch\b[^;&|]*(\s-D\b|--delete[^;&|]*--force|--force[^;&|]*--delete)'; why = 'git branch -D（強制刪除分支）' },
        @{ rx = 'git\s+push\b';                       why = 'git push（推送到遠端屬對外發送，一次授權不等於永久授權）' },
        @{ rx = 'git\s+commit\b[^;&|]*--amend';       why = 'git commit --amend（若該 commit 已推送過，改寫歷史很危險）' },
        @{ rx = '--no-verify\b|--no-gpg-sign\b';      why = '跳過 hook／簽章等安全機制' },
        @{ rx = 'git\s+stash\s+(drop|clear)\b';       why = 'git stash drop/clear（丟棄暫存的修改）' },
        @{ rx = 'git\s+update-ref\s+-d|git\s+reflog\s+expire'; why = '刪除 git 參照／reflog（斷後路）' },
        @{ rx = '\bfind\b[^;&|]*\s-delete\b';         why = 'find -delete（批次刪除檔案）' },
        @{ rx = '\bxargs\b[^;&|]*\brm\b';             why = 'xargs rm（刪除目標來自管線，靜態不可見）' },
        @{ rx = '\bchmod\b[^;&|]*\s0?000\b';          why = 'chmod 000（移除所有權限，等同鎖死）' },
        @{ rx = '\b(mv|cp)\s+[^;&|>]*\s/dev/null\b';  why = '搬移/覆蓋經 /dev/null（毀檔）' },
        @{ rx = '\btruncate\b[^;&|]*-s\s*0\b';        why = 'truncate -s 0（清空檔案內容）' },
        # A4（2026-07-11）：保守毀檔式（語義明確就是清空，日常幾乎不用；不碰一般 > 免誤殺重導）
        @{ rx = '\bcp\s+/dev/null\s+\S';              why = 'cp /dev/null 覆蓋檔案（清空內容）' },
        @{ rx = '(^|[\s;&|]):\s*>\s*[^\s>]';          why = ':> 清空檔案內容' },
        # A5（2026-07-11）：供應鏈——執行遠端來源
        @{ rx = '\bnpx\s+[^;&|]*(https?://|github:)'; why = 'npx 執行遠端套件（供應鏈風險）' },
        @{ rx = '\bpip[0-9.]*\s+install\s+[^;&|]*(git\+|https?://)'; why = 'pip 從 URL/git 安裝（供應鏈風險）' },
        @{ rx = 'core\.hookspath';                    why = '設定 git core.hooksPath（可能劫持 git hooks）' },
        # 2026-07-26（Antigravity adapter 對等化）：原兩條的殼清單漏了 Windows 上最自然的
        # `| powershell` / `| pwsh`，iex 那條又只認 iwr/downloadstring 家族——實測
        # `curl … | powershell`、`curl … | pwsh`、`curl … | iex`、`iwr … | Invoke-Expression`
        # 四種全部 pass（零攔截）。antigravity-guard 自含清單原本擋得住，改薄 shim 前先補進 core。
        # 維持 ask 不升 deny：與同組供應鏈規則（`curl | sh`）同級處置，避免同類風險兩種處置。
        @{ rx = '(curl|wget|iwr|invoke-webrequest)\b[^;&|]*\|\s*((ba|z|da)?sh|pwsh|powershell)(\.exe)?\b'; why = '下載內容直接餵給 shell 執行（供應鏈風險）' },
        @{ rx = '(curl|wget|iwr|invoke-webrequest|downloadstring)\b[^;&|]*\|\s*(iex|invoke-expression)\b'; why = '下載內容直接 Invoke-Expression（供應鏈風險）' },
        # A2b 延伸（2026-07-11）：解碼器/產生器管道餵 shell（混淆執行）→ ASK
        @{ rx = '(base64\s+-d|base64\s+--decode|xxd\s+-r|printf\b)[^;&|]*\|\s*(ba|z|da)?sh\b'; why = 'base64/printf 等解碼產生後直接餵 shell 執行（混淆式供應鏈風險）' },
        # 2026-07-25：PowerShell -EncodedCommand（base64 payload）——內容靜態不可判定，
        # 展開層也看不進去（實測 V1/V2 皆放行）。不解碼、只看旗標，一律 ask。
        # 取捨：合法的編碼呼叫也會被問一次；相對於「任意指令零攔截」這是划算的。
        @{ rx = '\b(powershell|pwsh)(\.exe)?\b[^;&|]*\s-(e|ec|enc|encoded|encodedcommand)\b'; why = 'PowerShell -EncodedCommand（base64 指令，內容不可靜態判定）' },
        # 2026-07-31（settings.local 破口同批）：--settings 指定外部設定檔＝第四種設定載體，
        # 可載入未受 guard-write 保護、未進版控的 permissions/hooks/env。與 protectRx 三載體同壘。
        @{ rx = '\bclaude(\.exe|\.cmd)?\b[^;&|]*\s--settings\b'; why = 'claude --settings 指定外部設定檔（繞過版控 settings 的第四種載體，先確認來源）' },
        # 2026-09-20（09-19 taskkill //IM 事故後的最小備援；完整評估見 research-decisions/2026-09-20-taskkill-incident-prevention.md）：
        # 程序終止動詞**出現在指令任何位置**就 ask。主防線是 settings 的 permissions.deny（整條 taskkill／Stop-Process -Name／pkill／killall），
        # 但實測 settings 規則有兩個洞：Bash 規則分大小寫（`Taskkill` 放行）、帶迴圈變數的 for 迴圈本體不被分析
        # （`for p in $(tasklist…); do taskkill /F /PID $p; done` 放行＝事故第二條的原形）。本規則用 -imatch 對整串比對，
        # 迴圈／變數／殼包裹／全路徑／大小寫都看得到。刻意用 ask 不用 deny：commit 訊息或 grep 提到這些字也會被問一次，
        # 但那是低頻且可放行的；deny 會連治理工作本身一起鎖死（紅隊實測 14 條）。合法收尾路徑＝ .governance/bin/with-child.mjs。
        # 不抓裸 `kill`（bash builtin 的 kill %1／PowerShell 別名太常見於無害脈絡）；PowerShell 別名 spps 抓。
        # 2026-10-03（setx-fix）：前綴字元類補 `{`（`& {taskkill ...}` 腳本區塊）與 `:`
        # （`-FilePath:taskkill` 這類冒號綁定），與下方 setx 規則同一個洞一併補。
        @{ rx = '(^|[\s;&|(){`"''/\\=:])(taskkill|tskill|pkill|killall|stop-process|spps)(\.exe)?(?![\w.-])'; why = '程序終止指令（2026-09-19 事故）：只准用 with-child.mjs 收自己登記的 PID；按名稱／篩選／埠／迴圈／變數殺一律先問' },
        @{ rx = '\bwmic(\.exe)?\b[^;&|]*\bprocess\b[^;&|]*\b(delete|call\s+terminate)\b|\b(invoke-cimmethod|invoke-wmimethod)\b[^;&|]*\bterminate\b|\.(kill|terminate|closemainwindow)\s*\('; why = '程序終止（WMI／CIM Terminate、.Kill()／.CloseMainWindow()）：只准用 with-child.mjs 收自己登記的 PID' },
        # 2026-10-03（setx-guard 補丁；規格權威見 .governance/specs/2026-10-03-persistent-env-guard.md）：
        # 持久環境變數／登錄檔 Environment 鍵寫入——與程序終止同級（AGENTS.md「機器狀態」規則，
        # 2026-09-19 事故後）：不得改永久環境變數、登錄檔。裁量權在使用者，故用 ask 不用 deny。
        #
        # 2026-10-03 setx-fix（第三輪，opus xhigh 與第二位 opus high 雙審查後的修補腿）：
        # 【效能】原版多條規則用 [\s\S]*? 跨段 lazy 掃描判定「A...之後某處出現 B」，在無匹配時
        # 逼引擎窮舉所有切點，32–160 KB 輸入會讓單條規則吃到 14–327 秒（實測），settings 沒設
        # hook timeout＝預設 600 秒，超長輸入可讓整支 guard-bash 連 deny 級規則一起 fail-open。
        # 本輪改法：①本區塊最前面加一道輸入長度保險（64 KB 門檔，排在 DENY 樣式與前面的
        # ask 檢查之後——只保護其後的規則不會被餵到那麼長還能跑完，不是整支 guard-core 的
        # 全部規則）；②SetEnvironmentVariable 改用「不跨括號／逗號的字元類＋一層巢狀括號」取代
        # [\s\S]*?，各參數段的切點是決定性的（遇到 , ( ) 就停），不會觸發回溯重試；③登錄檔
        # cmdlet／OpenSubKey 系列改成 ^(?=...)(?=...) 兩個獨立 lookahead 的「同時出現」判定
        # （已有 python winreg 規則先例），^ 錨點只讓引擎從位置 0 試一次，不會對每個起始位置
        # 重試整段掃描，故為 O(n)。reg add/delete/copy（外部行程）**不**放寬成同時出現——放寬會
        # 讓 `reg add 其他路徑; reg query HKCU\Environment` 這類無害指令被誤殺（N05/rn11 已證實）。
        # 改法是在原本的「同一段內」掃描中加一個否定前瞻：逐字元消耗時，若前方又出現另一個
        # `reg <subcommand>`（代表另一條獨立 reg 指令開始了）就停止消耗——這樣 caret 續行／
        # 換行轉 ; 的單一 reg add 仍可跨越人工插入的 ; 找到路徑（reg-guard-reg-caret-continuation
        # 迴歸案例），但兩條不同的 reg 指令之間不會互相洩漏。
        # 【SetEnvironmentVariable 閘門】改為「非 Process 即 ask」：錨點是識別字
        # setenvironmentvariable 本身（可選前置反斜線＋引號、可選 .Invoke），不再要求
        # [Environment]:: 前綴——型別參考用變數接、用括號包、用轉型字串呼叫都一樣命中，因為
        # 命中與否只看呼叫語法本身，不看前綴。找到呼叫後，第一、二個參數段（各可為一層巢狀
        # 括號、或完整引號字串——引號內的逗號/括號視為不透明整塊消耗，不會被誤判成參數分隔，
        # 這是 setenv-guard-comma-in-value-machine／-neg-two-args-comma 兩個既有迴歸案例的
        # 關鍵）確認是三參數呼叫，第三段用否定前瞻比對白名單——只有字面 Process／0／
        # [EnvironmentVariableTarget]::Process（允許前後空白／一層括號包覆、System. 前綴、
        # 大小寫不拘）算安全，其餘（變數、列舉轉整數、十六進位、引號內襯字、行內註解、反引號
        # 續行殘留、反引號跳脫雙引號殘留）一律不在白名單內→ask，不需要窮舉每種繞法的寫法，
        # 繞法只要不是那三種字面就自動落在「否則」。所有分隔符都用 [\s;]*（不是 \s*）：A1 把
        # 原本的換行轉成 「 ; 」，若只認 \s* 會在跨行呼叫時被插入的 ; 卡斷（已修復的迴歸：
        # setenv-guard-multiline-user／-neg-multiline-process、reg-guard-opensubkey-multiline）。
        # 【登錄檔 cmdlet】Set/New/Remove/Clear/Rename/Copy/Move-ItemProperty 與別名
        # sp/ni/rp/clp/rnp/cpp/mp、Set-Item／Remove-Item 與別名 si/ri/rm/del/erase 任一出現
        # ＋HKCU 系（HKCU:\、HKCU:/、Registry::HKEY_CURRENT_USER\、Registry::HKCU\ 皆算同一
        # 分隔字元類）／HKU\<SID>\Environment／HKEY_USERS\<SID>\Environment／HKLM Session
        # Manager\Environment 任一出現，指令任何位置皆可、不要求相鄰——涵蓋管線先取路徑再
        # Set-ItemProperty、路徑存變數、New-PSDrive 把 Environment 設成磁碟機根再用別名路徑寫
        # 入等「字面有出現、只是位置分散」的繞法。刻意不含裸 New-Item（只含 New-ItemProperty
        # 與別名 ni）：含了會讓「讀 Environment；New-Item 建全新檔案」這類無害指令被誤殺。
        # 【OpenSubKey／CreateSubKey】同樣改同時出現判定：'Environment' 當第二參數（含尾反
        # 斜線／正斜線變體）出現＋.SetValue(／.DeleteValue(／.DeleteSubKeyTree(／.DeleteSubKey(
        # 任一出現，不要求相鄰。另外 DeleteSubKeyTree／DeleteSubKey 也可能直接對 'Environment'
        # 呼叫（不經 OpenSubKey，例如 CurrentUser.DeleteSubKeyTree('Environment')），獨立補一條
        # 不需同時出現判定的直接呼叫規則。
        # 【新增涵蓋】regini（內容在外部 .ini 檔，靜態不可判定，比照 reg import/regedit /s 一律
        # ask）；StdRegProv CIM 方法（StdRegProv／寫入類方法名／environment 三者同時出現）；
        # reg add/delete/copy 與 Set-ItemProperty 系都補上 HKU\<SID>\Environment 變體。
        # 【已知限制（字串層結構性，與 webfetch spec F3 同性質，不留假紅燈）】
        #   - setx／cmdlet 名稱被 bash `\`（V02）或反引號（V01/rv02/rv14）拆成不連續子字串
        #     （se\etx、se`tx、Env`ironment）——這層會把字元拆開再由殼/引擎還原，字串比對
        #     看不到還原後的樣子；要修須加一道全域「剝反引號／反斜線」正規化，超出本次只動
        #     規則區塊的範圍，留作已知限制。
        #   - bash 空字串相接拆字（se''tx，V03）——同上，需要全域正規化才能收。
        #   - cmd 零長度子字串前綴（%ComSpec:~0,0%setx，V07）——cmd 變數展開在執行期才發生。
        #   - Get-Command 搭配萬用字元解析指令名（se?x／se?x.exe，V34／V34b）——哪個檔案會被
        #     萬用字元比對到是執行期才知道的，字串層看不到候選集合。
        #   - 路徑含 `..` 相對片段（HKCU:\Software\..\Environment，V22）或萬用字元
        #     （HKCU:\Environmen?，V23）——會命中 hkcu 開頭但中間不是純分隔字元，不在本輪
        #     HKCU 分隔字元類的射程；加萬用字元/相對路徑正規化風險大於效益，留作已知限制。
        #   - 執行期字串拼接組出函式名、型別、或登錄檔路徑的「子字串」本身不相鄰（例如先把
        #     hive 字串切兩半各自用 + 接起來才傳進 SetValue／iex 再拼出 setx）——字面上找不到
        #     完整關鍵字，結構性不可偵測；型別或成員改走 Reflection（GetMethod+Invoke）間接呼叫
        #     也屬此類（若仍直接寫出方法名字面如 .'SetEnvironmentVariable'(...) 或
        #     ([Environment])::SetEnvironmentVariable(...) 則本輪規則仍會命中，不算此限制）。
        @{ rx = '^[\s\S]{65536,}'; why = '指令字串超過 64 KB，靜態分析在此長度不可靠（2026-10-03 審查實測：舊版規則在 32–160 KB 輸入會耗時 14–327 秒，足以讓整支 guard-bash fail-open）：請拆成較短指令，或確認是否真的需要如此長的單一指令' },
        @{ rx = '(^|[\s;&|(){`"''/\\=:])setx(\.exe)?(?![\w.-])'; why = '持久環境變數／登錄檔 Environment 寫入（2026-09-19 機器狀態規則）：只准使用者親手改' },
        @{ rx = '\bsetenvironmentvariable[\s;]*\\?[''"]?[\s;]*(\.[\s;]*invoke)?[\s;]*\((?:\\?[''"][^''"]*\\?[''"]|\([^()]*\)|[^,()''"])*,(?:\\?[''"][^''"]*\\?[''"]|\([^()]*\)|[^,()''"])*,(?![\s;]*\(?[\s;]*\\?(?:0|process|[''"]process\\?[''"]|\[(?:system\.)?environmentvariabletarget\][\s;]*::[\s;]*process)\\?[\s;]*\)?[\s;]*\))'; why = '持久環境變數／登錄檔 Environment 寫入：SetEnvironmentVariable 三參數呼叫且第三參數非字面 Process／0／[EnvironmentVariableTarget]::Process（2026-09-19 機器狀態規則）：只准使用者親手改' },
        @{ rx = '^(?=[\s\S]*(?<![\w-])(set-itemproperty|new-itemproperty|remove-itemproperty|clear-itemproperty|rename-itemproperty|copy-itemproperty|move-itemproperty|sp|ni|rp|clp|rnp|cpp|mp|set-item|remove-item|si|ri|rm|del|erase)(?![\w-]))(?=[\s\S]*((hkcu|hkey_current_user)[:\\/]*environment\b|(hku|hkey_users)[:\\/]*[^\\/;&|()]{0,64}[\\/]environment\b|(hklm|hkey_local_machine)[:\\/]*system[\\/]+(currentcontrolset|controlset\d+)[\\/]+control[\\/]+session manager[\\/]+environment\b|session manager[\\/]+environment\b))'; why = '持久環境變數／登錄檔 Environment 寫入（登錄檔 cmdlet 與 Environment 鍵同時出現；2026-09-19 機器狀態規則）：只准使用者親手改' },
        @{ rx = '\breg(\.exe)?\s+(add|delete|copy)\b(?:(?!\breg(\.exe)?\s+\w)[^&|])*((hkcu|hkey_current_user)[\\/]+environment\b|(hku|hkey_users)[\\/]+[^\\/;&|()]{0,64}[\\/]+environment\b|session manager[\\/]+environment\b)'; why = '持久環境變數／登錄檔 Environment 寫入（2026-09-19 機器狀態規則）：只准使用者親手改' },
        @{ rx = '\breg(\.exe)?\s+(import|restore|load)\b|\bregedit(\.exe)?\b[^;&|]*(\s[/-]s\b|\.reg\b)|\bregini(\.exe)?\b'; why = '登錄檔匯入／regini（內容靜態不可判定、可寫入 Environment；2026-09-19 機器狀態規則）：只准使用者親手改' },
        @{ rx = '\[(microsoft\.win32\.)?registry\]::setvalue\s*\([^()]*environment'; why = '持久環境變數／登錄檔 Environment 寫入（2026-09-19 機器狀態規則）：只准使用者親手改' },
        @{ rx = '^(?=[\s\S]*(opensubkey|createsubkey)[\s;]*\([\s;]*[''"]environment[\\/]*[''"])(?=[\s\S]*\.[\s;]*(setvalue|deletevalue|deletesubkeytree|deletesubkey)[\s;]*\()'; why = '持久環境變數／登錄檔 Environment 寫入（OpenSubKey／CreateSubKey 與 SetValue／DeleteValue／DeleteSubKeyTree 同時出現；2026-09-19 機器狀態規則）：只准使用者親手改' },
        @{ rx = '\.[\s;]*(deletesubkeytree|deletesubkey)[\s;]*\([\s;]*[''"]environment[\\/]*[''"]'; why = '持久環境變數／登錄檔 Environment 寫入（直接呼叫 DeleteSubKeyTree／DeleteSubKey 的 Environment 鍵引數；2026-09-19 機器狀態規則）：只准使用者親手改' },
        @{ rx = '\bwmic(\.exe)?\b[^;&|]*\benvironment\b[^;&|]*\b(create|set|delete)\b|\b(new|set|remove)-ciminstance\b[^;&|]*\bwin32_environment\b|\bset-wmiinstance\b[^;&|]*\bwin32_environment\b|\bwin32_environment\b[\s\S]*?\b((set|remove)-ciminstance|remove-wmiobject|set-wmiinstance)\b|\bwin32_environment\b[\s\S]*?\.(put|delete)\s*\(|\[wmiclass\][^;&|]*\bwin32_environment\b'; why = '持久環境變數寫入（WMI／CIM Win32_Environment；2026-09-19 機器狀態規則）：只准使用者親手改' },
        @{ rx = '^(?=[\s\S]*\bstdregprov\b)(?=[\s\S]*\b(setstringvalue|setdwordvalue|setexpandedstringvalue|setmultistringvalue|setbinaryvalue|deletevalue|deletekey|createkey)\b)(?=[\s\S]*\benvironment\b)'; why = '持久環境變數／登錄檔 Environment 寫入（CIM StdRegProv 寫入類方法；2026-09-19 機器狀態規則）：只准使用者親手改' },
        @{ rx = '^(?=[\s\S]*winreg\b)(?=[\s\S]*environment)(?=[\s\S]*\b(setvalue(ex)?|deletevalue)\s*\()'; why = '持久環境變數／登錄檔 Environment 寫入（python winreg；2026-09-19 機器狀態規則）：只准使用者親手改' }
    )
    foreach ($p in $askPatterns) {
        if ($cmd -imatch $p.rx) { return @{ decision = 'ask'; why = $p.why } }
    }

    return @{ decision = 'pass'; why = '' }
}

# ──────────────────────────────────────────────────────────────
# 殼包裹展開（2026-07-25，紅隊實測後補）
#   `cmd /c <指令>`／`powershell -c "<指令>"`／`bash -c '<指令>'` 會讓內層指令不在段首，
#   使錨定段首動詞的分類器看不見它。A2b 原本只做「殼旗標 × 破壞性動詞共現 → ask」的
#   保守攔截，代價是 deny 級被降成 ask。此處剝除包裹前綴與外層引號、迴圈到穩定，
#   讓內層回到段首、走完整判定，再取「較嚴格者」為終判。
#
#   實測（127 案例 + 16 條日常指令）：只影響 7 條殼包裹攻擊案例（全為 ask→deny 加嚴），
#   日常合法指令 0 條被加嚴（`bash -c "rm -rf ./dist"` 等安全目標仍走內層 classifier 判 ask）。
#   已知殘留：base64 `-EncodedCommand`（改由上方 askPatterns 一律 ask 兜底）、
#   變數間接（`$r=rm;$r -rf /`）——展開層看不進去，仍是殘留。
# ──────────────────────────────────────────────────────────────
function Expand-ShellWrapper {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$Command)
    $c = $Command
    $prev = $null
    $depth = 0
    while ($c -ne $prev -and $depth -lt 10) {
        $depth++
        $prev = $c
        $c = $c.Trim()
        $c = $c -replace '^cmd(\.exe)?(\s+/[a-z0-9:]+)*\s+/[ck]\s+', ''
        $c = $c -replace '^(powershell|pwsh)(\.exe)?(\s+-\w+(\s+\S+)?)*\s+-(c|command)\s+', ''
        $c = $c -replace '^(bash|sh|zsh|dash)(\.exe)?(\s+-\w+)*\s+-c\s+', ''
        if ($c -match '^"(.*)"$') { $c = $Matches[1] }
        elseif ($c -match "^'(.*)'$") { $c = $Matches[1] }
    }
    return $c
}

# ──────────────────────────────────────────────────────────────
# 並行分支漂移偵測（P0-2，2026-09-19）
#
# 【為什麼】2026-09-18 與 09-19 兩次實際發生：一個 Claude session 工作到一半，
# 另一個 session 把同一棵工作樹的 checkout 切到別的分支並留下未提交檔，
# 而**沒有任何機制通知前者**——它是在做終態查詢時才發現的。
# AGENTS.md 早有「序列交接」鐵則，缺的是**機制**不是規則；而違規者正是
# hooks 唯一完整的那一家（Claude Code），證明既有 hooks 射程不含此接縫。
# 依據：research-decisions/2026-09-18-cross-agent-handoff-fable-ruling-and-plan.md §A.6。
#
# 【為什麼是 ask 不是 deny】誤判成本不對稱：漏提醒＝可能互毀 git 狀態（可回復，
# 有 reflog）；誤擋＝打斷工作流並訓練人忽略守門（信任損耗不可回復）。
# 本層**永遠不回 deny**，由 test-branch-drift.ps1 §9 機械釘住。
#
# 【為什麼 fail-open】狀態檔缺失或損壞時放行並說明——這是**安全網不是閘門**
# （memory components-not-alternatives）。做成閘門會在狀態檔還沒建立的第一個
# session 就擋死所有 git 操作，那比沒有守門更糟。
#
# 這兩個都是**純函式**：零 I/O、所有輸入顯式傳入。真實的檔案讀取與 git 查詢
# 留在 shim，這樣判定層才測得動（memory fixture-tests-must-not-read-real-env）。
# ──────────────────────────────────────────────────────────────

function Test-IsTreeMutatingGit {
    <#
    .SYNOPSIS 這條指令會不會動到 git 工作樹？
    .DESCRIPTION
      認定方式：指令裡出現 git 可執行檔 token，且**在它之後**出現會動樹的動詞。
      先把折行與多重空白正規化，讓「多行折行」「多重空白」兩種繞法失效。
      刻意不解析 git 的全域旗標（-C <path>、--git-dir=、-c k=v）——因為旗標的
      值可能是裸路徑（`git -C C:\ws\repo checkout`），逐一枚舉旗標文法必漏。
      改成「動詞出現在 git 之後」這個較寬的條件：本層只產生 ask，寬一點的代價
      是偶爾多問一次，窄一點的代價是漏掉真正的漂移。
    #>
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$Command)

    if ([string]::IsNullOrWhiteSpace($Command)) { return $false }

    # 正規化：反引號折行、CRLF、多重空白 → 單一空白
    $c = $Command -replace '`\s*\r?\n', ' '
    $c = $c -replace '\r?\n', ' '
    $c = $c -replace '\s+', ' '

    $gitToken = '(^|[\s&|;(])git(\.exe)?(\s|$)'
    $m = [regex]::Match($c, $gitToken, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $m.Success) { return $false }

    $after = $c.Substring($m.Index + $m.Length)
    $verbs = 'checkout|switch|reset|merge|rebase|stash|pull|commit|clean'
    return [bool][regex]::IsMatch($after, "(^|\s)($verbs)(\s|$)", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Test-IsBranchSwitchGit {
    <#
    .SYNOPSIS 這條指令是不是「切分支」？（checkout / switch）
    .DESCRIPTION
      比 Test-IsTreeMutatingGit 窄：只認 checkout／switch，因為只有它們會改變
      `rev-parse --abbrev-ref HEAD`。給 PostToolUse 用——**你自己切的分支不該讓你
      在下一條 git 指令被問一次**（Fable delta §5 #1-i：舊版狀態檔只在 SessionStart 寫，
      自己 `git checkout -b` 之後必觸發一次假 ask；E2E-4 用 checkout -b 模擬「別人切走」，
      等於同時證明了這個假陽性）。
      正規化與 Test-IsTreeMutatingGit 一致（折行／多重空白／git 之後才算動詞）。
    #>
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$Command)

    if ([string]::IsNullOrWhiteSpace($Command)) { return $false }
    $c = $Command -replace '`\s*\r?\n', ' '
    $c = $c -replace '\r?\n', ' '
    $c = $c -replace '\s+', ' '

    $m = [regex]::Match($c, '(^|[\s&|;(])git(\.exe)?(\s|$)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $m.Success) { return $false }
    $after = $c.Substring($m.Index + $m.Length)
    return [bool][regex]::IsMatch($after, '(^|\s)(checkout|switch)(\s|$)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Test-BranchDrift {
    <#
    .SYNOPSIS 分支有沒有在上次記錄之後被換掉？
    .DESCRIPTION
      ⚠️ **本層不知道是誰切的**（2026-09-20 更正）。狀態檔以 cwd 為鍵、所有 session 共用，
      後開的 session 其 SessionStart 會覆寫基準。所以真實語意是
      「**自上次有人記錄或基準化以來**，分支變了沒」，不是「自我開場以來」。
      這個語意夠用（09-18／09-19 兩案都抓得到），但訊息不得多說——舊版寫
      「而你這個 session 沒有切過」是工具**無從得知**的斷言，且自己 `git checkout -b`
      之後必觸發一次假 ask。
    .PARAMETER Recorded       上次記錄／基準化時的分支（來自 session-state json）
    .PARAMETER Current        現在實際的分支（來自 git rev-parse --abbrev-ref HEAD）
    .PARAMETER Pending        上一次已就「切到哪個分支」提示過使用者的目標分支。
                              等於 Current ＝ 使用者看過提示後選擇繼續 → 這次放行並由 I/O 層基準化。
    .PARAMETER RecordedBy     寫下該筆記錄的 session id
    .PARAMETER SelfSession    我是誰
    .PARAMETER StateAvailable 狀態檔可讀且可解析嗎（false 一律 fail-open）
    .OUTPUTS @{ decision = 'pass'|'ask'; why = '...' }  —— 永遠不回 deny
    #>
    param(
        [AllowEmptyString()] [string]$Recorded = '',
        [AllowEmptyString()] [string]$Current = '',
        [AllowEmptyString()] [string]$Pending = '',
        [AllowEmptyString()] [string]$RecordedBy = '',
        [AllowEmptyString()] [string]$SelfSession = '',
        [bool]$StateAvailable = $false
    )

    if (-not $StateAvailable) {
        return @{
            decision = 'pass'
            why      = '無法判定分支漂移：狀態檔缺失或損壞 → fail-open 放行（安全網不是閘門）'
        }
    }
    if ([string]::IsNullOrWhiteSpace($Recorded) -or [string]::IsNullOrWhiteSpace($Current)) {
        return @{
            decision = 'pass'
            why      = '無法判定分支漂移：開場記錄或目前分支為空 → fail-open 放行'
        }
    }
    if ($Recorded -eq $Current) {
        return @{ decision = 'pass'; why = "分支與上次記錄一致（$Current）" }
    }

    # 顯示上限，避免 1000 字元的分支名把 ask 訊息灌爆
    $shown = if ($Current.Length -gt 60) { $Current.Substring(0, 60) + '…' } else { $Current }

    # 【已提示過且使用者選擇繼續】上一次就這個目標分支問過了，這次放行。
    # 舊版在「發問的當下」就基準化，使用者答「否」完全沒有後果（下一條指令照樣 pass）——
    # 答否等於沒答。改成 pending：只有在使用者看過提示、且**仍在同一個分支上**再下一條
    # 指令時才基準化。答否後切回原分支會再被問一次，那是正確的。
    if (-not [string]::IsNullOrWhiteSpace($Pending) -and $Pending -eq $Current) {
        return @{
            decision = 'pass'
            why      = "分支漂移（$Recorded → $shown）已於上一次提示，你選擇繼續 → 重新基準化，不重複發問"
        }
    }

    $by = if ([string]::IsNullOrWhiteSpace($RecordedBy)) { '' } else { "（上次記錄者 $RecordedBy）" }
    return @{
        decision = 'ask'
        why      = "分支已從 $Recorded 變成 $shown$by——自上次記錄或基準化以來有人切過分支。" +
                   '本層不知道是誰切的：可能是另一個 session 在同一棵工作樹上動作，也可能是你自己剛切。' +
                   '⚠️ 你在原分支上改過但未提交的檔會跟著切到新分支。' +
                   '若不是你切的，繼續前請先確認對方是否收工（AGENTS.md「多 agent 並行的鐵則：序列交接」）。'
    }
}

# ── 以上為純函式（可單測）；以下為有 I/O 的外層，shim 呼叫這一層 ──

function Get-CwdStateKey {
    <#
    .SYNOPSIS 把工作目錄轉成穩定的檔名鍵（同一棵樹共用一個狀態檔）
    .DESCRIPTION
      刻意不用 Get-FileHash：pwsh 7 spawn 出來的 powershell 5.1 子行程會繼承
      PSModulePath 而找不到該 cmdlet（memory 已記，watch-credentials.ps1 同坑）。
      直接用 .NET 的 SHA256 類別。
    #>
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return 'unknown' }
    $norm = $Path.TrimEnd([char]92, [char]47).ToLowerInvariant()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $h = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($norm))
        return (($h | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 16)
    }
    finally { $sha.Dispose() }
}

function Get-BranchDriftVerdict {
    <#
    .SYNOPSIS Test-BranchDrift 的 I/O 外層：讀狀態檔、查 git，再交給純函式判定
    .DESCRIPTION
      **全程 fail-open**：任何一步取不到就回 pass。這是安全網不是閘門。

      【提示一次 → 使用者繼續才基準化】（2026-09-20 改，Fable delta 裁決 §5 #2）
      偵測到漂移時**只記 pending_drift、不動 branch**；使用者看過提示、仍在同一個分支上
      再下一條指令時，才把 branch 更新成現況。舊版在發問的當下就基準化，使用者答「否」
      之後下一條指令照樣 pass——**答否等於沒答**。
      理由：本層的目的是「讓你知道」，不是「每次都擋」。若不重新基準化，
      同一次漂移會在後續每一條 git 指令重複發問，使用者三次之後就會學會無視它
      ——那比沒有守門更糟（信任損耗不可回復）。對方若再切一次，你會再被通知一次。
    #>
    param(
        [AllowEmptyString()] [string]$Command = '',
        [AllowEmptyString()] [string]$StateDir = ''
    )
    try {
        $cwd = (Get-Location).Path
        if ([string]::IsNullOrWhiteSpace($StateDir)) {
            $StateDir = Join-Path $HOME (Join-Path '.claude' 'session-state')
        }
        $f = Join-Path $StateDir ((Get-CwdStateKey -Path $cwd) + '.json')
        if (-not (Test-Path -LiteralPath $f)) {
            return (Test-BranchDrift -StateAvailable $false)
        }

        $j = $null
        try { $j = [IO.File]::ReadAllText($f) | ConvertFrom-Json }
        catch { return (Test-BranchDrift -StateAvailable $false) }
        if ($null -eq $j -or [string]::IsNullOrWhiteSpace("$($j.branch)")) {
            return (Test-BranchDrift -StateAvailable $false)
        }

        $cur = ''
        try { $cur = "$(& git -C $cwd rev-parse --abbrev-ref HEAD 2>$null | Select-Object -First 1)".Trim() }
        catch { $cur = '' }
        if ([string]::IsNullOrWhiteSpace($cur)) {
            return (Test-BranchDrift -StateAvailable $false)
        }

        $pendingPrev = "$($j.pending_drift)"
        $v = Test-BranchDrift -Recorded "$($j.branch)" -Current $cur -Pending $pendingPrev `
            -RecordedBy "$($j.session_id)" -SelfSession "$env:CLAUDE_CODE_SESSION_ID" -StateAvailable $true

        # 狀態檔的兩種更新（都不影響判定；寫失敗只是降噪失效）：
        #  (1) ask → 只記 pending_drift，**不動 branch**。基準線要留著，
        #      否則使用者答「否」之後下一條指令照樣 pass ＝ 答否沒有任何後果。
        #  (2) 已提示過且使用者仍在同分支下指令（＝看過、選擇繼續）→ 這時才真正基準化。
        $needWrite = $false
        $newBranch = "$($j.branch)"
        $newPending = $pendingPrev
        if ($v.decision -eq 'ask') {
            $needWrite = $true; $newPending = $cur
        }
        elseif ($pendingPrev -and $pendingPrev -eq $cur) {
            $needWrite = $true; $newBranch = $cur; $newPending = ''
        }

        if ($needWrite) {
            # 重新基準化（見上方說明）。寫失敗不影響判定——這一步純粹是降噪。
            #
            # ⚠️ 踩過的坑（2026-09-19，E2E 抓到）：原本寫成 `$j.branch = $cur` 再
            # `$j.rebaselined_at = ...`。ConvertFrom-Json 回的是 PSCustomObject，
            # 對**不存在的屬性**用 `.` 指派會拋錯，而下面這個 catch 把它連同
            # branch 的更新一起吞掉 → 重新基準化從未生效、同一次漂移每條指令都重問。
            # 純函式測試抓不到（它不碰 I/O），是端到端重演才現形。
            # 修法：不去改 PSCustomObject，直接用讀到的值重建一個 ordered hashtable。
            try {
                $out = [ordered]@{
                    cwd            = "$($j.cwd)"
                    branch         = $newBranch
                    head           = "$($j.head)"
                    session_id     = "$($j.session_id)"
                    started        = "$($j.started)"
                    pending_drift  = $newPending
                    rebaselined_at = (Get-Date).ToUniversalTime().ToString('o')
                }
                [IO.File]::WriteAllText($f, ($out | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
            }
            catch { }
        }
        return $v
    }
    catch {
        return @{ decision = 'pass'; why = "分支漂移偵測本身出錯 → fail-open 放行：$($_.Exception.Message)" }
    }
}

function Write-SessionBranchState {
    <#
    .SYNOPSIS 由 SessionStart hook 呼叫：把本 session 開場看到的分支記下來
    .OUTPUTS 成功回**分支名**（非空字串）、失敗回空字串。
      ⚠️ 2026-09-20 從 $true/$false 改成 branch/''：呼叫端要把它印出來
      （Fable delta §5 #3——原本 pass 路徑完全靜音，hook 若沒生效沒有任何訊號，
      保護會靜默消失）。`[bool]` 語意不變（非空字串為真、'' 為假），既有斷言照舊成立。
    .DESCRIPTION
      放在 $HOME 不放 repo——寫進 repo 會製造髒工作樹，而髒工作樹正是這套機制
      要偵測的東西之一。全程 fail-open，寫不成就算了（下次 git 指令會走
      StateAvailable=$false 的放行路徑）。
    #>
    param(
        [AllowEmptyString()] [string]$Cwd = '',
        [AllowEmptyString()] [string]$StateDir = ''
    )
    try {
        if ([string]::IsNullOrWhiteSpace($Cwd)) { $Cwd = (Get-Location).Path }
        if (-not (Test-Path -LiteralPath (Join-Path $Cwd '.git'))) { return '' }

        $br = ''
        try { $br = "$(& git -C $Cwd rev-parse --abbrev-ref HEAD 2>$null | Select-Object -First 1)".Trim() } catch { }
        if ([string]::IsNullOrWhiteSpace($br)) { return '' }
        $head = ''
        try { $head = "$(& git -C $Cwd rev-parse --short HEAD 2>$null | Select-Object -First 1)".Trim() } catch { }

        if ([string]::IsNullOrWhiteSpace($StateDir)) {
            $StateDir = Join-Path $HOME (Join-Path '.claude' 'session-state')
        }
        if (-not (Test-Path -LiteralPath $StateDir)) {
            $null = New-Item -ItemType Directory -Path $StateDir -Force
        }
        $payload = [ordered]@{
            cwd        = $Cwd
            branch     = $br
            head       = $head
            session_id = "$env:CLAUDE_CODE_SESSION_ID"
            started    = (Get-Date).ToUniversalTime().ToString('o')
        }
        $f = Join-Path $StateDir ((Get-CwdStateKey -Path $Cwd) + '.json')
        [IO.File]::WriteAllText($f, ($payload | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
        return $br
    }
    catch { return '' }
}

# ──────────────────────────────────────────────────────────────
# Get-GuardVerdict — 對外唯一入口（介面不變）。純判定，不 exit、不輸出 JSON。
#   = 單層判定 + 殼內層展開判定，取較嚴格者。
# ──────────────────────────────────────────────────────────────
function Get-GuardVerdict {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Command,
        [int]$Depth = 0
    )
    $verdict = Get-GuardVerdictSingle -Command $Command
    if ($verdict.decision -eq 'deny') { return $verdict }   # 已最嚴格，短路

    # 空字串守衛：`cmd /c ""` 展開後為空——不遞迴（空指令無可判定），直接回單層結果。
    $inner = Expand-ShellWrapper -Command $Command
    if ([string]::IsNullOrWhiteSpace($inner)) { return $verdict }
    if ($inner -eq $Command.Trim()) { return $verdict }     # 沒有殼包裹
    if ($Depth -ge 3) { return $verdict }                   # 深度保險（Expand 已迴圈到穩定）

    $rank = @{ 'pass' = 0; 'ask' = 1; 'deny' = 2 }
    $innerVerdict = Get-GuardVerdict -Command $inner -Depth ($Depth + 1)
    if ($rank[$innerVerdict.decision] -gt $rank[$verdict.decision]) {
        return @{ decision = $innerVerdict.decision; why = "殼包裹內層：$($innerVerdict.why)" }
    }
    return $verdict
}
