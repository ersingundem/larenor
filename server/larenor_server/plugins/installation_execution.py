"""Closed installation-step coordination for the first S06.4 component.

The API process may persist and schedule these values, but it never receives or
constructs Docker JSON.  A separately configured worker backend re-verifies the
packaged plan and owns the binding.  This module only sequences the existing
durable create/start primitives and asks the caller to recheck authority before
every worker interaction.
"""

from dataclasses import dataclass, field
import json
import math
import re
from typing import Literal

from .catalog import load_catalog, verify_plan
from .stack_plan import MediaStackPlan, verify_media_stack_plan
from .worker import StepReceipt, WorkerStep


_ID = re.compile(r'[0-9a-f]{32}\Z')
_KINDS = ('create_container', 'start_container')


class InstallationExecutionError(Exception):
    """A static error code; supplied plan fields are never formatted."""

    def __init__(self, code='invalid_execution_request'):
        self.code = code if code in {'invalid_execution_request', 'invalid_worker_result'} else 'invalid_execution_request'
        super().__init__(self.code)


@dataclass(frozen=True)
class ExecutionGateResult:
    permitted: bool
    code: str | None = None

    def __post_init__(self):
        valid = {'authority_changed', 'context_changed', 'preparation_changed',
                 'inspection_changed', 'catalog_changed', 'cancelled'}
        if type(self.permitted) is not bool or (self.permitted and self.code is not None) or (
                not self.permitted and self.code not in valid):
            raise InstallationExecutionError()

    @classmethod
    def allowed(cls):
        return cls(True)

    @classmethod
    def denied(cls, code):
        return cls(False, code)


@dataclass(frozen=True)
class ExecutionResult:
    state: Literal['succeeded', 'pending', 'needs_attention', 'cancelled', 'failed']
    code: str
    container_id: str | None = None


@dataclass(frozen=True)
class InstallationExecution:
    service_id: Literal['jellyfin']
    operation_id: str
    steps: tuple[WorkerStep, WorkerStep]
    plan: MediaStackPlan = field(repr=False)

    def __post_init__(self):
        if (self.service_id != 'jellyfin' or not _ID.fullmatch(self.operation_id)
                or type(self.steps) is not tuple or len(self.steps) != 2
                or type(self.plan) is not MediaStackPlan
                or tuple(step.kind for step in self.steps) != _KINDS
                or self.component.serviceId != self.service_id
                or self.component.operationId != self.operation_id
                or any(step.installation_id != self.component.installationId for step in self.steps)):
            raise InstallationExecutionError()

    @property
    def component(self):
        try:
            return next(item for item in self.plan.components if item.serviceId == self.service_id)
        except StopIteration:
            raise InstallationExecutionError() from None

    def public(self):
        return {'serviceId': self.service_id, 'operationId': self.operation_id,
                'steps': [{'stepId': step.dispatch_id, 'kind': step.kind} for step in self.steps]}

    @staticmethod
    def _gate(gate):
        try:
            result = gate()
        except Exception:
            return ExecutionGateResult.denied('authority_changed')
        if type(result) is not ExecutionGateResult:
            return ExecutionGateResult.denied('authority_changed')
        return result

    @staticmethod
    def _result(receipt):
        if type(receipt) is not StepReceipt:
            return ExecutionResult('failed', 'invalid_worker_result')
        if receipt.state == 'succeeded':
            return ExecutionResult('succeeded', receipt.code, receipt.container_id)
        if receipt.state == 'needs_attention':
            return ExecutionResult('needs_attention', receipt.code, receipt.container_id)
        if receipt.state in {'prepared', 'mutating', 'uncertain'}:
            return ExecutionResult('pending', receipt.code, receipt.container_id)
        return ExecutionResult('failed', 'invalid_worker_result')

    def run(self, backend, gate):
        """Run at most the two closed effects, with a fresh gate per call."""
        for step in self.steps:
            current = self._gate(gate)
            if not current.permitted:
                state = 'cancelled' if current.code == 'cancelled' else 'needs_attention'
                return ExecutionResult(state, current.code)
            try:
                receipt = backend.apply(step, self.plan)
            except Exception:
                return ExecutionResult('pending', 'worker_unavailable')
            if (type(receipt) is not StepReceipt or receipt.job_id != step.job_id
                    or receipt.step != step.kind):
                return ExecutionResult('failed', 'invalid_worker_result')
            result = self._result(receipt)
            if receipt.state == 'uncertain':
                current = self._gate(gate)
                if not current.permitted:
                    state = 'cancelled' if current.code == 'cancelled' else 'needs_attention'
                    return ExecutionResult(state, current.code)
                try:
                    receipt = backend.reconcile(step, self.plan)
                except Exception:
                    return ExecutionResult('pending', 'worker_unavailable')
                if (type(receipt) is not StepReceipt or receipt.job_id != step.job_id
                        or receipt.step != step.kind):
                    return ExecutionResult('failed', 'invalid_worker_result')
                result = self._result(receipt)
            if result.state != 'succeeded':
                return result
        return result


class JellyfinWorkerBackend:
    """Bridge a verified child plan to worker-owned binding construction.

    ``binding_builder`` is packaged worker policy, not a request callback. It
    resolves previously prepared resources and returns the internal binding
    accepted by ``JournaledContainerOperations``.
    """

    def __init__(self, operations, binding_builder):
        if not callable(binding_builder) or not callable(getattr(operations, 'apply', None)) or not callable(
                getattr(operations, 'reconcile', None)):
            raise InstallationExecutionError()
        self.operations, self.binding_builder = operations, binding_builder

    @staticmethod
    def _verify(step, plan):
        try:
            if type(step) is not WorkerStep or type(plan) is not MediaStackPlan:
                raise ValueError()
            current = verify_media_stack_plan(plan, load_catalog())
            component = next(item for item in current.components if item.serviceId == 'jellyfin')
            if (component.plan.serviceId != 'jellyfin'
                    or step.installation_id != component.installationId
                    or step.kind not in _KINDS):
                raise ValueError()
            expected = next(item for item in component.steps if item.kind == step.kind)
            if expected.stepId != step.dispatch_id:
                raise ValueError()
            verify_plan(component.plan, load_catalog())
            return current
        except (ValueError, TypeError, AttributeError, StopIteration):
            raise InstallationExecutionError() from None

    def apply(self, step, plan):
        trusted = self._verify(step, plan)
        try:
            binding = self.binding_builder(trusted)
            return self.operations.apply(step, binding)
        except InstallationExecutionError:
            raise
        except Exception:
            raise InstallationExecutionError('invalid_worker_result') from None

    def reconcile(self, step, plan):
        self._verify(step, plan)
        try:
            return self.operations.reconcile(step.job_id, step.kind)
        except Exception:
            raise InstallationExecutionError('invalid_worker_result') from None


def build_execution(plan, *, job_id, deadline, service_id='jellyfin'):
    """Re-derive the packaged plan and select the fixed first component."""
    try:
        if (service_id != 'jellyfin' or type(job_id) is not str or _ID.fullmatch(job_id) is None
                or type(deadline) not in (int, float) or not math.isfinite(deadline) or deadline <= 0):
            raise ValueError()
        if type(plan) is dict:
            plan = MediaStackPlan.model_validate_json(json.dumps(
                plan, sort_keys=True, separators=(',', ':'), allow_nan=False))
        if type(plan) is not MediaStackPlan:
            raise ValueError()
        verified = verify_media_stack_plan(plan, load_catalog())
        component = next(item for item in verified.components if item.serviceId == 'jellyfin')
        by_kind = {step.kind: step for step in component.steps}
        steps = tuple(WorkerStep(job_id, component.installationId, kind,
                                 by_kind[kind].stepId, deadline) for kind in _KINDS)
        return InstallationExecution('jellyfin', component.operationId, steps, verified)
    except (ValueError, TypeError, AttributeError, StopIteration):
        raise InstallationExecutionError() from None
