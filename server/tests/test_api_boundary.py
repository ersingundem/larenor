import asyncio
import uuid
from typing import Annotated

from fastapi import APIRouter, Depends
from fastapi.testclient import TestClient
import pytest

from larenor_server.app import create_app
from larenor_server.auth import Principal
from larenor_server.boundary import SafeBoundaryMiddleware
from larenor_server.dependencies import require_admin
from larenor_server.errors import ApiError

from conftest import auth, bootstrap_password, document, login, ready


def test_health_is_public_and_security_responses_are_not_cached(server):
    _app, client, _, _ = server
    response = client.get("/api/v1/health")
    assert response.json() == {"service": "larenor-server", "apiVersion": 1}
    assert response.headers["cache-control"] == "no-store"
    assert response.headers["x-content-type-options"] == "nosniff"
    assert client.get("/api/v1/auth/me").status_code == 401
    for path in ("/docs", "/redoc", "/openapi.json"):
        assert client.get(path).status_code == 404
    assert client.get("/api/v1/openapi.json").status_code == 401


def test_admin_openapi_has_typed_request_response_role_security_and_errors(server):
    _app, client, _, _ = server
    pair = ready(server)
    response = client.get("/api/v1/openapi.json", headers=auth(pair))
    assert response.status_code == 200
    schema = response.json()
    schemas = schema["components"]["schemas"]
    assert schemas["PublicUser"]["properties"]["role"]["enum"] == ["admin", "member"]
    assert "mustChangePassword" in schemas["PublicUser"]["required"]
    assert schemas["SessionPair"]["properties"]["user"]["$ref"].endswith("PublicUser")
    assert set(schemas["VaultResponse"]["required"]) == {"revision", "document"}
    for path in ("/api/v1/auth/login", "/api/v1/auth/password", "/api/v1/auth/refresh"):
        assert schema["paths"][path]["post"]["responses"]["200"]["content"]["application/json"]["schema"]["$ref"].endswith("SessionPair")
    assert schema["paths"]["/api/v1/vault"]["put"]["security"] == [{"DeviceAccessToken": []}]
    assert schema["paths"]["/api/v1/vault"]["put"]["responses"]["409"]["content"]["application/json"]["schema"]["$ref"].endswith("ErrorResponse")


def test_packaged_router_hook_reuses_admin_dependency_and_never_imports_uploads(server):
    app, _client, settings, _ = server
    pair = ready(server)
    router = APIRouter()

    @router.get("/packaged-feature")
    def feature(principal: Annotated[Principal, Depends(require_admin)]):
        return {"role": principal.role}

    extended = create_app(settings, routers=(router,))
    core = extended.state.core
    with core.db.transaction() as connection:
        connection.execute("INSERT INTO users(id,username,role,password_hash,must_change_password,created_at) VALUES(?,?,?,?,?,?)",
                           (uuid.uuid4().hex, "member", "member", core.auth.hash_password("Synthetic member password"), 0, 1))
    with TestClient(extended) as client:
        assert client.get("/api/v1/packaged-feature").status_code == 401
        assert client.get("/api/v1/packaged-feature", headers=auth(pair)).json() == {"role": "admin"}
        member = login(client, "member", "Synthetic member password").json()
        assert client.get("/api/v1/openapi.json", headers=auth(member)).status_code == 403
        assert client.get("/api/v1/packaged-feature", headers=auth(member)).status_code == 403


@pytest.mark.parametrize("payload", [
    '{"username":"admin","username":"other","password":"synthetic-private","deviceName":"test"}',
    '{"username":"admin","password":"synthetic-private","deviceName":NaN}',
    '{"username":"admin","password":"synthetic-private","deviceName":null}',
    '{"username":"admin","password":"synthetic-private","deviceName":"test","isAdmin":true}',
])
def test_duplicate_nonfinite_extra_or_wrong_typed_json_is_rejected_without_echo(server, payload):
    _app, client, _, _ = server
    response = client.post("/api/v1/auth/login", content=payload, headers={"Content-Type": "application/json"})
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "invalid_request"
    assert "synthetic-private" not in response.text


def test_request_byte_limit_applies_before_endpoint_or_hash_work(server, monkeypatch):
    app, client, _, _ = server
    calls = []
    monkeypatch.setattr(app.state.core.auth, "login", lambda *args: calls.append(args))
    response = client.post("/api/v1/auth/login", content=b"x" * 8193, headers={"Content-Type": "application/json"})
    assert response.status_code == 413
    assert calls == []
    response = client.put("/api/v1/vault", content=b"x" * (2 * 1024 * 1024 + 1), headers={"Content-Type": "application/json"})
    assert response.status_code == 413


def test_invalid_credentials_and_arbitrary_handler_errors_are_static_and_do_not_log(server, monkeypatch, caplog):
    app, client, settings, _ = server

    def broken(*_args):
        raise RuntimeError("synthetic-private-token /private/path SQL VALUES(password)")

    monkeypatch.setattr(app.state.core.auth, "login", broken)
    response = login(client, "admin", bootstrap_password(settings))
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "server_unavailable"
    assert "synthetic-private-token" not in response.text
    assert "synthetic-private-token" not in caplog.text


def test_bounds_cover_depth_key_count_and_per_string_utf8_size():
    too_deep = {}
    current = too_deep
    for _ in range(17):
        current["nested"] = {}
        current = current["nested"]
    for invalid in (too_deep, {str(index): 1 for index in range(10001)}, {"value": "ş" * 32769}):
        from larenor_server.vault import validate_json_bounds
        with pytest.raises(ApiError, match="invalid_request"):
            validate_json_bounds(invalid)


def test_streaming_size_limit_cannot_be_bypassed_by_missing_content_length():
    invoked = False
    outgoing = []
    chunks = iter([
        {"type": "http.request", "body": b"x" * 8000, "more_body": True},
        {"type": "http.request", "body": b"x" * 2000, "more_body": False},
    ])

    async def endpoint(*_args):
        nonlocal invoked
        invoked = True

    async def receive():
        return next(chunks)

    async def send(message):
        outgoing.append(message)

    asyncio.run(SafeBoundaryMiddleware(endpoint)(
        {"type": "http", "path": "/api/v1/auth/login", "method": "POST", "headers": [(b"content-type", b"application/json")]},
        receive, send,
    ))
    assert not invoked
    assert outgoing[0]["status"] == 413


def test_body_timeout_is_safe_and_does_not_dispatch_endpoint(monkeypatch):
    class Expired:
        async def __aenter__(self):
            raise TimeoutError("private-network-info")

        async def __aexit__(self, *_):
            return False

    monkeypatch.setattr(asyncio, "timeout", lambda _duration: Expired())
    outgoing = []

    async def endpoint(*_args):
        raise AssertionError("Endpoint must not run")

    async def receive():
        return {"type": "http.request", "body": b"", "more_body": False}

    async def send(message):
        outgoing.append(message)

    asyncio.run(SafeBoundaryMiddleware(endpoint)(
        {"type": "http", "path": "/api/v1/auth/login", "method": "POST", "headers": []}, receive, send,
    ))
    assert outgoing[0]["status"] == 408
    assert b"private-network-info" not in outgoing[1]["body"]
