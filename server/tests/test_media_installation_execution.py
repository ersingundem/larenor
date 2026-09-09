"""Closed S06.4 execution intents; synthetic worker effects only."""

from dataclasses import replace

import pytest

from larenor_server.plugins.installation_execution import (
    ExecutionGateResult,
    InstallationExecution,
    InstallationExecutionError,
    JellyfinWorkerBackend,
    build_execution,
)
from larenor_server.plugins.worker import StepReceipt
from test_media_preparations_api import create_preparation


class Backend:
    def __init__(self):
        self.calls = []
        self.applies = 0
        self.results = [
            StepReceipt('0' * 32, 'create_container', 'succeeded', 'container_created', '1' * 64),
            StepReceipt('0' * 32, 'start_container', 'succeeded', 'container_started', '1' * 64),
        ]

    def apply(self, step, component):
        self.calls.append((step, component))
        result = self.results[self.applies]
        self.applies += 1
        return replace(result, job_id=step.job_id)

    def reconcile(self, step, component):
        self.calls.append((step, component, 'reconcile'))
        return StepReceipt(step.job_id, step.kind, 'succeeded', 'container_created', '1' * 64)


def stack(server):
    pair = __import__('conftest').ready(server)
    return create_preparation(server[1], pair)[1]['plan']


def test_builder_selects_only_trusted_jellyfin_child_and_has_no_docker_payload(server):
    plan = stack(server)
    execution = build_execution(plan, job_id='a' * 32, deadline=1788609900)
    assert execution.service_id == 'jellyfin'
    assert [step.kind for step in execution.steps] == ['create_container', 'start_container']
    assert execution.operation_id == next(
        item['operationId'] for item in plan['components'] if item['serviceId'] == 'jellyfin')
    wire = execution.public()
    assert set(wire) == {'serviceId', 'operationId', 'steps'}
    assert all(set(step) == {'stepId', 'kind'} for step in wire['steps'])
    assert 'Image' not in repr(wire) and 'HostConfig' not in repr(wire)


@pytest.mark.parametrize('field', ['service_id', 'job_id', 'deadline'])
def test_builder_rejects_caller_selected_effects(server, field):
    values = {'service_id': 'sonarr', 'job_id': 'x' * 32, 'deadline': float('nan')}
    arguments = {'job_id': 'a' * 32, 'deadline': 1788609900}
    arguments[field] = values[field]
    with pytest.raises(InstallationExecutionError, match='^invalid_execution_request$'):
        build_execution(stack(server), **arguments)


def test_authority_and_cancellation_are_rechecked_before_every_effect(server):
    execution = build_execution(stack(server), job_id='a' * 32, deadline=1788609900)
    backend = Backend()
    gates = iter([ExecutionGateResult.allowed(), ExecutionGateResult.denied('authority_changed')])
    result = execution.run(backend, lambda: next(gates))
    assert result.state == 'needs_attention' and result.code == 'authority_changed'
    assert [call[0].kind for call in backend.calls] == ['create_container']


def test_uncertain_create_is_reconciled_without_reissuing_effect(server):
    execution = build_execution(stack(server), job_id='a' * 32, deadline=1788609900)
    backend = Backend()
    backend.results[0] = StepReceipt('0' * 32, 'create_container', 'uncertain',
                                     'engine_operation_uncertain')
    result = execution.run(backend, ExecutionGateResult.allowed)
    assert result.state == 'succeeded' and result.code == 'container_started'
    assert [call[0].kind for call in backend.calls] == ['create_container', 'create_container', 'start_container']
    assert backend.calls[1][2] == 'reconcile'


@pytest.mark.parametrize('state,code', [
    ('needs_attention', 'resource_conflict'),
    ('prepared', 'accepted'),
    ('mutating', 'engine_operation_pending'),
])
def test_nonterminal_worker_receipts_never_advance_to_start(server, state, code):
    execution = build_execution(stack(server), job_id='a' * 32, deadline=1788609900)
    backend = Backend()
    backend.results[0] = StepReceipt('0' * 32, 'create_container', state, code)
    result = execution.run(backend, ExecutionGateResult.allowed)
    assert result.state == ('needs_attention' if state == 'needs_attention' else 'pending')
    assert [call[0].kind for call in backend.calls] == ['create_container']


def test_execution_constructor_is_not_a_public_raw_command_surface(server):
    execution = build_execution(stack(server), job_id='a' * 32, deadline=1788609900)
    with pytest.raises(TypeError):
        InstallationExecution(**execution.__dict__ | {'docker': {'Privileged': True}})


def test_forged_worker_receipt_cannot_advance_the_execution(server):
    execution = build_execution(stack(server), job_id='a' * 32, deadline=1788609900)
    backend = Backend()
    backend.results[0] = StepReceipt('f' * 32, 'start_container', 'succeeded',
                                     'container_started', '1' * 64)
    result = execution.run(backend, ExecutionGateResult.allowed)
    assert result.state == 'failed' and result.code == 'invalid_worker_result'
    assert len(backend.calls) == 1


def test_worker_bridge_reverifies_component_and_builds_binding_internally(server):
    execution = build_execution(stack(server), job_id='a' * 32, deadline=1788609900)
    calls = []
    class Operations:
        def apply(self, step, binding):
            calls.append((step, binding))
            return StepReceipt(step.job_id, step.kind, 'succeeded', 'container_created', '1' * 64)
        def reconcile(self, job, kind):
            calls.append((job, kind))
            return StepReceipt(job, kind, 'succeeded', 'container_created', '1' * 64)
    sentinel = object()
    bridge = JellyfinWorkerBackend(Operations(), lambda component: sentinel)
    receipt = bridge.apply(execution.steps[0], execution.component)
    assert receipt.state == 'succeeded' and calls == [(execution.steps[0], sentinel)]
    forged = execution.component.model_copy(update={'serviceId': 'sonarr'})
    with pytest.raises(InstallationExecutionError, match='^invalid_execution_request$'):
        bridge.apply(execution.steps[0], forged)
    assert len(calls) == 1
