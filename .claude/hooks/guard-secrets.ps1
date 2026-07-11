#!/usr/bin/env pwsh
# ============================================================
# guard-secrets.ps1  —  PreToolUse hook (matcher: Bash|PowerShell)
#
# 機密防線（2026-07-09 新增）：把「絕不 commit .env / token / 金鑰」
# 從 CLAUDE.md 的文字鐵則升級為機械強制。只在指令涉及
# `git add` / `git commit` 時介入，其餘一律放行（exit 0）。
#
#   - git add <目標> 含敏感檔名          → DENY（exit 2）
#   - git add -A / --all / . / *         → 用 git status --porcelain 檢查
#     「將被加入」的檔案有無敏感檔名     → 有則 DENY
#     （注意：已被 .gitignore 正確忽略的 .env 不會出現在 porcelain，
#       所以不會誤擋 —— 只有「危險地未被忽略」時才會攔。）
#   - git commit                          → 檢查已暫存檔名 + 暫存 diff
#     新增行中的 token 樣式               → 命中則 DENY
#
# 誤判時的出路（stderr 會說明）：使用者確認後自行手動執行，
# 或把檔案正確加入 .gitignore。解析／git 呼叫失敗一律 fail-open。
# ============================================================
$ErrorActionPreference = 'SilentlyContinue'

$raw = [Console]::In.ReadToEnd()
if (-not $raw) { exit 0 }
try { $data = $raw | ConvertFrom-Json } catch { exit 0 }

$cmd = $data.tool_input.command
if (-not $cmd) { exit 0 }

# 快篩：不含 git add / git commit 就直接放行
if ($cmd -inotmatch 'git\b[^;&|]*\b(add|commit)\b') { exit 0 }

function DenySecrets([string]$why, [string[]]$hits) {
    [Console]::Error.WriteLine("[BLOCKED] guard-secrets 機密防線：$why")
    foreach ($h in $hits) { [Console]::Error.WriteLine("  - $h") }
    [Console]::Error.WriteLine("  處置：確認這些檔案／內容不是機密；若是機密請加入 .gitignore 並移出暫存區，")
    [Console]::Error.WriteLine("        若確為誤判（如文件中的示例 token），請使用者確認後自行手動執行。")
    exit 2
}

# 敏感「檔名」樣式（對路徑的任一層生效）；.example/.sample/.template 豁免
# A6（2026-07-11）：.env 家族放寬——涵蓋 prod.env / my.env / config.env.local / .envrc
#   （`[^\\/]*\.env` 需字面 .env，故 environment.ts / .eslintrc 不誤中）。
$sensitiveNameRx = '(^|[\\/])([^\\/]*\.env(rc)?(\.[^\\/]+)?|id_rsa|id_ed25519|id_ecdsa|[^\\/]*\.(pem|key|pfx|p12)|credentials[^\\/]*\.json|tokens?[^\\/]*\.json|secrets?\.(json|ya?ml|toml))$'
$exemptNameRx    = '\.(example|sample|template)$|\.pub$'

function Test-SensitiveName([string]$path) {
    if ($path -imatch $exemptNameRx) { return $false }
    return ($path -imatch $sensitiveNameRx)
}

# 敏感「內容」樣式（只掃暫存 diff 的新增行）
$tokenPatterns = @(
    @{ rx = 'sk-ant-[A-Za-z0-9_-]{20,}';                 why = 'Anthropic API key' },
    @{ rx = '\bsk-[A-Za-z0-9]{32,}';                     why = 'OpenAI 式 API key' },
    @{ rx = 'ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}'; why = 'GitHub token' },
    @{ rx = 'xox[baprs]-[A-Za-z0-9-]{10,}';              why = 'Slack token' },
    @{ rx = 'AKIA[0-9A-Z]{16}';                          why = 'AWS access key' },
    @{ rx = 'AIza[0-9A-Za-z_-]{35}';                     why = 'Google API key' },
    @{ rx = '-----BEGIN [A-Z ]*PRIVATE KEY-----';        why = '私鑰內容' },
    @{ rx = 'eyJ[A-Za-z0-9_-]{20,}\.eyJ[A-Za-z0-9_-]{20,}'; why = 'JWT' }
)

# 決定 git 工作目錄：優先 `git -C <path>`，其次段落前的 `cd <path>`，最後 hook cwd
# A7（2026-07-11）：`-C` 用 -cmatch 大小寫敏感——`git -c config`（小寫）不再被誤當
#   gitDir 而 fail-open 放行機密；且假路徑不 exit，改 fallback 到 cwd（fail-closed）。
$gitDir = $null
if ($cmd -cmatch 'git\s+-C\s+("([^"]+)"|''([^'']+)''|(\S+))') {
    $gitDir = @($Matches[2], $Matches[3], $Matches[4]) | Where-Object { $_ } | Select-Object -First 1
}
if (-not $gitDir -and $cmd -imatch '(^|[;&|]\s*)cd\s+("([^"]+)"|''([^'']+)''|(\S+))\s*(&&|;)') {
    $gitDir = @($Matches[3], $Matches[4], $Matches[5]) | Where-Object { $_ } | Select-Object -First 1
}
if (-not $gitDir) { $gitDir = $data.cwd }
if (-not $gitDir) { $gitDir = (Get-Location).Path }
# 假路徑不 fail-open（放過機密）——退回 cwd 照常掃描
if (-not (Test-Path -LiteralPath $gitDir)) { $gitDir = (Get-Location).Path }

# ──────────────────────────────────────────────────────────────
# 檢查 1：git add
# ──────────────────────────────────────────────────────────────
if ($cmd -imatch 'git\b[^;&|]*\badd\b') {
    # 取出 add 之後的參數
    $addPart = ($cmd -split 'git\b[^;&|]*\badd\b', 2, 'IgnoreCase')[1]
    if ($null -ne $addPart) {
        $addPart = ($addPart -split '[;&|]')[0]
        $tokens = ($addPart -split '\s+') | Where-Object { $_ }
        $isBulk = $false
        $targets = @()
        foreach ($tok in $tokens) {
            $tk = $tok.Trim('"', "'")
            if ($tk -match '^-(A|a)$|^--all$|^--no-ignore-removal$') { $isBulk = $true; continue }
            if ($tk -match '^-') { continue }
            if ($tk -eq '.' -or $tk -eq '*' -or $tk -eq './' ) { $isBulk = $true; continue }
            $targets += $tk
        }

        # 1a) 具名目標直接比對敏感檔名
        $hits = @($targets | Where-Object { Test-SensitiveName $_ })
        if ($hits.Count -gt 0) {
            DenySecrets 'git add 的目標含敏感檔案' $hits
        }

        # 1b) 批次加入（-A / . / *）→ 檢查將被加入的檔案
        if ($isBulk) {
            $porcelain = & git -C "$gitDir" status --porcelain -uall 2>$null
            if ($LASTEXITCODE -eq 0 -and $porcelain) {
                $pending = @()
                foreach ($line in $porcelain) {
                    if ($line.Length -lt 4) { continue }
                    $p = $line.Substring(3).Trim('"')
                    if (Test-SensitiveName $p) { $pending += $p }
                }
                if ($pending.Count -gt 0) {
                    DenySecrets 'git add 批次加入將把敏感檔案掃進暫存區（這些檔案未被 .gitignore 忽略！）' $pending
                }
            }
        }
    }
}

# ──────────────────────────────────────────────────────────────
# 檢查 2：git commit → 掃描已暫存的檔名與內容
# ──────────────────────────────────────────────────────────────
if ($cmd -imatch 'git\b[^;&|]*\bcommit\b') {
    $staged = & git -C "$gitDir" diff --cached --name-only 2>$null
    if ($LASTEXITCODE -eq 0 -and $staged) {
        # 2a) 暫存檔名
        $nameHits = @($staged | Where-Object { Test-SensitiveName $_ })
        if ($nameHits.Count -gt 0) {
            DenySecrets '暫存區含敏感檔案，禁止 commit' $nameHits
        }
        # 2b) 暫存內容的新增行掃 token 樣式
        $diff = & git -C "$gitDir" diff --cached --no-color -U0 2>$null
        if ($LASTEXITCODE -eq 0 -and $diff) {
            $contentHits = @()
            foreach ($line in $diff) {
                if ($line -notmatch '^\+' -or $line -match '^\+\+\+') { continue }
                foreach ($tp in $tokenPatterns) {
                    if ($line -cmatch $tp.rx) {
                        $preview = if ($line.Length -gt 80) { $line.Substring(0, 80) + '…' } else { $line }
                        $contentHits += "$($tp.why)：$preview"
                        break
                    }
                }
            }
            if ($contentHits.Count -gt 0) {
                DenySecrets '暫存的變更內容疑似含 token／金鑰，禁止 commit' $contentHits
            }
        }
    }
}

exit 0
