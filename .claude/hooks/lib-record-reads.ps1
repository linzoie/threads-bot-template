#!/usr/bin/env pwsh
# ============================================================
# lib-record-reads.ps1  --  LIBRARY (dot-sourced; never wired as a hook, never run directly)
#   record-reads.ps1 的「Bash／PowerShell 執行過的腳本也算看過」那一半（pending 乙組 #6 P1，2026-11-08）。
#   2026-11-08 F1「負載合併」：原本 record-reads 的 matcher 含 Bash|PowerShell，每次 Bash／PowerShell 呼叫都為它多起一支 pwsh。
#   現在 shell 類工具的紀錄搬到本函式庫，由「本來每次都會跑」的 record-branch-switch.ps1（PostToolUse ^(Bash|PowerShell)$）呼叫；
#   record-reads 的接線 matcher 改回只含 Read|Grep|Glob|Edit|Write|MultiEdit|NotebookEdit，但 record-reads.ps1 本身仍認得
#   Bash／PowerShell 並呼叫同一個函式（舊接線＋新檔案並存時不失效；測試也由它直接驗）。
#   行為與搬家前相同：只記「被當成腳本執行」的檔名（pwsh／powershell -File 或位置參數、node、bash／sh、python／py、& 呼叫、
#   位於指令起頭的直接呼叫；pwsh／bash 的 -Command／-c 字串遞迴解析一層）；刻意不記 cat／grep／git 等只是指名的檔。
#   取捨：解析是啟發式——執行期才組出來的路徑（變數拼接、glob）抓不到，方向是多誤報、偏安全；指令字串不含任何腳本副檔名時
#   直接跳過（日常 git／ls 之類呼叫幾乎零額外成本）。
#   fail-safe 方向（同 record-reads）：本層壞掉＝讀側的集合少記，讀側必須把「集合不存在或為空」判成「不確定 → 放行」。
#   狀態寫入與 record-reads.ps1 的 Read 類路徑是同一份檔案格式（%TEMP%\claude-guard-reads\<sid>.txt，GUARD_READS_STATE_DIR 可覆寫；
#   一行一個小寫 basename、上限 2000 行）——Read 類路徑留在 record-reads.ps1 內不依賴本檔，兩處寫法的一致由 test-unread-claim.ps1 驗。
#   本檔不讀 stdin、不輸出、不呼叫 exit；自寫函式前綴 AgfxRd，避免與同進程載入的其他函式庫同名。
# ============================================================

$AgfxRdScriptExtRe = '\.(?:ps1|psm1|mjs|cjs|js|ts|tsx|py|sh|bash)$'
$AgfxRdInterpreters = @('pwsh', 'powershell', 'node', 'bash', 'sh', 'python', 'python3', 'py')
$AgfxRdShellInterpreters = @('pwsh', 'powershell', 'bash', 'sh')
$AgfxRdNestFlags = @('-c', '-command')                                  # 後面接一段 shell 字串 → 遞迴解析
$AgfxRdInlineFlags = @('-e', '-encodedcommand', '-ec', '--eval', '-p', '--print', '-m')   # 後面是內嵌程式碼／模組 → 沒有腳本檔

function AgfxRdUnquote {
    param([string]$Tok)
    $t = "$Tok".Trim()
    if ($t.Length -ge 2 -and (($t[0] -eq '"' -and $t[$t.Length - 1] -eq '"') -or ($t[0] -eq "'" -and $t[$t.Length - 1] -eq "'"))) {
        $t = $t.Substring(1, $t.Length - 2)
    }
    return $t.Trim()
}
function AgfxRdIsSep {
    param([string]$Tok)
    return ($Tok -match '^(?:\r?\n|\r|&&|\|\||;|\||&)$')
}
# 單一 token 若指向腳本檔（副檔名白名單）→ 回 basename 小寫；否則回空字串
function AgfxRdScriptBase {
    param([string]$Tok)
    $t = AgfxRdUnquote $Tok
    if ($t -notmatch $AgfxRdScriptExtRe) { return '' }
    $bn = @($t -split '[\\/]')[-1]
    if ([string]::IsNullOrWhiteSpace($bn)) { return '' }
    return $bn.Trim().ToLowerInvariant()
}
# token 是否為直譯器（取 basename、去 .exe）
function AgfxRdTokName {
    param([string]$Tok)
    $t = AgfxRdUnquote $Tok
    $bn = @($t -split '[\\/]')[-1]
    if ($null -eq $bn) { return '' }
    return ($bn.ToLowerInvariant() -replace '\.exe$', '')
}

function AgfxRdGetExecutedScripts {
    param([string]$Cmd, [int]$Depth = 0)
    $found = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Cmd) -or $Depth -gt 2) { return @() }
    # 預過濾：整串指令連一個腳本副檔名都沒有 → 不可能有被執行的腳本，省掉 tokenize
    if ($Cmd -notmatch '\.(?:ps1|psm1|mjs|cjs|js|ts|tsx|py|sh|bash)(?![A-Za-z0-9_])') { return @() }

    $toks = @([regex]::Matches($Cmd, '"[^"]*"|''[^'']*''|\r?\n|\r|&&|\|\||[;|&]|[^\s;&|"'']+') | ForEach-Object { $_.Value })
    for ($i = 0; $i -lt $toks.Count; $i++) {
        $t = $toks[$i]
        if (AgfxRdIsSep $t) {
            # 呼叫運算子：& 後面緊接的 token（單引號相對路徑、雙引號正斜線絕對路徑兩種寫法都算；註解不寫完整引號路徑——
            # lib-shipset 的 dot-source 抽取器會把「引號包住的 .ps1 路徑」誤當依賴，函式庫又在全域閉包裡，2026-11-08 F1 實踩）
            if ($t -eq '&' -and ($i + 1) -lt $toks.Count -and -not (AgfxRdIsSep $toks[$i + 1])) {
                $b = AgfxRdScriptBase $toks[$i + 1]
                if ($b) { $found.Add($b) }
            }
            continue
        }
        $atStart = ($i -eq 0) -or (AgfxRdIsSep $toks[$i - 1])
        $name = AgfxRdTokName $t
        if ($AgfxRdInterpreters -contains $name) {
            $limit = [Math]::Min($toks.Count - 1, $i + 16)
            for ($j = $i + 1; $j -le $limit; $j++) {
                $u = $toks[$j]
                if (AgfxRdIsSep $u) { break }
                $ul = (AgfxRdUnquote $u).ToLowerInvariant()
                if ($AgfxRdNestFlags -contains $ul) {
                    if ($AgfxRdShellInterpreters -contains $name -and ($j + 1) -lt $toks.Count) {
                        $nx = $toks[$j + 1]
                        if ($nx -match '^["'']') { $inner = AgfxRdUnquote $nx }
                        else { $inner = (@($toks[($j + 1)..($toks.Count - 1)]) -join ' ') }
                        foreach ($s in @(AgfxRdGetExecutedScripts -Cmd $inner -Depth ($Depth + 1))) { if ($s) { $found.Add($s) } }
                    }
                    break
                }
                if ($AgfxRdInlineFlags -contains $ul) { break }
                $b = AgfxRdScriptBase $u
                if ($b) { $found.Add($b); break }
            }
            continue
        }
        if ($atStart) {
            $b = AgfxRdScriptBase $t     # ./x.sh、.governance/bin/y.ps1 這種直接呼叫
            if ($b) { $found.Add($b) }
        }
    }
    return @($found.ToArray() | Select-Object -Unique)
}

# 記錄一次 Bash／PowerShell 呼叫執行過的腳本。$data＝已解析的 hook stdin 物件。不回傳值、不丟例外。
# 與搬家前相同：shell 類工具不套用失敗檢查（腳本跑了就是跑了，跑出非零離開碼仍代表「親眼看過它的行為」）；
# session_id 缺 → 不寫（絕不建立跨 session 共用桶）；已存在的條目不重複寫；上限 2000 行就停止追加。
function AgfxRdRecordShellScripts($data) {
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        if ($null -eq $data) { return }
        $ti = $data.tool_input
        if (-not $ti) { return }
        $toRecord = @(AgfxRdGetExecutedScripts -Cmd "$($ti.command)")
        if ($toRecord.Count -eq 0) { return }

        $sid = "$($data.session_id)"
        if ([string]::IsNullOrWhiteSpace($sid)) { return }
        $sidSan = ($sid -replace '[^A-Za-z0-9_.-]', '_')

        $stateDir = if ($env:GUARD_READS_STATE_DIR) { $env:GUARD_READS_STATE_DIR } else { Join-Path ([IO.Path]::GetTempPath()) 'claude-guard-reads' }
        if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
        $stateFile = Join-Path $stateDir "$sidSan.txt"

        $existing = @()
        if (Test-Path $stateFile) {
            $existing = @(Get-Content $stateFile -ErrorAction SilentlyContinue |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                ForEach-Object { $_.Trim() })
        }
        if ($existing.Count -ge 2000) { return }   # 上限兜底：超過即停止追加，不動既有條目

        foreach ($bn in $toRecord) {
            if ($existing -contains $bn) { continue }
            Add-Content -Path $stateFile -Value $bn -Encoding utf8
            $existing += $bn
        }
    } catch { }
}
