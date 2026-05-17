"""Search keywords → ask Claude to draft → save to data/draft_queue.jsonl.

Run this whenever you want fresh drafts. Then run review_drafts.py to act on them.
"""
import sys
sys.stdout.reconfigure(encoding="utf-8")

from datetime import datetime

from src import config, drafter, draft_state, keyword_searcher


def main():
    if not config.KEYWORDS_TO_SEARCH:
        print("[error] No keywords configured. Set KEYWORDS_TO_SEARCH in .env")
        return

    print("=" * 70)
    print(f"Finding drafts at {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"Keywords ({config.KEYWORDS_SOURCE}, {len(config.KEYWORDS_TO_SEARCH)} loaded):")
    print(f"  {', '.join(config.KEYWORDS_TO_SEARCH)}")
    print(f"Per keyword: {config.SEARCH_RESULTS_PER_KEYWORD} posts")
    print(f"Min score: {config.MIN_DRAFT_SCORE}")
    print("=" * 70)

    seen_ids = draft_state.already_drafted_ids()
    print(f"\nAlready drafted: {len(seen_ids)} posts (will skip)\n")

    total_searched = 0
    total_skipped_dup = 0
    total_dropped_low_score = 0
    total_skipped_by_claude = 0
    total_queued = 0

    for kw in config.KEYWORDS_TO_SEARCH:
        print(f"--- keyword: {kw}")
        try:
            posts = keyword_searcher.search(kw, limit=config.SEARCH_RESULTS_PER_KEYWORD)
        except Exception as e:
            print(f"    search failed: {e}")
            continue
        print(f"    found {len(posts)} posts")
        total_searched += len(posts)

        for p in posts:
            pid = p.get("id")
            ptext = (p.get("text") or "").strip()
            if not pid or not ptext:
                continue
            if pid in seen_ids:
                total_skipped_dup += 1
                continue

            decision = drafter.draft_for_stranger_post(ptext, p.get("username", ""))
            score = decision.get("score", 0.0)

            if not decision.get("should_engage"):
                total_skipped_by_claude += 1
                preview = ptext[:40].replace("\n", " ")
                print(f"    [skip claude] @{p.get('username','?')}: {preview}  (reason: {decision.get('reason','')[:50]})")
                seen_ids.add(pid)
                continue

            if score < config.MIN_DRAFT_SCORE:
                total_dropped_low_score += 1
                preview = ptext[:40].replace("\n", " ")
                print(f"    [skip score {score:.2f}] @{p.get('username','?')}: {preview}")
                seen_ids.add(pid)
                continue

            draft = {
                "post_id": pid,
                "post_text": ptext,
                "post_username": p.get("username", ""),
                "post_timestamp": p.get("timestamp", ""),
                "post_permalink": p.get("permalink", ""),
                "matched_keyword": kw,
                "score": score,
                "reason": decision.get("reason", ""),
                "reply": decision.get("reply", ""),
                "drafted_at": datetime.now().isoformat(),
            }
            draft_state.append_draft(draft)
            seen_ids.add(pid)
            total_queued += 1
            preview = ptext[:40].replace("\n", " ")
            print(f"    [queued {score:.2f}] @{p.get('username','?')}: {preview}")

    print("\n" + "=" * 70)
    print(f"Searched          : {total_searched}")
    print(f"  duplicate       : {total_skipped_dup}")
    print(f"  Claude skipped  : {total_skipped_by_claude}")
    print(f"  below threshold : {total_dropped_low_score}")
    print(f"  → queued        : {total_queued}")
    print("=" * 70)
    if total_queued:
        print(f"\nNext: run review_drafts.py to review and (optionally) post the {total_queued} new draft(s).")


if __name__ == "__main__":
    main()
