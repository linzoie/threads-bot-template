# AGENTS.md — threads-bot-template

> 共用治理規則見工作區層 `../AGENTS.md`（Codex／Antigravity 會沿目錄向上自動載入；
> Claude Code 由 `CLAUDE.md` 匯入）。本檔只放**本專案專屬**內容。

## 這個專案是什麼

Threads 自動回覆／草擬留言 bot 的**公開、無品牌、可 fork** 教學範本（MIT）。
`src/drafter.py` 的 `SYSTEM`／`STRANGER_SYSTEM`、`src/rules.py` 的 `RULES`、
`keywords.txt` 是**填空骨架**——三件套填完才是可用的真實 bot。與私有正式版
`threads-bot/` 同構但刻意「去品牌」，是一對但**分屬不同 repo、不共用機密**。

## 技術棧與進入點

Python 3.14、Anthropic／Groq、SQLite；4 層留言管線（Layer 0 硬跳／1 安全／
2 規則／3 診斷，見 `.claude/skills/pipeline-layers`）。

- 安裝：`python -m venv .venv` → `.venv\Scripts\python.exe -m pip install -r requirements.txt`
  （dev 相依另裝 `requirements-dev.txt`，含 ruff）
- 設定：複製 `.env.example` → `.env`，填 Threads + LLM 金鑰
- 驗證指令：`.venv\Scripts\ruff.exe check .`（須 0 errors；**本範本無自動化測試**，
  Stop hook 的 pytest 分支會因未裝 pytest 自動略過）
- 執行：`python verify.py`（連線檢查）／`python run_loop.py`（排程，Feature #1
  dev mode 可跑）／`python run_once.py`（單次）／`find_drafts.py`+`review_drafts.py`
  （Feature #2，**需過 Meta App Review** 拿 `threads_keyword_search` 才回真資料）
- `.bat` 包裝給非工程師：`setup/configure/verify/start/start_draft`
- 客製化前必讀 `.claude/skills/customization-guide`；動 4 層管線前必讀
  `.claude/skills/pipeline-layers`

## 本專案的紅線

- **公開範本、絕不可品牌化外洩**：這是公開 GitHub repo。**絕不**把客製化後的
  品牌 SYSTEM prompt、真實業務規則、商業機密 PR 或 commit 回這個 repo——
  那些屬於 fork 後的使用者自己的私人 repo。
- **絕不** commit `.env`／`.env.backup`／`data/`／`*.log`（`.gitignore` 已涵蓋，
  但每次 commit 前仍要 `git status` 二次確認）。
- **`DRY_RUN=true` 是範本硬預設**（`.env.example:26`）——任何改動都不得把預設
  值改成 `false`；那是 fork 使用者自己判斷後才做的事。
- **Feature #2（`find_drafts.py`）在 dev mode 下 API 回空陣列不報錯**——測試/
  改動這條路徑時不要誤判「沒資料＝壞了」，那是 Meta 平台限制非本專案 bug。
- **範本刻意不含**：真實品牌人設、webhook 模式、自動化測試。不要「順手」補上
  這些——它們是刻意的設計留白（見 `CLAUDE.md`「範本刻意不含的東西」表），
  要加也該先跟正式版 `threads-bot/` 的同步準則對齊，不能單方在此 repo 加。
- 改 Layer 1（安全閥）後建議自己補 mock case 測試，但**不要**把測試寫死在
  本範本裡當成「已附測試」——README 明載無測試，改動此宣稱前先確認一致。

## 接手前先讀

`.governance/handoff/projects/threads-bot-template.md`（狀態卡＝「做到哪了」的
權威來源）；正式版同步準則見 `threads-bot/docs/SYNC_POLICY.md`（在另一個 repo）。
