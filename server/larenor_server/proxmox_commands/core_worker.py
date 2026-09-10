"""Core-side component-egress gate for Proxmox power effects."""

from ..errors import ApiError
from .worker_ipc import ProxmoxPowerWorkerError


class EgressGatedProxmoxExecutor:
    """Bind each worker command to the current service grant and IP pins."""

    def __init__(self, delegate, component_egress):
        if delegate is None or component_egress is None:
            raise ValueError("worker_unavailable")
        self._delegate = delegate
        self._egress = component_egress

    def __repr__(self):
        return "EgressGatedProxmoxExecutor(<private>)"

    def _addresses(self, actor, descriptor):
        try:
            policy = self._egress.check_component(
                actor, descriptor.service_id, descriptor.service_revision,
                "proxmox_command_worker",
            )
            return tuple(address.address for address in policy.grants[0].addresses)
        except (ApiError, AttributeError, IndexError, TypeError, ValueError):
            raise ProxmoxPowerWorkerError() from None

    def execute_for_actor(
        self, actor, descriptor, action, guard, *, preview, deadline_ms,
        continuation_guard=None,
    ):
        def current_guard():
            guard()
            return self._addresses(actor, descriptor)

        def current_continuation():
            (continuation_guard or guard)()
            self._addresses(actor, descriptor)

        addresses = current_guard()
        result = self._delegate.execute_bounded(
            descriptor, action, current_guard, preview=preview,
            deadline_ms=deadline_ms,
            continuation_guard=current_continuation,
            allowed_addresses=addresses,
        )
        try:
            current_continuation()
        except (ProxmoxPowerWorkerError, ApiError):
            raise ProxmoxPowerWorkerError() from None
        return result
