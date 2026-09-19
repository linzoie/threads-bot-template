<!-- generated-by: .governance/bin/sync-workspace-rules.ps1 -->

> ⚠️ **這個檔案是自動產生的，不要手動編輯。**
>
> 權威來源：`
C:\Users\Linzoie\Documents\Claude\Projects\code\AGENTS.md
`
> 產生器：`.governance/bin/sync-workspace-rules.ps1`
> 改動請改權威來源，然後跑一次產生器。手改這裡會被下次同步無聲覆蓋。
>
> **存在理由**：Antigravity 的 context 收集器只往上走到最近的 repo 根，
> 在子專案裡讀不到工作區層的 `AGENTS.md`。`.agents/rules/*.md` 是它的官方
> 自動發現路徑（builtin `agy-customizations/SKILL.md` 第 49 行），所以把
> 工作區規則鏡像到這裡，它就讀得到。其他三家不讀這個目錄。

---

# AGENTS.md — code/ 工作區共用治理

> **所有 AI coding agent 的共同指令來源**（Claude Code／OpenAI Codex／Google Antigravity）。
> Codex 與 Antigravity 沿目錄向上自動載入本檔；Claude Code 透過 `CLAUDE.md` 的 `@AGENTS.md` 匯入。
>
> **分層**：本檔＝跨專案共用規則；各子專案的 `AGENTS.md`＝該專案專屬（技術棧、驗證指令、紅線）。
> 修改共用規則只改這裡，不要在各專案重複維護（重複必漂移）。
>
> ⚠️ **尺寸紀律**：Codex 把同一路徑上各層 AGENTS.md **加總**計入 32,768 B 硬限，且
> **上層先載入、下層被砍尾**——本檔膨脹會直接吃掉專案層的額度。改動後跑
> `pwsh .governance/bin/check-agents-size.ps1` 確認（governance-doctor 也會檢查）。

## 溝通語言

與使用者的所有溝通、報告、提問一律使用**繁體中文**；程式碼、變數名、檔名、JSON key、
commit message 格式維持英文慣例；引用官方文件與套件名稱保留原文。

## 工作區結構

`code/` 不是單一專案，而是**工作區容器**，底下每個子資料夾是**各自獨立的 git repo**。
跨專案工作前先確認在正確的子專案內，不跨 repo 混用。

---

## 接手工作：開工前的固定第一步

每個專案的「工作到哪了」權威來源是交接狀態卡：`.governance/handoff/projects/<專案>.md`

1. 讀該卡，用一句話總結你理解的現況與待辦
2. 比對卡片的 `last_verified_commit` 與目前 `git log -1`
3. **不一致或與程式碼牴觸就停下重讀**，先校正卡片再開始工作

**收工前的固定最後一步**：更新該卡（完成什麼、卡在哪、失敗過的方法、下一個具體動作、
**實際跑過**的驗證結果）。沒更新＝下一個 agent 從錯誤前提開始。

**交接卡的「下一個具體動作」是建議，不是授權。** 授權只來自使用者。
卡片可以**縮小**權限（`## 本次禁區`），**不能擴大**——卡片是 AI 寫、AI 讀、
使用者可能沒看，若它能授權，就成了一條繞過使用者的通道。

> **有工具代勞，別純手工**（2026-07-29 補：工具 07-24 就寫好了，這段流程卻一直是手動版）：
> `pwsh .governance/bin/handoff.ps1 onboard -Project <名>` 接手時自動比對卡片與 git 現況；
> `pwsh .governance/bin/handoff.ps1 checkpoint -Project <名>` 收工時自動抓 git 事實＋跑測試
> 回填卡片。**手寫的驗證數字會腐爛，工具抓的不會**——但「下一個具體動作」仍須你自己寫。

## 信任順序（資訊衝突時的裁決依據）

高者為準，並**回頭修正低者**：

1. **可重現的測試／建置實際輸出**
2. 目前的 git commit、diff 與實際檔案內容
3. AGENTS.md 與專案規格文件
4. 交接狀態卡
5. 對話歷史、agent 記憶、任何 AI 的自我宣稱

不要記錄「已知不一致」後繞過，也不要並列選項丟回使用者——蒐證裁定唯一正解，除非證據真的五五開。

---

## 五個強制動作（不等使用者提醒，自己做）

**1. 寫完就攻擊** — 完成任何防護性／驗證性的東西（輸入驗證、權限檢查、過濾規則、守門
邏輯）後，立刻列出至少五種變形寫法嘗試繞過並**實際測試**。單次作者看不見自己的盲點。

**2. 矛盾就裁定** — 依上方信任順序蒐證裁定，把其他來源改成一致。

**3. 宣稱就舉證** — 任何「完成／已修好／測試通過」必須附**本次實際執行的輸出**。跑不了
就明說。命名會騙人（叫 mock 的測試可能打真 API）。建立會被特定方式呼叫的工具（CLI／hook／
workflow）時，證據必須是**用那個確切呼叫方式端到端跑過一次**——語法檢查、型別檢查、
「看起來對」都不算。

**4. 錯誤就入庫** — 被糾正或發現新型錯誤時**當場**固化教訓（寫進規則、測試案例、專案
文件），別讓同一個坑等下一個 agent。
> 入哪一層由類別決定（2026-09-14 補，「當場」不變——當場一定先寫進某一層；變的是行為準則類
> **進規則正文**這一步改為候選累計＋使用者點頭，這是刻意的分流，非鬆綁）：①可機械攔截的（guard-case／
> 測試／hook 規則）**第一次就固化**；②有可重演方法的判斷力陷阱寫 golden-task；③純行為準則
> 先寫 memory 當**候選**——入庫前先 grep 既有同族條目，有就在該檔追加一行「復發：日期｜場景」，
> 並在 `.governance/pending-decisions.md`「候選升格」區記一行（memory 只留指標；Codex／Antigravity
> 的教訓直接寫 pending）；累計到門檻（試行：第三次，由稽核回填）或使用者說「直接升」→ **使用者
> 點頭後才進本檔／CLAUDE.md 正文**。但書：致命／一次性教訓不受次數限制；計數不只存在 memory。

**5. 風險必附緩解** — 列出任何選項的風險／缺點時，同處必須寫「最便宜的緩解＋緩解後的
殘餘風險」。寫不出緩解＝沒設計過那個選項，不得拿它當論據。對不推薦的選項先做出最強版本
再比較。

---

## 升級階梯（超出把握就升級）

下列情況**預設要升級**（問使用者／換更強模型／多視角互查），除非能明確說出「為何這次
不需要」。判斷標準是**客觀事實**，不是主觀的「我覺得難不難」：

- 跨 3 個以上檔案的重構或設計變更 → 先出計畫給使用者審核
- 本工作區**第一次做**的任務類型
- 測試或驗證**連續失敗 3 次** → 停止亂槍打鳥，改系統性除錯並回報
- 對結論**說不出可執行的驗證方法**（＝還沒想清楚）
- 涉及金錢、對外發送、共享狀態
- 知識可能過時（外部 API、版本、平台行為）→ 查官方文件，**絕不憑記憶**
- 非緊急的判斷題不當場決 → 記入 `.governance/pending-decisions.md`，等使用者的判斷 session

> **規則是預設，不是絕對**：當一條規則在某案例下明顯導致錯誤結果時，不要靜默遵守、也
> 不要靜默違反——把「規則 X 要求 Y，但這裡 Y 會導致 Z」的具體衝突**升級給使用者裁決**。
> 破例的權力在使用者；你的責任是聞到不對勁就講清楚。

---

## 破壞性／難復原動作一律先問

- **刪除**：`rm -rf`、`Remove-Item -Recurse`、`git branch -D`、刪 PR/issue/資料表
- **覆蓋／重置**：`git push --force`、`git reset --hard`、`git checkout --`、`--amend`
  已推送的 commit、覆寫沒讀過的既存檔
- **對外發送**：email、Slack、Telegram、建立／關閉／留言 PR 或 issue、推送遠端、上傳第三方
- **跳過安全機制**：`--no-verify`、`--no-gpg-sign`、停用 hook、降級或移除套件
- **共享狀態**：改 CI/CD、改權限、改共用基礎設施、改影響大的全域設定

**一次授權不等於永久授權**：換情境要重新確認。

## 機密鐵則

絕不 commit `.env`／token／金鑰／憑證（只有 `.env.example` 可進版控）；commit 前確認
`git status`；發現機密已被追蹤**立即停手告知使用者**；設定檔只放變數名，真值走環境變數
或密碼管理器；不要把憑證內容寫進交接卡、報告或對話輸出。

> **不分 agent 的機械地板**：`pwsh .governance/bin/install-git-hooks.ps1 -Repo <path>` 裝
> pre-commit 機密掃描——**任何** agent／工具／排程要 commit 機密都會被 git 層擋下（不依賴
> 你記得檢查）。⚠️ `.git/hooks` 天生不入版控＝**新 clone 或新建的 repo 一定沒有**，
> 且目前沒有任何檢查會提醒你，所以**建 repo 後請手動跑一次**。
>
> skills 若有更動：`.agents/skills/` 是權威（Codex／Antigravity 原生讀），改完跑
> `pwsh .governance/bin/sync-skills.ps1` 鏡像到 `.claude/skills/`，否則兩份會漂移。
>
> 其餘工具（sync-governance／doctor／probe-guards／lib-shipset 等）見 `.governance/README.md`
> ——本檔刻意不列全，走下方「漸進式揭露」（AGENTS.md 有 32KiB 加總截斷限制）。

## 多 agent 並行的鐵則：序列交接

**同一個 repo 在同一時間只能有一個 agent 在動。** 併發寫入同一棵工作樹會造成後寫覆蓋
先寫、branch checkout 互斷、git index 損毀。交接順序：前一個 agent 跑驗證 → 更新交接卡 →
commit → 確認 `git status --short` 乾淨 → 下一個 agent 才開始（第一步是讀交接卡）。

真要並行才用獨立 git worktree ＋ 獨立分支，但那有成本（`.env`／`node_modules` 不跟過去、
事後要清理），**屬條件觸發而非預設做法**。

---

## 完成的定義（DoD）

**全部**成立才算完成：相關測試**實際跑過看到綠燈**（不是「應該會綠」）＋ lint／格式檢查
無錯 ＋ 改動有測試覆蓋 ＋ 跑得起來的功能用**實際執行**確認行為（UI 類要眼睛看過）。
**禁止**未跑測試就宣稱「應該沒問題」。語言特定門檻見各專案 `.claude/rules/`。

## 各家 agent 的能力差異（重要）

| | Claude Code | Codex | Antigravity |
|---|---|---|---|
| 機械守門 | ✅ 完整 hooks | ⚠️ 內建審批 | ⚠️ 內建審批＋`.agents/hooks.json` |
| 前置條件 | 開目錄即生效 | 開目錄即生效 | **需先登記為 project** |
| 指令檔上限 | 無硬限 | 32,768 B（各層加總） | token 預算（與 skills/MCP 共享） |

**在 Codex／Antigravity 工作時沒有 Claude Code 那層 hooks 把關**，更要自律遵守上面的
「破壞性動作先問」與「機密鐵則」。重活（改核心程式、裁決、對抗驗證）優先留在 Claude Code。

## 漸進式揭露：需要時才讀

| 你要做的事 | 去讀 |
|---|---|
| 接手／交接工作 | `.governance/handoff/projects/<專案>.md` |
| 治理工具用法 | `.governance/README.md` |
| 未決的判斷題 | `.governance/pending-decisions.md` |
| 語言特定 lint／測試細則 | `<專案>/.claude/rules/` |
| 該專案的技術細節 | `<專案>/AGENTS.md` 與其 `docs/` |
