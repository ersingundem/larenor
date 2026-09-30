"""F04 acceptance at the production FastAPI -> HA worker boundary."""

from conftest import auth
from test_home_assistant_adapter import bind, ha, setup
from test_home_assistant_commands import command_body


def _root(app):
    scope = app.state.core.context
    return f"/api/v1/rule-arbitration/{scope.coreId}/{scope.homeId}"


def _rule(record, *, request_key="rule-request-key-0001", priority=50):
    return {
        "schemaVersion": 1,
        "requestKey": request_key,
        "deviceId": record["ref"]["id"],
        "expectedDeviceRevision": record["revision"],
        "action": "turn_on",
        "ruleId": "8" * 32,
        "expectedRuleRevision": 1,
        "priority": priority,
        "leaseSeconds": 300,
    }


def test_manual_worker_supersedes_rule_and_external_writes_stay_observed_only(
    server, ha
):
    app, client, admin, record, _service, base, public, binding_body = setup(
        server, ha
    )
    _, binding = bind(client, admin, base, binding_body)
    root = _root(app)

    rule_body = _rule(record)
    initial = client.post(root + "/rules", headers=auth(admin), json=rule_body)
    assert initial.status_code == 200, initial.text
    assert initial.json()["decision"]["state"] == "authorized"
    assert initial.json()["decision"]["shouldWrite"] is True

    manual_body = command_body(
        record, binding, admin, request_id="9" * 32, action="turn_off"
    )
    manual = client.post(public + "/commands", headers=auth(admin), json=manual_body)
    assert manual.status_code == 202, manual.text
    assert ha.command_calls == 1

    blocked = client.post(
        root + "/rules",
        headers=auth(admin),
        json=_rule(record, request_key="rule-request-key-0002", priority=100),
    )
    assert blocked.status_code == 200, blocked.text
    assert blocked.json()["decision"]["state"] == "suppressed"
    assert blocked.json()["decision"]["reason"] == "active_manual"
    assert blocked.json()["decision"]["shouldWrite"] is False
    assert ha.command_calls == 1

    clock = server[3]
    observed = client.post(
        root + "/external-observations",
        headers=auth(admin),
        json={
            "schemaVersion": 1,
            "observationId": "7" * 32,
            "deviceId": record["ref"]["id"],
            "providerRevision": 2,
            "action": "turn_on",
            "observedAt": float(clock.now),
            "origin": "home_assistant",
        },
    )
    assert observed.status_code == 200, observed.text
    assert observed.json()["observation"]["controlMode"] == "observed_only"
    assert observed.json()["observation"]["authoritative"] is False
    assert ha.command_calls == 1

    snapshot = client.get(root, headers=auth(admin))
    assert snapshot.status_code == 200, snapshot.text
    body = snapshot.json()
    assert body["externalWritesAreObservedOnly"] is True
    assert body["activeOwnership"][0]["source"] == "manual"
    assert body["externalObservations"][0]["id"] == "7" * 32


def test_rule_submission_is_idempotent_and_conflicts_fail_before_worker(server, ha):
    app, client, admin, record, _service, base, _public, binding_body = setup(
        server, ha
    )
    bind(client, admin, base, binding_body)
    root = _root(app)
    body = _rule(record)

    first = client.post(root + "/rules", headers=auth(admin), json=body)
    repeated = client.post(root + "/rules", headers=auth(admin), json=body)
    assert repeated.status_code == 200
    assert repeated.json() == first.json()

    conflict = client.post(
        root + "/rules",
        headers=auth(admin),
        json={**body, "action": "turn_off"},
    )
    assert conflict.status_code == 409
    assert conflict.json()["error"]["code"] == "idempotency_conflict"
    assert ha.command_calls == 0
