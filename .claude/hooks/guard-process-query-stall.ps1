#!/usr/bin/env pwsh
# ============================================================
# guard-process-query-stall.ps1  --  THIN SHELL over lib-process-query-stall.ps1 (Ag2bGuardEval)
#   pending-decisions 乙組 #10「卡住時 AI 收手（程序查詢逾時）」的守門端；邏輯、決策表、訊息與殘餘風險全在函式庫檔頭。
#
# 【2026-11-08 F1 負載合併】本檔**不再接線**：PreToolUse 的整機程序列舉判定改由 guard-bash.ps1 在原判定之後呼叫同一個
# Ag2bGuardEval（少起一支 pwsh，每次 Bash／PowerShell 呼叫約省 0.65 秒）。本檔保留成薄殼的理由：
#   1. 測試入口：test-process-query-stall.ps1 仍以「獨立 hook 檔」形狀逐案餵 stdin 驗同一套邏輯（既有案例一個不刪），
#      並另有經 guard-bash 入口的同等案例，兩條入口的輸出逐位元比對；
#   2. 舊接線相容：還沒跑 sync 的專案若 settings 仍接這支，它照常運作（與 guard-bash 內建的判定給同一個結果，只是重複）；
#   3. 診斷用：可以單獨餵一個 payload 看整機程序列舉的判定。
# 薄殼不含任何判定邏輯、不含訊息文字（單一份在函式庫；測試釘住「薄殼沒有第二份」）。
#
# 介面不變：stdin 一個 JSON；放行＝無輸出；ask／deny＝一行 ASCII JSON（permissionDecision），離開碼恆 0（deny 也是 JSON 決定，不是 exit 2）。
# fail-open：stdin／JSON 壞、函式庫載入失敗、任何例外一律放行（exit 0、不輸出決定）。本檔程式碼只用 ASCII。
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
    if (-not (Get-Command Ag2bGuardEval -ErrorAction SilentlyContinue)) { exit 0 }

    $v = Ag2bGuardEval $data
    if ($null -ne $v -and $v.json) { [Console]::Out.WriteLine($v.json) }
    exit 0
} catch {
    exit 0
}
