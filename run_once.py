"""Run one polling pass: fetch my recent threads, fetch their replies, run pipeline.

In DRY_RUN mode (default) this calls Claude but does NOT post anything to Threads.
Inspect the output to see what *would* be posted, then flip DRY_RUN=false in .env
when you're confident.
"""
import sys
sys.stdout.reconfigure(encoding="utf-8")

from src import config, pipeline, threads_client


def main(thread_limit: int = 10):
    print("=" * 70)
    print(f"DRY_RUN = {config.DRY_RUN}    LLM = {config.LLM_PROVIDER}")
    print("=" * 70)

    threads = threads_client.list_my_recent_threads(limit=thread_limit)
    print(f"Fetched {len(threads)} of my recent threads.\n")

    total_comments = 0
    by_action: dict[str, int] = {}

    for t in threads:
        replies = threads_client.list_replies(t["id"])
        if not replies:
            continue

        post_preview = (t.get("text") or "(no text)").replace("\n", " ")[:50]
        print(f"--- {t['timestamp'][:10]}  {post_preview}")
        print(f"    {len(replies)} reply(ies)")

        for c in replies:
            total_comments += 1
            result = pipeline.process(c, parent_post=t)
            action = result["action"]
            by_action[action] = by_action.get(action, 0) + 1

            ctext = (c.get("text") or "").replace("\n", " ")[:40]
            cuser = c.get("username", "?")
            print(f"      @{cuser}: {ctext}")
            print(f"        -> {action}")
            if "reply_text" in result["detail"]:
                rt = result["detail"]["reply_text"].replace("\n", " ")
                print(f"           reply: {rt}")
        print()

    print("=" * 70)
    print(f"Processed {total_comments} comment(s) across {len(threads)} thread(s)")
    print("Action breakdown:")
    for a, n in sorted(by_action.items(), key=lambda x: -x[1]):
        print(f"  {a:35s} {n}")
    print("=" * 70)


if __name__ == "__main__":
    main()
