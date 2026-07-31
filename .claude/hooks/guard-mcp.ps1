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
#   - WebFetch（對外抓取，可能 SSRF/資料外送）→ 每 session 每 host 問一次
#     （2026-07-29 dedup，見下方 WebFetch 專用段落與威脅模型）。
#
# 【fail-open／fail-closed 分流——同檔兩種政策，明文分清，避免互相「修回去」】
#   - stdin 讀不到 / JSON 解析失敗（拿不到 tool_name）→ fail-open（exit 0）。這裡沒有
#     任何輸入可判，卡住等於讓 hook 自身的偶發錯誤擋下整個工具呼叫，不是防護生效。
#   - WebFetch 分支內部：url 缺失／解析失敗／host 為空 → fail-closed（ASK），不沿用
#     上面那條 fail-open。理由：URL 是 WebFetch 這個高風險工具的核心參數，解析失敗
#     代表我們對「要抓什麼」一無所知，此時放行才是真正的防護失效。
#   WebFetch 分支的每一個 ASK 出口都是顯式呼叫，之後**不得**有無條件 fall-through
#   到下面第 54 行的「非 mcp__ 前綴 → exit 0」——那一行只服務非 WebFetch/非 mcp__
#   的呼叫，WebFetch 分支結尾必須是 exit 0（dedup 放行）或 AskMcp，兩者之一，不落空。
#
# 【WebFetch dedup 威脅模型與殘餘風險（B5，強制動作#5：風險必附緩解＋殘餘）】
#   本控制的目的：**降低確認疲勞**（同一 host 在同一 session 內被反覆詢問 3.5 次
#   平均），不是在對抗一個「已被注入、正主動想繞過守門」的行為者。
#   已知繞法：state 檔是 %TEMP% 下的純文字檔，被守的 agent 自己用 Bash/Write
#   往裡面寫一行就能自我核准（session_id 也非機密，transcript 路徑內就有）。
#   建議緩解（把 claude-guard-* state 目錄的寫入納入 guard-bash 的 ask 清單）需要
#   修改 guard-bash.ps1，但**本次任務的檔案範圍明確排除該檔**（見交接指示），故未
#   實作，僅在此明文記錄、留給下一輪處理。**接受方式**：本控制對「被注入 agent
#   自我繞過」沒有防禦力，只在對「使用者本人操作、agent 未被入侵」的場景降噪；
#   不得把「探針/測試綠」讀成「擋得住惡意 agent」。
#
# 【2026-07-29 v2＝C+ 改版】見 .governance/specs/2026-07-29-webfetch-session-dedup.md
# （v2，取代 v1 純 D）。核心變更：新增「白名單主閘門」——host 必須在去重白名單上
# （精確比對）才有資格進入去重，其餘一律每次問；原本承重的 never-dedup 黑名單
# **降級為安全網**，只需擋「人為把不該放的東西填進白名單」，不必再窮舉開放世界
# （v1 正是敗在黑名單當主閘門必然漏、且漏了是靜默放行——白名單漏了只會變嚴）。
#
# 【WebFetch dedup 放行的六道關卡（缺一即 ASK，依序判定，見 spec §2.2）】
#   1) URL 可解析、是絕對 URI、scheme 為 http/https、host 非空白。
#   2) host 正規化（小寫、去尾點）。
#   3)【主閘門】host 必須在「去重白名單」上（精確比對，不做 suffix）——決定節省率，
#      漏列的失敗方向是「多問一次」（變嚴），不是靜默放行。
#   4)【安全網】host 不得命中 never-dedup／私有網段／IPv6／非 ASCII／punycode
#      （xn--）——只擋「人為把不該放的東西加進白名單」，不需窮舉開放世界。
#   5)【結構檢查】本次請求本身要有「去重資格」：無 query、無 userinfo、URL 長度在
#      門檻內、path 各段總長 < 門檻（見 §2.6，實測後預設 64）。沒有它，「host 批准
#      過一次」會被利用成「該 host 底下任何 query payload（含外送的機密內容）永久
#      免問」，這才是 WebFetch 檔頭第一行寫的真正威脅（SSRF／外送 context），
#      載體是 path/query 不是 host。
#   6)【scheme+host 一致 ＋ session_id ＋ TTL】state 鍵為 `scheme://host`（批准 https
#      後 http 同 host 不得免問）；session_id 缺／空 → 一律 ASK 且不查/不寫 state
#      （不沿用 guard-bash ask-flood 的 no-session.txt 落地慣例：那是疲勞偵測，
#      這裡是 allowlist，跨 session 共用水桶等於一份無 TTL 的永久放行清單）；
#      state 檔 mtime 超過 24 小時即整份作廢（`--resume` 會沿用同一 session_id，
#      無 TTL 等於繼承幾天前、你已不記得批准過什麼的舊核准）。
# 解析失敗一律 fail-open（exit 0）——不因 hook 自身錯誤卡住工具（僅適用 stdin/JSON 層，
# 見上方分流說明；WebFetch 的 URL 層是 fail-closed）。
# ============================================================
# 2026-07-31（settings-env 不可信輸入加固）：測試注入從環境變數改為 CLI 參數。
# settings.json／settings.local.json 的 env 區塊會注入 hook 子行程環境＝env 可被
# 任何能寫 settings*.json 的行為者偽造；但 production 接線（settings 的 hooks 陣列）
# 只餵 stdin、不帶參數，CLI 參數注入不進來。test-mcp-guard.ps1 是唯一合法呼叫者。
param(
    [string]$TestAllowlistExtra = ''
)
$ErrorActionPreference = 'SilentlyContinue'

$raw = [Console]::In.ReadToEnd()
if (-not $raw) { exit 0 }
try { $data = $raw | ConvertFrom-Json } catch { exit 0 }

$tool = $data.tool_name
if (-not $tool) { exit 0 }

# 2026-07-31：env 目錄重導向只接受 TEMP 底下的路徑（測試／探針隔離是唯一正當用途，
# run-all／test-mcp-guard／probe-guards 全都指向 TEMP）。settings 的 env 區塊是 hook 的
# 隱性不可信輸入——TEMP 白名單讓「把守門 log 導去別處藏」「預埋 state 目錄」失效；
# TEMP 內的殘餘操縱空間與檔頭威脅模型已列的既知繞法等價，不新增攻擊面。
function Resolve-TempScopedDir([string]$candidate, [string]$fallback) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { return $fallback }
    try {
        $full = [IO.Path]::GetFullPath($candidate)
        $tmpRoot = [IO.Path]::GetFullPath(([IO.Path]::GetTempPath()))
        if ($full.StartsWith($tmpRoot, [System.StringComparison]::OrdinalIgnoreCase)) { return $full }
    } catch { }
    return $fallback
}

# outcome 觀測（2026-07-11）：記 ask 到 governance-logs（記 tool_name，屬非機密）。fail-open。
function Write-GovLog([string]$hook, [string]$decision, [string]$why) {
    try {
        $dir = Resolve-TempScopedDir $env:GOVLOG_DIR (Join-Path $HOME '.claude\governance-logs')
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

# 【主閘門】§2.5(a)：去重白名單——只有這份清單上的 host 有資格進入去重，其餘一律
# 每次問。**精確比對，不做 suffix**（readthedocs.io、github.io 這類是第三方託管
# 平台，suffix 比對會把整個平台放進來；要某專案的文件站就精確加那個 host）。
# 只放官方文件站：不放任何有使用者投稿／第三方託管內容的網域。
# 起始清單依實測流量產生（見交付說明量測 (c)）：github.com/api.github.com/
# raw.githubusercontent.com 是實測前三大 host 但屬第三方託管內容平台（安全網），
# 不放進來；*.readthedocs.io／*.github.io／dev.to／www.tradingview.com／capafy.ai
# 等即使流量高也明確排除（同上理由）。
$script:DedupAllowlistHosts = @(
    'code.claude.com', 'platform.claude.com', 'support.claude.com', 'docs.anthropic.com',
    'www.anthropic.com', 'arxiv.org', 'core.telegram.org', 'developer.mozilla.org',
    'nodejs.org', 'developer.tastytrade.com', 'support.tastytrade.com',
    'developers.line.biz', 'obsidian.md', 'help.obsidian.md', 'law.moj.gov.tw',
    'developers.openai.com', 'docs.github.com'
)
# 測試專用擴充（**只走 CLI 參數 -TestAllowlistExtra**；正式接線不帶參數＝無作用；
# 精確比對，不做 suffix）。2026-07-31 起不再讀 GUARD_WEBFETCH_ALLOWLIST_EXTRA 環境
# 變數——settings 的 env 區塊可注入 hook 子行程，env 版等於把白名單交給任何能寫
# settings*.json 的行為者（golden-task 2026-07-31-settings-local-json-governance-gap）。
# 讓 test-mcp-guard.ps1 能在不碰動正式白名單內容的前提下，用合成測試網域驗證
# 白名單以下各層（安全網／結構檢查／state 比對）的邏輯本身。
if ($TestAllowlistExtra) {
    $extra = @($TestAllowlistExtra -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
    $script:DedupAllowlistHosts = @($script:DedupAllowlistHosts) + $extra
}
function Test-DedupAllowlistHost([string]$h) {
    if ([string]::IsNullOrWhiteSpace($h)) { return $false }
    foreach ($d in $script:DedupAllowlistHosts) {
        if ($h -eq $d) { return $true }
    }
    return $false
}

# 【安全網，降級後不再承重】只擋「人為把不該放進白名單的東西填進去」這種小而封閉
# 的集合，**不需要窮舉開放世界**（v1 正是敗在這個不可能的要求上）。維護準則：
# 這份清單漏列不再是安全問題（白名單沒放它就進不來），因此不需要定期補；但也不得
# 因此把它刪掉——它是白名單填錯時的唯一攔截。
#
# 同一 host 下可由任意第三方放置內容，「批准過這個 host」不蘊含「批准該 host 底下
# 的其他路徑」。實測佔流量 15.7%（github.com 12.9% ＋ raw 2.8%，C+ 之下這些流量
# 現在同時也被主閘門擋下，安全網是第二道防線）。
$script:NeverDedupHosts = @(
    'github.com', 'githubusercontent.com', 'gist.github.com', 'gitlab.com', 'bitbucket.org',
    'pastebin.com', 'hastebin.com', 'paste.ee', 'ghostbin.com', 'jsfiddle.net', 'codepen.io',
    'replit.com', 'glitch.me', 'web.archive.org', 'jsdelivr.net', 'unpkg.com',
    'bit.ly', 'tinyurl.com', 't.co', 'goo.gl', 'is.gd', 'ow.ly'
)

# B2＋suggestion（IPv6 表示法跨版本不一致）：loopback／私有網段／IPv6 字面量／非 ASCII
# 一律 never-dedup。`.Host` 天然剝掉 port——批准一個無害的本機服務 port 不得被放大成
# 對整個 127.0.0.0/8 或本機其他 port（可能帶 token 的 API）免問。清單是「已知高風險樣態
# 的下限，不是安全邊界」——本函式用「一律問」的方向兜底，不是靠列舉窮舉安全。
#
# 【2026-07-29 二輪紅隊補強】原版漏掉會連到本機/CGNAT 的 host，實測可繞：
#   - `0.0.0.0`（已在 state）換 port 免問 → 補精確比對。
#   - `api.localhost` 等 *.localhost 子網域免問（原本只比對 `-eq 'localhost'`）→ 補
#     `.EndsWith('.localhost')`。
#   - `100.64.0.0/10`（CGNAT，Tailscale 等常用）、`198.18.0.0/15`（benchmark 網段）、
#     `192.0.0.0/24`（IETF protocol assignments）皆可路由到本機/內網服務，原本漏列。
#
# 【2026-07-29 C+ 補強：punycode 形式同形字】實測查證（見交付說明）：.NET
# `[System.Uri]` 在本機環境對「直接輸入的 Unicode 同形字網域」(如 gıthub.com)
# **不會**自動轉成 punycode——.Host 原樣保留 Unicode，故上面的非 ASCII 規則已能
# 攔截這類攻擊。但若攻擊者直接打 punycode 編碼字串本身（如 xn--gthub-jsa.com），
# 該字串全為 ASCII，非 ASCII 規則對它完全無效（已用 pwsh 實測確認：h -match
# '[^\x00-\x7F]' 對 'xn--gthub-jsa.com' 回傳 False）——這是獨立的漏洞，需要
# 獨立規則：host 任一 label 以 `xn--` 開頭一律 never-dedup。
function Test-NeverDedupHost([string]$h) {
    if ([string]::IsNullOrWhiteSpace($h)) { return $true }
    if ($h -match '[^\x00-\x7F]') { return $true }   # 非 ASCII（IDN 同形字，如 gıthub.com）
    if ($h -match '(^|\.)xn--') { return $true }      # punycode 編碼字串本身（同形字的 ASCII 表示）
    if ($h.Contains(':')) { return $true }            # IPv6 字面量（含 [::1] 這種帶括號形式）
    if ($h -eq 'localhost' -or $h.EndsWith('.localhost')) { return $true }  # localhost 及其子網域
    if ($h -eq '0.0.0.0') { return $true }            # 0.0.0.0（可連到本機任意 port 服務）
    if ($h -match '^127\.') { return $true }          # 127.0.0.0/8 loopback
    if ($h -match '^10\.') { return $true }            # 10.0.0.0/8 私有網段
    if ($h -match '^192\.168\.') { return $true }      # 192.168.0.0/16 私有網段
    if ($h -match '^172\.(1[6-9]|2[0-9]|3[01])\.') { return $true }  # 172.16.0.0/12 私有網段
    if ($h -match '^169\.254\.') { return $true }      # 169.254.0.0/16 link-local
    if ($h -match '^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.') { return $true }  # 100.64.0.0/10 CGNAT
    if ($h -match '^198\.(1[89])\.') { return $true }  # 198.18.0.0/15 benchmark 網段
    if ($h -match '^192\.0\.0\.') { return $true }     # 192.0.0.0/24 IETF protocol assignments
    foreach ($d in $script:NeverDedupHosts) {
        if ($h -eq $d -or $h.EndsWith('.' + $d)) { return $true }
    }
    return $false
}

# B1 必修：dedup 只認得「同一個 host」是不夠的——外送/SSRF 的載體是 path/query，
# 不是 host。這裡限定「本次請求本身」要長得像一次單純的內容抓取，才有資格吃 dedup：
# 無 query、無 userinfo（否則 .Host 剝掉的資訊會被利用）、URL 不超長、path 沒有疑似
# 高熵/base64 編碼片段（疑似把機密內容編碼藏進路徑外送）。這是啟發式門檻，不是精確
# 偵測——寧可誤判成「沒資格→每次問」，也不要誤判成「有資格→放行」。
#
# 【2026-07-29 二輪紅隊修正：方向反了的 fail-open】舊版寫「segment 落在
# `^[A-Za-z0-9_\-]+$` 字元集內且同時含數字與字母」才取消資格——這代表 segment 只要
# 含一個字元集外的字元（`. ; % + / =` 等外送/編碼常見字元）就整條跳過檢查，越像外送
# 載體越容易逃過（`/aGVsbG8gd29ybGRfc2VjcmV0.dat` 含 `.`、`/p;token=...` 是 matrix
# 參數，皆可繞過）。且原版逐 segment 各自比長度，切成多段、每段都 <24 字元一樣繞過
# （`/sk-ant-api03/xYz12/AbC34/QqR56`）。改法：**不綁字元集**、**累加所有 path
# segment 的字元長度**（不分段比較）——不論內容是什麼字元、不論切成幾段，路徑本體
# 的總字元量達門檻即視為不具去重資格，符合上一段註解宣稱的「寧可誤判為沒資格」。
#
# 【2026-07-29 C+ §2.6：path 門檻改為資料決定】v1 硬編碼 24 過嚴——白名單閘門就位
# 後收件人已限定為官方文件站，`code.claude.com/en/docs/claude-code/hooks-guide`
# 這類正常文件路徑（28 字）反而被擋。實測 2091 筆真實 WebFetch 語料掃 24/48/64/96
# 四門檻（見交付說明量測 (b)）：24→13.9% 節省率／166 次被擋，48→19.1%／37 次，
# 64→20.1%／9 次，96→20.5%／1 次（64→96 邊際增益僅 0.4 個百分點）。採 64 為預設
# （可用環境變數覆寫供測試使用，正式環境不設＝用 64）。
# 2026-07-31：門檻寫死（原 GUARD_WEBFETCH_PATH_SEGLEN_THRESHOLD env 覆寫已移除——
# 全 repo 無任何測試使用它，而 env 可被 settings 注入直接放寬外送門檻）。要改門檻
# 改這一行，並重跑真實語料量測（見上方 §2.6 註解的 24/48/64/96 掃描方法）。
$script:DedupPathSegLenThreshold = 64
function Test-DedupEligible([System.Uri]$uri, [string]$rawUrl) {
    if ($uri.UserInfo) { return $false }
    if ($uri.Query -and $uri.Query -ne '?') { return $false }
    if ($rawUrl.Length -gt 300) { return $false }
    $segs = @($uri.AbsolutePath -split '/' | Where-Object { $_ })
    $totalSegLen = ($segs | ForEach-Object { $_.Length } | Measure-Object -Sum).Sum
    if ($totalSegLen -ge $script:DedupPathSegLenThreshold) { return $false }
    return $true
}

if ($tool -eq 'WebFetch') {
    $url = $data.tool_input.url

    if ([string]::IsNullOrWhiteSpace($url)) {
        AskMcp 'WebFetch 缺 url 欄位或為空字串（fail-closed，無法判定要抓什麼）'
    }

    $uri = $null
    try { $uri = [System.Uri]$url } catch { $uri = $null }
    if ($null -eq $uri -or -not $uri.IsAbsoluteUri -or ($uri.Scheme -ne 'http' -and $uri.Scheme -ne 'https')) {
        AskMcp "WebFetch url 無法解析為絕對 http/https URI（fail-closed）：$url"
    }

    $hostName = $uri.Host
    if ([string]::IsNullOrWhiteSpace($hostName)) {
        AskMcp "WebFetch url 解析出空 host（fail-closed，可能是相對 URI 或 file:// 等非網路 scheme）：$url"
    }
    $hostName = $hostName.ToLowerInvariant().TrimEnd('.')

    # 【主閘門，C+ 核心】host 必須在去重白名單上（精確比對）才有資格繼續往下走；
    # 其餘一律每次問。這一關必須在安全網之前——漏列白名單的失敗方向是「多問一次」
    # （變嚴），不需要靠安全網兜底也能保證不會靜默放行。
    if (-not (Test-DedupAllowlistHost $hostName)) {
        AskMcp "WebFetch 對外抓取網路內容（可能觸發 SSRF 或把 context 送到外部 URL），host『$hostName』不在去重白名單（主閘門），每次必問"
    }

    if (Test-NeverDedupHost $hostName) {
        AskMcp "WebFetch 對外抓取網路內容（可能觸發 SSRF 或把 context 送到外部 URL），host『$hostName』雖在白名單但命中安全網（never-dedup／本機迴路／私有網段／IPv6／非 ASCII／punycode，疑似人為填錯白名單），每次必問"
    }

    if (-not (Test-DedupEligible $uri $url)) {
        AskMcp "WebFetch 對外抓取網路內容（可能觸發 SSRF 或把 context 送到外部 URL），host『$hostName』的這次請求含 query／userinfo／過長／path 超過門檻，不具去重資格，每次必問"
    }

    # 【scheme+host 一致】state 鍵含 scheme，批准 https 後 http 同 host 不得免問。
    $dedupKey = "$($uri.Scheme.ToLowerInvariant())://$hostName"

    # B3：session_id 缺 → 一律 ASK，且不得查也不得寫 state（不建立跨 session 共用桶）
    $sid = $data.session_id
    if (-not [string]::IsNullOrWhiteSpace($sid)) {
        $sidSan = ($sid -replace '[^A-Za-z0-9_.-]', '_')
        # 2026-07-31：state 目錄重導向限 TEMP（見 Resolve-TempScopedDir 註解）
        $stateDir = Resolve-TempScopedDir $env:GUARD_WEBFETCH_STATE_DIR (Join-Path ([IO.Path]::GetTempPath()) 'claude-guard-webfetch')
        $stateFile = Join-Path $stateDir "$sidSan.txt"
        if (Test-Path $stateFile) {
            # 【TTL，C+ 新增】state 檔 mtime 超過 24 小時即整份作廢——`--resume` 會
            # 沿用同一 session_id，無 TTL 等於繼承幾天前你已不記得批准過什麼的舊核准。
            # 讀不到 mtime（例外／檔案競態）一律視為「已過期」（失敗方向偏嚴，非偏鬆）。
            $ttlFresh = $false
            try {
                $age = (Get-Date) - (Get-Item $stateFile -ErrorAction Stop).LastWriteTime
                if ($age.TotalHours -le 24) { $ttlFresh = $true }
            } catch { $ttlFresh = $false }

            if ($ttlFresh) {
                # B4：濾掉空白行，避免一行空字串讓所有空 host 誤判命中；精確比對（非 suffix）。
                #
                # 【為何這一行沒有對應測試（2026-07-30 審查 minor M9′ 的裁定，不是漏測）】
                # 審查者實測「移除本過濾 → 整套測試仍全綠」＝無鑑別力。追查後確認這是
                # **結構上不可達的縱深防禦**，不是漏洞：$dedupKey 恆為 "scheme://host"，
                # 而上游有三道 fail-closed（url 空白→ASK、非絕對 http/https→ASK、
                # host 空白→ASK），因此 $dedupKey **不可能是空白字串**，永遠比對不到空白行。
                # → 寫不出「拿掉這行就會紅」的測試；硬加一條兩種實作都會過的斷言，
                #   就是本工作區明文禁止的假測試（memory: 回歸測試的 fake 不能內建修復）。
                # 保留本行的理由：若日後有人放寬上游任一道 fail-closed，它是最後一層兜底。
                # **不要因為「沒測試」就刪掉它，也不要為它補假測試。**
                $seen = @(Get-Content $stateFile -ErrorAction SilentlyContinue |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    ForEach-Object { $_.Trim() })
                if ($seen -contains $dedupKey) {
                    Write-GovLog 'guard-mcp' 'allow' "WebFetch dedup：host『$hostName』（$($uri.Scheme)）本 session 先前已成功抓取過，略過重複詢問"
                    exit 0
                }
            }
        }
    }

    AskMcp "WebFetch 對外抓取網路內容（可能觸發 SSRF 或把 context 送到外部 URL），host=$hostName"
    exit 0
}

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
