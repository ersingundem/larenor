"""Internal Linux entry point for the bounded Larenor installation worker.

The API process receives only this worker's Unix socket.  Docker access,
resource journals, the managed-container journal and the exact bootstrap helper
remain private to this process.  The policy is operator-owned and has no
environment-variable or Client override for Docker operations.
"""

import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import signal
import stat
import sys
import threading
import time

from ..errors import StartupError
from ..files import checked_path, private_read
from .catalog import load_catalog
from .docker_probe import DockerEndpoint
from .host_preflight import _host_platform
from .installation_execution import (
    ArrWorkerBackend, ExecutionGateResult, ExecutionResult, JellyfinWorkerBackend,
    MusicAssistantWorkerBackend, QbittorrentWorkerBackend,
    SeerrWorkerBackend, build_execution,
    service_for_step,
)
from .installation_ipc import InstallationWorkerServer
from .music_provider_setup_runtime import MusicProviderSetupRuntime
from .music_playback_runtime import MusicPlaybackRuntime
from .music_assistant_bootstrap_runtime import MusicAssistantBootstrapRuntime
from .installation_supervisor import RetainedDaemonPeerVerifier, SupervisedInstallationBackend
from .jellyfin_bootstrap_executor import JellyfinBootstrapExecutor
from .jellyfin_startup import JellyfinStartupConfigurator
from .jellyfin_authenticated_readback import JellyfinAuthenticatedReadback
from .jellyfin_managed_libraries import JellyfinManagedLibraries
from .seerr_bootstrap_executor import SeerrBootstrapExecutor
from .seerr_initial_admin import SeerrInitialAdmin
from .arr_config_runtime import ArrConfigRuntime
from .arr_bootstrap_executor import (
    ArrBootstrapExecutionError, ArrBootstrapExecutor,
)
from .arr_authenticated_readback import ArrAuthenticatedReadback
from .arr_managed_root_folders import ArrManagedRootFolders
from .arr_managed_download_client import ArrManagedDownloadClient
from .arr_config_effect import ArrConfigInstallReceipt
from .arr_config_models import (
    ArrConfiguredInstallReceipt, ArrConfigurationExecutionError,
    PrivateArrConfiguration,
)
from .qbittorrent_config_runtime import (
    QbittorrentConfigRuntime, QbittorrentConfigRuntimeError,
)
from .qbittorrent_config_effect import (
    QbittorrentConfigEffectError, QbittorrentConfigInstallReceipt,
)
from .qbittorrent_bootstrap_executor import (
    QbittorrentBootstrapExecutionError, QbittorrentBootstrapExecutionResult,
    QbittorrentBootstrapExecutor,
)
from .qbittorrent_authenticated_readback import QbittorrentAuthenticatedReadback
from .qbittorrent_managed_categories import QbittorrentManagedCategories
from .qbittorrent_config_models import (
    PrivateQbittorrentConfiguration, QbittorrentConfiguredInstallReceipt,
    QbittorrentConfigurationExecutionError,
)
from .managed_container import (
    JellyfinBindingBuilder,
    JellyfinEngineReaders,
    JellyfinResourceProofBroker,
    JournaledManagedContainerOperations,
    ManagedWorkerJournal,
)
from .resource_journal import ResourceJournal
from .resource_models import WorkerPolicyBinding
from .volume_bootstrap import VolumeBootstrapVerifier
from .volume_create_journal import VolumeCreateJournal
from .worker import UnixDockerEngine, _safe_path


MAX_POLICY_BYTES = 32768
_IMAGE_ID = re.compile(r'sha256:[0-9a-f]{64}\Z')


class _ConfigurationError(ValueError):
    pass


class _ParserExit(Exception):
    def __init__(self, status):
        self.status = status


class _Parser(argparse.ArgumentParser):
    def error(self, _message):
        raise _ConfigurationError()

    def exit(self, status=0, message=None):
        raise _ParserExit(status)


def _uid(value):
    if not re.fullmatch(r'[0-9]{1,10}', value) or int(value) > 2**31 - 1:
        raise _ConfigurationError()
    return int(value)


def _pairs(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise _ConfigurationError()
        value[key] = item
    return value


def _reject_number(_value):
    raise _ConfigurationError()


def _private_path(value):
    if type(value) is not str:
        raise _ConfigurationError()
    result = Path(value)
    if (not result.is_absolute() or '..' in result.parts or len(value.encode('utf-8')) > 4096
            or any(ord(char) < 32 or ord(char) == 127 for char in value)):
        raise _ConfigurationError()
    checked_path(result)
    return result


@dataclass(frozen=True, repr=False)
class InstallationRuntimePolicy:
    platform: str
    endpoint: DockerEndpoint
    worker_policy: WorkerPolicyBinding
    helper_image_id: str
    resource_journal: Path
    volume_journal: Path
    container_journal: Path

    def __repr__(self):
        return 'InstallationRuntimePolicy(<private>)'


def load_policy(path):
    """Validate the private policy without opening a journal or Docker socket."""
    invalid = False
    result = None
    try:
        source = checked_path(Path(path))
        _safe_path(source, uid=os.geteuid(), kind=stat.S_ISREG, private=True)
        raw = private_read(source, MAX_POLICY_BYTES)
        value = json.loads(
            raw.decode('utf-8'),
            object_pairs_hook=_pairs,
            parse_float=_reject_number,
            parse_constant=_reject_number,
        )
        if (type(value) is not dict
                or set(value) != {'version', 'platform', 'docker', 'workerPolicy',
                                  'bootstrap', 'journals'}
                or type(value['version']) is not int or value['version'] != 1
                or value['platform'] not in {'linux/amd64', 'linux/arm64'}):
            raise _ConfigurationError()
        docker = value['docker']
        if type(docker) is not dict or set(docker) != {
                'socketPath', 'ownerUid', 'daemonExecutable'}:
            raise _ConfigurationError()
        endpoint = DockerEndpoint(
            path=docker['socketPath'],
            owner_uid=docker['ownerUid'],
            daemon_executable=docker['daemonExecutable'],
        )
        worker_policy = WorkerPolicyBinding.model_validate(value['workerPolicy'])
        bootstrap = value['bootstrap']
        if (type(bootstrap) is not dict or set(bootstrap) != {'imageId'}
                or type(bootstrap['imageId']) is not str
                or _IMAGE_ID.fullmatch(bootstrap['imageId']) is None):
            raise _ConfigurationError()
        journals = value['journals']
        if type(journals) is not dict or set(journals) != {
                'resources', 'volumes', 'containers'}:
            raise _ConfigurationError()
        paths = tuple(_private_path(journals[name]) for name in (
            'resources', 'volumes', 'containers'))
        if (len(set(paths)) != 3
                or any(left in right.parents or right in left.parents
                       for index, left in enumerate(paths)
                       for right in paths[index + 1:])):
            raise _ConfigurationError()
        result = InstallationRuntimePolicy(
            value['platform'], endpoint, worker_policy, bootstrap['imageId'], *paths,
        )
    except Exception:
        invalid = True
    if invalid or type(result) is not InstallationRuntimePolicy:
        raise _ConfigurationError()
    return result


class _RuntimeBindingBuilder:
    """Recreate a plan-bound proof broker for every IPC worker request."""

    def __init__(self, policy, catalog, resources, volumes, container, readers):
        self._policy = policy
        self._catalog = catalog
        self._resource_journal = resources
        self._volume_journal = volumes
        self._container_journal = container
        self._readers = readers
        self._endpoint = readers._endpoint

    def __call__(self, stack, service_id='jellyfin'):
        broker = JellyfinResourceProofBroker(
            stack,
            self._catalog,
            self._policy,
            self._resource_journal,
            self._volume_journal,
            self._readers,
            engine_identity=self._endpoint,
            service_id=service_id,
        )
        return JellyfinBindingBuilder(
            self._catalog,
            self._policy,
            self._container_journal.identity,
            broker,
            service_id=service_id,
        )(stack)


class _InstallationRuntime:
    def __init__(self, backend, resources, volumes, containers):
        self.backend = backend
        self._journals = (containers, volumes, resources)
        self.closed = False

    def close(self):
        if self.closed:
            return
        self.closed = True
        failed = False
        for journal in self._journals:
            try:
                journal.close()
            except Exception:
                failed = True
        if failed:
            raise RuntimeError('worker_unavailable')


class _RuntimeBackend:
    """One journal/binding authority for installation and private bootstrap."""

    def __init__(self, operations, binding_builder, qbittorrent_config,
                 arr_config):
        self.operations = operations
        self.binding_builder = binding_builder
        self.qbittorrent_config = qbittorrent_config
        self.arr_config = arr_config
        self.installation = JellyfinWorkerBackend(operations, binding_builder)
        self.qbittorrent_installation = QbittorrentWorkerBackend(
            operations, binding_builder)
        self.seerr_installation = SeerrWorkerBackend(
            operations, binding_builder)
        self.music_assistant_installation = MusicAssistantWorkerBackend(
            operations, binding_builder)
        self.qbittorrent_bootstrap = QbittorrentBootstrapExecutor(
            operations, binding_builder, QbittorrentManagedCategories(),
            QbittorrentAuthenticatedReadback())
        self.arr_bootstrap = ArrBootstrapExecutor(
            operations, binding_builder, ArrManagedRootFolders(),
            ArrAuthenticatedReadback(), ArrManagedDownloadClient())
        self.bootstrap_executor = JellyfinBootstrapExecutor(
            operations, binding_builder, JellyfinStartupConfigurator(),
            JellyfinAuthenticatedReadback(), JellyfinManagedLibraries())
        self.seerr_bootstrap = SeerrBootstrapExecutor(
            operations, binding_builder, SeerrInitialAdmin())
        self.music_assistant_bootstrap = MusicAssistantBootstrapRuntime()
        self.music_provider_setup = MusicProviderSetupRuntime()
        self.music_playback = MusicPlaybackRuntime()

    def apply(self, step, plan):
        service = service_for_step(step, plan)
        backend = (self.seerr_installation if service == 'seerr'
                   else self.music_assistant_installation
                   if service == 'music_assistant' else self.installation)
        return backend.apply(step, plan)

    def reconcile(self, step, plan):
        service = service_for_step(step, plan)
        backend = (self.seerr_installation if service == 'seerr'
                   else self.music_assistant_installation
                   if service == 'music_assistant' else self.installation)
        return backend.reconcile(step, plan)

    def execute_music_provider_setup(self, action, *, deadline, gate):
        if gate() is not True:
            raise ValueError('provider_setup_authority_changed')
        result = self.music_provider_setup.execute(action, deadline=deadline)
        if gate() is not True:
            raise ValueError('provider_setup_authority_changed')
        return result

    def read_music_players(self, authority, *, deadline, gate):
        if gate() is not True:
            raise ValueError('music_playback_authority_changed')
        result = self.music_playback.read(authority, deadline=deadline)
        if gate() is not True:
            raise ValueError('music_playback_authority_changed')
        return result

    def execute_music_playback(self, action, *, deadline, gate):
        if gate() is not True:
            raise ValueError('music_playback_authority_changed')
        result = self.music_playback.execute(action, deadline=deadline)
        if gate() is not True:
            raise ValueError('music_playback_authority_changed')
        return result

    def bootstrap(self, job, plan, private, *, deadline, gate):
        return self.bootstrap_executor.execute(
            job, plan, private, deadline=deadline, gate=gate)

    def bootstrap_seerr(self, job, plan, private, *, deadline, gate):
        return self.seerr_bootstrap.execute(
            job, plan, private, deadline=deadline, gate=gate)

    def bootstrap_music_assistant(self, installation_id, username, credential,
                                  *, deadline, gate):
        if gate() is not True:
            raise ValueError('music_assistant_bootstrap_authority_changed')
        result = self.music_assistant_bootstrap.create(
            installation_id=installation_id, username=username,
            credential=credential, deadline=deadline)
        if gate() is not True:
            raise ValueError('music_assistant_bootstrap_authority_changed')
        return result

    def configure_qbittorrent(self, job, stack, credential, *, api_key, salt,
                              cancelled, deadline, gate):
        if type(job) is not str or re.fullmatch(r'[0-9a-f]{32}', job) is None:
            raise ValueError('invalid_worker_result')
        return self.qbittorrent_config.install(
            stack, credential, api_key=api_key, salt=salt,
            cancelled=cancelled, before_dispatch=gate,
        )

    def configure_arr(self, job, stack, service_id, *, api_key, cancelled,
                      deadline, gate):
        if type(job) is not str or re.fullmatch(r'[0-9a-f]{32}', job) is None:
            raise ValueError('invalid_worker_result')
        return self.arr_config.install(
            stack, service_id, api_key=api_key, cancelled=cancelled,
            before_dispatch=gate,
        )

    def install_configured_arr(self, job, stack, service_id, *, api_key,
                               qbittorrent_api_key=None, cancelled, deadline,
                               gate):
        try:
            configured = self.configure_arr(
                job, stack, service_id, api_key=api_key,
                cancelled=cancelled, deadline=deadline, gate=gate)
        except ArrConfigurationExecutionError:
            raise
        except Exception:
            raise ArrConfigurationExecutionError(
                'arr_config_resources_unavailable',
                cause_code='arr_configure_stage_failed') from None
        if (type(configured) is not ArrConfigInstallReceipt
                or configured.service_id != service_id):
            raise ArrConfigurationExecutionError(
                'arr_config_result_invalid', uncertain_effect=True)

        def authority():
            try:
                return (ExecutionGateResult.allowed() if gate() is True
                        else ExecutionGateResult.denied('authority_changed'))
            except Exception:
                return ExecutionGateResult.denied('authority_changed')

        remaining = deadline - time.monotonic()
        if not 0 < remaining <= 120:
            raise ArrConfigurationExecutionError('arr_config_timeout')
        try:
            execution = build_execution(
                stack, job_id=job, deadline=time.time() + remaining,
                service_id=service_id)
            result = execution.run(
                ArrWorkerBackend(
                    self.operations, self.binding_builder, service_id),
                authority)
        except ArrConfigurationExecutionError:
            raise
        except Exception:
            raise ArrConfigurationExecutionError(
                'arr_config_result_invalid', uncertain_effect=True,
                cause_code='arr_execution_stage_failed') from None
        if (type(result) is not ExecutionResult or result.state != 'succeeded'
                or result.code != 'container_started'
                or result.container_id is None):
            result_key = (getattr(result, 'state', None),
                          getattr(result, 'code', None))
            authority_codes = {
                'authority_changed', 'context_changed', 'preparation_changed',
                'inspection_changed', 'catalog_changed', 'cancelled',
            }
            code = ('arr_config_authority_changed'
                    if type(result) is ExecutionResult
                    and result.code in authority_codes
                    else 'arr_config_resources_unavailable'
                    if type(result) is ExecutionResult
                    and (result.state == 'pending' or result.code in {
                        'resource_conflict', 'container_not_running',
                        'dispatch_expired',
                    })
                    else 'arr_config_result_invalid')
            cause = ({
                ('pending', 'worker_unavailable'):
                    'arr_execution_worker_unavailable',
                ('failed', 'invalid_worker_result'):
                    'arr_execution_invalid_worker_result',
                ('needs_attention', 'resource_conflict'):
                    'arr_execution_resource_conflict',
                ('needs_attention', 'container_not_running'):
                    'arr_execution_container_not_running',
                ('needs_attention', 'dispatch_expired'):
                    'arr_execution_dispatch_expired',
                ('cancelled', 'cancelled'): 'arr_execution_cancelled',
            }.get(result_key)
                     if type(result) is ExecutionResult else None)
            if cause is None and type(result) is ExecutionResult \
                    and result.code in authority_codes:
                cause = 'arr_execution_authority_changed'
            raise ArrConfigurationExecutionError(
                code, uncertain_effect=True, cause_code=cause)
        try:
            verified = self.arr_bootstrap.execute(
                job, stack, PrivateArrConfiguration(
                    serviceId=service_id, apiKey=api_key,
                    qbittorrentApiKey=qbittorrent_api_key),
                deadline=deadline, gate=gate)
        except ArrBootstrapExecutionError as error:
            code = {
                'arr_bootstrap_authority_changed':
                    'arr_config_authority_changed',
                'arr_bootstrap_timeout': 'arr_config_timeout',
                'arr_bootstrap_resources_unavailable':
                    'arr_config_resources_unavailable',
                'arr_bootstrap_endpoint_unavailable':
                    'arr_config_resources_unavailable',
            }.get(error.code, 'arr_config_result_invalid')
            cause = error.cause_code
            if cause == 'arr_bootstrap_unexpected' and error.boundary is not None:
                cause = f'arr_bootstrap_{error.boundary}_failed'
            if cause is None and error.code in {
                    'arr_bootstrap_authority_changed',
                    'arr_bootstrap_resources_unavailable',
                    'arr_bootstrap_endpoint_unavailable',
                    'arr_bootstrap_endpoint_changed',
                    'arr_bootstrap_wiring_failed',
                    'arr_bootstrap_readback_failed',
                    'arr_bootstrap_timeout'}:
                cause = error.code
            raise ArrConfigurationExecutionError(
                code, uncertain_effect=True, cause_code=cause) from None
        except Exception:
            raise ArrConfigurationExecutionError(
                'arr_config_result_invalid', uncertain_effect=True,
                cause_code='arr_bootstrap_stage_failed') from None
        if (verified.state != 'verified'
                or verified.service_id != service_id):
            raise ArrConfigurationExecutionError(
                'arr_config_result_invalid', uncertain_effect=True)
        try:
            return ArrConfiguredInstallReceipt(
                configured, result.container_id,
                service_id + '_container_started',
                service_id + '_service_verified')
        except (TypeError, ValueError):
            raise ArrConfigurationExecutionError(
                'arr_config_result_invalid', uncertain_effect=True,
                cause_code='arr_receipt_stage_failed') from None

    def install_configured_qbittorrent(
            self, job, stack, credential, *, api_key, salt, cancelled,
            deadline, gate):
        """Verify/install config, then and only then execute create/start."""
        try:
            configured = self.configure_qbittorrent(
                job, stack, credential, api_key=api_key, salt=salt,
                cancelled=cancelled, deadline=deadline, gate=gate)
        except (QbittorrentConfigurationExecutionError,
                QbittorrentConfigRuntimeError,
                QbittorrentConfigEffectError):
            raise
        except Exception:
            raise QbittorrentConfigurationExecutionError(
                'qbittorrent_config_resources_unavailable',
                cause_code='qbittorrent_configure_stage_failed') from None
        if (type(configured) is not QbittorrentConfigInstallReceipt
                or configured.state not in {
                    'qbittorrent_config_installed',
                    'qbittorrent_config_already_installed'}):
            raise QbittorrentConfigurationExecutionError(
                'qbittorrent_config_result_invalid',
                uncertain_effect=True)

        def authority():
            try:
                return (ExecutionGateResult.allowed() if gate() is True
                        else ExecutionGateResult.denied('authority_changed'))
            except Exception:
                return ExecutionGateResult.denied('authority_changed')

        remaining = deadline - time.monotonic()
        if not 0 < remaining <= 120:
            raise QbittorrentConfigurationExecutionError(
                'qbittorrent_config_timeout')
        try:
            execution = build_execution(
                stack, job_id=job, deadline=time.time() + remaining,
                service_id='qbittorrent')
            result = execution.run(
                self.qbittorrent_installation, authority)
        except QbittorrentConfigurationExecutionError:
            raise
        except Exception:
            raise QbittorrentConfigurationExecutionError(
                'qbittorrent_config_result_invalid', uncertain_effect=True,
                cause_code='qbittorrent_execution_stage_failed') from None
        if (type(result) is not ExecutionResult or result.state != 'succeeded'
                or result.code != 'container_started'
                or result.container_id is None):
            cause = ({
                ('pending', 'worker_unavailable'):
                    'qbittorrent_execution_worker_unavailable',
                ('failed', 'invalid_worker_result'):
                    'qbittorrent_execution_invalid_worker_result',
                ('needs_attention', 'resource_conflict'):
                    'qbittorrent_execution_resource_conflict',
                ('needs_attention', 'container_not_running'):
                    'qbittorrent_execution_container_not_running',
                ('needs_attention', 'dispatch_expired'):
                    'qbittorrent_execution_dispatch_expired',
            }.get((getattr(result, 'state', None),
                   getattr(result, 'code', None)))
                     if type(result) is ExecutionResult else None)
            raise QbittorrentConfigurationExecutionError(
                'qbittorrent_config_result_invalid',
                uncertain_effect=True, cause_code=cause)
        try:
            verified = self.qbittorrent_bootstrap.execute(
                job, stack, PrivateQbittorrentConfiguration(
                    credential=credential, apiKey=api_key,
                    saltHex=salt.hex()),
                deadline=deadline, gate=gate)
        except QbittorrentBootstrapExecutionError as error:
            code = {
                'qbittorrent_bootstrap_authority_changed':
                    'qbittorrent_config_authority_changed',
                'qbittorrent_bootstrap_endpoint_unavailable':
                    'qbittorrent_service_unavailable',
                'qbittorrent_bootstrap_endpoint_changed':
                    'qbittorrent_service_changed',
                'qbittorrent_bootstrap_timeout': 'qbittorrent_config_timeout',
            }.get(error.code, 'qbittorrent_service_verification_failed')
            cause = {
                'qbittorrent_bootstrap_binding_invalid_installation_plan':
                    'qbittorrent_bootstrap_binding_invalid_installation_plan',
                'qbittorrent_bootstrap_binding_resources_unavailable':
                    'qbittorrent_bootstrap_binding_resources_unavailable',
                'qbittorrent_bootstrap_binding_resources_untrusted':
                    'qbittorrent_bootstrap_binding_resources_untrusted',
                'qbittorrent_bootstrap_proof_plan_failed':
                    'qbittorrent_bootstrap_proof_plan_failed',
                'qbittorrent_bootstrap_proof_journal_bind_failed':
                    'qbittorrent_bootstrap_proof_journal_bind_failed',
                'qbittorrent_bootstrap_proof_image_observation_failed':
                    'qbittorrent_bootstrap_proof_image_observation_failed',
                'qbittorrent_bootstrap_proof_volume_observation_failed':
                    'qbittorrent_bootstrap_proof_volume_observation_failed',
                'qbittorrent_bootstrap_proof_volume_bootstrap_failed':
                    'qbittorrent_bootstrap_proof_volume_bootstrap_failed',
                'qbittorrent_bootstrap_proof_network_list_failed':
                    'qbittorrent_bootstrap_proof_network_list_failed',
                'qbittorrent_bootstrap_proof_network_observation_failed':
                    'qbittorrent_bootstrap_proof_network_observation_failed',
                'qbittorrent_bootstrap_proof_journal_rebind_failed':
                    'qbittorrent_bootstrap_proof_journal_rebind_failed',
                'qbittorrent_bootstrap_proof_result_failed':
                    'qbittorrent_bootstrap_proof_result_failed',
                'invalid_qbittorrent_categories':
                    'invalid_qbittorrent_categories',
                'qbittorrent_categories_authentication_failed':
                    'qbittorrent_categories_authentication_failed',
                'qbittorrent_categories_protocol':
                    'qbittorrent_categories_protocol',
                'qbittorrent_categories_observation_protocol':
                    'qbittorrent_categories_observation_protocol',
                'qbittorrent_categories_observation_framing':
                    'qbittorrent_categories_observation_framing',
                'qbittorrent_categories_observation_http':
                    'qbittorrent_categories_observation_http',
                'qbittorrent_categories_observation_closed':
                    'qbittorrent_categories_observation_closed',
                'qbittorrent_categories_observation_payload':
                    'qbittorrent_categories_observation_payload',
                'qbittorrent_category_create_protocol':
                    'qbittorrent_category_create_protocol',
                'qbittorrent_categories_verification_protocol':
                    'qbittorrent_categories_verification_protocol',
                'qbittorrent_category_conflict':
                    'qbittorrent_category_conflict',
                'qbittorrent_categories_unavailable':
                    'qbittorrent_categories_unavailable',
                'qbittorrent_categories_timeout':
                    'qbittorrent_categories_timeout',
                'invalid_qbittorrent_authenticated_readback':
                    'invalid_qbittorrent_authenticated_readback',
                'qbittorrent_authentication_failed':
                    'qbittorrent_authentication_failed',
                'qbittorrent_readback_protocol':
                    'qbittorrent_readback_protocol',
                'qbittorrent_readback_mismatch':
                    'qbittorrent_readback_mismatch',
                'qbittorrent_authenticated_readback_unavailable':
                    'qbittorrent_authenticated_readback_unavailable',
                'qbittorrent_authenticated_readback_timeout':
                    'qbittorrent_authenticated_readback_timeout',
            }.get(error.cause_code)
            if (cause is None
                    and error.cause_code == 'qbittorrent_bootstrap_unexpected'
                    and error.boundary is not None):
                cause = f'qbittorrent_bootstrap_{error.boundary}_failed'
            if cause is None and error.code in {
                    'qbittorrent_bootstrap_resources_unavailable',
                    'qbittorrent_bootstrap_categories_failed',
                    'qbittorrent_bootstrap_readback_failed'}:
                cause = error.code
            raise QbittorrentConfigurationExecutionError(
                code, uncertain_effect=True, cause_code=cause) from None
        except Exception:
            raise QbittorrentConfigurationExecutionError(
                'qbittorrent_service_verification_failed',
                uncertain_effect=True,
                cause_code='qbittorrent_bootstrap_stage_failed') from None
        if (type(verified) is not QbittorrentBootstrapExecutionResult
                or verified.state != 'verified'):
            raise QbittorrentConfigurationExecutionError(
                'qbittorrent_service_verification_failed',
                uncertain_effect=True)
        try:
            return QbittorrentConfiguredInstallReceipt(
                configured, result.container_id,
                'qbittorrent_container_started',
                'qbittorrent_service_verified')
        except (TypeError, ValueError):
            raise QbittorrentConfigurationExecutionError(
                'qbittorrent_config_result_invalid', uncertain_effect=True,
                cause_code='qbittorrent_receipt_stage_failed') from None


def _build_runtime(policy, *, peer_uid=None):
    journals = []
    try:
        resources = ResourceJournal(policy.resource_journal)
        journals.append(resources)
        volumes = VolumeCreateJournal(policy.volume_journal)
        journals.append(volumes)
        containers = ManagedWorkerJournal(policy.container_journal)
        journals.append(containers)
        bootstrap = VolumeBootstrapVerifier(
            policy.endpoint,
            policy.helper_image_id,
            policy.platform,
            peer_uid=peer_uid,
        )
        readers = JellyfinEngineReaders(policy.endpoint, bootstrap, peer_uid=peer_uid)
        catalog = load_catalog()
        builder = _RuntimeBindingBuilder(
            policy.worker_policy,
            catalog,
            resources,
            volumes,
            containers,
            readers,
        )
        engine = UnixDockerEngine(
            policy.endpoint.path,
            socket_uid=policy.endpoint.owner_uid,
            peer_uid=peer_uid,
        )
        operations = JournaledManagedContainerOperations(containers, engine)
        qbittorrent_config = QbittorrentConfigRuntime(
            policy.endpoint, volumes, catalog, policy.worker_policy,
            policy.helper_image_id, policy.platform, peer_uid=peer_uid,
        )
        arr_config = ArrConfigRuntime(
            policy.endpoint, volumes, catalog, policy.worker_policy,
            policy.helper_image_id, policy.platform, peer_uid=peer_uid,
        )
        return _InstallationRuntime(
            _RuntimeBackend(
                operations, builder, qbittorrent_config, arr_config),
            resources,
            volumes,
            containers,
        )
    except Exception:
        for journal in reversed(journals):
            try:
                journal.close()
            except Exception:
                pass
        raise _ConfigurationError() from None


def _serve(args, policy):
    stopped = threading.Event()
    previous = {}
    built = None
    worker = None
    failed = False

    def stop(_number, _frame):
        stopped.set()

    try:
        for number in (signal.SIGINT, signal.SIGTERM):
            previous[number] = signal.getsignal(number)
            signal.signal(number, stop)
        peer_verifier = RetainedDaemonPeerVerifier(policy.endpoint)
        built = _build_runtime(policy, peer_uid=peer_verifier)
        worker = InstallationWorkerServer(
            args.socket,
            SupervisedInstallationBackend(
                policy.endpoint, built.backend, platform=policy.platform,
                peer_verifier=peer_verifier,
            ),
            allowed_uid=args.api_uid,
            socket_gid=args.socket_gid,
        )
        worker.start()
        stopped.wait()
    except Exception:
        failed = True
    finally:
        if worker is not None:
            try:
                worker.close()
            except Exception:
                failed = True
        if built is not None:
            try:
                built.close()
            except Exception:
                failed = True
        for number, handler in previous.items():
            try:
                signal.signal(number, handler)
            except Exception:
                failed = True
    return 1 if failed else 0


def main(argv=None) -> int:
    parser = _Parser(prog='larenor-installation-worker', description=__doc__)
    parser.add_argument('--policy', required=True, type=Path)
    parser.add_argument('--socket', required=True, type=Path)
    parser.add_argument('--api-uid', required=True, type=_uid)
    parser.add_argument('--socket-gid', type=_uid)
    parser.add_argument(
        '--check-config',
        action='store_true',
        help='Validate private policy only; never open journals, Docker or a socket',
    )
    try:
        args = parser.parse_args(argv)
        checked_path(args.policy)
        checked_path(args.socket)
        if (os.getuid() != os.geteuid()
                or args.api_uid != os.getuid() and args.socket_gid is None):
            raise _ConfigurationError()
    except _ParserExit as result:
        return result.status
    except (ValueError, StartupError, OSError):
        print('invalid_arguments', file=sys.stderr)
        return 2
    try:
        policy = load_policy(args.policy)
        if _host_platform() != policy.platform:
            raise _ConfigurationError()
    except Exception:
        print('worker_configuration_invalid', file=sys.stderr)
        return 1
    socket_path = args.socket.absolute()
    journal_paths = (
        policy.resource_journal, policy.volume_journal, policy.container_journal,
    )
    if (socket_path == Path(policy.endpoint.path)
            or any(socket_path == path or path in socket_path.parents
                   for path in journal_paths)):
        print('invalid_arguments', file=sys.stderr)
        return 2
    if args.check_config:
        return 0
    status = _serve(args, policy)
    if status:
        print('worker_unavailable', file=sys.stderr)
    return status


if __name__ == '__main__':
    raise SystemExit(main())
