#!/usr/bin/env pwsh
# ============================================================
# record-reads.ps1  —  PostToolUse hook
#   建議 matcher: Read|Grep|Glob|Edit|Write|MultiEdit|NotebookEdit
#
# 2026-07-30：「未讀檔斷言偵測器」的**寫入端**（設計見 .governance/specs/
# 2026-07-30-unread-claim-detector.md）。detect-unread-claim.ps1（Stop）是讀側；
# 本檔把「本 session 實際看過哪些檔」累積成 per-session 集合，供讀側比對
# 「你在提案裡斷言了某支腳本的行為，但你從沒開過它」。
#
# 【為何欄位名要「寬容收集」而不是精確指定】
# Claude Code 官方 hooks 文件**沒有**記載 Read／Grep／Glob 的 tool_input 欄位名
# （2026-07-30 查證：Stop 的 last_assistant_message 與 exit 2 行為有明文，
# PostToolUse 的 per-tool 欄位名那段查不到）。與其憑工具 schema 推論一個名字然後
# 賭它對——那正是本偵測器要治的病——這裡**把所有合理候選都讀一遍**
# （file_path / path / notebook_path），有值就用。這樣「欄位名到底叫什麼」
# 從一個未驗證前提降級成無關緊要的實作細節。
#
# 【為何 Edit/Write 也算「看過」】Edit 工具本身要求先 Read 過該檔；Write 則是自己
# 產生內容。兩者都代表模型對該檔有一手認識。收得寬 → 讀側誤報少（fail-safe 方向）。
#
# 【Grep/Glob 的 path 通常是目錄，不是檔案】只有在 path 實際指向**檔案**時才記；
# 指向目錄代表「掃過那個範圍」，不等於「看過某個特定檔的內容」，記了會讓讀側漏報。
#
# 【fail-safe 方向——本檔壞掉必須讓讀側「放行」而非「擋住」】
# 任何一步失敗都靜默 exit 0。後果是集合永遠是空的；讀側**必須**把「集合不存在或為空」
# 判成「不確定 → 放行」（見 detect-unread-claim.ps1 的 fail-safe 段）。
# ⚠️ 這與 record-webfetch.ps1 的降級方向**相反**，因為失效後果不同：
# 那邊變鬆＝多問使用者幾次；這邊若變嚴＝**每個回合都被擋，session 卡死**。
#
# 【威脅模型】state 檔是 %TEMP% 下純文字，任何能執行指令的行為者（含被守的 agent
# 自己）都能自行寫入來偽造「我讀過了」。本控制只降低「無心的未查證提案」發生率，
# 不是對抗刻意繞過的安全邊界。
# ============================================================
$ErrorActionPreference = 'SilentlyContinue'

$raw = [Console]::In.ReadToEnd()
if (-not $raw) { exit 0 }
try { $data = $raw | ConvertFrom-Json } catch { exit 0 }

$tool = "$($data.tool_name)"
$readish = @('Read', 'Grep', 'Glob', 'Edit', 'Write', 'MultiEdit', 'NotebookEdit')
if ($readish -notcontains $tool) { exit 0 }   # 防禦性；matcher 理論上已過濾

# 防禦性失敗檢查（同 record-webfetch.ps1）：失敗的呼叫不算「看過」。
# PostToolUse 依官方文件只在工具成功後觸發，但版本行為非契約，多一層保險。
$resp = $data.tool_response
if ($resp) {
    if ($resp.is_error -eq $true) { exit 0 }
    if ($resp.isError -eq $true) { exit 0 }
    if ($resp.error) { exit 0 }
}

# 寬容收集所有合理的路徑欄位（見檔頭說明）
$ti = $data.tool_input
if (-not $ti) { exit 0 }
$cands = @($ti.file_path, $ti.path, $ti.notebook_path) | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") }
if ($cands.Count -eq 0) { exit 0 }

# session_id 缺 → 不寫（絕不建立跨 session 共用桶；同 record-webfetch.ps1 B3 裁定）
$sid = "$($data.session_id)"
if ([string]::IsNullOrWhiteSpace($sid)) { exit 0 }
$sidSan = ($sid -replace '[^A-Za-z0-9_.-]', '_')

try {
    $stateDir = if ($env:GUARD_READS_STATE_DIR) { $env:GUARD_READS_STATE_DIR } else { Join-Path ([IO.Path]::GetTempPath()) 'claude-guard-reads' }
    if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
    $stateFile = Join-Path $stateDir "$sidSan.txt"

    $existing = @()
    if (Test-Path $stateFile) {
        $existing = @(Get-Content $stateFile -ErrorAction SilentlyContinue |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim() })
    }
    if ($existing.Count -ge 2000) { exit 0 }   # 上限兜底：超過即停止追加，不動既有條目

    foreach ($c in $cands) {
        $p = "$c"
        # Grep/Glob 的 path 多為目錄 → 只有指向檔案才算「看過內容」（見檔頭）
        if (Test-Path -LiteralPath $p -PathType Container) { continue }

        # 記 basename（小寫）：訊息裡通常只提檔名不帶完整路徑，讀側也只能比對 basename。
        # 代價＝同名不同目錄的檔會互相「頂替」，屬刻意接受的精度損失（偏向少誤報）。
        $bn = ''
        try { $bn = [IO.Path]::GetFileName($p) } catch { $bn = '' }
        if ([string]::IsNullOrWhiteSpace($bn)) { continue }
        $bn = $bn.ToLowerInvariant()

        if ($existing -contains $bn) { continue }
        Add-Content -Path $stateFile -Value $bn -Encoding utf8
        $existing += $bn
    }
} catch { }

exit 0