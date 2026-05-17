r"""L1 OAuth: paste-URL flow.

Use this when you can't bind a localhost server (corp firewall, port
conflict) or want to see what's happening at each step. Flow:

  1. Run this — it prints the authorize URL
  2. Open the URL in your browser, click [Authorize]
  3. Meta redirects to your redirect_uri (browser may 404 — that's OK)
  4. Copy the FULL URL from the browser's address bar (it contains ?code=...)
  5. Paste back here

Still needs a registered Valid OAuth Redirect URI in Meta Dashboard.
Default is http://localhost:8765/callback (same as oauth_login.py).
Override with --redirect-uri or THREADS_OAUTH_REDIRECT_URI env var if you
already have a different one configured.

Usage:
    .\.venv\Scripts\python.exe oauth_paste.py
    .\.venv\Scripts\python.exe oauth_paste.py --open-browser
    .\.venv\Scripts\python.exe oauth_paste.py --redirect-uri https://my-ngrok.ngrok.io/cb
    .\.venv\Scripts\python.exe oauth_paste.py --verify
"""
import sys
sys.stdout.reconfigure(encoding="utf-8")

import argparse
import os
import webbrowser

from src import notifier, oauth

DEFAULT_REDIRECT_URI = "http://localhost:8765/callback"


def _run_verify():
    print("\n--- running verify.py to confirm new token ---")
    try:
        from verify import check_threads
        check_threads()
    except Exception as e:
        notifier.alert_warning("verify.py failed after OAuth", f"{type(e).__name__}: {e}")


def main():
    p = argparse.ArgumentParser(description="Threads OAuth: paste-URL (L1)")
    p.add_argument(
        "--redirect-uri",
        default=os.environ.get("THREADS_OAUTH_REDIRECT_URI", DEFAULT_REDIRECT_URI),
        help="Must match Meta Dashboard Valid OAuth Redirect URIs.",
    )
    p.add_argument("--open-browser", action="store_true", help="Auto-open authorize URL in default browser.")
    p.add_argument("--verify", action="store_true", help="Run verify.py after token write.")
    args = p.parse_args()

    authorize_url = oauth.build_authorize_url(args.redirect_uri)

    print("=" * 64)
    print("  Threads OAuth — L1 paste-URL flow")
    print("=" * 64)
    print(f"  redirect URI : {args.redirect_uri}")
    print(f"  (this must be in Meta Dashboard -> Valid OAuth Redirect URIs)")
    print()
    print("Open this URL, click [Authorize], then paste the redirected URL back here:")
    print()
    print(f"  {authorize_url}")
    print()

    if args.open_browser:
        webbrowser.open(authorize_url)
        print("(opened in browser)")

    print("\n貼上瀏覽器跳轉後的完整 URL（會包含 ?code=...），按 Enter 結束：")
    print("-" * 64)
    try:
        pasted = input("> ").strip()
    except (KeyboardInterrupt, EOFError):
        print("\n[aborted]")
        sys.exit(130)

    if not pasted:
        print("[abort] empty input")
        sys.exit(1)

    code = oauth.extract_code_from_redirect(pasted)
    if not code:
        notifier.alert_error("No code in pasted URL", f"input head: {pasted[:200]}")
        sys.exit(1)

    print("\nGot code, exchanging for tokens...")
    try:
        result = oauth.complete_and_save(code, args.redirect_uri)
    except Exception as e:
        notifier.alert_error("OAuth token exchange failed", f"{type(e).__name__}: {e}")
        sys.exit(1)

    if result["status"] != "ok":
        notifier.alert_error(
            f"OAuth failed at step: {result.get('step')}",
            str(result.get("response", "")),
        )
        sys.exit(1)

    print(f"\n[OK] DONE")
    print(f"  user_id          : {result.get('user_id')}")
    print(f"  token issued at  : {result.get('refreshed_at')}")
    print(f"  expires in days  : ~{result.get('expires_in_days')}")
    print(f"  .env updated     : THREADS_LONG_LIVED_TOKEN + THREADS_TOKEN_REFRESHED_AT (backup at .env.backup)")

    if args.verify:
        _run_verify()
    else:
        print(f"\n下一步：./.venv/Scripts/python.exe verify.py")


if __name__ == "__main__":
    main()
