from conftest import auth, ready
from larenor_server.multi_display import service


def _path(app):
    context = app.state.core.context
    return f"/api/v1/multi-display/{context.coreId}/{context.homeId}/authority"


def test_authority_projects_exact_current_core_home_account_and_session(server):
    app, client, _settings, _clock = server
    pair = ready(server)
    response = client.get(_path(app), headers=auth(pair))
    assert response.status_code == 200, response.text
    value = response.json()
    authority = value["authority"]
    snapshot = value["publicSnapshot"]
    with app.state.core.db.connection() as connection:
        user = connection.execute(
            "SELECT revision FROM users WHERE id=?", (pair["user"]["id"],)
        ).fetchone()
        home = app.state.core.home_resources._state(connection)
    assert authority == {
        "schemaVersion": 1,
        "coreId": app.state.core.context.coreId,
        "homeId": app.state.core.context.homeId,
        "accountId": pair["user"]["id"],
        "accountRevision": user["revision"],
        "homeRevision": home["revision"],
        "sessionFamilyId": pair["sessionFamilyId"],
        "routePolicyRevision": 2,
        "allowedSecondaryRoutes": ["core.status"],
    }
    assert value["schemaVersion"] == 1
    assert set(snapshot) == {
        "schemaVersion", "snapshotRevision", "observedAtMs", "expiresAtMs",
        "serviceState", "apiVersion", "systemLoadPercent", "processMemoryMiB",
        "dataDiskFreeBytes", "dataDiskTotalBytes", "processUptimeSeconds",
    }
    assert snapshot["schemaVersion"] == snapshot["apiVersion"] == 1
    assert snapshot["serviceState"] == "online"
    assert 0 <= snapshot["systemLoadPercent"] <= 100
    assert 0 <= snapshot["processMemoryMiB"] <= 1_048_576
    assert 0 <= snapshot["dataDiskFreeBytes"] <= snapshot["dataDiskTotalBytes"]
    assert snapshot["expiresAtMs"] - snapshot["observedAtMs"] == 15_000
    assert snapshot["processUptimeSeconds"] >= 0
    private_words = (
        "accessToken", "refreshToken", "accountId", "sessionFamilyId",
        "coreId", "homeId", "hostname", "path", "media",
    )
    snapshot_text = str(snapshot)
    assert all(word not in snapshot_text for word in private_words)


def test_authority_fails_closed_for_wrong_scope_revoked_session_and_unsafe_revision(server):
    app, client, _settings, clock = server
    pair = ready(server)
    context = app.state.core.context
    wrong = client.get(
        f"/api/v1/multi-display/{'f' * 32}/{context.homeId}/authority",
        headers=auth(pair),
    )
    assert wrong.status_code == 404

    with app.state.core.db.transaction() as connection:
        connection.execute(
            "UPDATE users SET revision=? WHERE id=?",
            (2**53, pair["user"]["id"]),
        )
    overflow = client.get(_path(app), headers=auth(pair))
    assert overflow.status_code == 503
    with app.state.core.db.transaction() as connection:
        connection.execute(
            "UPDATE users SET revision=2 WHERE id=?", (pair["user"]["id"],)
        )
        connection.execute(
            "UPDATE session_families SET revoked_at=? WHERE id=?",
            (clock(), pair["sessionFamilyId"]),
        )
    revoked = client.get(_path(app), headers=auth(pair))
    assert revoked.status_code == 401


def test_public_observation_rechecks_authority_after_actual_os_read(server, monkeypatch):
    app, client, _settings, clock = server
    pair = ready(server)
    original = service.os.statvfs

    def revoke_during_read(path):
        result = original(path)
        with app.state.core.db.transaction() as connection:
            connection.execute(
                "UPDATE session_families SET revoked_at=? WHERE id=?",
                (clock(), pair["sessionFamilyId"]),
            )
        return result

    monkeypatch.setattr(service.os, "statvfs", revoke_during_read)
    response = client.get(_path(app), headers=auth(pair))
    assert response.status_code == 401


def test_public_observation_fails_closed_when_host_metric_is_unavailable(server, monkeypatch):
    app, client, _settings, _clock = server
    pair = ready(server)
    monkeypatch.setattr(
        service.os,
        "statvfs",
        lambda _path: (_ for _ in ()).throw(OSError("synthetic private path")),
    )
    response = client.get(_path(app), headers=auth(pair))
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "server_unavailable"
    assert "synthetic private path" not in response.text
