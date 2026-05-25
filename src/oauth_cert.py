"""Self-signed TLS cert for the OAuth localhost HTTPS callback server.

Meta requires all Threads OAuth redirect URIs to use https://, so the L2
localhost callback needs a real TLS handshake. We generate a self-signed
cert on first run and cache it under data/ (gitignored).

Browsers will show "Your connection is not private" the first time because
a self-signed cert isn't in any root store. Click Advanced -> Proceed to
localhost (unsafe) once; the localhost server receives Meta's redirect
and OAuth finishes normally.
"""
from datetime import UTC, datetime, timedelta
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID


def ensure_cert(cert_dir: Path, hostname: str = "localhost", days: int = 365) -> tuple[Path, Path]:
    """Generate cert + key if missing. Returns (cert_path, key_path). Idempotent."""
    cert_dir.mkdir(parents=True, exist_ok=True)
    cert_path = cert_dir / "oauth_cert.pem"
    key_path = cert_dir / "oauth_key.pem"
    if cert_path.exists() and key_path.exists():
        return cert_path, key_path

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = issuer = x509.Name([
        x509.NameAttribute(NameOID.COMMON_NAME, hostname),
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, "threads-bot oauth localhost"),
    ])
    now = datetime.now(UTC)
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(days=1))
        .not_valid_after(now + timedelta(days=days))
        .add_extension(
            x509.SubjectAlternativeName([
                x509.DNSName(hostname),
                x509.DNSName("127.0.0.1"),
            ]),
            critical=False,
        )
        .sign(private_key=key, algorithm=hashes.SHA256())
    )

    cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    key_path.write_bytes(key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.TraditionalOpenSSL,
        encryption_algorithm=serialization.NoEncryption(),
    ))
    return cert_path, key_path
