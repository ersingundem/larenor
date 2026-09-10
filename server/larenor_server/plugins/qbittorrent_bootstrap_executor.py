"""Worker-private qBittorrent category wiring and authenticated readback."""

from dataclasses import dataclass, field
import math
import re
import time

from pydantic import ValidationError

from .catalog import load_catalog
from .managed_container import (
    JournaledManagedContainerOperations, ManagedContainerBinding,
    ManagedContainerError,
)
from .qbittorrent_authenticated_readback import (
    QbittorrentAuthenticatedReadback,
    QbittorrentAuthenticatedReadbackError,
    QbittorrentAuthenticatedReadbackLimits,
    QbittorrentAuthenticatedReadbackResult,
)
from .qbittorrent_config_models import PrivateQbittorrentConfiguration
from .qbittorrent_endpoint import (
    QbittorrentEndpointError, open_qbittorrent_endpoint,
    prove_qbittorrent_endpoint,
)
from .qbittorrent_managed_categories import (
    QbittorrentManagedCategories, QbittorrentManagedCategoriesError,
    QbittorrentManagedCategoriesLimits, QbittorrentManagedCategoriesResult,
)
from .stack_plan import MediaStackPlan, verify_media_stack_plan
from .worker import DockerWorkerError, StepReceipt


_JOB = re.compile(r'[0-9a-f]{32}\Z')
_CATEGORIES = (
    ('movies', '/data/downloads/movies'),
    ('tv', '/data/downloads/tv'),
)
_CODES = frozenset({
    'invalid_qbittorrent_bootstrap_execution',
    'qbittorrent_bootstrap_authority_changed',
    'qbittorrent_bootstrap_resources_unavailable',
    'qbittorrent_bootstrap_endpoint_unavailable',
    'qbittorrent_bootstrap_endpoint_changed',
    'qbittorrent_bootstrap_categories_failed',
    'qbittorrent_bootstrap_readback_failed',
    'qbittorrent_bootstrap_timeout',
})
_BOUNDARIES = frozenset({
    'before_connect', 'after_categories_connect', 'after_categories',
    'after_readback_connect', 'after_readback',
})
_CAUSE_CODES = frozenset({
    'invalid_qbittorrent_categories',
    'qbittorrent_categories_authentication_failed',
    'qbittorrent_categories_protocol',
    'qbittorrent_category_conflict',
    'qbittorrent_categories_unavailable',
    'qbittorrent_categories_timeout',
    'invalid_qbittorrent_authenticated_readback',
    'qbittorrent_authentication_failed',
    'qbittorrent_readback_protocol',
    'qbittorrent_readback_mismatch',
    'qbittorrent_authenticated_readback_unavailable',
    'qbittorrent_authenticated_readback_timeout',
    'qbittorrent_bootstrap_binding_invalid_installation_plan',
    'qbittorrent_bootstrap_binding_resources_unavailable',
    'qbittorrent_bootstrap_binding_resources_untrusted',
    'qbittorrent_bootstrap_proof_plan_failed',
    'qbittorrent_bootstrap_proof_journal_bind_failed',
    'qbittorrent_bootstrap_proof_image_observation_failed',
    'qbittorrent_bootstrap_proof_volume_observation_failed',
    'qbittorrent_bootstrap_proof_volume_bootstrap_failed',
    'qbittorrent_bootstrap_proof_network_list_failed',
    'qbittorrent_bootstrap_proof_network_observation_failed',
    'qbittorrent_bootstrap_proof_journal_rebind_failed',
    'qbittorrent_bootstrap_proof_result_failed',
    'qbittorrent_bootstrap_unexpected',
})
_CATEGORY_STEPS = frozenset({
    (), ('categories_observed',),
    ('categories_observed', 'categories_verified'),
    ('categories_observed', 'movies_created'),
    ('categories_observed', 'movies_created', 'categories_verified'),
    ('categories_observed', 'tv_created'),
    ('categories_observed', 'tv_created', 'categories_verified'),
    ('categories_observed', 'movies_created', 'tv_created'),
    ('categories_observed', 'movies_created', 'tv_created',
     'categories_verified'),
})
_READBACK_STEPS = frozenset({
    (), ('version_verified',),
    ('version_verified', 'preferences_verified', 'categories_verified'),
})


class QbittorrentBootstrapExecutionError(Exception):
    def __init__(self, code='qbittorrent_bootstrap_resources_unavailable', *,
                 uncertain_effect=False, boundary=None, cause_code=None,
                 category_steps=(), readback_steps=()):
        self.code = code if code in _CODES else 'qbittorrent_bootstrap_resources_unavailable'
        self.uncertain_effect = uncertain_effect is True
        self.boundary = boundary if boundary in _BOUNDARIES else None
        self.cause_code = cause_code if cause_code in _CAUSE_CODES else None
        try:
            category_steps = tuple(category_steps)
        except (TypeError, RecursionError):
            category_steps = ()
        self.category_steps = (category_steps if category_steps in _CATEGORY_STEPS
                               else ())
        try:
            readback_steps = tuple(readback_steps)
        except (TypeError, RecursionError):
            readback_steps = ()
        self.readback_steps = (readback_steps if readback_steps in _READBACK_STEPS
                               else ())
        super().__init__(self.code)

    def __repr__(self):
        return (f'QbittorrentBootstrapExecutionError({self.code!r}, '
                f'uncertain_effect={self.uncertain_effect!r}, '
                f'boundary={self.boundary!r}, cause_code={self.cause_code!r}, '
                f'category_steps={len(self.category_steps)}, '
                f'readback_steps={len(self.readback_steps)})')


@dataclass(frozen=True, repr=False)
class QbittorrentBootstrapExecutionResult:
    state: str
    categories: QbittorrentManagedCategoriesResult = field(repr=False)
    readback: QbittorrentAuthenticatedReadbackResult = field(repr=False)

    def __post_init__(self):
        if (self.state != 'verified'
                or type(self.categories) is not QbittorrentManagedCategoriesResult
                or self.categories.state != 'verified'
                or self.categories.categories != _CATEGORIES
                or self.categories.completed_steps not in _CATEGORY_STEPS
                or self.categories.completed_steps[-1:] != ('categories_verified',)
                or type(self.readback) is not QbittorrentAuthenticatedReadbackResult
                or self.readback.state != 'verified'
                or self.readback.version != 'v5.2.3'
                or self.readback.settings.categories != _CATEGORIES
                or self.readback.completed_steps != (
                    'version_verified', 'preferences_verified',
                    'categories_verified')):
            raise QbittorrentBootstrapExecutionError(
                'qbittorrent_bootstrap_readback_failed',
                uncertain_effect=True)

    def __repr__(self):
        return 'QbittorrentBootstrapExecutionResult(<private>)'


def _remaining(deadline):
    value = deadline - time.monotonic()
    if value <= 0:
        raise QbittorrentBootstrapExecutionError(
            'qbittorrent_bootstrap_timeout')
    return value


class QbittorrentBootstrapExecutor:
    """Wire and verify one exact started qBittorrent container.

    Only the initial read-only TCP readiness check is retried. Every retry
    revalidates authority and the same journal-bound private endpoint.
    """

    def __init__(self, operations, binding_builder, categories, readback):
        if (type(operations) is not JournaledManagedContainerOperations
                or not callable(binding_builder)
                or type(categories) is not QbittorrentManagedCategories
                or type(readback) is not QbittorrentAuthenticatedReadback):
            raise QbittorrentBootstrapExecutionError(
                'invalid_qbittorrent_bootstrap_execution')
        self.operations = operations
        self.binding_builder = binding_builder
        self.categories = categories
        self.readback = readback

    @staticmethod
    def _gate(gate, *, uncertain=False):
        try:
            if gate() is not True:
                raise ValueError()
        except Exception:
            raise QbittorrentBootstrapExecutionError(
                'qbittorrent_bootstrap_authority_changed',
                uncertain_effect=uncertain) from None

    @staticmethod
    def _inputs(job, stack, private, deadline, gate):
        now = time.monotonic()
        if (type(job) is not str or _JOB.fullmatch(job) is None
                or type(stack) is not MediaStackPlan
                or type(private) is not PrivateQbittorrentConfiguration
                or type(deadline) not in (int, float)
                or not math.isfinite(deadline)
                or not now < deadline <= now + 120 or not callable(gate)):
            raise QbittorrentBootstrapExecutionError(
                'invalid_qbittorrent_bootstrap_execution')
        try:
            trusted = verify_media_stack_plan(stack, load_catalog())
            secret = PrivateQbittorrentConfiguration.model_validate(
                private.model_dump(mode='python'))
            component = next(item for item in trusted.components
                             if item.serviceId == 'qbittorrent')
            settings = {item.name: item.value for item in component.plan.settings}
            if (set(settings) != {
                    'dataRootId', 'instanceName', 'libraryRootId',
                    'torrentPort', 'webPort'}
                    or type(settings['webPort']) is not int
                    or type(settings['torrentPort']) is not int):
                raise ValueError()
            return trusted, secret, settings['webPort'], settings['torrentPort']
        except (ValidationError, ValueError, TypeError, AttributeError,
                KeyError, StopIteration):
            raise QbittorrentBootstrapExecutionError(
                'invalid_qbittorrent_bootstrap_execution') from None

    @staticmethod
    def _receipt(value, job):
        if (type(value) is not StepReceipt or value.job_id != job
                or value.step != 'start_container' or value.state != 'succeeded'
                or value.code != 'container_started'
                or type(value.container_id) is not str
                or re.fullmatch(r'[0-9a-f]{64}', value.container_id) is None):
            raise QbittorrentBootstrapExecutionError(
                'qbittorrent_bootstrap_resources_unavailable')
        return value

    def _open_ready(self, observed, binding, trusted, receipt, expected, *,
                    deadline, gate, uncertain):
        """Retry only a refused read-only connect while authority stays exact."""
        while True:
            self._gate(gate, uncertain=uncertain)
            try:
                return open_qbittorrent_endpoint(
                    observed, binding, trusted, receipt.container_id,
                    timeout=min(10.0, _remaining(deadline)))
            except QbittorrentEndpointError as error:
                if error.code != 'qbittorrent_endpoint_unavailable':
                    raise
                time.sleep(min(0.1, _remaining(deadline)))
                observed = self.operations.engine.inspect_container(binding.name)
                current = prove_qbittorrent_endpoint(
                    observed, binding, trusted, receipt.container_id)
                if current != expected:
                    raise QbittorrentBootstrapExecutionError(
                        'qbittorrent_bootstrap_endpoint_changed',
                        uncertain_effect=uncertain,
                        boundary='before_connect')

    def execute(self, job, stack, private, *, deadline, gate):
        trusted, secret, web_port, torrent_port = self._inputs(
            job, stack, private, deadline, gate)
        categories_opened = readback_opened = None
        categories_called = readback_called = False
        category_result = None
        boundary = 'before_connect'
        self._gate(gate)
        try:
            binding = self.binding_builder(trusted, 'qbittorrent')
            if type(binding) is not ManagedContainerBinding:
                raise ValueError()
            receipt = self._receipt(
                self.operations.reconcile(job, 'start_container', binding), job)
            _remaining(deadline)
            observed = self.operations.engine.inspect_container(binding.name)
            before = prove_qbittorrent_endpoint(
                observed, binding, trusted, receipt.container_id)
            categories_opened = self._open_ready(
                observed, binding, trusted, receipt, before,
                deadline=deadline, gate=gate, uncertain=False)
            boundary = 'after_categories_connect'
            observed = self.operations.engine.inspect_container(binding.name)
            after_connect = prove_qbittorrent_endpoint(
                observed, binding, trusted, receipt.container_id)
            if after_connect != before or categories_opened.proof != before:
                raise QbittorrentBootstrapExecutionError(
                    'qbittorrent_bootstrap_endpoint_changed', boundary=boundary)
            self._gate(gate)
            categories_called = True
            category_result = self.categories.apply(
                categories_opened.connection, api_key=secret.apiKey,
                limits=QbittorrentManagedCategoriesLimits(
                    total_seconds=min(30.0, _remaining(deadline)),
                    max_response_bytes=262144))
            boundary = 'after_categories'
            if (type(category_result) is not QbittorrentManagedCategoriesResult
                    or category_result.state != 'verified'
                    or category_result.categories != _CATEGORIES
                    or category_result.completed_steps[-1:] !=
                    ('categories_verified',)):
                raise QbittorrentBootstrapExecutionError(
                    'qbittorrent_bootstrap_categories_failed',
                    uncertain_effect=True, boundary=boundary)
            observed = self.operations.engine.inspect_container(binding.name)
            after_categories = prove_qbittorrent_endpoint(
                observed, binding, trusted, receipt.container_id)
            if after_categories != before:
                raise QbittorrentBootstrapExecutionError(
                    'qbittorrent_bootstrap_endpoint_changed',
                    uncertain_effect=True, boundary=boundary)
            readback_opened = self._open_ready(
                observed, binding, trusted, receipt, before,
                deadline=deadline, gate=gate, uncertain=True)
            boundary = 'after_readback_connect'
            observed = self.operations.engine.inspect_container(binding.name)
            after_readback_connect = prove_qbittorrent_endpoint(
                observed, binding, trusted, receipt.container_id)
            if (after_readback_connect != before
                    or readback_opened.proof != before):
                raise QbittorrentBootstrapExecutionError(
                    'qbittorrent_bootstrap_endpoint_changed',
                    uncertain_effect=True, boundary=boundary)
            self._gate(gate, uncertain=True)
            readback_called = True
            verified = self.readback.read(
                readback_opened.connection, api_key=secret.apiKey,
                web_port=web_port, torrent_port=torrent_port,
                limits=QbittorrentAuthenticatedReadbackLimits(
                    total_seconds=min(30.0, _remaining(deadline)),
                    max_response_bytes=262144))
            boundary = 'after_readback'
            if (type(verified) is not QbittorrentAuthenticatedReadbackResult
                    or verified.state != 'verified'
                    or verified.version != 'v5.2.3'
                    or verified.settings.categories != _CATEGORIES
                    or verified.completed_steps != (
                        'version_verified', 'preferences_verified',
                        'categories_verified')):
                raise QbittorrentBootstrapExecutionError(
                    'qbittorrent_bootstrap_readback_failed',
                    uncertain_effect=True, boundary=boundary)
            observed = self.operations.engine.inspect_container(binding.name)
            after_readback = prove_qbittorrent_endpoint(
                observed, binding, trusted, receipt.container_id)
            if after_readback != before:
                raise QbittorrentBootstrapExecutionError(
                    'qbittorrent_bootstrap_endpoint_changed',
                    uncertain_effect=True, boundary=boundary)
            self._gate(gate, uncertain=True)
            _remaining(deadline)
            return QbittorrentBootstrapExecutionResult(
                'verified', category_result, verified)
        except QbittorrentBootstrapExecutionError:
            raise
        except QbittorrentManagedCategoriesError as error:
            raise QbittorrentBootstrapExecutionError(
                'qbittorrent_bootstrap_categories_failed',
                uncertain_effect=error.uncertain_effect,
                boundary=boundary, cause_code=error.code,
                category_steps=error.completed_steps) from None
        except QbittorrentAuthenticatedReadbackError as error:
            raise QbittorrentBootstrapExecutionError(
                'qbittorrent_bootstrap_readback_failed',
                uncertain_effect=True, boundary=boundary,
                cause_code=error.code,
                category_steps=(() if category_result is None
                                else category_result.completed_steps),
                readback_steps=error.completed_steps) from None
        except QbittorrentEndpointError as error:
            code = ('qbittorrent_bootstrap_timeout'
                    if time.monotonic() >= deadline
                    else 'qbittorrent_bootstrap_endpoint_unavailable'
                    if error.code == 'qbittorrent_endpoint_unavailable'
                    else 'qbittorrent_bootstrap_endpoint_changed')
            raise QbittorrentBootstrapExecutionError(
                code, uncertain_effect=category_result is not None,
                boundary=boundary) from None
        except ManagedContainerError as error:
            cause = {
                'invalid_installation_plan':
                    'qbittorrent_bootstrap_binding_invalid_installation_plan',
                'resources_unavailable':
                    'qbittorrent_bootstrap_binding_resources_unavailable',
                'resources_untrusted':
                    'qbittorrent_bootstrap_binding_resources_untrusted',
            }.get(error.code)
            proof_cause = {
                'resource_proof_plan_failed':
                    'qbittorrent_bootstrap_proof_plan_failed',
                'resource_proof_journal_bind_failed':
                    'qbittorrent_bootstrap_proof_journal_bind_failed',
                'resource_proof_image_observation_failed':
                    'qbittorrent_bootstrap_proof_image_observation_failed',
                'resource_proof_volume_observation_failed':
                    'qbittorrent_bootstrap_proof_volume_observation_failed',
                'resource_proof_volume_bootstrap_failed':
                    'qbittorrent_bootstrap_proof_volume_bootstrap_failed',
                'resource_proof_network_list_failed':
                    'qbittorrent_bootstrap_proof_network_list_failed',
                'resource_proof_network_observation_failed':
                    'qbittorrent_bootstrap_proof_network_observation_failed',
                'resource_proof_journal_rebind_failed':
                    'qbittorrent_bootstrap_proof_journal_rebind_failed',
                'resource_proof_result_failed':
                    'qbittorrent_bootstrap_proof_result_failed',
            }.get(error.cause_code)
            raise QbittorrentBootstrapExecutionError(
                'qbittorrent_bootstrap_resources_unavailable',
                uncertain_effect=category_result is not None,
                boundary=boundary, cause_code=proof_cause or cause) from None
        except TimeoutError:
            raise QbittorrentBootstrapExecutionError(
                'qbittorrent_bootstrap_timeout',
                uncertain_effect=category_result is not None,
                boundary=boundary) from None
        except (DockerWorkerError, ValueError, TypeError, AttributeError,
                RuntimeError):
            code = ('qbittorrent_bootstrap_timeout'
                    if time.monotonic() >= deadline
                    else 'qbittorrent_bootstrap_resources_unavailable')
            raise QbittorrentBootstrapExecutionError(
                code, uncertain_effect=category_result is not None,
                boundary=boundary) from None
        except Exception:
            code = ('qbittorrent_bootstrap_timeout'
                    if time.monotonic() >= deadline
                    else 'qbittorrent_bootstrap_resources_unavailable')
            raise QbittorrentBootstrapExecutionError(
                code, uncertain_effect=category_result is not None,
                boundary=boundary,
                cause_code='qbittorrent_bootstrap_unexpected') from None
        finally:
            if categories_opened is not None and not categories_called:
                try:
                    categories_opened.connection.close()
                except OSError:
                    pass
            if readback_opened is not None and not readback_called:
                try:
                    readback_opened.connection.close()
                except OSError:
                    pass
