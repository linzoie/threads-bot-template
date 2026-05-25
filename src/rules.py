"""Layer 2: hard keyword/heuristic rules with fixed-or-derived templates.

These bypass Claude entirely — for cases where same response every time is on-brand
(commercial keywords) OR where Claude is wasted overkill (emoji-only acks).

Order matters: first match wins. Edit RULES below to tweak.
"""
import re

# ---------------------------------------------------------------------------
# Helpers for the emoji / short-praise rule
# ---------------------------------------------------------------------------

# Map common emoji → matching response. First match by `in` wins.
# Pick reciprocal energy: fire ↔ fire, heart ↔ heart, etc.
EMOJI_MAP = {
    "🔥": "🔥",
    "❤️": "❤️",
    "❤": "❤️",
    "🩷": "❤️",
    "💗": "❤️",
    "💕": "❤️",
    "💖": "❤️",
    "😂": "😂",
    "🤣": "😂",
    "👍": "🙏",
    "🙌": "🙏",
    "💯": "🙏",
    "🤩": "🙏",
    "🥹": "🙏",
}

SHORT_PRAISE = {"推", "讚", "好", "棒", "帥", "酷", "+1", "收藏", "強", "厲害"}


def _is_pure_emoji(text: str) -> bool:
    """True if text contains no word/letter chars (only emojis, symbols, spaces)."""
    return not re.search(r"\w", text, flags=re.UNICODE)


def _is_short_praise(text: str) -> bool:
    return text in SHORT_PRAISE


def _emoji_response(text: str) -> str:
    for emoji, reply in EMOJI_MAP.items():
        if emoji in text:
            return reply
    return "🙏"


# ---------------------------------------------------------------------------
# Rule definitions
# ---------------------------------------------------------------------------

def _has_any(patterns):
    return lambda t: any(p in t for p in patterns)


RULES = [
    {
        "name": "consultation",
        "match": _has_any(["諮詢", "想諮詢", "可以諮詢", "預約諮詢"]),
        "render": lambda t: "謝謝你的詢問！諮詢可以直接私訊我聊聊，我會儘快回你 🙏",
    },
    {
        "name": "collab_or_sponsor",
        "match": _has_any(["合作", "業配", "業務合作", "業務洽詢", "想合作"]),
        "render": lambda t: "謝謝邀請!合作相關可以直接私訊我，我們聊聊細節 🙌",
    },
    {
        "name": "pricing",
        "match": _has_any(["報價", "收費多少", "費用多少", "怎麼收費", "多少錢"]),
        "render": lambda t: "費用因方案不同，方便的話請私訊我，我提供詳細報價 🙏",
    },
    {
        "name": "emoji_or_praise",
        "match": lambda t: _is_pure_emoji(t) or _is_short_praise(t),
        "render": _emoji_response,
    },
]


def match(text: str) -> dict | None:
    """Return {name, template} for first matching rule, else None."""
    if not text:
        return None
    text = text.strip()
    for rule in RULES:
        if rule["match"](text):
            return {"name": rule["name"], "template": rule["render"](text)}
    return None
