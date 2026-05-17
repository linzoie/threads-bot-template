r"""Standalone CLI for the Threads token refresher.

Usage:
    .\.venv\Scripts\python.exe refresh_token.py              # refresh if due
    .\.venv\Scripts\python.exe refresh_token.py --status     # show age only
    .\.venv\Scripts\python.exe refresh_token.py --force      # force refresh (Meta still enforces 24h min)
    .\.venv\Scripts\python.exe refresh_token.py --threshold-days 7

run_loop.py already calls ensure_fresh() once a day on its own — this CLI
is for manual checks, ad-hoc force-refresh, or Task Scheduler if you decide
to add it later.
"""
import sys
sys.stdout.reconfigure(encoding="utf-8")

import argparse
import os

from src import config, token_refresher


def main():
    p = argparse.ArgumentParser(description="Refresh the Threads long-lived access token.")
    p.add_argument("--status", action="store_true", help="Just print current token age. Do not refresh.")
    p.add_argument("--force", action="store_true", help="Skip the threshold check (Meta still requires 24h min age).")
    p.add_argument("--threshold-days", type=int, default=None, help="Override THREADS_TOKEN_REFRESH_THRESHOLD_DAYS.")
    args = p.parse_args()

    refreshed_at = os.environ.get("THREADS_TOKEN_REFRESHED_AT", "").strip()
    age = token_refresher.token_age(refreshed_at)
    threshold = args.threshold_days if args.threshold_days is not None else config.THREADS_TOKEN_REFRESH_THRESHOLD_DAYS

    print("=" * 64)
    print("  Threads long-lived token — status")
    print("=" * 64)
    if age is None:
        print(f"  refreshed_at : (unknown — never recorded)")
        print(f"  age          : unknown — will treat as due on next refresh")
    else:
        days_used = age.days
        hours = age.seconds // 3600
        days_left = token_refresher.TOKEN_LIFETIME_DAYS - days_used
        print(f"  refreshed_at : {refreshed_at}")
        print(f"  age          : {days_used} days, {hours} hours")
        print(f"  expires in   : ~{days_left} days (60-day window since last refresh)")
    print(f"  threshold    : {threshold} days  (refresh when age > this)")
    print("=" * 64)

    if args.status:
        return

    print("\nChecking refresh need...")
    result = token_refresher.ensure_fresh(threshold_days=threshold, force=args.force)
    status = result["status"]
    print(f"\nResult: {status}")
    if result.get("reason"):
        print(f"  reason: {result['reason']}")
    if status == "refreshed":
        print(f"  new token issued — expires in ~{result.get('expires_in_days')} days")
        print(f"  .env updated (backup at .env.backup)")


if __name__ == "__main__":
    main()
