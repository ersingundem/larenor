"""F05 durable single-step workflows over selected Home Assistant switches.

The workflow owns orchestration only.  The existing Home Assistant adapter owns
the physical command intent, dispatch, readback, and command history.
"""
from importlib import import_module
import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError

from conftest import auth, ready
from larenor_server.app import create_app
from test_admin import activate, create as create_user
from test_home_assistant_adapter import bind, ha, setup


CONTRACT = Path(__file__).resolve().parents[2] / "contracts/home-workflows.v1.json"


def workflow_root(app):
    scope = app.state.core.context
    return f"/api/v1/home-workflows/{scope.coreId}/{scope.homeId}"


def create_body(record, binding, *, request_id="a" * 32, **changes):
    value = {
        "schemaVersion": 1,
        "requestId": request_id,
        "title": "Turn on the synthetic switch",
        "deadlineSeconds": 300,
        "target": {
            "kind": "home_assistant_switch",
            "resourceId": record["ref"]["id"],
            "action": "turn_on",
            "expectedBindingRevision": binding["revision"],
            "expectedResourceRevision": record["revision"],
            "expectedAclRevision": record["aclRevision"],
        },
    }
    value.update(changes)
    return value


def decision_body(workflow, decision, *, decision_id="b" * 32):
    return {
        "schemaVersion": 1,
        "decisionId": decision_id,
        "expectedRevision": workflow["revision"],
        "decision": decision,
    }


def resume_body(workflow, *, resume_id="c" * 32):
    return {
        "schemaVersion": 1,
        "resumeId": resume_id,
        "expectedRevision": workflow["revision"],
    }


def create_workflow(client, pair, root, body):
    response = client.post(root, headers=auth(pair), json=body)
    assert response.status_code == 201, response.text
    assert set(response.json()) == {"schemaVersion", "workflow"}
    return response.json()["workflow"]


def test_committed_v1_contract_is_closed_and_matches_test_builders():
    contract = json.loads(CONTRACT.read_text())
    assert contract["schemaVersion"] == 1
    assert contract["root"] == "/home-workflows/{coreId}/{homeId}"
    assert contract["createRequest"] == create_body(
        {"ref": {"id": "1" * 32}, "revision": 1, "aclRevision": 1},
        {"revision": 1},
    )
    assert contract["decisionRequest"] == decision_body(
        {"revision": 1}, "approve"
    )
    assert contract["resumeRequest"] == resume_body(
        {"revision": 2}
    )
    assert contract["limits"] == {
        "workflows": 256,
        "page": 50,
        "titleCharacters": 80,
        "deadlineSecondsMinimum": 1,
        "deadlineSecondsMaximum": 86400,
        "attempts": 3,
    }


def test_v1_models_are_strict_closed_and_bounded():
    models = import_module("larenor_server.home_workflows.models")
    valid = create_body(
        {"ref": {"id": "1" * 32}, "revision": 1, "aclRevision": 1},
        {"revision": 1},
    )
    request = models.CreateWorkflowRequest.model_validate(valid)
    assert request.schemaVersion == 1
    assert request.target.kind == "home_assistant_switch"

    invalid = (
        {**valid, "schemaVersion": True},
        {**valid, "title": "x" * 81},
        {**valid, "deadlineSeconds": 0},
        {**valid, "deadlineSeconds": 86401},
        {**valid, "extra": "forbidden"},
        {**valid, "target": {**valid["target"], "kind": "shell"}},
        {**valid, "target": {**valid["target"], "action": "toggle"}},
        {**valid, "target": {**valid["target"], "resourceId": "not-an-id"}},
    )
    for value in invalid:
        with pytest.raises(ValidationError):
            models.CreateWorkflowRequest.model_validate(value)

    workflow = {
        "id": "d" * 32,
        "revision": 1,
    }
    approve = models.WorkflowDecisionRequest.model_validate(
        decision_body(workflow, "approve")
    )
    assert approve.decision == "approve"
    for decision in ("retry", "force", "skip"):
        with pytest.raises(ValidationError):
            models.WorkflowDecisionRequest.model_validate(
                decision_body(workflow, decision)
            )


def test_create_is_idempotent_then_human_approval_dispatches_exactly_once(server, ha):
    app, client, admin, record, _service, base, _public, binding_body = setup(
        server, ha
    )
    _, binding = bind(client, admin, base, binding_body)
    root = workflow_root(app)
    body = create_body(record, binding)

    workflow = create_workflow(client, admin, root, body)
    assert workflow == {
        "schemaVersion": 1,
        "id": workflow["id"],
        "revision": 1,
        "requestId": body["requestId"],
        "scope": {
            "schemaVersion": 1,
            "coreId": record["ref"]["coreId"],
            "homeId": record["ref"]["homeId"],
        },
        "creatorId": admin["user"]["id"],
        "title": body["title"],
        "target": {
            "kind": "home_assistant_switch",
            "resource": record["ref"],
            "action": "turn_on",
            "bindingRevision": 1,
            "resourceRevision": 1,
            "aclRevision": 1,
        },
        "state": "waiting_decision",
        "decisionRequired": "approve_effect",
        "attempt": 1,
        "stepRequestId": None,
        "effectState": "not_started",
        "reconciliationResult": "none",
        "cancelRequested": False,
        "deadlineAt": workflow["deadlineAt"],
        "createdAt": workflow["createdAt"],
        "updatedAt": workflow["updatedAt"],
    }
    assert workflow["id"] != body["requestId"]
    assert workflow["createdAt"] == workflow["updatedAt"]
    assert workflow["deadlineAt"] > workflow["createdAt"]
    assert ha.command_calls == 0

    replay = client.post(root, headers=auth(admin), json=body)
    assert replay.status_code == 201
    assert replay.json()["workflow"] == workflow
    conflict = client.post(
        root,
        headers=auth(admin),
        json={**body, "title": "A conflicting workflow"},
    )
    assert conflict.status_code == 409
    assert conflict.json()["error"]["code"] == "home_workflow_conflict"

    endpoint = root + "/" + workflow["id"] + "/decisions"
    approved = client.post(
        endpoint,
        headers=auth(admin),
        json=decision_body(workflow, "approve"),
    )
    assert approved.status_code == 200, approved.text
    completed = approved.json()["workflow"]
    assert completed["revision"] == 2
    assert completed["state"] == "completed"
    assert completed["decisionRequired"] is None
    assert completed["effectState"] == "accepted"
    assert completed["reconciliationResult"] == "effect_applied"
    assert completed["stepRequestId"] is not None
    assert ha.command_calls == 1

    duplicate = client.post(
        endpoint,
        headers=auth(admin),
        json=decision_body(workflow, "approve"),
    )
    assert duplicate.status_code == 200
    assert duplicate.json() == approved.json()
    assert ha.command_calls == 1

    history = client.get(
        f"/api/v1/home-assistant/{record['ref']['coreId']}/"
        f"{record['ref']['homeId']}/resources/{record['ref']['id']}/history",
        headers=auth(admin),
    )
    assert history.status_code == 200
    attribution = history.json()["entries"][0]["attribution"]
    assert attribution == {
        "schemaVersion": 1,
        "correlationId": completed["stepRequestId"],
        "source": "core_workflow",
        "reason": "workflow_step_execution",
        "serviceId": binding["serviceId"],
        "serviceRevision": binding["serviceRevision"],
        "workflowId": workflow["id"],
        "workflowRevision": 1,
        "stepId": "effect",
    }


def test_interrupted_effect_survives_restart_and_resume_never_replays(server, ha):
    app, client, admin, record, _service, base, _public, binding_body = setup(
        server, ha
    )
    _, binding = bind(client, admin, base, binding_body)
    root = workflow_root(app)
    workflow = create_workflow(client, admin, root, create_body(record, binding))
    calls = []

    def interrupted(*args, **kwargs):
        calls.append(args)
        raise SystemExit("synthetic process loss after durable HA intent")

    app.state.core.home_assistant._commander = interrupted
    actor = app.state.core.auth.authenticate(admin["accessToken"])
    with pytest.raises(SystemExit, match="synthetic process loss"):
        app.state.core.home_workflows.decide(
            actor,
            record["ref"]["coreId"],
            record["ref"]["homeId"],
            workflow["id"],
            decision_body(workflow, "approve"),
        )
    assert len(calls) == 1

    restarted = create_app(server[2])
    with TestClient(restarted) as other:
        fetched = other.get(root + "/" + workflow["id"], headers=auth(admin))
        assert fetched.status_code == 200, fetched.text
        interrupted_workflow = fetched.json()["workflow"]
        assert interrupted_workflow["state"] == "reconciliation_required"
        assert interrupted_workflow["decisionRequired"] == "reconcile_effect"
        assert interrupted_workflow["effectState"] == "unknown"
        assert interrupted_workflow["stepRequestId"] is not None

        first = other.post(
            root + "/" + workflow["id"] + "/resume",
            headers=auth(admin),
            json=resume_body(interrupted_workflow),
        )
        assert first.status_code == 200, first.text
        assert first.json()["workflow"]["state"] == "reconciliation_required"
        second = other.post(
            root + "/" + workflow["id"] + "/resume",
            headers=auth(admin),
            json=resume_body(interrupted_workflow),
        )
        assert second.status_code == 200
        assert second.json() == first.json()
    assert len(calls) == 1


def test_timeout_cancel_and_human_reconciliation_never_blindly_retry(server, ha):
    app, client, admin, record, _service, base, _public, binding_body = setup(
        server, ha
    )
    _, binding = bind(client, admin, base, binding_body)
    root = workflow_root(app)

    expiring = create_workflow(
        client,
        admin,
        root,
        create_body(record, binding, request_id="1" * 32, deadlineSeconds=1),
    )
    server[3].now += 2
    expired = client.post(
        root + "/" + expiring["id"] + "/decisions",
        headers=auth(admin),
        json=decision_body(expiring, "approve", decision_id="2" * 32),
    )
    assert expired.status_code == 409
    assert expired.json()["error"]["code"] == "home_workflow_timed_out"
    assert client.get(
        root + "/" + expiring["id"], headers=auth(admin)
    ).json()["workflow"]["state"] == "timed_out"
    assert ha.command_calls == 0

    cancellable = create_workflow(
        client,
        admin,
        root,
        create_body(record, binding, request_id="3" * 32),
    )
    cancelled = client.post(
        root + "/" + cancellable["id"] + "/decisions",
        headers=auth(admin),
        json=decision_body(cancellable, "cancel", decision_id="4" * 32),
    )
    assert cancelled.status_code == 200
    assert cancelled.json()["workflow"]["state"] == "cancelled"
    assert ha.command_calls == 0

    uncertain = create_workflow(
        client,
        admin,
        root,
        create_body(record, binding, request_id="5" * 32),
    )
    app.state.core.home_assistant._commander = lambda *args, **kwargs: None
    result = client.post(
        root + "/" + uncertain["id"] + "/decisions",
        headers=auth(admin),
        json=decision_body(uncertain, "approve", decision_id="6" * 32),
    )
    assert result.status_code == 200, result.text
    needs_human = result.json()["workflow"]
    assert needs_human["state"] == "reconciliation_required"
    assert needs_human["effectState"] == "unknown"
    assert needs_human["decisionRequired"] == "reconcile_effect"
    assert ha.command_calls == 0  # direct test commander replaced the loopback fixture

    not_applied = client.post(
        root + "/" + uncertain["id"] + "/decisions",
        headers=auth(admin),
        json=decision_body(
            needs_human, "effect_not_applied", decision_id="7" * 32
        ),
    )
    assert not_applied.status_code == 200
    second_attempt = not_applied.json()["workflow"]
    assert second_attempt["state"] == "waiting_decision"
    assert second_attempt["decisionRequired"] == "approve_effect"
    assert second_attempt["attempt"] == 2
    assert second_attempt["stepRequestId"] is None

    # Reconciliation creates a new attempt, but it is never itself a retry.
    with app.state.core.db.connection() as connection:
        current_commands = connection.execute(
            "SELECT COUNT(*) FROM home_assistant_commands"
        ).fetchone()[0]
    assert current_commands == 1

    applied = client.post(
        root + "/" + uncertain["id"] + "/decisions",
        headers=auth(admin),
        json=decision_body(
            second_attempt, "effect_applied", decision_id="8" * 32
        ),
    )
    assert applied.status_code == 409
    assert applied.json()["error"]["code"] == "home_workflow_decision_invalid"


def test_current_write_authority_is_required_for_create_approval_and_resume(server, ha):
    app, client, admin, record, _service, base, _public, binding_body = setup(
        server, ha
    )
    _, binding = bind(client, admin, base, binding_body)
    root = workflow_root(app)
    create_user(client, admin)
    member = activate(client, "member")
    ref = record["ref"]
    grant = (
        f"/api/v1/admin/home-resources/{ref['coreId']}/{ref['homeId']}/"
        f"{ref['id']}/grants/{member['user']['id']}"
    )

    assert client.post(root, json=create_body(record, binding)).status_code == 401
    hidden = client.post(
        root, headers=auth(member), json=create_body(record, binding)
    )
    assert hidden.status_code == 404
    assert client.put(
        grant,
        headers=auth(admin),
        json={
            "expectedAclRevision": 1,
            "permissions": {"read": True, "write": False},
        },
    ).status_code == 200
    read_only_record = {**record, "aclRevision": 2}
    denied = client.post(
        root,
        headers=auth(member),
        json=create_body(read_only_record, binding),
    )
    assert denied.status_code == 403
    assert ha.command_calls == 0

    assert client.put(
        grant,
        headers=auth(admin),
        json={
            "expectedAclRevision": 2,
            "permissions": {"read": True, "write": True},
        },
    ).status_code == 200
    writable_record = {**record, "aclRevision": 3}
    workflow = create_workflow(
        client, member, root, create_body(writable_record, binding)
    )
    assert client.put(
        grant,
        headers=auth(admin),
        json={
            "expectedAclRevision": 3,
            "permissions": {"read": True, "write": False},
        },
    ).status_code == 200
    revoked = client.post(
        root + "/" + workflow["id"] + "/decisions",
        headers=auth(member),
        json=decision_body(workflow, "approve"),
    )
    assert revoked.status_code == 409
    assert revoked.json()["error"]["code"] == "home_workflow_authority_changed"
    assert ha.command_calls == 0

    assert client.post(
        "/api/v1/auth/logout",
        headers=auth(member),
        json={"refreshToken": member["refreshToken"]},
    ).status_code == 204
    assert client.get(
        root + "/" + workflow["id"], headers=auth(member)
    ).status_code == 401


def test_workflow_and_page_limits_are_enforced_without_dispatch(server, ha, monkeypatch):
    app, client, admin, record, _service, base, _public, binding_body = setup(
        server, ha
    )
    _, binding = bind(client, admin, base, binding_body)
    schema = import_module("larenor_server.home_workflows.schema")
    monkeypatch.setattr(schema, "MAX_WORKFLOWS", 2)
    root = workflow_root(app)
    for index in range(2):
        create_workflow(
            client,
            admin,
            root,
            create_body(record, binding, request_id=f"{index + 1:x}" * 32),
        )
    limited = client.post(
        root,
        headers=auth(admin),
        json=create_body(record, binding, request_id="f" * 32),
    )
    assert limited.status_code == 429
    assert limited.json()["error"]["code"] == "home_workflow_limit_reached"
    assert client.get(root + "?limit=51", headers=auth(admin)).status_code == 400
    page = client.get(root + "?limit=1", headers=auth(admin))
    assert page.status_code == 200
    assert len(page.json()["workflows"]) == 1
    assert page.json()["nextBefore"] is not None
    assert ha.command_calls == 0
