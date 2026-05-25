import os
from pathlib import Path

from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent.parent
load_dotenv(ROOT / ".env")

THREADS_APP_ID = os.environ["THREADS_APP_ID"]
THREADS_APP_SECRET = os.environ["THREADS_APP_SECRET"]
THREADS_USER_ID = os.environ["THREADS_USER_ID"]
THREADS_USERNAME = os.environ.get("THREADS_USERNAME", "")
THREADS_LONG_LIVED_TOKEN = os.environ["THREADS_LONG_LIVED_TOKEN"]

LLM_PROVIDER = os.environ.get("LLM_PROVIDER", "claude").lower()
ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")
CLAUDE_MODEL = os.environ.get("CLAUDE_MODEL", "claude-sonnet-4-6")
GROQ_API_KEY = os.environ.get("GROQ_API_KEY", "")
GROQ_MODEL = os.environ.get("GROQ_MODEL", "llama-3.3-70b-versatile")

MAX_REPLIES_PER_DAY = int(os.environ.get("MAX_REPLIES_PER_DAY", 80))
MAX_REPLIES_PER_HOUR = int(os.environ.get("MAX_REPLIES_PER_HOUR", 15))
QUIET_HOURS_START = int(os.environ.get("QUIET_HOURS_START", 3))
QUIET_HOURS_END = int(os.environ.get("QUIET_HOURS_END", 7))
DRY_RUN = os.environ.get("DRY_RUN", "true").lower() == "true"

WEBHOOK_VERIFY_TOKEN = os.environ.get("WEBHOOK_VERIFY_TOKEN", "")
WEBHOOK_PORT = int(os.environ.get("WEBHOOK_PORT", 8000))

def _load_keywords() -> list[str]:
    """keywords.txt (one per line, # for comments) takes priority over .env."""
    kf = ROOT / "keywords.txt"
    if kf.exists():
        return [
            line.strip()
            for line in kf.read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.strip().startswith("#")
        ]
    return [k.strip() for k in os.environ.get("KEYWORDS_TO_SEARCH", "").split(",") if k.strip()]


KEYWORDS_TO_SEARCH = _load_keywords()
KEYWORDS_SOURCE = "keywords.txt" if (ROOT / "keywords.txt").exists() else ".env"
SEARCH_RESULTS_PER_KEYWORD = int(os.environ.get("SEARCH_RESULTS_PER_KEYWORD", 10))
MIN_DRAFT_SCORE = float(os.environ.get("MIN_DRAFT_SCORE", 0.5))

# Token 自動 refresh（由 src.token_refresher 管理；REFRESHED_AT 會被程式自動寫入）
THREADS_TOKEN_REFRESHED_AT = os.environ.get("THREADS_TOKEN_REFRESHED_AT", "")
THREADS_TOKEN_REFRESH_THRESHOLD_DAYS = int(os.environ.get("THREADS_TOKEN_REFRESH_THRESHOLD_DAYS", 30))

# Telegram 通知（可選，留空表示只用 console + log）
TELEGRAM_BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
TELEGRAM_CHAT_ID = os.environ.get("TELEGRAM_CHAT_ID", "")

# OAuth L2 自簽/mkcert 切換 (mkcert_auto | mkcert_manual | self_signed)
CERT_MODE = os.environ.get("CERT_MODE", "mkcert_auto").strip().lower()

THREADS_API_BASE = "https://graph.threads.net/v1.0"
