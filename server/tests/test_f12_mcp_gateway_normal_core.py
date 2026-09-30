import json

import pytest
from fastapi.testclient import TestClient

from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.errors import StartupError

from conftest import Clock, auth, login, ready


PASSWORD = "Synthetic durable password 2026"
TEMPORARY = "Synthetic temporary password 2026"
CLIENT_ID = "fixture.mcp.client"


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
    return f"/api/v1/mcp-gateway/{context.coreId}/{context.homeId}"


def _external(token, client_id=CLIENT_ID):
    return {
        "Authorization": "Bearer " + token,
        "X-Larenor-MCP-Client": client_id,
    }


def _mcp(client, root, token, method, params=None, request_id=1, client_id=CLIENT_ID):
    return client.post(
        root + "/mcp",
        headers=_external(token, client_id),
        json={
            "jsonrpc": "2.0",
            "id": request_id,
            "method": method,
            "params": params or {},
        },
    )


def _grant(client, root, actor, clock, request_key, tools=None, client_id=CLIENT_ID):
    return client.post(
        root + "/grants",
        headers=auth(actor),
        json={
            "schemaVersion": 1,
            "requestKey": request_key,
            "clientId": client_id,
            "clientName": "Bounded fixture client",
            "tools": tools or ["home.note.create", "home.resource_count.read"],
            "expiresAt": clock.now + 600,
        },
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


def test_real_mcp_grant_preview_confirm_restart_and_revoke(tmp_path):
    clock = Clock()
    settings = _settings(tmp_path, clock)
    app = create_app(settings)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        root = _scope(app)
        created = _grant(client, root, admin, clock, "mcp-grant-request-0001")
        assert created.status_code == 201, created.text
        body = created.json()
        grant, token = body["grant"], body["accessToken"]
        assert len(token) == 43 and token not in json.dumps(grant)

        duplicate = _grant(client, root, admin, clock, "mcp-grant-request-0001")
        assert duplicate.status_code == 409
        assert duplicate.json()["error"]["code"] == "mcp_grant_token_already_issued"
        listing = client.get(root + "/grants", headers=auth(admin))
        assert listing.status_code == 200 and token not in listing.text

        initialized = _mcp(
            client,
            root,
            token,
            "initialize",
            {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "fixture"},
            },
        )
        assert initialized.status_code == 200
        assert initialized.json()["result"]["protocolVersion"] == "2025-06-18"
        tools = _mcp(client, root, token, "tools/list", request_id=2).json()
        assert [item["name"] for item in tools["result"]["tools"]] == grant["tools"]

        counted = _mcp(
            client,
            root,
            token,
            "tools/call",
            {"name": "home.resource_count.read", "arguments": {}},
            3,
        )
        assert counted.status_code == 200 and len(counted.content) < 4096
        facts = counted.json()["result"]["structuredContent"]
        assert facts["coreId"] == app.state.core.context.coreId
        assert facts["homeId"] == app.state.core.context.homeId

        preview = _mcp(
            client,
            root,
            token,
            "tools/call",
            {
                "name": "home.note.create",
                "arguments": {
                    "phase": "preview",
                    "requestKey": "mcp-note-request-0001",
                    "title": "Bounded metadata note",
                },
            },
            4,
        )
        assert preview.status_code == 200
        previewed = preview.json()["result"]["structuredContent"]
        assert previewed["deviceWrites"] == 0 and previewed["confirmationRequired"] is True
        confirm_params = {
            "name": "home.note.create",
            "arguments": {
                "phase": "confirm",
                "previewId": previewed["previewId"],
                "expectedRevision": previewed["previewRevision"],
            },
        }
        first = _mcp(client, root, token, "tools/call", confirm_params, 5)
        replay = _mcp(client, root, token, "tools/call", confirm_params, 6)
        assert first.status_code == replay.status_code == 200
        assert (
            first.json()["result"]["structuredContent"]
            == replay.json()["result"]["structuredContent"]
        )
        assert first.json()["result"]["structuredContent"]["deviceWrites"] == 0
        assert _mcp(client, root, token, "ping", client_id="wrong.client").status_code == 401

    with TestClient(create_app(settings)) as restarted:
        ping = _mcp(restarted, root, token, "ping")
        assert ping.status_code == 200 and ping.json()["result"] == {}
        revoked = restarted.post(
            f"{root}/grants/{grant['id']}/revoke",
            headers=auth(admin),
            json={"schemaVersion": 1, "expectedRevision": grant["revision"]},
        )
        assert revoked.status_code == 200
        assert revoked.json()["grant"]["state"] == "revoked"
        assert _mcp(restarted, root, token, "ping").status_code == 401


def test_mcp_authority_tracks_expiry_and_current_admin_session(tmp_path):
    clock = Clock()
    settings = _settings(tmp_path, clock)
    app = create_app(settings)
    with TestClient(app) as client:
        owner = ready((app, client, settings, clock))
        root = _scope(app)
        delegated_user, delegated = _create_admin(client, owner, "mcpdelegate")
        issued = _grant(client, root, delegated, clock, "mcp-authority-request-1")
        assert issued.status_code == 201
        token = issued.json()["accessToken"]
        assert _mcp(client, root, token, "ping").status_code == 200

        changed = client.patch(
            f"/api/v1/admin/users/{delegated_user['id']}",
            headers=auth(owner),
            json={"expectedRevision": 2, "role": "member"},
        )
        assert changed.status_code == 200
        assert _mcp(client, root, token, "ping").status_code == 401

        expiring = _grant(client, root, owner, clock, "mcp-expiry-request-0001")
        expiry_token = expiring.json()["accessToken"]
        clock.now += 601
        expired = _mcp(client, root, expiry_token, "ping")
        assert expired.status_code == 401
        assert expired.json()["error"]["code"] == "mcp_authority_inactive"


def test_mcp_storage_tamper_fails_closed_on_restart(tmp_path):
    clock = Clock()
    settings = _settings(tmp_path, clock)
    app = create_app(settings)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        created = _grant(client, _scope(app), admin, clock, "mcp-tamper-request-001")
        assert created.status_code == 201
        with app.state.core.db.transaction() as connection:
            connection.execute("UPDATE mcp_gateway_grants SET client_name='tampered'")
    with pytest.raises(StartupError, match="mcp_gateway_storage_invalid"):
        create_app(settings)
