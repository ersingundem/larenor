import copy
import hashlib
import hmac
import sqlite3

import pytest
from conftest import auth, ready

from larenor_server.errors import ApiError


def plan(client, pair):
    response = client.get("/api/v1/admin/backups/plan", headers=auth(pair))
    assert response.status_code == 200
    return response.json()


def test_admin_plan_binds_one_consistent_db_key_config_and_component_set(
    server, tmp_path
):
    app, client, settings, _clock = server
    pair = ready(server)

    response = plan(client, pair)

    assert response["status"] == "ready"
    assert response["blockers"] == []
    manifest = response["manifest"]
    assert manifest["contractVersion"] == 2
    assert len(manifest["snapshotId"]) == 32
    assert manifest["coreVersion"] == app.version
    assert manifest["databaseSchemaVersion"] == 3
    assert [(item["id"], item["kind"]) for item in manifest["resources"]] == [
        ("component-index", "componentData"),
        ("core-configuration", "configuration"),
        ("core-database", "database"),
        ("family-board", "familyBoard"),
        ("vault-key", "vaultKey"),
    ]
    for item in manifest["resources"]:
        assert item["byteLength"] > 0
        assert len(item["sha256"]) == 64
        assert "/" not in item["id"]
    raw = str(response)
    assert str(settings.data_dir) not in raw
    assert str(settings.key_file) not in raw
    assert settings.key_file.read_bytes().hex() not in raw

    actor = app.state.core.auth.authenticate(pair["accessToken"])
    capture = app.state.core.core_backups.capture(actor)
    snapshot_path = tmp_path / "snapshot.sqlite3"
    snapshot_path.write_bytes(capture.payloads["core-database"])
    snapshot = sqlite3.connect(snapshot_path)
    stored = snapshot.execute(
        "SELECT value FROM metadata WHERE key='key_check'"
    ).fetchone()[0]
    expected = hmac.new(
        capture.payloads["vault-key"],
        b"larenor-vault-key-check-v1",
        hashlib.sha256,
    ).hexdigest()
    assert hmac.compare_digest(stored, expected)
    assert snapshot.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    snapshot.close()


def test_plan_and_export_reject_a_key_that_no_longer_matches_the_database(server):
    _app, client, settings, _clock = server
    pair = ready(server)
    original = settings.key_file.read_bytes()
    replacement = bytes(byte ^ 0xFF for byte in original)

    try:
        settings.key_file.write_bytes(replacement)
        responses = (
            client.get("/api/v1/admin/backups/plan", headers=auth(pair)),
            client.post(
                "/api/v1/admin/backups/export",
                headers=auth(pair),
                json={"passphrase": "Correct horse battery staple 2026"},
            ),
        )
    finally:
        settings.key_file.write_bytes(original)

    for response in responses:
        assert response.status_code == 503
        assert response.json()["error"] == {
            "code": "server_unavailable",
            "message": "The service is temporarily unavailable.",
        }
        assert str(settings.key_file) not in response.text
        assert replacement.hex() not in response.text


def test_inflight_effect_blocks_cut_and_never_claims_ready(server):
    app, client, _settings, clock = server
    pair = ready(server)
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    with app.state.core.db.transaction() as connection:
        connection.execute(
            "INSERT INTO bounded_transfer_receipts VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (
                "1" * 32,
                actor.id,
                app.state.core.context.coreId,
                app.state.core.context.homeId,
                "2" * 32,
                "3" * 64,
                "accepted",
                "4" * 32,
                1,
                "5" * 64,
                "application/octet-stream",
                1,
                clock(),
                clock(),
                "6" * 64,
            ),
        )

    response = plan(client, pair)

    assert response == {
        "status": "blocked",
        "blockers": ["active_bounded_transfer"],
        "manifest": None,
    }


def test_restore_validation_is_exact_versioned_and_fail_closed(server):
    _app, client, _settings, _clock = server
    pair = ready(server)
    manifest = plan(client, pair)["manifest"]

    accepted = client.post(
        "/api/v1/admin/backups/restore/validate",
        headers=auth(pair),
        json={"manifest": manifest},
    )
    assert accepted.status_code == 200
    assert accepted.json() == {"compatible": True, "reasons": []}

    for field, value, reason in (
        ("contractVersion", 3, "unsupported_contract_version"),
        ("databaseSchemaVersion", 2, "database_schema_mismatch"),
        ("coreVersion", "99.0.0", "core_version_mismatch"),
        ("componentSchemaVersions", {}, "component_schema_mismatch"),
    ):
        changed = copy.deepcopy(manifest)
        changed[field] = value
        if field == "databaseSchemaVersion":
            next(
                item for item in changed["resources"] if item["id"] == "core-database"
            )["version"] = "2"
        response = client.post(
            "/api/v1/admin/backups/restore/validate",
            headers=auth(pair),
            json={"manifest": changed},
        )
        assert response.status_code == 200
        assert response.json() == {"compatible": False, "reasons": [reason]}

    missing = copy.deepcopy(manifest)
    missing["resources"].pop()
    response = client.post(
        "/api/v1/admin/backups/restore/validate",
        headers=auth(pair),
        json={"manifest": missing},
    )
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "invalid_request"


def test_backup_contract_is_admin_only_strict_and_documented(server):
    _app, client, _settings, _clock = server
    admin = ready(server)
    created = client.post(
        "/api/v1/admin/users",
        headers=auth(admin),
        json={
            "username": "member",
            "initialPassword": "Synthetic member pass 2026",
            "role": "member",
        },
    )
    assert created.status_code == 201
    member = client.post(
        "/api/v1/auth/login",
        json={
            "username": "member",
            "password": "Synthetic member pass 2026",
            "deviceName": "Tablet",
        },
    ).json()
    assert (
        client.get("/api/v1/admin/backups/plan", headers=auth(member)).status_code
        == 403
    )

    manifest = plan(client, admin)["manifest"]
    invalid = client.post(
        "/api/v1/admin/backups/restore/validate",
        headers=auth(admin),
        json={"manifest": manifest, "unexpected": True},
    )
    assert invalid.status_code == 400

    contract = client.get("/api/v1/openapi.json", headers=auth(admin)).json()
    paths = contract["paths"]
    assert "/api/v1/admin/backups/plan" in paths
    assert "/api/v1/admin/backups/restore/validate" in paths
    assert "/api/v1/admin/backups/export" in paths
    export_content = paths["/api/v1/admin/backups/export"]["post"]["responses"]["200"][
        "content"
    ]
    assert "application/vnd.larenor.core-backup" in export_content


def test_encrypted_export_roundtrip_contains_exact_captured_resources(server):
    app, client, settings, _clock = server
    pair = ready(server)
    response = client.post(
        "/api/v1/admin/backups/export",
        headers=auth(pair),
        json={"passphrase": "Correct horse battery staple 2026"},
    )

    assert response.status_code == 200
    assert response.headers["content-type"] == "application/vnd.larenor.core-backup"
    assert response.headers["cache-control"] == "no-store"
    assert response.headers["content-disposition"] == (
        'attachment; filename="larenor-core-backup.larenor-core"'
    )
    bundle = response.content
    assert bundle.startswith(b"LARENOR-CORE-BACKUP\x00\x01")
    assert settings.key_file.read_bytes() not in bundle
    assert b"CREATE TABLE" not in bundle
    assert b"admin" not in bundle

    opened = app.state.core.core_backups.open_bundle(
        bundle, "Correct horse battery staple 2026"
    )
    assert set(opened.payloads) == {
        "component-index",
        "core-configuration",
        "core-database",
        "family-board",
        "vault-key",
    }
    by_id = {resource.id: resource for resource in opened.manifest.resources}
    for identifier, payload in opened.payloads.items():
        assert by_id[identifier].byteLength == len(payload)
        assert by_id[identifier].sha256 == hashlib.sha256(payload).hexdigest()


def test_encrypted_export_rejects_wrong_passphrase_tamper_and_weak_input(server):
    app, client, _settings, _clock = server
    pair = ready(server)
    bundle = client.post(
        "/api/v1/admin/backups/export",
        headers=auth(pair),
        json={"passphrase": "Correct horse battery staple 2026"},
    ).content

    for changed, passphrase in (
        (bundle, "Wrong horse battery staple 2026"),
        (bundle[:-1] + bytes([bundle[-1] ^ 1]), "Correct horse battery staple 2026"),
        (bundle[:20], "Correct horse battery staple 2026"),
    ):
        with pytest.raises(ApiError) as raised:
            app.state.core.core_backups.open_bundle(changed, passphrase)
        assert raised.value.code == "backup_decryption_failed"
        assert str(raised.value) == "backup_decryption_failed"

    weak = client.post(
        "/api/v1/admin/backups/export",
        headers=auth(pair),
        json={"passphrase": "too short"},
    )
    assert weak.status_code == 400
    assert weak.json()["error"]["code"] == "invalid_request"


def test_export_never_runs_through_an_active_effect(server):
    app, client, _settings, clock = server
    pair = ready(server)
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    with app.state.core.db.transaction() as connection:
        connection.execute(
            "INSERT INTO bounded_transfer_receipts VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (
                "7" * 32,
                actor.id,
                app.state.core.context.coreId,
                app.state.core.context.homeId,
                "8" * 32,
                "9" * 64,
                "accepted",
                "a" * 32,
                1,
                "b" * 64,
                "application/octet-stream",
                1,
                clock(),
                clock(),
                "c" * 64,
            ),
        )

    response = client.post(
        "/api/v1/admin/backups/export",
        headers=auth(pair),
        json={"passphrase": "Correct horse battery staple 2026"},
    )
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "backup_blocked"


def test_export_has_one_bounded_expensive_worker_and_never_echoes_passphrase(server):
    app, client, _settings, _clock = server
    pair = ready(server)
    lock = app.state.core.core_backups._export_lock
    assert lock.acquire(blocking=False)
    try:
        response = client.post(
            "/api/v1/admin/backups/export",
            headers=auth(pair),
            json={"passphrase": "Never echo this backup passphrase 2026"},
        )
    finally:
        lock.release()
    assert response.status_code == 409
    assert response.json()["error"] == {
        "code": "backup_busy",
        "message": "Another Core backup is already being created.",
    }
    assert "Never echo" not in response.text


def test_plan_shares_the_expensive_capture_gate_with_export(server):
    app, client, _settings, _clock = server
    pair = ready(server)
    lock = app.state.core.core_backups._export_lock
    assert lock.acquire(blocking=False)
    try:
        response = client.get("/api/v1/admin/backups/plan", headers=auth(pair))
    finally:
        lock.release()
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "backup_busy"
    assert plan(client, pair)["status"] == "ready"
