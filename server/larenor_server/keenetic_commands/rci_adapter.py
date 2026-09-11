"""Packaged Keenetic RCI allowlist with an injected, unavailable-by-default transport."""

import math
import time
from typing import Literal

from pydantic import Field

from ..home_resources.models import FrozenModel
from .credential_lease import KeeneticCredentialLease
from .models import TargetState
from .service import KeeneticEffectError
from .worker_models import KeeneticWorkerCommand, KeeneticWorkerResult


class RciCommand(FrozenModel):
    operation: Literal[
        "guest_wifi_enable",
        "guest_wifi_disable",
        "client_access_pause",
        "client_access_resume",
        "wan_reconnect",
    ]
    expectedState: TargetState
    credentialLease: KeeneticCredentialLease | None = Field(default=None, repr=False)

    @property
    def targetKind(self):
        return self.expectedState.targetKind

    @property
    def targetId(self):
        return self.expectedState.targetId


_OPERATIONS = {
    "guest_wifi_enable": "guest_wifi_enable",
    "guest_wifi_disable": "guest_wifi_disable",
    "client_internet_pause": "client_access_pause",
    "client_internet_resume": "client_access_resume",
    "wan_reconnect": "wan_reconnect",
}


class UnavailableRciTransport:
    """Safe packaged default. It has no DNS, HTTP, or socket implementation."""

    def __call__(self, _command, *, deadline, cancelled):
        raise KeeneticEffectError("keenetic_effect_unavailable")


class PackagedRciCommandAdapter:
    def __init__(self, transport=None):
        self._transport = transport or UnavailableRciTransport()

    def execute(self, command, *, deadline, cancelled):
        command = KeeneticWorkerCommand.model_validate(command)
        if (
            type(deadline) not in (int, float)
            or not math.isfinite(deadline)
            or not callable(cancelled)
        ):
            raise KeeneticEffectError("keenetic_effect_rejected")
        if cancelled():
            raise KeeneticEffectError("keenetic_effect_cancelled")
        if time.monotonic() >= deadline:
            raise KeeneticEffectError("keenetic_effect_timeout")
        operation = RciCommand(
            operation=_OPERATIONS[command.action],
            expectedState=command.target,
            credentialLease=command.credentialLease,
        )
        dispatched = False
        try:
            dispatched = True
            observed = self._transport(
                operation, deadline=deadline, cancelled=cancelled
            )
            if cancelled():
                raise KeeneticEffectError(
                    "keenetic_effect_cancelled", uncertain=True
                )
            if time.monotonic() >= deadline:
                raise KeeneticEffectError(
                    "keenetic_effect_timeout", uncertain=True
                )
            return KeeneticWorkerResult.for_command(command, {
                "schemaVersion": 1,
                "requestId": command.requestId,
                "action": command.action,
                "target": command.target,
                "previewReceipt": command.previewReceipt,
                "status": "succeeded",
                "code": "keenetic_effect_succeeded",
                "observedState": observed,
            })
        except KeeneticEffectError:
            raise
        except Exception:
            raise KeeneticEffectError(
                "keenetic_effect_unknown", uncertain=dispatched
            ) from None
