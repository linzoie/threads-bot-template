#!/usr/bin/env pwsh
# ============================================================
# guard-core.ps1 — 危險指令守門「純判定核心」
#
# 從 guard-bash.ps1 抽出的純判定邏輯，供各 agent adapter（Claude／
# Antigravity／Codex）共用。**純函式、無副作用**：
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
        $t = $t -replace '^(sudo|nohup|time|command|exec|env|stdbuf\s+\S+|nice(\s+-n\s+-?\d+)?)\s+', ''  # 裸 wrapper
        $t = $t -replace '^timeout(\s+(-{1,2}\S+|\d+[smhd]?))*\s+', ''                            # timeout [flags/時長…] cmd
        $t = $t -replace '^\\(?=\w)', ''                                                          # \rm -> rm
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
        @{ rx = '\b(powershell|pwsh)(\.exe)?\b[^;&|]*\s-(e|ec|enc|encoded|encodedcommand)\b'; why = 'PowerShell -EncodedCommand（base64 指令，內容不可靜態判定）' }
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
