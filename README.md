# Threads Bot Template

> 用 Python + Meta Threads API + Claude API 建一個自動回覆留言、AI 草擬陌生人留言的 Threads bot 樣板。
>
> **這是樣板**——clone 之後填入你的品牌語氣（在 `src/drafter.py` 跟 `src/rules.py`），就能依你的領域跑起來。

合規優先、品牌安全、不踩平台 spam 偵測雷。

---

## 🎯 你會做出什麼

兩個核心功能：

| 功能 | 說明 |
|---|---|
| **① 自動回覆自家留言** | 每 5 分鐘檢查自家最新 8 則貼文，新留言進來自動分類處理：商業關鍵字走固定模板、emoji 回 emoji、一般提問交給 Claude AI、敏感留言標記人工處理 |
| **② AI 草擬陌生人留言** | 你滑 Threads 看到值得留言的貼文，貼進腳本，Claude 用你的品牌語氣寫草稿，你決定要不要貼上送出 |

## 📚 跟著哪份指南做？

依你的程度二選一：

| 文件 | 給誰看？ |
|---|---|
| 🌟 [docs/setup_guide_lite.md](docs/setup_guide_lite.md) | **零基礎、不熟電腦操作的朋友**——4 個 .bat 檔搞定，用 Claude.ai 當 SOS |
| 📖 [docs/setup_guide.md](docs/setup_guide.md) | 想理解架構、做進階客製化、看完整解釋 |
| 📋 [docs/app_review_checklist.md](docs/app_review_checklist.md) | 未來想走 Meta App Review 商業化（可選） |

## 🚀 快速開始

### 不熟電腦操作的朋友（雙擊路線）

1. clone / 下載這個 repo（GitHub 點 Code → Download ZIP）
2. 雙擊 **`setup.bat`** → 自動裝好環境
3. 雙擊 **`configure.bat`** → 跟著精靈填 6 個設定值
4. 雙擊 **`verify.bat`** → 確認連線正確
5. 雙擊 **`start.bat`**（自動回覆）或 **`start_draft.bat`**（陌生人 AI 草擬）

→ 詳細 step-by-step 看 [setup_guide_lite.md](docs/setup_guide_lite.md)

### 工程師路線

```powershell
git clone https://github.com/[YOUR_USERNAME]/threads-bot-template.git
cd threads-bot-template
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
copy .env.example .env
notepad .env   # 填你的 token / key
.\.venv\Scripts\python.exe verify.py
.\.venv\Scripts\python.exe run_loop.py
```

## 🛠️ 技術棧

- Python 3.11+
- Meta Threads Graph API（含**自動 OAuth + token 自動 refresh**，token 一勞永逸）
- Anthropic Claude API（也支援 Groq Llama 切換）
- 三層 pipeline：硬性跳過 → 安全閥 → 關鍵字規則 → AI 診斷
- 多通道警示 notifier（console + log + Telegram-ready；自動 redact secrets）
- 自簽 cert（cryptography）+ 可選 mkcert 整合（OAuth 流程零警告）

## 🏗️ 架構

```
留言進來
  │
  ├─ Layer 0: 硬性跳過 ──────► 自己的留言 / 已回過 / 在靜音時段
  │
  ├─ Layer 1: 負評安全閥 ────► 含敏感字 OR Claude 判定為負評/爭議
  │                          → 不自動回，丟「人工待處理」清單
  │
  ├─ Layer 2: 關鍵字規則 ────► 含「諮詢/合作/報價」等商業字
  │                          → 走預先寫好的固定模板（不呼叫 Claude）
  │                          + 純 emoji / 短讚字 → 回對應 emoji
  │
  └─ Layer 3: 診斷型 ────────► 其他全部交 Claude 判斷
                              → 「要不要回 + 回什麼」一次解決
```

## 🔐 Token 管理（已自動化）

Meta 長效 Token 60 天到期。本 template 內建完整自動化：

### 自動 refresh（背景運作，零人工）

`run_loop.py` 每 24 小時自動檢查 token age：
- 超過 30 天 → 自動呼叫 Meta `/refresh_access_token` 延長 60 天
- 失敗會用 console + log 警示（多通道，可串 Telegram）
- **理論上只要 bot 持續運行，token 永不死**

手動檢查狀態：
```powershell
.\.venv\Scripts\python.exe refresh_token.py --status
```

### Token 真的死了：重做 OAuth（如改密碼 / 撤權 / Meta 撤）

兩個腳本任挑：

| 腳本 | 場景 | 操作 |
|---|---|---|
| `oauth_login.py` | 一般情況（推薦） | 跑腳本 → 瀏覽器跳出 → 按 [Authorize] → 完成 |
| `oauth_paste.py` | port 8443 被佔 / 公司網路擋 localhost | 跑腳本 → 瀏覽器按 [Authorize] → 複製 URL 貼回 terminal |

**一次性 Meta Dashboard 設定**（兩個腳本都需要）：

1. 到 https://developers.facebook.com/apps/ → 你的 App
2. Use cases → Threads → Customize → Settings
3. **重新導向回呼網址 / Valid OAuth Redirect URIs** 加：`https://localhost:8443/callback`
4. Save

#### 三種 cert 模式（`.env` 的 `CERT_MODE` 控制）

| 模式 | 體驗 | 適合 |
|---|---|---|
| `self_signed`（template 預設） | 瀏覽器首次跳「不安全」按「進階→繼續」 | 完全不熟電腦的朋友（不會被 UAC 嚇到） |
| `mkcert_auto` | 第一次自動下載 mkcert (~5MB) + 跳 1 次 UAC → 之後**零警告** | 工程師（最佳體驗） |
| `mkcert_manual` | 自己 `choco install mkcert`，沒裝 fallback 自簽 | 不想讓腳本下載 binary 的人 |

任一模式失敗都會自動 fallback 到自簽，OAuth 流程不會掛。

## 🔍 Feature #2 重要提醒：需要 App Review

`find_drafts.py` + `review_drafts.py` 是「關鍵字搜尋 → AI 草擬 → 人工審核」workflow：

```powershell
# 1. 編輯 keywords.txt（一行一個關鍵字）
notepad keywords.txt

# 2. 自動搜尋 + Claude 草擬 + 進 queue
.\.venv\Scripts\python.exe find_drafts.py

# 3. 互動式審核：A approve（複製到剪貼簿）/ E edit / S skip
.\.venv\Scripts\python.exe review_drafts.py
```

但 Meta 的 `threads_keyword_search` API 在 **dev mode 下不會回傳任何貼文**（不報錯、但回空陣列）。要這個功能能用：

- 走 Meta App Review 過 `threads_keyword_search` 權限（見 [docs/app_review_checklist.md](docs/app_review_checklist.md)）
- App 進入 Live mode 後，`find_drafts.py` 就會抓到真實熱門貼文

Feature #1（自家貼文自動回覆）在 dev mode 就能正常運作，**不需要 App Review**。

## 📝 客製化（必做）

這個 repo 是**樣板**，預設 prompt 是泛用版本，**clone 完後一定要客製化**：

- **`src/drafter.py`** 的 `SYSTEM` 跟 `STRANGER_SYSTEM` → 填你的領域、風格、絕對禁止事項
- **`src/rules.py`** 的 `RULES` → 填你的商業關鍵字 + 對應模板

**不改的話 bot 寫出來的回覆會很 generic、沒有你的個性**。

詳見 [setup_guide.md 的客製化章節](docs/setup_guide.md#customize)。

## ⚠️ 重要：上 GitHub 前的安全檢查

**永遠不要 commit `.env` 到 GitHub**。`.gitignore` 已經幫你擋住，但建議手動再確認：

```powershell
git status
# 應該看不到 .env 在「Changes to be committed」
```

如果不小心傳上去了，**立刻**：
1. 重設 Threads App Secret（dashboard 重新產生）
2. 跑 `oauth_login.py` 或 `oauth_paste.py` 重做 OAuth 取新 token（舊 token 可能被別人撿走）
3. 重設 Anthropic API Key
4. 用 `git filter-branch` 或 BFG 清掉歷史

`notifier.py` 會自動 redact log 裡的 access_token / Bearer，但 `.env` 本身永遠不該進 git。

## 💰 預估成本

| 項目 | 費用 |
|---|---|
| Meta Developer 帳號 | 免費 |
| Anthropic API（Claude Sonnet 4.6） | ~$5 USD / 1-2 個月 |
| Groq API（如果切換） | 免費 tier 夠用 |
| 部署（如果用本機跑 bot） | 免費 |

## 🤝 反饋 / 貢獻

這是樣板，歡迎 fork 後做自己的版本。如果有改進建議或發現 bug，可以開 issue 或 PR。

## 📄 授權

MIT License — 自由使用、修改、分享，但作者不負責你拿來怎麼用。

---

**Built with [Anthropic Claude](https://www.anthropic.com/claude) + [Meta Threads API](https://developers.facebook.com/docs/threads)**
