"""Journal-bound Sonarr/Radarr config install through one disposable helper.

Only a previously rendered and re-verifiable private config binding can reach
the effect. The helper image, mount, command, user, limits and Engine routes are
fixed. Config bytes travel through the bounded Unix Engine stdin transport and
never enter container metadata, errors, logs owned by this adapter or public
models. The operation has no retry or cleanup of ambiguous retained data.
"""

from dataclasses import dataclass, fields
import hashlib
import hmac
import re
import threading
from urllib.parse import urlencode
import uuid

from .docker_probe import DockerEndpoint
from .engine_stdin import EngineStdinError, EngineStdinLimits, UnixEngineStdin
from .arr_config_binding import (
    ArrConfigBinding,
    verify_arr_config_binding,
)
from .worker import DockerWorkerError, UnixDockerEngine, _canonical, _decode


_IMAGE_ID = re.compile(r'sha256:[0-9a-f]{64}\Z')
_CONTAINER_ID = re.compile(r'[0-9a-f]{64}\Z')
_NAME = re.compile(r'[0-9a-f]{32}\Z')
_IDENTIFIER = re.compile(r'[0-9a-f]{32}\Z')
_DIGEST = re.compile(r'[0-9a-f]{64}\Z')
_SERVICE_STATES = {
    'sonarr': frozenset({
        'sonarr_config_installed', 'sonarr_config_already_installed'}),
    'radarr': frozenset({
        'radarr_config_installed', 'radarr_config_already_installed'}),
}
_STATES = frozenset().union(*_SERVICE_STATES.values())
_CODES = frozenset({
    'arr_config_effect_untrusted',
    'arr_config_effect_configuration_invalid',
    'arr_config_effect_dispatch_denied',
    'arr_config_effect_cancelled',
    'arr_config_effect_create_failed',
    'arr_config_effect_start_failed',
    'arr_config_effect_stream_failed',
    'arr_config_effect_result_failed',
    'arr_config_effect_wait_failed',
    'arr_config_effect_cleanup_failed',
    'arr_config_effect_authority_changed',
})
_CAUSE_CODES = frozenset({
    'engine_stdin_invalid', 'engine_stdin_invalid_limits',
    'engine_stdin_protocol', 'engine_stdin_response_limit',
    'engine_stdin_unavailable', 'engine_stdin_timeout',
    'engine_stdin_cancelled', 'engine_stdin_api_unsupported',
    'engine_stdin_dispatch_denied',
    'engine_stdin_version_protocol',
    'engine_stdin_attach_protocol',
    'engine_stdin_frames_protocol',
})


class ArrConfigEffectError(Exception):
    def __init__(self, code='arr_config_effect_untrusted', *,
                 uncertain_effect=False, cause_code=None):
        self.code = code if code in _CODES else 'arr_config_effect_untrusted'
        self.uncertain_effect = uncertain_effect is True
        self.cause_code = cause_code if cause_code in _CAUSE_CODES else None
        super().__init__(self.code)

    def __repr__(self):
        return (f'ArrConfigEffectError({self.code!r}, '
                f'uncertain_effect={self.uncertain_effect!r}, '
                f'cause_code={self.cause_code!r})')


def _require(value, code='arr_config_effect_untrusted', *, uncertain=False):
    if not value:
        raise ArrConfigEffectError(code, uncertain_effect=uncertain)


def _exact(value, cls):
    return type(value) is cls and set(vars(value)) == {
        item.name for item in fields(cls)}


def _binding(value):
    _require(_exact(value, ArrConfigBinding))
    try:
        selected = ArrConfigBinding(**vars(value))
    except (TypeError, ValueError):
        raise ArrConfigEffectError() from None
    _require(all(_IDENTIFIER.fullmatch(item) is not None for item in (
        selected.resource_id, selected.operation_id, selected.journal_id,
        selected.ownership_nonce))
        and type(selected.revision) is int
        and 3 <= selected.revision <= 2**63 - 2
        and selected.service_id in _SERVICE_STATES
        and selected.volume_name
        == 'larenor-appdata-v1-' + selected.resource_id
        and selected.relative_path == 'config.xml'
        and type(selected.configuration) is bytes
        and 1 <= len(selected.configuration) <= 4096
        and _DIGEST.fullmatch(selected.configuration_digest) is not None
        and hmac.compare_digest(
            hashlib.sha256(selected.configuration).hexdigest(),
            selected.configuration_digest))
    return selected


@dataclass(frozen=True, repr=False)
class ArrConfigHelperResult:
    state: str
    configuration_digest: str

    def __post_init__(self):
        _require(self.state in _STATES
                 and type(self.configuration_digest) is str
                 and _DIGEST.fullmatch(self.configuration_digest) is not None,
                 'arr_config_effect_result_failed')

    def __repr__(self):
        return 'ArrConfigHelperResult(<private>)'


@dataclass(frozen=True, repr=False)
class ArrConfigInstallReceipt:
    service_id: str
    resource_id: str
    operation_id: str
    journal_id: str
    revision: int
    volume_name: str
    configuration_digest: str
    state: str

    def __post_init__(self):
        _require(self.service_id in _SERVICE_STATES
                 and all(
                     type(item) is str
                     and _IDENTIFIER.fullmatch(item) is not None
                     for item in (self.resource_id, self.operation_id,
                                  self.journal_id))
                 and type(self.revision) is int
                 and 3 <= self.revision <= 2**63 - 2
                 and self.volume_name
                 == 'larenor-appdata-v1-' + self.resource_id
                 and type(self.configuration_digest) is str
                 and _DIGEST.fullmatch(self.configuration_digest) is not None
                 and self.state in _SERVICE_STATES[self.service_id],
                 'arr_config_effect_result_failed')

    def __repr__(self):
        return 'ArrConfigInstallReceipt(<private>)'


def _helper_result(stdout, stderr, digest, service_id):
    _require(stderr == b'' and type(stdout) is bytes and len(stdout) <= 4096,
             'arr_config_effect_result_failed', uncertain=True)
    _require(service_id in _SERVICE_STATES,
             'arr_config_effect_result_failed', uncertain=True)
    for state in _SERVICE_STATES[service_id]:
        expected = _canonical({
            'schemaVersion': 1,
            'sha256': digest,
            'state': state,
        }) + b'\n'
        if hmac.compare_digest(stdout, expected):
            return ArrConfigHelperResult(state, digest)
    raise ArrConfigEffectError(
        'arr_config_effect_result_failed', uncertain_effect=True)


class UnixArrConfigEngine:
    """Create/start/stream/wait/remove one fixed networks-off helper."""

    def __init__(self, endpoint, *, transport_factory=None, stdin_factory=None,
                 name_factory=None, peer_uid=None):
        try:
            _require(type(endpoint) is DockerEndpoint
                     and (transport_factory is None or callable(transport_factory))
                     and (stdin_factory is None or callable(stdin_factory))
                     and (name_factory is None or callable(name_factory))
                     and (peer_uid is None or callable(peer_uid)),
                     'arr_config_effect_configuration_invalid')
            self._endpoint = endpoint
            self._transport = (UnixDockerEngine(
                endpoint.path, timeout=1.0, socket_uid=endpoint.owner_uid,
                peer_uid=peer_uid) if transport_factory is None
                else transport_factory(endpoint))
            self._stdin = (UnixEngineStdin(endpoint, peer_uid=peer_uid)
                           if stdin_factory is None else stdin_factory(endpoint))
            _require(callable(getattr(self._transport, '_exchange', None))
                     and getattr(self._stdin, '_endpoint', None) is endpoint
                     and callable(getattr(self._stdin, 'exchange', None)),
                     'arr_config_effect_configuration_invalid')
            self._name_factory = uuid.uuid4 if name_factory is None else name_factory
        except (ValueError, TypeError, AttributeError, DockerWorkerError,
                EngineStdinError, ArrConfigEffectError):
            raise ArrConfigEffectError(
                'arr_config_effect_configuration_invalid') from None

    @staticmethod
    def _response(response, status, code, *, body=False, uncertain=False):
        _require(type(getattr(response, 'status', None)) is int
                 and response.status == status,
                 code, uncertain=uncertain)
        raw = getattr(response, 'body', None)
        _require(type(raw) is bytes and (body or raw == b''),
                 code, uncertain=uncertain)
        if not body:
            return None
        try:
            value = _decode(raw, 4096)
        except DockerWorkerError:
            raise ArrConfigEffectError(
                code, uncertain_effect=uncertain) from None
        _require(type(value) is dict, code, uncertain=uncertain)
        return value

    @staticmethod
    def _body(binding, image_id):
        selected = _binding(binding)
        _require(type(image_id) is str and _IMAGE_ID.fullmatch(image_id) is not None,
                 'arr_config_effect_configuration_invalid')
        return _canonical({
            'Image': image_id,
            'User': '1000:1000',
            'Entrypoint': [
                '/usr/local/bin/python', '-I',
                '/opt/larenor/volume_bootstrap_helper.py'],
            'Cmd': ['install_' + selected.service_id + '_config'],
            'AttachStdin': True,
            'AttachStdout': True,
            'AttachStderr': True,
            'OpenStdin': True,
            'StdinOnce': True,
            'Tty': False,
            'NetworkDisabled': True,
            'Labels': {
                'org.larenor.config-effect-schema': '1',
                'org.larenor.resource': selected.resource_id,
                'org.larenor.volume-journal': selected.journal_id,
                'org.larenor.ownership-nonce': selected.ownership_nonce,
                'org.larenor.configuration': selected.configuration_digest,
                'org.larenor.service': selected.service_id,
            },
            'HostConfig': {
                'NetworkMode': 'none',
                'ReadonlyRootfs': True,
                'CapDrop': ['ALL'],
                'CapAdd': [],
                'SecurityOpt': ['no-new-privileges:true'],
                'Memory': 64 * 1048576,
                'MemorySwap': -1,
                'PidsLimit': 32,
                'AutoRemove': False,
                'Mounts': [{
                    'Type': 'volume', 'Source': selected.volume_name,
                    'Target': '/volume', 'ReadOnly': False,
                    'VolumeOptions': {'NoCopy': True},
                }],
            },
        })

    @staticmethod
    def _gate(before_dispatch):
        try:
            permitted = before_dispatch() is True
        except Exception:
            raise ArrConfigEffectError(
                'arr_config_effect_dispatch_denied') from None
        _require(permitted, 'arr_config_effect_dispatch_denied')

    def install(self, binding, helper_image_id, platform, *, cancelled,
                before_dispatch):
        selected = _binding(binding)
        _require(type(helper_image_id) is str
                 and _IMAGE_ID.fullmatch(helper_image_id) is not None
                 and platform in {'linux/amd64', 'linux/arm64'}
                 and type(cancelled) is threading.Event
                 and callable(before_dispatch),
                 'arr_config_effect_untrusted')
        _require(not cancelled.is_set(), 'arr_config_effect_cancelled')
        suffix = self._name_factory()
        suffix = suffix.hex if isinstance(suffix, uuid.UUID) else suffix
        _require(type(suffix) is str and _NAME.fullmatch(suffix) is not None)
        body = self._body(selected, helper_image_id)
        identity = None
        result = None
        failure = None
        cause_code = None
        uncertain = False
        stage = 'create'
        try:
            self._gate(before_dispatch)
            _require(self._body(selected, helper_image_id) == body)
            target = '/containers/create?' + urlencode({
                'name': 'larenor-arr-config-' + suffix,
                'platform': platform,
            })
            created = self._response(
                self._transport._exchange('POST', target, body), 201,
                'arr_config_effect_create_failed', body=True)
            created_identity = created.get('Id')
            _require(type(created_identity) is str
                     and _CONTAINER_ID.fullmatch(created_identity) is not None
                     and created.get('Warnings') in (None, []),
                     'arr_config_effect_create_failed', uncertain=True)
            identity = created_identity
            _require(not cancelled.is_set(),
                     'arr_config_effect_cancelled')
            stage = 'start'
            self._response(self._transport._exchange(
                'POST', f'/containers/{identity}/start'), 204,
                'arr_config_effect_start_failed')
            uncertain = True
            _require(not cancelled.is_set(),
                     'arr_config_effect_cancelled')
            stage = 'stream'
            result = self._stdin.exchange(
                identity, selected.configuration,
                lambda stdout, stderr: _helper_result(
                    stdout, stderr, selected.configuration_digest,
                    selected.service_id),
                platform=platform,
                limits=EngineStdinLimits(10, 2, 4096, 32),
                before_dispatch=before_dispatch,
                cancelled=cancelled,
            )
            stage = 'wait'
            waited = self._response(self._transport._exchange(
                'POST', f'/containers/{identity}/wait?condition=not-running'),
                200, 'arr_config_effect_wait_failed', body=True,
                uncertain=True)
            _require(type(waited.get('StatusCode')) is int
                     and waited['StatusCode'] == 0
                     and waited.get('Error') is None,
                     'arr_config_effect_wait_failed', uncertain=True)
            _require(_exact(result, ArrConfigHelperResult))
            result = ArrConfigHelperResult(**vars(result))
            _require(result.configuration_digest == selected.configuration_digest)
        except ArrConfigEffectError as error:
            failure = error.code
            uncertain = uncertain or error.uncertain_effect
        except EngineStdinError as error:
            failure = {
                'engine_stdin_cancelled': 'arr_config_effect_cancelled',
                'engine_stdin_dispatch_denied':
                    'arr_config_effect_dispatch_denied',
            }.get(error.code, 'arr_config_effect_stream_failed')
            cause_code = error.code
            uncertain = True
        except Exception:
            failure = 'arr_config_effect_' + stage + '_failed'
        finally:
            if identity is not None:
                try:
                    cleanup = self._transport._exchange(
                        'DELETE',
                        f'/containers/{identity}?force=1&v=0')
                    self._response(
                        cleanup, 204,
                        'arr_config_effect_cleanup_failed',
                        uncertain=uncertain)
                except Exception:
                    failure = 'arr_config_effect_cleanup_failed'
                    uncertain = True
        if failure is not None:
            raise ArrConfigEffectError(
                failure, uncertain_effect=uncertain,
                cause_code=cause_code) from None
        return result


class ArrConfigInstaller:
    """Rebind the private journal source around the single helper effect."""

    def __init__(self, endpoint, helper_image_id, platform, *,
                 engine_factory=None, peer_uid=None):
        try:
            _require(type(endpoint) is DockerEndpoint
                     and type(helper_image_id) is str
                     and _IMAGE_ID.fullmatch(helper_image_id) is not None
                     and platform in {'linux/amd64', 'linux/arm64'}
                     and (engine_factory is None or callable(engine_factory))
                     and (peer_uid is None or callable(peer_uid)),
                     'arr_config_effect_configuration_invalid')
            self._endpoint = endpoint
            self._helper_image_id = helper_image_id
            self._platform = platform
            self._engine = (UnixArrConfigEngine(
                endpoint, peer_uid=peer_uid) if engine_factory is None
                else engine_factory(endpoint))
            _require(getattr(self._engine, '_endpoint', None) is endpoint
                     and callable(getattr(self._engine, 'install', None)),
                     'arr_config_effect_configuration_invalid')
        except (ValueError, TypeError, AttributeError,
                ArrConfigEffectError):
            raise ArrConfigEffectError(
                'arr_config_effect_configuration_invalid') from None

    def install(self, binding, journal, intent, *, api_key,
                cancelled, before_dispatch):
        try:
            selected = _binding(binding)
            _require(type(cancelled) is threading.Event
                     and callable(before_dispatch)
                     and verify_arr_config_binding(
                         selected, journal, intent, api_key=api_key))
            _require(not cancelled.is_set(),
                     'arr_config_effect_cancelled')
        except ArrConfigEffectError:
            raise
        except Exception:
            raise ArrConfigEffectError() from None
        try:
            result = self._engine.install(
                selected, self._helper_image_id, self._platform,
                cancelled=cancelled, before_dispatch=before_dispatch)
        except ArrConfigEffectError:
            raise
        except Exception:
            raise ArrConfigEffectError() from None
        try:
            _require(_exact(result, ArrConfigHelperResult),
                     'arr_config_effect_authority_changed',
                     uncertain=True)
            result = ArrConfigHelperResult(**vars(result))
            _require(result.configuration_digest
                     == selected.configuration_digest
                     and result.state in _SERVICE_STATES[selected.service_id]
                     and verify_arr_config_binding(
                         selected, journal, intent, api_key=api_key),
                     'arr_config_effect_authority_changed',
                     uncertain=True)
            _require(before_dispatch() is True,
                     'arr_config_effect_authority_changed',
                     uncertain=True)
            return ArrConfigInstallReceipt(
                selected.service_id, selected.resource_id,
                selected.operation_id, selected.journal_id,
                selected.revision, selected.volume_name,
                selected.configuration_digest, result.state)
        except ArrConfigEffectError:
            raise
        except Exception:
            raise ArrConfigEffectError(
                'arr_config_effect_authority_changed',
                uncertain_effect=True) from None
