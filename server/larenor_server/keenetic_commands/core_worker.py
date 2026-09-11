"""Core-side gate for one exact live Keenetic command worker."""

import os

from ..errors import ApiError
from ..files import private_read
from .credential_lease import KeeneticCredentialLeaseIssuer
from .service import KeeneticEffectError
from .worker_ipc import (
    KeeneticCommandWorkerClient,
    LeasedKeeneticCommandWorkerClient,
)
from .worker_runtime import RuntimeConfigurationError, WorkerHealthStore


def _process_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


class HealthGatedKeeneticWorkerEffect:
    """Issue leases only while worker identity and component egress stay exact."""

    def __init__(self, settings, services, component_egress, *, process_alive=None):
        self._settings = settings
        self._egress = component_egress
        self._process_alive = process_alive or _process_alive
        if not callable(self._process_alive):
            raise KeeneticEffectError("keenetic_effect_unavailable")
        try:
            self._health = WorkerHealthStore(
                settings.keenetic_worker_health,
                owner_uid=settings.keenetic_worker_uid,
            )
            self._identity = self._health.verify_ready(
                settings.keenetic_worker_socket
            )
            if not self._process_alive(self._identity.workerPid):
                raise ValueError()
            key = private_read(settings.keenetic_worker_key_file, 32)
            if len(key) != 32:
                raise ValueError()
            raw = KeeneticCommandWorkerClient(
                settings.keenetic_worker_socket,
                owner_uid=settings.keenetic_worker_uid,
            )
            issuer = KeeneticCredentialLeaseIssuer(
                services, key, clock=settings.clock
            )
            self._delegate = LeasedKeeneticCommandWorkerClient(
                raw,
                issuer,
                worker_id=self._identity.workerId,
                ttl_seconds=10,
                egress=self._allowed,
            )
        except Exception:
            raise KeeneticEffectError("keenetic_effect_unavailable") from None

    def __repr__(self):
        return "HealthGatedKeeneticWorkerEffect(<private>)"

    def _live(self):
        try:
            current = self._health.verify_ready(
                self._settings.keenetic_worker_socket
            )
            if current != self._identity or not self._process_alive(current.workerPid):
                raise ValueError()
        except Exception:
            raise KeeneticEffectError("keenetic_effect_unavailable") from None

    def _allowed(self, actor, target):
        try:
            policy = self._egress.check_component(
                actor,
                target.serviceId,
                target.serviceRevision,
                "keenetic_command_worker",
            )
            return tuple(
                address.address for address in policy.grants[0].addresses
            )
        except (ApiError, AttributeError, IndexError, TypeError, ValueError):
            raise KeeneticEffectError("keenetic_effect_unavailable") from None

    def execute_for_actor(self, actor, request, guard):
        def preflight():
            guard()
            self._live()
            self._allowed(actor, request.target)

        preflight()
        result = self._delegate.execute_for_actor(actor, request, preflight)
        try:
            preflight()
        except KeeneticEffectError:
            raise KeeneticEffectError(
                "keenetic_result_unknown", uncertain=True
            ) from None
        return result


def build_keenetic_worker_effect(
    settings, services, component_egress, *, process_alive=None
):
    if settings.keenetic_worker_socket is None:
        return None
    try:
        return HealthGatedKeeneticWorkerEffect(
            settings,
            services,
            component_egress,
            process_alive=process_alive,
        )
    except (KeeneticEffectError, RuntimeConfigurationError, OSError, ValueError):
        return None
