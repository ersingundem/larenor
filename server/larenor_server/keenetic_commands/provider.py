"""Revision-bound command targets derived from authorized Keenetic telemetry."""

from pydantic import ValidationError

from ..errors import ApiError
from ..keenetic_resources.models import ResourceSnapshot
from .models import CommandTargetDescriptor, CommandTargetResponse, TargetState


MAX_TARGETS = 128


def _unavailable():
    return ApiError("keenetic_command_unavailable", 503)


class KeeneticCommandStateProvider:
    """Turn one fresh read-side snapshot into command-authority descriptors."""

    def __init__(self, resources, *, authorize, actor_revision, egress):
        self._resources = resources
        self._authorize = authorize
        self._actor_revision = actor_revision
        self._egress = egress

    @staticmethod
    def _target(snapshot, *, kind, identity, value):
        status = snapshot.telemetry.status
        return TargetState(
            schemaVersion=1,
            coreId=snapshot.ref.coreId,
            homeId=snapshot.ref.homeId,
            resourceId=snapshot.ref.id,
            resourceRevision=snapshot.resourceRevision,
            aclRevision=snapshot.aclRevision,
            bindingId=snapshot.bindingId,
            bindingRevision=snapshot.bindingRevision,
            serviceId=snapshot.serviceId,
            serviceRevision=snapshot.serviceRevision,
            firmwareVersion=status.firmware,
            firmwareRevision=status.firmwareRevision,
            stateRevision=status.statusRevision,
            targetKind=kind,
            targetId=identity,
            value=value,
        )

    def _build(self, snapshot, user_revision):
        status = snapshot.telemetry.status
        if (
            snapshot.remainingTtlMs <= 0
            or not status.online
            or status.firmware is None
            or status.firmwareRevision is None
            or status.statusRevision is None
        ):
            raise _unavailable()

        descriptors = []
        for interface in snapshot.telemetry.interfaces:
            if interface.kind == "wifi" and interface.guest is True:
                value = "enabled" if interface.online else "disabled"
                action = "guest_wifi_disable" if interface.online else "guest_wifi_enable"
                descriptors.append((0, interface.id, self._target(
                    snapshot, kind="guest_wifi", identity=interface.id, value=value
                ), action))
        for host in snapshot.telemetry.hosts:
            if host.internetAccess is not None:
                action = (
                    "client_internet_pause"
                    if host.internetAccess == "allowed"
                    else "client_internet_resume"
                )
                descriptors.append((1, host.macAddress.upper(), self._target(
                    snapshot,
                    kind="client",
                    identity=host.macAddress.upper(),
                    value=host.internetAccess,
                ), action))
        for interface in snapshot.telemetry.interfaces:
            if interface.kind == "wan" and interface.online:
                descriptors.append((2, interface.id, self._target(
                    snapshot, kind="wan", identity=interface.id, value="online"
                ), "wan_reconnect"))

        descriptors.sort(key=lambda item: (item[0], item[1]))
        identities = [(target.targetKind, target.targetId) for _, _, target, _ in descriptors]
        if not descriptors or len(descriptors) > MAX_TARGETS or len(set(identities)) != len(identities):
            raise _unavailable()
        return CommandTargetResponse(descriptors=[
            CommandTargetDescriptor(
                target=target, actions=[action], expectedUserRevision=user_revision
            )
            for _, _, target, action in descriptors
        ])

    def descriptors(self, actor, core, home, resource, *, cancelled=lambda: False):
        try:
            before = self._actor_revision(actor)
            raw = self._resources.snapshot(
                actor,
                core,
                home,
                resource,
                cancelled=cancelled,
                bypass_cache=True,
            )["snapshot"]
            snapshot = ResourceSnapshot.model_validate(raw)
            if (
                snapshot.ref.coreId,
                snapshot.ref.homeId,
                snapshot.ref.id,
            ) != (core, home, resource):
                raise _unavailable()
            response = self._build(snapshot, before)
            for descriptor in response.descriptors:
                self._authorize(actor, descriptor.target, "write")
            self._egress.check_component(
                actor,
                snapshot.serviceId,
                snapshot.serviceRevision,
                "keenetic_command_worker",
            )
            if self._actor_revision(actor) != before:
                raise _unavailable()
            return response.model_dump(mode="json")
        except (ApiError, KeyError, TypeError, ValueError, ValidationError):
            raise _unavailable() from None

    def for_actor(self, actor, target):
        try:
            expected = TargetState.model_validate(target)
            response = self.descriptors(
                actor, expected.coreId, expected.homeId, expected.resourceId
            )
            matches = [
                TargetState.model_validate(item["target"])
                for item in response["descriptors"]
                if item["target"]["targetKind"] == expected.targetKind
                and item["target"]["targetId"] == expected.targetId
            ]
            if len(matches) != 1 or matches[0] != expected:
                raise _unavailable()
            return matches[0]
        except (ApiError, KeyError, TypeError, ValueError, ValidationError):
            raise _unavailable() from None
