"""A single persistent media preparation, through authenticated HTTP only."""

from copy import deepcopy

from fastapi.testclient import TestClient
import pytest

from conftest import auth, login, ready
from test_admin import TEMPORARY, activate, create as create_user
from larenor_server.app import create_app


BASE = "/api/v1/admin/media/preparations"
ORDER = ["qbittorrent", "sonarr", "radarr", "jellyfin", "seerr", "music_assistant"]


def submission(client, pair, *, request_id="1" * 32, name="larenor"):
    headers = auth(pair)
    return {"requestId": request_id, "templateId": "media",
            "context": client.get("/api/v1/context", headers=headers).json(),
            "catalogDigest": client.get("/api/v1/admin/plugins/catalog", headers=headers).json()["catalogDigest"],
            "platform": "linux/amd64",
            "settings": {"instanceName": name, "dataRootId": "appdata",
                         "libraryRootId": "library", "musicRootId": None}}


def create_preparation(client, pair, **options):
    body = submission(client, pair, **options)
    response = client.post(BASE, headers=auth(pair), json=body)
    assert response.status_code == 201, response.text
    return body, response.json()["preparation"]


def test_one_preparation_has_six_components_and_stable_unique_child_operations(server, monkeypatch):
    app, client, _, _ = server
    pair = ready(server)

    def forbidden(*_args, **_kwargs):
        pytest.fail("Preparation attempted a host or Docker inspection")

    monkeypatch.setattr("larenor_server.plugins.host_preflight.HostInspector.inspect", forbidden)
    monkeypatch.setattr("larenor_server.plugins.docker_probe.DockerProbe.inspect", forbidden)
    body, record = create_preparation(client, pair)
    assert set(record) == {"id", "requestId", "revision", "state", "createdAt", "updatedAt", "catalogCurrent", "plan"}
    assert record["requestId"] == body["requestId"] and record["revision"] == 1
    assert record["state"] == "prepared" and record["catalogCurrent"] is True
    assert record["createdAt"] == record["updatedAt"] == "2026-09-05T12:00:00.000Z"
    plan = record["plan"]
    assert plan["preparationId"] == record["id"]
    assert plan["coreId"] == body["context"]["coreId"]
    assert plan["homeId"] == body["context"]["homeId"]
    assert plan["installAvailable"] is False and plan["bootstrapExposure"] == "unverified"
    assert [component["serviceId"] for component in plan["components"]] == ORDER
    assert plan["requestedResources"] == {"memoryMiB": 16384, "cpuMillis": 12000,
                                          "pidsLimit": 3072, "minimumDiskMiB": 49152}
    for component in plan["components"]:
        assert component["plan"]["installable"] is False
        assert len({step["stepId"] for step in component["steps"]}) == 5
    assert len({component["operationId"] for component in plan["components"]}) == 6
    assert len({component["installationId"] for component in plan["components"]}) == 6
    assert client.get(BASE + "/" + record["id"], headers=auth(pair)).json() == {"preparation": record}
    assert client.get(BASE, headers=auth(pair)).json() == {"preparations": [record], "nextBefore": None}
    with app.state.core.db.connection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM plugin_jobs").fetchone()[0] == 0


def test_retry_restart_and_cancellation_preserve_the_same_preparation(server):
    app, client, settings, _ = server
    pair = ready(server)
    body, record = create_preparation(client, pair)
    assert client.post(BASE, headers=auth(pair), json=body).json() == {"preparation": record}
    with TestClient(create_app(settings)) as reopened:
        assert reopened.get(BASE, headers=auth(pair)).json() == {"preparations": [record], "nextBefore": None}
        cancelled = reopened.post(BASE + "/" + record["id"] + "/cancel", headers=auth(pair),
                                  json={"expectedRevision": 1})
        assert cancelled.status_code == 200
        current = cancelled.json()["preparation"]
        assert current["state"] == "cancelled" and current["revision"] == 2
        assert current["plan"] == record["plan"]
        assert reopened.post(BASE, headers=auth(pair), json=body).json() == {"preparation": current}
        assert reopened.post(BASE + "/" + record["id"] + "/cancel", headers=auth(pair),
                             json={"expectedRevision": 1}).status_code == 409
        assert reopened.post(BASE + "/" + record["id"] + "/cancel", headers=auth(pair),
                             json={"expectedRevision": 2}).json() == {"preparation": current}


def test_reused_request_and_active_instance_conflicts_do_not_replace_saved_plan(server):
    _, client, _, _ = server
    pair = ready(server)
    body, record = create_preparation(client, pair)
    changed = deepcopy(body)
    changed["settings"]["instanceName"] = "changed"
    for candidate in (changed, body | {"requestId": "2" * 32}):
        response = client.post(BASE, headers=auth(pair), json=candidate)
        assert response.status_code == 409
        assert response.json()["error"]["code"] == "media_preparation_conflict"
    assert client.get(BASE + "/" + record["id"], headers=auth(pair)).json() == {"preparation": record}


def test_history_and_cancel_are_available_to_current_admins_after_creator_logout(server):
    _, client, _, _ = server
    pair = ready(server)
    _, record = create_preparation(client, pair)
    create_user(client, pair, "operator", "admin")
    other = activate(client, "operator")
    assert client.post("/api/v1/auth/logout", headers=auth(pair)).status_code == 204
    assert client.get(BASE + "/" + record["id"], headers=auth(other)).json() == {"preparation": record}
    assert client.post(BASE + "/" + record["id"] + "/cancel", headers=auth(other),
                       json={"expectedRevision": 1}).json()["preparation"]["state"] == "cancelled"
    assert client.get(BASE, headers=auth(pair)).status_code == 401


def test_anonymous_member_and_initial_password_sessions_cannot_manage_preparations(server):
    _, client, _, _ = server
    pair = ready(server)
    body, record = create_preparation(client, pair)
    create_user(client, pair, "viewer", "member")
    member = activate(client, "viewer")
    create_user(client, pair, "newadmin", "admin")
    initial = login(client, "newadmin", TEMPORARY).json()
    for headers, status in (({}, 401), (auth(member), 403), (auth(initial), 403)):
        for method, path, payload in (("GET", BASE, None), ("GET", BASE + "/" + record["id"], None),
                                      ("POST", BASE, body),
                                      ("POST", BASE + "/" + record["id"] + "/cancel", {"expectedRevision": 1})):
            response = client.request(method, path, headers=headers, json=payload)
            assert response.status_code == status


@pytest.mark.parametrize("change,code", [("catalogDigest", "media_catalog_changed"),
                                        ("coreId", "media_context_changed"), ("homeId", "media_context_changed")])
def test_creation_is_bound_to_reviewed_core_and_catalog(server, change, code):
    _, client, _, _ = server
    pair = ready(server)
    body = submission(client, pair)
    if change == "catalogDigest":
        body[change] = "0" * 64
    else:
        body["context"][change] = "0" * 32
    response = client.post(BASE, headers=auth(pair), json=body)
    assert response.status_code == 409 and response.json()["error"]["code"] == code
    assert client.get(BASE, headers=auth(pair)).json()["preparations"] == []


def test_cursor_pagination_and_openapi_use_the_real_protected_contract(server):
    _, client, _, _ = server
    pair = ready(server)
    records = [create_preparation(client, pair, request_id=str(i) * 32, name=f"home-{i}")[1]
               for i in range(1, 4)]
    first = client.get(BASE + "?limit=2", headers=auth(pair)).json()
    assert first["preparations"] == list(reversed(records[1:]))
    assert type(first["nextBefore"]) is int
    second = client.get(BASE + "?limit=2&before=" + str(first["nextBefore"]), headers=auth(pair)).json()
    assert second == {"preparations": records[:1], "nextBefore": None}
    schema = client.get("/api/v1/openapi.json", headers=auth(pair)).json()
    assert schema["paths"][BASE]["post"]["security"] == [{"DeviceAccessToken": []}]


@pytest.mark.parametrize("mutation", ["unknown", "image", "bad_settings", "boolean_schema", "boolean_port", "oversize_name"])
def test_untrusted_creation_fields_are_rejected_without_echo(server, mutation):
    _, client, _, _ = server
    pair = ready(server)
    body = submission(client, pair)
    if mutation in ("unknown", "image"):
        body[mutation] = "synthetic-private-payload"
    elif mutation == "bad_settings":
        body["settings"]["dataRootId"] = "../../synthetic-private-payload"
    elif mutation == "boolean_schema":
        body["context"]["schemaVersion"] = True
    elif mutation == "boolean_port":
        body["settings"]["webPort"] = True
    else:
        body["settings"]["instanceName"] = "x" * 21
    response = client.post(BASE, headers=auth(pair), json=body)
    assert response.status_code == 400 and response.json()["error"]["code"] == "invalid_request"
    assert "synthetic-private-payload" not in response.text
