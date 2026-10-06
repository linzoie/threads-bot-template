#!/usr/bin/env pwsh
# ============================================================
# guard-write.ps1  —  PreToolUse hook (matcher: Edit|Write|MultiEdit)
#
# S4a（2026-07-11）：保護治理層自身。防「模型自主編輯 hook/settings/agent/
# governance 檔」而**靜默自我繳械**（例如在 guard-bash.ps1 頂端插 exit 0，
# 下個 session 重啟後全線放行）。命中受保護路徑 → ASK（強制使用者確認）。
#
# 受保護：.claude/{hooks,agents}/、任何 settings.json／settings.local.json／
#         managed-settings.json（三種載體同享 permissions/hooks/env 效力，缺一即繞道
#         ——settings.local.json 曾是零確認框自我核准通道，2026-07-31 補），
#         .governance/{project-template,bin,tests}/（執行邏輯與其來源/散佈/測試）。
#   （.governance/{reports,golden-tasks,handoff} 屬文件、頻繁編輯，不保護。）
#
# 誠實邊界（非閉環）：模型仍可 Write 到他處再 `mv` 進 hooks 目錄——但 mv 走
#   guard-bash（PreToolUse Bash）。本 hook 只擋直接 Edit/Write 受保護路徑。
# 解析失敗一律 fail-open（exit 0）。
# ============================================================
$ErrorActionPreference = 'SilentlyContinue'

$raw = [Console]::In.ReadToEnd()
if (-not $raw) { exit 0 }
try { $data = $raw | ConvertFrom-Json } catch { exit 0 }

# Edit/Write/MultiEdit 都用 tool_input.file_path
$fp = $data.tool_input.file_path
if (-not $fp) { exit 0 }

# 反斜線與正斜線都要涵蓋（Windows 上 file_path 為反斜線——這是 S4a 的關鍵）
$protectRx = '[\\/]\.claude[\\/](hooks|agents)[\\/]|[\\/](managed-)?settings(\.local)?\.json$|[\\/]\.governance[\\/](project-template|bin|tests)[\\/]'

# outcome 觀測（2026-07-11）：記 ask 到 governance-logs。fail-open。
#
# 【2026-09-20 補 target 欄】起因：使用者被確認框打斷打字，事後問「我剛剛批准了什麼」
# ——而 log 只有 hook／decision／ts，**答不出來**，只能靠檔案 mtime 反推。
# 守門有動作卻查不到它對什麼動作，等於沒有事後可稽核性。
#
# ⚠️ **這個「記路徑」的決定只適用本檔，不得外推到 guard-secrets／guard-read-secrets**：
#   - 本檔的 target 必定是**受保護治理檔**（.claude/hooks、settings、.governance/{bin,tests,
#     project-template}），依定義不是機密；而且同一個路徑本來就已經印在使用者看到的
#     確認框裡（下方 $reason 的「檔案：$fp」），記進 log 不增加任何暴露面。
#   - guard-secrets.ps1 檔頭明寫「**不記檔名/內容，避免洩密**」，那是刻意的相反決定：
#     它處理的正是機密檔。兩者不可統一（memory: rule-compression-drops-exceptions——
#     把六份 Write-GovLog 重構成一份共用時，最容易靜默丟掉的就是這種但書）。
# 2026-09-22：StartsWith(TEMP) 不解析 reparse point——%TEMP% 內一個 junction 就能把 log 導到 TEMP 外。
# 逐層檢查既存祖先，任一是 reparse point（junction／symlink）即拒（讀不到＝fail-closed）。
function Test-NoReparseUnderTemp([string]$full, [string]$tmpRoot) {
    $stop = $tmpRoot.TrimEnd('\', '/'); $p = $full
    while ($p -and $p.StartsWith($stop, [System.StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $p) { try { if ((Get-Item -LiteralPath $p -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false } } catch { return $false } }
        $parent = [IO.Path]::GetDirectoryName($p); if (-not $parent -or $parent -eq $p) { break }; $p = $parent
    }
    return $true
}

function Write-GovLog([string]$hook, [string]$decision, [string]$why, [string]$target = '') {
    try {
        # 2026-07-31：env 重導向限 TEMP（settings 的 env 區塊是隱性不可信輸入，防守門 log 被導走）；2026-09-22 補 junction 解析
        $dir = Join-Path $HOME '.claude\governance-logs'
        if ($env:GOVLOG_DIR) { try { $c = [IO.Path]::GetFullPath($env:GOVLOG_DIR); $tr = [IO.Path]::GetFullPath(([IO.Path]::GetTempPath())); if ($c.StartsWith($tr, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-NoReparseUnderTemp $c $tr)) { $dir = $c } } catch { } }
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $f = Join-Path $dir ('decisions-' + (Get-Date -Format 'yyyy-MM') + '.jsonl')
        $rec = @{ ts = (Get-Date -Format 'o'); hook = $hook; decision = $decision; why = $why }
        # 只在有值時才加欄位：舊紀錄沒有 target，讀取端要能容忍缺欄（別讓新欄位變成必填）
        if (-not [string]::IsNullOrWhiteSpace($target)) { $rec['target'] = $target }
        $line = $rec | ConvertTo-Json -Compress
        Add-Content -Path $f -Value $line -Encoding utf8
    } catch { }
}

# 2026-10-02（webfetch-preapproval spec §2「自我核准的縫」；2026-10-02 修補簡報
# F6）：claude-guard-webfetch 目錄（WebFetch 預放行檔＋既有 session dedup
# state）只准 guard-mcp.ps1 本身與使用者在終端親手執行的
# .governance/bin/preapprove-webfetch.ps1 寫入；Write／Edit／MultiEdit 對該目錄
# 一律 DENY（比下面 S4a 的治理檔保護更嚴格——那組是 ASK，因為使用者可能真的要
# 改治理檔，這裡沒有那個正當情境）。
#
# 正規化後再比對（F6）：小寫化、正斜線化、去 `\\?\`／`//?/` 長路徑前綴、去尾點，
# 讓 `\\?\C:\...\CLAUDE-GUARD-WEBFETCH\x`、大小寫變體、尾點變體都躲不掉——原版
# 只比對原始字面，這些變形未實測過，審查列為待補。
# 邊界只要求「前面」是斜線或字串起點，**不要求後面也接斜線**（能命中目錄本身，
# 或尾點被去除後落在字串結尾的情況）；但後面若有其他字元，仍要求是斜線或字串
# 結尾，避免誤殺單純提到這個詞彙的一般檔名／文件（例如
# notes-about-claude-guard-webfetch-design.md 前後接的是連字號，不是這個目錄
# 底下的檔案）。
function Test-PathHasWebfetchDir([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return $false }
    $n = $path.ToLowerInvariant()
    $n = $n -replace '^\\\\\?\\', ''
    $n = $n -replace '^//\?/', ''
    $n = $n -replace '\\', '/'
    $n = $n.TrimEnd('.')
    return [bool]($n -match '(^|/)claude-guard-webfetch(/|$)')
}
if (Test-PathHasWebfetchDir $fp) {
    Write-GovLog 'guard-write' 'deny' '寫入 WebFetch 預放行檔目錄（claude-guard-webfetch）' "$fp"
    [Console]::Error.WriteLine('[BLOCKED] guard-write 攔截：claude-guard-webfetch 目錄只准使用者親手執行 .governance/bin/preapprove-webfetch.ps1 寫入，Write/Edit/MultiEdit 一律拒絕。')
    [Console]::Error.WriteLine("  檔案：$fp")
    exit 2
}

if ($fp -imatch $protectRx) {
    Write-GovLog 'guard-write' 'ask' '寫入受保護治理檔' "$fp"
    $reason = "使用者硬規則「保護治理層自身」：正在寫入治理檔（hook/settings/agent/governance）" +
              "——這會改動安全防線本身，請確認不是被誘導的自我繳械後再放行。檔案：$fp"
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
exit 0
