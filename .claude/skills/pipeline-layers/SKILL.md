---
name: pipeline-layers
description: |
  Use this skill whenever editing or extending src/pipeline.py, src/safety.py,
  src/rules.py, or src/drafter.py — even if the user doesn't explicitly ask.
  規範 4 層留言處理管線的職責邊界、擴充原則與測試守則。
allowed-tools: Read, Write, Edit, Grep, Glob
---

# threads-bot-template：4 層管線契約

`src/pipeline.process()` 是**唯一**的 routing 點。任何留言都必須循這 4 層走過一次，
順序固定、不准跳層。

## 各層職責

| 層 | 檔案 | 做什麼 | 不做什麼 |
|---|---|---|---|
| **0 硬跳** | `pipeline.py` | 自留言、重複留言、無文字 → 跳過 | 不做任何判斷邏輯，純資料檢查 |
| **1 安全** | `safety.py` | 敏感關鍵字 + Claude 負評分類 → **進人工佇列**（不自動回） | 不回任何留言；不在這裡套品牌話術 |
| **2 規則** | `rules.py` | 命中商業關鍵字（諮詢／合作／報價）或 emoji → 套**固定模板**回覆 | 不呼叫 LLM；first-match-wins，順序敏感 |
| **3 診斷** | `drafter.py` | Claude **一次** 決定 `should_reply` + `reply` 內容 | 不再做安全分類（Layer 1 已過濾） |

## 不變量（絕不能違反）

1. **層的順序是 Layer 0 → 1 → 2 → 3，不可重排**。順序代表「成本 → 確定性 → 可解釋性」遞減。
2. **Layer 1 的結果只有兩種**：放行下一層、或丟人工佇列。**不准**在 Layer 1 自動回覆。
3. **Layer 2 不准呼叫 LLM**。規則的價值就在於確定性。
4. **Layer 3 不准做安全檢查**。負評／法律／自殘已在 Layer 1 攔走；Layer 3 預設輸入是「乾淨的」。
5. **DRY_RUN 永遠在 `_send` 入口檢查**，不准任何路徑繞過。

## 何時加規則（Layer 2）vs. 交給 Layer 3

- **加規則**：同樣的話術重複出現、回覆內容**不需要**因人而異（例：所有「報價」問題都回同一句話）。
- **交給 Layer 3**：每則留言都需要個別理解（提問、感謝、討論、分享經驗）。

→ 標準：「**未來 30 天內**，預估這個話術會用到 10 次以上」才值得加規則。

## 何時加新層

幾乎不需要。如果想加，先問自己：
- 它的職責跟現有 4 層**真的**不重疊嗎？
- 加在哪兩層之間？順序的「成本 → 確定性」性質會被破壞嗎？

→ 95% 的需求應該是「在現有層裡加邏輯」，不是「新增一層」。

## 測試守則（範本目前無測試 —— 建議自己補）

範本不附測試，建議你 fork 後自行建立（以下為各層測試守則）：

- 改 **Layer 0 / 1** → 寫 mock 留言斷言「該被 skip 的有 skip、該進人工佇列的有進」。
- 改 **Layer 2** → 對每個 RULE 寫一個 mock case（命中該規則、模板輸出符合預期）。
- 改 **Layer 3** → mock `drafter.diagnose` 後跑；同時人工跑一次 `run_once.py`（DRY_RUN）觀察實際輸出。
- 改 **state.py** → 用乾淨 DB（`del data/state.db`）跑，確保不依賴既有資料的偶然狀態。

## 範例：正確擴充規則（Layer 2）

```python
# rules.py
RULES = [
    # ...既有 4 條...
    {
        "name": "address_or_location",
        "match": _has_any(["地址", "在哪", "怎麼去"]),
        "render": lambda t: "工作室位置不公開，請私訊我約 🙏",
    },
]
```

不需要動 `pipeline.py`；只在 `RULES` list 加一條（建議同步補一個測試 case）。

## 反例

```python
# ❌ 在 Layer 2 規則裡呼叫 LLM
{ "match": lambda t: llm.draft(...).startswith("yes"), "render": ... }  # 違反不變量 3

# ❌ 在 Layer 3 再做負評過濾
def diagnose(...):
    if "去死" in comment_text: return None  # Layer 1 已經做了，重複
```