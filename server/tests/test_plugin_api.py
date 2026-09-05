"""Real API, account and encrypted-storage boundaries for catalog previews."""

from concurrent.futures import ThreadPoolExecutor

import pytest
from fastapi.testclient import TestClient

from conftest import auth, bootstrap_password, login, ready
from test_admin import activate, create as create_user
from larenor_server.app import create_app
from larenor_server.errors import StartupError


BASE = "/api/v1/admin/plugins"


def request_for(client, pair, **changes):
    catalog = client.get(BASE + "/catalog", headers=auth(pair)).json()
    entry = next(item for item in catalog["entries"] if item["manifest"]["serviceId"] == "jellyfin")
    return {"serviceId": "jellyfin", "distributionId": entry["manifest"]["distributionId"],
            "manifestDigest": entry["manifestDigest"], "platform": "linux/amd64",
            "settings": {}, **changes}


def preview(client, pair, **changes):
    response = client.post(BASE + "/previews", headers=auth(pair), json=request_for(client, pair, **changes))
    assert response.status_code == 201, response.text
    return response.json()["preview"]


def test_catalog_and_preview_are_typed_and_do_not_claim_a_running_worker(server):
    app, client, settings, clock = server
    pair = ready(server)
    response = client.get(BASE + "/catalog", headers=auth(pair))
    assert response.status_code == 200
    catalog = response.json()
    assert len(catalog["entries"]) == 6
    assert catalog["worker"] == {"available": False, "platform": None, "reason": "worker_not_configured"}
    record = preview(client, pair)
    assert record["revision"] == 1
    assert record["createdAt"] == "2026-09-05T12:00:00.000Z"
    assert record["expiresAt"] == "2026-09-05T12:10:00.000Z"
    assert record["plan"]["installable"] is False
    assert "worker_unverified" in record["plan"]["blockers"]
    assert record["plan"]["catalogDigest"] == catalog["catalogDigest"]
    assert client.get(BASE + "/previews/" + record["id"], headers=auth(pair)).json() == {"preview": record}
    # Restart preserves the exact encrypted preview and active account.
    with TestClient(create_app(settings)) as restarted:
        assert restarted.get(BASE + "/previews/" + record["id"], headers=auth(pair)).json() == {"preview": record}
    schema = client.get("/api/v1/openapi.json", headers=auth(pair)).json()
    assert schema["paths"][BASE + "/previews"]["post"]["security"] == [{"DeviceAccessToken": []}]
    assert schema["paths"][BASE + "/catalog"]["get"]["responses"]["200"]["content"]["application/json"]["schema"]["$ref"].endswith("PluginCatalogResponse")
    # No fake queue or installation route exists until a worker is integrated.
    assert BASE + "/jobs" not in schema["paths"]
    assert not hasattr(app.state.core, "docker")


def test_anonymous_initial_account_and_members_cannot_read_or_preview(server):
    _, client, settings, _ = server
    initial = login(client, "admin", bootstrap_password(settings)).json()
    pair = ready(server)
    create_user(client, pair)
    member = activate(client, "member")
    body = request_for(client, pair)
    for headers, code in [({}, 401), (auth(initial), 401), (auth(member), 403)]:
        assert client.get(BASE + "/catalog", headers=headers).status_code == code
        assert client.post(BASE + "/previews", headers=headers, json=body).status_code == code
    # A still-current bootstrap account has not completed mandatory password change.


def test_initial_password_is_rejected_before_catalog_access(server):
    _, client, settings, _ = server
    initial = login(client, "admin", bootstrap_password(settings)).json()
    assert client.get(BASE + "/catalog", headers=auth(initial)).status_code == 403


@pytest.mark.parametrize("changes", [
    {"platform": "windows/amd64"}, {"manifestDigest": "x" * 64},
    {"settings": {"command": "unsafe-command"}}, {"settings": {"hostPath": "/etc"}},
    {"settings": {"token": "synthetic-secret-should-not-echo"}},
    {"settings": {"extra": {"nested": "value"}}}, {"settings": {"x": 1.5}},
    {"settings": {"x": None}}, {"extra": True},
])
def test_unrecognized_settings_and_types_are_static_errors(server, changes):
    app, client, _, _ = server
    pair = ready(server)
    response = client.post(BASE + "/previews", headers=auth(pair), json=request_for(client, pair, **changes))
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "invalid_request"
    assert "synthetic-secret" not in response.text and "unsafe-command" not in response.text
    with app.state.core.db.connection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM plugin_previews").fetchone()[0] == 0


def test_stale_manifest_and_missing_service_are_distinct(server):
    _, client, _, _ = server
    pair = ready(server)
    for changes, status, code in [({"manifestDigest": "0" * 64}, 409, "plugin_catalog_changed"),
                                  ({"serviceId": "missing"}, 404, "not_found")]:
        result = client.post(BASE + "/previews", headers=auth(pair), json=request_for(client, pair, **changes))
        assert result.status_code == status
        assert result.json()["error"]["code"] == code


def test_preview_is_private_to_account_and_session_family_but_survives_token_refresh(server):
    _, client, _, _ = server
    pair = ready(server)
    record = preview(client, pair)
    path = BASE + "/previews/" + record["id"]
    create_user(client, pair, "operator", "admin")
    operator = activate(client, "operator")
    assert client.get(path, headers=auth(operator)).status_code == 404
    other_device = login(client, "admin", "Synthetic new password 2026", "Another tablet").json()
    assert client.get(path, headers=auth(other_device)).status_code == 404
    refreshed = client.post("/api/v1/auth/refresh", json={"refreshToken": pair["refreshToken"]}).json()
    assert client.get(path, headers=auth(refreshed)).json() == {"preview": record}


def test_preview_expires_at_exact_boundary_and_expired_rows_release_capacity(server, monkeypatch):
    from larenor_server.plugins import service
    monkeypatch.setattr(service, "MAX_PREVIEWS", 1)
    app, client, _, clock = server
    pair = ready(server)
    record = preview(client, pair)
    denied = client.post(BASE + "/previews", headers=auth(pair), json=request_for(client, pair))
    assert denied.status_code == 409 and denied.json()["error"]["code"] == "plugin_preview_limit_reached"
    clock.now += 600
    assert client.get(BASE + "/previews/" + record["id"], headers=auth(pair)).json()["error"]["code"] == "plugin_preview_expired"
    replacement = preview(client, pair)
    assert replacement["id"] != record["id"]
    with app.state.core.db.connection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM plugin_previews").fetchone()[0] == 1


def test_preview_capacity_is_atomic_under_parallel_submissions(server, monkeypatch):
    from larenor_server.plugins import service
    from larenor_server.plugins.api_models import PluginPreviewRequest
    from larenor_server.errors import ApiError
    monkeypatch.setattr(service, "MAX_PREVIEWS", 1)
    app, client, _, _ = server
    pair = ready(server)
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    body = PluginPreviewRequest(**request_for(client, pair))
    def submit(_):
        try:
            app.state.core.plugins.preview(actor, body)
            return 201
        except ApiError as error:
            return error.status
    with ThreadPoolExecutor(max_workers=2) as pool:
        assert sorted(pool.map(submit, range(2))) == [201, 409]


def test_session_retention_can_remove_old_preview_without_blocking_login(server):
    app, client, _, clock = server
    pair = ready(server)
    record = preview(client, pair)
    with app.state.core.db.transaction() as connection:
        # A full device-session history causes the next legitimate login to
        # retire its oldest family. Previews must not block account recovery.
        for index in range(31):
            connection.execute("INSERT INTO session_families VALUES(?,?,?,?,?,NULL)",
                               (f"{index + 1:032x}", pair["user"]["id"], "Fixture tablet",
                                clock.now + index + 1, clock.now + 10000))
    assert login(client, "admin", "Synthetic new password 2026", "New tablet").status_code == 200
    with app.state.core.db.connection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM plugin_previews WHERE id=?", (record["id"],)).fetchone()[0] == 0


def test_revocation_during_calculation_cannot_commit_preview(server, monkeypatch):
    from larenor_server.plugins import service
    app, client, _, _ = server
    pair = ready(server)
    body = request_for(client, pair)
    original = service.plan
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    def revoke(*args, **kwargs):
        calculated = original(*args, **kwargs)
        app.state.core.auth.logout(actor)
        return calculated
    monkeypatch.setattr(service, "plan", revoke)
    assert client.post(BASE + "/previews", headers=auth(pair), json=body).status_code == 401
    with app.state.core.db.connection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM plugin_previews").fetchone()[0] == 0


@pytest.mark.parametrize("change", ["ciphertext", "actor_revision", "family_id", "expires_at"])
def test_corrupt_or_rebound_preview_fails_closed_and_is_never_replaced(server, change):
    app, client, settings, _ = server
    pair = ready(server)
    record = preview(client, pair)
    with app.state.core.db.connection() as connection:
        # Simulate offline file corruption, including metadata normally guarded
        # by SQLite constraints; authenticated decoding must still reject it.
        connection.execute("PRAGMA foreign_keys=OFF")
        connection.execute("PRAGMA ignore_check_constraints=ON")
        replacement = {"ciphertext": b"corrupt", "actor_revision": 999, "family_id": "a" * 32,
                       "expires_at": 2000000000}[change]
        connection.execute(f"UPDATE plugin_previews SET {change}=? WHERE id=?", (replacement, record["id"]))
    result = client.get(BASE + "/previews/" + record["id"], headers=auth(pair))
    assert result.status_code == 503
    assert result.json()["error"]["code"] == "plugin_storage_unavailable"
    with pytest.raises(StartupError, match="invalid_plugins_storage"):
        create_app(settings)


def test_plans_are_encrypted_with_distinct_aad_and_schema_preserves_other_tables(server):
    app, client, settings, _ = server
    pair = ready(server)
    record = preview(client, pair)
    with app.state.core.db.connection() as connection:
        row = connection.execute("SELECT * FROM plugin_previews").fetchone()
        assert b'"image"' not in row["ciphertext"]
        assert record["plan"]["planHash"].encode() not in row["ciphertext"]
        assert len(row["nonce"]) == 12
        assert connection.execute("SELECT value FROM metadata WHERE key='plugins_schema'").fetchone()[0] == "1"
        assert connection.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 1
        assert connection.execute("SELECT COUNT(*) FROM service_connections").fetchone()[0] == 0
    assert app.state.core.plugins._aad(row).startswith(b"larenor:plugins:schema=1:")


@pytest.mark.parametrize("change", ["unknown_version", "partial"])
def test_plugin_schema_refuses_partial_or_unknown_state_without_reset(server, change):
    app, _, settings, _ = server
    with app.state.core.db.transaction() as connection:
        if change == "unknown_version":
            connection.execute("UPDATE metadata SET value='900' WHERE key='plugins_schema'")
        else:
            connection.execute("DROP TABLE plugin_previews")
    with pytest.raises(StartupError, match="plugins_schema_unsupported"):
        create_app(settings)
