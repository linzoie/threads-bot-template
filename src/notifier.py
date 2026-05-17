"""Multi-channel alert helpers.

Active channels:
  - Console: ANSI-coloured banner so errors are obvious in a long log stream.
  - Log file: outputs/logs/notifier_YYYY-MM.log (rotated monthly).
  - Telegram: only if TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID are set in .env.

Callers use alert_error() / alert_warning() / info(). The Telegram path is
silent when unconfigured — that is intentional so the same call sites work
in dev and once you wire Telegram up.
"""
import os
import re
from datetime import datetime
from pathlib import Path

os.system("")

_TOKEN_PARAM_RE = re.compile(r"(access_token=)[^&\s\"']+", re.IGNORECASE)
_BEARER_RE = re.compile(r"(Bearer\s+)\S+", re.IGNORECASE)


def _redact(text: str) -> str:
    """Mask access_token= URL params and Bearer headers before logging."""
    if not text:
        return text
    text = _TOKEN_PARAM_RE.sub(r"\1***REDACTED***", text)
    text = _BEARER_RE.sub(r"\1***REDACTED***", text)
    return text

ROOT = Path(__file__).resolve().parent.parent
LOG_DIR = ROOT / "outputs" / "logs"

RED = "\033[91m"
YELLOW = "\033[93m"
GREEN = "\033[92m"
BOLD = "\033[1m"
RESET = "\033[0m"


def _log(level: str, title: str, body: str) -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    month = datetime.now().strftime("%Y-%m")
    fp = LOG_DIR / f"notifier_{month}.log"
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with fp.open("a", encoding="utf-8") as f:
        f.write(f"[{ts}] [{level}] {title}\n{body}\n\n")


def _console_box(color: str, label: str, title: str, body: str) -> None:
    bar = "=" * 70
    print(f"\n{color}{BOLD}{bar}{RESET}")
    print(f"{color}{BOLD}  ⚠  {label}: {title}{RESET}")
    print(f"{color}{bar}{RESET}")
    for line in (body.splitlines() if body else [""]):
        print(f"{color}  {line}{RESET}")
    print(f"{color}{bar}{RESET}\n")


def _try_telegram(title: str, body: str) -> bool:
    tg_token = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
    tg_chat = os.environ.get("TELEGRAM_CHAT_ID", "").strip()
    if not tg_token or not tg_chat:
        return False
    try:
        import requests
        msg = f"⚠ [threads-bot] {title}\n\n{body}"
        requests.post(
            f"https://api.telegram.org/bot{tg_token}/sendMessage",
            data={"chat_id": tg_chat, "text": msg[:4000]},
            timeout=10,
        )
        return True
    except Exception:
        return False


def alert_error(title: str, body: str = "") -> None:
    body = _redact(body)
    _console_box(RED, "ERROR", title, body)
    _log("ERROR", title, body)
    _try_telegram(title, body)


def alert_warning(title: str, body: str = "") -> None:
    body = _redact(body)
    _console_box(YELLOW, "WARN", title, body)
    _log("WARN", title, body)


def info(msg: str) -> None:
    print(f"{GREEN}[notifier]{RESET} {msg}")
