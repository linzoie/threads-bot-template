"""Thin wrapper for the Threads Graph API endpoints we actually use."""
import requests

from . import config


def _get(path: str, **params):
    params["access_token"] = config.THREADS_LONG_LIVED_TOKEN
    r = requests.get(f"{config.THREADS_API_BASE}/{path}", params=params, timeout=15)
    r.raise_for_status()
    return r.json()


def _post(path: str, **data):
    data["access_token"] = config.THREADS_LONG_LIVED_TOKEN
    r = requests.post(f"{config.THREADS_API_BASE}/{path}", data=data, timeout=15)
    r.raise_for_status()
    return r.json()


def list_my_recent_threads(limit: int = 10) -> list[dict]:
    """Latest top-level threads posted by me."""
    resp = _get(
        "me/threads",
        fields="id,text,timestamp,permalink",
        limit=limit,
    )
    return resp.get("data", [])


def list_replies(thread_id: str, limit: int = 100) -> list[dict]:
    """All top-level replies under one of my threads."""
    resp = _get(
        f"{thread_id}/replies",
        fields="id,text,username,timestamp,replied_to",
        limit=limit,
    )
    return resp.get("data", [])


def post_reply(reply_to_id: str, text: str) -> dict:
    """Two-step publish: create container, then publish.

    Skipped entirely when DRY_RUN=true; caller checks config.DRY_RUN before calling.
    """
    container = _post(
        f"{config.THREADS_USER_ID}/threads",
        media_type="TEXT",
        text=text,
        reply_to_id=reply_to_id,
    )
    creation_id = container["id"]
    published = _post(
        f"{config.THREADS_USER_ID}/threads_publish",
        creation_id=creation_id,
    )
    return {"creation_id": creation_id, "published_id": published.get("id")}
