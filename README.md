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
- Meta Threads Graph API
- Anthropic Claude API（也支援 Groq Llama 切換）
- 三層 pipeline：硬性跳過 → 安全閥 → 關鍵字規則 → AI 診斷

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
2. 重做 OAuth 取新 token（舊 token 可能被別人撿走）
3. 重設 Anthropic API Key
4. 用 `git filter-branch` 或 BFG 清掉歷史

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
