#!/usr/bin/env pwsh
# ============================================================
# guard-bash.ps1  —  PreToolUse hook (matcher: Bash|PowerShell)
#
# v3（2026-07-09 升級，vs v2）：
#   1) 同時攔截 Bash 與 PowerShell 工具的指令（兩者 stdin JSON 皆為
#      tool_input.command，故同一支腳本通吃；settings.json matcher
#      需設為 "Bash|PowerShell"）。
#   2) 三級處置：
#      - DENY（exit 2 + stderr）：災難級、不可逆、無正當日常用途
#        （刪根/家目錄、mkfs、dd 寫裝置、fork bomb、SQL DROP、force push）
#      - ASK（permissionDecision: "ask" JSON）：使用者硬規則
#        「破壞性／難復原動作一律先問」清單 —— 不擋死，強制跳出
#        確認框由使用者決定；此決定優先於 permissions.allow 自動放行。
#      - ALLOW：常見安全目標的遞迴刪除（node_modules、__pycache__、
#        dist 等建置產物、scratchpad 暫存）直接放行，避免誤殺。
#   3) 補上 v2 的繞過洞：拆開/長寫法旗標（rm -r -f、--recursive）、
#      PowerShell 刪除指令（Remove-Item -Recurse、rd /s）、
#      git reset --hard / checkout -- / clean -f / branch -D /
#      restore / stash drop / --amend / --no-verify / find -delete /
#      refspec 強推（push origin +main）/ curl|sh。
#
# 一切正常時 exit 0。解析失敗一律 fail-open（exit 0）。
# ============================================================
$ErrorActionPreference = 'SilentlyContinue'

# 1) 讀取 hook 由 stdin 傳入的 JSON
$raw = [Console]::In.ReadToEnd()
if (-not $raw) { exit 0 }
try { $data = $raw | ConvertFrom-Json } catch { exit 0 }

$cmd = $data.tool_input.command
if (-not $cmd) { exit 0 }

# A1（2026-07-11）：換行/CR 正規化成分隔符——防「echo hi<換行>rm -rf /」這類換行切段繞過
# （categorical fix：讓換行後的段落照常被逐段錨定檢查）。已知取捨：heredoc/字串字面內的
# 危險指令「文字」會被誤判 DENY（低頻可接受，非 bug）。
$cmd = $cmd -replace '[\r\n]+', ' ; '

# outcome 觀測（2026-07-11）：把每次 deny/ask 記一行到 ~/.claude/governance-logs（月檔）。
# 記 decision + why 分類（why 可能含少量指令片段如 rm 目標，但不含完整指令；且為本機私有
# log、信任層級同 debug-logs）。全程 fail-open——記 log 失敗絕不影響決策。
# 用來回答「牆有沒有被撞、ask 是否被 rubber-stamp」，是 outcome 觀測不是安全邊界。
function Write-GovLog([string]$hook, [string]$decision, [string]$why) {
    try {
        $dir = if ($env:GOVLOG_DIR) { $env:GOVLOG_DIR } else { Join-Path $HOME '.claude\governance-logs' }
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $f = Join-Path $dir ('decisions-' + (Get-Date -Format 'yyyy-MM') + '.jsonl')
        $line = @{ ts = (Get-Date -Format 'o'); hook = $hook; decision = $decision; why = $why } | ConvertTo-Json -Compress
        Add-Content -Path $f -Value $line -Encoding utf8
    } catch { }
}

function Deny([string]$why) {
    Write-GovLog 'guard-bash' 'deny' $why
    [Console]::Error.WriteLine("[BLOCKED] guard 攔截危險指令：$why")
    [Console]::Error.WriteLine("  指令內容：$cmd")
    [Console]::Error.WriteLine("  此類指令一律由使用者本人於終端機手動執行，不由 Claude 代行。")
    exit 2
}

# flooding 偵測：同一 session 短時間內 ask 過密 → 加警示前綴，對抗確認疲乏
# （arXiv:2606.08919「審查有容量上限，過度提示更不安全」）。
# 時間窗設計（非只增不減）：只算最近 N 分鐘；達門檻警示一次後重置。
# 全程 best-effort——任何錯誤回空字串，絕不影響 ask 決策本身。
# 計數檔非安全邊界：刪除即重置是可接受行為（它防的是雜訊，不是攻擊）。
function Get-AskFloodPrefix {
    try {
        $sid = $data.session_id
        if (-not $sid) { $sid = 'no-session' }
        $sid = ($sid -replace '[^A-Za-z0-9_.-]', '_')
        $stateDir = $env:GUARD_ASK_STATE_DIR
        if (-not $stateDir) { $stateDir = Join-Path ([IO.Path]::GetTempPath()) 'claude-guard-ask' }
        if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
        $threshold = if ($env:GUARD_ASK_THRESHOLD) { [int]$env:GUARD_ASK_THRESHOLD } else { 8 }
        $windowMin = if ($env:GUARD_ASK_WINDOW_MIN) { [double]$env:GUARD_ASK_WINDOW_MIN } else { 30 }
        $file = Join-Path $stateDir "$sid.txt"
        $nowTicks = [DateTime]::UtcNow.Ticks
        $cutoff = [DateTime]::UtcNow.AddMinutes(-$windowMin).Ticks
        $stamps = @()
        if (Test-Path $file) {
            # 只取合法數字行（壞行不吃掉整個累積），再濾窗口
            $stamps = @(Get-Content $file | Where-Object { $_.Trim() -match '^\d+$' } |
                ForEach-Object { [long]$_ } | Where-Object { $_ -ge $cutoff })
        }
        $stamps += $nowTicks
        if ($stamps.Count -ge $threshold) {
            Set-Content -Path $file -Value '' -Encoding utf8   # 警示後重置（警一次不連環警）
            return "⚠️ 本 session 近 $windowMin 分鐘內第 $($stamps.Count) 次確認框——留意 rubber-stamp 疲乏，逐字讀這一條再決定，別反射性同意。 "
        }
        Set-Content -Path $file -Value ($stamps -join "`n") -Encoding utf8
        return ''
    } catch { return '' }
}

function Ask([string]$why) {
    Write-GovLog 'guard-bash' 'ask' $why
    $reason = (Get-AskFloodPrefix) + "使用者硬規則「破壞性／難復原動作一律先問」：$why。請確認後再放行。"
    $out = @{
        hookSpecificOutput = @{
            hookEventName            = 'PreToolUse'
            permissionDecision       = 'ask'
            permissionDecisionReason = $reason
        }
    } | ConvertTo-Json -Depth 5 -Compress
    [Console]::Out.WriteLine($out)
    exit 0
}

# ──────────────────────────────────────────────────────────────
# 2) 遞迴刪除指令的目標分級（posix rm 與 PowerShell 刪除家族）
#    回傳 'deny' / 'ask' / 'allow' / $null（此段落非刪除指令或非遞迴）
# ──────────────────────────────────────────────────────────────
function Get-DeleteClassification([string]$segment) {
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
        $base = ($gg -split '[\\/]')[-1]
        $inScratchpad = $gg -imatch 'Temp[\\/]claude'
        if (-not (($base -imatch $safeNames) -or $inScratchpad)) { $allSafe = $false }
    }
    if ($allSafe) { return 'allow' }
    return 'ask'
}

# 以 ; && || | 及單一 & 切段，逐段檢查刪除指令
# （2026-07-24：補單一 & 繞法——`echo hi & rm -rf /` 在 bash（背景符）與 cmd（串接符）下都會執行，
#  原 splitter 漏切單 &，使 echo 前綴把整段當非刪除放行。&(?!&) 只切單 &、不誤切 &&；
#  denyPatterns 對整串 $cmd 比對故不受影響，本切段只餵刪除分類器。）
$segments = [regex]::Split($cmd, '\s*(?:;|&&|\|\||\||&(?!&))\s*')
foreach ($seg in $segments) {
    $cls = Get-DeleteClassification $seg
    if ($cls -eq 'deny')  { Deny  "遞迴刪除根目錄／家目錄／整個目前目錄（$($seg.Trim())）" }
    if ($cls -eq 'ask')   { Ask   "遞迴刪除檔案／目錄（$($seg.Trim())）" }
    # 'allow'（安全目標）與 $null（非刪除）都繼續往下檢查其他樣式
}

# ──────────────────────────────────────────────────────────────
# 3) DENY 樣式：災難級、不可逆
# ──────────────────────────────────────────────────────────────
$denyPatterns = @(
    @{ rx = 'git\s+push\b[^;&|]*(--force(?!-with-lease)\b|\s-f\b)'; why = 'git push --force / -f（覆蓋遠端歷史；如有需要請改 --force-with-lease 並經使用者確認）' },
    @{ rx = 'git\s+push\b[^;&|]*\s\+\S+';       why = 'git push refspec 強推（+branch 等同 --force）' },
    @{ rx = '\bDROP\s+(TABLE|DATABASE|SCHEMA)\b'; why = 'SQL DROP（破壞性結構操作）' },
    @{ rx = '\bTRUNCATE\s+TABLE\b';             why = 'SQL TRUNCATE（清空資料表）' },
    @{ rx = '\bmkfs(\.|\s)';                    why = '格式化檔案系統' },
    @{ rx = '\bdd\s+[^;&|]*of=/dev/';           why = 'dd 直接寫入磁碟裝置' },
    @{ rx = 'format-volume|clear-disk|initialize-disk'; why = 'PowerShell 磁碟格式化／清除' },
    @{ rx = ':\(\)\s*\{\s*:\s*\|\s*:';          why = 'fork bomb' },
    # 機密外洩（2026-07-11 依社群研究補；deny 級連 --dangerously-skip-permissions 都擋得住）：
    # 把機密檔上傳到網路——幾乎無正當日常用途
    @{ rx = '(curl|wget|iwr|invoke-webrequest)\b[^;&|]*(-T\s|--upload-file|-d\s*@|--data(-binary|-raw|-urlencode)?[= ]@|-F\s+[^;&|]*@)[^;&|]*(\.env|\.pem|\.key|id_rsa|id_ed25519|credentials|\.pfx|secrets?\.(json|ya?ml))'; why = '把機密檔（.env/私鑰/憑證）上傳到網路' }
)
foreach ($p in $denyPatterns) {
    if ($cmd -imatch $p.rx) { Deny $p.why }
}

# ──────────────────────────────────────────────────────────────
# 4) ASK 樣式：使用者「先問」清單 → 強制確認框
# ──────────────────────────────────────────────────────────────

# SQL 整表刪除：DELETE FROM 無 WHERE（2026-07-11 紅隊實測穿透後補）
if ($cmd -imatch '\bDELETE\s+FROM\b' -and $cmd -inotmatch '\bWHERE\b') {
    Ask 'DELETE FROM 無 WHERE 條件（整表刪除）'
}

# 機密讀取/傾印（2026-07-11 依社群研究補）：讀機密檔或傾印含 token 的環境變數。
# 這些有正當除錯用途（故用 ask 不用 deny），但輸出可能進 log/被截圖外流，先問。
# .env.example / .sample / .template / .pub 是公開範本，豁免。
if ($cmd -imatch '(^|[\s;&|])(cat|type|bat|less|more|head|tail|get-content|gc)\b[^;&|]*\.env\b' `
        -and $cmd -inotmatch '\.env\.(example|sample|template)\b') {
    Ask '讀取 .env（可能含 token／金鑰，輸出恐外流）'
}
if ($cmd -imatch '(^|[\s;&|])(cat|type|bat|get-content|gc)\b[^;&|]*(id_rsa|id_ed25519|id_ecdsa|\.pem\b|\.pfx\b|\.p12\b|(?<!\.pub)\.key\b|credentials[^;&|]*\.json|secrets?\.(json|ya?ml|toml))' `
        -and $cmd -inotmatch '\.(pub|example|sample|template)\b') {
    Ask '讀取私鑰／憑證／機密檔（輸出恐外流）'
}
if ($cmd -imatch '\bprintenv\b' -or $cmd -imatch '(get-childitem|gci|ls|dir)\s+env:' -or $cmd -imatch '\benv\s*$') {
    Ask '傾印全部環境變數（可能含 token／金鑰）'
}
if ($cmd -imatch '(echo|write-output|write-host)\s+["'']?\$(\{)?(env:)?\w*(TOKEN|SECRET|KEY|PASSWORD|PASSWD|APIKEY|API_KEY|CREDENTIAL)') {
    Ask 'echo 含機密的環境變數（輸出恐外流）'
}

# A2b（2026-07-11）：bash -c / sh -c 包裹破壞性指令 → ASK（保守：不遞迴解析內層引號，
# 僅偵測「殼包裹旗標」與破壞性動詞共現。巢狀/base64/變數間接為已知殘留，見 guard-cases）。
if ($cmd -imatch '\b(ba|z|da)?sh\s+-[a-z]*c\b' `
        -and $cmd -imatch '\brm\s+-[a-zA-Z]*[rf]|\bmkfs(\.|\s)|\bdd\s+[^;&|]*of=/dev/|\bDROP\s+(TABLE|DATABASE|SCHEMA)\b|:\(\)\s*\{\s*:') {
    Ask 'bash -c/sh -c 包裹疑似破壞性指令（保守攔截，請確認內層安全）'
}

# A3（2026-07-11）：讀機密 × 送網路 組合 → ASK（精確 curl 上傳已在 DENY 段；此處補
# scp/rsync/python/node/--post-file/http.server 等非 curl 管道。排除 curl/wget 下載目標
# `-o/-O/--output/>` 免誤殺「下載存成 .pem/.key」）。heuristic 故用 ASK 不用 DENY。
$a3secret   = '\.env\b|\.pem\b|(?<!\.pub)\.key\b|id_rsa|id_ed25519|credentials|\.pfx\b|secrets?\.(json|ya?ml)'
$a3send     = '\b(scp|rsync|nc|ncat|telnet)\b|--post-file|\bhttp\.server\b|-m\s+http\.server|\b(python[0-9.]*|node|php|ruby)\b[^;&|]*(requests|urllib|urlopen|http\b|fetch|socket|net/http)'
$a3download = '\b(curl|wget)\b[^;&|]*(-o\b|-O\b|--output\b|>)'
if ($cmd -imatch $a3secret -and $cmd -imatch $a3send -and $cmd -inotmatch $a3download) {
    Ask '疑似把機密檔（.env/私鑰/憑證）送出網路（scp/rsync/python/wget --post-file 等）'
}

# git restore：只有「純 --staged（不含 --worktree）」是安全的取消暫存
if ($cmd -imatch 'git\s+restore\b') {
    $isStagedOnly = ($cmd -imatch '--staged') -and ($cmd -inotmatch '--worktree')
    if (-not $isStagedOnly) { Ask 'git restore（會丟棄工作區未提交的修改）' }
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
    @{ rx = '(curl|wget|iwr|invoke-webrequest)\b[^;&|]*\|\s*(ba|z|da)?sh\b'; why = '下載內容直接餵給 shell 執行（供應鏈風險）' },
    @{ rx = '(iwr|invoke-webrequest|downloadstring)[^;&|]*\|\s*iex\b';       why = '下載內容直接 Invoke-Expression（供應鏈風險）' },
    # A2b 延伸（2026-07-11）：解碼器/產生器管道餵 shell（混淆執行）→ ASK
    @{ rx = '(base64\s+-d|base64\s+--decode|xxd\s+-r|printf\b)[^;&|]*\|\s*(ba|z|da)?sh\b'; why = 'base64/printf 等解碼產生後直接餵 shell 執行（混淆式供應鏈風險）' }
)
foreach ($p in $askPatterns) {
    if ($cmd -imatch $p.rx) { Ask $p.why }
}

exit 0
