import json

import pytest
from fastapi.testclient import TestClient

from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.errors import StartupError

from conftest import Clock, auth, login, ready


PASSWORD = "Synthetic durable password 2026"
TEMPORARY = "Synthetic temporary password 2026"
SUPPORTER = "fixture.supporter"
ALL_PERMISSIONS = [
    "component_egress:summary.read",
    "core:audit.verify",
    "core:health.read",
    "home_registry:resource_count.read",
    "session:activity.read",
]


def _settings(tmp_path, clock):
    root = tmp_path.resolve()
    return Settings(
        root / "data",
        root / "secrets/vault.key",
        clock=clock,
        login_ip_limit=100,
        login_account_limit=100,
        login_global_limit=100,
    )


def _scope(app):
    context = app.state.core.context
    return f"/api/v1/support-sessions/{context.coreId}/{context.homeId}"


def _external(token, supporter=SUPPORTER):
    return {
        "Authorization": "Bearer " + token,
        "X-Larenor-Supporter": supporter,
    }


def _create(client, root, actor, clock, request_key, permissions=None):
    return client.post(
        root,
        headers=auth(actor),
        json={
            "schemaVersion": 1,
            "requestKey": request_key,
            "supporterId": SUPPORTER,
            "supporterName": "Bounded support fixture",
            "permissions": permissions or ALL_PERMISSIONS,
            "expiresAt": clock.now + 600,
        },
    )


def _access(client, root, token, permission, supporter=SUPPORTER):
    return client.post(
        root + "/access",
        headers=_external(token, supporter),
        json={"schemaVersion": 1, "permission": permission},
    )


def _create_admin(client, actor, username):
    created = client.post(
        "/api/v1/admin/users",
        headers=auth(actor),
        json={"username": username, "role": "admin", "initialPassword": TEMPORARY},
    )
    assert created.status_code == 201, created.text
    initial = login(client, username, TEMPORARY).json()
    changed = client.post(
        "/api/v1/auth/password",
        headers=auth(initial),
        json={"currentPassword": TEMPORARY, "newPassword": PASSWORD},
    )
    assert changed.status_code == 200, changed.text
    return created.json()["user"], changed.json()


def test_real_support_session_restart_bounded_reads_activity_and_revoke(tmp_path):
    clock = Clock()
    settings = _settings(tmp_path, clock)
    app = create_app(settings)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        root = _scope(app)
        created = _create(client, root, admin, clock, "support-request-0001")
        assert created.status_code == 201, created.text
        body = created.json()
        session, token = body["session"], body["accessToken"]
        assert len(token) == 43 and token not in json.dumps(session)
        duplicate = _create(client, root, admin, clock, "support-request-0001")
        assert duplicate.status_code == 409
        assert duplicate.json()["error"]["code"] == "support_session_token_already_issued"

        for permission in ALL_PERMISSIONS:
            response = _access(client, root, token, permission)
            assert response.status_code == 200, response.text
            assert len(response.content) < 16_384
            result = response.json()
            assert result["permission"] == permission
            assert result["logPolicy"]["freeformLogsStored"] is False
            assert "authorization" in result["logPolicy"]["redactedFields"]
            assert token not in response.text
        wrong = _access(client, root, token, "core:health.read", "wrong.supporter")
        assert wrong.status_code == 401
        listing = client.get(root, headers=auth(admin))
        detail = client.get(f"{root}/{session['id']}", headers=auth(admin))
        assert listing.status_code == detail.status_code == 200
        assert token not in listing.text and token not in detail.text
        assert len(detail.json()["activity"]) == len(ALL_PERMISSIONS)

    with TestClient(create_app(settings)) as restarted:
        health = _access(restarted, root, token, "core:health.read")
        assert health.status_code == 200
        assert health.json()["result"] == {
            "status": "ready",
            "coreId": app.state.core.context.coreId,
            "homeId": app.state.core.context.homeId,
            "secretsIncluded": False,
            "remoteShellAvailable": False,
        }
        revoked = restarted.post(
            f"{root}/{session['id']}/revoke",
            headers=auth(admin),
            json={"schemaVersion": 1, "expectedRevision": session["revision"]},
        )
        assert revoked.status_code == 200
        assert revoked.json()["session"]["state"] == "revoked"
        assert _access(restarted, root, token, "core:health.read").status_code == 401


def test_support_denial_and_live_admin_authority_are_recorded(tmp_path):
    clock = Clock()
    settings = _settings(tmp_path, clock)
    app = create_app(settings)
    with TestClient(app) as client:
        owner = ready((app, client, settings, clock))
        root = _scope(app)
        delegated_user, delegated = _create_admin(client, owner, "supportdelegate")
        created = _create(
            client,
            root,
            delegated,
            clock,
            "support-authority-001",
            ["core:health.read"],
        )
        token = created.json()["accessToken"]
        session = created.json()["session"]
        denied = _access(client, root, token, "home_registry:resource_count.read")
        assert denied.status_code == 403
        assert denied.json()["error"]["code"] == "support_permission_forbidden"
        activity = client.get(f"{root}/{session['id']}", headers=auth(delegated)).json()["activity"]
        assert activity == [{
            "schemaVersion": 1,
            "id": activity[0]["id"],
            "permission": "home_registry:resource_count.read",
            "outcome": "denied",
            "createdAt": clock.now,
            "detailsStored": False,
        }]

        changed = client.patch(
            f"/api/v1/admin/users/{delegated_user['id']}",
            headers=auth(owner),
            json={"expectedRevision": 2, "role": "member"},
        )
        assert changed.status_code == 200
        inactive = _access(client, root, token, "core:health.read")
        assert inactive.status_code == 401
        assert inactive.json()["error"]["code"] == "support_session_inactive"

        expiring = _create(client, root, owner, clock, "support-expiry-00001", ["core:health.read"])
        expiry_token = expiring.json()["accessToken"]
        clock.now += 601
        assert _access(client, root, expiry_token, "core:health.read").status_code == 401


def test_support_storage_tamper_fails_closed_on_restart(tmp_path):
    clock = Clock()
    settings = _settings(tmp_path, clock)
    app = create_app(settings)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        created = _create(client, _scope(app), admin, clock, "support-tamper-0001")
        assert created.status_code == 201
        with app.state.core.db.transaction() as connection:
            connection.execute("UPDATE support_sessions SET supporter_name='tampered'")
    with pytest.raises(StartupError, match="support_session_storage_invalid"):
        create_app(settings)
