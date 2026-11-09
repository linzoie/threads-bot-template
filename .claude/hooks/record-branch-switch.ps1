#!/usr/bin/env pwsh
# ============================================================
# record-branch-switch.ps1  —  PostToolUse hook (matcher: Bash|PowerShell)
#
# 本檔現在是「Bash／PowerShell 每次呼叫都會跑的那一支 PostToolUse hook」，承載三段彼此獨立的工作（2026-11-08 F1 負載合併：
# 後兩段原本各是獨立 hook，每次呼叫各多起一支 pwsh，約 0.65 秒／支）：
#   A. 並行分支漂移的基準線更新（本檔原本的工作，見下）。
#   B. 整機程序列舉的卡住記錄（lib-process-query-stall.ps1 的 Ag2bRecordEval；PostToolUse 成功路徑與 is_error 旗標；
#      PostToolUseFailure 事件仍由 record-process-query-stall.ps1 獨立接線）。
#   C. Bash／PowerShell 執行過的腳本記為「已看過」（lib-record-reads.ps1 的 AgfxRdRecordShellScripts，供 detect-unread-claim 用）。
# 三段各自 try/catch：任何一段出錯都不影響其他段，也不得擋工具（Post hook 一律 exit 0）。stdout 只有 B 可能輸出一行
# ASCII JSON（additionalContext 提醒）；A、C 不輸出。各段行為與搬家前相同。
#
# 【A 的為什麼】並行分支漂移偵測（guard-bash 步驟 4b → Get-BranchDriftVerdict）比對的是
# 「狀態檔記的分支」vs「現在的分支」。狀態檔原本**只在 SessionStart 寫一次**，所以
# 你自己 `git checkout -b feat/x` 之後，下一條 git 指令必然被問一次——而那是**假陽性**：
# 守門的目的是「別人動了你的樹」，不是「你動了自己的樹」。
# test-branch-drift.ps1 的 E2E-4 正是用 `git checkout -b` 模擬「別的 session 切走」，
# 等於同時證明了這個假陽性存在（Fable delta 裁決 §5 #1-i）。
#
# 【A 為什麼是 PostToolUse】PreToolUse 無從得知指令最終有沒有執行成功，也無從得知使用者
# 按了准還是不准。PostToolUse 只在工具**實際執行成功後**觸發，所以「本檔被觸發」本身
# 就是「這條 checkout 真的跑了」的訊號。同 record-webfetch.ps1 的理由。
#
# 【A 的載入優化（F1，行為不變）】guard-core.ps1 約 160 KB，解析一次要數百毫秒；A 只在指令字串含 git 時才可能成立
# （Test-IsBranchSwitchGit 的第一個條件就是 git token），所以指令不含 git 這三個字母時完全不載入 guard-core。
#
# 【fail-safe 方向】本檔任何一步失敗都靜默 exit 0，且**不影響任何判定**。
# 壞掉的唯一後果是：你自己切分支後會被多問一次（退回本次改動前的行為）。
# 絕不會讓「別人切走了」變成不問——那個方向的判定完全在 guard-bash/guard-core，
# 本檔只會把基準線更新成「現在確實在的分支」，不會製造放行。
#
# 【殘餘風險】切換與回寫之間有微秒級競態：若另一個 session 恰好在這兩者之間切走分支，
# 本檔會把對方的分支記成基準，那次漂移就不會被通知。這是 ask 級安全網可接受的殘餘
# （fail-open 不是閘門）；真正的互斥要靠 worktree 或人工序列化。
# ============================================================

$ErrorActionPreference = 'Stop'

try {
    # stdin is read as raw bytes and decoded as UTF-8. [Console]::In decodes with the console input
    # code page (950 on zh-TW), which corrupts non-ASCII text and eats backslashes (Bad JSON escape).
    # The byte read happens only when stdin is redirected (the real hook case: Claude Code pipes it). When stdin
    # is the interactive console, OpenStandardInput().CopyTo() waits for keyboard EOF forever, so it is skipped.
    # Console.In is the fallback when stdin is not redirected, the byte read fails, or it yields nothing
    # (this also serves in-process callers that inject stdin via [Console]::SetIn, e.g. test-adapter-parity).
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
    $raw = Read-StdinUtf8
    if (-not $raw) { exit 0 }

    $data = $null
    try { $data = $raw | ConvertFrom-Json } catch { exit 0 }
    if ($null -eq $data) { exit 0 }

    $tool = "$($data.tool_name)"
    if ($tool -ne 'Bash' -and $tool -ne 'PowerShell') { exit 0 }

    # ── A. 分支基準線（原本的工作）──
    try {
        $doBranch = $true
        # 防禦性：PostToolUse 理論上只在成功後觸發，但那是版本行為非契約（同 record-webfetch）
        $resp = $data.tool_response
        if ($resp) {
            if ($resp.is_error -eq $true) { $doBranch = $false }
            if ($resp.isError -eq $true) { $doBranch = $false }
        }
        $cmd = "$($data.tool_input.command)"
        if ([string]::IsNullOrWhiteSpace($cmd)) { $doBranch = $false }
        # 載入優化：Test-IsBranchSwitchGit 要求指令含 git token；不含 git 字樣就不可能是切分支，免載 guard-core
        if ($doBranch -and ($cmd -match 'git')) {
            $core = Join-Path $PSScriptRoot 'guard-core.ps1'
            if (Test-Path -LiteralPath $core) {
                . (Join-Path $PSScriptRoot 'guard-core.ps1')
                if ((Get-Command Test-IsBranchSwitchGit -ErrorAction SilentlyContinue) -and
                    (Test-IsBranchSwitchGit -Command $cmd) -and
                    (Get-Command Write-SessionBranchState -ErrorAction SilentlyContinue)) {
                    # 重寫基準線＝現在實際所在的分支（Write-SessionBranchState 自己查 git，不信任指令字面：
                    # `git checkout` 可能失敗、可能切到別的地方、可能帶 -- 路徑根本沒換分支）。
                    # 順帶清掉 pending_drift（新 payload 不含該欄），因為基準線已經是現況。
                    $null = Write-SessionBranchState -Cwd (Get-Location).Path
                }
            }
        }
    } catch { }

    # ── B. 整機程序列舉卡住記錄（lib-process-query-stall.ps1）──
    # F1-M1（總審必修）：全域 ~/.claude/hooks 的副本在 sync 後也會帶到本段，而全域 settings 本來就接了 record-branch-switch；
    # 在 code/ 的 session 裡全域與專案兩份會各跑一次 B，同一次逾時被記兩次（計數 0 直接到 2、下次整機列舉從 ask 變 deny、跳兩則提醒）。
    # 程序列舉守門與記錄原本只接在專案 settings（code/ 與子專案），所以全域副本不做 B（範圍維持原狀、不擴到所有目錄）。
    # 判斷「我是不是全域副本」只看自己所在的目錄＝$HOME\.claude\hooks；判斷失敗（例外）當成不是全域副本＝照常記錄（寧可偶爾重複、不可漏記）。
    # 本函式與 guard-bash.ps1 裡同名的那份逐字相同（test-process-query-stall.ps1 第 5c 節比對，防漂移）。
    function AgfxF1IsGlobalCopy {
        try {
            $here = [IO.Path]::GetFullPath("$PSScriptRoot").TrimEnd('\', '/')
            $glob = [IO.Path]::GetFullPath((Join-Path $HOME '.claude\hooks')).TrimEnd('\', '/')
            return ($here -ieq $glob)
        } catch { return $false }
    }
    try {
        $libPq = Join-Path $PSScriptRoot 'lib-process-query-stall.ps1'
        if ((-not (AgfxF1IsGlobalCopy)) -and (Test-Path -LiteralPath $libPq)) {
            . (Join-Path $PSScriptRoot 'lib-process-query-stall.ps1')
            if (Get-Command Ag2bRecordEval -ErrorAction SilentlyContinue) {
                $pqOut = Ag2bRecordEval $data
                if ($pqOut) { [Console]::Out.WriteLine($pqOut) }
            }
        }
    } catch { }

    # ── C. Bash／PowerShell 執行過的腳本記為已看過（lib-record-reads.ps1）──
    try {
        $libRr = Join-Path $PSScriptRoot 'lib-record-reads.ps1'
        if (Test-Path -LiteralPath $libRr) {
            . (Join-Path $PSScriptRoot 'lib-record-reads.ps1')
            if (Get-Command AgfxRdRecordShellScripts -ErrorAction SilentlyContinue) { AgfxRdRecordShellScripts $data }
        }
    } catch { }
}
catch { }

exit 0
