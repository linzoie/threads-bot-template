from pathlib import Path
from dotenv import load_dotenv
import os

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

KEYWORDS_TO_SEARCH = [k.strip() for k in os.environ.get("KEYWORDS_TO_SEARCH", "").split(",") if k.strip()]
SEARCH_RESULTS_PER_KEYWORD = int(os.environ.get("SEARCH_RESULTS_PER_KEYWORD", 10))
MIN_DRAFT_SCORE = float(os.environ.get("MIN_DRAFT_SCORE", 0.5))

THREADS_API_BASE = "https://graph.threads.net/v1.0"
