---
name: customization-guide
description: |
  Use this skill whenever the user is forking / cloning / customizing this template
  for their own brand, or when editing src/drafter.py (SYSTEM/STRANGER_SYSTEM),
  src/rules.py (RULES), or keywords.txt — even if not explicitly asked.
  Guides filling in the three customization touchpoints, with safety rails.
allowed-tools: Read, Write, Edit, Grep, Glob
---

# threads-bot-template：客製化引導

這是一個**教學範本**。Fork 後想真正能用，要客製化「**三件套**」+ 一個安全選項。

## 三件套的角色

| 檔案 | 做什麼 | 影響哪個 Feature |
|---|---|---|
| `src/drafter.py` 的 `SYSTEM` | Layer 3 Claude 的人設＋合規護欄＋判斷規則 | Feature #1（自家貼文自動回覆） |
| `src/drafter.py` 的 `STRANGER_SYSTEM` | 對「陌生人貼文」要用什麼角度草擬回覆 | Feature #2（陌生人貼文草擬） |
| `src/rules.py` 的 `RULES` | Layer 2 商業關鍵字 → 固定模板回覆 | Feature #1 的 fast path |
| `keywords.txt` | `find_drafts.py` 用來搜尋陌生人貼文的關鍵字 | Feature #2 的觸發源 |

> **Feature #1 在 Meta dev mode 就能跑**；
> **Feature #2 必須過 Meta App Review** 拿到 `threads_keyword_search` 權限才會回真資料（dev mode 下 API 不報錯、但回空陣列）。先把 Feature #1 跑起來再考慮 #2。

## 客製化步驟（建議順序）

### Step 1：客製 `SYSTEM`（最重要）

`src/drafter.py` 開頭已寫好「填空指引」，按裡面的範例改。**每個領域都要設「絕對禁止」**：

| 你的領域 | 必設的「絕對禁止」範例 |
|---|---|
| 財務 | 不薦商品（具體股票/ETF/基金）、不保證報酬、不公開給個人化財務建議 |
| 醫療 | 不給診斷、不給用藥建議、引導去看醫生 |
| 法律 | 不給具體法律意見、引導去找律師 |
| 健身 | 不給特定醫療診斷、不替補劑/品牌背書 |
| 心理 | 不取代專業諮商、嚴重情緒引導去找專業 |
| 教育 | 不替學生做作業／代寫、不給特定升學保證 |

→ **沒有自家領域「絕對禁止」就直接跑 bot 是高風險的** —— Claude 可能寫出讓你違規／挨告的話。

### Step 2：客製 `STRANGER_SYSTEM`（要用 Feature #2 才需要）

要決定：陌生人貼文裡你會用什麼角度切入草擬回覆？是「先肯定再補充」、「直接給專業觀點」、還是「丟一個延伸問題」？這影響 `find_drafts.py` 的草稿品質。

### Step 3：客製 `RULES`（視業務需要）

範本繼承 threads-bot 的 4 條規則（consultation / collab_or_sponsor / pricing / emoji_or_praise），都是通用商業詢問。多數人 fork 後要做的：

- 保留 `emoji_or_praise`（純表情／單字回覆 → 用 emoji 回的邏輯通用）
- 改寫 consultation / collab / pricing 的觸發詞與回覆模板成你業務用語
- 加你業務常被問的「重複型」問題（例：營業時間、地址、預約方式）

→ 標準：「**未來 30 天內**會被問 10 次以上」的問題才值得加規則。

### Step 4：客製 `keywords.txt`（要用 Feature #2 才需要）

`keywords.txt` 預設整份註解 + 兩個品牌範例（財務／健身）。寫你的關鍵字前先想：

- **避開會被 MLM／詐騙留言淹沒的詞**（例：投資、賺錢、副業、被動收入、加密貨幣）
- 避開違反你「絕對禁止」會招麻煩的詞
- 從 3–5 個最核心的開始試，跑一週看 `find_drafts.py` 的 approve/skip 比例再增刪

### Step 5：保留 `DRY_RUN=true` 直到你信任輸出

`.env.example:26` 預設 `DRY_RUN=true`。**所有客製化都在 dry-run 下試 1–2 週**，看 log 中的 `dry_run` 紀錄判斷品質。確認 OK 再改 `DRY_RUN=false`。

### Step 6：自己補測試（強烈建議）

範本沒測試。Fork 後請參考 `code/threads-bot/test_pipeline_mock.py` 的 13 個 mock case 自己寫一份。針對你新加的 RULE、客製過的 SYSTEM 各補幾個 case。

## 客製化前的安全檢查清單

- [ ] 我有為自己的領域寫「絕對禁止」嗎？
- [ ] 我有先在本機跑 `python verify.py` 確認 Threads + LLM 連線 OK 嗎？
- [ ] 我有把 `DRY_RUN` 保留為 `true` 嗎？
- [ ] 我的 `.env` 確定沒被 git 追蹤嗎？（`.gitignore` 已涵蓋，但 fork 後請自己再確認一次）
- [ ] 客製化內容是不是包含商業機密／個人品牌細節？→ 那些 commit 到你自己的私人 repo，**不要 PR 回這個公開範本 repo**。

## 反例

- ❌ Fork 後沒改 SYSTEM 就直接跑 —— bot 寫出來的回覆會 generic 且可能違反你的領域規範。
- ❌ 把客製化後的品牌 SYSTEM PR 回公開範本 repo —— 範本要維持「填空骨架」。
- ❌ 直接 `DRY_RUN=false` 跑全新客製化 —— 沒先觀察 dry-run 紀錄，會發出沒驗證過的回覆。
- ❌ 加「投資」、「賺錢」進 `keywords.txt` 卻沒做反 MLM 過濾 —— `find_drafts.py` 會被洗版。