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

function Deny([string]$why) {
    [Console]::Error.WriteLine("[BLOCKED] guard 攔截危險指令：$why")
    [Console]::Error.WriteLine("  指令內容：$cmd")
    [Console]::Error.WriteLine("  此類指令一律由使用者本人於終端機手動執行，不由 Claude 代行。")
    exit 2
}

function Ask([string]$why) {
    $reason = "使用者硬規則「破壞性／難復原動作一律先問」：$why。請確認後再放行。"
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
    $t = $segment.Trim()
    $isPosixRm = $t -imatch '^(sudo\s+)?rm(\.exe)?\s'
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

# 以 ; && || | 切段，逐段檢查刪除指令
$segments = [regex]::Split($cmd, '\s*(?:;|&&|\|\||\|)\s*')
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
    @{ rx = ':\(\)\s*\{\s*:\s*\|\s*:';          why = 'fork bomb' }
)
foreach ($p in $denyPatterns) {
    if ($cmd -imatch $p.rx) { Deny $p.why }
}

# ──────────────────────────────────────────────────────────────
# 4) ASK 樣式：使用者「先問」清單 → 強制確認框
# ──────────────────────────────────────────────────────────────

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
    @{ rx = '(curl|wget|iwr|invoke-webrequest)\b[^;&|]*\|\s*(ba|z|da)?sh\b'; why = '下載內容直接餵給 shell 執行（供應鏈風險）' },
    @{ rx = '(iwr|invoke-webrequest|downloadstring)[^;&|]*\|\s*iex\b';       why = '下載內容直接 Invoke-Expression（供應鏈風險）' }
)
foreach ($p in $askPatterns) {
    if ($cmd -imatch $p.rx) { Ask $p.why }
}

exit 0
