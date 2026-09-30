from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import hashlib
import socket
import ssl
import threading
import time

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID
from fastapi.testclient import TestClient
import pytest
import uvicorn

from larenor_server.core_backups.append_target import (
    AppendTargetPolicy, AppendTargetStore, create_append_target, DAY,
)
from larenor_server.core_backups.immutable_transport import RestAppendOnlyTransport
from larenor_server.errors import ApiError
from larenor_server.files import private_create

NOW = 1_800_000_000
WRITER = "w" * 40
RECOVERY = "r" * 40
PAYLOAD = b"isolated encrypted archive bytes"
OBJECT = "a" * 32


def policy(tmp_path):
    key = tmp_path / "secrets" / "target.key"
    private_create(key, bytes.fromhex("71" * 32))
    return AppendTargetPolicy(contractVersion=1, targetId="home-backup",
        dataDirectory=str(tmp_path / "data"), sealKeyFile=str(key),
        writeToken=WRITER, recoveryToken=RECOVERY,
        quotaBytes=64 * 1024**2, minimumRetentionDays=7)


def headers(*, payload=PAYLOAD, until=NOW + DAY, token=WRITER):
    return {"Authorization": "Bearer " + token,
        "Content-Type": "application/vnd.larenor.core-backup",
        "Content-Length": str(len(payload)), "X-Larenor-Protected-Until": str(until),
        "X-Larenor-SHA256": hashlib.sha256(payload).hexdigest()}


def test_append_only_real_persistence_retention_idempotency_and_recovery(tmp_path):
    cfg = policy(tmp_path)
    root = "/v1/append/home-backup/objects/" + OBJECT
    app = create_append_target(cfg, clock=lambda: NOW)
    with TestClient(app) as client:
        saved = client.post(root, headers=headers(), content=PAYLOAD)
        assert saved.status_code == 201
        receipt = saved.json()
        assert receipt["protectedUntil"] == NOW + 7 * DAY
        assert receipt["quotaUsedBytes"] == len(PAYLOAD)
        assert client.post(root, headers=headers(), content=PAYLOAD).json() == receipt
        changed = b"different archive"
        assert client.post(root, headers=headers(payload=changed), content=changed).status_code == 409
        assert client.delete(root, headers=headers()).status_code == 405
        assert client.post(root, headers=headers(token=RECOVERY), content=PAYLOAD).status_code == 401
        recovery = "/v1/recovery/home-backup/objects/" + OBJECT
        assert client.get(recovery, headers=headers()).status_code == 401
        fetched = client.get(recovery, headers=headers(token=RECOVERY))
        assert fetched.content == PAYLOAD
        assert fetched.headers["x-larenor-sha256"] == receipt["sha256"]
        assert fetched.headers["cache-control"] == "no-store"
    with TestClient(create_append_target(cfg, clock=lambda: NOW + 10 * DAY)) as restarted:
        assert restarted.get(recovery, headers=headers(token=RECOVERY)).content == PAYLOAD
        points = restarted.get("/v1/recovery/home-backup/objects", headers=headers(token=RECOVERY)).json()
        assert points["points"] == [receipt]
        # Retention expiry never grants delete/overwrite authority.
        assert restarted.delete(recovery, headers=headers(token=RECOVERY)).status_code == 405
        assert restarted.post(root, headers=headers(), content=PAYLOAD).json() == receipt


def test_wrong_digest_length_scope_and_quota_never_publish(tmp_path):
    app = create_append_target(policy(tmp_path), clock=lambda: NOW)
    with TestClient(app) as client:
        root = "/v1/append/home-backup/objects/" + OBJECT
        malformed = headers(); malformed["X-Larenor-SHA256"] = "0" * 64
        assert client.post(root, headers=malformed, content=PAYLOAD).status_code == 400
        malformed = headers(); malformed["Content-Length"] = str(len(PAYLOAD) + 1)
        assert client.post(root, headers=malformed, content=PAYLOAD).status_code == 400
        assert client.post(root.replace("home-backup", "other-target"), headers=headers(), content=PAYLOAD).status_code == 404
        malformed = headers(); malformed["Content-Length"] = str(65 * 1024**2)
        assert client.post(root, headers=malformed, content=PAYLOAD).status_code == 413
        assert app.state.append_store.points()["points"] == []


def test_persistent_byte_quota_rejects_new_object_without_deleting_old(tmp_path):
    cfg = policy(tmp_path)
    store = AppendTargetStore(cfg, clock=lambda: NOW)
    full = b"q" * cfg.quotaBytes
    receipt = store.append(OBJECT, full, hashlib.sha256(full).hexdigest(), NOW + DAY)
    assert receipt.quotaUsedBytes == cfg.quotaBytes
    with pytest.raises(ApiError, match="append_quota_exceeded"):
        store.append("b" * 32, b"x", hashlib.sha256(b"x").hexdigest(), NOW + DAY)
    restarted = AppendTargetStore(cfg, clock=lambda: NOW)
    assert restarted.points()["points"] == [receipt.model_dump()]
    assert restarted.read(OBJECT)[1] == full


def test_sealed_ledger_or_payload_tampering_fails_closed_after_restart(tmp_path):
    cfg = policy(tmp_path)
    store = AppendTargetStore(cfg, clock=lambda: NOW)
    store.append(OBJECT, PAYLOAD, hashlib.sha256(PAYLOAD).hexdigest(), NOW + DAY)
    with store._connection() as connection:
        connection.execute("UPDATE objects SET payload=?", (b"bad",))
    with pytest.raises(ApiError, match="append_target_storage_invalid"):
        AppendTargetStore(cfg, clock=lambda: NOW)
    with store._connection() as connection:
        connection.execute("DELETE FROM objects")
        connection.execute("DELETE FROM ledger")
    with pytest.raises(ApiError, match="append_target_storage_invalid"):
        AppendTargetStore(cfg, clock=lambda: NOW)


@contextmanager
def tls_target(tmp_path, cfg, clock=lambda: NOW):
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "localhost")])
    now = datetime.now(timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
        .public_key(key.public_key()).serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(minutes=1)).not_valid_after(now + timedelta(days=1))
        .add_extension(x509.SubjectAlternativeName([x509.DNSName("localhost")]), critical=False)
        .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
        .sign(key, hashes.SHA256()))
    cert_path, key_path = tmp_path / "tls" / "cert.pem", tmp_path / "tls" / "key.pem"
    private_create(cert_path, cert.public_bytes(serialization.Encoding.PEM))
    private_create(key_path, key.private_bytes(serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    listener = socket.socket(); listener.bind(("127.0.0.1", 0))
    running = uvicorn.Server(uvicorn.Config(create_append_target(cfg, clock=clock),
        ssl_certfile=str(cert_path), ssl_keyfile=str(key_path), log_level="critical", access_log=False))
    worker = threading.Thread(target=lambda: running.run(sockets=[listener]), daemon=True)
    worker.start()
    try:
        deadline = time.monotonic() + 5
        while not running.started:
            if time.monotonic() >= deadline or not worker.is_alive():
                raise RuntimeError("isolated_target_startup_failed")
            time.sleep(0.01)
        yield (f"https://localhost:{listener.getsockname()[1]}",
               ssl.create_default_context(cafile=str(cert_path)))
    finally:
        running.should_exit = True
        worker.join(timeout=5)
        listener.close()


def test_actual_tls_transport_can_append_and_recover_extended_retention(tmp_path):
    cfg = policy(tmp_path)
    with tls_target(tmp_path, cfg) as (endpoint, context):
        transport = RestAppendOnlyTransport(context=context)
        receipt = transport.append(endpoint=endpoint, target_id=cfg.targetId,
            object_id=OBJECT, payload=PAYLOAD, sha256=hashlib.sha256(PAYLOAD).hexdigest(),
            protected_until=NOW + DAY, write_token=WRITER)
        assert receipt.protectedUntil == NOW + 7 * DAY
        assert receipt.byteLength == len(PAYLOAD)
        assert transport.append(endpoint=endpoint, target_id=cfg.targetId,
            object_id=OBJECT, payload=PAYLOAD, sha256=receipt.sha256,
            protected_until=NOW + DAY, write_token=WRITER) == receipt
        assert transport.recover(endpoint=endpoint, target_id=cfg.targetId,
            object_id=OBJECT, expected_sha256=receipt.sha256,
            expected_byte_length=receipt.byteLength, recovery_token=RECOVERY) == PAYLOAD
        with pytest.raises(ApiError, match="immutable_target_receipt_mismatch"):
            transport.recover(endpoint=endpoint, target_id=cfg.targetId, object_id=OBJECT,
                expected_sha256="0" * 64, expected_byte_length=receipt.byteLength,
                recovery_token=RECOVERY)
        with pytest.raises(ApiError):
            transport.recover(endpoint=endpoint, target_id=cfg.targetId, object_id=OBJECT,
                expected_sha256=receipt.sha256, expected_byte_length=receipt.byteLength,
                recovery_token=WRITER)


def test_normal_core_scheduled_backup_remote_read_and_empty_core_recovery(server, tmp_path):
    from tests.conftest import ready, auth
    from tests.test_admin import create, activate
    from larenor_server.config import Settings
    from larenor_server.core_backups.restore import restore_empty
    from larenor_server.app import create_app
    app, client, _settings, clock = server
    pair = ready(server)
    cfg = policy(tmp_path / "remote")
    with tls_target(tmp_path / "remote", cfg, clock) as (endpoint, tls):
        manager = app.state.core.core_backups.immutable_target
        manager.transport = RestAppendOnlyTransport(context=tls)
        body = dict(contractVersion=1, expectedRevision=0, endpoint=endpoint,
            targetId=cfg.targetId, retentionDays=7, quotaBytes=cfg.quotaBytes,
            writeToken=WRITER, recoveryToken=RECOVERY,
            backupPassphrase="Synthetic backup passphrase 2026")
        assert client.put("/api/v1/admin/backups/immutable-target", headers=auth(pair), json=body).status_code == 200
        clock.now += DAY + 1
        # Refresh access after the schedule advances, preserving the actor family.
        refreshed = client.post("/api/v1/auth/refresh", json={"refreshToken": pair["refreshToken"]})
        assert refreshed.status_code == 200
        pair = refreshed.json()
        assert manager.tick() is True
        points = client.get("/api/v1/admin/backups/immutable-target/restore-points", headers=auth(pair))
        assert points.status_code == 200
        point = points.json()["points"][0]
        url = "/api/v1/admin/backups/immutable-target/restore-points/" + point["objectId"] + "/archive"
        exported = client.get(url, headers=auth(pair))
        assert exported.status_code == 200
        assert hashlib.sha256(exported.content).hexdigest() == point["sha256"]
        assert exported.headers["x-larenor-capture-generation"]
        assert exported.headers["cache-control"] == "no-store"
        assert exported.headers["x-content-type-options"] == "nosniff"
        destination = tmp_path / "replacement"
        settings = Settings(destination / "data", destination / "secrets" / "vault.key", clock=clock)
        restore_empty(settings, exported.content, body["backupPassphrase"])
        with TestClient(create_app(settings)) as restored:
            assert restored.get("/api/v1/health").status_code == 200
        create(client, pair)
        member = activate(client, "member")
        assert client.get(url, headers=auth(member)).status_code == 403
        body["expectedRevision"] = 1
        assert client.put("/api/v1/admin/backups/immutable-target", headers=auth(pair), json=body).status_code == 200
        assert client.get(url, headers=auth(pair)).status_code == 409


def test_prepared_retry_rechecks_configuring_admin_authority(server):
    from tests.conftest import ready, auth
    app, client, _settings, clock = server
    pair = ready(server)
    manager = app.state.core.core_backups.immutable_target

    class InterruptedTransport:
        calls = 0

        def append(self, **_request):
            self.calls += 1
            raise ApiError("immutable_target_unavailable", 503)

    interrupted = InterruptedTransport()
    manager.transport = interrupted
    body = dict(contractVersion=1, expectedRevision=0,
        endpoint="https://backup.example.invalid", targetId="home-backup",
        retentionDays=7, quotaBytes=64 * 1024**2,
        writeToken=WRITER, recoveryToken=RECOVERY,
        backupPassphrase="Synthetic backup passphrase 2026")
    assert client.put("/api/v1/admin/backups/immutable-target", headers=auth(pair), json=body).status_code == 200
    clock.now += DAY + 1
    with pytest.raises(ApiError, match="immutable_target_unavailable"):
        manager.tick()
    assert interrupted.calls == 1
    with app.state.core.db.transaction() as connection:
        assert connection.execute("SELECT state FROM immutable_backup_job").fetchone()[0] == "prepared"
        connection.execute("UPDATE users SET revision=revision+1 WHERE role='admin'")
    with pytest.raises(ApiError, match="forbidden"):
        manager.tick()
    assert interrupted.calls == 1
    assert list(manager._pending.iterdir())
