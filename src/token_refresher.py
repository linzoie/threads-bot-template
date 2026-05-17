"""Auto-refresh the Threads long-lived access token.

Meta long-lived tokens live 60 days. The refresh endpoint extends them by
another 60 days, but only after the current token is at least 24h old.
Once a token expires it cannot be refreshed — only a full OAuth dance
recovers from that state.

ensure_fresh() is the entry point. It is idempotent: safe to call from
run_loop.py on every tick — it gates internally on token age.
"""
import os
import shutil
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional

import requests

from . import config, notifier


REFRESH_ENDPOINT = "https://graph.threads.net/refresh_access_token"
DEFAULT_THRESHOLD_DAYS = 30
MIN_AGE_HOURS = 24
TOKEN_LIFETIME_DAYS = 60


def _now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def _parse_iso(s: str) -> Optional[datetime]:
    try:
        dt = datetime.fromisoformat(s)
    except (ValueError, TypeError):
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def token_age(refreshed_at: str) -> Optional[timedelta]:
    dt = _parse_iso(refreshed_at)
    if dt is None:
        return None
    return datetime.now(timezone.utc) - dt


def _update_env(path: Path, updates: dict) -> None:
    """Rewrite KEY=value lines in-place, append missing ones. Atomic + backup."""
    shutil.copy2(path, path.with_suffix(path.suffix + ".backup"))

    lines = path.read_text(encoding="utf-8").splitlines()
    handled = set()
    for i, line in enumerate(lines):
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key = stripped.split("=", 1)[0].strip()
        if key in updates:
            lines[i] = f"{key}={updates[key]}"
            handled.add(key)

    for key, val in updates.items():
        if key not in handled:
            lines.append(f"{key}={val}")

    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def call_refresh(token: str) -> dict:
    r = requests.get(
        REFRESH_ENDPOINT,
        params={"grant_type": "th_refresh_token", "access_token": token},
        timeout=15,
    )
    r.raise_for_status()
    return r.json()


def ensure_fresh(threshold_days: Optional[int] = None, *, force: bool = False) -> dict:
    """Refresh token if older than threshold_days.

    Returns one of:
      {"status": "skipped", "reason": "..."}
      {"status": "refreshed", "expires_in_days": N, "refreshed_at": iso}
      {"status": "error", "reason": "..."}
    """
    threshold = threshold_days if threshold_days is not None else config.THREADS_TOKEN_REFRESH_THRESHOLD_DAYS
    env_path = config.ROOT / ".env"
    token = config.THREADS_LONG_LIVED_TOKEN
    refreshed_at = os.environ.get("THREADS_TOKEN_REFRESHED_AT", "").strip()

    age = token_age(refreshed_at)

    if not force:
        if age is not None:
            if age < timedelta(hours=MIN_AGE_HOURS):
                hrs = age.total_seconds() / 3600
                return {"status": "skipped", "reason": f"token {hrs:.1f}h old (< Meta min {MIN_AGE_HOURS}h)"}
            if age < timedelta(days=threshold):
                return {"status": "skipped", "reason": f"token {age.days}d old (< threshold {threshold}d)"}

    try:
        resp = call_refresh(token)
    except requests.RequestException as e:
        body = ""
        if getattr(e, "response", None) is not None:
            try:
                body = f" | body: {e.response.text[:300]}"
            except Exception:
                pass
        msg = f"refresh call failed: {e}{body}"
        notifier.alert_error("Threads token refresh failed", msg)
        return {"status": "error", "reason": msg}

    new_token = resp.get("access_token")
    expires_in = resp.get("expires_in")
    if not new_token:
        msg = f"refresh endpoint returned unexpected payload: {resp}"
        notifier.alert_error("Threads token refresh failed", msg)
        return {"status": "error", "reason": msg}

    now = _now_iso()
    try:
        _update_env(env_path, {
            "THREADS_LONG_LIVED_TOKEN": new_token,
            "THREADS_TOKEN_REFRESHED_AT": now,
        })
    except OSError as e:
        msg = f"got new token but failed to write .env: {e}"
        notifier.alert_error("Threads token refresh: .env write failed", msg)
        return {"status": "error", "reason": msg, "new_token": new_token}

    os.environ["THREADS_LONG_LIVED_TOKEN"] = new_token
    os.environ["THREADS_TOKEN_REFRESHED_AT"] = now
    config.THREADS_LONG_LIVED_TOKEN = new_token
    config.THREADS_TOKEN_REFRESHED_AT = now

    return {
        "status": "refreshed",
        "expires_in_seconds": expires_in,
        "expires_in_days": (expires_in // 86400) if expires_in else None,
        "refreshed_at": now,
    }
