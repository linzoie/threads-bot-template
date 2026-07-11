#!/usr/bin/env pwsh
# ============================================================
# guard-mcp.ps1  —  PreToolUse hook (matcher: mcp__.*|WebFetch)
#
# S1（2026-07-11）：對外通道執法者。評估報告 B1——環境掛 Gmail(發信)/Drive(寫檔)/
# Notion/Figma/Calendar/Plaud 等 MCP，PreToolUse 原本只認 Bash|PowerShell，這些
# 對外/寫入通道零攔截，「對外發送先問」只有 CLAUDE.md 文字無執法者。
#
# 策略（fail-closed）：
#   - 唯讀動作（get/list/search/read/query/fetch/whoami + download_file_content/
#     suggest_time）→ 放行（exit 0）。
#   - 其餘 MCP 動作（create/send/update/delete/upload/label… 寫入或對外）→ ASK。
#   - **未知 MCP 動作**（不在唯讀白名單）→ 一律 ASK（使用者選 fail-closed）。
#   - WebFetch（對外抓取，可能 SSRF/資料外送）→ ASK。
# 解析失敗一律 fail-open（exit 0）——不因 hook 自身錯誤卡住工具。
# ============================================================
$ErrorActionPreference = 'SilentlyContinue'

$raw = [Console]::In.ReadToEnd()
if (-not $raw) { exit 0 }
try { $data = $raw | ConvertFrom-Json } catch { exit 0 }

$tool = $data.tool_name
if (-not $tool) { exit 0 }

# outcome 觀測（2026-07-11）：記 ask 到 governance-logs（記 tool_name，屬非機密）。fail-open。
function Write-GovLog([string]$hook, [string]$decision, [string]$why) {
    try {
        $dir = if ($env:GOVLOG_DIR) { $env:GOVLOG_DIR } else { Join-Path $HOME '.claude\governance-logs' }
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $f = Join-Path $dir ('decisions-' + (Get-Date -Format 'yyyy-MM') + '.jsonl')
        $line = @{ ts = (Get-Date -Format 'o'); hook = $hook; decision = $decision; why = $why } | ConvertTo-Json -Compress
        Add-Content -Path $f -Value $line -Encoding utf8
    } catch { }
}

function AskMcp([string]$why) {
    Write-GovLog 'guard-mcp' 'ask' $why
    $out = @{
        hookSpecificOutput = @{
            hookEventName            = 'PreToolUse'
            permissionDecision       = 'ask'
            permissionDecisionReason = "使用者硬規則「對外發送／寫入先問」：$why。請確認後再放行。"
        }
    } | ConvertTo-Json -Depth 5 -Compress
    [Console]::Out.WriteLine($out)
    exit 0
}

# WebFetch：對外抓取
if ($tool -eq 'WebFetch') { AskMcp 'WebFetch 對外抓取網路內容（可能觸發 SSRF 或把 context 送到外部 URL）' }

# 非 MCP 工具（理論上 matcher 不會送來）→ 放行
if ($tool -notmatch '^mcp__') { exit 0 }

# 取動作名（最後一段），判斷唯讀白名單
$action = ($tool -split '__')[-1]
# 唯讀：get/list/search/read/query/fetch/whoami（-/_ 皆可為分隔），加白名單特例
$readonlyRx = '(^|[-_])(get|list|search|read|query|fetch|whoami)([-_]|$)|^(download_file_content|suggest_time|get_current_user)$'
if ($action -imatch $readonlyRx) { exit 0 }

# 其餘（寫入/對外/未知）→ ASK
AskMcp "MCP 寫入／對外動作『$tool』（clean 唯讀清單外一律先確認）"
exit 0
