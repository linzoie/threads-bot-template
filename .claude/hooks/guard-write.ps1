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
function Write-GovLog([string]$hook, [string]$decision, [string]$why, [string]$target = '') {
    try {
        # 2026-07-31：env 重導向限 TEMP（settings 的 env 區塊是隱性不可信輸入，防守門 log 被導走）
        $dir = Join-Path $HOME '.claude\governance-logs'
        if ($env:GOVLOG_DIR) { try { $c = [IO.Path]::GetFullPath($env:GOVLOG_DIR); if ($c.StartsWith([IO.Path]::GetFullPath(([IO.Path]::GetTempPath())), [System.StringComparison]::OrdinalIgnoreCase)) { $dir = $c } } catch { } }
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $f = Join-Path $dir ('decisions-' + (Get-Date -Format 'yyyy-MM') + '.jsonl')
        $rec = @{ ts = (Get-Date -Format 'o'); hook = $hook; decision = $decision; why = $why }
        # 只在有值時才加欄位：舊紀錄沒有 target，讀取端要能容忍缺欄（別讓新欄位變成必填）
        if (-not [string]::IsNullOrWhiteSpace($target)) { $rec['target'] = $target }
        $line = $rec | ConvertTo-Json -Compress
        Add-Content -Path $f -Value $line -Encoding utf8
    } catch { }
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
