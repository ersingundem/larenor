"""Same-device arbitration stays current through the actual provider boundary."""

import threading
from contextlib import ExitStack

import pytest
from fastapi.testclient import TestClient

from conftest import auth, ready
from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.errors import ApiError
from larenor_server.home_assistant.models import Projection
from larenor_server.rule_arbitration.models import (
    CompleteArbitratedIntent,
    SubmitManualIntent,
    SubmitRuleIntent,
)
from larenor_server.rule_arbitration import schema as arbitration_schema
from larenor_server.rule_arbitration.service import (
    RuleArbitrationService,
    _DeviceDispatchRegistry,
)
from test_home_assistant_adapter import bind, setup
from test_home_assistant_commands import command_body


pytest_plugins = ("test_home_assistant_adapter",)


def _configured(server, ha):
    app, client, admin, record, _service, base, _public, binding_body = setup(
        server, ha
    )
    _, binding = bind(client, admin, base, binding_body)
    rule = client.post(
        base + "/rules",
        headers=auth(admin),
        json={
            "schemaVersion": 1,
            "action": "turn_on",
            "expectedResourceRevision": record["revision"],
            "expectedAclRevision": record["aclRevision"],
            "expectedBindingRevision": binding["revision"],
            "expectedServiceRevision": binding["serviceRevision"],
        },
    )
    assert rule.status_code == 201, rule.text
    actor = app.state.core.auth.authenticate(admin["accessToken"])
    ref = record["ref"]
    return app, actor, record, binding, rule.json()["rule"], ref


def _run(target, output):
    try:
        output.append(target())
    except BaseException as error:  # The exact exception is asserted by each test.
        output.append(error)


def _execute_rule(app, actor, record, rule, ref, request_id):
    return app.state.core.home_assistant_rules.execute(
        actor,
        ref["coreId"],
        ref["homeId"],
        ref["id"],
        rule["id"],
        {
            "schemaVersion": 1,
            "requestId": request_id,
            "expectedRuleRevision": rule["revision"],
        },
    )


def test_held_rule_effect_orders_same_device_manual_after_provider_completion(
    server, ha
):
    app, actor, record, binding, rule, ref = _configured(server, ha)
    adapter = app.state.core.home_assistant
    entered = threading.Event()
    release = threading.Event()
    manual_entered = threading.Event()
    effects = []
    state = {"value": "off"}
    state_lock = threading.Lock()

    def commander(_service, _entity, action, *, guard):
        guard()
        if action == "turn_on":
            entered.set()
            assert release.wait(2)
        else:
            manual_entered.set()
        guard()
        with state_lock:
            state["value"] = "on" if action == "turn_on" else "off"
            effects.append(action)
        return True

    def reader(_service, _entity, *, guard):
        guard()
        with state_lock:
            return Projection(state=state["value"])

    adapter._commander = commander
    adapter._reader = reader
    rule_result = []
    manual_result = []
    first = threading.Thread(
        target=_run,
        args=(
            lambda: _execute_rule(app, actor, record, rule, ref, "a" * 32),
            rule_result,
        ),
        daemon=True,
    )
    second = threading.Thread(
        target=_run,
        args=(
            lambda: adapter.command(
                actor,
                ref["coreId"],
                ref["homeId"],
                ref["id"],
                command_body(
                    record,
                    binding,
                    {"user": {"id": actor.id}},
                    request_id="b" * 32,
                    action="turn_off",
                ),
            ),
            manual_result,
        ),
        daemon=True,
    )
    first.start()
    assert entered.wait(1)
    second.start()
    try:
        assert not manual_entered.wait(0.2)
    finally:
        release.set()
        first.join(2)
        second.join(2)
    assert not first.is_alive() and not second.is_alive()
    assert len(rule_result) == len(manual_result) == 1
    assert not isinstance(rule_result[0], BaseException)
    assert not isinstance(manual_result[0], BaseException)
    assert effects == ["turn_on", "turn_off"]


def test_exact_concurrent_replay_waits_before_decision_and_returns_one_receipt(
    server, ha
):
    app, actor, record, _binding, rule, ref = _configured(server, ha)
    adapter = app.state.core.home_assistant
    arbitration = app.state.core.rule_arbitration
    before_effect = threading.Event()
    release_first = threading.Event()
    provider_calls = []
    original = arbitration.run_authorized_effect
    boundary_lock = threading.Lock()
    first = {"waiting": False}

    def held_boundary(*args):
        with boundary_lock:
            wait = not first["waiting"]
            if wait:
                first["waiting"] = True
        if wait:
            before_effect.set()
            assert release_first.wait(2)
        return original(*args)

    def commander(_service, _entity, _action, *, guard):
        guard()
        provider_calls.append("write")
        return True

    adapter._commander = commander
    results = []
    arbitration.run_authorized_effect = held_boundary
    first_thread = threading.Thread(
        target=_run,
        args=(lambda: _execute_rule(app, actor, record, rule, ref, "d" * 32), results),
        daemon=True,
    )
    second_thread = threading.Thread(
        target=_run,
        args=(lambda: _execute_rule(app, actor, record, rule, ref, "d" * 32), results),
        daemon=True,
    )
    first_thread.start()
    assert before_effect.wait(1)
    second_thread.start()
    try:
        second_thread.join(0.2)
        assert second_thread.is_alive()
    finally:
        release_first.set()
        first_thread.join(2)
        second_thread.join(2)
        arbitration.run_authorized_effect = original
    assert not first_thread.is_alive() and not second_thread.is_alive()
    assert len(results) == 2
    assert all(not isinstance(result, BaseException) for result in results)
    assert results[0] == results[1]
    assert provider_calls == ["write"]


@pytest.mark.parametrize("replacement", ["manual", "higher_rule"])
def test_superseded_decision_is_rejected_before_effect_callback(server, replacement):
    app, _client, _settings, _clock = server
    admin = ready(server)
    actor = app.state.core.auth.authenticate(admin["accessToken"])
    scope = app.state.core.context
    service = app.state.core.rule_arbitration
    device_id = "1" * 32
    first = service.submit_rule(
        actor,
        scope.coreId,
        scope.homeId,
        SubmitRuleIntent(
            schemaVersion=1,
            requestKey="first-rule-request",
            deviceId=device_id,
            expectedDeviceRevision=1,
            action="turn_on",
            ruleId="2" * 32,
            expectedRuleRevision=1,
            priority=40,
            leaseSeconds=30,
        ),
    )["decision"]
    if replacement == "manual":
        service.submit_manual(
            actor,
            scope.coreId,
            scope.homeId,
            SubmitManualIntent(
                schemaVersion=1,
                requestKey="replacement-manual",
                deviceId=device_id,
                expectedDeviceRevision=1,
                action="turn_off",
                holdSeconds=30,
            ),
        )
    else:
        service.submit_rule(
            actor,
            scope.coreId,
            scope.homeId,
            SubmitRuleIntent(
                schemaVersion=1,
                requestKey="replacement-rule-1",
                deviceId=device_id,
                expectedDeviceRevision=1,
                action="turn_off",
                ruleId="3" * 32,
                expectedRuleRevision=1,
                priority=100,
                leaseSeconds=30,
            ),
        )
    effects = []
    with pytest.raises(ApiError, match="rule_action_suppressed"):
        service.run_authorized_effect(
            actor,
            scope.coreId,
            scope.homeId,
            first,
            lambda _guard: effects.append("provider_write"),
        )
    assert effects == []


def test_expired_decision_is_rejected_before_effect_and_stale_completion(server):
    app, _client, _settings, clock = server
    admin = ready(server)
    actor = app.state.core.auth.authenticate(admin["accessToken"])
    scope = app.state.core.context
    service = app.state.core.rule_arbitration
    decision = service.submit_rule(
        actor,
        scope.coreId,
        scope.homeId,
        SubmitRuleIntent(
            schemaVersion=1,
            requestKey="expiring-rule-0001",
            deviceId="4" * 32,
            expectedDeviceRevision=1,
            action="turn_on",
            ruleId="5" * 32,
            expectedRuleRevision=1,
            priority=50,
            leaseSeconds=1,
        ),
    )["decision"]
    clock.now += 1
    effects = []
    with pytest.raises(ApiError, match="rule_action_suppressed"):
        service.run_authorized_effect(
            actor,
            scope.coreId,
            scope.homeId,
            decision,
            lambda _guard: effects.append("provider_write"),
        )
    assert effects == []
    with pytest.raises(ApiError, match="rule_arbiter_result_stale"):
        service.complete(
            actor,
            scope.coreId,
            scope.homeId,
            decision["id"],
            CompleteArbitratedIntent(
                schemaVersion=1,
                effectToken=decision["effectToken"],
                outcome="unknown",
                readbackDeviceRevision=None,
            ),
        )


def test_expiry_after_durable_command_intent_blocks_provider_and_replay(server, ha):
    app, actor, record, _binding, rule, ref = _configured(server, ha)
    adapter = app.state.core.home_assistant
    clock = server[3]
    effects = []

    def commander(_service, _entity, _action, *, guard):
        clock.now += 30
        guard()
        effects.append("provider_write")
        return True

    adapter._commander = commander
    with pytest.raises(ApiError, match="rule_action_suppressed"):
        _execute_rule(app, actor, record, rule, ref, "c" * 32)
    assert effects == []
    receipt = adapter.command_result(
        actor,
        ref["coreId"],
        ref["homeId"],
        ref["id"],
        "c" * 32,
    )["receipt"]
    assert receipt["dispatchState"] == "unknown"
    assert receipt["providerAccepted"] is None
    with pytest.raises(ApiError, match="rule_action_suppressed"):
        _execute_rule(app, actor, record, rule, ref, "c" * 32)
    assert effects == []


def test_cancel_before_provider_is_durable_rejection_without_effect(server, ha):
    app, actor, record, _binding, rule, ref = _configured(server, ha)
    adapter = app.state.core.home_assistant
    effects = []

    def commander(_service, _entity, _action, *, guard):
        guard()
        effects.append("provider_write")
        return True

    adapter._commander = commander
    with pytest.raises(ApiError, match="request_timeout"):
        app.state.core.home_assistant_rules.execute(
            actor,
            ref["coreId"],
            ref["homeId"],
            ref["id"],
            rule["id"],
            {
                "schemaVersion": 1,
                "requestId": "e" * 32,
                "expectedRuleRevision": rule["revision"],
            },
            cancelled=lambda: True,
        )
    result = adapter.command_result(
        actor, ref["coreId"], ref["homeId"], ref["id"], "e" * 32
    )
    assert result["receipt"]["dispatchState"] == "rejected"
    assert result["receipt"]["providerAccepted"] is False
    assert effects == []
    snapshot = app.state.core.rule_arbitration.snapshot(
        actor, ref["coreId"], ref["homeId"]
    )
    assert snapshot["activeOwnership"] == []


def test_dispatch_lock_is_shared_by_same_database_but_not_other_device_or_core(
    server, tmp_path
):
    app, _client, settings, clock = server
    admin = ready(server)
    actor = app.state.core.auth.authenticate(admin["accessToken"])
    scope = app.state.core.context
    first_service = app.state.core.rule_arbitration
    second_service = RuleArbitrationService(
        app.state.core.db,
        app.state.core.auth,
        settings,
        settings.key_file.read_bytes(),
        scope,
    )
    first = first_service.submit_rule(
        actor,
        scope.coreId,
        scope.homeId,
        SubmitRuleIntent(
            schemaVersion=1,
            requestKey="shared-lock-rule-1",
            deviceId="6" * 32,
            expectedDeviceRevision=1,
            action="turn_on",
            ruleId="7" * 32,
            expectedRuleRevision=1,
            priority=50,
            leaseSeconds=30,
        ),
    )["decision"]
    entered = threading.Event()
    release = threading.Event()
    first_result = []

    def held_effect(_guard):
        entered.set()
        assert release.wait(2)
        return "sent"

    owner = threading.Thread(
        target=_run,
        args=(
            lambda: first_service.run_authorized_effect(
                actor,
                scope.coreId,
                scope.homeId,
                first,
                held_effect,
            ),
            first_result,
        ),
        daemon=True,
    )
    owner.start()
    assert entered.wait(1)
    same_done = threading.Event()
    same_result = []

    def replace_same():
        try:
            same_result.append(
                second_service.submit_manual(
                    actor,
                    scope.coreId,
                    scope.homeId,
                    SubmitManualIntent(
                        schemaVersion=1,
                        requestKey="shared-lock-manual",
                        deviceId=first["deviceId"],
                        expectedDeviceRevision=1,
                        action="turn_off",
                        holdSeconds=30,
                    ),
                )
            )
        finally:
            same_done.set()

    same_thread = threading.Thread(target=replace_same, daemon=True)
    same_thread.start()
    try:
        assert not same_done.wait(0.2)
        unrelated = second_service.submit_rule(
            actor,
            scope.coreId,
            scope.homeId,
            SubmitRuleIntent(
                schemaVersion=1,
                requestKey="unrelated-rule-01",
                deviceId="8" * 32,
                expectedDeviceRevision=1,
                action="turn_on",
                ruleId="9" * 32,
                expectedRuleRevision=1,
                priority=50,
                leaseSeconds=30,
            ),
        )["decision"]
        assert unrelated["state"] == "authorized"

        other_settings = Settings(
            tmp_path / "other-data",
            tmp_path / "other-secrets/vault.key",
            clock=clock,
            login_ip_limit=100,
            login_account_limit=100,
            login_global_limit=100,
        )
        other_app = create_app(other_settings)
        with TestClient(other_app) as other_client:
            other_admin = ready((other_app, other_client, other_settings, clock))
            other_actor = other_app.state.core.auth.authenticate(
                other_admin["accessToken"]
            )
            other_scope = other_app.state.core.context
            other = other_app.state.core.rule_arbitration.submit_rule(
                other_actor,
                other_scope.coreId,
                other_scope.homeId,
                SubmitRuleIntent(
                    schemaVersion=1,
                    requestKey="other-core-rule-01",
                    deviceId=first["deviceId"],
                    expectedDeviceRevision=1,
                    action="turn_on",
                    ruleId="a" * 32,
                    expectedRuleRevision=1,
                    priority=50,
                    leaseSeconds=30,
                ),
            )["decision"]
            assert other["state"] == "authorized"
    finally:
        release.set()
        owner.join(2)
        same_thread.join(2)
    assert first_result == ["sent"]
    assert same_done.is_set() and len(same_result) == 1


def test_dispatch_registry_rejects_new_device_at_capacity_without_evicting_holder():
    registry = _DeviceDispatchRegistry()
    first_device = "0" * 32
    waiter_entered = threading.Event()
    waiter_finished = threading.Event()

    def wait_for_first():
        with registry.hold(first_device):
            waiter_entered.set()
        waiter_finished.set()

    waiter = threading.Thread(target=wait_for_first, daemon=True)
    with ExitStack() as held:
        for value in range(arbitration_schema.MAX_DEVICES):
            held.enter_context(registry.hold(f"{value:032x}"))
        waiter.start()
        assert not waiter_entered.wait(0.2)
        with pytest.raises(ApiError, match="rule_arbiter_limit_reached"):
            with registry.hold(f"{arbitration_schema.MAX_DEVICES:032x}"):
                pytest.fail("capacity admission unexpectedly acquired a lock")
    waiter.join(2)
    assert waiter_entered.is_set() and waiter_finished.is_set()
