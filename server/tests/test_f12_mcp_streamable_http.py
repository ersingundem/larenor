import pytest
from fastapi.testclient import TestClient

from larenor_server.app import create_app
from larenor_server.config import Settings

from conftest import Clock, auth, ready


CLIENT_ID = "fixture.standard.mcp"
PROTOCOL = "2025-06-18"


@pytest.fixture
def mcp(tmp_path):
    clock = Clock()
    settings = Settings(
        tmp_path / "data",
        tmp_path / "secrets/vault.key",
        clock=clock,
        login_ip_limit=100,
        login_account_limit=100,
        login_global_limit=100,
    )
    app = create_app(settings)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        context = app.state.core.context
        root = f"/api/v1/mcp-gateway/{context.coreId}/{context.homeId}"
        response = client.post(
            root + "/grants",
            headers=auth(admin),
            json={
                "schemaVersion": 1,
                "requestKey": "mcp-standard-transport-grant-0001",
                "clientId": CLIENT_ID,
                "clientName": "Standard transport fixture",
                "tools": ["home.resource_count.read"],
                "expiresAt": clock.now + 600,
            },
        )
        assert response.status_code == 201, response.text
        issued = response.json()
        yield client, root, issued["accessToken"], admin, issued["grant"]


def _headers(token, **extra):
    return {
        "Authorization": "Bearer " + token,
        "X-Larenor-MCP-Client": CLIENT_ID,
        "Accept": "application/json, text/event-stream",
        **extra,
    }


def _initialize(
    client,
    root,
    token,
    *,
    offered_protocol=PROTOCOL,
    meta=None,
    **headers,
):
    return client.post(
        root + "/mcp",
        headers=_headers(token, **headers),
        json={
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": offered_protocol,
                "capabilities": {},
                "clientInfo": {"name": "fixture", "version": "1"},
                "_meta": {} if meta is None else meta,
            },
        },
    )


def test_initialized_notification_requires_live_authority_and_returns_empty_202(mcp):
    client, root, token, admin, grant = mcp
    initialized = _initialize(client, root, token)
    assert initialized.status_code == 200

    notification = {
        "jsonrpc": "2.0",
        "method": "notifications/initialized",
    }
    missing = client.post(root + "/mcp", json=notification)
    assert missing.status_code == 401
    wrong = client.post(
        root + "/mcp",
        headers=_headers("A" * 43, **{"MCP-Protocol-Version": PROTOCOL}),
        json=notification,
    )
    assert wrong.status_code == 401, wrong.text

    accepted = client.post(
        root + "/mcp",
        headers=_headers(token, **{"MCP-Protocol-Version": PROTOCOL}),
        json=notification,
    )
    assert accepted.status_code == 202
    assert accepted.content == b""

    listed = client.post(
        root + "/mcp",
        headers=_headers(token, **{"MCP-Protocol-Version": PROTOCOL}),
        json={"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
    )
    assert listed.status_code == 200
    assert [tool["name"] for tool in listed.json()["result"]["tools"]] == [
        "home.resource_count.read"
    ]

    revoked = client.post(
        f"{root}/grants/{grant['id']}/revoke",
        headers=auth(admin),
        json={"schemaVersion": 1, "expectedRevision": grant["revision"]},
    )
    assert revoked.status_code == 200
    inactive = client.post(
        root + "/mcp",
        headers=_headers(token, **{"MCP-Protocol-Version": PROTOCOL}),
        json=notification,
    )
    assert inactive.status_code == 401
    assert inactive.json()["error"]["code"] == "mcp_authority_inactive"


def test_initialize_negotiates_newer_bounded_offer_and_standard_metadata(mcp):
    client, root, token, _admin, _grant = mcp
    initialized = _initialize(
        client,
        root,
        token,
        offered_protocol="2025-11-25",
        meta={"fixture": "official-sdk-shape"},
    )
    assert initialized.status_code == 200, initialized.text
    assert initialized.json()["result"]["protocolVersion"] == PROTOCOL

    impossible = _initialize(
        client,
        root,
        token,
        offered_protocol="9999-99-99",
    )
    assert impossible.status_code == 200
    assert impossible.json() == {
        "jsonrpc": "2.0",
        "id": 1,
        "error": {"code": -32602, "message": "Invalid params"},
    }


def test_origin_and_protocol_version_fail_at_transport_boundary(mcp):
    client, root, token, _admin, _grant = mcp
    rejected_origin = _initialize(
        client,
        root,
        token,
        Origin="https://attacker.invalid",
    )
    assert rejected_origin.status_code == 403
    assert rejected_origin.json()["error"]["code"] == "forbidden"

    unsupported = _initialize(
        client,
        root,
        token,
        **{"MCP-Protocol-Version": "2024-11-05"},
    )
    assert unsupported.status_code == 400
    body = unsupported.json()
    assert body == {
        "jsonrpc": "2.0",
        "id": None,
        "error": {"code": -32600, "message": "Invalid Request"},
    }


def test_json_rpc_method_and_parameter_errors_are_protocol_responses(mcp):
    client, root, token, _admin, _grant = mcp
    headers = _headers(token, **{"MCP-Protocol-Version": PROTOCOL})

    unknown = client.post(
        root + "/mcp",
        headers=headers,
        json={"jsonrpc": "2.0", "id": "unknown-1", "method": "resources/list", "params": {}},
    )
    assert unknown.status_code == 200
    assert unknown.json() == {
        "jsonrpc": "2.0",
        "id": "unknown-1",
        "error": {"code": -32601, "message": "Method not found"},
    }

    invalid_params = client.post(
        root + "/mcp",
        headers=headers,
        json={"jsonrpc": "2.0", "id": 3, "method": "ping", "params": {"extra": True}},
    )
    assert invalid_params.status_code == 200
    assert invalid_params.json() == {
        "jsonrpc": "2.0",
        "id": 3,
        "error": {"code": -32602, "message": "Invalid params"},
    }

    invalid_request = client.post(
        root + "/mcp",
        headers=headers,
        json={"jsonrpc": "2.0", "method": "ping", "params": {}},
    )
    assert invalid_request.status_code == 200
    assert invalid_request.json() == {
        "jsonrpc": "2.0",
        "id": None,
        "error": {"code": -32600, "message": "Invalid Request"},
    }


def test_malformed_json_uses_protocol_error_without_weakening_shared_bounds(mcp):
    client, root, token, _admin, _grant = mcp
    headers = _headers(
        token,
        **{"MCP-Protocol-Version": PROTOCOL, "Content-Type": "application/json"},
    )

    malformed = client.post(root + "/mcp", headers=headers, content=b'{"jsonrpc":')
    assert malformed.status_code == 400
    assert malformed.json() == {
        "jsonrpc": "2.0",
        "id": None,
        "error": {"code": -32700, "message": "Parse error"},
    }

    duplicate = client.post(
        root + "/mcp",
        headers=headers,
        content=b'{"jsonrpc":"2.0","jsonrpc":"2.0","id":1,"method":"ping"}',
    )
    assert duplicate.status_code == 400
    assert duplicate.json()["error"]["code"] == -32700

    oversized = client.post(root + "/mcp", headers=headers, content=b'"' + b"x" * 8192 + b'"')
    assert oversized.status_code == 413
    assert oversized.json()["error"]["code"] == "payload_too_large"
