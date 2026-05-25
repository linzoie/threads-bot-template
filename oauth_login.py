r"""L2 OAuth: 1-click localhost HTTPS callback flow.

Spins up a local HTTPS server on https://localhost:PORT/callback (self-signed
cert auto-generated under data/), opens your default browser to Meta authorize,
captures the redirect's ?code= automatically.

Meta requires https:// for all Threads OAuth redirect URIs. The first time
the browser hits the localhost callback it will warn "Your connection is not
private" (NET::ERR_CERT_AUTHORITY_INVALID) because the cert is self-signed.
Click Advanced -> Proceed to localhost (unsafe) once and the OAuth completes.

One-time Meta Dashboard setup:
  1. Go to https://developers.facebook.com/apps/ -> your app
  2. Use cases -> Threads -> Customize -> Settings
  3. Valid OAuth Redirect URIs: add  https://localhost:8443/callback
  4. Save

Usage:
    .\.venv\Scripts\python.exe oauth_login.py                # full flow
    .\.venv\Scripts\python.exe oauth_login.py --port 9443    # different port (must also update Meta)
    .\.venv\Scripts\python.exe oauth_login.py --no-browser   # don't auto-open browser
    .\.venv\Scripts\python.exe oauth_login.py --verify       # auto-run verify.py after writing token
"""
import sys

sys.stdout.reconfigure(encoding="utf-8")

import argparse
import os
import ssl
import threading
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer

from src import cert_manager, config, notifier, oauth

DEFAULT_PORT = 8443
CALLBACK_PATH = "/callback"
TIMEOUT_SECONDS = 300


class _Handler(BaseHTTPRequestHandler):
    captured_code: str | None = None
    captured_error: str | None = None

    def do_GET(self):
        if not self.path.startswith(CALLBACK_PATH):
            self.send_response(404)
            self.end_headers()
            return
        code = oauth.extract_code_from_redirect(self.path)
        if code:
            _Handler.captured_code = code
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(
                "<!doctype html><html><body style='font-family:system-ui;padding:60px;text-align:center'>"
                "<h1 style='color:#0a7'>OAuth 完成</h1>"
                "<p>可以關閉這個分頁，回到 terminal 看新 token 寫入結果。</p>"
                "</body></html>".encode()
            )
        else:
            _Handler.captured_error = self.path
            self.send_response(400)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"<h1>No code in callback</h1>")

    def log_message(self, fmt, *args):
        pass


def _run_verify():
    print("\n--- running verify.py to confirm new token ---")
    try:
        from verify import check_threads
        check_threads()
    except Exception as e:
        notifier.alert_warning("verify.py failed after OAuth", f"{type(e).__name__}: {e}")


def main():
    p = argparse.ArgumentParser(description="Threads OAuth: localhost callback (L2)")
    p.add_argument("--port", type=int, default=int(os.environ.get("OAUTH_PORT", DEFAULT_PORT)))
    p.add_argument("--no-browser", action="store_true", help="Don't auto-open the browser.")
    p.add_argument("--verify", action="store_true", help="Run verify.py after token write.")
    args = p.parse_args()

    redirect_uri = f"https://localhost:{args.port}{CALLBACK_PATH}"
    authorize_url = oauth.build_authorize_url(redirect_uri)

    print("=" * 64)
    print("  Threads OAuth — L2 localhost HTTPS callback flow")
    print("=" * 64)
    print(f"  redirect URI : {redirect_uri}")
    print("  (this must be in Meta Dashboard -> Valid OAuth Redirect URIs)")
    print()

    cert_path, key_path, cert_mode = cert_manager.ensure_cert(
        config.ROOT / "data", mode=config.CERT_MODE
    )
    if cert_mode == "mkcert":
        print(f"  TLS cert     : {cert_path.name} (mkcert trusted; zero browser warning)")
    else:
        print(f"  TLS cert     : {cert_path.name} (self-signed; browser will warn first time)")
    print()

    try:
        server = HTTPServer(("localhost", args.port), _Handler)
    except OSError as e:
        notifier.alert_error(
            f"Cannot bind localhost:{args.port}",
            f"{type(e).__name__}: {e}\n試試 --port 換一個 port (例如 --port 9443)，記得 Meta Dashboard 的 redirect URI 也要同步改"
        )
        sys.exit(1)

    ssl_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ssl_ctx.load_cert_chain(certfile=str(cert_path), keyfile=str(key_path))
    server.socket = ssl_ctx.wrap_socket(server.socket, server_side=True)

    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()

    if args.no_browser:
        print("打開這個 URL 並按 [Authorize]：")
        print(f"  {authorize_url}\n")
    else:
        print("瀏覽器即將打開。看到 Meta 授權頁後按 [Authorize]。")
        if cert_mode == "self_signed":
            print("Authorize 後瀏覽器會跳到 localhost callback —— 第一次會跳「不安全」警告，")
            print("按「進階」-> 「繼續前往 localhost (不安全)」一次即可（自簽 cert 必經）。\n")
        else:
            print("Authorize 後瀏覽器直接跳到 localhost callback、自動完成（mkcert trusted，零警告）。\n")
        webbrowser.open(authorize_url)

    print(f"Waiting for callback (timeout {TIMEOUT_SECONDS}s)... press Ctrl+C to abort\n")

    waited = 0
    poll = 0.5
    try:
        while waited < TIMEOUT_SECONDS:
            if _Handler.captured_code or _Handler.captured_error:
                break
            time.sleep(poll)
            waited += poll
    except KeyboardInterrupt:
        print("\n[aborted by user]")
        sys.exit(130)
    finally:
        server.shutdown()
        server.server_close()

    if _Handler.captured_error:
        notifier.alert_error("OAuth callback got no code", _Handler.captured_error)
        sys.exit(1)
    if not _Handler.captured_code:
        notifier.alert_error("OAuth timed out", f"No callback after {TIMEOUT_SECONDS}s. 沒按 Authorize 嗎？")
        sys.exit(1)

    print("Got code, exchanging for tokens...")
    try:
        result = oauth.complete_and_save(_Handler.captured_code, redirect_uri)
    except Exception as e:
        notifier.alert_error("OAuth token exchange failed", f"{type(e).__name__}: {e}")
        sys.exit(1)

    if result["status"] != "ok":
        notifier.alert_error(
            f"OAuth failed at step: {result.get('step')}",
            str(result.get("response", "")),
        )
        sys.exit(1)

    print("\n[OK] DONE")
    print(f"  user_id          : {result.get('user_id')}")
    print(f"  token issued at  : {result.get('refreshed_at')}")
    print(f"  expires in days  : ~{result.get('expires_in_days')}")
    print("  .env updated     : THREADS_LONG_LIVED_TOKEN + THREADS_TOKEN_REFRESHED_AT (backup at .env.backup)")

    if args.verify:
        _run_verify()
    else:
        print("\n下一步：./.venv/Scripts/python.exe verify.py")


if __name__ == "__main__":
    main()
