from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Event, Thread
from types import SimpleNamespace

import pytest

from conftest import auth, bootstrap_password, login, ready
from test_admin import activate, create as create_user
from test_services import BASE, SECRET, create
from larenor_server.errors import ApiError
from larenor_server.services.models import UpdateServiceRequest
from larenor_server.services.probe_runner import ServiceProbeRunner


def install(app, probe):
    runner = ServiceProbeRunner(app.state.core.services, probe=probe)
    app.state.core.service_probe = runner
    return runner


def target(record):
    return BASE + "/" + record["id"] + "/check"


def test_check_persists_revision_bound_observation_and_typed_contract(server):
    app, client, _, _ = server
    pair = ready(server)
    record = create(client, pair)
    calls = []
    def probe(connection):
        calls.append(connection)
        return SimpleNamespace(state="authenticated", version="2026.9.0")
    install(app, probe)
    response = client.post(target(record), headers=auth(pair), json={"expectedRevision": 1})
    assert response.status_code == 200, response.text
    result = response.json()["service"]
    assert result["revision"] == 1
    assert result["verification"] == {"state": "authenticated", "version": "2026.9.0",
                                      "checkedAt": "2026-09-05T12:00:00.000Z"}
    assert SECRET not in response.text
    assert len(calls) == 1 and calls[0].credentials == {"token": SECRET}
    assert client.get(BASE, headers=auth(pair)).json()["services"] == [result]
    schema = client.get("/api/v1/openapi.json", headers=auth(pair)).json()
    operation = schema["paths"][BASE + "/{service_id}/check"]["post"]
    assert operation["security"] == [{"DeviceAccessToken": []}]
    assert operation["responses"]["200"]["content"]["application/json"]["schema"]["$ref"].endswith("ServiceResponse")
    with app.state.core.db.connection() as connection:
        assert connection.execute("SELECT action,status FROM service_audit ORDER BY id DESC LIMIT 1").fetchone()[:] == ("check", "success")


def test_anonymous_initial_password_member_and_stale_revision_never_probe(server):
    app, client, settings, _ = server
    calls = []
    install(app, lambda connection: calls.append(connection))
    initial = login(client, "admin", bootstrap_password(settings)).json()
    url = BASE + "/" + "a" * 32 + "/check"
    for headers, status in [({}, 401), (auth(initial), 403)]:
        assert client.post(url, headers=headers, json={"expectedRevision": 1}).status_code == status
    pair = ready(server)
    record = create(client, pair)
    create_user(client, pair)
    member = activate(client, "member")
    assert client.post(target(record), headers=auth(member), json={"expectedRevision": 1}).status_code == 403
    assert client.post(target(record), headers=auth(pair), json={"expectedRevision": 2}).status_code == 409
    assert client.post(url, headers=auth(pair), json={"expectedRevision": 1}).status_code == 404
    assert calls == []


@pytest.mark.parametrize("body", [{}, {"expectedRevision": 0}, {"expectedRevision": True},
                                  {"expectedRevision": "1"}, {"expectedRevision": 2**63},
                                  {"expectedRevision": 1, "credentials": {"token": SECRET}}])
def test_invalid_check_request_does_not_open_outbound_connection(server, body):
    app, client, _, _ = server
    pair = ready(server)
    record = create(client, pair)
    calls = []
    install(app, lambda connection: calls.append(connection))
    response = client.post(target(record), headers=auth(pair), json=body)
    assert response.status_code == 400
    assert SECRET not in response.text
    assert calls == []


@pytest.mark.parametrize("change", ["edit", "forget", "logout", "demote"])
def test_change_during_probe_cannot_store_stale_or_unauthorized_observation(server, change):
    app, client, _, _ = server
    admin = ready(server)
    user = create_user(client, admin, "operator", "admin")
    pair = activate(client, "operator")
    record = create(client, admin)
    manager = app.state.core.services
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    administrator = app.state.core.auth.authenticate(admin["accessToken"])
    def probe(connection):
        if change == "edit":
            manager.update(administrator, record["id"], UpdateServiceRequest(
                expectedRevision=1, name="Updated", baseUrl=record["baseUrl"], credentials={}))
        elif change == "forget":
            manager.delete(administrator, record["id"], 1)
        elif change == "logout":
            app.state.core.auth.logout(actor)
        else:
            assert client.patch("/api/v1/admin/users/" + user["id"], headers=auth(admin),
                                json={"expectedRevision": 2, "role": "member"}).status_code == 200
        return SimpleNamespace(state="authenticated", version="2026.9")
    install(app, probe)
    response = client.post(target(record), headers=auth(pair), json={"expectedRevision": 1})
    assert response.status_code == {"edit": 409, "forget": 404, "logout": 401, "demote": 401}[change]
    saved = client.get(BASE, headers=auth(admin)).json()["services"]
    assert saved == [] if change == "forget" else saved[0]["verification"]["state"] == "never"


def test_duplicate_and_global_probe_limits_release_after_completion(server):
    app, client, _, _ = server
    pair = ready(server)
    records = [create(client, pair, name=f"Service {i}") for i in range(5)]
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    entered = [Event() for _ in records]
    release = Event()
    def probe(connection):
        entered[next(i for i, item in enumerate(records) if item["id"] == connection.id)].set()
        assert release.wait(5)
        return SimpleNamespace(state="reachable", version=None)
    runner = install(app, probe)
    with ThreadPoolExecutor(max_workers=4) as pool:
        futures = [pool.submit(runner.check, actor, item["id"], 1) for item in records[:4]]
        try:
            assert all(event.wait(5) for event in entered[:4])
            for item in (records[0], records[4]):
                with pytest.raises(ApiError) as error:
                    runner.check(actor, item["id"], 1)
                assert (error.value.status, error.value.code) == (429, "rate_limited")
            assert not entered[4].is_set()
        finally:
            release.set()
        assert all(future.result()["service"]["verification"]["state"] == "reachable" for future in futures)
    assert runner.check(actor, records[4]["id"], 1)["service"]["verification"]["state"] == "reachable"


def test_unexpected_probe_exception_is_redacted_and_does_not_leave_busy_slot(server):
    app, client, _, _ = server
    pair = ready(server)
    record = create(client, pair)
    calls = []
    def probe(connection):
        calls.append(connection)
        if len(calls) == 1:
            raise ValueError(SECRET)
        return SimpleNamespace(state="authenticated", version=SECRET)
    install(app, probe)
    first = client.post(target(record), headers=auth(pair), json={"expectedRevision": 1})
    assert first.status_code == 503 and SECRET not in first.text
    assert client.get(BASE, headers=auth(pair)).json()["services"][0]["verification"]["state"] == "never"
    second = client.post(target(record), headers=auth(pair), json={"expectedRevision": 1})
    assert second.status_code == 200 and SECRET not in second.text
    assert second.json()["service"]["verification"]["version"] is None


def test_process_start_initializes_probe_runner(server):
    app, _, _, _ = server
    assert isinstance(app.state.core.service_probe, ServiceProbeRunner)


@pytest.mark.parametrize("authorized", [True, False])
def test_real_loopback_probe_through_api_transport_and_encrypted_storage(server, authorized):
    """A local synthetic HA fixture exercises the complete production check path."""
    _, client, _, _ = server
    pair = ready(server)
    requests = []
    class Fixture(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_GET(self):
            requests.append((self.command, self.path, self.headers.get("Authorization")))
            body = b'{"version":"2026.9.1","components":["light","api"]}' if authorized else b'{"message":"Unauthorized"}'
            self.send_response(200 if authorized else 401)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    upstream = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    worker = Thread(target=upstream.serve_forever, daemon=True)
    worker.start()
    try:
        record = create(client, pair, baseUrl=f"http://127.0.0.1:{upstream.server_port}/home")
        checked = client.post(target(record), headers=auth(pair), json={"expectedRevision": 1})
        assert checked.status_code == 200, checked.text
        expected = "authenticated" if authorized else "unauthorized"
        assert checked.json()["service"]["verification"]["state"] == expected
        assert SECRET not in checked.text
        assert requests == [("GET", "/home/api/config", "Bearer " + SECRET)]
        assert client.get(BASE, headers=auth(pair)).json()["services"][0]["verification"]["state"] == expected
    finally:
        upstream.shutdown()
        upstream.server_close()
        worker.join(timeout=2)
