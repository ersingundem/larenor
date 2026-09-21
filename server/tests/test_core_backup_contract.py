import copy
import hashlib
import hmac
import sqlite3

from conftest import auth, ready


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
    assert manifest["contractVersion"] == 1
    assert len(manifest["snapshotId"]) == 32
    assert manifest["coreVersion"] == app.version
    assert manifest["databaseSchemaVersion"] == 3
    assert [(item["id"], item["kind"]) for item in manifest["resources"]] == [
        ("component-index", "componentData"),
        ("core-configuration", "configuration"),
        ("core-database", "database"),
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
        ("contractVersion", 2, "unsupported_contract_version"),
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
