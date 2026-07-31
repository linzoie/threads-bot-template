#!/usr/bin/env pwsh
# ============================================================
# record-webfetch.ps1  —  PostToolUse hook (matcher: WebFetch)
#
# 2026-07-29：WebFetch 確認疲勞降噪（v2＝方案 C+，見 .governance/specs/
# 2026-07-29-webfetch-session-dedup.md）的「寫入端」。guard-mcp.ps1（PreToolUse）
# 是「讀」這份 session state；本檔是唯一的「寫」——WebFetch 成功執行後，把 host
# 追加進同一份 per-session state 檔，讓同 session 下次對同一 host 的請求（若也通過
# guard-mcp.ps1 的結構性資格關卡）不必再問。
#
# 【為何必須是 PostToolUse 而不是「ASK 當下就記錄」】
# PreToolUse 無從得知使用者最終按了准還是不准——ASK 只是「送出確認框」，決定權在
# 使用者。若在 ASK 當下（PreToolUse）就記錄，會出現「使用者明明按了拒絕，同 session
# 下次對同一 host 反而被自動放行」的荒謬結果，等於用一次 fail-open 把使用者的拒絕
# 決定整個抵銷掉。PostToolUse 只在工具**實際執行成功後**才觸發（Claude Code 對
# 使用者拒絕走的是獨立的 PermissionDenied 事件、不會落到 PostToolUse——2026-07-29
# 以 Claude Code v2.1.216 內建文件核實：PostToolUse 明列「Run after successful
# tool」且 tool_response 是 PostToolUse-only 欄位；此為版本行為非契約，見下方防禦性
# 檢查），所以「PostToolUse 觸發」本身就是「使用者已核准且工具已成功抓到內容」的
# 唯一可靠訊號。
#
# 【fail-safe 性質——降級方向只能是變嚴，不能是變鬆】
# 本檔任何一步失敗（未接線、拋例外、state 目錄寫入失敗、環境變數缺失…）都必須
# 靜默 exit 0，且**不影響任何判定**：本檔壞掉的唯一後果是 state 永遠是空的，
# guard-mcp.ps1 讀不到任何已核准 host → 每次都 ASK → 退回本次改動前的現行行為。
# 絕不能因為本檔的錯誤導致「看起來像已核准」的誤判。
#
# 【威脅模型與殘餘風險（同 guard-mcp.ps1 檔頭 B5 段，此處不重複展開）】
# state 檔是 %TEMP% 下的純文字檔案，任何能在本機執行指令的行為者（包含被守的
# agent 自己）都能繞過本檔直接寫一行進去自我核准。本控制只做「降低對使用者的
# 確認疲勞」，不是對抗「已被注入、主動想繞過守門」的行為者的安全邊界。
#
# 【與 guard-mcp.ps1 的一致性義務】host 正規化（小寫＋去尾點）必須與 guard-mcp.ps1
# 的正規化邏輯完全一致，否則兩邊對不上、dedup 永遠失效或誤判。兩檔各自維護一份
# （範圍限制不允許抽成共用檔），改一邊記得改另一邊。
#
# 【2026-07-29 C+：state 鍵改為 scheme://host】修 v1 的 scheme 降級漏洞——批准過
# https 的 host，同 host 換成 http 不得免問。本檔寫入的鍵格式必須與 guard-mcp.ps1
# 讀取時比對的鍵格式完全一致（皆為 `<scheme>://<host>`，小寫、host 去尾點）。
#
# 【本檔不做白名單過濾】是否放行由 guard-mcp.ps1（讀側）的主閘門決定；本檔（寫側）
# 對任何成功的 WebFetch 呼叫一律記錄，即使該 host 不在白名單也記——因為即使記了，
# 主閘門仍會在下次請求時擋下（白名單檢查發生在 state 查詢之前），這裡多記幾筆
# 不影響安全性，只是 state 檔可能多出幾筆永遠用不到的 entry（500 行上限兜底）。
# ============================================================
$ErrorActionPreference = 'SilentlyContinue'

$raw = [Console]::In.ReadToEnd()
if (-not $raw) { exit 0 }
try { $data = $raw | ConvertFrom-Json } catch { exit 0 }

$tool = $data.tool_name
if ($tool -ne 'WebFetch') { exit 0 }   # 防禦性；matcher 理論上只會送 WebFetch

# 防禦性失敗檢查（suggestions 段落建議、非必要但便宜）：PostToolUse 依 2026-07-29 查證的
# v2.1.216 版本行為只在工具「成功」時觸發，真實的「使用者拒絕」根本不會走到這裡（見上方
# 檔頭說明）；但版本行為非契約，這裡仍防禦性檢查 tool_response 是否帶有失敗標記，若有則
# 不記錄——多一層保險，不影響任何判定（不記錄永遠是安全方向）。
$resp = $data.tool_response
if ($resp) {
    if ($resp.is_error -eq $true) { exit 0 }
    if ($resp.isError -eq $true) { exit 0 }
    if ($resp.error) { exit 0 }
}

$url = $data.tool_input.url
if ([string]::IsNullOrWhiteSpace($url)) { exit 0 }

$uri = $null
try { $uri = [System.Uri]$url } catch { $uri = $null }
if ($null -eq $uri -or -not $uri.IsAbsoluteUri -or ($uri.Scheme -ne 'http' -and $uri.Scheme -ne 'https')) { exit 0 }

$hostName = $uri.Host
if ([string]::IsNullOrWhiteSpace($hostName)) { exit 0 }
$hostName = $hostName.ToLowerInvariant().TrimEnd('.')
$dedupKey = "$($uri.Scheme.ToLowerInvariant())://$hostName"

# B3：session_id 缺 → 不查也不寫 state（絕不建立跨 session 共用桶／no-session 永久水桶）
$sid = $data.session_id
if ([string]::IsNullOrWhiteSpace($sid)) { exit 0 }
$sidSan = ($sid -replace '[^A-Za-z0-9_.-]', '_')

try {
    # 2026-07-31：env 重導向限 TEMP（settings 的 env 區塊是隱性不可信輸入，與 guard-mcp 同步加固）
    $stateDir = Join-Path ([IO.Path]::GetTempPath()) 'claude-guard-webfetch'
    if ($env:GUARD_WEBFETCH_STATE_DIR) { try { $c = [IO.Path]::GetFullPath($env:GUARD_WEBFETCH_STATE_DIR); if ($c.StartsWith([IO.Path]::GetFullPath(([IO.Path]::GetTempPath())), [System.StringComparison]::OrdinalIgnoreCase)) { $stateDir = $c } } catch { } }
    if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
    $stateFile = Join-Path $stateDir "$sidSan.txt"

    $existing = @()
    if (Test-Path $stateFile) {
        $existing = @(Get-Content $stateFile -ErrorAction SilentlyContinue |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim() })
    }

    if ($existing -contains $dedupKey) { exit 0 }       # 已記過，不重複追加
    if ($existing.Count -ge 500) { exit 0 }              # 上限 500 行：超過即停止追加，不影響既有條目

    Add-Content -Path $stateFile -Value $dedupKey -Encoding utf8
} catch { }

exit 0