#!/usr/bin/env pwsh
# ============================================================
# detect-unread-claim.ps1  —  Stop hook（與 verify-before-done.ps1 併掛，互不影響）
#
# 2026-07-30：「未讀檔斷言偵測器」的**讀取端**（設計與完整背景見
# .governance/specs/2026-07-30-unread-claim-detector.md）。
#
# 【要治什麼】模型向使用者提出建議，該建議依賴「某支腳本／hook 的行為是 X」，
# 而模型從沒開過那個檔，只憑印象或從相鄰事實外推 → 使用者對著錯選項裁決。
# 實例：提案「package.json 加 format:check，讓 Stop hook 把 prettier 納入 DoD」，
# 使用者 GO 後才發現 verify-before-done.ps1 對零相依專案跑完 test 就 exit 0、
# 且迴圈只枚舉 lint/typecheck/test —— 加了等於沒加。
#
# 【為何要機械偵測而非再寫一條規則】同機制的文字規則已有三條、內容全部命中，
# 且 golden-task 2026-07-29-three-secondhand-claims 是同一顆模型同一天親手寫的、
# 6.5 小時後就破功 → 排除「不知道」，斷層在「知道」與「當下檢索到」之間。
# 工作區已 25+ 張卡逼近注意力天花板，再寫第五條文字規則邊際效益為負。
#
# 【為何是獨立檔案，不塞進 verify-before-done.ps1】本檔是**啟發式**、必然有誤報。
# 不能讓它的 bug 拖垮既有的 DoD 閘門。Stop 陣列可掛多個 hook。
#
# 【fail-safe：不確定一律放行（⚠️ 與 record-webfetch.ps1 方向相反）】
# 若寫入端（record-reads.ps1）壞掉／未接線，已讀集合會是空的，此時「這個檔沒被讀過」
# 對**每一個**檔都成立 → 會擋下每一個回合、session 卡死。所以：
#   集合檔不存在 或 為空  → exit 0（放行）
#   「沒有證據」≠「證據顯示沒讀過」。
#
# 【誠實邊界——本檔抓不到什麼】（不得從註解移除，否則就是假裝抓得到）
#   1. 用概念稱呼機制（「讓 Stop hook 把關」而非點名 verify-before-done.ps1）→ 結構性失明
#   2. 讀過但沒看懂（找到第一層早退就宣布查清楚了）→ 條件④滿足，放行
#   3. 存在性前提（「補回歸測試」但該專案沒有測試基礎設施）→ 非「工具行為」型
#   4. 跨檔交互（真相同時取決於 hook 邏輯 + package.json 的 script 名稱）
#   5. subagent 內部的 Read 是否觸發主 session PostToolUse＝未確認 → 可能誤報
# → 這是**降低發生率的機械後盾，不是防線**。
# ============================================================
$ErrorActionPreference = 'SilentlyContinue'

$raw = [Console]::In.ReadToEnd()
if (-not $raw) { exit 0 }
try { $data = $raw | ConvertFrom-Json } catch { exit 0 }

# 0) 防迴圈：本 hook 已擋過一輪就放行（沿用 verify-before-done.ps1 的既有慣例）
if ($data.stop_hook_active) { exit 0 }

# 1) 取本回合助理最後訊息。官方文件明文：需要當前回合最終助理文字的 hook 應該用
#    last_assistant_message，而不要讀 transcript（transcript 非同步寫入、可能落後）。
$msg = "$($data.last_assistant_message)"
if ([string]::IsNullOrWhiteSpace($msg)) { exit 0 }

# 2) fail-safe：拿不到已讀集合就放行（見檔頭）
$sid = "$($data.session_id)"
if ([string]::IsNullOrWhiteSpace($sid)) { exit 0 }
$sidSan = ($sid -replace '[^A-Za-z0-9_.-]', '_')
$stateDir = if ($env:GUARD_READS_STATE_DIR) { $env:GUARD_READS_STATE_DIR } else { Join-Path ([IO.Path]::GetTempPath()) 'claude-guard-reads' }
$stateFile = Join-Path $stateDir "$sidSan.txt"
if (-not (Test-Path -LiteralPath $stateFile)) { exit 0 }
$readSet = @(Get-Content $stateFile -ErrorAction SilentlyContinue |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object { $_.Trim().ToLowerInvariant() })
if ($readSet.Count -eq 0) { exit 0 }

# 3) 條件①：徵求核可語氣。沒有在問使用者「要不要做」就不是提案，不管。
$approvalPatterns = @(
    '要我', '要不要', '可以嗎', '好嗎', '如何[?？]', '建議', '我的建議',
    '你決定', '等你', '點頭', '授權', 'GO 嗎', '\bGO\b'
)
$asksApproval = $false
foreach ($p in $approvalPatterns) { if ($msg -match $p) { $asksApproval = $true; break } }
if (-not $asksApproval) { exit 0 }

# 4) 掃出「被指名的可執行／設定檔」候選。副檔名白名單＝行為承載型檔案；
#    .md/.txt 刻意不列（文件不「執行」，斷言其行為的風險型態不同）。
$fileRe = '(?<![\w.-])([A-Za-z0-9_][A-Za-z0-9_.-]{0,60}\.(?:ps1|psm1|mjs|cjs|js|ts|tsx|json|py|sh|bash|yml|yaml|toml))(?![\w])'
$hits = [regex]::Matches($msg, $fileRe)
if ($hits.Count -eq 0) { exit 0 }

# 專案樹內的檔案查找（用於條件②「磁碟上真實存在」）。
#
# ⚠️ 【效能是本 hook 的存亡問題——實測數字，不是猜的】本檔在**每個回合結束**都可能跑。
# 原本用 `Get-ChildItem -Recurse -Filter X | Where-Object {排除 node_modules}`：
# 那是**先遍歷整棵樹、再過濾**，所以 node_modules 照樣被走完。2026-07-30 在 code/
# 工作區實測：找得到的檔 610ms，**找不到的檔（＝正常放行路徑）10,008ms**。
# 一個「放行」就讓回合多等 10 秒、最多 3 個候選＝30 秒 → 這種 hook 必然被關掉。
#
# 改成**剪枝走訪 ＋ 時間預算硬上限**（下降前就跳過重目錄；用 .NET Enumerate* 免 cmdlet 開銷）。
#
# ⚠️ 測量誠實性註記：初版註解曾寫「剪枝後 288ms、快 35 倍」——那個 288ms 是**熱快取**
# 的數字（前一個指令剛走完整棵樹把 FS cache 灌滿），拿它比冷快取的 10,008ms 是不公平的
# 比較。改用測試實測（冷一點的狀態）→ 剪枝走訪在 code/ 仍需 **~3.5 秒**。
# 所以剪枝本身不夠，必須再加一道**時間預算**：超時就當「找不到」→ 條件②不成立 → 放行。
# 這讓最壞延遲從「取決於樹多大」變成「由我們決定的常數」。
#
# 另一候選 `git ls-files`（68ms／161 筆）被否決：它只列 code/ 自己追蹤的檔，
# 子專案（各自獨立 repo、對 code/ 是 gitignore）的檔查不到 → 漏報。
$projRoot = if ($data.cwd) { "$($data.cwd)" } elseif ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { (Get-Location).Path }
$skipDirs = @('node_modules', '.git', '.venv', 'dist', 'out', 'coverage', '__pycache__', '.next', 'vendor')
$searchBudgetMs = if ($env:GUARD_READS_SEARCH_BUDGET_MS) { [int]$env:GUARD_READS_SEARCH_BUDGET_MS } else { 900 }
$existsCache = @{}
# 預算是**全域共用**、不是每個檔名各給一份：訊息裡最多掃 3 個候選檔名，
# 若各給 900ms 最壞就是 2.7 秒。共用一個 Stopwatch → 整個 hook 的搜尋總量有上限。
$sw = [Diagnostics.Stopwatch]::StartNew()
function Test-InProject {
    param([string]$BaseName)
    if ($existsCache.ContainsKey($BaseName)) { return $existsCache[$BaseName] }
    $found = $false
    try {
        $stack = [System.Collections.Generic.Stack[string]]::new()
        $stack.Push($projRoot)
        while ($stack.Count -gt 0) {
            if ($sw.ElapsedMilliseconds -gt $searchBudgetMs) { break }   # 時間預算用盡
            $d = $stack.Pop()
            try {
                foreach ($f in [IO.Directory]::EnumerateFiles($d)) {
                    if ([IO.Path]::GetFileName($f) -ieq $BaseName) { $found = $true; break }
                }
            } catch { }
            if ($found) { break }
            try {
                foreach ($sd in [IO.Directory]::EnumerateDirectories($d)) {
                    if ($skipDirs -notcontains [IO.Path]::GetFileName($sd)) { $stack.Push($sd) }
                }
            } catch { }
        }
    } catch { $found = $false }
    # 超時／例外 → $found 維持 false → 條件②不成立 → **放行**。
    # 代價＝大樹上深處的檔可能查不到而漏報（recall 損失），但方向與整體 fail-safe 一致：
    # 寧可漏報，不可因為「查不動」就擋住使用者的回合。
    $existsCache[$BaseName] = $found
    return $found
}

# 條件③：檔名鄰近有「行為斷言」動詞（在講這個檔會做什麼，而不只是提到它存在）
$behaviorRe = '會|納入|擋|攔|跑|執行|判定|把關|觸發|生效|呼叫|檢查|驗證|自動'
# 條件⑤：排除「提議新建」語境——那本來就還不存在，沒有「該去讀」的對象
$createRe   = '新增|新建|建立|新開|生成|產生|create|scaffold|寫一支|寫一個'

# 【謂詞順序是刻意的：最貴的檢查放最後】④（比對已讀集合，O(n) 記憶體查找）先跑，
# ②（磁碟搜尋，最貴）最後跑。效果：**只有「你提到某檔的行為、而你沒讀過它」這個可疑
# 情況才付搜尋成本**，也就是本 hook 即將擋下的那種情況。日常回合（提到的檔都讀過了）
# 完全不觸發搜尋、零額外延遲。順序反過來寫會讓每個回合都付 ~1-2 秒。
$culprits = @()
foreach ($m in $hits) {
    $name = $m.Groups[1].Value
    $lower = $name.ToLowerInvariant()

    if ($readSet -contains $lower) { continue }                      # 條件④：已讀過 → 放行

    # 取檔名前後各 100 字作為判斷語境
    $s = [Math]::Max(0, $m.Index - 100)
    $len = [Math]::Min($msg.Length - $s, $name.Length + 200)
    $ctx = $msg.Substring($s, $len)

    if ($ctx -notmatch $behaviorRe) { continue }                     # 條件③：沒在斷言行為
    if ($ctx -match $createRe) { continue }                          # 條件⑤：在提議新建
    if (-not (Test-InProject $name)) { continue }                    # 條件②：磁碟上不存在
    if ($culprits -notcontains $name) { $culprits += $name }
    if ($culprits.Count -ge 3) { break }                             # 一次最多報 3 個，避免訊息爆量
}

if ($culprits.Count -eq 0) { exit 0 }

# 5) 命中 → exit 2。官方文件：Stop 的 exit 2「Prevents Claude from stopping」，
#    且 exit 2 時 stdout 被忽略、**stderr 回饋給模型**。
$list = ($culprits | ForEach-Object { "`"$_`"" }) -join '、'
$lines = @(
    "[unread-claim] 你在這則提案裡斷言了 $list 的行為，但本 session 從未開過這些檔。",
    '',
    '這是「掛載式提案」失效模式（同機制已第 3-4 次復發）：依賴某支腳本/hook 的行為卻沒讀它，',
    '使用者會對著一個錯的選項裁決。動手前才發現＝已經花掉使用者的裁決成本。',
    '',
    '請選一個：',
    '  (a) 先讀那些檔（或實際執行它們）確認行為真的如你所說，再重新提案；',
    '  (b) 若無法查證，把該前提明確標成「⚠️ 未驗證」，讓使用者知道自己在對什麼裁決。',
    '',
    '（本偵測器是啟發式後盾、有誤報：若你其實是透過 subagent 讀過、或該檔名只是順帶提及',
    '  而非斷言其行為，說明一句即可繼續——下一輪不會再擋（stop_hook_active）。）'
)
[Console]::Error.WriteLine(($lines -join "`n"))
exit 2