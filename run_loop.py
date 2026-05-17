"""Long-running scheduler. Polls every N minutes, skips quiet hours.
Press Ctrl+C to stop.
"""
import sys
sys.stdout.reconfigure(encoding="utf-8")

import random
import time
import traceback
from datetime import datetime, timedelta

import schedule

from src import config, notifier, token_refresher
from run_once import main as run_pass


INTERVAL_MINUTES = 5
JITTER_MAX_SECONDS = 30
TOKEN_CHECK_INTERVAL_HOURS = 24

_last_token_check: datetime | None = None


def _maybe_refresh_token() -> None:
    """Idempotent: refreshes Threads token if old enough; safe to call every tick."""
    global _last_token_check
    now = datetime.now()
    if _last_token_check is not None and now - _last_token_check < timedelta(hours=TOKEN_CHECK_INTERVAL_HOURS):
        return
    _last_token_check = now
    ts = now.strftime("%H:%M:%S")
    try:
        result = token_refresher.ensure_fresh()
        status = result["status"]
        if status == "refreshed":
            print(f"[{ts}] [token] OK refreshed — new expiry in {result.get('expires_in_days')} days")
        elif status == "skipped":
            print(f"[{ts}] [token] -- {result.get('reason')}")
        else:
            print(f"[{ts}] [token] !! {result.get('reason')}")
    except Exception as e:
        notifier.alert_error("Token refresh tick crashed", f"{type(e).__name__}: {e}")


def in_quiet_hours() -> bool:
    h = datetime.now().hour
    start, end = config.QUIET_HOURS_START, config.QUIET_HOURS_END
    if start < end:
        return start <= h < end
    # Wrap (e.g., 22 -> 7)
    return h >= start or h < end


def tick():
    _maybe_refresh_token()
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    if in_quiet_hours():
        print(f"[{now}] -- quiet hours ({config.QUIET_HOURS_START:02d}:00-{config.QUIET_HOURS_END:02d}:00), skip --\n")
        return

    jitter = random.uniform(0, JITTER_MAX_SECONDS)
    print(f"\n[{now}] tick (sleep {jitter:.1f}s before pass)")
    time.sleep(jitter)

    try:
        run_pass()
    except Exception:
        print(f"[{datetime.now().strftime('%H:%M:%S')}] ERROR — will retry next tick:")
        traceback.print_exc()


def main():
    print("=" * 50)
    print("Threads bot scheduler")
    print(f"  interval     : every {INTERVAL_MINUTES} min  (+ 0-{JITTER_MAX_SECONDS}s jitter)")
    print(f"  DRY_RUN      : {config.DRY_RUN}")
    print(f"  LLM          : {config.LLM_PROVIDER}")
    print(f"  quiet hours  : {config.QUIET_HOURS_START:02d}:00 - {config.QUIET_HOURS_END:02d}:00")
    print(f"  token check  : on startup + every {TOKEN_CHECK_INTERVAL_HOURS}h (auto refresh if > {config.THREADS_TOKEN_REFRESH_THRESHOLD_DAYS} days old)")
    print("  stop         : Ctrl+C")
    print("=" * 50)

    tick()  # immediate first run
    schedule.every(INTERVAL_MINUTES).minutes.do(tick)

    while True:
        schedule.run_pending()
        time.sleep(5)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n[stopped]")
