from dataclasses import replace

import pytest

from larenor_server.errors import ApiError
from larenor_server.legacy_remote import (
    LegacyRemoteManager,
    RemoteAuthority,
    RemoteCodeBinding,
    RemoteCommandDefinition,
    RemoteCommandProfile,
    RemoteDeliveryReceipt,
    RemoteDevice,
    RemoteWorkerCommand,
)


CORE = "1" * 32
HOME = "2" * 32
ACCOUNT = "3" * 32
FAMILY = "4" * 32
DEVICE = "5" * 32
BRIDGE = "6" * 32
PROVIDER = "7" * 32
PROFILE = "8" * 32
CODE_SET = "9" * 32
POWER = "a" * 32
VOLUME_UP = "b" * 32


class Clock:
    def __init__(self):
        self.ms = 3_000_000

    def __call__(self):
        return self.ms


def authority(**changes):
    values = dict(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        homeRevision=3,
        accountId=ACCOUNT,
        accountRevision=5,
        memberRevision=7,
        sessionFamilyId=FAMILY,
        active=True,
        canControlLegacyRemote=True,
    )
    values.update(changes)
    return RemoteAuthority(**values)


def device(**changes):
    values = dict(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        deviceId=DEVICE,
        revision=11,
        providerType="home_assistant",
        providerId=PROVIDER,
        providerRevision=13,
        bridgeId=BRIDGE,
        bridgeRevision=17,
        protocol="ir",
        stored=True,
        reachable=True,
        providerVerified=True,
    )
    values.update(changes)
    return RemoteDevice(**values)


def profile(**changes):
    values = dict(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        profileId=PROFILE,
        revision=19,
        deviceId=DEVICE,
        expectedDeviceRevision=11,
        providerId=PROVIDER,
        expectedProviderRevision=13,
        codeSetId=CODE_SET,
        codeSetRevision=23,
        protocol="ir",
        commands=[
            RemoteCommandDefinition(
                schemaVersion=1,
                bindingId=POWER,
                key="power_toggle",
                maxRepeats=1,
                maxHoldMs=0,
            ),
            RemoteCommandDefinition(
                schemaVersion=1,
                bindingId=VOLUME_UP,
                key="volume_up",
                maxRepeats=3,
                maxHoldMs=600,
            ),
        ],
    )
    values.update(changes)
    return RemoteCommandProfile(**values)


def manager(
    current_device,
    current_profile,
    worker,
    clock=None,
    current_authority=None,
):
    live_authority = current_authority or authority()
    return LegacyRemoteManager(
        auditKey=b"f56-legacy-smart-remote-audit-key",
        authorityResolver=lambda account_id: (
            live_authority if account_id == ACCOUNT else None
        ),
        deviceResolver=lambda device_id: current_device if device_id == DEVICE else None,
        profileResolver=lambda profile_id: current_profile if profile_id == PROFILE else None,
        worker=worker,
        clockMs=clock or Clock(),
    )


def test_device_code_set_and_provider_revisions_are_exactly_bound():
    current_device = device()
    current_profile = profile()
    service = manager(current_device, current_profile, lambda command: None)
    preview = service.preview(
        authority(),
        current_device,
        current_profile,
        commandKey="volume_up",
        repeats=2,
        holdMs=400,
        requestId="c" * 32,
    )

    assert preview.deviceRevision == 11
    assert preview.providerRevision == 13
    assert preview.codeSetRevision == 23
    assert preview.bindingId == VOLUME_UP
    assert preview.providerType == "home_assistant"

    stale_values = [
        (current_device.model_copy(update={"revision": 99}), current_profile),
        (
            current_device.model_copy(update={"providerRevision": 99}),
            current_profile,
        ),
        (
            current_device,
            current_profile.model_copy(update={"codeSetRevision": 99}),
        ),
        (current_device, current_profile.model_copy(update={"revision": 99})),
    ]
    for stale_device, stale_profile in stale_values:
        with pytest.raises(ApiError) as error:
            service.preview(
                authority(),
                stale_device,
                stale_profile,
                commandKey="volume_up",
                repeats=1,
                holdMs=0,
                requestId="d" * 32,
            )
        assert (error.value.code, error.value.status) == (
            "revision_conflict",
            409,
        )


def test_preview_confirm_deadline_idempotency_and_lost_ack_never_replay():
    clock = Clock()
    current_device = device()
    current_profile = profile()
    calls = []

    def worker(command):
        calls.append(command)
        return RemoteDeliveryReceipt(
            schemaVersion=1,
            requestId=command.requestId,
            coreId=command.coreId,
            homeId=command.homeId,
            providerId=command.providerId,
            providerRevision=command.providerRevision,
            bridgeId=command.bridgeId,
            bridgeRevision=command.bridgeRevision,
            deviceId=command.deviceId,
            deviceRevision=command.deviceRevision,
            profileId=command.profileId,
            profileRevision=command.profileRevision,
            codeSetId=command.codeSetId,
            codeSetRevision=command.codeSetRevision,
            bindingId=command.bindingId,
            key=command.key,
            repeats=command.repeats,
            holdMs=command.holdMs,
            status="emitted",
        )

    service = manager(current_device, current_profile, worker, clock)
    preview = service.preview(
        authority(),
        current_device,
        current_profile,
        commandKey="power_toggle",
        repeats=1,
        holdMs=0,
        requestId="c" * 32,
    )
    result = service.confirm(authority(), preview, preview.confirmationToken)
    assert (result.status, result.deliveryVerified, result.deviceStateVerified) == (
        "dispatched",
        True,
        False,
    )
    assert service.confirm(authority(), preview, preview.confirmationToken) == result
    assert len(calls) == 1

    expired = service.preview(
        authority(),
        current_device,
        current_profile,
        commandKey="volume_up",
        repeats=1,
        holdMs=0,
        requestId="d" * 32,
    )
    clock.ms = expired.expiresAtMs
    with pytest.raises(ApiError) as deadline_error:
        service.confirm(authority(), expired, expired.confirmationToken)
    assert (deadline_error.value.code, deadline_error.value.status) == (
        "remote_preview_expired",
        409,
    )
    assert len(calls) == 1

    clock.ms -= 1
    lost_calls = []

    def lost_ack(command):
        lost_calls.append(command)
        raise TimeoutError("private bridge token")

    lost = manager(current_device, current_profile, lost_ack, clock)
    lost_preview = lost.preview(
        authority(),
        current_device,
        current_profile,
        commandKey="volume_up",
        repeats=1,
        holdMs=0,
        requestId="e" * 32,
    )
    uncertain = lost.confirm(
        authority(), lost_preview, lost_preview.confirmationToken
    )
    assert (uncertain.status, uncertain.reason) == ("uncertain", "lost_ack")
    assert lost.confirm(
        authority(), lost_preview, lost_preview.confirmationToken
    ) == uncertain
    assert len(lost_calls) == 1
    assert "private bridge token" not in uncertain.model_dump_json()


def test_only_authorized_bounded_keys_are_public_and_raw_learning_stays_private():
    current_device = device()
    current_profile = profile()
    captured = []
    service = manager(
        current_device,
        current_profile,
        lambda command: captured.append(command),
    )

    restricted = authority(canControlLegacyRemote=False)
    restricted_service = manager(
        current_device,
        current_profile,
        lambda command: captured.append(command),
        current_authority=restricted,
    )
    with pytest.raises(ApiError) as authority_error:
        restricted_service.preview(
            restricted,
            current_device,
            current_profile,
            commandKey="power_toggle",
            repeats=1,
            holdMs=0,
            requestId="c" * 32,
        )
    assert (authority_error.value.code, authority_error.value.status) == (
        "forbidden",
        403,
    )

    for key, repeats, hold_ms in (
        ("learn", 1, 0),
        ("raw_ir", 1, 0),
        ("volume_up", 4, 0),
        ("volume_up", 1, 601),
    ):
        with pytest.raises(ApiError) as command_error:
            service.preview(
                authority(),
                current_device,
                current_profile,
                commandKey=key,
                repeats=repeats,
                holdMs=hold_ms,
                requestId="d" * 32,
            )
        assert (command_error.value.code, command_error.value.status) == (
            "remote_command_forbidden",
            403,
        )

    preview = service.preview(
        authority(),
        current_device,
        current_profile,
        commandKey="power_toggle",
        repeats=1,
        holdMs=0,
        requestId="e" * 32,
    )
    public = preview.model_dump(mode="json")
    forbidden_names = {"raw", "payload", "secret", "credential", "learning"}
    assert not any(
        blocked in name.lower()
        for name in public
        for blocked in forbidden_names
    )
    assert "private-provider-secret" not in preview.model_dump_json()

    binding = RemoteCodeBinding(
        schemaVersion=1,
        bindingId=POWER,
        key="power_toggle",
        codeSetId=CODE_SET,
        codeSetRevision=23,
    )
    assert set(binding.model_dump()) == {
        "schemaVersion",
        "bindingId",
        "key",
        "codeSetId",
        "codeSetRevision",
    }

    public_types = (
        RemoteAuthority,
        RemoteCodeBinding,
        RemoteCommandDefinition,
        RemoteCommandProfile,
        RemoteDeliveryReceipt,
        RemoteDevice,
        RemoteWorkerCommand,
    )
    assert not any(
        blocked in field.lower()
        for model in public_types
        for field in model.model_fields
        for blocked in forbidden_names
    )

    first = service.audit[0]
    service._audit[0] = replace(first, entryHash="0" * 64)
    with pytest.raises(ApiError) as audit_error:
        service.preview(
            authority(),
            current_device,
            current_profile,
            commandKey="power_toggle",
            repeats=1,
            holdMs=0,
            requestId="f" * 32,
        )
    assert (audit_error.value.code, audit_error.value.status) == (
        "remote_command_integrity_failed",
        503,
    )
    assert captured == []
