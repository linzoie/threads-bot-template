"""Wrap the Threads keyword_search endpoint."""
import requests

from . import config


def search(keyword: str, search_type: str = "TOP", limit: int = 10) -> list[dict]:
    """Search public Threads posts for a keyword.

    search_type: TOP (popular) | RECENT (latest)
    """
    r = requests.get(
        f"{config.THREADS_API_BASE}/keyword_search",
        params={
            "q": keyword,
            "search_type": search_type,
            "fields": "id,text,username,timestamp,permalink",
            "access_token": config.THREADS_LONG_LIVED_TOKEN,
        },
        timeout=15,
    )
    r.raise_for_status()
    data = r.json().get("data", [])
    return data[:limit]
