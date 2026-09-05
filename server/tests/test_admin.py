from concurrent.futures import ThreadPoolExecutor
from threading import Barrier, Event
import json
import uuid

import pytest

from larenor_server.admin.models import CreateUserRequest, UpdateUserRequest
from larenor_server.errors import ApiError

from conftest import auth, bootstrap_password, document, login, ready


TEMPORARY = "Synthetic temporary password 2026"
PERMANENT = "Synthetic changed member password"


def create(client, admin, name="member", role="member"):
    response = client.post("/api/v1/admin/users", headers=auth(admin), json={
        "username": name, "role": role, "initialPassword": TEMPORARY})
    assert response.status_code == 201, response.text
    return response.json()["user"]


def activate(client, username):
    pair = login(client, username, TEMPORARY).json()
    response = client.post("/api/v1/auth/password", headers=auth(pair), json={
        "currentPassword": TEMPORARY, "newPassword": PERMANENT})
    assert response.status_code == 200, response.text
    return response.json()


def users(client, admin):
    response = client.get("/api/v1/admin/users", headers=auth(admin))
    assert response.status_code == 200
    return response.json()["users"]


def revision(client, admin, user_id):
    return next(user["revision"] for user in users(client, admin) if user["id"] == user_id)


def test_create_force_change_and_typed_openapi_never_return_password(server):
    app, client, _settings, _clock = server
    admin = ready(server)
    user = create(client, admin, "Member.ONE")
    assert user == {"id": user["id"], "username": "member.one", "role": "member",
                    "disabled": False, "mustChangePassword": True, "revision": 1,
                    "createdAt": "2026-09-05T12:00:00.000Z"}
    pair = login(client, "MEMBER.ONE", TEMPORARY).json()
    assert client.get("/api/v1/vault", headers=auth(pair)).json()["error"]["code"] == "password_change_required"
    assert client.get("/api/v1/admin/users", headers=auth(pair)).status_code == 403
    updated = activate(client, "member.one")
    assert client.get("/api/v1/vault", headers=auth(updated)).status_code == 200
    assert client.get("/api/v1/admin/users", headers=auth(updated)).status_code == 403
    schema = client.get("/api/v1/openapi.json", headers=auth(admin)).json()
    assert schema["components"]["schemas"]["CreateUserRequest"]["properties"]["initialPassword"]["writeOnly"]
    assert schema["paths"]["/api/v1/admin/users"]["post"]["responses"]["201"]["content"]["application/json"]["schema"]["$ref"].endswith("AdminUserResponse")
    assert schema["paths"]["/api/v1/admin/sessions"]["get"]["security"] == [{"DeviceAccessToken": []}]
    assert "password" not in json.dumps(users(client, admin)).lower().replace("mustchangepassword", "")
    with app.state.core.db.connection() as connection:
        encoded = connection.execute("SELECT password_hash FROM users WHERE id=?", (user["id"],)).fetchone()[0]
    assert encoded.startswith("$argon2id$")
    assert TEMPORARY not in encoded


def test_bootstrap_anonymous_and_member_cannot_access_any_admin_route(server):
    _app, client, settings, _clock = server
    initial = login(client, "admin", bootstrap_password(settings)).json()
    assert client.get("/api/v1/admin/audit", headers=auth(initial)).json()["error"]["code"] == "password_change_required"
    admin = ready(server)
    user = create(client, admin)
    member = activate(client, "member")
    paths = [("GET", "/users", None), ("POST", "/users", {"username": "other", "role": "admin", "initialPassword": TEMPORARY}),
             ("PATCH", f'/users/{user["id"]}', {"expectedRevision": 2, "role": "admin"}),
             ("POST", f'/users/{user["id"]}/password', {"expectedRevision": 2, "temporaryPassword": TEMPORARY}),
             ("GET", "/sessions", None), ("DELETE", f'/sessions/{uuid.uuid4().hex}', None), ("GET", "/audit", None)]
    for method, path, body in paths:
        for headers, status in [({}, 401), (auth(member), 403)]:
            response = client.request(method, "/api/v1/admin" + path, headers=headers, **({"json": body} if body else {}))
            assert response.status_code == status
    assert len(users(client, admin)) == 2
    assert len(client.get("/api/v1/admin/audit", headers=auth(admin)).json()["events"]) == 1


def test_case_insensitive_uniqueness_and_user_cap_are_atomic(server):
    app, client, _settings, clock = server
    admin = ready(server)
    user = create(client, admin, "Mixed.Case")
    duplicate = client.post("/api/v1/admin/users", headers=auth(admin), json={
        "username": "MIXED.case", "role": "member", "initialPassword": TEMPORARY})
    assert duplicate.status_code == 409
    assert duplicate.json()["error"]["code"] == "username_unavailable"
    with app.state.core.db.transaction() as connection:
        encoded = connection.execute("SELECT password_hash FROM users WHERE id=?", (user["id"],)).fetchone()[0]
        connection.executemany("INSERT INTO users(id,username,role,password_hash,must_change_password,created_at) VALUES(?,?,'member',?,1,?)",
                               [(uuid.uuid4().hex, f"fixture{i:03d}", encoded, clock()) for i in range(253)])
    actor = app.state.core.auth.authenticate(admin["accessToken"])
    barrier = Barrier(2)
    def one(name):
        barrier.wait()
        try:
            return app.state.core.admin.create_user(actor, CreateUserRequest(username=name, role="member", initialPassword=TEMPORARY))["user"]
        except ApiError as error:
            return error.code
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(one, ["lastone", "lasttwo"]))
    assert sum(isinstance(item, dict) for item in results) == 1
    assert "user_limit_reached" in results
    assert len(users(client, admin)) == 256


@pytest.mark.parametrize("change", [{"role": "member"}, {"disabled": True}])
def test_concurrent_last_admin_changes_keep_one_active_admin(server, change):
    app, client, _settings, _clock = server
    first = ready(server)
    create(client, first, "second", "admin")
    second = activate(client, "second")
    principals = [app.state.core.auth.authenticate(pair["accessToken"]) for pair in (first, second)]
    barrier = Barrier(2)
    def one(actor):
        barrier.wait()
        try:
            return app.state.core.admin.update_user(actor, actor.id, UpdateUserRequest(expectedRevision=2, **change))
        except ApiError as error:
            return error.code
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(one, principals))
    assert sum(isinstance(result, dict) for result in results) == 1
    assert "last_active_admin" in results
    with app.state.core.db.connection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM users WHERE role='admin' AND disabled=0").fetchone()[0] == 1
        assert {row[0] for row in connection.execute("SELECT status FROM admin_audit WHERE action='update'")} == {"success", "denied"}


def test_revision_conflict_noop_and_role_revokes_all_device_sessions(server):
    _app, client, _settings, _clock = server
    admin = ready(server)
    user = create(client, admin)
    first = activate(client, "member")
    second = login(client, "member", PERMANENT, "Other device").json()
    path = f'/api/v1/admin/users/{user["id"]}'
    conflict = client.patch(path, headers=auth(admin), json={"expectedRevision": 1, "role": "admin"})
    assert conflict.status_code == 409
    noop = client.patch(path, headers=auth(admin), json={"expectedRevision": 2, "disabled": False})
    assert noop.json()["user"]["revision"] == 2
    assert client.get("/api/v1/auth/me", headers=auth(first)).status_code == 200
    promote = client.patch(path, headers=auth(admin), json={"expectedRevision": 2, "role": "admin"})
    assert promote.json()["user"]["revision"] == 3
    for pair in (first, second):
        assert client.get("/api/v1/auth/me", headers=auth(pair)).status_code == 401
        assert client.post("/api/v1/auth/refresh", json={"refreshToken": pair["refreshToken"]}).status_code == 401
    fresh = login(client, "member", PERMANENT).json()
    assert fresh["user"]["role"] == "admin"
    assert client.get("/api/v1/admin/users", headers=auth(fresh)).status_code == 200


def test_disabled_user_cannot_login_refresh_or_reuse_retained_principal(server):
    app, client, _settings, _clock = server
    admin = ready(server)
    user = create(client, admin)
    member = activate(client, "member")
    principal = app.state.core.auth.authenticate(member["accessToken"])
    response = client.patch(f'/api/v1/admin/users/{user["id"]}', headers=auth(admin), json={"expectedRevision": 2, "disabled": True})
    assert response.status_code == 200
    assert login(client, "member", PERMANENT).json()["error"]["code"] == "invalid_credentials"
    assert client.get("/api/v1/auth/me", headers=auth(member)).status_code == 401
    with pytest.raises(ApiError, match="invalid_session"):
        app.state.core.vault.put(principal, 0, document())
    # Defense in depth: disabled check remains even if family revocation were absent.
    with app.state.core.db.transaction() as connection:
        connection.execute("UPDATE session_families SET revoked_at=NULL WHERE user_id=?", (user["id"],))
    assert client.get("/api/v1/auth/me", headers=auth(member)).status_code == 401
    assert client.post("/api/v1/auth/refresh", json={"refreshToken": member["refreshToken"]}).status_code == 401
    with pytest.raises(ApiError, match="invalid_session"):
        with app.state.core.db.transaction() as connection:
            app.state.core.auth.assert_current(connection, principal)
    enabled = client.patch(f'/api/v1/admin/users/{user["id"]}', headers=auth(admin), json={"expectedRevision": 3, "disabled": False})
    assert enabled.json()["user"]["revision"] == 4
    assert client.get("/api/v1/auth/me", headers=auth(member)).status_code == 401
    assert login(client, "member", PERMANENT).status_code == 200


@pytest.mark.parametrize("mutation", ["create", "patch", "reset", "revoke"])
def test_every_admin_mutation_rechecks_role_after_http_dependency(server, monkeypatch, mutation):
    app, client, _settings, _clock = server
    admin = ready(server)
    delegated = create(client, admin, "delegate", "admin")
    pair = activate(client, "delegate")
    target = create(client, admin, "target")
    target_pair = activate(client, "target")
    family = app.state.core.auth.authenticate(target_pair["accessToken"]).family_id
    service = app.state.core.admin
    names = {"create": "create_user", "patch": "update_user", "reset": "reset_password", "revoke": "revoke_session"}
    original = getattr(service, names[mutation])
    entered, release = Event(), Event()
    actor_id = delegated["id"]
    def delayed(actor, *args, **kwargs):
        if actor.id == actor_id:
            entered.set()
            assert release.wait(5)
        return original(actor, *args, **kwargs)
    monkeypatch.setattr(service, names[mutation], delayed)
    requests = {
        "create": ("POST", "/users", {"username": "forbidden-new", "role": "admin", "initialPassword": TEMPORARY}),
        "patch": ("PATCH", f'/users/{target["id"]}', {"expectedRevision": 2, "role": "admin"}),
        "reset": ("POST", f'/users/{target["id"]}/password', {"expectedRevision": 2, "temporaryPassword": "Another synthetic password"}),
        "revoke": ("DELETE", f"/sessions/{family}", None),
    }
    method, path, body = requests[mutation]
    with ThreadPoolExecutor(max_workers=1) as pool:
        pending = pool.submit(lambda: client.request(method, "/api/v1/admin" + path, headers=auth(pair), **({"json": body} if body else {})))
        assert entered.wait(5)
        try:
            changed = client.patch(f'/api/v1/admin/users/{delegated["id"]}', headers=auth(admin), json={"expectedRevision": 2, "role": "member"})
            assert changed.status_code == 200
        finally:
            release.set()
        denied = pending.result(timeout=5)
    assert denied.status_code == 401
    assert len(users(client, admin)) == 3
    assert client.get("/api/v1/auth/me", headers=auth(target_pair)).status_code == 200
    assert login(client, "target", PERMANENT).status_code == 200
    assert next(user for user in users(client, admin) if user["id"] == target["id"])["role"] == "member"


def test_password_reset_is_explicit_revokes_sessions_and_self_reset_rejected(server):
    app, client, _settings, _clock = server
    admin = ready(server)
    user = create(client, admin)
    first = activate(client, "member")
    second = login(client, "member", PERMANENT).json()
    app.state.core.vault.put(app.state.core.auth.authenticate(first["accessToken"]), 0, document())
    path = f'/api/v1/admin/users/{user["id"]}/password'
    reset_password = "Synthetic replacement temporary"
    response = client.post(path, headers=auth(admin), json={"expectedRevision": 2, "temporaryPassword": reset_password})
    assert response.status_code == 200
    assert response.json()["user"]["mustChangePassword"] is True
    assert response.json()["user"]["revision"] == 3
    assert reset_password not in response.text
    assert login(client, "member", PERMANENT).status_code == 401
    for pair in (first, second):
        assert client.get("/api/v1/auth/me", headers=auth(pair)).status_code == 401
    initial = login(client, "member", reset_password).json()
    assert client.get("/api/v1/vault", headers=auth(initial)).status_code == 403
    renewed = client.post("/api/v1/auth/password", headers=auth(initial), json={"currentPassword": reset_password, "newPassword": PERMANENT}).json()
    assert client.get("/api/v1/vault", headers=auth(renewed)).json()["document"] == document()
    own = client.post(f'/api/v1/admin/users/{admin["user"]["id"]}/password', headers=auth(admin), json={"expectedRevision": 2, "temporaryPassword": TEMPORARY})
    assert own.status_code == 403
    assert own.json()["error"]["code"] == "self_password_reset_forbidden"
    assert client.get("/api/v1/auth/me", headers=auth(admin)).status_code == 200


def test_sessions_paginate_ties_filter_and_revoke_only_selected_family(server):
    app, client, _settings, clock = server
    admin = ready(server)
    user = create(client, admin)
    member = activate(client, "member")
    other = login(client, "member", PERMANENT, "Second tablet").json()
    family = app.state.core.auth.authenticate(member["accessToken"]).family_id
    seen, cursor = [], None
    while True:
        response = client.get("/api/v1/admin/sessions", headers=auth(admin), params={"limit": 1, "userId": user["id"], **({"cursor": cursor} if cursor else {})})
        assert response.status_code == 200
        payload = response.json()
        seen.extend(payload["sessions"])
        cursor = payload["nextCursor"]
        if not cursor:
            break
    assert len(seen) == len({item["id"] for item in seen}) == 3  # Initial force-change session is retained revoked.
    assert {item["status"] for item in seen} == {"active", "revoked"}
    assert all(item["userId"] == user["id"] for item in seen)
    assert all(item["createdAt"].endswith("Z") for item in seen)
    other_family = app.state.core.auth.authenticate(admin["accessToken"]).family_id
    assert client.get("/api/v1/admin/sessions", headers=auth(admin), params={"userId": user["id"], "cursor": other_family}).status_code == 400
    assert client.delete(f"/api/v1/admin/sessions/{family}", headers=auth(admin)).status_code == 204
    assert client.get("/api/v1/auth/me", headers=auth(member)).status_code == 401
    assert client.get("/api/v1/auth/me", headers=auth(other)).status_code == 200
    # Revocation is idempotent and never refreshes its original timestamp.
    clock.now += 1
    assert client.delete(f"/api/v1/admin/sessions/{family}", headers=auth(admin)).status_code == 204
    with app.state.core.db.transaction() as connection:
        connection.execute("UPDATE session_families SET expires_at=? WHERE id=?", (clock() - 1, app.state.core.auth.authenticate(other["accessToken"]).family_id))
    statuses = client.get("/api/v1/admin/sessions", headers=auth(admin), params={"userId": user["id"]}).json()["sessions"]
    assert {item["status"] for item in statuses} == {"revoked", "expired"}
    own = client.delete(f"/api/v1/admin/sessions/{other_family}", headers=auth(admin))
    assert own.status_code == 204
    assert client.get("/api/v1/admin/users", headers=auth(admin)).status_code == 401


def test_audit_static_redacted_ordered_paginated_retained(server, monkeypatch):
    import larenor_server.admin.service as service_module
    app, client, _settings, _clock = server
    admin = ready(server)
    monkeypatch.setattr(service_module, "MAX_AUDIT_EVENTS", 3)
    user = create(client, admin, "sensitive-name")
    path = f'/api/v1/admin/users/{user["id"]}'
    for payload in [{"expectedRevision": 1, "disabled": True},
                    {"expectedRevision": 1, "role": "admin"},
                    {"expectedRevision": 2, "disabled": False}]:
        client.patch(path, headers=auth(admin), json=payload)
    page = client.get("/api/v1/admin/audit", headers=auth(admin), params={"limit": 2}).json()
    tail = client.get("/api/v1/admin/audit", headers=auth(admin), params={"limit": 2, "cursor": page["nextCursor"]}).json()
    events = page["events"] + tail["events"]
    assert len(events) == 3
    assert [int(item["id"]) for item in events] == sorted([int(item["id"]) for item in events], reverse=True)
    assert {item["status"] for item in events} == {"success", "denied"}
    assert tail["nextCursor"] is None
    assert all(set(item) == {"id", "event", "action", "object", "status", "timestamp", "actorId", "targetId"} for item in events)
    with app.state.core.db.connection() as connection:
        raw = json.dumps([dict(row) for row in connection.execute("SELECT * FROM admin_audit")])
    for secret in ["sensitive-name", TEMPORARY, admin["accessToken"], admin["refreshToken"], "http", "password_hash"]:
        assert secret not in raw


@pytest.mark.parametrize("path,body", [
    ("/users", {"username": "bad name", "role": "admin", "initialPassword": TEMPORARY}),
    ("/users", {"username": "valid", "role": "owner", "initialPassword": TEMPORARY}),
    ("/users", {"username": "valid", "role": "admin", "initialPassword": "short"}),
    ("/users", {"username": "valid", "role": "admin", "initialPassword": "unsafe\npassword"}),
    ("/users", {"username": "valid", "role": "admin", "initialPassword": TEMPORARY, "disabled": False}),
])
def test_create_rejects_invalid_inputs_without_hashing(server, monkeypatch, path, body):
    app, client, _settings, _clock = server
    admin = ready(server)
    def forbidden(*_args):
        pytest.fail("Invalid request reached password hashing")
    monkeypatch.setattr(app.state.core.auth, "hash_password", forbidden)
    response = client.post("/api/v1/admin" + path, headers=auth(admin), json=body)
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "invalid_request"
    assert TEMPORARY not in response.text


@pytest.mark.parametrize("body", [{"expectedRevision": 2}, {"role": "member"},
                                   {"expectedRevision": True, "disabled": True},
                                   {"expectedRevision": 2, "disabled": 1},
                                   {"expectedRevision": 2, "disabled": None, "role": "member"}])
def test_patch_schema_is_strict(server, body):
    _app, client, _settings, _clock = server
    admin = ready(server)
    response = client.patch(f'/api/v1/admin/users/{admin["user"]["id"]}', headers=auth(admin), json=body)
    assert response.status_code == 400
    assert len(users(client, admin)) == 1


@pytest.mark.parametrize("path", ["/sessions?limit=0", "/sessions?limit=101", "/sessions?cursor=not-an-id",
                                   "/sessions?userId=../admin", "/audit?limit=101", "/audit?cursor=-1",
                                   "/audit?cursor=9999999999999999999"])
def test_bounded_query_validation(server, path):
    _app, client, _settings, _clock = server
    admin = ready(server)
    response = client.get("/api/v1/admin" + path, headers=auth(admin))
    assert response.status_code == 400


def test_admin_write_rate_limit_is_shared_across_mutations(server):
    app, client, _settings, _clock = server
    admin = ready(server)
    actor = app.state.core.auth.authenticate(admin["accessToken"])
    for _ in range(20):
        app.state.core.admin._write_limit(actor)
    response = client.patch(f'/api/v1/admin/users/{actor.id}', headers=auth(admin), json={"expectedRevision": 2, "disabled": False})
    assert response.status_code == 429
    assert client.get("/api/v1/admin/audit", headers=auth(admin)).json()["events"] == []


def test_partial_admin_mutation_rolls_back_before_denied_audit(server, monkeypatch):
    app, client, _settings, _clock = server
    admin = ready(server)
    user = create(client, admin)
    member = activate(client, "member")
    original = app.state.core.admin._revoke_user
    def fail_after_revoke(connection, user_id):
        original(connection, user_id)
        raise ApiError("forbidden", 403)
    monkeypatch.setattr(app.state.core.admin, "_revoke_user", fail_after_revoke)
    result = client.patch(f'/api/v1/admin/users/{user["id"]}', headers=auth(admin), json={"expectedRevision": 2, "role": "admin"})
    assert result.status_code == 403
    current = next(row for row in users(client, admin) if row["id"] == user["id"])
    assert current["role"] == "member" and current["revision"] == 2
    assert client.get("/api/v1/auth/me", headers=auth(member)).status_code == 200
    event = client.get("/api/v1/admin/audit", headers=auth(admin)).json()["events"][0]
    assert event["action"] == "update" and event["status"] == "denied"


def test_audit_storage_failure_rolls_back_user_and_session_changes(server):
    app, client, _settings, _clock = server
    admin = ready(server)
    user = create(client, admin)
    member = activate(client, "member")
    with app.state.core.db.transaction() as connection:
        connection.execute("CREATE TRIGGER fail_audit BEFORE INSERT ON admin_audit BEGIN SELECT RAISE(ABORT, 'synthetic write failure'); END")
    result = client.patch(f'/api/v1/admin/users/{user["id"]}', headers=auth(admin), json={"expectedRevision": 2, "disabled": True})
    assert result.status_code == 503
    assert "synthetic" not in result.text
    current = next(row for row in users(client, admin) if row["id"] == user["id"])
    assert current["disabled"] is False and current["revision"] == 2
    assert client.get("/api/v1/auth/me", headers=auth(member)).status_code == 200


@pytest.mark.parametrize("read", ["users", "sessions", "audit"])
def test_cached_admin_principal_cannot_read_after_demotion(server, read):
    app, client, _settings, _clock = server
    admin = ready(server)
    user = create(client, admin, "former-admin", "admin")
    previous = activate(client, "former-admin")
    principal = app.state.core.auth.authenticate(previous["accessToken"])
    assert client.patch(f'/api/v1/admin/users/{user["id"]}', headers=auth(admin), json={"expectedRevision": 2, "role": "member"}).status_code == 200
    with pytest.raises(ApiError, match="invalid_session"):
        getattr(app.state.core.admin, read)(principal)


def test_session_page_is_capped_to_100_without_exposing_token_columns(server):
    app, client, _settings, clock = server
    admin = ready(server)
    user = create(client, admin)
    with app.state.core.db.transaction() as connection:
        connection.executemany("INSERT INTO session_families VALUES(?,?,?,?,?,NULL)",
                               [(uuid.uuid4().hex, user["id"], f"Tablet {index}", clock(), clock() + 100) for index in range(151)])
    first = client.get("/api/v1/admin/sessions", headers=auth(admin), params={"limit": 100, "userId": user["id"]}).json()
    second = client.get("/api/v1/admin/sessions", headers=auth(admin), params={"limit": 100, "userId": user["id"], "cursor": first["nextCursor"]}).json()
    assert len(first["sessions"]) == 100 and len(second["sessions"]) == 51
    assert second["nextCursor"] is None
    assert len({row["id"] for row in first["sessions"] + second["sessions"]}) == 151
    assert all(set(row) == {"id", "userId", "deviceName", "createdAt", "expiresAt", "revokedAt", "status"} for row in first["sessions"])
