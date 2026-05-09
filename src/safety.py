"""Layer 1: catch sensitive / negative comments before any auto-reply.

Two-stage check: cheap keyword scan first, then Claude judgment if keywords miss.
Anything flagged here goes to human queue, NOT auto-replied.
"""
from . import llm

# Hardcoded sensitive substrings — comments containing any of these go straight to human.
# Keep tight: false positives just mean a few extra items in your review queue.
SENSITIVE_KEYWORDS = [
    # 法律/糾紛
    "告你", "提告", "法律", "詐欺", "詐騙", "騙人", "騙錢", "退費", "求償", "賠償",
    # 強烈攻擊
    "去死", "幹你", "操你", "白癡", "智障", "廢物", "垃圾",
    # 金融敏感（你不該對陌生人公開回的）
    "我帳戶", "盜刷", "被駭", "被盜",
    # 感情/精神（轉介專業）
    "想自殺", "不想活", "想不開",
]


def keyword_flagged(text: str) -> str | None:
    """Return the first matching sensitive keyword, or None."""
    if not text:
        return None
    for kw in SENSITIVE_KEYWORDS:
        if kw in text:
            return kw
    return None


CLASSIFIER_SYSTEM = """你是社群留言安全分類器。判斷下面這則留言是否屬於以下任一類：
- 負評/批評/嘲諷
- 客訴/抱怨
- 引戰/挑釁
- 涉及法律、金錢糾紛、隱私
- 嚴重情緒（自殘、輕生、人身攻擊）

只回單字 yes 或 no，不要解釋。"""


def claude_says_negative(text: str) -> bool:
    """Use Claude to catch nuanced negative tone the keyword list missed."""
    if not text or not text.strip():
        return False
    out = llm.draft(
        system=CLASSIFIER_SYSTEM,
        user=f"留言：「{text}」",
        max_tokens=10,
    )
    return out.strip().lower().startswith("yes")
