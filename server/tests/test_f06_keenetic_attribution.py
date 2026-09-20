import json

from fastapi.testclient import TestClient

from larenor_server.app import create_app
from larenor_server.keenetic_commands import journal as journal_module
from larenor_server.keenetic_commands.service import KeeneticCommandAuthority

from conftest import auth, ready
from test_admin import activate, create as create_user
from test_home_resource_registry import create as create_resource, paths
from test_keenetic_command_authority import Harness, request, state
from test_keenetic_command_http_journal import install_fixture_authority


def _command_fixture(server):
    app, client, _, _ = server
    pair = ready(server)
    _, admin_resources = paths(app)
    record = create_resource(
        client,
        pair,
        admin_resources,
        kind="resource",
        label="Keenetic Router",
    )
    context = app.state.core.context
    target = state().model_copy(
        update={
            "coreId": context.coreId,
            "homeId": context.homeId,
            "resourceId": record["ref"]["id"],
            "resourceRevision": record["revision"],
            "aclRevision": record["aclRevision"],
        }
    )
    harness = Harness(target)
    install_fixture_authority(app, harness)
    body = request(current=target).model_dump()
    with app.state.core.db.connection() as connection:
        body["expectedUserRevision"] = connection.execute(
            "SELECT revision FROM users WHERE username='admin'"
        ).fetchone()["revision"]
    root = (
        f"/api/v1/admin/homes/{context.coreId}/{context.homeId}/resources/"
        f"{record['ref']['id']}/keenetic/commands"
    )
    return app, client, pair, record, body, root, admin_resources


def test_attributed_history_closes_actor_service_command_and_result(server):
    app, client, pair, record, body, root, _ = _command_fixture(server)
    preview = client.post(root + "/preview", headers=auth(pair), json=body).json()[
        "preview"
    ]
    response = client.post(
        root + f"/{preview['id']}/confirm",
        headers=auth(pair),
        json={"token": preview["confirmToken"]},
    )
    assert response.status_code == 200

    history = client.get(root + "/history/attributed", headers=auth(pair))
    assert history.status_code == 200, history.text
    value = history.json()
    assert set(value) == {"schemaVersion", "ref", "events", "verified"}
    assert value["schemaVersion"] == 1 and value["verified"] is True
    assert value["ref"] == record["ref"]
    assert [event["status"] for event in value["events"]] == [
        "accepted",
        "executing",
        "succeeded",
    ]
    for sequence, event in enumerate(value["events"], 1):
        assert set(event) == {
            "schemaVersion",
            "sequence",
            "attribution",
            "requestId",
            "action",
            "status",
            "target",
            "code",
        }
        assert event["schemaVersion"] == 1 and event["sequence"] == sequence
        assert event["requestId"] == body["requestId"]
        assert event["action"] == body["action"]
        assert event["target"]["serviceId"] == body["target"]["serviceId"]
        assert event["target"]["serviceRevision"] == body["target"]["serviceRevision"]
        assert event["attribution"] == {
            "schemaVersion": 1,
            "correlationId": body["requestId"],
            "actorId": pair["user"]["id"],
            "source": "core_api",
            "reason": "explicit_admin_request",
            "serviceId": body["target"]["serviceId"],
            "serviceRevision": body["target"]["serviceRevision"],
        }
    assert body["reason"] not in history.text
    assert body["idempotencyKey"] not in history.text


def test_recovery_is_factual_and_legacy_attribution_stays_unknown(server):
    app, _, pair, _, body, root, _ = _command_fixture(server)
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    app.state.core.keenetic_commands.preview(actor, body)

    legacy = journal_module.attribution_for_event(
        {
            "request_id": body["requestId"],
            "actor_id": pair["user"]["id"],
        },
        {
            "requestId": body["requestId"],
            "target": body["target"],
            "status": "accepted",
            "action": body["action"],
            "code": "accepted",
        },
    )
    assert legacy == {
        "schemaVersion": 1,
        "correlationId": body["requestId"],
        "actorId": pair["user"]["id"],
        "source": "unknown",
        "reason": "unknown",
        "serviceId": body["target"]["serviceId"],
        "serviceRevision": body["target"]["serviceRevision"],
    }

    reopened_app = create_app(app.state.core.settings)
    with TestClient(reopened_app) as reopened:
        response = reopened.get(root + "/history/attributed", headers=auth(pair))
        assert response.status_code == 200, response.text
        events = response.json()["events"]
        assert events[-1]["status"] == "unknown"
        assert events[-1]["code"] == "keenetic_command_interrupted"
        assert events[-1]["attribution"]["source"] == "core_recovery"
        assert events[-1]["attribution"]["reason"] == "interrupted_after_restart"
        assert body["reason"] not in json.dumps(events)


def test_attributed_history_rechecks_session_role_home_and_resource(server):
    app, client, pair, record, body, root, admin_resources = _command_fixture(server)
    client.post(root + "/preview", headers=auth(pair), json=body)

    assert client.get(root + "/history/attributed").status_code == 401
    create_user(client, pair, "history-member")
    member = activate(client, "history-member")
    assert (
        client.get(root + "/history/attributed", headers=auth(member)).status_code
        == 403
    )
    other_home = root.replace(app.state.core.context.homeId, "f" * 32)
    other_resource = root.replace(record["ref"]["id"], "e" * 32)
    assert (
        client.get(other_home + "/history/attributed", headers=auth(pair)).status_code
        == 404
    )
    assert (
        client.get(
            other_resource + "/history/attributed", headers=auth(pair)
        ).status_code
        == 404
    )

    deleted = client.delete(
        f"{admin_resources}/{record['ref']['id']}"
        "?expectedRevision=1&expectedAclRevision=1",
        headers=auth(pair),
    )
    assert deleted.status_code == 204
    assert (
        client.get(root + "/history/attributed", headers=auth(pair)).status_code
        == 404
    )
