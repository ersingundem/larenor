"""Bounded Unix IPC for the closed Jellyfin create/start worker surface."""

import json
import math
from pathlib import Path
import platform as host_platform
import re
import socket
import stat
import threading
import time
import uuid

from .installation_execution import service_for_step
from .jellyfin_bootstrap_executor import (
    JellyfinBootstrapExecutionError, JellyfinBootstrapExecutionResult,
)
from .jellyfin_authenticated_readback import JellyfinAuthenticatedReadbackResult
from .media_service_bootstrap_models import PrivateMediaServiceBootstrap
from .music_assistant_bootstrap_models import PrivateMusicAssistantBootstrap
from .music_assistant_bootstrap_runtime import (
    MusicAssistantBootstrapRuntimeError,
)
from .music_assistant_core_models import AuthenticatedMusicAssistantReadback
from .music_provider_setup_models import (
    PrivateMusicProviderSetupAction, ProviderSetupWorkerResult,
)
from .music_playback_models import (
    MusicPlaybackReadback, MusicPlaybackWorkerResult,
    PrivateMusicPlaybackAction, PrivateMusicPlaybackAuthority,
)
from .seerr_bootstrap_models import PrivateSeerrBootstrap
from .seerr_bootstrap_executor import (
    SeerrBootstrapExecutionError, SeerrBootstrapExecutionResult,
)
from .seerr_arr_wiring import SeerrArrWiringResult
from .preflight_ipc import PreflightIPCError, PreflightWorkerServer, read_packet, write_packet
from .arr_config_effect import ArrConfigEffectError, ArrConfigInstallReceipt
from .arr_config_models import (
    ARR_CONFIG_EXECUTION_CODES, ArrConfiguredInstallReceipt,
    ArrConfigurationExecutionError,
    PrivateArrConfiguration,
)
from .arr_config_runtime import ArrConfigRuntimeError
from .qbittorrent_config_effect import (
    QbittorrentConfigEffectError, QbittorrentConfigInstallReceipt,
)
from .qbittorrent_config_models import (
    PrivateQbittorrentConfiguration, QB_CONFIG_EXECUTION_CODES,
    QbittorrentConfiguredInstallReceipt,
    QbittorrentConfigurationExecutionError,
)
from .qbittorrent_config_runtime import QbittorrentConfigRuntimeError
from .catalog import load_catalog
from .stack_plan import MediaStackPlan, verify_media_stack_plan
from .worker import DockerWorkerError, StepReceipt, WorkerStep, _safe_path


class InstallationIPCError(Exception):
    def __init__(self, code='worker_unavailable'):
        self.code = code if code in {'worker_unavailable', 'invalid_request', 'invalid_worker_result'} else 'worker_unavailable'
        super().__init__(self.code)


def _receipt(value, step):
    try:
        if type(value) is StepReceipt:
            result = value
        elif type(value) is dict and set(value) == {'jobId', 'step', 'state', 'code', 'containerId'}:
            result = StepReceipt(value['jobId'], value['step'], value['state'], value['code'], value['containerId'])
        else:
            raise ValueError()
        if result.job_id != step.job_id or result.step != step.kind:
            raise ValueError()
        return result
    except (ValueError, TypeError, AttributeError):
        raise InstallationIPCError('invalid_worker_result') from None


def _wire_receipt(value):
    return {'jobId': value.job_id, 'step': value.step, 'state': value.state,
            'code': value.code, 'containerId': value.container_id}


_BOOTSTRAP_STEPS = (
    'observed_unconfigured', 'configuration_updated', 'user_updated',
    'remote_access_updated', 'wizard_completed',
)


def _wire_bootstrap(value=None, error=None):
    if error is not None:
        return {
            'state': 'failed', 'completedSteps': list(error.completed_steps),
            'errorCode': error.code, 'uncertainEffect': error.uncertain_effect,
            'readback': None,
        }
    if (type(value) is not JellyfinBootstrapExecutionResult
            or value.state != 'wiring_partial'
            or value.completed_steps != _BOOTSTRAP_STEPS
            or type(value.readback) is not JellyfinAuthenticatedReadbackResult):
        raise InstallationIPCError('invalid_worker_result')
    return {
        'state': value.state,
        'completedSteps': list(value.completed_steps),
        'errorCode': None, 'uncertainEffect': False,
        'readback': {
            'state': value.readback.state,
            'serverId': value.readback.server_id,
            'serverName': value.readback.server_name,
            'version': value.readback.version,
            'apiKey': value.readback.api_key,
            'libraries': [
                {
                    'name': name, 'collectionType': collection,
                    'itemId': item_id, 'locations': list(locations),
                }
                for name, collection, item_id, locations in value.readback.libraries
            ],
            'completedSteps': list(value.readback.completed_steps),
        },
    }


def _bootstrap_result(value):
    try:
        if (type(value) is not dict or set(value) != {
                'state', 'completedSteps', 'errorCode', 'uncertainEffect', 'readback'}
                or type(value['completedSteps']) is not list
                or any(type(item) is not str or item not in _BOOTSTRAP_STEPS
                       for item in value['completedSteps'])
                or tuple(value['completedSteps']) != _BOOTSTRAP_STEPS[:len(value['completedSteps'])]
                or type(value['uncertainEffect']) is not bool):
            raise ValueError()
        completed = tuple(value['completedSteps'])
        if (value['state'] == 'wiring_partial'
                and value['completedSteps'] == list(_BOOTSTRAP_STEPS)
                and value['errorCode'] is None
                and value['uncertainEffect'] is False):
            readback = value['readback']
            if (type(readback) is not dict or set(readback) != {
                    'state', 'serverId', 'serverName', 'version', 'apiKey',
                    'libraries', 'completedSteps'}
                    or readback['state'] != 'verified'
                    or type(readback['libraries']) is not list
                    or len(readback['libraries']) > 256
                    or type(readback['completedSteps']) is not list):
                raise ValueError()
            libraries = []
            for item in readback['libraries']:
                if type(item) is not dict or set(item) != {
                        'name', 'collectionType', 'itemId', 'locations'}:
                    raise ValueError()
                libraries.append((
                    item['name'], item['collectionType'], item['itemId'],
                    tuple(item['locations']),
                ))
            verified = JellyfinAuthenticatedReadbackResult(
                readback['state'], readback['serverId'], readback['serverName'],
                readback['version'], readback['apiKey'], tuple(libraries),
                tuple(readback['completedSteps']),
            )
            # Re-validate every private value through the same strict encrypted
            # storage model before the Core can persist it.
            from .media_service_bootstrap_models import (
                PrivateJellyfinReadback, PrivateMediaLibrary,
            )
            PrivateJellyfinReadback(
                apiKey=verified.api_key,
                serverId=verified.server_id,
                serverName=verified.server_name,
                version=verified.version,
                libraries=tuple(
                    PrivateMediaLibrary(
                        name=name, collectionType=collection, itemId=item_id,
                        locations=locations,
                    )
                    for name, collection, item_id, locations in verified.libraries
                ),
            )
            return JellyfinBootstrapExecutionResult(
                'wiring_partial', completed, verified)
        if (value['state'] != 'failed' or type(value['errorCode']) is not str
                or value['readback'] is not None
                or value['errorCode'] not in {
                    'invalid_bootstrap_execution', 'bootstrap_authority_changed',
                    'bootstrap_resources_unavailable', 'bootstrap_endpoint_unavailable',
                    'bootstrap_endpoint_changed', 'bootstrap_startup_failed',
                    'bootstrap_readback_failed', 'bootstrap_wiring_failed',
                    'bootstrap_timeout'}):
            raise ValueError()
        raise JellyfinBootstrapExecutionError(
            value['errorCode'], completed_steps=completed,
            uncertain_effect=value['uncertainEffect'])
    except JellyfinBootstrapExecutionError:
        raise
    except (ValueError, TypeError, AttributeError):
        raise InstallationIPCError('invalid_worker_result') from None


_SEERR_BOOTSTRAP_STEPS = (
    'uninitialized_verified', 'admin_created',
    'api_key_verified', 'session_destroyed', 'arr_wiring_verified',
)
_SEERR_BOOTSTRAP_CODES = frozenset({
    'invalid_seerr_bootstrap_execution',
    'seerr_bootstrap_authority_changed',
    'seerr_bootstrap_resources_unavailable',
    'seerr_bootstrap_endpoint_unavailable',
    'seerr_bootstrap_endpoint_changed',
    'seerr_bootstrap_peer_changed',
    'seerr_bootstrap_initial_admin_failed',
    'seerr_bootstrap_arr_wiring_failed',
    'seerr_bootstrap_timeout',
})


def _wire_seerr_bootstrap(value=None, error=None):
    if error is not None:
        if type(error) is not SeerrBootstrapExecutionError:
            error = SeerrBootstrapExecutionError()
        return {
            'state': 'failed', 'apiKey': error.api_key,
            'arrInstanceIds': None,
            'completedSteps': list(error.completed_steps),
            'errorCode': error.code,
            'uncertainEffect': error.uncertain_effect,
            'causeCode': error.cause_code,
        }
    try:
        if type(value) is not SeerrBootstrapExecutionResult:
            raise ValueError()
        verified = SeerrBootstrapExecutionResult(
            value.state, value.api_key, value.completed_steps, value.arr_wiring)
        return {
            'state': verified.state, 'apiKey': verified.api_key,
            'arrInstanceIds': (
                None if verified.arr_wiring is None
                else list(verified.arr_wiring.instance_ids)
            ),
            'completedSteps': list(verified.completed_steps),
            'errorCode': None, 'uncertainEffect': False, 'causeCode': None,
        }
    except (ValueError, TypeError, AttributeError,
            SeerrBootstrapExecutionError):
        raise InstallationIPCError('invalid_worker_result') from None


def _seerr_bootstrap_result(value):
    try:
        if (type(value) is not dict or set(value) != {
                'state', 'apiKey', 'completedSteps', 'errorCode',
                'uncertainEffect', 'causeCode', 'arrInstanceIds'}
                or type(value['completedSteps']) is not list
                or tuple(value['completedSteps'])
                != _SEERR_BOOTSTRAP_STEPS[:len(value['completedSteps'])]
                or type(value['uncertainEffect']) is not bool):
            raise ValueError()
        if value['state'] == 'verified':
            if (value['errorCode'] is not None
                    or value['uncertainEffect'] is not False
                    or value['causeCode'] is not None):
                raise ValueError()
            wiring = None
            if value['arrInstanceIds'] is None:
                if value['completedSteps'] != list(_SEERR_BOOTSTRAP_STEPS[:4]):
                    raise ValueError()
            else:
                if value['completedSteps'] != list(_SEERR_BOOTSTRAP_STEPS):
                    raise ValueError()
                if (type(value['arrInstanceIds']) is not list
                        or len(value['arrInstanceIds']) != 2):
                    raise ValueError()
                wiring = SeerrArrWiringResult(
                    'verified', ('radarr', 'sonarr'),
                    tuple(value['arrInstanceIds']))
            return SeerrBootstrapExecutionResult(
                value['state'], value['apiKey'], tuple(value['completedSteps']),
                wiring)
        if (value['state'] != 'failed'
                or value['arrInstanceIds'] is not None
                or value['errorCode'] not in _SEERR_BOOTSTRAP_CODES):
            raise ValueError()
        failure = SeerrBootstrapExecutionError(
            value['errorCode'], completed_steps=tuple(value['completedSteps']),
            uncertain_effect=value['uncertainEffect'],
            cause_code=value['causeCode'], api_key=value['apiKey'])
        if (failure.code != value['errorCode']
                or failure.cause_code != value['causeCode']):
            raise ValueError()
        raise failure
    except SeerrBootstrapExecutionError:
        raise
    except (ValueError, TypeError, AttributeError):
        raise InstallationIPCError('invalid_worker_result') from None


def _wire_music_assistant_bootstrap(value=None, error=None):
    if error is not None:
        failure = error if type(error) is MusicAssistantBootstrapRuntimeError else (
            MusicAssistantBootstrapRuntimeError(
                'music_assistant_bootstrap_uncertain', uncertain_effect=True))
        return {
            'state': 'failed', 'errorCode': failure.code,
            'uncertainEffect': failure.uncertain_effect, 'readback': None,
        }
    try:
        if type(value) is not AuthenticatedMusicAssistantReadback:
            raise ValueError()
        readback = AuthenticatedMusicAssistantReadback.model_validate(
            value.model_dump(mode='python', warnings=False))
        return {
            'state': 'verified', 'errorCode': None,
            'uncertainEffect': False,
            'readback': readback.model_dump(mode='json', warnings=False),
        }
    except (ValueError, TypeError, AttributeError):
        raise InstallationIPCError('invalid_worker_result') from None


def _music_assistant_bootstrap_result(value):
    try:
        if (type(value) is not dict or set(value) != {
                'state', 'errorCode', 'uncertainEffect', 'readback'}
                or type(value['uncertainEffect']) is not bool):
            raise ValueError()
        if value['state'] == 'verified':
            if (value['errorCode'] is not None
                    or value['uncertainEffect'] is not False
                    or type(value['readback']) is not dict):
                raise ValueError()
            return AuthenticatedMusicAssistantReadback.model_validate(
                value['readback'])
        if (value['state'] != 'failed' or value['readback'] is not None
                or type(value['errorCode']) is not str):
            raise ValueError()
        failure = MusicAssistantBootstrapRuntimeError(
            value['errorCode'], uncertain_effect=value['uncertainEffect'])
        if failure.code != value['errorCode']:
            raise ValueError()
        raise failure
    except MusicAssistantBootstrapRuntimeError:
        raise
    except (ValueError, TypeError, AttributeError):
        raise InstallationIPCError('invalid_worker_result') from None


def _qbittorrent_error(error):
    if isinstance(error, QbittorrentConfigurationExecutionError):
        return error
    if isinstance(error, QbittorrentConfigEffectError):
        if error.code in {
            'qbittorrent_config_effect_dispatch_denied',
            'qbittorrent_config_effect_authority_changed',
            'qbittorrent_config_effect_cancelled',
        }:
            code = 'qbittorrent_config_authority_changed'
        elif error.code == 'qbittorrent_config_effect_result_failed':
            code = 'qbittorrent_config_result_invalid'
        else:
            code = 'qbittorrent_config_write_failed'
        return QbittorrentConfigurationExecutionError(
            code, uncertain_effect=error.uncertain_effect)
    if isinstance(error, QbittorrentConfigRuntimeError):
        code = {
            'qbittorrent_config_runtime_effect_failed': 'qbittorrent_config_write_failed',
            'qbittorrent_config_runtime_result_invalid': 'qbittorrent_config_result_invalid',
        }.get(error.code, 'qbittorrent_config_resources_unavailable')
        return QbittorrentConfigurationExecutionError(
            code, uncertain_effect=error.uncertain_effect)
    return QbittorrentConfigurationExecutionError()


def _arr_error(error):
    if isinstance(error, ArrConfigurationExecutionError):
        return error
    if isinstance(error, ArrConfigEffectError):
        if error.code in {
            'arr_config_effect_dispatch_denied',
            'arr_config_effect_authority_changed',
            'arr_config_effect_cancelled',
        }:
            code = 'arr_config_authority_changed'
        elif error.code == 'arr_config_effect_result_failed':
            code = 'arr_config_result_invalid'
        else:
            code = 'arr_config_write_failed'
        return ArrConfigurationExecutionError(
            code, uncertain_effect=error.uncertain_effect)
    if isinstance(error, ArrConfigRuntimeError):
        code = {
            'arr_config_runtime_effect_failed': 'arr_config_write_failed',
            'arr_config_runtime_result_invalid': 'arr_config_result_invalid',
        }.get(error.code, 'arr_config_resources_unavailable')
        return ArrConfigurationExecutionError(
            code, uncertain_effect=error.uncertain_effect)
    return ArrConfigurationExecutionError()


def _wire_arr(value=None, error=None):
    if error is not None:
        failure = _arr_error(error)
        return {
            'state': 'failed', 'errorCode': failure.code,
            'uncertainEffect': failure.uncertain_effect, 'receipt': None,
        }
    try:
        if type(value) is not ArrConfigInstallReceipt:
            raise ValueError()
        receipt = ArrConfigInstallReceipt(**vars(value))
        return {
            'state': 'succeeded', 'errorCode': None,
            'uncertainEffect': False,
            'receipt': {
                'serviceId': receipt.service_id,
                'resourceId': receipt.resource_id,
                'operationId': receipt.operation_id,
                'journalId': receipt.journal_id,
                'revision': receipt.revision,
                'volumeName': receipt.volume_name,
                'configurationDigest': receipt.configuration_digest,
                'state': receipt.state,
            },
        }
    except (ValueError, TypeError, AttributeError, ArrConfigEffectError):
        failure = ArrConfigurationExecutionError(
            'arr_config_result_invalid', uncertain_effect=True)
        return {
            'state': 'failed', 'errorCode': failure.code,
            'uncertainEffect': True, 'receipt': None,
        }


def _arr_result(value):
    try:
        if (type(value) is not dict or set(value) != {
                'state', 'errorCode', 'uncertainEffect', 'receipt'}
                or type(value['uncertainEffect']) is not bool):
            raise ValueError()
        if value['state'] == 'failed':
            if (value['receipt'] is not None
                    or value['errorCode'] not in ARR_CONFIG_EXECUTION_CODES):
                raise ValueError()
            raise ArrConfigurationExecutionError(
                value['errorCode'],
                uncertain_effect=value['uncertainEffect'])
        receipt = value['receipt']
        if (value['state'] != 'succeeded' or value['errorCode'] is not None
                or value['uncertainEffect'] is not False
                or type(receipt) is not dict or set(receipt) != {
                    'serviceId', 'resourceId', 'operationId', 'journalId',
                    'revision', 'volumeName', 'configurationDigest', 'state'}):
            raise ValueError()
        return ArrConfigInstallReceipt(
            receipt['serviceId'], receipt['resourceId'],
            receipt['operationId'], receipt['journalId'], receipt['revision'],
            receipt['volumeName'], receipt['configurationDigest'],
            receipt['state'])
    except ArrConfigurationExecutionError:
        raise
    except (ValueError, TypeError, AttributeError, ArrConfigEffectError):
        raise ArrConfigurationExecutionError(
            'arr_config_result_invalid', uncertain_effect=True) from None


def _wire_arr_install(value):
    if type(value) is not ArrConfiguredInstallReceipt:
        raise InstallationIPCError('invalid_worker_result')
    return {
        'state': value.state, 'containerId': value.container_id,
        'serviceState': value.service_state,
        'configuration': _wire_arr(value=value.configuration)['receipt'],
    }


def _arr_install_result(value):
    try:
        if type(value) is dict and set(value) == {
                'state', 'errorCode', 'uncertainEffect', 'receipt'}:
            _arr_result(value)
            raise ValueError()
        if (type(value) is not dict or set(value) != {
                'state', 'containerId', 'serviceState', 'configuration'}
                or type(value['containerId']) is not str
                or re.fullmatch(r'[0-9a-f]{64}', value['containerId']) is None):
            raise ValueError()
        wrapped = {
            'state': 'succeeded', 'errorCode': None,
            'uncertainEffect': False, 'receipt': value['configuration'],
        }
        configuration = _arr_result(wrapped)
        return ArrConfiguredInstallReceipt(
            configuration, value['containerId'], value['state'],
            value['serviceState'])
    except ArrConfigurationExecutionError:
        raise
    except (ValueError, TypeError, AttributeError):
        raise ArrConfigurationExecutionError(
            'arr_config_result_invalid', uncertain_effect=True) from None


def _wire_qbittorrent(value=None, error=None):
    if error is not None:
        failure = _qbittorrent_error(error)
        return {
            'state': 'failed', 'errorCode': failure.code,
            'uncertainEffect': failure.uncertain_effect, 'receipt': None,
        }
    try:
        if type(value) is not QbittorrentConfigInstallReceipt:
            raise ValueError()
        receipt = QbittorrentConfigInstallReceipt(**vars(value))
        return {
            'state': 'succeeded', 'errorCode': None,
            'uncertainEffect': False,
            'receipt': {
                'resourceId': receipt.resource_id,
                'operationId': receipt.operation_id,
                'journalId': receipt.journal_id,
                'revision': receipt.revision,
                'volumeName': receipt.volume_name,
                'configurationDigest': receipt.configuration_digest,
                'state': receipt.state,
            },
        }
    except (ValueError, TypeError, AttributeError, QbittorrentConfigEffectError):
        failure = QbittorrentConfigurationExecutionError(
            'qbittorrent_config_result_invalid', uncertain_effect=True)
        return {
            'state': 'failed', 'errorCode': failure.code,
            'uncertainEffect': True, 'receipt': None,
        }


def _qbittorrent_result(value):
    try:
        if (type(value) is not dict or set(value) != {
                'state', 'errorCode', 'uncertainEffect', 'receipt'}
                or type(value['uncertainEffect']) is not bool):
            raise ValueError()
        if value['state'] == 'failed':
            if (value['receipt'] is not None
                    or value['errorCode'] not in QB_CONFIG_EXECUTION_CODES):
                raise ValueError()
            raise QbittorrentConfigurationExecutionError(
                value['errorCode'], uncertain_effect=value['uncertainEffect'])
        receipt = value['receipt']
        if (value['state'] != 'succeeded' or value['errorCode'] is not None
                or value['uncertainEffect'] is not False
                or type(receipt) is not dict or set(receipt) != {
                    'resourceId', 'operationId', 'journalId', 'revision',
                    'volumeName', 'configurationDigest', 'state'}):
            raise ValueError()
        return QbittorrentConfigInstallReceipt(
            receipt['resourceId'], receipt['operationId'], receipt['journalId'],
            receipt['revision'], receipt['volumeName'],
            receipt['configurationDigest'], receipt['state'])
    except QbittorrentConfigurationExecutionError:
        raise
    except (ValueError, TypeError, AttributeError, QbittorrentConfigEffectError):
        raise QbittorrentConfigurationExecutionError(
            'qbittorrent_config_result_invalid', uncertain_effect=True) from None


def _wire_qbittorrent_install(value):
    if type(value) is not QbittorrentConfiguredInstallReceipt:
        raise InstallationIPCError('invalid_worker_result')
    configuration = _wire_qbittorrent(value=value.configuration)['receipt']
    return {
        'state': value.state,
        'containerId': value.container_id,
        'serviceState': value.service_state,
        'configuration': configuration,
    }


def _qbittorrent_install_result(value):
    try:
        if type(value) is dict and set(value) == {
                'state', 'errorCode', 'uncertainEffect', 'receipt'}:
            # Reuse the closed configuration error envelope. A success value
            # can never have this shape for the configured-container operation.
            _qbittorrent_result(value)
            raise ValueError()
        if (type(value) is not dict or set(value) != {
                'state', 'containerId', 'serviceState', 'configuration'}
                or value['state'] != 'qbittorrent_container_started'
                or value['serviceState'] != 'qbittorrent_service_verified'
                or type(value['containerId']) is not str
                or re.fullmatch(r'[0-9a-f]{64}', value['containerId']) is None):
            raise ValueError()
        wrapped = {
            'state': 'succeeded', 'errorCode': None,
            'uncertainEffect': False, 'receipt': value['configuration'],
        }
        return QbittorrentConfiguredInstallReceipt(
            _qbittorrent_result(wrapped), value['containerId'], value['state'],
            value['serviceState'])
    except QbittorrentConfigurationExecutionError:
        raise
    except (ValueError, TypeError, AttributeError):
        raise QbittorrentConfigurationExecutionError(
            'qbittorrent_config_result_invalid', uncertain_effect=True) from None


class InstallationWorkerClient:
    def __init__(self, path, *, owner_uid=0, peer_uid=None, timeout=5):
        from .preflight_ipc import _peer_uid
        if type(owner_uid) is not int or owner_uid < 0 or type(timeout) not in (int, float) or not 0 < timeout <= 5:
            raise InstallationIPCError()
        self.path = Path(path).absolute()
        self.owner_uid, self.peer_uid, self.timeout = owner_uid, peer_uid or _peer_uid, timeout

    def _exchange(self, operation, step=None, plan=None, bootstrap=None,
                  qbittorrent=None, arr=None, seerr=None, music_provider=None,
                  music_playback=None, music_bootstrap=None):
        try:
            _safe_path(self.path, uid=self.owner_uid, kind=stat.S_ISSOCK)
            deadline = time.monotonic() + self.timeout
            request = {'protocol': 1, 'requestId': uuid.uuid4().hex, 'operation': operation}
            if step is not None:
                request['step'] = {
                    'job_id': step.job_id, 'installation_id': step.installation_id,
                    'kind': step.kind, 'dispatch_id': step.dispatch_id,
                    'start_deadline': step.start_deadline,
                }
                request['plan'] = plan.model_dump(mode='json')
            elif bootstrap is not None:
                job, private = bootstrap
                request['jobId'] = job
                request['plan'] = plan.model_dump(mode='json')
                request['private'] = private.model_dump(mode='json')
            elif qbittorrent is not None:
                job, private = qbittorrent
                request['jobId'] = job
                request['plan'] = plan.model_dump(mode='json')
                request['private'] = private.model_dump(mode='json', warnings=False)
            elif arr is not None:
                job, private = arr
                request['jobId'] = job
                request['plan'] = plan.model_dump(mode='json')
                request['private'] = private.model_dump(
                    mode='json', warnings=False)
            elif seerr is not None:
                job, private = seerr
                request['jobId'] = job
                request['plan'] = plan.model_dump(mode='json')
                request['private'] = private.model_dump(
                    mode='json', warnings=False)
            elif music_provider is not None:
                request['private'] = music_provider.model_dump(
                    mode='json', warnings=False)
            elif music_playback is not None:
                request['private'] = music_playback.model_dump(
                    mode='json', warnings=False)
            elif music_bootstrap is not None:
                request['private'] = music_bootstrap.model_dump(
                    mode='json', warnings=False)
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(self.timeout)
                connection.connect(str(self.path))
                if self.peer_uid(connection) != self.owner_uid:
                    raise InstallationIPCError()
                write_packet(connection, request, deadline)
                response = read_packet(connection, deadline)
            if response['requestId'] != request['requestId']:
                raise InstallationIPCError('invalid_worker_result')
            if set(response) == {'protocol', 'requestId', 'error'}:
                raise InstallationIPCError()
            if set(response) != {'protocol', 'requestId', 'result'}:
                raise InstallationIPCError('invalid_worker_result')
            return response['result']
        except InstallationIPCError:
            raise
        except (OSError, ValueError, TypeError, AttributeError, DockerWorkerError, PreflightIPCError):
            raise InstallationIPCError() from None

    def status(self):
        result = self._exchange('status')
        expected = {
            'capability': 'container_execution', 'installAvailable': False,
            'services': ['jellyfin', 'qbittorrent', 'sonarr', 'radarr', 'seerr',
                         'music_assistant'],
        }
        if result != expected:
            raise InstallationIPCError('invalid_worker_result')
        return result

    def execute_music_provider_setup(self, action, *, deadline, gate):
        now = time.monotonic()
        if (type(action) is not PrivateMusicProviderSetupAction
                or type(deadline) not in (int, float) or not math.isfinite(deadline)
                or not now < deadline <= now + 120 or not callable(gate)):
            raise InstallationIPCError('invalid_request')
        try:
            if gate() is not True:
                raise ValueError()
            raw = self._exchange('music_provider_setup', music_provider=action)
            result = ProviderSetupWorkerResult.model_validate(raw)
            if gate() is not True:
                raise ValueError()
            return result
        except InstallationIPCError:
            raise
        except Exception:
            raise InstallationIPCError('invalid_worker_result') from None

    def bootstrap_music_assistant(self, private, *, deadline, gate):
        now = time.monotonic()
        if (type(private) is not PrivateMusicAssistantBootstrap
                or type(deadline) not in (int, float)
                or not math.isfinite(deadline)
                or not now < deadline <= now + 120 or not callable(gate)):
            raise MusicAssistantBootstrapRuntimeError(
                'invalid_music_assistant_bootstrap')
        try:
            if gate() is not True:
                raise ValueError()
        except Exception:
            raise MusicAssistantBootstrapRuntimeError(
                'music_assistant_bootstrap_cancelled') from None
        try:
            result = _music_assistant_bootstrap_result(self._exchange(
                'bootstrap_music_assistant', music_bootstrap=private))
        except MusicAssistantBootstrapRuntimeError:
            raise
        except InstallationIPCError:
            raise MusicAssistantBootstrapRuntimeError(
                'music_assistant_bootstrap_uncertain',
                uncertain_effect=True) from None
        try:
            if gate() is not True:
                raise ValueError()
        except Exception:
            raise MusicAssistantBootstrapRuntimeError(
                'music_assistant_bootstrap_uncertain',
                uncertain_effect=True) from None
        return result

    def read_music_players(self, authority, *, deadline, gate):
        return self._music_playback_exchange(
            'music_players_read', authority, MusicPlaybackReadback,
            deadline, gate)

    def execute_music_playback(self, action, *, deadline, gate):
        return self._music_playback_exchange(
            'music_playback_execute', action, MusicPlaybackWorkerResult,
            deadline, gate)

    def _music_playback_exchange(self, operation, private, model, deadline,
                                 gate):
        now = time.monotonic()
        if (type(private) not in (PrivateMusicPlaybackAuthority,
                                 PrivateMusicPlaybackAction)
                or type(deadline) not in (int, float)
                or not math.isfinite(deadline)
                or not now < deadline <= now + 120 or not callable(gate)):
            raise InstallationIPCError('invalid_request')
        try:
            if gate() is not True:
                raise ValueError()
            result = model.model_validate(self._exchange(
                operation, music_playback=private))
            if gate() is not True:
                raise ValueError()
            return result
        except InstallationIPCError:
            raise
        except Exception:
            raise InstallationIPCError('invalid_worker_result') from None

    def apply(self, step, plan):
        if type(step) is not WorkerStep or type(plan) is not MediaStackPlan:
            raise InstallationIPCError('invalid_request')
        return _receipt(self._exchange('apply', step, plan), step)

    def reconcile(self, step, plan):
        if type(step) is not WorkerStep or type(plan) is not MediaStackPlan:
            raise InstallationIPCError('invalid_request')
        return _receipt(self._exchange('reconcile', step, plan), step)

    def execute(self, job, plan, private, *, deadline, gate):
        now = time.monotonic()
        if (type(job) is not str or re.fullmatch(r'[0-9a-f]{32}', job) is None
                or type(plan) is not MediaStackPlan
                or type(private) is not PrivateMediaServiceBootstrap
                or type(deadline) not in (int, float) or not math.isfinite(deadline)
                or not now < deadline <= now + 120 or not callable(gate)):
            raise JellyfinBootstrapExecutionError('invalid_bootstrap_execution')
        try:
            plan = verify_media_stack_plan(plan, load_catalog())
        except (ValueError, TypeError, AttributeError, OSError):
            raise JellyfinBootstrapExecutionError('invalid_bootstrap_execution') from None
        try:
            permitted = gate()
        except Exception:
            raise JellyfinBootstrapExecutionError('bootstrap_authority_changed') from None
        if permitted is not True:
            raise JellyfinBootstrapExecutionError('bootstrap_authority_changed')
        try:
            return _bootstrap_result(self._exchange(
                'bootstrap', plan=plan, bootstrap=(job, private)))
        except JellyfinBootstrapExecutionError:
            raise
        except InstallationIPCError:
            raise JellyfinBootstrapExecutionError(
                'bootstrap_resources_unavailable') from None

    def bootstrap_seerr(self, job, plan, private, *, deadline, gate):
        now = time.monotonic()
        if (type(job) is not str or re.fullmatch(r'[0-9a-f]{32}', job) is None
                or type(plan) is not MediaStackPlan
                or type(private) is not PrivateSeerrBootstrap
                or type(deadline) not in (int, float) or not math.isfinite(deadline)
                or not now < deadline <= now + 120 or not callable(gate)):
            raise SeerrBootstrapExecutionError(
                'invalid_seerr_bootstrap_execution')
        try:
            plan = verify_media_stack_plan(plan, load_catalog())
            private = PrivateSeerrBootstrap.model_validate(
                private.model_dump(mode='python', warnings=False))
            if private.sourceBootstrapId == job:
                raise ValueError()
        except (ValueError, TypeError, AttributeError, OSError):
            raise SeerrBootstrapExecutionError(
                'invalid_seerr_bootstrap_execution') from None
        try:
            if gate() is not True:
                raise ValueError()
        except Exception:
            raise SeerrBootstrapExecutionError(
                'seerr_bootstrap_authority_changed') from None
        try:
            result = _seerr_bootstrap_result(self._exchange(
                'bootstrap_seerr', plan=plan, seerr=(job, private)))
        except SeerrBootstrapExecutionError:
            raise
        except InstallationIPCError:
            raise SeerrBootstrapExecutionError(
                'seerr_bootstrap_resources_unavailable',
                uncertain_effect=True) from None
        try:
            if gate() is not True:
                raise ValueError()
        except Exception:
            raise SeerrBootstrapExecutionError(
                'seerr_bootstrap_authority_changed',
                uncertain_effect=True) from None
        return result

    def configure_qbittorrent(self, job, plan, private, *, deadline, gate):
        now = time.monotonic()
        if (type(job) is not str or re.fullmatch(r'[0-9a-f]{32}', job) is None
                or type(plan) is not MediaStackPlan
                or type(private) is not PrivateQbittorrentConfiguration
                or type(deadline) not in (int, float) or not math.isfinite(deadline)
                or not now < deadline <= now + 120 or not callable(gate)):
            raise QbittorrentConfigurationExecutionError(
                'qbittorrent_config_resources_unavailable')
        try:
            plan = verify_media_stack_plan(plan, load_catalog())
        except (ValueError, TypeError, AttributeError, OSError):
            raise QbittorrentConfigurationExecutionError(
                'qbittorrent_config_resources_unavailable') from None
        try:
            if gate() is not True:
                raise ValueError()
        except Exception:
            raise QbittorrentConfigurationExecutionError(
                'qbittorrent_config_authority_changed') from None
        try:
            result = _qbittorrent_result(self._exchange(
                'configure_qbittorrent', plan=plan,
                qbittorrent=(job, private)))
        except QbittorrentConfigurationExecutionError:
            raise
        except InstallationIPCError:
            raise QbittorrentConfigurationExecutionError(
                'qbittorrent_config_resources_unavailable') from None
        try:
            if gate() is not True:
                raise ValueError()
        except Exception:
            raise QbittorrentConfigurationExecutionError(
                'qbittorrent_config_authority_changed',
                uncertain_effect=True) from None
        return result

    def install_qbittorrent(self, job, plan, private, *, deadline, gate):
        now = time.monotonic()
        if (type(job) is not str or re.fullmatch(r'[0-9a-f]{32}', job) is None
                or type(plan) is not MediaStackPlan
                or type(private) is not PrivateQbittorrentConfiguration
                or type(deadline) not in (int, float) or not math.isfinite(deadline)
                or not now < deadline <= now + 120 or not callable(gate)):
            raise QbittorrentConfigurationExecutionError(
                'qbittorrent_config_resources_unavailable')
        try:
            plan = verify_media_stack_plan(plan, load_catalog())
        except (ValueError, TypeError, AttributeError, OSError):
            raise QbittorrentConfigurationExecutionError(
                'qbittorrent_config_resources_unavailable') from None
        try:
            if gate() is not True:
                raise ValueError()
        except Exception:
            raise QbittorrentConfigurationExecutionError(
                'qbittorrent_config_authority_changed') from None
        try:
            result = _qbittorrent_install_result(self._exchange(
                'install_configured_qbittorrent', plan=plan,
                qbittorrent=(job, private)))
        except QbittorrentConfigurationExecutionError:
            raise
        except InstallationIPCError:
            raise QbittorrentConfigurationExecutionError(
                'qbittorrent_config_resources_unavailable') from None
        try:
            if gate() is not True:
                raise ValueError()
        except Exception:
            raise QbittorrentConfigurationExecutionError(
                'qbittorrent_config_authority_changed',
                uncertain_effect=True) from None
        return result

    def configure_arr(self, job, plan, private, *, deadline, gate):
        now = time.monotonic()
        if (type(job) is not str
                or re.fullmatch(r'[0-9a-f]{32}', job) is None
                or type(plan) is not MediaStackPlan
                or type(private) is not PrivateArrConfiguration
                or type(deadline) not in (int, float)
                or not math.isfinite(deadline)
                or not now < deadline <= now + 120
                or not callable(gate)):
            raise ArrConfigurationExecutionError(
                'arr_config_resources_unavailable')
        try:
            plan = verify_media_stack_plan(plan, load_catalog())
            private = PrivateArrConfiguration.model_validate(
                private.model_dump(mode='python', warnings=False))
        except (ValueError, TypeError, AttributeError, OSError):
            raise ArrConfigurationExecutionError(
                'arr_config_resources_unavailable') from None
        try:
            if gate() is not True:
                raise ValueError()
        except Exception:
            raise ArrConfigurationExecutionError(
                'arr_config_authority_changed') from None
        try:
            result = _arr_result(self._exchange(
                'configure_arr', plan=plan, arr=(job, private)))
            if result.service_id != private.serviceId:
                raise ArrConfigurationExecutionError(
                    'arr_config_result_invalid', uncertain_effect=True)
        except ArrConfigurationExecutionError:
            raise
        except InstallationIPCError:
            raise ArrConfigurationExecutionError(
                'arr_config_resources_unavailable') from None
        try:
            if gate() is not True:
                raise ValueError()
        except Exception:
            raise ArrConfigurationExecutionError(
                'arr_config_authority_changed',
                uncertain_effect=True) from None
        return result

    def install_arr(self, job, plan, private, *, deadline, gate):
        now = time.monotonic()
        if (type(job) is not str
                or re.fullmatch(r'[0-9a-f]{32}', job) is None
                or type(plan) is not MediaStackPlan
                or type(private) is not PrivateArrConfiguration
                or type(deadline) not in (int, float)
                or not math.isfinite(deadline)
                or not now < deadline <= now + 120
                or not callable(gate)):
            raise ArrConfigurationExecutionError('arr_config_resources_unavailable')
        try:
            plan = verify_media_stack_plan(plan, load_catalog())
            private = PrivateArrConfiguration.model_validate(
                private.model_dump(mode='python', warnings=False))
        except (ValueError, TypeError, AttributeError, OSError):
            raise ArrConfigurationExecutionError(
                'arr_config_resources_unavailable') from None
        try:
            if gate() is not True:
                raise ValueError()
        except Exception:
            raise ArrConfigurationExecutionError(
                'arr_config_authority_changed') from None
        try:
            result = _arr_install_result(self._exchange(
                'install_configured_arr', plan=plan, arr=(job, private)))
            if result.configuration.service_id != private.serviceId:
                raise ArrConfigurationExecutionError(
                    'arr_config_result_invalid', uncertain_effect=True)
        except ArrConfigurationExecutionError:
            raise
        except InstallationIPCError:
            raise ArrConfigurationExecutionError(
                'arr_config_resources_unavailable') from None
        try:
            if gate() is not True:
                raise ValueError()
        except Exception:
            raise ArrConfigurationExecutionError(
                'arr_config_authority_changed', uncertain_effect=True) from None
        return result


class InstallationWorkerServer(PreflightWorkerServer):
    def __init__(self, path, backend, *, allowed_uid, socket_gid=None, peer_uid=None, timeout=5):
        machine = host_platform.machine().lower()
        platform = 'linux/arm64' if machine in {'arm64', 'aarch64'} else 'linux/amd64'
        super().__init__(path, backend, platform=platform, allowed_uid=allowed_uid,
                         socket_gid=socket_gid, peer_uid=peer_uid, timeout=timeout)
        self.backend = backend
        self._backend_ready = threading.Event()
        self._backend_started = False
        self._backend_failed = False

    def start(self):
        if self._listener is not None or self._lock is not None:
            raise PreflightIPCError()
        self._backend_ready.clear()
        self._backend_started = self._backend_failed = False
        super().start()
        if not self._backend_ready.wait(self.timeout) or self._backend_failed:
            try:
                super().close()
            finally:
                raise PreflightIPCError() from None

    def _serve(self):
        try:
            opening = getattr(self.backend, 'open', None)
            if callable(opening):
                opening(time.monotonic() + self.timeout)
            self._backend_started = True
            self._backend_ready.set()
            super()._serve()
        except Exception:
            self._backend_failed = True
            self._stopped.set()
            self._backend_ready.set()
        finally:
            if self._backend_started:
                closing = getattr(self.backend, 'close', None)
                if callable(closing):
                    try:
                        closing()
                    except Exception:
                        self._backend_failed = True
            self._backend_ready.set()

    def close(self):
        super().close()
        if self._backend_failed:
            raise PreflightIPCError()

    def _answer(self, request, *, deadline=None):
        deadline = time.monotonic() + self.timeout if deadline is None else deadline
        operation = request.get('operation')
        if operation == 'status' and set(request) == {'protocol', 'requestId', 'operation'}:
            return {
                'capability': 'container_execution', 'installAvailable': False,
                'services': [
                    'jellyfin', 'qbittorrent', 'sonarr', 'radarr', 'seerr',
                    'music_assistant'],
            }
        if operation == 'music_provider_setup':
            if (set(request) != {
                    'protocol', 'requestId', 'operation', 'private'}
                    or time.monotonic() >= deadline):
                raise PreflightIPCError('invalid_request')
            try:
                raw = json.dumps(request['private'], sort_keys=True,
                                 separators=(',', ':'), allow_nan=False)
                action = PrivateMusicProviderSetupAction.model_validate_json(raw)
                cancelled = threading.Event()
                timed = getattr(
                    self.backend, 'execute_music_provider_setup_with_deadline',
                    None)
                result = (timed(action, deadline)
                          if callable(timed)
                          else self.backend.execute_music_provider_setup(
                              action, deadline=deadline,
                              gate=lambda: time.monotonic() < deadline))
                if (time.monotonic() >= deadline
                        or type(result) is not ProviderSetupWorkerResult):
                    raise ValueError()
                return result.model_dump(mode='json', warnings=False)
            except Exception:
                raise PreflightIPCError('invalid_request') from None
        if operation == 'bootstrap_music_assistant':
            if (set(request) != {
                    'protocol', 'requestId', 'operation', 'private'}
                    or time.monotonic() >= deadline):
                raise PreflightIPCError('invalid_request')
            try:
                raw = json.dumps(request['private'], sort_keys=True,
                                 separators=(',', ':'), allow_nan=False)
                private = PrivateMusicAssistantBootstrap.model_validate_json(raw)
            except (ValueError, TypeError, AttributeError, RecursionError):
                raise PreflightIPCError('invalid_request') from None
            try:
                timed = getattr(
                    self.backend, 'bootstrap_music_assistant_with_deadline',
                    None)
                result = (timed(private, deadline) if callable(timed)
                          else self.backend.bootstrap_music_assistant(
                              private.installationId, private.username,
                              private.credential, deadline=deadline,
                              gate=lambda: time.monotonic() < deadline))
            except MusicAssistantBootstrapRuntimeError as error:
                return _wire_music_assistant_bootstrap(error=error)
            except Exception:
                return _wire_music_assistant_bootstrap(error=
                    MusicAssistantBootstrapRuntimeError(
                        'music_assistant_bootstrap_uncertain',
                        uncertain_effect=True))
            if time.monotonic() >= deadline:
                return _wire_music_assistant_bootstrap(error=
                    MusicAssistantBootstrapRuntimeError(
                        'music_assistant_bootstrap_uncertain',
                        uncertain_effect=True))
            try:
                return _wire_music_assistant_bootstrap(value=result)
            except InstallationIPCError:
                return _wire_music_assistant_bootstrap(error=
                    MusicAssistantBootstrapRuntimeError(
                        'music_assistant_bootstrap_readback_changed',
                        uncertain_effect=True))
        if operation in {'music_players_read', 'music_playback_execute'}:
            if (set(request) != {
                    'protocol', 'requestId', 'operation', 'private'}
                    or time.monotonic() >= deadline):
                raise PreflightIPCError('invalid_request')
            try:
                raw = json.dumps(request['private'], sort_keys=True,
                                 separators=(',', ':'), allow_nan=False)
                model = (PrivateMusicPlaybackAuthority
                         if operation == 'music_players_read'
                         else PrivateMusicPlaybackAction)
                private = model.model_validate_json(raw)
                method = ('read_music_players'
                          if operation == 'music_players_read'
                          else 'execute_music_playback')
                timed = getattr(self.backend, method + '_with_deadline', None)
                result = (timed(private, deadline) if callable(timed)
                          else getattr(self.backend, method)(
                              private, deadline=deadline,
                              gate=lambda: time.monotonic() < deadline))
                expected = (MusicPlaybackReadback
                            if operation == 'music_players_read'
                            else MusicPlaybackWorkerResult)
                if time.monotonic() >= deadline or type(result) is not expected:
                    raise ValueError()
                return result.model_dump(mode='json', warnings=False)
            except Exception:
                raise PreflightIPCError('invalid_request') from None
        if operation in {'configure_arr', 'install_configured_arr'}:
            if (set(request) != {
                    'protocol', 'requestId', 'operation', 'jobId', 'plan',
                    'private'}
                    or type(request['jobId']) is not str
                    or re.fullmatch(r'[0-9a-f]{32}', request['jobId']) is None
                    or time.monotonic() >= deadline):
                raise PreflightIPCError('invalid_request')
            try:
                raw_plan = json.dumps(
                    request['plan'], sort_keys=True, separators=(',', ':'),
                    allow_nan=False)
                raw_private = json.dumps(
                    request['private'], sort_keys=True, separators=(',', ':'),
                    allow_nan=False)
                plan = verify_media_stack_plan(
                    MediaStackPlan.model_validate_json(raw_plan), self.catalog)
                private = PrivateArrConfiguration.model_validate_json(
                    raw_private)
                cancelled = threading.Event()
                method = ('configure_arr' if operation == 'configure_arr'
                          else 'install_configured_arr')
                timed = getattr(self.backend, method + '_with_deadline', None)
                private_arguments = {'api_key': private.apiKey}
                if (operation == 'install_configured_arr'
                        and private.qbittorrentApiKey is not None):
                    private_arguments['qbittorrent_api_key'] = (
                        private.qbittorrentApiKey)
                try:
                    result = (timed(
                        request['jobId'], plan, private.serviceId,
                        **private_arguments, cancelled=cancelled,
                        deadline=deadline,
                    ) if callable(timed) else getattr(self.backend, method)(
                        request['jobId'], plan, private.serviceId,
                        **private_arguments, cancelled=cancelled,
                        deadline=deadline,
                        gate=lambda: time.monotonic() < deadline))
                except Exception as error:
                    return _wire_arr(error=error)
                if time.monotonic() >= deadline:
                    return _wire_arr(error=ArrConfigurationExecutionError(
                        'arr_config_timeout', uncertain_effect=True))
                if operation == 'configure_arr':
                    return _wire_arr(value=result)
                try:
                    return _wire_arr_install(result)
                except InstallationIPCError:
                    return _wire_arr(error=ArrConfigurationExecutionError(
                        'arr_config_result_invalid', uncertain_effect=True))
            except (ValueError, TypeError, AttributeError, RecursionError):
                raise PreflightIPCError('invalid_request') from None
        if operation in {
                'configure_qbittorrent',
                'install_configured_qbittorrent'}:
            if (set(request) != {
                    'protocol', 'requestId', 'operation', 'jobId', 'plan', 'private'}
                    or type(request['jobId']) is not str
                    or re.fullmatch(r'[0-9a-f]{32}', request['jobId']) is None
                    or time.monotonic() >= deadline):
                raise PreflightIPCError('invalid_request')
            try:
                raw_plan = json.dumps(
                    request['plan'], sort_keys=True, separators=(',', ':'),
                    allow_nan=False)
                raw_private = json.dumps(
                    request['private'], sort_keys=True, separators=(',', ':'),
                    allow_nan=False)
                plan = verify_media_stack_plan(
                    MediaStackPlan.model_validate_json(raw_plan), self.catalog)
                private = PrivateQbittorrentConfiguration.model_validate_json(
                    raw_private)
                cancelled = threading.Event()
                method = ('configure_qbittorrent' if operation == 'configure_qbittorrent'
                          else 'install_configured_qbittorrent')
                timed = getattr(self.backend, method + '_with_deadline', None)
                try:
                    result = (timed(
                        request['jobId'], plan, private.credential,
                        api_key=private.apiKey,
                        salt=bytes.fromhex(private.saltHex),
                        cancelled=cancelled, deadline=deadline,
                    ) if callable(timed) else getattr(self.backend, method)(
                        request['jobId'], plan, private.credential,
                        api_key=private.apiKey,
                        salt=bytes.fromhex(private.saltHex),
                        cancelled=cancelled, deadline=deadline,
                        gate=lambda: time.monotonic() < deadline))
                except Exception as error:
                    return _wire_qbittorrent(error=error)
                if time.monotonic() >= deadline:
                    return _wire_qbittorrent(error=
                        QbittorrentConfigurationExecutionError(
                            'qbittorrent_config_timeout', uncertain_effect=True))
                if operation == 'configure_qbittorrent':
                    return _wire_qbittorrent(value=result)
                try:
                    return _wire_qbittorrent_install(result)
                except InstallationIPCError:
                    return _wire_qbittorrent(error=
                        QbittorrentConfigurationExecutionError(
                            'qbittorrent_config_result_invalid',
                            uncertain_effect=True))
            except (ValueError, TypeError, AttributeError, RecursionError):
                raise PreflightIPCError('invalid_request') from None
        if operation in {'bootstrap', 'bootstrap_seerr'}:
            if (set(request) != {
                    'protocol', 'requestId', 'operation', 'jobId', 'plan', 'private'}
                    or type(request['jobId']) is not str
                    or re.fullmatch(r'[0-9a-f]{32}', request['jobId']) is None
                    or time.monotonic() >= deadline):
                raise PreflightIPCError('invalid_request')
            try:
                raw_plan = json.dumps(
                    request['plan'], sort_keys=True, separators=(',', ':'),
                    allow_nan=False)
                raw_private = json.dumps(
                    request['private'], sort_keys=True, separators=(',', ':'),
                    allow_nan=False)
                plan = verify_media_stack_plan(
                    MediaStackPlan.model_validate_json(raw_plan), self.catalog)
                private_model = (PrivateMediaServiceBootstrap
                                 if operation == 'bootstrap'
                                 else PrivateSeerrBootstrap)
                private = private_model.model_validate_json(raw_private)
                method = ('bootstrap' if operation == 'bootstrap'
                          else 'bootstrap_seerr')
                timed = getattr(self.backend, method + '_with_deadline', None)
                try:
                    result = (timed(request['jobId'], plan, private, deadline)
                              if callable(timed) else getattr(self.backend, method)(
                                  request['jobId'], plan, private,
                                  deadline=deadline))
                except (JellyfinBootstrapExecutionError,
                        SeerrBootstrapExecutionError) as error:
                    return (_wire_bootstrap(error=error)
                            if operation == 'bootstrap'
                            else _wire_seerr_bootstrap(error=error))
                if time.monotonic() >= deadline:
                    if operation == 'bootstrap':
                        raise JellyfinBootstrapExecutionError('bootstrap_timeout')
                    raise SeerrBootstrapExecutionError(
                        'seerr_bootstrap_timeout', uncertain_effect=True)
                if operation == 'bootstrap':
                    return _wire_bootstrap(value=result)
                try:
                    return _wire_seerr_bootstrap(value=result)
                except InstallationIPCError:
                    return _wire_seerr_bootstrap(error=
                        SeerrBootstrapExecutionError(
                            'seerr_bootstrap_resources_unavailable',
                            uncertain_effect=True))
            except (JellyfinBootstrapExecutionError,
                    SeerrBootstrapExecutionError) as error:
                return (_wire_bootstrap(error=error)
                        if operation == 'bootstrap'
                        else _wire_seerr_bootstrap(error=error))
            except (ValueError, TypeError, AttributeError, DockerWorkerError,
                    InstallationIPCError):
                raise PreflightIPCError('invalid_request') from None
        if (operation not in {'apply', 'reconcile'}
                or set(request) != {'protocol', 'requestId', 'operation', 'step', 'plan'}
                or time.monotonic() >= deadline):
            raise PreflightIPCError('invalid_request')
        try:
            raw = json.dumps(request['plan'], sort_keys=True, separators=(',', ':'), allow_nan=False)
            plan = MediaStackPlan.model_validate_json(raw)
            step = WorkerStep(**request['step'])
            service_for_step(step, plan)
            if time.monotonic() >= deadline:
                raise ValueError()
            timed = getattr(self.backend, operation + '_with_deadline', None)
            result = (timed(step, plan, deadline) if callable(timed)
                      else getattr(self.backend, operation)(step, plan))
            result = _receipt(result, step)
            if time.monotonic() >= deadline:
                raise ValueError()
            return _wire_receipt(result)
        except (ValueError, TypeError, AttributeError, DockerWorkerError, InstallationIPCError):
            raise PreflightIPCError('invalid_request') from None
