"""F06 real persisted rule-origin attribution over the HA command path."""

import json

from fastapi.testclient import TestClient

from conftest import auth
from larenor_server.app import create_app
from larenor_server.errors import StartupError
from test_home_assistant_adapter import bind, ha, setup
from test_home_assistant_commands import command_body


def rules_url(public):
    return "/api/v1/admin" + public.removeprefix("/api/v1") + "/rules"


def create_body(record, binding, *, action="turn_on"):
    return {
        "schemaVersion": 1,
        "action": action,
        "expectedResourceRevision": record["revision"],
        "expectedAclRevision": record["aclRevision"],
        "expectedBindingRevision": binding["revision"],
        "expectedServiceRevision": binding["serviceRevision"],
    }


def test_rule_is_current_admin_created_encrypted_and_restart_readable(server, ha):
    app, client, admin, record, service, base, public, body = setup(server, ha)
    _, binding = bind(client, admin, base, body)
    created = client.post(
        rules_url(public),
        headers=auth(admin),
        json=create_body(record, binding),
    )
    assert created.status_code == 201, created.text
    rule = created.json()["rule"]
    assert rule == {
        "schemaVersion": 1,
        "id": rule["id"],
        "revision": 1,
        "ref": record["ref"],
        "action": "turn_on",
        "creatorId": admin["user"]["id"],
        "resourceRevision": record["revision"],
        "aclRevision": record["aclRevision"],
        "bindingId": binding["id"],
        "bindingRevision": binding["revision"],
        "serviceId": service["id"],
        "serviceRevision": service["revision"],
    }
    with app.state.core.db.connection() as connection:
        raw = "\n".join(connection.iterdump())
    assert "turn_on" not in raw
    assert admin["user"]["id"] not in raw

    with TestClient(create_app(server[2])) as restarted:
        response = restarted.get(
            rules_url(public) + "/" + rule["id"], headers=auth(admin)
        )
        assert response.status_code == 200, response.text
        assert response.json() == {"rule": rule}
    assert ha.command_calls == 0


def test_rule_execution_uses_stored_identity_and_one_correlated_result(server, ha):
    _app, client, admin, record, service, base, public, body = setup(server, ha)
    _, binding = bind(client, admin, base, body)
    rule = client.post(
        rules_url(public), headers=auth(admin), json=create_body(record, binding)
    ).json()["rule"]
    request_id = "7" * 32
    execute = client.post(
        rules_url(public) + "/" + rule["id"] + "/executions",
        headers=auth(admin),
        json={
            "schemaVersion": 1,
            "requestId": request_id,
            "expectedRuleRevision": rule["revision"],
        },
    )
    assert execute.status_code == 202, execute.text
    assert execute.json()["receipt"]["requestId"] == request_id
    assert execute.json()["receipt"]["actorId"] == admin["user"]["id"]
    assert ha.command_calls == 1

    history = client.get(public + "/history", headers=auth(admin)).json()
    entry = history["entries"][0]
    assert entry["attribution"] == {
        "schemaVersion": 1,
        "correlationId": request_id,
        "source": "core_rule",
        "reason": "rule_execution",
        "serviceId": service["id"],
        "serviceRevision": service["revision"],
        "ruleId": rule["id"],
        "ruleRevision": rule["revision"],
        "executionId": request_id,
    }
    repeated = client.post(
        rules_url(public) + "/" + rule["id"] + "/executions",
        headers=auth(admin),
        json={
            "schemaVersion": 1,
            "requestId": request_id,
            "expectedRuleRevision": rule["revision"],
        },
    )
    assert repeated.status_code == 202
    assert repeated.json() == execute.json()
    assert ha.command_calls == 1


def test_rule_origin_cannot_be_claimed_by_nearby_command_and_storage_fails_closed(
    server, ha
):
    app, client, admin, record, _service, base, public, body = setup(server, ha)
    _, binding = bind(client, admin, base, body)
    explicit = command_body(record, binding, admin, request_id="6" * 32)
    assert client.post(public + "/commands", headers=auth(admin), json=explicit).status_code == 202
    assert client.get(public + "/history", headers=auth(admin)).json()["entries"][0][
        "attribution"
    ]["source"] == "core_api"

    rule = client.post(
        rules_url(public), headers=auth(admin), json=create_body(record, binding)
    ).json()["rule"]
    calls = ha.command_calls
    missing = client.post(
        rules_url(public) + "/" + "f" * 32 + "/executions",
        headers=auth(admin),
        json={
            "schemaVersion": 1,
            "requestId": "5" * 32,
            "expectedRuleRevision": 1,
        },
    )
    assert missing.status_code == 404
    forged = client.post(
        rules_url(public) + "/" + rule["id"] + "/executions",
        headers=auth(admin),
        json={
            "schemaVersion": 1,
            "requestId": "4" * 32,
            "expectedRuleRevision": 1,
            "source": "core_rule",
            "reason": "rule_execution",
        },
    )
    assert forged.status_code == 400
    assert ha.command_calls == calls

    with app.state.core.db.transaction() as connection:
        cipher = bytearray(
            connection.execute(
                "SELECT ciphertext FROM automation_rule_records WHERE rule_id=?",
                (rule["id"],),
            ).fetchone()[0]
        )
        cipher[-1] ^= 1
        connection.execute(
            "UPDATE automation_rule_records SET ciphertext=? WHERE rule_id=?",
            (bytes(cipher), rule["id"]),
        )
    assert client.get(
        rules_url(public) + "/" + rule["id"], headers=auth(admin)
    ).status_code == 503
    try:
        create_app(server[2])
    except StartupError as error:
        assert str(error) == "automation_rule_storage_invalid"
    else:
        raise AssertionError("tampered rule storage started")

    # The explicit command remains explicitly attributed; adjacency to the
    # damaged rule record never rewrites its source or reason.
    with app.state.core.db.connection() as connection:
        row = connection.execute(
            "SELECT ciphertext FROM home_assistant_commands WHERE request_id=?",
            (explicit["requestId"],),
        ).fetchone()
    assert row is not None
    assert "core_rule" not in json.dumps(explicit)
