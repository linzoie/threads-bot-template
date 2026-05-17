"""Threads OAuth primitives — shared by oauth_login.py (L2) and oauth_paste.py (L1).

Three logical steps:
  1. Direct user to AUTHORIZE_URL, get back ?code= via redirect.
  2. Exchange code -> short-lived token (POST).
  3. Exchange short-lived -> long-lived 60-day token (GET).

complete_and_save() bundles steps 2-3 plus the .env write so callers only
need to feed it a code + the same redirect_uri used in step 1.
"""
import os
from datetime import datetime, timezone
from typing import Optional
from urllib.parse import parse_qs, urlencode

import requests

from . import config, token_refresher


AUTHORIZE_URL = "https://threads.net/oauth/authorize"
SHORT_LIVED_TOKEN_URL = "https://graph.threads.net/oauth/access_token"
LONG_LIVED_TOKEN_URL = "https://graph.threads.net/access_token"

DEFAULT_SCOPES = [
    "threads_basic",
    "threads_content_publish",
    "threads_manage_replies",
    "threads_read_replies",
    "threads_keyword_search",
    "threads_manage_insights",
]


def build_authorize_url(redirect_uri: str, scopes: Optional[list] = None, state: str = "threadsbot") -> str:
    params = {
        "client_id": config.THREADS_APP_ID,
        "redirect_uri": redirect_uri,
        "scope": ",".join(scopes or DEFAULT_SCOPES),
        "response_type": "code",
        "state": state,
    }
    return f"{AUTHORIZE_URL}?{urlencode(params)}"


def extract_code_from_redirect(url_or_path: str) -> Optional[str]:
    """Pull 'code' from a full URL or just a path?query string. Strips Meta's #_=_ fragment."""
    if "?" not in url_or_path:
        return None
    qs = url_or_path.split("?", 1)[1].split("#", 1)[0]
    codes = parse_qs(qs).get("code", [])
    return codes[0] if codes else None


def exchange_code_for_short_lived(code: str, redirect_uri: str) -> dict:
    r = requests.post(
        SHORT_LIVED_TOKEN_URL,
        data={
            "client_id": config.THREADS_APP_ID,
            "client_secret": config.THREADS_APP_SECRET,
            "grant_type": "authorization_code",
            "redirect_uri": redirect_uri,
            "code": code,
        },
        timeout=15,
    )
    r.raise_for_status()
    return r.json()


def exchange_short_lived_for_long_lived(short_lived_token: str) -> dict:
    r = requests.get(
        LONG_LIVED_TOKEN_URL,
        params={
            "grant_type": "th_exchange_token",
            "client_secret": config.THREADS_APP_SECRET,
            "access_token": short_lived_token,
        },
        timeout=15,
    )
    r.raise_for_status()
    return r.json()


def complete_and_save(code: str, redirect_uri: str) -> dict:
    """End-to-end: code -> short-lived -> long-lived -> .env write.

    Returns one of:
      {"status": "ok", "user_id": ..., "expires_in_days": N, "refreshed_at": iso}
      {"status": "error", "step": "short_lived" | "long_lived", "response": dict}
    """
    sl_resp = exchange_code_for_short_lived(code, redirect_uri)
    sl_token = sl_resp.get("access_token")
    if not sl_token:
        return {"status": "error", "step": "short_lived", "response": sl_resp}

    ll_resp = exchange_short_lived_for_long_lived(sl_token)
    ll_token = ll_resp.get("access_token")
    expires_in = ll_resp.get("expires_in")
    if not ll_token:
        return {"status": "error", "step": "long_lived", "response": ll_resp}

    now_iso = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    env_path = config.ROOT / ".env"
    token_refresher._update_env(env_path, {
        "THREADS_LONG_LIVED_TOKEN": ll_token,
        "THREADS_TOKEN_REFRESHED_AT": now_iso,
    })

    os.environ["THREADS_LONG_LIVED_TOKEN"] = ll_token
    os.environ["THREADS_TOKEN_REFRESHED_AT"] = now_iso
    config.THREADS_LONG_LIVED_TOKEN = ll_token
    config.THREADS_TOKEN_REFRESHED_AT = now_iso

    return {
        "status": "ok",
        "user_id": sl_resp.get("user_id"),
        "expires_in_days": (expires_in // 86400) if expires_in else None,
        "refreshed_at": now_iso,
    }
