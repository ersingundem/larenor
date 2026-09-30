import datetime
import ipaddress
import json
import os
import socket
import ssl
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

from larenor_server import cli
from larenor_server.config import Settings

from conftest import bootstrap_password


def _tls_pair(root, *, stem="server"):
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "127.0.0.1")])
    now = datetime.datetime.now(datetime.UTC)
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(minutes=1))
        .not_valid_after(now + datetime.timedelta(days=1))
        .add_extension(
            x509.SubjectAlternativeName([x509.IPAddress(ipaddress.ip_address("127.0.0.1"))]),
            critical=False,
        )
        .sign(key, hashes.SHA256())
    )
    cert_path, key_path = root / f"{stem}.pem", root / f"{stem}.key"
    cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    key_path.write_bytes(
        key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
    )
    os.chmod(cert_path, 0o600)
    os.chmod(key_path, 0o600)
    return cert_path, key_path


def test_initialize_only_prints_private_file_location_never_password_or_key(tmp_path, monkeypatch, capsys):
    root = tmp_path.resolve()
    settings = Settings(root / "data", root / "secrets/vault.key")
    monkeypatch.setattr(Settings, "from_environment", classmethod(lambda _cls: settings))
    assert cli.main(["--initialize-only"]) == 0
    output = capsys.readouterr()
    assert str(settings.effective_bootstrap_file) in output.out
    assert bootstrap_password(settings) not in output.out + output.err
    assert settings.key_file.read_bytes().hex() not in output.out + output.err
    assert cli.main(["--initialize-only"]) == 0
    assert capsys.readouterr().out == ""


def test_invalid_key_error_has_static_code_without_path_or_secret(tmp_path, monkeypatch, capsys):
    root = tmp_path.resolve()
    settings = Settings(root / "data", root / "secrets/vault.key")
    monkeypatch.setattr(Settings, "from_environment", classmethod(lambda _cls: settings))
    assert cli.main(["--initialize-only"]) == 0
    capsys.readouterr()
    settings.key_file.write_bytes(b"synthetic-secret-invalid-key")
    assert cli.main(["--initialize-only"]) == 1
    output = capsys.readouterr()
    assert output.out == ""
    assert output.err == "Larenor Server initialization failed: vault_key_invalid\n"
    assert "synthetic" not in output.err


def test_tls_pair_is_private_validated_and_passed_to_uvicorn(tmp_path, monkeypatch):
    root = tmp_path.resolve()
    settings = Settings(root / "data", root / "secrets/vault.key")
    cert_path, key_path = _tls_pair(root)
    captured = {}
    monkeypatch.setattr(Settings, "from_environment", classmethod(lambda _cls: settings))
    monkeypatch.setattr(cli.uvicorn, "run", lambda app, **options: captured.update(options))

    assert cli.main(["--tls-cert", str(cert_path), "--tls-key", str(key_path)]) == 0
    assert captured["ssl_certfile"] == str(cert_path)
    assert captured["ssl_keyfile"] == str(key_path)
    assert captured["ssl_version"] == cli.ssl.PROTOCOL_TLS_SERVER


def test_tls_configuration_rejects_partial_mismatched_and_permissive_inputs(
    tmp_path, monkeypatch, capsys
):
    root = tmp_path.resolve()
    settings = Settings(root / "data", root / "secrets/vault.key")
    monkeypatch.setattr(Settings, "from_environment", classmethod(lambda _cls: settings))
    cert_path, key_path = _tls_pair(root, stem="one")
    _, other_key = _tls_pair(root, stem="two")

    with pytest.raises(SystemExit):
        cli.main(["--tls-cert", str(cert_path), "--initialize-only"])
    assert "must be used together" in capsys.readouterr().err

    assert cli.main([
        "--tls-cert", str(cert_path), "--tls-key", str(other_key), "--initialize-only"
    ]) == 1
    output = capsys.readouterr()
    assert output.err == "Larenor Server initialization failed: tls_configuration_invalid\n"
    assert str(cert_path) not in output.err

    os.chmod(key_path, 0o644)
    assert cli.main([
        "--tls-cert", str(cert_path), "--tls-key", str(key_path), "--initialize-only"
    ]) == 1
    assert capsys.readouterr().err == (
        "Larenor Server initialization failed: storage_file_not_private\n"
    )


def test_cli_serves_normal_core_health_over_trusted_tls(tmp_path):
    root = tmp_path.resolve()
    cert_path, key_path = _tls_pair(root)
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    environment = {
        key: value for key, value in os.environ.items()
        if not key.startswith("LARENOR_")
    }
    environment.update(
        LARENOR_DATA_DIR=str(root / "data"),
        LARENOR_KEY_FILE=str(root / "secrets/vault.key"),
        PYTHONPATH=str(Path(__file__).resolve().parents[1]),
    )
    process = subprocess.Popen(
        [
            sys.executable,
            "-m",
            "larenor_server.cli",
            "--host",
            "127.0.0.1",
            "--port",
            str(port),
            "--tls-cert",
            str(cert_path),
            "--tls-key",
            str(key_path),
        ],
        cwd=Path(__file__).resolve().parents[1],
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    context = ssl.create_default_context(cafile=str(cert_path))
    try:
        deadline = time.monotonic() + 20
        while True:
            try:
                with urllib.request.urlopen(
                    f"https://127.0.0.1:{port}/api/v1/health",
                    context=context,
                    timeout=1,
                ) as response:
                    payload = json.load(response)
                    assert response.status == 200
                    assert payload["service"] == "larenor-server"
                    break
            except (OSError, urllib.error.URLError):
                if process.poll() is not None or time.monotonic() >= deadline:
                    stdout, stderr = process.communicate(timeout=2)
                    pytest.fail(
                        "normal TLS Core did not become ready: "
                        f"exit={process.returncode}, stdout={stdout!r}, stderr={stderr!r}"
                    )
                time.sleep(0.05)
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
