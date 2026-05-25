@../CLAUDE.md

# threads-bot-template（公開教學範本）

## 這是什麼

Threads 自動回覆 / 草擬 bot 的**公開、無品牌、可 fork** 的教學範本。
跟 `code/threads-bot/` 程式架構幾乎相同，但 `src/drafter.py` 的 `SYSTEM` 與
`STRANGER_SYSTEM` prompt 是**填空骨架**、無品牌客製。

> 想看完整正式版（有品牌客製、有測試、有 webhook 伺服器）→ `code/threads-bot/`
> 想自己 fork 一份 → 直接用這個範本，三件套填空後就能跑。

## 跟 threads-bot 的差異一覽

| 面向 | threads-bot（正式版） | threads-bot-template（範本） |
|---|---|---|
| `src/drafter.py` SYSTEM | 「人生財務整理師」品牌人設 | **填空骨架**，含多領域絕對禁止範例 |
| `src/rules.py` RULES | 4 條商業規則（諮詢／合作／報價／emoji） | 同上 4 條（**fork 後請改成自己的業務**） |
| `keywords.txt` | 5 個 🟢 已啟用關鍵字 | **全部註解**，含財務／健身兩個品牌範例供參 |
| `test_pipeline_mock.py` | 有，13 個 mock case | **無**（fork 後建議自己加） |
| `test_webhook.py` / `webhook_server.py` | 有 | **無**（範本不含 webhook 模式） |
| `debug_*.py` | 有 | 無 |
| `.env.example` `CERT_MODE` 預設 | `mkcert_auto` | `self_signed`（避免 lite 用戶被 UAC 嚇到） |

## 技術棧與關鍵指令

- Python 3.14、Anthropic／Groq、SQLite
- 安裝：`python -m venv .venv` → `.venv\Scripts\python.exe -m pip install -r requirements.txt`
- 開發相依：`.venv\Scripts\python.exe -m pip install -r requirements-dev.txt`（ruff）
- 設定：複製 `.env.example` → `.env`，填 Threads + LLM 金鑰
- 驗證：`python verify.py`
- 執行：
  - `python run_loop.py` — 排程模式（**Feature #1 在 dev mode 就能跑**）
  - `python run_once.py` — 單次測試
  - `python find_drafts.py` + `python review_drafts.py` — Feature #2（**需要 Meta App Review** 過 `threads_keyword_search` 才會回真資料）
- `.bat` 包裝（給非工程師）：`setup / configure / verify / start / start_draft`
- Lint／format：ruff（after-edit hook 自動執行）

## Fork 後必改的「三件套」

| 檔案 | 必改？ | 怎麼改 |
|---|---|---|
| `src/drafter.py` 的 `SYSTEM` | **必改** | 填入你的主題／風格／受眾／絕對禁止；檔案開頭已寫好填空指引與多領域範例 |
| `src/drafter.py` 的 `STRANGER_SYSTEM` | 用 Feature #2 才需改 | 描述要對「陌生人貼文」用什麼策略草擬回覆 |
| `src/rules.py` 的 `RULES` | 視業務 | 範本繼承 threads-bot 的 4 條，多數人 fork 後要換成自己的商業關鍵字 |
| `keywords.txt` | 用 Feature #2 才需改 | 加你品牌的搜尋關鍵字（注意 Meta App Review） |

→ 動三件套之前讀 `.claude/skills/customization-guide`。

## 4 層留言處理管線（與 threads-bot 相同）

```
留言進來
  ├── Layer 0：硬跳（自留言／已回過／無文字）
  ├── Layer 1：安全（敏感關鍵字 → Claude 判定負評）→ 進人工佇列
  ├── Layer 2：規則（rules.py 的 RULES）→ 固定模板
  └── Layer 3：診斷（Claude 一次決定 should_reply + reply）
```

各層的職責與不變量見 `.claude/skills/pipeline-layers`。

## 安全預設（執行行為）

- **`DRY_RUN=true` 是預設值**（`.env.example:26`）—— 任何發布動作都先 dry-run、寫 log，**不真的送出**。要實際送出必須明確改 `.env` 為 `DRY_RUN=false`。
- 速率：`MAX_REPLIES_PER_DAY=80`、`MAX_REPLIES_PER_HOUR=15`。
- 安靜時段：03–07 時不發送。
- **`CERT_MODE=self_signed`** 是範本預設（OAuth 流程用自簽憑證，首次跳警告）；想要零警告改 `mkcert_auto`。

## Token 自動更新

`run_loop.py` 每 24 小時呼叫 `src/token_refresher.py` 續期 Threads long-lived token；冪等、重複呼叫安全。

## 程式碼地圖

- `src/pipeline.py` — 4 層管線路由
- `src/safety.py` / `src/rules.py` / `src/drafter.py` — Layer 1 / 2 / 3
- `src/llm.py` — Claude／Groq 抽象
- `src/state.py` — SQLite 持久化
- `src/threads_client.py` — Threads API 包裝
- `src/oauth*.py` / `src/cert_manager.py` — OAuth 三種 cert 模式
- `src/token_refresher.py` — token 續期
- 根目錄 `run_*.py` / `find_*.py` / `*.bat` — 進入點與 wrappers

## 鐵則（IMPORTANT）

- **絕不** commit `.env`、`.env.backup`、`data/`、`*.log`（`.gitignore` 已涵蓋）。
- **絕不** 把客製化後的品牌 prompt（含商業機密、人設細節）誤推到這個公開範本 repo —— 那是 fork 後該推到自己 repo 的東西。
- Fork 並客製化前讀 `.claude/skills/customization-guide`。
- 改 Layer 1（安全）後**建議** 自己補測試（可參考 threads-bot 的 `test_pipeline_mock.py` 13 個 mock case）。

## 開發流程

預設走 Superpowers 5.1.0 workflow（詳見工作區 `code/CLAUDE.md` 的「開發流程」段，靠 `@../CLAUDE.md` import 已自動拉入）：

1. `/superpowers:brainstorming` — 收斂模糊需求
2. `/superpowers:writing-plans` — 產規格＋逐步計畫，寫進 `specs/`
3. `/superpowers:test-driven-development` — 先寫失敗測試，再實作
4. `/superpowers:verification-before-completion` — 宣稱完成前跑驗證
5. `/superpowers:requesting-code-review` — 完成／合併前審查

遇 bug 用 `/superpowers:systematic-debugging`。動到品牌三件套
（`drafter.py` SYSTEM / `rules.py` RULES / `keywords.txt`）時 `customization-guide`
skill 會自動載入並提醒填空指引與紅線。

## 完成的定義（Definition of Done）

threads-bot-template 任務完成的具體門檻：

- `.venv\Scripts\ruff.exe check .` **0 errors**
  （2026-05-25 已清乾淨；34 個 E402 是根目錄腳本的設計 pattern，已在 `ruff.toml` 加 per-file-ignores）
- 動到品牌三件套（`src/drafter.py` SYSTEM / `src/rules.py` RULES / `keywords.txt`）
  → 必須對齊 `.claude/skills/customization-guide` 的填空指引、不留半套
- 動到 4 層管線（`src/pipeline.py` / `safety.py` / `rules.py` / `drafter.py`）
  → 必須對齊 `.claude/skills/pipeline-layers` 的契約
- **強烈建議**：本範本沒原生測試，若你 fork 後做出較大功能修改，請從
  `code/threads-bot/test_pipeline_mock.py` 抓 13 個 mock case 的設計移植過來
- 跑得起來的功能（`python verify.py`、`python run_once.py` DRY_RUN）已用實際 dry-run 確認

必須做實際執行驗證、看到結果，才能回報完成；**禁止**在未跑驗證時宣稱「應該沒問題 / 應該已修好」。

> Stop hook `.claude/hooks/verify-before-done.ps1` 自動把關 ruff（pytest 分支因本範本沒裝 pytest 會略過）；
> ruff 失敗會強迫 Claude 繼續修，不能宣告完成。
