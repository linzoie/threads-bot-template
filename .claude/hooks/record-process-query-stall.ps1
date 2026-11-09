#!/usr/bin/env pwsh
# ============================================================
# record-process-query-stall.ps1  --  THIN SHELL over lib-process-query-stall.ps1 (Ag2bRecordEval)
#   PostToolUse + PostToolUseFailure hook (matcher: Bash|PowerShell)
#   pending-decisions 乙組 #10「卡住時 AI 收手（程序查詢逾時）」的記錄端；邏輯（失敗判定、計數、成功歸零、UNDETERMINED、
#   訊息）、使用者核定流程、殘餘風險全在函式庫 lib-process-query-stall.ps1 檔頭。
#
# 【2026-11-08 F1 負載合併】PostToolUse（成功路徑，含「列舉成功把計數 1 歸零」與 tool_response 帶失敗旗標的情形）改由
# record-branch-switch.ps1 呼叫同一個 Ag2bRecordEval（少起一支 pwsh，每次 Bash／PowerShell 呼叫約省 0.65 秒）。
# 本檔因此只剩一個接線：PostToolUseFailure（只在工具失敗時觸發，少見，不值得併進別的 hook）。薄殼不含任何判定邏輯、
# 不含訊息文字（單一份在函式庫）；它仍同時認得 PostToolUse 事件（舊接線相容與測試入口），行為與搬家前相同。
#
# 介面不變：stdin 一個 JSON；輸出＝無，或一行 ASCII JSON（additionalContext 提醒）；離開碼恆 0，不含任何擋或問的決定。
# fail-open：任何一步出錯一律 exit 0。本檔程式碼只用 ASCII。
# ============================================================
$ErrorActionPreference = 'SilentlyContinue'

# stdin is read as raw bytes and decoded as UTF-8 (see after-edit.ps1 for the full reasoning: Console.In
# decodes with the console code page, which corrupts non-ASCII text on a zh-TW machine).
function Read-StdinUtf8 {
    $b = $null
    if ([Console]::IsInputRedirected) {
        try {
            $ms = New-Object System.IO.MemoryStream
            [Console]::OpenStandardInput().CopyTo($ms)
            $b = $ms.ToArray()
        } catch { $b = $null }
    }
    if ($null -ne $b -and $b.Length -gt 0) {
        $start = 0
        if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $start = 3 }
        return [System.Text.Encoding]::UTF8.GetString($b, $start, $b.Length - $start).TrimStart([char]0xFEFF)
    }
    try { return [Console]::In.ReadToEnd() } catch { return '' }
}
# Output: stdout/stderr leave as UTF-8 bytes on the raw handles, never through the console code page (at 950 the
# default writer emits Big5: reason text turns into mojibake and a JSON reason can break). Only when redirected (the
# real hook case); an interactive console keeps its default writer. Any failure keeps the default writer.
function Initialize-HookUtf8Output {
    try {
        if ([Console]::IsOutputRedirected) { $w = New-Object System.IO.StreamWriter([Console]::OpenStandardOutput(), (New-Object System.Text.UTF8Encoding $false)); $w.AutoFlush = $true; [Console]::SetOut($w) }
        if ([Console]::IsErrorRedirected) { $w = New-Object System.IO.StreamWriter([Console]::OpenStandardError(), (New-Object System.Text.UTF8Encoding $false)); $w.AutoFlush = $true; [Console]::SetError($w) }
    } catch { }
}
Initialize-HookUtf8Output

try {
    $raw = Read-StdinUtf8
    if (-not $raw) { exit 0 }
    $data = $raw | ConvertFrom-Json
    if ($null -eq $data) { exit 0 }

    . (Join-Path $PSScriptRoot 'lib-process-query-stall.ps1')
    if (-not (Get-Command Ag2bRecordEval -ErrorAction SilentlyContinue)) { exit 0 }

    $ctx = Ag2bRecordEval $data
    if ($ctx) { [Console]::Out.WriteLine($ctx) }
    exit 0
} catch {
    exit 0
}
