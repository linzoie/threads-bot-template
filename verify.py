"""Sanity check: Threads token works AND chosen LLM provider works."""
import sys

sys.stdout.reconfigure(encoding="utf-8")

import requests

from src import config


def check_threads():
    print("\n--- Threads API ---")
    me = requests.get(
        f"{config.THREADS_API_BASE}/me",
        params={
            "fields": "id,username,threads_biography",
            "access_token": config.THREADS_LONG_LIVED_TOKEN,
        },
        timeout=10,
    )
    me.raise_for_status()
    profile = me.json()
    print(f"[OK] @{profile.get('username')} (id: {profile.get('id')})")

    threads = requests.get(
        f"{config.THREADS_API_BASE}/me/threads",
        params={
            "fields": "id,text,timestamp",
            "limit": 5,
            "access_token": config.THREADS_LONG_LIVED_TOKEN,
        },
        timeout=10,
    )
    threads.raise_for_status()
    items = threads.json().get("data", [])
    print(f"[OK] Latest {len(items)} thread(s):")
    for t in items:
        text = (t.get("text") or "(no text)").replace("\n", " ")
        if len(text) > 50:
            text = text[:50] + "..."
        print(f"     {t.get('timestamp', '')[:10]}  {text}")


def check_llm():
    from src import llm

    print(f"\n--- LLM ({config.LLM_PROVIDER}) ---")
    key_var = "ANTHROPIC_API_KEY" if config.LLM_PROVIDER == "claude" else "GROQ_API_KEY"
    key_val = config.ANTHROPIC_API_KEY if config.LLM_PROVIDER == "claude" else config.GROQ_API_KEY
    if not key_val or key_val.startswith("PASTE_"):
        print(f"[SKIP] {key_var} not set in .env")
        return

    out = llm.draft(
        system="你是一個簡潔的繁體中文助理，回答必須在 20 字內。",
        user="用一句話介紹 Threads 這個社群平台。",
        max_tokens=100,
    )
    model = config.CLAUDE_MODEL if config.LLM_PROVIDER == "claude" else config.GROQ_MODEL
    print(f"[OK] model={model}")
    print(f"     reply: {out}")


def main():
    print("=" * 60)
    print("Connection check")
    print("=" * 60)
    check_threads()
    check_llm()
    print("\n[DONE]")


if __name__ == "__main__":
    main()
