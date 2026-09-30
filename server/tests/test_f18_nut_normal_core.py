import hashlib
import json
import socket
import threading
import time
from datetime import datetime, timedelta, timezone

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID
from fastapi.testclient import TestClient
import uvicorn

from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.power_recovery.nut_bridge import (
    CoreHttpsDelivery,
    NutBridgeConfig,
    NutBridgeOutbox,
    NutBridgeWorker,
)
from tests.conftest import auth, ready


NOW = 1_788_800_000


def _certificate(tmp_path):
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "127.0.0.1")])
    current = datetime.now(timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(current - timedelta(minutes=1))
        .not_valid_after(current + timedelta(days=1))
        .add_extension(
            x509.SubjectAlternativeName([x509.IPAddress(__import__("ipaddress").ip_address("127.0.0.1"))]),
            critical=False,
        )
        .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
        .sign(key, hashes.SHA256())
    )
    cert_path, key_path = tmp_path / "cert.pem", tmp_path / "key.pem"
    cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    key_path.write_bytes(
        key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
    )
    cert_path.chmod(0o600)
    key_path.chmod(0o600)
    return cert_path, key_path


def _bridge_config(tmp_path, port, cert_path):
    state = tmp_path / "nut-state"
    state.mkdir(mode=0o700)
    upsc = tmp_path / "upsc"
    upsc.write_text(
        "#!/bin/sh\nprintf 'battery.charge: 96\\nbattery.runtime: 600\\nups.status: OL\\n'\n",
        encoding="ascii",
    )
    upsc.chmod(0o700)
    source = tmp_path / "nut.json"
    source.write_text(json.dumps({
        "schemaVersion": 1,
        "sourceId": "ups-main",
        "sourceRevision": 1,
        "sourceToken": "t" * 32,
        "upsName": "rackups@127.0.0.1:3493",
        "coreUrl": f"https://127.0.0.1:{port}",
        "caFile": str(cert_path),
        "caSha256": hashlib.sha256(cert_path.read_bytes()).hexdigest(),
        "upsc": str(upsc),
        "upscSha256": hashlib.sha256(upsc.read_bytes()).hexdigest(),
        "stateRoot": str(state),
        "maxEventAgeSeconds": 240,
        "upscTimeoutSeconds": 3,
        "httpTimeoutSeconds": 5,
        "retrySeconds": 2,
        "notifyUser": "nut",
    }), encoding="utf-8")
    source.chmod(0o600)
    return NutBridgeConfig.load(source)


def test_verified_nut_snapshot_to_tls_normal_core_ingest_and_durable_readback(tmp_path):
    settings = Settings(
        tmp_path / "data", tmp_path / "secrets/vault.key",
        clock=lambda: NOW, login_ip_limit=100,
        login_account_limit=100, login_global_limit=100,
    )
    app = create_app(settings)
    with TestClient(app) as client:
        admin = ready((app, client, settings, None))
        configured = client.put(
            "/api/v1/admin/power-recovery/policy",
            headers=auth(admin),
            json={
                "contractVersion": 1,
                "expectedRevision": 0,
                "sourceId": "ups-main",
                "sourceToken": "t" * 32,
                "criticalRuntimeSeconds": 60,
                "restoreStableSeconds": 30,
                "targets": [{
                    "targetId": "a" * 32,
                    "label": "Synthetic no-effect target",
                    "kind": "service",
                    "shutdownOrder": 1,
                    "startOnRestore": False,
                    "timeoutSeconds": 30,
                }],
            },
        )
        assert configured.status_code == 200, configured.text

    cert_path, key_path = _certificate(tmp_path)
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    running = uvicorn.Server(uvicorn.Config(
        app, ssl_certfile=str(cert_path), ssl_keyfile=str(key_path),
        log_level="critical", access_log=False,
    ))
    thread = threading.Thread(
        target=lambda: running.run(sockets=[listener]), daemon=True,
    )
    thread.start()
    try:
        deadline = time.monotonic() + 5
        while not running.started:
            assert thread.is_alive() and time.monotonic() < deadline
            time.sleep(0.01)
        config = _bridge_config(tmp_path, listener.getsockname()[1], cert_path)
        outbox = NutBridgeOutbox(config, clock=lambda: NOW)
        outbox.enqueue({"UPSNAME": config.ups_name, "NOTIFYTYPE": "ONLINE"})
        result = NutBridgeWorker(
            config, outbox,
            upsc=lambda peer, timeout: (
                b"battery.charge: 96\nbattery.runtime: 600\nups.status: OL\n"
                if (peer, timeout) == (config.ups_name, 3)
                else (_ for _ in ()).throw(AssertionError("unexpected upsc request"))
            ),
            deliver=CoreHttpsDelivery(config), clock=lambda: NOW,
        ).run_once()
        assert result == "delivered"
        assert outbox.status()["lastDeliveredSequence"] == 1
        with app.state.core.db.connection() as connection:
            state = connection.execute(
                "SELECT source_state,last_sequence,last_observed_at "
                "FROM power_recovery_state WHERE id=1"
            ).fetchone()
        assert tuple(state) == ("online", 1, NOW)
    finally:
        running.should_exit = True
        thread.join(timeout=5)
        listener.close()
