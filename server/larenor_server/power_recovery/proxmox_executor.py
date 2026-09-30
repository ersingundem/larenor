"""Production Proxmox power target resolver and bounded F18 effect executor.

The saved provider reference is a durable delegation to one exact admin account,
home resource, binding, service and egress policy revision.  Runtime execution
revalidates those facts without manufacturing an HTTP session.  Guest selection
comes only from the trusted provider inventory and the private worker owns the
fixed Proxmox API paths and credentials.
"""

from collections import deque
from dataclasses import dataclass
import math
import sqlite3
import threading
import uuid

from cryptography.exceptions import InvalidTag

from ..component_egress import storage as egress_storage
from ..errors import ApiError
from ..proxmox_commands.models import PreviewRequest, ProxmoxGuestDescriptor
from ..proxmox_commands.worker_ipc import ProxmoxPowerWorkerError
from .models import (
    PowerEffectObservation,
    PowerEffectReceipt,
    PowerEffectRequest,
    PowerTarget,
    ProxmoxPowerProviderRef,
)


@dataclass(frozen=True)
class _Authority:
    addresses: tuple[str, ...]
    descriptor: ProxmoxGuestDescriptor


class StoredProxmoxPowerResolver:
    """Resolve only a previously captured, still-current home resource target."""

    def __init__(
        self,
        db,
        auth,
        resources,
        services,
        proxmox_resources,
        component_egress,
        provider,
    ):
        if any(
            value is None
            for value in (
                db,
                auth,
                resources,
                services,
                proxmox_resources,
                component_egress,
            )
        ):
            raise ValueError("power_recovery_proxmox_unavailable")
        self.db = db
        self.auth = auth
        self.resources = resources
        self.services = services
        self.proxmox_resources = proxmox_resources
        self.component_egress = component_egress
        self.provider = provider

    @staticmethod
    def _provider_values(provider, resource_id):
        if provider is None:
            return None
        discover = getattr(provider, "discover", None)
        values = discover(resource_id) if callable(discover) else None
        if values is None:
            selected = provider.resolve(resource_id)
            values = [] if selected is None else [selected]
        if type(values) not in {list, tuple} or len(values) > 256:
            raise ProxmoxPowerWorkerError()
        return values

    @staticmethod
    def _descriptor(ref, values, *, configuring):
        if values is None:
            return ProxmoxGuestDescriptor(
                resource_id=ref.resourceId,
                binding_id=ref.bindingId,
                binding_revision=ref.bindingRevision,
                service_id=ref.serviceId,
                service_revision=ref.serviceRevision,
                guest_kind=ref.guestKind,
                status="unavailable",
                status_revision=ref.statusRevision,
                installation_id=ref.installationId,
                node=ref.node,
                guest_id=ref.guestId,
                capability_ready=True,
            )
        matches = []
        for value in values:
            if not isinstance(value, ProxmoxGuestDescriptor):
                raise ProxmoxPowerWorkerError()
            if (
                value.resource_id == ref.resourceId
                and value.binding_id == ref.bindingId
                and value.binding_revision == ref.bindingRevision
                and value.service_id == ref.serviceId
                and value.service_revision == ref.serviceRevision
                and value.installation_id == ref.installationId
                and value.node == ref.node
                and value.guest_kind == ref.guestKind
                and value.guest_id == ref.guestId
            ):
                matches.append(value)
        if len(matches) != 1:
            raise ProxmoxPowerWorkerError()
        value = matches[0]
        if (
            not value.capability_ready
            or value.status not in {"running", "stopped"}
            or type(value.status_revision) is not int
            or not 1 <= value.status_revision <= 2**63 - 1
            or configuring and value.status_revision != ref.statusRevision
            or not configuring and value.status_revision < ref.statusRevision
        ):
            raise ProxmoxPowerWorkerError()
        return value

    def _authority(self, connection, ref):
        self.resources._check_context(connection, ref.coreId, ref.homeId)
        self.resources._state(connection)
        user = connection.execute(
            "SELECT revision,role,disabled,must_change_password FROM users WHERE id=?",
            (ref.actorId,),
        ).fetchone()
        if (
            user is None
            or user["revision"] != ref.actorRevision
            or user["role"] != "admin"
            or user["disabled"]
            or user["must_change_password"]
        ):
            raise ProxmoxPowerWorkerError()
        row, resource_ref, _data = self.resources._target(
            connection, ref.resourceId
        )
        if (
            resource_ref.kind != "resource"
            or (resource_ref.coreId, resource_ref.homeId)
            != (ref.coreId, ref.homeId)
            or row["revision"] != ref.resourceRevision
            or row["acl_revision"] != ref.aclRevision
        ):
            raise ProxmoxPowerWorkerError()
        binding_row = connection.execute(
            "SELECT * FROM proxmox_resource_bindings WHERE resource_id=?",
            (ref.resourceId,),
        ).fetchone()
        if binding_row is None:
            raise ProxmoxPowerWorkerError()
        binding = self.proxmox_resources._decode(binding_row)
        service = self.services._proxmox_connection(
            connection, ref.serviceId, ref.serviceRevision
        )
        if (
            binding.id != ref.bindingId
            or binding.revision != ref.bindingRevision
            or binding.ref != resource_ref
            or binding.serviceId != ref.serviceId
            or binding.serviceRevision != ref.serviceRevision
            or service.id != ref.serviceId
            or service.revision != ref.serviceRevision
        ):
            raise ProxmoxPowerWorkerError()
        state = egress_storage.load(
            connection,
            self.component_egress.key,
            self.component_egress.scope,
        )
        policies = [
            policy for policy in state.policies if policy.serviceId == ref.serviceId
        ]
        if (
            len(policies) != 1
            or policies[0].revision != ref.egressRevision
            or policies[0].serviceRevision != ref.serviceRevision
            or policies[0].component != "proxmox_command_worker"
            or not self.component_egress._matches(policies[0], service)
        ):
            raise ProxmoxPowerWorkerError()
        return tuple(
            address.address for address in policies[0].grants[0].addresses
        )

    def validate_configuration(self, connection, actor, target: PowerTarget):
        ref = target.providerRef
        if (
            not isinstance(ref, ProxmoxPowerProviderRef)
            or target.kind != "proxmoxGuest"
            or target.targetId != ref.target_id()
            or actor.id != ref.actorId
        ):
            raise ApiError("invalid_request")
        try:
            self.auth.assert_current(connection, actor)
            addresses = self._authority(connection, ref)
            descriptor = self._descriptor(
                ref,
                self._provider_values(self.provider, ref.resourceId),
                configuring=True,
            )
            return _Authority(addresses, descriptor)
        except ApiError:
            raise
        except (InvalidTag, sqlite3.Error, ProxmoxPowerWorkerError, ValueError, TypeError):
            raise ApiError("revision_conflict", 409) from None

    def _read_authority(self, ref):
        try:
            with self.db.connection() as connection:
                connection.execute("BEGIN")
                return self._authority(connection, ref)
        except (InvalidTag, sqlite3.Error, ApiError, ValueError, TypeError):
            raise ProxmoxPowerWorkerError() from None

    def guard(self, ref, expected_addresses):
        if self._read_authority(ref) != expected_addresses:
            raise ProxmoxPowerWorkerError()

    def resolve(self, ref):
        if not isinstance(ref, ProxmoxPowerProviderRef):
            raise ProxmoxPowerWorkerError()
        addresses = self._read_authority(ref)
        descriptor = self._descriptor(
            ref,
            self._provider_values(self.provider, ref.resourceId),
            configuring=False,
        )
        if self._read_authority(ref) != addresses:
            raise ProxmoxPowerWorkerError()
        return _Authority(addresses, descriptor)


class ProxmoxPowerRecoveryExecutor:
    """Execute F18 effects only through current exact authority and worker IPC."""

    available = True

    def __init__(self, resolver, worker, settings):
        if resolver is None or worker is None or settings is None:
            raise ValueError("power_recovery_proxmox_unavailable")
        self.resolver = resolver
        self.worker = worker
        self.settings = settings
        self._lock = threading.Lock()
        self._receipts = {}
        self._receipt_order = deque()

    def validate_configuration(self, connection, actor, target):
        if target.providerRef is None:
            return None
        selected = self.resolver.validate_configuration(connection, actor, target)
        ref = target.providerRef
        self.worker.observe_bounded(
            selected.descriptor,
            lambda: None,
            user_revision=ref.actorRevision,
            resource_revision=ref.resourceRevision,
            acl_revision=ref.aclRevision,
            deadline_ms=min(5_000, target.timeoutSeconds * 1000),
            allowed_addresses=selected.addresses,
        )
        return selected

    def _remember(self, receipt):
        key = (receipt.runId, receipt.stepId)
        with self._lock:
            self._receipts[key] = receipt
            self._receipt_order.append(key)
            while len(self._receipt_order) > 128:
                old = self._receipt_order.popleft()
                if old not in self._receipt_order:
                    self._receipts.pop(old, None)

    def reconcile(self, request):
        """Return only an in-process causal receipt; never infer it from a later GET."""
        if not isinstance(request, PowerEffectRequest):
            return None
        with self._lock:
            receipt = self._receipts.get((request.runId, request.stepId))
        if (
            receipt is None
            or receipt.targetId != request.target.targetId
            or receipt.action != request.action
            or receipt.completedAt > request.deadlineAt
        ):
            return None
        return receipt

    def observe(self, request):
        """Return current state evidence without claiming the earlier effect ran."""
        if (
            not isinstance(request, PowerEffectRequest)
            or request.target.kind != "proxmoxGuest"
            or request.target.providerRef is None
        ):
            raise ProxmoxPowerWorkerError()
        ref = request.target.providerRef
        selected = self.resolver.resolve(ref)
        observed = self.worker.observe_bounded(
            selected.descriptor,
            lambda: self.resolver.guard(ref, selected.addresses),
            user_revision=ref.actorRevision,
            resource_revision=ref.resourceRevision,
            acl_revision=ref.aclRevision,
            deadline_ms=min(5_000, request.target.timeoutSeconds * 1000),
            allowed_addresses=selected.addresses,
        )
        observed_at = self.settings.clock()
        if (
            type(observed_at) not in {int, float}
            or isinstance(observed_at, bool)
            or not math.isfinite(observed_at)
            or observed_at < 0
        ):
            raise ProxmoxPowerWorkerError()
        return PowerEffectObservation(
            contractVersion=1,
            runId=request.runId,
            stepId=request.stepId,
            targetId=request.target.targetId,
            action=request.action,
            observedState=observed.state,
            observedAt=int(observed_at),
        )

    def _remaining_deadline_ms(self, deadline_at):
        now = self.settings.clock()
        if (
            type(now) not in {int, float}
            or isinstance(now, bool)
            or not math.isfinite(now)
        ):
            raise ProxmoxPowerWorkerError()
        remaining = deadline_at - now
        if remaining < 0.5:
            raise ProxmoxPowerWorkerError()
        return min(30_000, max(500, int(remaining * 1000)))

    def execute(self, request):
        if (
            not isinstance(request, PowerEffectRequest)
            or request.target.kind != "proxmoxGuest"
            or request.target.providerRef is None
        ):
            raise ProxmoxPowerWorkerError()
        ref = request.target.providerRef
        selected = self.resolver.resolve(ref)
        observation_deadline_ms = self._remaining_deadline_ms(request.deadlineAt)

        def guard():
            self.resolver.guard(ref, selected.addresses)

        observation = self.worker.observe_bounded(
            selected.descriptor,
            guard,
            user_revision=ref.actorRevision,
            resource_revision=ref.resourceRevision,
            acl_revision=ref.aclRevision,
            deadline_ms=observation_deadline_ms,
            allowed_addresses=selected.addresses,
        )
        expected_source = "running" if request.action == "shutdown" else "stopped"
        if observation.state != expected_source:
            # A read taken after an unknown earlier effect is not causal proof.
            raise ProxmoxPowerWorkerError()
        mutation_deadline_ms = self._remaining_deadline_ms(request.deadlineAt)
        descriptor = ProxmoxGuestDescriptor(
            resource_id=selected.descriptor.resource_id,
            binding_id=selected.descriptor.binding_id,
            binding_revision=selected.descriptor.binding_revision,
            service_id=selected.descriptor.service_id,
            service_revision=selected.descriptor.service_revision,
            guest_kind=selected.descriptor.guest_kind,
            status=observation.state,
            status_revision=observation.status_revision,
            installation_id=selected.descriptor.installation_id,
            node=selected.descriptor.node,
            guest_id=selected.descriptor.guest_id,
            capability_ready=selected.descriptor.capability_ready,
        )
        preview = PreviewRequest(
            schemaVersion=1,
            requestId=uuid.uuid4().hex,
            action=request.action,
            expectedUserRevision=ref.actorRevision,
            expectedResourceRevision=ref.resourceRevision,
            expectedAclRevision=ref.aclRevision,
            expectedBindingId=ref.bindingId,
            expectedBindingRevision=ref.bindingRevision,
            expectedServiceId=ref.serviceId,
            expectedServiceRevision=ref.serviceRevision,
            expectedGuestKind=ref.guestKind,
            expectedCurrentState=observation.state,
            expectedStatusRevision=observation.status_revision,
        )
        result = self.worker.execute_bounded(
            descriptor,
            request.action,
            guard,
            preview=preview,
            deadline_ms=mutation_deadline_ms,
            allowed_addresses=selected.addresses,
        )
        completed = self.settings.clock()
        expected_state = "stopped" if request.action == "shutdown" else "running"
        if (
            result.outcome != "succeeded"
            or result.state != expected_state
            or type(completed) not in {int, float}
            or isinstance(completed, bool)
            or not math.isfinite(completed)
            or completed > request.deadlineAt
        ):
            raise ProxmoxPowerWorkerError()
        receipt = PowerEffectReceipt(
            contractVersion=1,
            runId=request.runId,
            stepId=request.stepId,
            targetId=request.target.targetId,
            action=request.action,
            status="completed",
            observedState=expected_state,
            completedAt=int(completed),
        )
        self._remember(receipt)
        return receipt
