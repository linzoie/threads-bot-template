#!/usr/bin/env pwsh
# ============================================================
# guard-bash.ps1  —  PreToolUse hook (matcher: Bash)
#
# 在 Claude 執行任何 bash 指令「之前」攔截危險樣式。
# 偵測到危險指令時印出說明並 exit 2（Claude Code 會因此阻擋該指令）。
# 一切正常時 exit 0。
# ============================================================
$ErrorActionPreference = 'SilentlyContinue'

# 1) 讀取 hook 由 stdin 傳入的 JSON
$raw = [Console]::In.ReadToEnd()
if (-not $raw) { exit 0 }
try { $data = $raw | ConvertFrom-Json } catch { exit 0 }

$cmd = $data.tool_input.command
if (-not $cmd) { exit 0 }

# 2) 危險樣式清單（regex；比對時不分大小寫）
$patterns = @(
    @{ rx = 'rm\s+-[rRfF]+\s+/(\s|$)';            why = 'rm -rf /（刪除根目錄）' },
    @{ rx = 'rm\s+-[rRfF]+\s+/\*';                why = 'rm -rf /*（刪除根目錄內容）' },
    @{ rx = 'rm\s+-[rRfF]+\s+~(\s|/|$)';          why = 'rm -rf ~（刪除家目錄）' },
    @{ rx = 'rm\s+-[rRfF]+\s+\$HOME';             why = 'rm -rf $HOME（刪除家目錄）' },
    @{ rx = 'rm\s+-[rRfF]+\s+\*(\s|$)';           why = 'rm -rf *（清空目前目錄）' },
    @{ rx = 'git\s+push\b.*--force(?!-with-lease)'; why = 'git push --force（請改用 --force-with-lease）' },
    @{ rx = 'git\s+push\b.*\s-f(\s|$)';           why = 'git push -f（請改用 --force-with-lease）' },
    @{ rx = 'DROP\s+(TABLE|DATABASE|SCHEMA)';     why = 'SQL DROP（破壞性結構操作）' },
    @{ rx = 'TRUNCATE\s+TABLE';                   why = 'SQL TRUNCATE（清空資料表）' },
    @{ rx = 'mkfs\.';                             why = '格式化檔案系統' },
    @{ rx = '\bdd\s+.*of=/dev/';                  why = 'dd 直接寫入磁碟裝置' },
    @{ rx = ':\(\)\s*\{\s*:\s*\|\s*:';            why = 'fork bomb' }
)

foreach ($p in $patterns) {
    if ($cmd -imatch $p.rx) {
        [Console]::Error.WriteLine("[BLOCKED] guard-bash 攔截危險指令：$($p.why)")
        [Console]::Error.WriteLine("  指令內容：$cmd")
        [Console]::Error.WriteLine("  若確實需要，請使用者自行於終端機手動執行。")
        exit 2
    }
}
exit 0