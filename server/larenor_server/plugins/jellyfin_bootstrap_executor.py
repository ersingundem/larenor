"""Worker-private journal, endpoint and Jellyfin startup orchestration."""

from dataclasses import dataclass
import math
import re
import time

from pydantic import ValidationError

from .jellyfin_endpoint import (
    JellyfinEndpointError, open_jellyfin_endpoint, prove_jellyfin_endpoint,
)
from .jellyfin_startup import (
    JellyfinStartupConfigurator, JellyfinStartupError, JellyfinStartupLimits,
    JellyfinStartupResult,
)
from .managed_container import ManagedContainerBinding, JournaledManagedContainerOperations
from .media_service_bootstrap_models import PrivateMediaServiceBootstrap
from .stack_plan import MediaStackPlan, verify_media_stack_plan
from .catalog import load_catalog
from .worker import DockerWorkerError, StepReceipt


_JOB = re.compile(r'[0-9a-f]{32}\Z')
_CODES = frozenset({
    'invalid_bootstrap_execution', 'bootstrap_authority_changed',
    'bootstrap_resources_unavailable', 'bootstrap_endpoint_changed',
    'bootstrap_startup_failed', 'bootstrap_timeout',
})


class JellyfinBootstrapExecutionError(Exception):
    def __init__(self, code='bootstrap_resources_unavailable', *, completed_steps=(),
                 uncertain_effect=False):
        self.code = code if code in _CODES else 'bootstrap_resources_unavailable'
        self.completed_steps = tuple(completed_steps)
        self.uncertain_effect = uncertain_effect is True
        super().__init__(self.code)

    def __repr__(self):
        return (f'JellyfinBootstrapExecutionError({self.code!r}, completed_steps='
                f'{len(self.completed_steps)}, uncertain_effect={self.uncertain_effect!r})')


@dataclass(frozen=True, repr=False)
class JellyfinBootstrapExecutionResult:
    state: str
    completed_steps: tuple[str, ...]

    def __repr__(self):
        return 'JellyfinBootstrapExecutionResult(<private>)'


def _remaining(deadline):
    value = deadline - time.monotonic()
    if value <= 0:
        raise JellyfinBootstrapExecutionError('bootstrap_timeout')
    return value


class JellyfinBootstrapExecutor:
    """Run one no-retry bootstrap against the exact started journal receipt."""

    def __init__(self, operations, binding_builder, configurator):
        if (type(operations) is not JournaledManagedContainerOperations
                or not callable(binding_builder)
                or type(configurator) is not JellyfinStartupConfigurator):
            raise JellyfinBootstrapExecutionError('invalid_bootstrap_execution')
        self.operations = operations
        self.binding_builder = binding_builder
        self.configurator = configurator

    @staticmethod
    def _gate(gate):
        try:
            if gate() is not True:
                raise ValueError()
        except Exception:
            raise JellyfinBootstrapExecutionError('bootstrap_authority_changed') from None

    @staticmethod
    def _inputs(job, stack, private, deadline, gate):
        now = time.monotonic()
        if (type(job) is not str or _JOB.fullmatch(job) is None
                or type(stack) is not MediaStackPlan
                or type(private) is not PrivateMediaServiceBootstrap
                or type(deadline) not in (int, float) or not math.isfinite(deadline)
                or not now < deadline <= now + 120 or not callable(gate)):
            raise JellyfinBootstrapExecutionError('invalid_bootstrap_execution')
        try:
            trusted = verify_media_stack_plan(stack, load_catalog())
            secret = PrivateMediaServiceBootstrap.model_validate(
                private.model_dump(mode='python'))
            return trusted, secret
        except (ValidationError, ValueError, TypeError, AttributeError):
            raise JellyfinBootstrapExecutionError('invalid_bootstrap_execution') from None

    @staticmethod
    def _receipt(value, job):
        if (type(value) is not StepReceipt or value.job_id != job
                or value.step != 'start_container' or value.state != 'succeeded'
                or value.code != 'container_started' or type(value.container_id) is not str
                or re.fullmatch(r'[0-9a-f]{64}', value.container_id) is None):
            raise JellyfinBootstrapExecutionError('bootstrap_resources_unavailable')
        return value

    def execute(self, job, stack, private, *, deadline, gate):
        trusted, secret = self._inputs(job, stack, private, deadline, gate)
        opened = None
        startup_called = False
        completed = ()
        self._gate(gate)
        try:
            binding = self.binding_builder(trusted)
            if type(binding) is not ManagedContainerBinding:
                raise ValueError()
            receipt = self._receipt(
                self.operations.reconcile(job, 'start_container', binding), job)
            _remaining(deadline)
            observed = self.operations.engine.inspect_container(binding.name)
            before = prove_jellyfin_endpoint(
                observed, binding, trusted, receipt.container_id)
            self._gate(gate)
            opened = open_jellyfin_endpoint(
                observed, binding, trusted, receipt.container_id,
                timeout=min(10.0, _remaining(deadline)),
            )
            observed = self.operations.engine.inspect_container(binding.name)
            after_connect = prove_jellyfin_endpoint(
                observed, binding, trusted, receipt.container_id)
            if after_connect != before or opened.proof != before:
                raise JellyfinBootstrapExecutionError('bootstrap_endpoint_changed')
            self._gate(gate)
            startup_called = True
            result = self.configurator.configure(
                opened.connection,
                secret,
                limits=JellyfinStartupLimits(
                    total_seconds=min(30.0, _remaining(deadline)),
                    max_response_bytes=4096,
                ),
            )
            if (type(result) is not JellyfinStartupResult or result.state != 'succeeded'
                    or result.completed_steps != (
                        'observed_unconfigured', 'configuration_updated', 'user_updated',
                        'remote_access_updated', 'wizard_completed')):
                raise JellyfinBootstrapExecutionError(
                    'bootstrap_startup_failed', uncertain_effect=True)
            completed = result.completed_steps
            observed = self.operations.engine.inspect_container(binding.name)
            after_startup = prove_jellyfin_endpoint(
                observed, binding, trusted, receipt.container_id)
            if after_startup != before:
                raise JellyfinBootstrapExecutionError(
                    'bootstrap_endpoint_changed', completed_steps=completed,
                    uncertain_effect=True,
                )
            self._gate(gate)
            _remaining(deadline)
            return JellyfinBootstrapExecutionResult('credentials_configured', completed)
        except JellyfinBootstrapExecutionError as error:
            if startup_called and not error.completed_steps:
                raise JellyfinBootstrapExecutionError(
                    error.code, completed_steps=completed,
                    uncertain_effect=error.uncertain_effect or bool(completed),
                ) from None
            raise
        except JellyfinStartupError as error:
            raise JellyfinBootstrapExecutionError(
                'bootstrap_startup_failed', completed_steps=error.completed_steps,
                uncertain_effect=error.uncertain_effect,
            ) from None
        except JellyfinEndpointError as error:
            code = ('bootstrap_timeout' if time.monotonic() >= deadline
                    else 'bootstrap_endpoint_changed')
            raise JellyfinBootstrapExecutionError(code, completed_steps=completed,
                                                   uncertain_effect=bool(completed)) from None
        except (DockerWorkerError, ValueError, TypeError, AttributeError, RuntimeError):
            code = ('bootstrap_timeout' if time.monotonic() >= deadline
                    else 'bootstrap_resources_unavailable')
            raise JellyfinBootstrapExecutionError(code, completed_steps=completed,
                                                   uncertain_effect=bool(completed)) from None
        finally:
            if opened is not None and not startup_called:
                try:
                    opened.connection.close()
                except OSError:
                    pass
