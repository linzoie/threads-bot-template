#!/usr/bin/env pwsh
# ============================================================
# record-branch-switch.ps1  —  PostToolUse hook (matcher: Bash|PowerShell)
#
# 【為什麼】並行分支漂移偵測（guard-bash 步驟 4b → Get-BranchDriftVerdict）比對的是
# 「狀態檔記的分支」vs「現在的分支」。狀態檔原本**只在 SessionStart 寫一次**，所以
# 你自己 `git checkout -b feat/x` 之後，下一條 git 指令必然被問一次——而那是**假陽性**：
# 守門的目的是「別人動了你的樹」，不是「你動了自己的樹」。
# test-branch-drift.ps1 的 E2E-4 正是用 `git checkout -b` 模擬「別的 session 切走」，
# 等於同時證明了這個假陽性存在（Fable delta 裁決 §5 #1-i）。
#
# 【為什麼是 PostToolUse】PreToolUse 無從得知指令最終有沒有執行成功，也無從得知使用者
# 按了准還是不准。PostToolUse 只在工具**實際執行成功後**觸發，所以「本檔被觸發」本身
# 就是「這條 checkout 真的跑了」的訊號。同 record-webfetch.ps1 的理由。
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
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { exit 0 }

    $data = $null
    try { $data = $raw | ConvertFrom-Json } catch { exit 0 }
    if ($null -eq $data) { exit 0 }

    $tool = "$($data.tool_name)"
    if ($tool -ne 'Bash' -and $tool -ne 'PowerShell') { exit 0 }

    # 防禦性：PostToolUse 理論上只在成功後觸發，但那是版本行為非契約（同 record-webfetch）
    $resp = $data.tool_response
    if ($resp) {
        if ($resp.is_error -eq $true) { exit 0 }
        if ($resp.isError -eq $true) { exit 0 }
    }

    $cmd = "$($data.tool_input.command)"
    if ([string]::IsNullOrWhiteSpace($cmd)) { exit 0 }

    $core = Join-Path $PSScriptRoot 'guard-core.ps1'
    if (-not (Test-Path -LiteralPath $core)) { exit 0 }
    . (Join-Path $PSScriptRoot 'guard-core.ps1')

    if (-not (Get-Command Test-IsBranchSwitchGit -ErrorAction SilentlyContinue)) { exit 0 }
    if (-not (Test-IsBranchSwitchGit -Command $cmd)) { exit 0 }
    if (-not (Get-Command Write-SessionBranchState -ErrorAction SilentlyContinue)) { exit 0 }

    # 重寫基準線＝現在實際所在的分支（Write-SessionBranchState 自己查 git，不信任指令字面：
    # `git checkout` 可能失敗、可能切到別的地方、可能帶 -- 路徑根本沒換分支）。
    # 順帶清掉 pending_drift（新 payload 不含該欄），因為基準線已經是現況。
    $null = Write-SessionBranchState -Cwd (Get-Location).Path
}
catch { }

exit 0
