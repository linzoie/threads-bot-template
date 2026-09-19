#!/usr/bin/env pwsh
# ============================================================
# guard-workflow-prior-art.ps1  —  PreToolUse hook (matcher: ^Workflow$)
#
# 【為什麼存在】2026-09-19：同一個 session 內，我對「Dify vs n8n 哪個好」派了
# 7 支 workflow，而正確答案（兩者是正交零件、不是二選一）**早在 1 小時 06 分前
# 就由我自己寫進 research-decisions/2026-09-19-dify-platform-evaluation.md 的
# §5.4**。五支偵察腿無一引用該檔。同一份檔案的 §5.3 還逐字寫著「『繼續自己寫』：
# 一級選項……這一格在既有偏好下幾乎必然勝出，卻從未被當一級選項 steelman」——
# 它把「本輪缺席」記成缺失，我隔一小時再缺席一次。
#
# 失效點不在知識（memory components-not-alternatives 早就存在、我自己寫的歸檔
# 也存在），在**檢索時機**：收到二選一的問法時直接進入比較模式，沒有先問
# 「這題以前裁定過沒有」。這是 memory precaution-needs-live-trigger 的形狀——
# 知道規則 ≠ 在對的時機執行檢查。所以第四條文字規則沒有用，要機械化。
#
# 【設計：提醒而非阻擋，理由】
# 誤判成本不對稱：漏提醒的代價是重做一輪研究（昂貴但可回復）；誤擋一個合法
# workflow 的代價是打斷工作流並訓練人忽略這個 hook（不可回復的信任損耗）。
# 且本次失效的性質是「沒想到要查」而不是「查了但無視」——把命中的檔名直接
# 放到眼前就足以解決。若日後出現「提醒了仍照做」的復發，再升級為 ask。
#
# 【fail-safe 性質】任何一步失敗（stdin 空、JSON 壞、歸檔目錄不存在、regex 例外）
# 都靜默 exit 0，退回本檔不存在時的現行行為。本檔壞掉的唯一後果是「沒有提醒」，
# 絕不會阻擋或誤導。降級方向只能是變鬆到「無提醒」，不會變成「看起來查過了」。
#
# 【刻意不做的事】
# - 不讀檔案內容做語意比對：那需要 LLM，而 hook 是同步阻塞的，成本與延遲都不可接受。
# - 不做模糊比對／編輯距離：寧可漏報也不要噪音。噪音會讓人關掉 hook。
# - 不寫任何 state：無狀態，每次獨立判斷，避免「第一次提醒過就不再提醒」的靜默降級。
# ============================================================
$ErrorActionPreference = 'SilentlyContinue'

$raw = [Console]::In.ReadToEnd()
if (-not $raw) { exit 0 }
try { $data = $raw | ConvertFrom-Json } catch { exit 0 }

if ($data.tool_name -ne 'Workflow') { exit 0 }   # 防禦性；matcher 理論上只送 Workflow

# 歸檔目錄：預設由 USERPROFILE 推導（可攜，不硬編使用者名）；允許環境變數覆寫以利測試。
$archiveDir = Join-Path $env:USERPROFILE 'Documents/Claude/research-decisions'
if ($env:GOVERNANCE_RESEARCH_ARCHIVE_DIR) { $archiveDir = $env:GOVERNANCE_RESEARCH_ARCHIVE_DIR }
if (-not (Test-Path $archiveDir)) { exit 0 }

# 取 script（inline）或 scriptPath（檔案）的內容當語料
$script = $data.tool_input.script
if ([string]::IsNullOrWhiteSpace($script)) {
    $sp = $data.tool_input.scriptPath
    if (-not [string]::IsNullOrWhiteSpace($sp) -and (Test-Path $sp)) {
        $script = Get-Content $sp -Raw -ErrorAction SilentlyContinue
    }
}
if ([string]::IsNullOrWhiteSpace($script)) { exit 0 }

# 只從 meta 的 name 與 description 抽關鍵詞——那兩個欄位是作者對**主題**的自述。
# 2026-09-19 首次測試實測修正：原本抽整個 meta 區塊，結果 phases 的 title（如 'Scan'）
# 與 detail 也被抽進來，害「深度研究」「scan」這類流程詞命中一堆無關歸檔（正對照 1
# 命中 6 筆，其中 2 筆是純噪音）。phases 描述的是流程階段、不是主題，必須排除。
$metaText = ''
try {
    $m = [regex]::Match($script, 'export\s+const\s+meta\s*=\s*\{(.+?)\n\}', 'Singleline')
    if ($m.Success) {
        $body = $m.Groups[1].Value
        foreach ($field in @('name', 'description', 'whenToUse')) {
            $fm = [regex]::Match($body, ("(?m)^\s*{0}\s*:\s*(['""`])(.*?)\1" -f $field))
            if ($fm.Success) { $metaText += $fm.Groups[2].Value + ' ' }
        }
    }
} catch { }
if ([string]::IsNullOrWhiteSpace($metaText)) { exit 0 }

# 停用詞：workflow 樣板與治理詞彙，出現在幾乎每支 script 裡，比對價值為零
$stop = @(
    'name','description','phases','title','detail','model','true','false','null',
    'workflow','agent','agents','research','deep','verify','scout','phase','report',
    'opus','sonnet','fable','haiku','claude','const','export','meta',
    '偵察','驗證','綜合','對抗','研究','報告','分析','評估','深研','紅隊','腿','支',
    # 2026-09-19 第二輪實測補：通用流程詞會命中一堆無關歸檔。中文抽詞抓的是連續字串，
    # 所以「深度研究」不會被「研究」這個停用詞攔到，必須整串列出。
    '深度研究','深度','完整','詳細','可行性','比較','選擇','選型','方案','角度','並行'
)

$tokens = @()
try {
    # 英數詞（>=3 字元）與中文詞（>=2 字元）分別抽
    foreach ($mm in [regex]::Matches($metaText, '[A-Za-z][A-Za-z0-9._-]{2,}')) {
        $t = $mm.Value.ToLowerInvariant().Trim('.','_','-')
        if ($t.Length -ge 3 -and $stop -notcontains $t) { $tokens += $t }
    }
    foreach ($mm in [regex]::Matches($metaText, '[一-鿿]{2,}')) {
        $t = $mm.Value
        if ($stop -notcontains $t) { $tokens += $t }
    }
} catch { exit 0 }

$tokens = @($tokens | Select-Object -Unique | Where-Object { $_.Length -ge 2 })
if ($tokens.Count -eq 0) { exit 0 }

# 比對：檔名命中（強訊號）＋ 標題行命中（次強）。不掃全文內容——噪音太大。
$hits = @{}
try {
    $files = @(Get-ChildItem -Path $archiveDir -Filter '*.md' -File -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
        $base = $f.BaseName.ToLowerInvariant()
        $matched = $null
        foreach ($t in $tokens) {
            if ($base -like "*$t*") { $matched = $t; break }
        }
        if (-not $matched) {
            # 只讀前 40 行找標題與一句話結論，避免整檔掃描的成本與噪音
            $head = (Get-Content $f.FullName -TotalCount 40 -ErrorAction SilentlyContinue) -join "`n"
            if ($head) {
                foreach ($t in $tokens) {
                    if ($t.Length -ge 4 -and $head.ToLowerInvariant().Contains($t)) { $matched = $t; break }
                }
            }
        }
        if ($matched) { $hits[$f.Name] = $matched }
    }
} catch { exit 0 }

if ($hits.Count -eq 0) { exit 0 }

# 命中太多代表關鍵詞太泛（例如只抽到「工具」），那是噪音不是訊號——靜默放行
if ($hits.Count -gt 6) { exit 0 }

$lines = @()
$lines += '【既有裁定偵測】research-decisions/ 裡有與本次 workflow 主題相關的歸檔：'
foreach ($k in ($hits.Keys | Sort-Object -Descending)) {
    $lines += ("  - {0}  (命中詞: {1})" -f $k, $hits[$k])
}
$lines += ''
$lines += '發射前先讀上列檔案的「一句話結論」與「若要重啟，第一步是什麼」兩段，確認這題是否已被裁定過。'
$lines += '2026-09-19 實例：同一 session 內隔 1 小時 06 分對同一題重跑 7 支 workflow，而正解已寫在自己 1 小時前的歸檔 §5.4。'
$lines += '若確認是新題目或要刻意重做，直接繼續即可——本提醒不阻擋。'

$msg = $lines -join "`n"

# PreToolUse 的 additionalContext：把命中檔名直接放到眼前，不需要想起來要查
$out = [ordered]@{
    hookSpecificOutput = [ordered]@{
        hookEventName     = 'PreToolUse'
        additionalContext = $msg
    }
}
$out | ConvertTo-Json -Depth 6 -Compress
exit 0
