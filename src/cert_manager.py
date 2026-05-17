"""Pick the best TLS cert for the OAuth localhost HTTPS callback.

Three modes (CERT_MODE in .env, default mkcert_auto):

  mkcert_auto    — Best UX. Detect mkcert (PATH -> vendored -> download).
                   If missing, prompt to download from GitHub releases (~5MB).
                   Run mkcert -install (UAC prompt on Windows) once to install
                   a local CA. Generates a browser-trusted cert. Zero warning.
                   Any failure -> graceful fallback to self-signed.

  mkcert_manual  — Detect mkcert in PATH. If found, use it. If missing, print
                   choco/scoop/winget/brew install hints and fall back to
                   self-signed. No download, no UAC unless you ran mkcert
                   -install yourself previously.

  self_signed    — Always use the stdlib-only self-signed cert generator.
                   Browser shows 'not private' warning first time per machine,
                   click Advanced -> Proceed once. Zero external dependencies.
"""
import ctypes
import hashlib
import os
import platform
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from typing import Optional

from . import oauth_cert


MKCERT_VERSION = "v1.4.4"
MKCERT_BASE_URL = f"https://github.com/FiloSottile/mkcert/releases/download/{MKCERT_VERSION}"

# binary filename per (system, normalized_arch). SHA256 left None → skipped
# (HTTPS to github.com is the trust anchor). Set via MKCERT_SHA256 env var to enforce.
_BINARIES = {
    ("Windows", "amd64"): f"mkcert-{MKCERT_VERSION}-windows-amd64.exe",
    ("Windows", "arm64"): f"mkcert-{MKCERT_VERSION}-windows-arm64.exe",
    ("Darwin",  "amd64"): f"mkcert-{MKCERT_VERSION}-darwin-amd64",
    ("Darwin",  "arm64"): f"mkcert-{MKCERT_VERSION}-darwin-arm64",
    ("Linux",   "amd64"): f"mkcert-{MKCERT_VERSION}-linux-amd64",
    ("Linux",   "arm64"): f"mkcert-{MKCERT_VERSION}-linux-arm64",
}

VALID_MODES = ("mkcert_auto", "mkcert_manual", "self_signed")
DEFAULT_MODE = "mkcert_auto"


class _MkcertUnavailable(Exception):
    pass


def ensure_cert(cert_dir: Path, mode: Optional[str] = None, hostname: str = "localhost") -> tuple[Path, Path, str]:
    """Return (cert_path, key_path, actual_mode_used)."""
    mode = (mode or os.environ.get("CERT_MODE", DEFAULT_MODE)).strip().lower()
    if mode not in VALID_MODES:
        print(f"[cert] unknown CERT_MODE={mode!r}, falling back to {DEFAULT_MODE}")
        mode = DEFAULT_MODE

    cert_dir.mkdir(parents=True, exist_ok=True)

    if mode in ("mkcert_auto", "mkcert_manual"):
        try:
            cert, key = _try_mkcert(cert_dir, hostname, auto_download=(mode == "mkcert_auto"))
            return cert, key, "mkcert"
        except _MkcertUnavailable as e:
            print(f"[cert] mkcert path unavailable: {e}")
            print(f"[cert] falling back to self-signed (browser will warn first time)")

    cert, key = oauth_cert.ensure_cert(cert_dir, hostname=hostname)
    return cert, key, "self_signed"


def _try_mkcert(cert_dir: Path, hostname: str, auto_download: bool) -> tuple[Path, Path]:
    mkcert = _find_mkcert(cert_dir, auto_download=auto_download)
    if not mkcert:
        raise _MkcertUnavailable("mkcert binary not located")

    if not _verify_mkcert_works(mkcert):
        raise _MkcertUnavailable(f"mkcert at {mkcert} did not respond to -version")

    _ensure_mkcert_ca(mkcert)

    cert_path = cert_dir / "mkcert_cert.pem"
    key_path = cert_dir / "mkcert_key.pem"
    if not (cert_path.exists() and key_path.exists()):
        r = subprocess.run(
            [str(mkcert), "-cert-file", str(cert_path), "-key-file", str(key_path),
             hostname, "127.0.0.1"],
            capture_output=True, text=True, encoding="utf-8", errors="replace",
        )
        if r.returncode != 0:
            raise _MkcertUnavailable(f"mkcert cert gen failed: {r.stderr.strip()}")

    return cert_path, key_path


def _find_mkcert(cert_dir: Path, auto_download: bool) -> Optional[Path]:
    sys_mkcert = shutil.which("mkcert")
    if sys_mkcert:
        return Path(sys_mkcert)

    suffix = ".exe" if platform.system() == "Windows" else ""
    vendored = cert_dir / f"mkcert{suffix}"
    if vendored.exists():
        return vendored

    if not auto_download:
        _print_install_hints()
        return None

    if not _ask_consent_for_download():
        _print_install_hints()
        return None

    if not _download_mkcert(vendored):
        return None
    return vendored


def _verify_mkcert_works(mkcert: Path) -> bool:
    try:
        r = subprocess.run([str(mkcert), "-version"], capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=10)
        return r.returncode == 0
    except Exception:
        return False


def _ensure_mkcert_ca(mkcert: Path) -> None:
    """Run mkcert -install if CA not yet present. Triggers UAC/sudo as needed."""
    caroot = _get_caroot(mkcert)
    if caroot and (caroot / "rootCA.pem").exists():
        return

    print()
    print("=" * 64)
    print("  mkcert 需要安裝本機 CA 到系統 trust store")
    print("=" * 64)
    if platform.system() == "Windows":
        print("  Windows 即將跳 UAC 提示「mkcert 想變更系統」")
        print("  → 按「是」(一輩子只跳一次，之後永遠零警告)")
        print("  → 按「否」也沒關係，會自動 fallback 到自簽模式")
        print("=" * 64)
        ps_cmd = (
            f"$ErrorActionPreference='Stop'; "
            f"Start-Process -FilePath '{mkcert}' -ArgumentList '-install' "
            f"-Verb RunAs -Wait -WindowStyle Hidden"
        )
        try:
            r = subprocess.run(
                ["powershell", "-NoProfile", "-Command", ps_cmd],
                capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=120,
            )
            if r.returncode != 0:
                raise _MkcertUnavailable(
                    f"elevated mkcert -install failed (user denied UAC?): {r.stderr.strip() or 'no stderr'}"
                )
        except subprocess.TimeoutExpired:
            raise _MkcertUnavailable("mkcert -install timed out (no UAC response within 2 min)")
    else:
        print("  系統可能要求 sudo 密碼")
        print("=" * 64)
        r = subprocess.run([str(mkcert), "-install"], capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=120)
        if r.returncode != 0:
            raise _MkcertUnavailable(f"mkcert -install failed: {r.stderr.strip()}")

    time.sleep(0.5)
    caroot = _get_caroot(mkcert)
    if not (caroot and (caroot / "rootCA.pem").exists()):
        raise _MkcertUnavailable("CA file not present after install (UAC denied?)")
    print(f"  [OK] CA installed at {caroot}")


def _get_caroot(mkcert: Path) -> Optional[Path]:
    try:
        r = subprocess.run([str(mkcert), "-CAROOT"], capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=10)
        if r.returncode == 0 and r.stdout.strip():
            return Path(r.stdout.strip())
    except Exception:
        pass
    return None


def _ask_consent_for_download() -> bool:
    print()
    print("=" * 64)
    print("  CERT_MODE=mkcert_auto -> 需要下載 mkcert 啟用零警告模式")
    print("=" * 64)
    print(f"  來源    : GitHub releases (FiloSottile/mkcert {MKCERT_VERSION})")
    print(f"  大小    : 約 5 MB")
    print(f"  傳輸    : HTTPS to github.com (TLS verified)")
    print(f"  存放    : data/mkcert{'.exe' if platform.system() == 'Windows' else ''} (gitignored)")
    print(f"  接著    : 會跑 mkcert -install (Windows 跳 UAC 一次)")
    print()
    print("  下載？[Y/n] 按 n 會 fallback 到自簽 cert (功能不變，瀏覽器會警告) ",
          end="", flush=True)
    try:
        ans = input().strip().lower()
    except (EOFError, KeyboardInterrupt):
        print()
        return False
    return ans in ("", "y", "yes")


def _platform_key() -> tuple:
    arch = platform.machine().lower()
    if arch in ("amd64", "x86_64"):
        arch = "amd64"
    elif arch in ("arm64", "aarch64"):
        arch = "arm64"
    return (platform.system(), arch)


def _download_mkcert(target: Path) -> bool:
    key = _platform_key()
    filename = _BINARIES.get(key)
    if not filename:
        print(f"[cert] no mkcert binary published for {key}, fallback to self-signed")
        return False

    url = f"{MKCERT_BASE_URL}/{filename}"
    print(f"  downloading {url}")
    try:
        with urllib.request.urlopen(url, timeout=60) as resp:
            data = resp.read()
    except Exception as e:
        print(f"  download failed: {type(e).__name__}: {e}")
        return False

    expected = os.environ.get("MKCERT_SHA256", "").strip()
    if expected:
        digest = hashlib.sha256(data).hexdigest()
        if digest != expected:
            print(f"  SHA256 mismatch! expected {expected[:16]}..., got {digest[:16]}...")
            return False
        print(f"  SHA256 verified ({digest[:16]}...)")

    target.write_bytes(data)
    if platform.system() != "Windows":
        target.chmod(0o755)
    print(f"  saved {len(data):,} bytes to {target}")
    return True


def _print_install_hints() -> None:
    print()
    print("Install mkcert manually to enable zero-warning mode:")
    sys_ = platform.system()
    if sys_ == "Windows":
        print("  choco install mkcert                  (Chocolatey)")
        print("  scoop install mkcert                  (Scoop)")
        print("  winget install FiloSottile.mkcert     (winget)")
    elif sys_ == "Darwin":
        print("  brew install mkcert")
    else:
        print("  apt install libnss3-tools mkcert      (Debian/Ubuntu)")
        print("  dnf install nss-tools mkcert          (Fedora)")
    print("Or set CERT_MODE=mkcert_auto in .env to auto-download from GitHub.")
