from dataclasses import dataclass

import pytest

from larenor_server.errors import ApiError
from larenor_server.keenetic_commands.models import CommandRequest, TargetState
from larenor_server.keenetic_commands.service import (
    KeeneticCommandAuthority,
    KeeneticEffectError,
)
from larenor_server.keenetic_commands import service as service_module


CORE = "1" * 32
HOME = "2" * 32
RESOURCE = "3" * 32
BINDING = "4" * 32
SERVICE = "5" * 32
USER = "6" * 32
REQUEST = "7" * 32
KEY = "A" * 43


@dataclass(frozen=True)
class Actor:
    id: str = USER
    revision: int = 9
    role: str = "admin"
    disabled: bool = False
    must_change_password: bool = False
    session_current: bool = True


def state(*, kind="guest_wifi", value="disabled", revision=11, target="Guest"):
    return TargetState(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        resourceId=RESOURCE,
        resourceRevision=3,
        aclRevision=4,
        bindingId=BINDING,
        bindingRevision=5,
        serviceId=SERVICE,
        serviceRevision=6,
        firmwareVersion="5.0.4",
        firmwareRevision=7,
        stateRevision=revision,
        targetKind=kind,
        targetId=target,
        value=value,
    )


def request(action="guest_wifi_enable", *, current=None, request_id=REQUEST, key=KEY):
    target = current or state()
    return CommandRequest(
        schemaVersion=1,
        action=action,
        target=target,
        expectedUserRevision=9,
        requestId=request_id,
        idempotencyKey=key,
        reason="Evening guest access",
    )


class Harness:
    def __init__(self, current=None):
        self.current = current or state()
        self.authorizations = []
        self.effects = []

    def authorize(self, actor, target, action):
        self.authorizations.append((actor.id, target.resourceId, action))

    def observe(self, target):
        return self.current

    def effect(self, command, guard):
        self.effects.append(command.action)
        guard()
        desired = {
            "guest_wifi_enable": "enabled",
            "guest_wifi_disable": "disabled",
            "client_internet_pause": "paused",
            "client_internet_resume": "allowed",
            "wan_reconnect": "online",
        }[command.action]
        self.current = self.current.model_copy(
            update={"value": desired, "stateRevision": self.current.stateRevision + 1}
        )


def authority(harness, **kwargs):
    effect = kwargs.pop("effect", harness.effect)
    return KeeneticCommandAuthority(
        authorize=harness.authorize,
        observe=harness.observe,
        effect=effect,
        **kwargs,
    )


@pytest.mark.parametrize(
    ("action", "kind", "value", "risk"),
    [
        ("guest_wifi_enable", "guest_wifi", "disabled", "low"),
        ("guest_wifi_disable", "guest_wifi", "enabled", "low"),
        ("client_internet_pause", "client", "allowed", "medium"),
        ("client_internet_resume", "client", "paused", "medium"),
        ("wan_reconnect", "wan", "online", "high"),
    ],
)
def test_packaged_allowlist_binds_action_target_state_and_risk(action, kind, value, risk):
    harness = Harness(state(kind=kind, value=value, target=f"{kind}-1"))
    preview = authority(harness).preview(Actor(), request(action, current=harness.current))
    assert preview["preview"]["risk"] == risk
    assert preview["preview"]["status"] == "accepted"
    assert preview["preview"]["target"] == harness.current.model_dump()
    assert harness.authorizations == [(USER, RESOURCE, "write")]


def test_member_or_read_only_resource_cannot_preview_an_action():
    harness = Harness()
    with pytest.raises(ApiError, match="forbidden"):
        authority(harness).preview(Actor(role="member"), request())

    def deny(*_):
        raise ApiError("forbidden", 403)

    with pytest.raises(ApiError, match="forbidden"):
        KeeneticCommandAuthority(authorize=deny, observe=harness.observe).preview(
            Actor(), request()
        )


def test_confirmation_is_one_use_and_duplicate_never_replays_effect():
    harness = Harness()
    command = authority(harness)
    preview = command.preview(Actor(), request())["preview"]
    receipt = command.confirm(Actor(), preview["id"], preview["confirmToken"])["receipt"]
    assert receipt["status"] == "succeeded"
    assert receipt["transitions"] == ["accepted", "executing", "succeeded"]
    assert harness.effects == ["guest_wifi_enable"]
    assert command.confirm(Actor(), preview["id"], preview["confirmToken"])["receipt"] == receipt
    assert harness.effects == ["guest_wifi_enable"]
    assert command.preview(Actor(), request())["receipt"] == receipt


def test_cancel_consumes_preview_without_effect_or_later_confirmation():
    harness = Harness()
    command = authority(harness)
    preview = command.preview(Actor(), request())["preview"]
    receipt = command.cancel(Actor(), preview["id"])["receipt"]
    assert receipt["status"] == "cancelled"
    assert receipt["transitions"] == ["accepted", "cancelled"]
    assert command.confirm(Actor(), preview["id"], preview["confirmToken"])["receipt"] == receipt
    assert harness.effects == []


def test_wan_reconnect_needs_a_distinct_second_confirmation():
    current = state(kind="wan", value="online", target="wan0")
    harness = Harness(current)
    command = authority(harness)
    preview = command.preview(Actor(), request("wan_reconnect", current=current))["preview"]
    challenge = command.confirm(Actor(), preview["id"], preview["confirmToken"])["confirmation"]
    assert challenge["risk"] == "high"
    assert challenge["token"] != preview["confirmToken"]
    assert harness.effects == []
    receipt = command.confirm(Actor(), preview["id"], challenge["token"])["receipt"]
    assert receipt["status"] == "succeeded"
    assert harness.effects == ["wan_reconnect"]


def test_expired_second_confirmation_releases_request_indexes():
    class Clock:
        value = 100.0

        def __call__(self):
            return self.value

    clock = Clock()
    current = state(kind="wan", value="online", target="wan0")
    harness = Harness(current)
    command = authority(harness, clock=clock)
    body = request("wan_reconnect", current=current)
    preview = command.preview(Actor(), body)["preview"]
    challenge = command.confirm(Actor(), preview["id"], preview["confirmToken"])[
        "confirmation"
    ]
    clock.value += 31

    with pytest.raises(ApiError, match="keenetic_preview_invalid"):
        command.confirm(Actor(), preview["id"], challenge["token"])

    replacement = command.preview(Actor(), body)["preview"]
    assert replacement["id"] != preview["id"]


def test_receipt_eviction_releases_idempotency_and_request_indexes(monkeypatch):
    monkeypatch.setattr(service_module, "MAX_RECEIPTS", 1)
    harness = Harness()
    command = authority(harness)
    first_body = request()
    first = command.preview(Actor(), first_body)["preview"]
    command.confirm(Actor(), first["id"], first["confirmToken"])

    second_body = request(
        "guest_wifi_disable",
        current=harness.current,
        request_id="8" * 32,
        key="B" * 43,
    )
    second = command.preview(Actor(), second_body)["preview"]
    command.confirm(Actor(), second["id"], second["confirmToken"])

    replacement_body = request(
        current=harness.current,
        request_id=first_body.requestId,
        key=first_body.idempotencyKey,
    )
    replacement = command.preview(Actor(), replacement_body)["preview"]
    assert replacement["id"] != first["id"]


@pytest.mark.parametrize(
    "changed",
    [
        {"resourceRevision": 30},
        {"aclRevision": 30},
        {"bindingRevision": 30},
        {"serviceRevision": 30},
        {"firmwareRevision": 30},
        {"stateRevision": 30},
        {"targetId": "other"},
    ],
)
def test_revision_or_identity_drift_before_effect_fails_closed(changed):
    harness = Harness()
    command = authority(harness)
    preview = command.preview(Actor(), request())["preview"]
    harness.current = harness.current.model_copy(update=changed)
    with pytest.raises(ApiError, match="keenetic_command_changed"):
        command.confirm(Actor(), preview["id"], preview["confirmToken"])
    assert harness.effects == []


@pytest.mark.parametrize("version", ["1.4.0", "6.0.0", "unknown", "5.0\nprivate"])
def test_unknown_or_unsupported_firmware_fails_before_authorization(version):
    with pytest.raises(ValueError):
        TargetState.model_validate(state().model_dump() | {"firmwareVersion": version})


def test_default_effect_is_unavailable_and_performs_no_network():
    harness = Harness()
    command = KeeneticCommandAuthority(
        authorize=harness.authorize,
        observe=harness.observe,
    )
    preview = command.preview(Actor(), request())["preview"]
    receipt = command.confirm(Actor(), preview["id"], preview["confirmToken"])["receipt"]
    assert receipt["status"] == "failed"
    assert receipt["code"] == "keenetic_effect_unavailable"


def test_disconnect_or_uncertain_effect_is_unknown_and_never_retried():
    harness = Harness()

    def uncertain(*_):
        harness.effects.append("attempt")
        raise KeeneticEffectError("keenetic_effect_unknown", uncertain=True)

    command = KeeneticCommandAuthority(
        authorize=harness.authorize,
        observe=harness.observe,
        effect=uncertain,
    )
    preview = command.preview(Actor(), request())["preview"]
    receipt = command.confirm(Actor(), preview["id"], preview["confirmToken"])["receipt"]
    assert receipt["status"] == "unknown"
    assert command.confirm(Actor(), preview["id"], preview["confirmToken"])["receipt"] == receipt
    assert harness.effects == ["attempt"]


def test_request_id_and_idempotency_are_exact_and_conflicts_fail_closed():
    harness = Harness()
    command = authority(harness)
    first = command.preview(Actor(), request())["preview"]
    assert command.preview(Actor(), request())["preview"] == first
    changed = request(current=state(target="Other"))
    with pytest.raises(ApiError, match="idempotency_conflict"):
        command.preview(Actor(), changed)

    with pytest.raises(ApiError, match="idempotency_conflict"):
        command.preview(Actor(), request(key="B" * 43))


def test_wrong_confirmation_token_never_dispatches_and_cannot_be_guessed():
    harness = Harness()
    command = authority(harness)
    preview = command.preview(Actor(), request())["preview"]
    with pytest.raises(ApiError, match="keenetic_confirmation_invalid"):
        command.confirm(Actor(), preview["id"], "wrong")
    assert harness.effects == []


def test_late_effect_completion_is_unknown_and_never_replayed():
    class Clock:
        value = 100.0

        def __call__(self):
            return self.value

    clock = Clock()
    harness = Harness()

    def late(command, guard):
        guard()
        harness.effects.append(command.action)
        harness.current = harness.current.model_copy(
            update={"value": "enabled", "stateRevision": 12}
        )
        clock.value += 11

    command = authority(harness, effect=late, clock=clock)
    preview = command.preview(Actor(), request())["preview"]
    receipt = command.confirm(Actor(), preview["id"], preview["confirmToken"])["receipt"]
    assert receipt["status"] == "unknown"
    assert receipt["code"] == "keenetic_effect_timeout"
    assert command.confirm(Actor(), preview["id"], preview["confirmToken"])["receipt"] == receipt
    assert harness.effects == ["guest_wifi_enable"]


def test_monotonic_clock_rollback_invalidates_all_pending_confirmation():
    class Clock:
        value = 100.0

        def __call__(self):
            return self.value

    clock = Clock()
    harness = Harness()
    command = authority(harness, clock=clock)
    preview = command.preview(Actor(), request())["preview"]
    clock.value = 99.0
    with pytest.raises(ApiError, match="server_unavailable"):
        command.confirm(Actor(), preview["id"], preview["confirmToken"])
    assert harness.effects == []


def test_authorization_loss_after_dispatch_returns_unknown_without_replay():
    harness = Harness()
    allowed = True

    def authorize(*_):
        if not allowed:
            raise ApiError("forbidden", 403)

    def effect(command, guard):
        nonlocal allowed
        guard()
        harness.effects.append(command.action)
        harness.current = harness.current.model_copy(
            update={"value": "enabled", "stateRevision": 12}
        )
        allowed = False

    command = KeeneticCommandAuthority(
        authorize=authorize,
        observe=harness.observe,
        effect=effect,
    )
    preview = command.preview(Actor(), request())["preview"]
    receipt = command.confirm(Actor(), preview["id"], preview["confirmToken"])["receipt"]
    assert receipt["status"] == "unknown"
    assert receipt["code"] == "keenetic_result_unknown"
    assert harness.effects == ["guest_wifi_enable"]
