from types import SimpleNamespace

import pytest
from pydantic import ValidationError

from larenor_server.power_recovery.models import (
    PowerEffectRequest,
    PowerTarget,
    ProxmoxPowerProviderRef,
)
from larenor_server.power_recovery.proxmox_executor import (
    ProxmoxPowerRecoveryExecutor,
)
from larenor_server.proxmox_commands.models import (
    ProxmoxGuestDescriptor,
    ProxmoxPowerEffectResult,
)
from larenor_server.proxmox_commands.worker_ipc import (
    PackagedProxmoxObservationResult,
    ProxmoxPowerWorkerError,
)


def provider_ref():
    return ProxmoxPowerProviderRef(
        contractVersion=1,
        provider="proxmox",
        actorId="1" * 32,
        actorRevision=3,
        coreId="2" * 32,
        homeId="3" * 32,
        resourceId="4" * 32,
        resourceRevision=5,
        aclRevision=6,
        bindingId="binding_1",
        bindingRevision=7,
        serviceId="service_1",
        serviceRevision=9,
        egressRevision=10,
        installationId="service_1",
        node="node-a",
        guestKind="qemu",
        guestId=101,
        statusRevision=11,
    )


def target():
    ref = provider_ref()
    return PowerTarget(
        targetId=ref.target_id(),
        label="Synthetic guest",
        kind="proxmoxGuest",
        shutdownOrder=1,
        startOnRestore=True,
        timeoutSeconds=30,
        providerRef=ref,
    )


def effect(action="shutdown"):
    return PowerEffectRequest(
        contractVersion=1,
        runId="5" * 32,
        stepId="6" * 32,
        action=action,
        target=target(),
        deadlineAt=130,
    )


class Resolver:
    def __init__(self, state="running"):
        self.state = state
        self.guards = []
        self.validations = []
        self.value = SimpleNamespace(
            addresses=("10.0.0.2",),
            descriptor=ProxmoxGuestDescriptor(
                resource_id="4" * 32,
                binding_id="binding_1",
                binding_revision=7,
                service_id="service_1",
                service_revision=9,
                guest_kind="qemu",
                status=state,
                status_revision=11,
                installation_id="service_1",
                node="node-a",
                guest_id=101,
                capability_ready=True,
            ),
        )

    def resolve(self, ref):
        assert ref == provider_ref()
        return self.value

    def guard(self, ref, addresses):
        self.guards.append((ref, addresses))

    def validate_configuration(self, connection, actor, selected):
        self.validations.append((connection, actor, selected))


class Worker:
    def __init__(self, state="running", outcome="succeeded"):
        self.state = state
        self.outcome = outcome
        self.calls = []

    def observe_bounded(self, descriptor, guard, **options):
        guard()
        self.calls.append(("GET", descriptor, options))
        return PackagedProxmoxObservationResult(self.state, 11)

    def execute_bounded(self, descriptor, action, guard, **options):
        guard()
        self.calls.append(("POST", descriptor, action, options))
        target_state = "stopped" if action == "shutdown" else "running"
        return ProxmoxPowerEffectResult(self.outcome, target_state, 12, None)


def test_executor_observes_then_dispatches_exact_bounded_effect_and_caches_receipt():
    resolver = Resolver()
    worker = Worker()
    executor = ProxmoxPowerRecoveryExecutor(
        resolver, worker, SimpleNamespace(clock=lambda: 100)
    )

    receipt = executor.execute(effect())

    assert [call[0] for call in worker.calls] == ["GET", "POST"]
    observation = worker.calls[0][2]
    assert observation["user_revision"] == 3
    assert observation["resource_revision"] == 5
    assert observation["acl_revision"] == 6
    preview = worker.calls[1][3]["preview"]
    assert (
        preview.expectedBindingId,
        preview.expectedBindingRevision,
        preview.expectedServiceId,
        preview.expectedServiceRevision,
    ) == ("binding_1", 7, "service_1", 9)
    assert receipt.observedState == "stopped"
    assert executor.reconcile(effect()) == receipt
    assert len(resolver.guards) == 2


def test_executor_recomputes_one_effect_deadline_after_observation():
    resolver = Resolver()
    worker = Worker()
    times = iter((100, 110, 111))
    executor = ProxmoxPowerRecoveryExecutor(
        resolver, worker, SimpleNamespace(clock=lambda: next(times))
    )

    executor.execute(effect())

    assert worker.calls[0][2]["deadline_ms"] == 30_000
    assert worker.calls[1][3]["deadline_ms"] == 20_000


def test_later_matching_observation_is_never_a_terminal_effect_receipt():
    resolver = Resolver(state="stopped")
    worker = Worker(state="stopped")
    executor = ProxmoxPowerRecoveryExecutor(
        resolver, worker, SimpleNamespace(clock=lambda: 100)
    )

    with pytest.raises(ProxmoxPowerWorkerError):
        executor.execute(effect())

    assert [call[0] for call in worker.calls] == ["GET"]
    assert executor.reconcile(effect()) is None


def test_unknown_mutation_result_retains_no_reconcilable_receipt():
    executor = ProxmoxPowerRecoveryExecutor(
        Resolver(), Worker(outcome="unknown"), SimpleNamespace(clock=lambda: 100)
    )

    with pytest.raises(ProxmoxPowerWorkerError):
        executor.execute(effect())

    assert executor.reconcile(effect()) is None


def test_provider_ref_must_derive_the_selected_public_target_identity():
    values = target().model_dump()
    values["targetId"] = "f" * 32

    with pytest.raises(ValidationError):
        PowerTarget.model_validate(values)
