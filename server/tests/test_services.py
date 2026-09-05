from concurrent.futures import ThreadPoolExecutor
from threading import Barrier
import json

import pytest
from fastapi.testclient import TestClient

from conftest import auth, bootstrap_password, login, ready
from test_admin import activate, create as create_user
from larenor_server.app import create_app
from larenor_server.errors import ApiError, StartupError
from larenor_server.services.models import CreateServiceRequest, UpdateServiceRequest
from larenor_server.services import schema as service_schema


BASE = "/api/v1/admin/services"
SECRET = "Synthetic-service-secret-not-for-production"


def body(**changes):
    return {"name": "Living room", "kind": "home_assistant", "baseUrl": "https://fixture.invalid/ha",
            "credentials": {"token": SECRET}, **changes}


def create(client, pair, **changes):
    response = client.post(BASE, headers=auth(pair), json=body(**changes))
    assert response.status_code == 201, response.text
    return response.json()["service"]


def test_crud_is_redacted_encrypted_and_persists_across_restart(server):
    app, client, settings, _ = server
    pair = ready(server)
    record = create(client, pair, baseUrl="HTTPS://FIXTURE.invalid:443/ha/", name=" Living room ")
    assert record == {"id": record["id"], "name": "Living room", "kind": "home_assistant",
                      "baseUrl": "https://fixture.invalid/ha", "revision": 1, "credentialKeys": ["token"],
                      "verification": {"state": "never", "checkedAt": None, "version": None}}
    assert len(record["id"]) == 32
    assert client.get(BASE, headers=auth(pair)).json() == {"services": [record]}
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    private = app.state.core.services.connection(actor, record["id"], 1)
    assert private.credentials == {"token": SECRET}
    assert SECRET not in repr(private)
    with app.state.core.db.connection() as connection:
        sql = "\n".join(connection.iterdump())
    for hidden in (SECRET, "Living room", "fixture.invalid"):
        assert hidden not in sql
    schema = client.get("/api/v1/openapi.json", headers=auth(pair)).json()
    assert schema["components"]["schemas"]["CreateServiceRequest"]["properties"]["credentials"]["writeOnly"]
    assert SECRET not in json.dumps(schema)
    with TestClient(create_app(settings)) as restarted:
        assert restarted.get(BASE, headers=auth(pair)).json() == {"services": [record]}
    saved = client.patch(BASE + "/" + record["id"], headers=auth(pair), json={
        "expectedRevision": 1, "name": "Renamed", "baseUrl": record["baseUrl"]})
    assert saved.status_code == 200
    assert saved.json()["service"]["revision"] == 2
    assert saved.json()["service"]["credentialKeys"] == ["token"]
    assert client.delete(BASE + "/" + record["id"] + "?expectedRevision=1", headers=auth(pair)).status_code == 409
    assert client.delete(BASE + "/" + record["id"] + "?expectedRevision=2", headers=auth(pair)).status_code == 204
    assert client.get(BASE, headers=auth(pair)).json() == {"services": []}
    with app.state.core.db.connection() as connection:
        audit = connection.execute("SELECT action,status FROM service_audit ORDER BY id").fetchall()
    assert [tuple(row) for row in audit] == [("create", "success"), ("update", "success"),
                                            ("delete", "denied"), ("delete", "success")]


def test_all_routes_reject_anonymous_initial_password_and_member(server):
    _app, client, settings, _ = server
    initial = login(client, "admin", bootstrap_password(settings)).json()
    for method, suffix, payload in [("GET", "", None), ("POST", "", body()),
                                    ("PATCH", "/" + "a" * 32, {"expectedRevision": 1, "name": "Changed", "baseUrl": "https://fixture.invalid"}),
                                    ("DELETE", "/" + "a" * 32 + "?expectedRevision=1", None)]:
        response = client.request(method, BASE + suffix, headers=auth(initial), **({"json": payload} if payload else {}))
        assert response.status_code == 403
        assert response.json()["error"]["code"] == "password_change_required"
    admin = ready(server)
    record = create(client, admin)
    create_user(client, admin)
    member = activate(client, "member")
    for method, suffix, payload in [("GET", "", None), ("POST", "", body()),
                                     ("PATCH", "/" + record["id"], {"expectedRevision": 1, "name": "Changed", "baseUrl": record["baseUrl"]}),
                                     ("DELETE", "/" + record["id"] + "?expectedRevision=1", None)]:
        for headers, status in [({}, 401), (auth(member), 403)]:
            response = client.request(method, BASE + suffix, headers=headers,
                                      **({"json": payload} if payload else {}))
            assert response.status_code == status


@pytest.mark.parametrize("mutation", ["list", "create", "update", "delete", "connection", "verify"])
@pytest.mark.parametrize("revocation", ["demote", "revoke"])
def test_retained_principal_is_rechecked_for_reads_and_writes(server, mutation, revocation):
    app, client, _, _ = server
    admin = ready(server)
    user = create_user(client, admin, "delegate", "admin")
    delegated = activate(client, "delegate")
    actor = app.state.core.auth.authenticate(delegated["accessToken"])
    record = create(client, admin)
    if revocation == "demote":
        assert client.patch("/api/v1/admin/users/" + user["id"], headers=auth(admin),
                            json={"expectedRevision": 2, "role": "member"}).status_code == 200
    else:
        assert client.delete("/api/v1/admin/sessions/" + actor.family_id, headers=auth(admin)).status_code == 204
    manager = app.state.core.services
    actions = {
        "list": lambda: manager.list(actor),
        "create": lambda: manager.create(actor, CreateServiceRequest(**body())),
        "update": lambda: manager.update(actor, record["id"], UpdateServiceRequest(expectedRevision=1, name="Changed", baseUrl=record["baseUrl"])),
        "delete": lambda: manager.delete(actor, record["id"], 1),
        "connection": lambda: manager.connection(actor, record["id"], 1),
        "verify": lambda: manager.record_verification(actor, record["id"], 1, state="authenticated", version="2026.9"),
    }
    with pytest.raises(ApiError, match="invalid_session"):
        actions[mutation]()
    assert client.get(BASE, headers=auth(admin)).json()["services"] == [record]


def test_endpoint_change_requires_explicit_credentials_and_never_reuses_old_secret(server):
    app, client, _, _ = server
    pair = ready(server)
    record = create(client, pair)
    target = BASE + "/" + record["id"]
    update = {"expectedRevision": 1, "name": "Changed", "baseUrl": "http://different.invalid"}
    denied = client.patch(target, headers=auth(pair), json=update)
    assert denied.status_code == 400
    assert denied.json()["error"]["code"] == "service_credentials_required"
    saved = client.patch(target, headers=auth(pair), json={**update, "credentials": {}})
    assert saved.status_code == 200
    assert saved.json()["service"]["credentialKeys"] == []
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    assert app.state.core.services.connection(actor, record["id"], 2).credentials == {}
    assert client.patch(target, headers=auth(pair), json={**update, "credentials": {"token": "replacement"}}).status_code == 409


def test_optimistic_update_race_has_exactly_one_winner(server):
    app, client, _, _ = server
    pair = ready(server)
    record = create(client, pair)
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    barrier = Barrier(2)
    def change(name):
        barrier.wait()
        try:
            return app.state.core.services.update(actor, record["id"], UpdateServiceRequest(
                expectedRevision=1, name=name, baseUrl=record["baseUrl"]))
        except ApiError as error:
            return error.code
    with ThreadPoolExecutor(max_workers=2) as pool:
        outcomes = list(pool.map(change, ["First", "Second"]))
    assert sum(isinstance(value, dict) for value in outcomes) == 1
    assert "revision_conflict" in outcomes


def test_verification_is_revision_bound_and_reset_when_credentials_change(server):
    app, client, _, clock = server
    pair = ready(server)
    record = create(client, pair)
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    manager = app.state.core.services
    checked = manager.record_verification(actor, record["id"], 1, state="authenticated", version="2026.9")
    assert checked["service"]["revision"] == 1
    assert checked["service"]["verification"] == {"state": "authenticated", "checkedAt": "2026-09-05T12:00:00.000Z", "version": "2026.9"}
    saved = manager.update(actor, record["id"], UpdateServiceRequest(expectedRevision=1, name="Renamed", baseUrl=record["baseUrl"]))
    assert saved["service"]["verification"] == checked["service"]["verification"]
    with pytest.raises(ApiError, match="revision_conflict"):
        manager.record_verification(actor, record["id"], 1, state="unavailable")
    reset = manager.update(actor, record["id"], UpdateServiceRequest(expectedRevision=2, name="Renamed", baseUrl=record["baseUrl"], credentials={}))
    assert reset["service"]["verification"] == {"state": "never", "checkedAt": None, "version": None}
    assert manager.configured_connections()[0].credentials == {}


@pytest.mark.parametrize("url", ["ftp://fixture.invalid", "https://user:pass@fixture.invalid", "https://fixture.invalid?q=x",
                                "https://fixture.invalid#x", "https://fixture.invalid\\other", "https://fixture.invalid/\nother",
                                "https://fixture.invalid/%2e%2e/private", "https://fixture.invalid/%5cprivate", "https://fixture.invalid/%0d",
                                "https://fixture.invalid:99999", "https:///missing", "https://fixture.invalid/../private"])
def test_ambiguous_or_unsafe_endpoints_are_rejected(server, url):
    _, client, _, _ = server
    pair = ready(server)
    response = client.post(BASE, headers=auth(pair), json=body(baseUrl=url))
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "invalid_request"
    assert SECRET not in response.text


@pytest.mark.parametrize("changes", [{"name": " "}, {"name": "a" * 81}, {"name": "bad\u0000"}, {"kind": "arbitrary"},
                                     {"credentials": {"unknown": "x"}}, {"credentials": {"token": 1}},
                                     {"credentials": {"token": ""}}, {"credentials": {"token": "x" * 2049}},
                                     {"credentials": {"token": "é" * 2048, "password": "a"}},
                                     {"credentials": {"token": "bad\r\nheader"}}, {"credentials": None}])
def test_input_bounds_are_strict_and_redacted(server, changes):
    _, client, _, _ = server
    pair = ready(server)
    response = client.post(BASE, headers=auth(pair), json=body(**changes))
    assert response.status_code in (400, 413)
    assert SECRET not in response.text


@pytest.mark.parametrize("tamper", ["ciphertext", "revision", "swap"])
def test_encrypted_records_fail_closed_after_tampering(server, tamper):
    app, client, settings, _ = server
    pair = ready(server)
    first = create(client, pair)
    second = create(client, pair, name="Another")
    with app.state.core.db.transaction() as connection:
        if tamper == "ciphertext":
            connection.execute("UPDATE service_connections SET ciphertext=? WHERE id=?", (b"broken", first["id"]))
        elif tamper == "revision":
            connection.execute("UPDATE service_connections SET revision=revision+1 WHERE id=?", (first["id"],))
        else:
            encrypted = connection.execute("SELECT nonce,ciphertext FROM service_connections WHERE id=?", (second["id"],)).fetchone()
            connection.execute("UPDATE service_connections SET nonce=?,ciphertext=? WHERE id=?", (*encrypted, first["id"]))
    response = client.get(BASE, headers=auth(pair))
    assert response.status_code == 503
    assert SECRET not in response.text
    with pytest.raises(StartupError, match="invalid_services_storage"):
        create_app(settings)


def test_capacity_limit_is_atomic_and_delete_only_forgets_local_record(server):
    app, client, _, _ = server
    pair = ready(server)
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    for index in range(127):
        app.state.core.services.create(actor, CreateServiceRequest(**body(name=f"Fixture {index}")))
    barrier = Barrier(2)
    def insert(name):
        barrier.wait()
        try:
            return app.state.core.services.create(actor, CreateServiceRequest(**body(name=name)))
        except ApiError as error:
            return error.code
    with ThreadPoolExecutor(max_workers=2) as pool:
        values = list(pool.map(insert, ["Last one", "Last two"]))
    assert sum(isinstance(value, dict) for value in values) == 1
    assert "service_limit_reached" in values
    assert len(app.state.core.services.configured_connections()) == 128


@pytest.mark.parametrize("change", ["unknown", "missing_marker", "missing_table"])
def test_unknown_or_missing_existing_services_schema_fails_closed(server, change):
    app, _, settings, _ = server
    with app.state.core.db.transaction() as connection:
        if change == "unknown":
            connection.execute("UPDATE metadata SET value='999' WHERE key='services_schema'")
        elif change == "missing_marker":
            connection.execute("DELETE FROM metadata WHERE key='services_schema'")
        else:
            connection.execute("DROP TABLE service_audit")
    with pytest.raises(StartupError, match="services_schema_unsupported"):
        create_app(settings)


def test_additive_migration_preserves_existing_account_and_vault(server):
    app, client, settings, _ = server
    pair = ready(server)
    with app.state.core.db.transaction() as connection:
        connection.execute("DROP TABLE service_connections")
        connection.execute("DROP TABLE service_audit")
        connection.execute("DELETE FROM metadata WHERE key='services_schema'")
    with TestClient(create_app(settings)) as restarted:
        assert restarted.get("/api/v1/auth/me", headers=auth(pair)).status_code == 200
        assert restarted.get(BASE, headers=auth(pair)).json() == {"services": []}


def test_interrupted_schema_migration_rolls_back_and_retries(server, monkeypatch):
    app, _, settings, _ = server
    ready(server)
    with app.state.core.db.transaction() as connection:
        connection.execute("DROP TABLE service_connections")
        connection.execute("DROP TABLE service_audit")
        connection.execute("DELETE FROM metadata WHERE key='services_schema'")
    original = service_schema.TABLES
    monkeypatch.setattr(service_schema, "TABLES", (original[0], "CREATE TABLE deliberately broken sql"))
    with pytest.raises(StartupError, match="storage_initialization_failed"):
        create_app(settings)
    with app.state.core.db.connection() as connection:
        assert connection.execute("SELECT value FROM metadata WHERE key='services_schema'").fetchone() is None
        assert connection.execute("SELECT name FROM sqlite_master WHERE name='service_connections'").fetchone() is None
    monkeypatch.setattr(service_schema, "TABLES", original)
    assert create_app(settings).state.core.services.configured_connections() == ()


@pytest.mark.parametrize("source,expected", [
    ("http://LOCALHOST:80/", "http://localhost"),
    ("https://[2001:0db8:0:0::1]:443/prefix/", "https://[2001:db8::1]/prefix"),
    ("http://192.168.1.10:8123/ha/", "http://192.168.1.10:8123/ha"),
    ("https://bücher.example/panel", "https://xn--bcher-kva.example/panel"),
    ("https://fixture.invalid/%68a", "https://fixture.invalid/ha"),
])
def test_endpoint_canonicalization_is_consistent(source, expected):
    assert CreateServiceRequest(**body(baseUrl=source)).baseUrl == expected
    assert CreateServiceRequest(**body(baseUrl=expected)).baseUrl == expected


def test_noop_keeps_revision_and_internal_credentials_are_immutable(server):
    app, client, _, _ = server
    pair = ready(server)
    record = create(client, pair, credentials={"password": SECRET, "username": "fixture-user"})
    assert record["credentialKeys"] == ["password", "username"]
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    private = app.state.core.services.connection(actor, record["id"])
    with pytest.raises(TypeError):
        private.credentials["password"] = "Changed"
    saved = client.patch(BASE + "/" + record["id"], headers=auth(pair), json={
        "expectedRevision": 1, "name": record["name"], "baseUrl": record["baseUrl"]})
    assert saved.json()["service"] == record


@pytest.mark.parametrize("payload", [{"expectedRevision": True}, {"expectedRevision": 0},
                                   {"credentials": None}, {"kind": "jellyfin"}, {"extra": "invalid"}])
def test_patch_rejects_invalid_revisions_null_secrets_and_kind_changes(server, payload):
    _, client, _, _ = server
    pair = ready(server)
    record = create(client, pair)
    response = client.patch(BASE + "/" + record["id"], headers=auth(pair), json={
        "expectedRevision": 1, "name": record["name"], "baseUrl": record["baseUrl"], **payload})
    assert response.status_code == 400
    assert client.get(BASE, headers=auth(pair)).json() == {"services": [record]}


def test_verification_never_echoes_a_credential_as_version(server):
    app, client, _, _ = server
    pair = ready(server)
    record = create(client, pair)
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    checked = app.state.core.services.record_verification(actor, record["id"], 1, state="reachable", version=SECRET)
    assert checked["service"]["verification"]["version"] is None
    assert SECRET not in json.dumps(checked)
    with pytest.raises(ApiError, match="invalid_request"):
        app.state.core.services.record_verification(actor, record["id"], 1, state="unexpected")
    with pytest.raises(ApiError, match="invalid_request"):
        app.state.core.services.record_verification(actor, record["id"], 1, state="authenticated", version="upstream\nsecret")


def test_unknown_service_and_invalid_identifiers_are_static(server):
    app, client, _, _ = server
    pair = ready(server)
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    assert client.delete(BASE + "/" + "a" * 32 + "?expectedRevision=1", headers=auth(pair)).status_code == 404
    assert client.delete(BASE + "/not-an-id?expectedRevision=1", headers=auth(pair)).status_code == 400
    with pytest.raises(ApiError, match="invalid_request"):
        app.state.core.services.connection(actor, "not-an-id")


def test_internal_helpers_enforce_ready_admin_without_http_dependencies(server):
    app, client, settings, _ = server
    initial = login(client, "admin", bootstrap_password(settings)).json()
    initial_actor = app.state.core.auth.authenticate(initial["accessToken"])
    with pytest.raises(ApiError, match="password_change_required"):
        app.state.core.services.create(initial_actor, CreateServiceRequest(**body()))
    admin = ready(server)
    create_user(client, admin)
    member = activate(client, "member")
    member_actor = app.state.core.auth.authenticate(member["accessToken"])
    with pytest.raises(ApiError, match="forbidden"):
        app.state.core.services.list(member_actor)
