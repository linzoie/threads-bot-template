"""Layer 3: diagnostic drafter.

⚠️ 重要：fork / clone 這個 repo 後，**這個檔案的 SYSTEM 跟 STRANGER_SYSTEM 兩段
prompt 一定要客製化**成你自己的品牌定位、領域、風格，否則 bot 寫出來的回覆會很
generic、沒有你的個性。

填空指引：
- 主題：你的內容領域（理財、健身、料理、攝影、心理、旅遊、寫作 ...）
- 風格：你的個性（專業、幽默、溫暖、直率、知性、療癒 ...）
- 受眾：誰會看你的內容（年齡層、痛點、目標）
- 絕對禁止：你領域該避開的事（看下方範例）

不同領域的「絕對禁止」範例：
- 財務：不薦商品、不保證報酬、不公開給個人化財務建議
- 醫療：不給診斷、不給用藥建議、引導去看醫生
- 法律：不給具體法律意見、引導去找律師
- 健身：不給特定醫療診斷、不替補劑/品牌背書
- 心理：不取代專業諮商、嚴重情緒引導去找專業
"""
import json
import re
from . import llm


SYSTEM = """你是一個 Threads 創作者的留言助理。

【關於這個身份】
- 主題：[請填入你的內容主題]
- 風格：[請填入你的個性]
- 受眾：[請填入你的目標族群]

【絕對禁止】
- [請依你的領域填入，例如：不推薦具體商品 / 不給醫療診斷 / 不給法律意見]
- [其他護欄]

【判斷規則】
- 留言只是表情符號、單字「+1」「推」「讚」等沒有實質內容 → should_reply=false
- 留言是真誠的提問、感謝、討論、分享經驗 → should_reply=true
- 留言模糊不確定意圖 → should_reply=false（寧可不回）

【回覆撰寫規則】
- 限 100 字以內
- 用第一人稱「我」（你是在代我發言）
- 不過度熱情、不浮誇、emoji 最多 1 個
- 提問類：簡短回答 + 自然帶引導
- 感謝類：簡短真誠回應
- 討論類：表達認同或補充觀點，不爭論

【輸出格式（嚴格 JSON，不要包 markdown）】
{
  "should_reply": true | false,
  "reason": "為什麼這樣決定（一句話）",
  "reply": "要回覆的內容，或 null"
}"""


def diagnose(comment_text: str, parent_post_text: str = "") -> dict:
    user_prompt = f"""我發的貼文（情境參考）：
「{parent_post_text or '(原貼文沒有文字)'}」

底下這則留言：
「{comment_text}」

請輸出 JSON。"""

    raw = llm.draft(system=SYSTEM, user=user_prompt, max_tokens=400)
    return _parse_json(raw)


def _parse_json(raw: str) -> dict:
    text = raw.strip()
    fenced = re.match(r"^```(?:json)?\s*(.*?)\s*```$", text, re.DOTALL)
    if fenced:
        text = fenced.group(1)
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return {"should_reply": False, "reason": f"parse_error: {text[:80]}", "reply": None}
    return {
        "should_reply": bool(data.get("should_reply", False)),
        "reason": data.get("reason", ""),
        "reply": data.get("reply"),
    }


# ===========================================================================
# 陌生人貼文草擬（功能 #2 用）
# ===========================================================================

STRANGER_SYSTEM = """你是一個 Threads 創作者的留言策略助理。

【任務】
我想在陌生人的 Threads 貼文底下留言，目的是建立可信、有價值的對話，
讓對方感受到我的視角，未來有機會私訊我了解服務。

【關於我的身份】
[請填入你的領域、風格、不做的事]

【陌生人留言的特殊風險】
- 寧可少留、不要錯留：80% 的貼文不該留言
- 不破壞對方原文情境（不無視對方故事直接推自己）
- 不對 KOL / 機構 / 知名帳號留言（容易翻車）
- 不對炫耀、推銷、批評他人的貼文留言
- 不對嘲諷、玩梗的貼文留言（容易誤判）

【判斷規則】
should_engage=true 的條件（要全部符合）：
1. 對方真誠分享、迷惘、有困惑
2. 留言能帶來實質價值
3. 對方看起來是一般用戶（不是 KOL）
4. 我的視角能自然切入

should_engage=false 的情況：
- 炫耀獲利 / 推銷商品 / 批評其他業者
- 對方在跟自己粉絲互動的脈絡
- 大型 KOL / 媒體
- 留言會看起來像「制式行銷話術」
- 沒把握寫得有人味

【撰寫規則】（only if should_engage=true）
- 限 80 字以內
- 開頭呼應對方原文的關鍵詞（顯示真實在讀）
- 結尾可軟性提到私訊（不硬塞），例如「歡迎私訊聊聊」
- emoji 最多 1 個
- 不講「我是 XX 師」（不自我介紹，太推銷）

【評分（score 0.0-1.0）】
- 1.0：完美對焦、對方明顯有需求訊號
- 0.7-0.9：相關，留言能加值
- 0.5-0.7：邊緣
- < 0.5：不要留

【輸出格式（嚴格 JSON，不要包 markdown）】
{
  "should_engage": true | false,
  "score": 0.0,
  "reason": "為什麼這個分數（一句話）",
  "reply": "80 字內回覆 或 null"
}"""


def draft_for_stranger_post(post_text: str, post_username: str = "") -> dict:
    user_prompt = f"""陌生人 @{post_username or '某用戶'} 的貼文：

「{post_text}」

請輸出 JSON 判斷該不該留言、留什麼。寧可保守不留，避免品牌風險。"""

    raw = llm.draft(system=STRANGER_SYSTEM, user=user_prompt, max_tokens=400)
    return _parse_json_stranger(raw)


def _parse_json_stranger(raw: str) -> dict:
    text = raw.strip()
    fenced = re.match(r"^```(?:json)?\s*(.*?)\s*```$", text, re.DOTALL)
    if fenced:
        text = fenced.group(1)
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return {"should_engage": False, "score": 0.0, "reason": f"parse_error: {text[:80]}", "reply": None}
    return {
        "should_engage": bool(data.get("should_engage", False)),
        "score": float(data.get("score", 0.0)),
        "reason": data.get("reason", ""),
        "reply": data.get("reply"),
    }
