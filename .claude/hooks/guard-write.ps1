#!/usr/bin/env pwsh
# ============================================================
# guard-write.ps1  —  PreToolUse hook (matcher: Edit|Write|MultiEdit)
#
# S4a（2026-07-11）：保護治理層自身。防「模型自主編輯 hook/settings/agent/
# governance 檔」而**靜默自我繳械**（例如在 guard-bash.ps1 頂端插 exit 0，
# 下個 session 重啟後全線放行）。命中受保護路徑 → ASK（強制使用者確認）。
#
# 受保護：.claude/{hooks,agents}/、任何 settings.json、
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
$protectRx = '[\\/]\.claude[\\/](hooks|agents)[\\/]|[\\/]settings\.json$|[\\/]\.governance[\\/](project-template|bin|tests)[\\/]'

if ($fp -imatch $protectRx) {
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
