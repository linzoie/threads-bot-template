#!/usr/bin/env pwsh
# ============================================================
# guard-read-secrets.ps1  —  PreToolUse hook (matcher: Read)
#
# B12（2026-07-31，使用者裁決選項 B）：補上「agent 用 Read 工具直接讀機密檔」這個
# **既有四道防線全都攔不到**的缺口。
#
# 【射程對照——為什麼非補不可】
#   guard-secrets   攔 git add／commit 的機密檔        → 攔不到「讀」
#   guard-core      攔 `cat .env`／`printenv` 這類**指令** → 攔不到非 shell 的讀取
#   pre-commit      攔 commit                          → 同上
#   guard-mcp       攔 WebFetch 的 **host**             → 不看送出去的**內容**
#   ────────────────────────────────────────────────
#   Read('.env') → 內容進 context → 之後可能經摘要／log／截圖／某次對外呼叫流出去
#   四道全部不攔。這是 2026-07-31 可攜性重稽核的社群掃描指出的新威脅面。
#
# 【為什麼是 ask 不是 deny】
# `.env` 本來就是給程式讀的，硬擋會讓正常開發寸步難行；而且同組機密（guard-core 的
# 「讀機密檔」段）現行處置就是 ask——**只升這一條會造成同類風險兩種處置**，
# 那正是 2026-07-26 `auth.json` 裁決明文避開的 policy 分岔起點。
#
# 【誠實邊界（非閉環，明文寫出來免得被讀成「機密不會外流了」）】
#   - 只攔 **Read 工具**。程式在執行期自己載入 `.env`（dotenv/os.environ）不經任何 hook。
#   - 攔不到 `Grep`／`Glob` 把機密內容當搜尋結果帶出來（另一個入口，見下方 TODO）。
#   - 使用者按下「允許」之後內容就進 context 了——這是**確認**不是**阻止**。
#   - 覆蓋的是「檔名看起來像機密」，不是「內容是機密」。改名成 config.txt 就繞過了。
#     這條刻意不做內容偵測：Read 的 stdin 只有路徑沒有內容，做不到；
#     而猜檔名的偽陰性方向是「少問一次」，不是「靜默放行一個本來會擋的東西」。
#
# 解析失敗一律 fail-open（exit 0）——不因 hook 自身錯誤卡住工具。
# ============================================================
$ErrorActionPreference = 'SilentlyContinue'

$raw = [Console]::In.ReadToEnd()
if (-not $raw) { exit 0 }
try { $data = $raw | ConvertFrom-Json } catch { exit 0 }

$fp = $data.tool_input.file_path
if (-not $fp) { exit 0 }

# ── 型別防禦（2026-07-31 驗證腿實測的繞法 5）──
# `file_path` 給物件 `{"path":".env"}` 時，$fp 是 PSCustomObject，後面的 -replace 會把它
# 轉成 "@{path=.env}" 之類的字串而比對不中 → **fail-open**。
# 陣列 `[".env"]` 反而還會中（PowerShell 對陣列做 -match 是逐元素）。
# 處置：非字串一律當成「無法判定」→ 保守 ask，不放行。
# 這是 fail-closed，與檔頭「解析失敗 fail-open」的分流不同——那條講的是拿不到任何輸入，
# 這裡是**拿到了但形狀不對**，代表有人在玩參數，該問。
if ($fp -isnot [string]) {
    if ($fp -is [System.Array] -and $fp.Count -eq 1 -and $fp[0] -is [string]) {
        $fp = [string]$fp[0]
    } else {
        $out = @{
            hookSpecificOutput = @{
                hookEventName            = 'PreToolUse'
                permissionDecision       = 'ask'
                permissionDecisionReason = "使用者硬規則「機密不外流」：Read 的 file_path 不是單純的字串（型別：$($fp.GetType().Name)），無法判定要讀什麼——保守先問。"
            }
        } | ConvertTo-Json -Depth 5 -Compress
        [Console]::Out.WriteLine($out)
        exit 0
    }
}

# 正規化：統一成正斜線、取小寫供比對
# （註：PowerShell 的 -match 本來就不分大小寫，ToLowerInvariant 對 regex 比對是冗餘的；
#   保留是因為下面的 .EndsWith／Contains 類字串操作會用到，且讓意圖明確。）
$norm = ($fp -replace '\\', '/')

# ── NTFS 替代資料流（2026-07-31 驗證腿實測的繞法 1，**已驗證真的讀得到明文**）──
# `C:/proj/.env::$DATA` 與 `C:/proj/.env:hidden` 都能讀到同一份內容，
# 但路徑字串尾巴多了 `::$DATA` 就不再匹配 `\.env$` 這類尾錨樣式。
# 處置：比對前先把資料流後綴剝掉。剝的是「最後一個路徑段裡的第一個冒號之後」，
# 不能無條件砍冒號——`C:/...` 的磁碟機冒號會被誤砍。
$lastSeg = $norm.Substring($norm.LastIndexOf('/') + 1)
if ($lastSeg.Contains(':')) {
    $stripped = $lastSeg.Substring(0, $lastSeg.IndexOf(':'))
    if ($stripped) { $norm = $norm.Substring(0, $norm.LastIndexOf('/') + 1) + $stripped }
}

# ── 備份／暫存後綴剝除（2026-07-31 回歸測試找到的繞法）──
# `id_rsa.bak`／`auth.json.bak`／`restic-password.txt.old` 都繞得過**精確比對**的樣式。
# 剝掉常見的備份後綴後再比對；剝除是**疊代**的（`.env.bak.old` 也要中）。
# 上限 3 次避免病態輸入造成長迴圈。
$bakRx = '\.(bak|old|orig|save|copy|backup|tmp|swp|~)$'
for ($i = 0; $i -lt 3 -and $norm -match $bakRx; $i++) { $norm = $norm -replace $bakRx, '' }

# ── 尾端空白／句點剝除 ──
# Windows API 開檔時會 trim 尾端空白與句點，所以 `.env ` 實際讀得到 `.env`
# （T2 建真實檔實測確認），但字串比對不中。
$norm = $norm.TrimEnd(' ', '.')

$lower = $norm.ToLowerInvariant()

# ── `.env` 當**目錄名**（`.env/notes-with-keys.txt`）──
# 樣式錨在檔名段，路徑中間出現 `.env/` 兩支都不中。這類目錄整個就是機密區。
if ($lower -match '(^|/)\.env/') {
    $out = @{
        hookSpecificOutput = @{
            hookEventName            = 'PreToolUse'
            permissionDecision       = 'ask'
            permissionDecisionReason = "使用者硬規則「機密不外流」：路徑位於 `.env/` 目錄底下（該目錄通常整個是機密區）。檔案：$fp"
        }
    } | ConvertTo-Json -Depth 5 -Compress
    [Console]::Out.WriteLine($out)
    exit 0
}

# ── 豁免（放在最前面：範本／範例檔本來就該被讀，且它們是最常見的誤殺來源）──
# `.env.example`／`.env.sample`／`.env.template`／`.env.*.example`、以及公開金鑰 `.pub`
if ($lower -match '\.(example|sample|template|dist)$' -or $lower -match '\.pub$') { exit 0 }

# ── 受保護樣式 ──
# 逐條列出並各自寫明理由，避免日後有人「順手合併成一條大 regex」時丟掉某個入口。
$patterns = @(
    # .env 家族：`.env`、`.env.local`、`.env.production`、`foo.env`
    @{ rx = '(^|/)\.env($|\.[^/]*$)'; why = '.env（環境變數檔，通常含 API key／token）' },
    @{ rx = '(^|/)[^/]*\.env$'; why = '*.env（環境變數檔）' },
    # 憑證與金鑰檔
    @{ rx = '(^|/)\.credentials\.json$|(^|/)credentials[^/]*\.json$'; why = 'credentials json（OAuth／服務憑證）' },
    @{ rx = '(^|/)auth\.json$'; why = 'auth.json（各家 CLI 的 OAuth token 常存在此檔名）' },
    @{ rx = '\.(pem|key|p12|pfx|keystore|jks|p8|ppk|asc|gpg)$'; why = '私鑰／憑證檔' },
    @{ rx = '(^|/)id_(rsa|dsa|ecdsa|ed25519)([._-][^/]*)?$'; why = 'SSH 私鑰（含 id_rsa_work 這類後綴命名）' },
    @{ rx = '(^|/)secrets?\.(json|ya?ml|toml|ini|txt)$'; why = 'secrets 設定檔' },
    # 本工作區特有：restic 密碼與 B2 憑證（丟了＝所有備份打不開）
    @{ rx = '(^|/)restic-password\.txt$|(^|/)b2-credentials\.ps1$'; why = '備份庫解鎖憑證（restic 密碼／B2 金鑰）' },
    # 密碼管理器匯出檔（常被順手放桌面）
    # 註：vault-export 那半刻意加副檔名限定，否則 keyvault-exporter.js／vault-export-guide.md
    # 這類原始碼與說明文件會被一起判 ask，製造確認疲勞（2026-07-31 驗證腿實測誤殺）。
    @{ rx = '(^|/)bitwarden[^/]*\.(json|csv)$|(^|/)[^/]*vault[-_]?export[^/]*\.(json|csv|xml)$'; why = '密碼管理器匯出檔' },

    # ── 2026-07-31 第二輪：跨家族驗證腿實測「靜默放行」的家族，逐一補上 ──
    # 共同根因：原清單只想到「有副檔名的機密檔」，但實務上最常見的憑證檔**沒有副檔名**。
    @{ rx = '(^|/)\.aws/credentials$|(^|/)\.aws\\credentials$'; why = 'AWS 憑證（~/.aws/credentials，無副檔名）' },
    @{ rx = '(^|/)\.netrc$|(^|/)_netrc$'; why = '.netrc（明文存 host 帳密，curl/git 會自動讀）' },
    @{ rx = '(^|/)\.git-credentials$'; why = '.git-credentials（git 明文憑證儲存）' },
    @{ rx = '(^|/)\.npmrc$|(^|/)\.pypirc$'; why = '套件管理器設定（常含 _authToken／registry 密碼）' },
    @{ rx = '(^|/)\.kube/config$|(^|/)\.kube\\config$'; why = 'kubeconfig（叢集憑證）' },
    @{ rx = '(^|/)\.docker/config\.json$|(^|/)\.docker\\config\.json$'; why = 'docker config（registry 認證）' },
    # GCP／Firebase 服務帳戶金鑰：含 .json 但不含 credentials 字樣，是最常見的外洩載體之一
    @{ rx = '(^|/)[^/]*service[-_]?account[^/]*\.json$'; why = 'GCP 服務帳戶金鑰' },
    @{ rx = '(^|/)firebase[-_]adminsdk[^/]*\.json$'; why = 'Firebase Admin SDK 金鑰' },
    # gh CLI 的 token 存放處（本機 gh 為雙裝，見 pending-decisions 第 4 組）
    @{ rx = '(^|/)gh/hosts\.ya?ml$|(^|/)gh\\hosts\.ya?ml$'; why = 'GitHub CLI hosts.yml（內含 token）' }
)

# outcome 觀測：記 ask 到 governance-logs。fail-open。
# env 重導向限 TEMP——settings 的 env 是 hook 的隱性不可信輸入（2026-07-31 已一手實證：
# 隔離 fixture 的 settings.env 金絲雀確實注入到 hook 子行程，且能改寫 log 落點）。
function Write-GovLog([string]$hook, [string]$decision, [string]$why) {
    try {
        $dir = Join-Path $HOME '.claude\governance-logs'
        if ($env:GOVLOG_DIR) {
            try {
                $c = [IO.Path]::GetFullPath($env:GOVLOG_DIR)
                if ($c.StartsWith([IO.Path]::GetFullPath(([IO.Path]::GetTempPath())), [System.StringComparison]::OrdinalIgnoreCase)) { $dir = $c }
            } catch { }
        }
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $f = Join-Path $dir ('decisions-' + (Get-Date -Format 'yyyy-MM') + '.jsonl')
        $line = @{ ts = (Get-Date -Format 'o'); hook = $hook; decision = $decision; why = $why } | ConvertTo-Json -Compress
        Add-Content -Path $f -Value $line -Encoding utf8
    } catch { }
}

foreach ($p in $patterns) {
    if ($lower -match $p.rx) {
        Write-GovLog 'guard-read-secrets' 'ask' $p.why
        $reason = "使用者硬規則「機密不外流」：正在讀取 $($p.why)。" +
                  "讀進來的內容會留在 context 裡，之後可能經摘要／log／截圖／對外呼叫流出去。" +
                  "確認這次真的需要看它的內容再放行（只是要確認檔案存在的話用 ls／Glob）。檔案：$fp"
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
}
exit 0
