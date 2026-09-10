"""Worker-private Sonarr/Radarr started-container verification."""

import math
import re
import time
from dataclasses import dataclass, field

from pydantic import ValidationError

from .arr_authenticated_readback import (
    ArrAuthenticatedReadback,
    ArrAuthenticatedReadbackError,
    ArrAuthenticatedReadbackLimits,
    ArrAuthenticatedReadbackResult,
)
from .arr_config_models import PrivateArrConfiguration
from .arr_endpoint import ArrEndpointError, open_arr_endpoint, prove_arr_endpoint
from .arr_managed_root_folders import (
    ArrManagedRootFolders, ArrManagedRootFoldersError,
    ArrManagedRootFoldersLimits, ArrManagedRootFoldersResult,
)
from .arr_managed_download_client import (
    ArrManagedDownloadClient, ArrManagedDownloadClientError,
    ArrManagedDownloadClientLimits,
)
from .catalog import load_catalog
from .managed_container import (
    JournaledManagedContainerOperations,
    ManagedContainerBinding,
    ManagedContainerError,
)
from .stack_plan import MediaStackPlan, verify_media_stack_plan
from .worker import DockerWorkerError, StepReceipt

_JOB = re.compile(r'[0-9a-f]{32}\Z')


class ArrBootstrapExecutionError(Exception):
    def __init__(
        self,
        code='arr_bootstrap_resources_unavailable',
        *,
        uncertain_effect=False,
        boundary=None,
        cause_code=None,
    ):
        self.code = (
            code
            if code
            in {
                'invalid_arr_bootstrap_execution',
                'arr_bootstrap_authority_changed',
                'arr_bootstrap_resources_unavailable',
                'arr_bootstrap_endpoint_unavailable',
                'arr_bootstrap_endpoint_changed',
                'arr_bootstrap_wiring_failed',
                'arr_bootstrap_readback_failed',
                'arr_bootstrap_timeout',
            }
            else 'arr_bootstrap_resources_unavailable'
        )
        self.uncertain_effect = uncertain_effect is True
        self.boundary = (
            boundary
            if boundary in {
                'before_connect', 'after_connect', 'after_readback',
                'after_wiring_connect', 'after_wiring',
            }
            else None
        )
        self.cause_code = (
            cause_code
            if cause_code
            in {
                'invalid_arr_authenticated_readback',
                'arr_authentication_failed',
                'arr_readback_protocol',
                'arr_readback_mismatch',
                'arr_authenticated_readback_unavailable',
                'arr_authenticated_readback_timeout',
                'invalid_arr_managed_root_folders',
                'arr_root_folders_authentication_failed',
                'arr_root_folders_observation_protocol',
                'arr_root_folders_observation_framing',
                'arr_root_folders_observation_http',
                'arr_root_folders_observation_closed',
                'arr_root_folders_observation_payload',
                'arr_root_folder_create_protocol',
                'arr_root_folders_verification_protocol',
                'arr_root_folder_conflict',
                'arr_root_folders_unavailable',
                'arr_root_folders_timeout',
                'invalid_arr_managed_download_client',
                'arr_download_client_authentication_failed',
                'arr_download_client_observation_protocol',
                'arr_download_client_observation_framing',
                'arr_download_client_observation_payload',
                'arr_download_client_schema_protocol',
                'arr_download_client_schema_conflict',
                'arr_download_client_test_protocol',
                'arr_download_client_test_failed',
                'arr_download_client_create_protocol',
                'arr_download_client_verification_protocol',
                'arr_download_client_conflict',
                'arr_download_client_unavailable',
                'arr_download_client_timeout',
                'arr_bootstrap_binding_invalid_installation_plan',
                'arr_bootstrap_binding_resources_unavailable',
                'arr_bootstrap_binding_resources_untrusted',
                'arr_bootstrap_proof_plan_failed',
                'arr_bootstrap_proof_journal_bind_failed',
                'arr_bootstrap_proof_image_observation_failed',
                'arr_bootstrap_proof_volume_observation_failed',
                'arr_bootstrap_proof_volume_bootstrap_failed',
                'arr_bootstrap_proof_network_list_failed',
                'arr_bootstrap_proof_network_observation_failed',
                'arr_bootstrap_proof_journal_rebind_failed',
                'arr_bootstrap_proof_result_failed',
                'arr_bootstrap_unexpected',
            }
            else None
        )
        super().__init__(self.code)

    def __repr__(self):
        return f'ArrBootstrapExecutionError({self.code!r}, uncertain_effect={self.uncertain_effect!r}, boundary={self.boundary!r}, cause_code={self.cause_code!r})'


@dataclass(frozen=True, repr=False)
class ArrBootstrapExecutionResult:
    state: str
    service_id: str
    root_folders: ArrManagedRootFoldersResult = field(repr=False)
    readback: ArrAuthenticatedReadbackResult = field(repr=False)

    def __post_init__(self):
        if (
            self.state != 'verified'
            or self.service_id not in {'sonarr', 'radarr'}
            or type(self.root_folders) is not ArrManagedRootFoldersResult
            or self.root_folders.state != 'verified'
            or self.root_folders.service_id != self.service_id
            or type(self.readback) is not ArrAuthenticatedReadbackResult
            or self.readback.state != 'verified'
            or self.readback.service_id != self.service_id
        ):
            raise ArrBootstrapExecutionError(
                'arr_bootstrap_readback_failed', uncertain_effect=True
            )

    def __repr__(self):
        return 'ArrBootstrapExecutionResult(<private>)'


def _remaining(deadline):
    value = deadline - time.monotonic()
    if value <= 0:
        raise ArrBootstrapExecutionError('arr_bootstrap_timeout')
    return value


class ArrBootstrapExecutor:
    def __init__(self, operations, binding_builder, root_folders, readback,
                 download_client=None):
        if (
            type(operations) is not JournaledManagedContainerOperations
            or not callable(binding_builder)
            or type(root_folders) is not ArrManagedRootFolders
            or type(readback) is not ArrAuthenticatedReadback
            or download_client is not None
            and type(download_client) is not ArrManagedDownloadClient
        ):
            raise ArrBootstrapExecutionError('invalid_arr_bootstrap_execution')
        self.operations = operations
        self.binding_builder = binding_builder
        self.root_folders = root_folders
        self.readback = readback
        self.download_client = download_client

    @staticmethod
    def _gate(gate, uncertain=False):
        try:
            if gate() is not True:
                raise ValueError()
        except Exception:
            raise ArrBootstrapExecutionError(
                'arr_bootstrap_authority_changed', uncertain_effect=uncertain
            ) from None

    def execute(self, job, stack, private, *, deadline, gate):
        now = time.monotonic()
        if (
            type(job) is not str
            or not _JOB.fullmatch(job)
            or type(stack) is not MediaStackPlan
            or type(private) is not PrivateArrConfiguration
            or type(deadline) not in (int, float)
            or not math.isfinite(deadline)
            or not now < deadline <= now + 120
            or not callable(gate)
        ):
            raise ArrBootstrapExecutionError('invalid_arr_bootstrap_execution')
        try:
            trusted = verify_media_stack_plan(stack, load_catalog())
            secret = PrivateArrConfiguration.model_validate(
                private.model_dump(mode='python')
            )
            next(x for x in trusted.components if x.serviceId == secret.serviceId)
        except (ValidationError, ValueError, TypeError, AttributeError, StopIteration):
            raise ArrBootstrapExecutionError(
                'invalid_arr_bootstrap_execution'
            ) from None
        opened = None
        called = False
        boundary = 'before_connect'
        self._gate(gate)
        try:
            binding = self.binding_builder(trusted, secret.serviceId)
            if type(binding) is not ManagedContainerBinding:
                raise ValueError()
            receipt = self.operations.reconcile(job, 'start_container', binding)
            if (
                type(receipt) is not StepReceipt
                or receipt.job_id != job
                or receipt.step != 'start_container'
                or receipt.state != 'succeeded'
                or receipt.code != 'container_started'
                or type(receipt.container_id) is not str
                or re.fullmatch(r'[0-9a-f]{64}', receipt.container_id) is None
            ):
                raise ValueError()
            observed = self.operations.engine.inspect_container(binding.name)
            proof = prove_arr_endpoint(
                observed, binding, trusted, receipt.container_id, secret.serviceId
            )
            while True:
                self._gate(gate)
                try:
                    opened = open_arr_endpoint(
                        observed,
                        binding,
                        trusted,
                        receipt.container_id,
                        secret.serviceId,
                        timeout=min(10.0, _remaining(deadline)),
                    )
                    break
                except ArrEndpointError as error:
                    if error.code != 'arr_endpoint_unavailable':
                        raise
                    time.sleep(min(0.1, _remaining(deadline)))
                    observed = self.operations.engine.inspect_container(binding.name)
                    current = prove_arr_endpoint(
                        observed,
                        binding,
                        trusted,
                        receipt.container_id,
                        secret.serviceId,
                    )
                    if current != proof:
                        raise ArrBootstrapExecutionError(
                            'arr_bootstrap_endpoint_changed', boundary='before_connect'
                        )
            boundary = 'after_connect'
            observed = self.operations.engine.inspect_container(binding.name)
            if (
                prove_arr_endpoint(
                    observed, binding, trusted, receipt.container_id, secret.serviceId
                )
                != proof
                or opened.proof != proof
            ):
                raise ArrBootstrapExecutionError(
                    'arr_bootstrap_endpoint_changed', boundary=boundary
                )
            self._gate(gate)
            limits = ArrAuthenticatedReadbackLimits(
                total_seconds=min(30.0, _remaining(deadline))
            )
            called = True
            verified = self.readback.read(
                opened.connection,
                service_id=secret.serviceId,
                api_key=secret.apiKey,
                limits=limits,
            )
            boundary = 'after_readback'
            observed = self.operations.engine.inspect_container(binding.name)
            if (
                prove_arr_endpoint(
                    observed, binding, trusted, receipt.container_id, secret.serviceId
                )
                != proof
            ):
                raise ArrBootstrapExecutionError(
                    'arr_bootstrap_endpoint_changed',
                    uncertain_effect=True,
                    boundary=boundary,
                )
            self._gate(gate, True)
            _remaining(deadline)
            opened = None
            called = False
            while True:
                self._gate(gate, True)
                try:
                    opened = open_arr_endpoint(
                        observed, binding, trusted, receipt.container_id,
                        secret.serviceId,
                        timeout=min(10.0, _remaining(deadline)),
                    )
                    break
                except ArrEndpointError as error:
                    if error.code != 'arr_endpoint_unavailable':
                        raise
                    time.sleep(min(0.1, _remaining(deadline)))
                    observed = self.operations.engine.inspect_container(binding.name)
                    current = prove_arr_endpoint(
                        observed, binding, trusted, receipt.container_id,
                        secret.serviceId,
                    )
                    if current != proof:
                        raise ArrBootstrapExecutionError(
                            'arr_bootstrap_endpoint_changed',
                            uncertain_effect=True, boundary='after_readback')
            boundary = 'after_wiring_connect'
            observed = self.operations.engine.inspect_container(binding.name)
            if (prove_arr_endpoint(
                    observed, binding, trusted, receipt.container_id,
                    secret.serviceId) != proof or opened.proof != proof):
                raise ArrBootstrapExecutionError(
                    'arr_bootstrap_endpoint_changed', uncertain_effect=True,
                    boundary=boundary)
            self._gate(gate, True)
            wiring_limits = ArrManagedRootFoldersLimits(
                total_seconds=min(30.0, _remaining(deadline)))
            called = True
            root_folders = self.root_folders.apply(
                opened.connection, service_id=secret.serviceId,
                api_key=secret.apiKey, limits=wiring_limits)
            if (self.download_client is not None
                    and secret.qbittorrentApiKey is not None):
                opened = None
                called = False
                self._gate(gate, True)
                opened = open_arr_endpoint(
                    observed, binding, trusted, receipt.container_id,
                    secret.serviceId,
                    timeout=min(10.0, _remaining(deadline)))
                boundary = 'after_wiring_connect'
                observed = self.operations.engine.inspect_container(binding.name)
                if (prove_arr_endpoint(
                        observed, binding, trusted, receipt.container_id,
                        secret.serviceId) != proof or opened.proof != proof):
                    raise ArrBootstrapExecutionError(
                        'arr_bootstrap_endpoint_changed',
                        uncertain_effect=True, boundary=boundary)
                self._gate(gate, True)
                called = True
                self.download_client.apply(
                    opened.connection, service_id=secret.serviceId,
                    arr_api_key=secret.apiKey,
                    qbittorrent_api_key=secret.qbittorrentApiKey,
                    limits=ArrManagedDownloadClientLimits(
                        total_seconds=min(30.0, _remaining(deadline))))
            boundary = 'after_wiring'
            observed = self.operations.engine.inspect_container(binding.name)
            if prove_arr_endpoint(
                    observed, binding, trusted, receipt.container_id,
                    secret.serviceId) != proof:
                raise ArrBootstrapExecutionError(
                    'arr_bootstrap_endpoint_changed', uncertain_effect=True,
                    boundary=boundary)
            self._gate(gate, True)
            _remaining(deadline)
            return ArrBootstrapExecutionResult(
                'verified', secret.serviceId, root_folders, verified)
        except ArrBootstrapExecutionError:
            raise
        except ArrAuthenticatedReadbackError as error:
            raise ArrBootstrapExecutionError(
                'arr_bootstrap_readback_failed',
                uncertain_effect=True,
                boundary=boundary,
                cause_code=error.code,
            ) from None
        except ArrManagedRootFoldersError as error:
            raise ArrBootstrapExecutionError(
                'arr_bootstrap_wiring_failed',
                uncertain_effect=error.uncertain_effect,
                boundary=boundary,
                cause_code=error.code,
            ) from None
        except ArrManagedDownloadClientError as error:
            raise ArrBootstrapExecutionError(
                'arr_bootstrap_wiring_failed',
                uncertain_effect=error.uncertain_effect,
                boundary=boundary, cause_code=error.code) from None
        except ArrEndpointError as error:
            code = (
                'arr_bootstrap_timeout'
                if time.monotonic() >= deadline
                else 'arr_bootstrap_endpoint_unavailable'
                if error.code == 'arr_endpoint_unavailable'
                else 'arr_bootstrap_endpoint_changed'
            )
            raise ArrBootstrapExecutionError(code, boundary=boundary) from None
        except ManagedContainerError as error:
            cause = {
                'invalid_installation_plan':
                    'arr_bootstrap_binding_invalid_installation_plan',
                'resources_unavailable':
                    'arr_bootstrap_binding_resources_unavailable',
                'resources_untrusted':
                    'arr_bootstrap_binding_resources_untrusted',
            }.get(error.code)
            proof_cause = {
                'resource_proof_plan_failed':
                    'arr_bootstrap_proof_plan_failed',
                'resource_proof_journal_bind_failed':
                    'arr_bootstrap_proof_journal_bind_failed',
                'resource_proof_image_observation_failed':
                    'arr_bootstrap_proof_image_observation_failed',
                'resource_proof_volume_observation_failed':
                    'arr_bootstrap_proof_volume_observation_failed',
                'resource_proof_volume_bootstrap_failed':
                    'arr_bootstrap_proof_volume_bootstrap_failed',
                'resource_proof_network_list_failed':
                    'arr_bootstrap_proof_network_list_failed',
                'resource_proof_network_observation_failed':
                    'arr_bootstrap_proof_network_observation_failed',
                'resource_proof_journal_rebind_failed':
                    'arr_bootstrap_proof_journal_rebind_failed',
                'resource_proof_result_failed':
                    'arr_bootstrap_proof_result_failed',
            }.get(error.cause_code)
            raise ArrBootstrapExecutionError(
                'arr_bootstrap_resources_unavailable', boundary=boundary,
                cause_code=proof_cause or cause) from None
        except (
            DockerWorkerError,
            ValueError,
            TypeError,
            AttributeError,
            RuntimeError,
        ):
            raise ArrBootstrapExecutionError(
                'arr_bootstrap_resources_unavailable',
                boundary=boundary,
                cause_code='arr_bootstrap_unexpected',
            ) from None
        except Exception:
            raise ArrBootstrapExecutionError(
                'arr_bootstrap_resources_unavailable',
                boundary=boundary,
                cause_code='arr_bootstrap_unexpected',
            ) from None
        finally:
            if opened is not None and not called:
                try:
                    opened.connection.close()
                except OSError:
                    pass
