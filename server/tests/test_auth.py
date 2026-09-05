from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import threading
import uuid

import pytest

from larenor_server.errors import ApiError

from conftest import auth, bootstrap_password, login, ready


def test_initial_login_forces_password_change_before_other_capabilities(server):
    app, client, settings, _ = server
    password = bootstrap_password(settings)
    response = login(client, "admin", password)
    assert response.status_code == 200
    pair = response.json()
    assert pair["user"]["role"] == "admin"
    assert pair["user"]["mustChangePassword"] is True
    assert len(pair["accessToken"]) == 43
    assert len(pair["refreshToken"]) == 64
    assert pair["expiresIn"] == 900
    assert client.get("/api/v1/auth/me", headers=auth(pair)).json() == {"user": pair["user"]}
    for method, path, body in (("GET", "/api/v1/vault", None),
                               ("GET", "/api/v1/openapi.json", None),
                               ("POST", "/api/v1/auth/refresh", {"refreshToken": pair["refreshToken"]})):
        denied = client.request(method, path, headers=auth(pair), json=body) if body else client.request(method, path, headers=auth(pair))
        assert denied.status_code == 403
        assert denied.json()["error"]["code"] == "password_change_required"
    assert client.post("/api/v1/auth/logout", headers=auth(pair)).status_code == 204
    assert client.get("/api/v1/auth/me", headers=auth(pair)).status_code == 401


def test_password_change_revokes_every_old_device_and_removes_bootstrap(server):
    app, client, settings, _ = server
    password = bootstrap_password(settings)
    first = login(client, "admin", password, "Tablet").json()
    second = login(client, "admin", password, "DeX").json()
    response = client.post("/api/v1/auth/password", headers=auth(first),
                           json={"currentPassword": password, "newPassword": "New synthetic password 2026"})
    assert response.status_code == 200
    pair = response.json()
    assert pair["user"]["mustChangePassword"] is False
    assert not settings.effective_bootstrap_file.exists()
    for old in (first, second):
        assert client.get("/api/v1/auth/me", headers=auth(old)).status_code == 401
        assert client.post("/api/v1/auth/refresh", json={"refreshToken": old["refreshToken"]}).status_code == 401
    assert login(client, "admin", password).status_code == 401
    assert client.get("/api/v1/auth/me", headers=auth(pair)).status_code == 200
    with app.state.core.db.connection() as connection:
        encoded = connection.execute("SELECT password_hash FROM users").fetchone()[0]
    assert encoded.startswith("$argon2id$v=19$m=65536,t=3,p=4$")
    assert password not in encoded


def test_refresh_rotates_and_old_token_replay_revokes_new_pair(server):
    _app, client, _, _ = server
    pair = ready(server)
    response = client.post("/api/v1/auth/refresh", json={"refreshToken": pair["refreshToken"]})
    assert response.status_code == 200
    rotated = response.json()
    assert rotated["accessToken"] != pair["accessToken"]
    assert rotated["refreshToken"] != pair["refreshToken"]
    assert client.get("/api/v1/auth/me", headers=auth(pair)).status_code == 401
    assert client.get("/api/v1/auth/me", headers=auth(rotated)).status_code == 200
    assert client.post("/api/v1/auth/refresh", json={"refreshToken": pair["refreshToken"]}).status_code == 401
    assert client.get("/api/v1/auth/me", headers=auth(rotated)).status_code == 401
    assert client.post("/api/v1/auth/refresh", json={"refreshToken": rotated["refreshToken"]}).status_code == 401


def test_simultaneous_refresh_does_not_create_two_live_descendants(server):
    _app, client, _, _ = server
    pair = ready(server)
    barrier = threading.Barrier(2)

    def refresh():
        barrier.wait(timeout=5)
        return client.post("/api/v1/auth/refresh", json={"refreshToken": pair["refreshToken"]})

    with ThreadPoolExecutor(max_workers=2) as executor:
        responses = list(executor.map(lambda _: refresh(), range(2)))
    assert sorted(response.status_code for response in responses) == [200, 401]
    descendant = next(response.json() for response in responses if response.status_code == 200)
    assert client.get("/api/v1/auth/me", headers=auth(descendant)).status_code == 401


def test_access_and_absolute_refresh_expiry_use_injected_clock(server):
    _app, client, settings, clock = server
    pair = ready(server)
    clock.now += settings.access_ttl_seconds
    assert client.get("/api/v1/auth/me", headers=auth(pair)).status_code == 401
    response = client.post("/api/v1/auth/refresh", json={"refreshToken": pair["refreshToken"]})
    assert response.status_code == 200
    renewed = response.json()
    clock.now += settings.refresh_ttl_seconds
    assert client.post("/api/v1/auth/refresh", json={"refreshToken": renewed["refreshToken"]}).status_code == 401


def test_logout_never_revokes_someone_elses_supplied_refresh_token(server):
    app, client, _, _ = server
    admin = ready(server)
    encoded = app.state.core.auth.hash_password("Another synthetic password")
    with app.state.core.db.transaction() as connection:
        connection.execute("INSERT INTO users(id,username,role,password_hash,must_change_password,created_at) VALUES(?,?,?,?,?,?)", (uuid.uuid4().hex, "member", "member", encoded, 0, 1))
    member = login(client, "member", "Another synthetic password").json()
    response = client.post("/api/v1/auth/logout", headers=auth(admin), json={"refreshToken": member["refreshToken"]})
    assert response.status_code == 204
    assert client.get("/api/v1/auth/me", headers=auth(member)).status_code == 200
    assert client.get("/api/v1/auth/me", headers=auth(admin)).status_code == 401


def test_password_hash_and_login_session_creation_are_guarded_against_concurrent_change(server, monkeypatch):
    app, client, settings, _ = server
    password = bootstrap_password(settings)
    service = app.state.core.auth
    original = service._verify
    replacement = service.hash_password("Racing synthetic password")

    def raced(encoded, supplied):
        result = original(encoded, supplied)
        with app.state.core.db.transaction() as connection:
            connection.execute("UPDATE users SET password_hash=?", (replacement,))
        return result

    monkeypatch.setattr(service, "_verify", raced)
    assert login(client, "admin", password).status_code == 401
    with app.state.core.db.connection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM session_families").fetchone()[0] == 0


def test_opaque_tokens_exist_only_as_sha256_digests_in_database(server):
    app, _client, settings, _ = server
    pair = ready(server)
    with app.state.core.db.connection() as connection:
        rows = connection.execute("SELECT access_hash,refresh_hash FROM session_tokens").fetchall()
    encoded = json.dumps([tuple(row) for row in rows])
    assert pair["accessToken"] not in encoded
    assert pair["refreshToken"] not in encoded
    assert hashlib.sha256(pair["accessToken"].encode()).hexdigest() in encoded


def test_password_work_has_a_bounded_concurrency_limit(server):
    app, client, settings, _ = server
    slots = app.state.core.auth._password_slots
    slots.acquire()
    slots.acquire()
    try:
        response = login(client, "admin", bootstrap_password(settings))
        assert response.status_code == 429
        assert response.json()["error"]["code"] == "rate_limited"
    finally:
        slots.release()
        slots.release()


def test_no_account_enumeration_error_and_persistent_rate_limit(server):
    app, client, _settings, clock = server
    first = login(client, "admin", "wrong-synthetic-password")
    unknown = login(client, "missing-user", "wrong-synthetic-password")
    assert first.status_code == unknown.status_code == 401
    assert first.json() == unknown.json()
    core = app.state.core
    for _ in range(3):
        core.auth.rate_limit([("test", "peer", 3)])
    with pytest.raises(ApiError, match="rate_limited"):
        core.auth.rate_limit([("test", "peer", 3)])
    # Re-instantiating the auth service does not reset the SQL counters.
    from larenor_server.auth import AuthService
    another = AuthService(core.db, core.settings, core.auth._key)
    with pytest.raises(ApiError, match="rate_limited"):
        another.rate_limit([("test", "peer", 3)])
    clock.now += 60
    another.rate_limit([("test", "peer", 3)])


def test_logout_between_auth_dependency_and_write_prevents_mutation(server):
    app, _client, _, _ = server
    pair = ready(server)
    core = app.state.core
    principal = core.auth.authenticate(pair["accessToken"])
    core.auth.logout(principal)
    from conftest import document
    with pytest.raises(ApiError, match="invalid_session"):
        core.vault.put(principal, 0, document())
    with core.db.connection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM vaults").fetchone()[0] == 0
