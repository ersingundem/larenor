"""F06 attribution for real component-egress policy and probe commands."""

import json
import secrets

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from fastapi.testclient import TestClient

from conftest import auth
from larenor_server.app import create_app
from larenor_server.errors import StartupError
from larenor_server.component_egress import storage
from test_admin import activate, create as create_user
from test_component_egress import grant_body, policy_url
from test_component_egress_safety import network, setup
from test_services import BASE, SECRET, create


def history_url(record):
    return policy_url(record) + "/history"


def test_policy_and_probe_events_have_one_closed_attribution_contract(
    server, monkeypatch
):
    _app, client, pair, record, _ = setup(server)
    network(monkeypatch)
    checked = client.post(
        BASE + "/" + record["id"] + "/check",
        headers=auth(pair),
        json={"expectedRevision": 1},
    )
    assert checked.status_code == 200, checked.text

    response = client.get(policy_url(record), headers=auth(pair))
    assert response.status_code == 200, response.text
    payload = response.json()
    assert payload["schemaVersion"] == 2
    events = payload["audit"]
    assert [
        (event["source"], event["reason"], event["command"], event["result"])
        for event in events
    ] == [
        ("core_api", "policy_replaced", "replace_egress_policy", "accepted"),
        ("core_api", "dispatch_authorized", "verify_service", "authorized"),
        ("core_api", "probe_completed", "verify_service", "verified"),
    ]
    assert all(
        event["actorId"] == pair["user"]["id"]
        and event["serviceId"] == record["id"]
        and event["serviceRevision"] == record["revision"]
        and len(event["correlationId"]) == 32
        for event in events
    )
    assert events[-2]["correlationId"] == events[-1]["correlationId"]
    assert events[0]["correlationId"] != events[-1]["correlationId"]
    assert SECRET not in response.text


def test_v1_events_migrate_to_unknown_without_inventing_command_or_result(server):
    app, client, pair, record, _ = setup(server)
    egress = app.state.core.component_egress
    with app.state.core.db.transaction() as connection:
        row = connection.execute(
            "SELECT nonce,ciphertext FROM component_egress_state WHERE singleton=1"
        ).fetchone()
        raw = json.loads(
            AESGCM(egress.key).decrypt(
                row["nonce"], row["ciphertext"], storage._aad(egress.scope)
            )
        )
        assert raw["schemaVersion"] == 2
        raw["schemaVersion"] = 1
        for event in raw["events"]:
            event.pop("serviceRevision")
            event.pop("command")
            event.pop("result")
        nonce = secrets.token_bytes(12)
        ciphertext = AESGCM(egress.key).encrypt(
            nonce,
            json.dumps(raw, separators=(",", ":")).encode(),
            storage._aad(egress.scope),
        )
        connection.execute(
            "UPDATE component_egress_state SET nonce=?,ciphertext=? WHERE singleton=1",
            (nonce, ciphertext),
        )
        connection.execute(
            "UPDATE metadata SET value='1' WHERE key='component_egress_schema'"
        )

    with TestClient(create_app(server[2])) as restarted:
        response = restarted.get(policy_url(record), headers=auth(pair))
        assert response.status_code == 200, response.text
        assert response.json()["schemaVersion"] == 2
        assert all(
            event["source"] == "unknown"
            and event["reason"] == "unknown"
            and event["command"] == "unknown"
            and event["result"] == "unknown"
            and event["serviceRevision"] is None
            for event in response.json()["audit"]
        )


def test_history_is_current_admin_service_scoped_and_tamper_closed(server):
    app, client, pair, first, _ = setup(server)
    second = create(
        client,
        pair,
        name="Second Home Assistant",
        baseUrl="https://second.example.test",
    )
    second_policy = grant_body(host="second.example.test", address="10.20.30.41")
    response = client.put(
        policy_url(second), headers=auth(pair), json=second_policy
    )
    assert response.status_code == 200, response.text

    first_response = client.get(history_url(first), headers=auth(pair))
    second_response = client.get(history_url(second), headers=auth(pair))
    assert first_response.status_code == 200, first_response.text
    assert second_response.status_code == 200, second_response.text
    assert first_response.json()["verified"] is True
    assert first_response.json()["service"] == {
        "id": first["id"],
        "revision": first["revision"],
    }
    assert "grants" not in first_response.text
    assert "10.20.30" not in first_response.text
    first_history = first_response.json()["entries"]
    second_history = second_response.json()["entries"]
    assert first_history and second_history
    assert {event["serviceId"] for event in first_history} == {first["id"]}
    assert {event["serviceId"] for event in second_history} == {second["id"]}
    assert {
        event["correlationId"] for event in first_history
    }.isdisjoint(event["correlationId"] for event in second_history)

    create_user(client, pair)
    member = activate(client, "member")
    assert client.get(history_url(first), headers=auth(member)).status_code == 403
    assert client.delete(
        BASE + "/" + first["id"] + "?expectedRevision=1", headers=auth(pair)
    ).status_code == 204
    assert client.get(history_url(first), headers=auth(pair)).status_code == 404

    with app.state.core.db.transaction() as connection:
        ciphertext = bytearray(
            connection.execute(
                "SELECT ciphertext FROM component_egress_state WHERE singleton=1"
            ).fetchone()[0]
        )
        ciphertext[-1] ^= 1
        connection.execute(
            "UPDATE component_egress_state SET ciphertext=? WHERE singleton=1",
            (bytes(ciphertext),),
        )
    assert client.get(history_url(second), headers=auth(pair)).status_code == 503
    try:
        create_app(server[2])
    except StartupError as error:
        assert str(error) == "component_egress_storage_invalid"
    else:
        raise AssertionError("tampered attribution storage started")
