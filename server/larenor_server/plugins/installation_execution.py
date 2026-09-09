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

from .catalog import load_catalog
from .stack_plan import MediaStackComponent, MediaStackPlan, verify_media_stack_plan
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
    component: MediaStackComponent = field(repr=False)

    def __post_init__(self):
        if (self.service_id != 'jellyfin' or not _ID.fullmatch(self.operation_id)
                or type(self.steps) is not tuple or len(self.steps) != 2
                or type(self.component) is not MediaStackComponent
                or self.component.serviceId != self.service_id
                or self.component.operationId != self.operation_id
                or tuple(step.kind for step in self.steps) != _KINDS
                or any(step.installation_id != self.component.installationId for step in self.steps)):
            raise InstallationExecutionError()

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
                receipt = backend.apply(step, self.component)
            except Exception:
                return ExecutionResult('pending', 'worker_unavailable')
            result = self._result(receipt)
            if receipt.state == 'uncertain':
                current = self._gate(gate)
                if not current.permitted:
                    state = 'cancelled' if current.code == 'cancelled' else 'needs_attention'
                    return ExecutionResult(state, current.code)
                try:
                    receipt = backend.reconcile(step, self.component)
                except Exception:
                    return ExecutionResult('pending', 'worker_unavailable')
                result = self._result(receipt)
            if result.state != 'succeeded':
                return result
        return result


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
        return InstallationExecution('jellyfin', component.operationId, steps, component)
    except (ValueError, TypeError, AttributeError, StopIteration):
        raise InstallationExecutionError() from None
