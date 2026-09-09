"""Worker-private journal, endpoint and Jellyfin startup orchestration."""

from dataclasses import dataclass, field
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
from .jellyfin_authenticated_readback import (
    JellyfinAuthenticatedReadback, JellyfinAuthenticatedReadbackError,
    JellyfinAuthenticatedReadbackLimits, JellyfinAuthenticatedReadbackResult,
)
from .managed_container import ManagedContainerBinding, JournaledManagedContainerOperations
from .media_service_bootstrap_models import PrivateMediaServiceBootstrap
from .stack_plan import MediaStackPlan, verify_media_stack_plan
from .catalog import load_catalog
from .worker import DockerWorkerError, StepReceipt


_JOB = re.compile(r'[0-9a-f]{32}\Z')
_CODES = frozenset({
    'invalid_bootstrap_execution', 'bootstrap_authority_changed',
    'bootstrap_resources_unavailable', 'bootstrap_endpoint_unavailable',
    'bootstrap_endpoint_changed',
    'bootstrap_startup_failed', 'bootstrap_readback_failed', 'bootstrap_timeout',
})
_BOUNDARIES = frozenset({
    'before_connect', 'after_connect', 'after_startup',
    'after_readback_connect', 'after_readback',
})
_CAUSE_CODES = frozenset({
    'invalid_jellyfin_startup_request', 'invalid_jellyfin_startup_limits',
    'jellyfin_startup_protocol', 'jellyfin_startup_unavailable',
    'jellyfin_startup_timeout', 'jellyfin_already_configured',
    'invalid_jellyfin_authenticated_readback',
    'jellyfin_authentication_failed',
    'jellyfin_authenticated_readback_protocol',
    'jellyfin_authenticated_readback_unavailable',
    'jellyfin_authenticated_readback_timeout',
    'jellyfin_session_cleanup_failed',
})
_READBACK_STEPS = frozenset({
    (),
    ('authenticated',),
    ('authenticated', 'keys_observed'),
    ('authenticated', 'keys_observed', 'key_created'),
    ('authenticated', 'keys_observed', 'key_created', 'key_verified'),
    ('authenticated', 'keys_observed', 'key_verified'),
    ('authenticated', 'keys_observed', 'key_created', 'key_verified',
     'system_verified'),
    ('authenticated', 'keys_observed', 'key_verified', 'system_verified'),
    ('authenticated', 'keys_observed', 'key_created', 'key_verified',
     'system_verified', 'libraries_verified'),
    ('authenticated', 'keys_observed', 'key_verified', 'system_verified',
     'libraries_verified'),
})


class JellyfinBootstrapExecutionError(Exception):
    def __init__(self, code='bootstrap_resources_unavailable', *, completed_steps=(),
                 uncertain_effect=False, boundary=None, cause_code=None,
                 readback_steps=()):
        self.code = code if code in _CODES else 'bootstrap_resources_unavailable'
        self.completed_steps = tuple(completed_steps)
        self.uncertain_effect = uncertain_effect is True
        self.boundary = boundary if boundary in _BOUNDARIES else None
        self.cause_code = cause_code if cause_code in _CAUSE_CODES else None
        try:
            readback_steps = tuple(readback_steps)
        except (TypeError, RecursionError):
            readback_steps = ()
        self.readback_steps = readback_steps if readback_steps in _READBACK_STEPS else ()
        super().__init__(self.code)

    def __repr__(self):
        return (f'JellyfinBootstrapExecutionError({self.code!r}, completed_steps='
                f'{len(self.completed_steps)}, uncertain_effect={self.uncertain_effect!r}, '
                f'boundary={self.boundary!r}, cause_code={self.cause_code!r}, '
                f'readback_steps={len(self.readback_steps)})')


@dataclass(frozen=True, repr=False)
class JellyfinBootstrapExecutionResult:
    state: str
    completed_steps: tuple[str, ...]
    readback: JellyfinAuthenticatedReadbackResult = field(repr=False)

    def __repr__(self):
        return 'JellyfinBootstrapExecutionResult(<private>)'


def _remaining(deadline):
    value = deadline - time.monotonic()
    if value <= 0:
        raise JellyfinBootstrapExecutionError('bootstrap_timeout')
    return value


class JellyfinBootstrapExecutor:
    """Run one no-retry bootstrap against the exact started journal receipt."""

    def __init__(self, operations, binding_builder, configurator, readback):
        if (type(operations) is not JournaledManagedContainerOperations
                or not callable(binding_builder)
                or type(configurator) is not JellyfinStartupConfigurator
                or type(readback) is not JellyfinAuthenticatedReadback):
            raise JellyfinBootstrapExecutionError('invalid_bootstrap_execution')
        self.operations = operations
        self.binding_builder = binding_builder
        self.configurator = configurator
        self.readback = readback

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
        readback_opened = None
        startup_called = False
        readback_called = False
        completed = ()
        boundary = 'before_connect'
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
            boundary = 'after_connect'
            observed = self.operations.engine.inspect_container(binding.name)
            after_connect = prove_jellyfin_endpoint(
                observed, binding, trusted, receipt.container_id)
            if after_connect != before or opened.proof != before:
                raise JellyfinBootstrapExecutionError(
                    'bootstrap_endpoint_changed', boundary=boundary)
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
            boundary = 'after_startup'
            observed = self.operations.engine.inspect_container(binding.name)
            after_startup = prove_jellyfin_endpoint(
                observed, binding, trusted, receipt.container_id)
            if after_startup != before:
                raise JellyfinBootstrapExecutionError(
                    'bootstrap_endpoint_changed', completed_steps=completed,
                    uncertain_effect=True, boundary=boundary,
                )
            self._gate(gate)
            _remaining(deadline)
            readback_opened = open_jellyfin_endpoint(
                observed, binding, trusted, receipt.container_id,
                timeout=min(10.0, _remaining(deadline)),
            )
            boundary = 'after_readback_connect'
            observed = self.operations.engine.inspect_container(binding.name)
            after_readback_connect = prove_jellyfin_endpoint(
                observed, binding, trusted, receipt.container_id)
            if after_readback_connect != before or readback_opened.proof != before:
                raise JellyfinBootstrapExecutionError(
                    'bootstrap_endpoint_changed', completed_steps=completed,
                    uncertain_effect=True, boundary=boundary,
                )
            self._gate(gate)
            readback_called = True
            verified = self.readback.read(
                readback_opened.connection,
                secret,
                device_id=job,
                limits=JellyfinAuthenticatedReadbackLimits(
                    total_seconds=min(30.0, _remaining(deadline)),
                    max_response_bytes=262144,
                ),
            )
            boundary = 'after_readback'
            if (type(verified) is not JellyfinAuthenticatedReadbackResult
                    or verified.state != 'verified'
                    or verified.completed_steps[-3:] != (
                        'system_verified', 'libraries_verified', 'session_closed')):
                raise JellyfinBootstrapExecutionError(
                    'bootstrap_readback_failed', completed_steps=completed,
                    uncertain_effect=True,
                )
            observed = self.operations.engine.inspect_container(binding.name)
            after_readback = prove_jellyfin_endpoint(
                observed, binding, trusted, receipt.container_id)
            if after_readback != before:
                raise JellyfinBootstrapExecutionError(
                    'bootstrap_endpoint_changed', completed_steps=completed,
                    uncertain_effect=True, boundary=boundary,
                )
            self._gate(gate)
            _remaining(deadline)
            return JellyfinBootstrapExecutionResult(
                'wiring_partial', completed, verified,
            )
        except JellyfinBootstrapExecutionError as error:
            if startup_called and not error.completed_steps:
                raise JellyfinBootstrapExecutionError(
                    error.code, completed_steps=completed,
                    uncertain_effect=error.uncertain_effect or bool(completed),
                    boundary=error.boundary,
                    cause_code=error.cause_code,
                    readback_steps=error.readback_steps,
                ) from None
            raise
        except JellyfinStartupError as error:
            raise JellyfinBootstrapExecutionError(
                'bootstrap_startup_failed', completed_steps=error.completed_steps,
                uncertain_effect=error.uncertain_effect,
                cause_code=error.code,
            ) from None
        except JellyfinAuthenticatedReadbackError as error:
            raise JellyfinBootstrapExecutionError(
                'bootstrap_readback_failed', completed_steps=completed,
                uncertain_effect=True,
                cause_code=error.code, readback_steps=error.completed_steps,
            ) from None
        except JellyfinEndpointError as error:
            if time.monotonic() >= deadline:
                code = 'bootstrap_timeout'
            elif error.code == 'jellyfin_endpoint_unavailable':
                code = 'bootstrap_endpoint_unavailable'
            else:
                code = 'bootstrap_endpoint_changed'
            raise JellyfinBootstrapExecutionError(
                code, completed_steps=completed,
                uncertain_effect=bool(completed), boundary=boundary,
            ) from None
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
            if readback_opened is not None and not readback_called:
                try:
                    readback_opened.connection.close()
                except OSError:
                    pass
