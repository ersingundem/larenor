"""Fixed Docker helper for read-only managed-volume root verification.

This worker-only adapter accepts a retained ``VolumeCreateIntent`` from the
private journal and runs one exact helper image as an ephemeral container.  It
does not accept a command, Docker JSON, bind mount, host path, network, image
reference or cleanup option from IPC/API callers.
"""

import re
import threading
from urllib.parse import urlencode
import uuid

from .docker_probe import DockerEndpoint
from .volume_create_journal import VolumeCreateIntent, _exact
from .volume_resources import _binding
from .worker import DockerWorkerError, UnixDockerEngine, _canonical, _decode


_IMAGE_ID = re.compile(r'sha256:[0-9a-f]{64}\Z')
_CONTAINER_ID = re.compile(r'[0-9a-f]{64}\Z')
_HELPER_NAME = re.compile(r'[0-9a-f]{32}\Z')


class VolumeBootstrapError(Exception):
    def __init__(self, code='bootstrap_unavailable'):
        self.code = code if code in {
            'bootstrap_configuration_invalid', 'bootstrap_unavailable',
            'bootstrap_create_failed', 'bootstrap_start_failed',
            'bootstrap_wait_failed', 'bootstrap_result_failed',
            'bootstrap_cleanup_failed', 'bootstrap_cleanup_status_failed',
            'bootstrap_cleanup_transport_failed',
        } else 'bootstrap_unavailable'
        super().__init__(self.code)


def _require(value, code='bootstrap_unavailable'):
    if not value:
        raise VolumeBootstrapError(code)


def _intent(value):
    try:
        _require(_exact(value, VolumeCreateIntent))
        selected = _binding(value.binding)
        receipt = value.receipt
        _require(receipt.resource_id == selected.resource_id)
        _require(receipt.operation_id == selected.resource.operationId)
        _require(receipt.plan_hash == selected.source[0].planHash)
        _require(receipt.worker_policy_digest == selected.source[0].workerPolicyDigest)
        _require(receipt.state == 'observed_requires_bootstrap')
        _require(type(receipt.revision) is int and 3 <= receipt.revision <= 2**63 - 2)
        _require(type(value.specification_digest) is str
                 and re.fullmatch(r'[0-9a-f]{64}', value.specification_digest) is not None)
        return value
    except (ValueError, TypeError, AttributeError, RecursionError, VolumeBootstrapError):
        raise VolumeBootstrapError() from None


class UnixVolumeBootstrapEngine:
    """Exact create/start/wait/remove transport for the packaged helper."""

    def __init__(self, endpoint, *, transport_factory=None, name_factory=None):
        try:
            _require(type(endpoint) is DockerEndpoint, 'bootstrap_configuration_invalid')
            _require(transport_factory is None or callable(transport_factory),
                     'bootstrap_configuration_invalid')
            _require(name_factory is None or callable(name_factory),
                     'bootstrap_configuration_invalid')
            self._endpoint = endpoint
            if transport_factory is None:
                self._transport = UnixDockerEngine(
                    endpoint.path, timeout=1.0, socket_uid=endpoint.owner_uid,
                )
                self._cleanup_transport = UnixDockerEngine(
                    endpoint.path, timeout=10.0, socket_uid=endpoint.owner_uid,
                )
            else:
                self._transport = transport_factory(endpoint)
                self._cleanup_transport = self._transport
            _require(all(callable(getattr(transport, '_exchange', None)) for transport in (
                self._transport, self._cleanup_transport,
            )),
                     'bootstrap_configuration_invalid')
            self._name_factory = (lambda: uuid.uuid4().hex) if name_factory is None else name_factory
        except (ValueError, TypeError, AttributeError, DockerWorkerError,
                VolumeBootstrapError, RecursionError):
            raise VolumeBootstrapError('bootstrap_configuration_invalid') from None

    @staticmethod
    def _response(response, status, *, body=False):
        _require(type(getattr(response, 'status', None)) is int and response.status == status)
        raw = getattr(response, 'body', None)
        _require(type(raw) is bytes and (body or raw == b''))
        return _decode(raw, 4096) if body else None

    @staticmethod
    def _body(intent, image_id):
        binding = intent.binding
        return _canonical({
            'Image': image_id,
            'User': '1000:1000',
            'Entrypoint': [
                '/usr/local/bin/python', '-I',
                '/opt/larenor/volume_bootstrap_helper.py',
            ],
            'Cmd': ['verify_root'],
            'Labels': {
                'org.larenor.bootstrap-schema': '1',
                'org.larenor.resource': binding.resource_id,
                'org.larenor.volume-journal': binding.journal_id,
                'org.larenor.ownership-nonce': binding.ownership_nonce,
            },
            'NetworkDisabled': True,
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
                    'Type': 'volume',
                    'Source': binding.resource.name,
                    'Target': '/volume',
                    'ReadOnly': True,
                    'VolumeOptions': {'NoCopy': True},
                }],
            },
        })

    def verify_root(self, intent, helper_image_id, platform, *, cancelled):
        intent = _intent(intent)
        _require(type(helper_image_id) is str and _IMAGE_ID.fullmatch(helper_image_id) is not None)
        _require(platform in {'linux/amd64', 'linux/arm64'})
        _require(type(cancelled) is threading.Event and not cancelled.is_set())
        suffix = self._name_factory()
        _require(type(suffix) is str and _HELPER_NAME.fullmatch(suffix) is not None)
        identity = None
        failure = None
        stage = 'create'
        try:
            target = '/containers/create?' + urlencode({
                'name': 'larenor-bootstrap-' + suffix,
                'platform': platform,
            })
            result = self._response(
                self._transport._exchange('POST', target, self._body(intent, helper_image_id)),
                201,
                body=True,
            )
            identity = result.get('Id')
            _require(type(identity) is str and _CONTAINER_ID.fullmatch(identity) is not None)
            _require(result.get('Warnings') in (None, []))
            _require(not cancelled.is_set())
            stage = 'start'
            self._response(self._transport._exchange(
                'POST', f'/containers/{identity}/start'), 204)
            _require(not cancelled.is_set())
            stage = 'wait'
            waited = self._response(self._transport._exchange(
                'POST', f'/containers/{identity}/wait?condition=not-running'),
                200,
                body=True,
            )
            stage = 'result'
            _require(set(waited) == {'StatusCode', 'Error'})
            _require(type(waited['StatusCode']) is int and waited['StatusCode'] == 0)
            _require(waited['Error'] is None)
            _require(not cancelled.is_set())
        except Exception:
            failure = 'bootstrap_' + stage + '_failed'
        finally:
            if identity is not None:
                try:
                    cleanup = self._cleanup_transport._exchange(
                        'DELETE', f'/containers/{identity}')
                except Exception:
                    failure = 'bootstrap_cleanup_transport_failed'
                else:
                    try:
                        self._response(cleanup, 204)
                    except Exception:
                        failure = 'bootstrap_cleanup_status_failed'
        if failure is not None:
            raise VolumeBootstrapError(failure) from None
        return True


class VolumeBootstrapVerifier:
    """Return only a revision-bound proof from the exact helper result."""

    def __init__(self, endpoint, helper_image_id, platform, *, engine_factory=None):
        try:
            _require(type(endpoint) is DockerEndpoint, 'bootstrap_configuration_invalid')
            _require(type(helper_image_id) is str and _IMAGE_ID.fullmatch(helper_image_id) is not None,
                     'bootstrap_configuration_invalid')
            _require(platform in {'linux/amd64', 'linux/arm64'},
                     'bootstrap_configuration_invalid')
            _require(engine_factory is None or callable(engine_factory),
                     'bootstrap_configuration_invalid')
            self._endpoint = endpoint
            self._helper_image_id = helper_image_id
            self._platform = platform
            factory = UnixVolumeBootstrapEngine if engine_factory is None else engine_factory
            self._engine = factory(endpoint)
            _require(getattr(self._engine, '_endpoint', None) is endpoint
                     and callable(getattr(self._engine, 'verify_root', None)),
                     'bootstrap_configuration_invalid')
        except (ValueError, TypeError, AttributeError, DockerWorkerError,
                VolumeBootstrapError, RecursionError):
            raise VolumeBootstrapError('bootstrap_configuration_invalid') from None

    def verify(self, intent, *, cancelled):
        try:
            selected = _intent(intent)
            _require(type(cancelled) is threading.Event and not cancelled.is_set())
            result = self._engine.verify_root(
                selected,
                self._helper_image_id,
                self._platform,
                cancelled=cancelled,
            )
            _require(result is True and not cancelled.is_set())
            from .managed_container import VolumeBootstrapObservation
            binding, receipt = selected.binding, selected.receipt
            return VolumeBootstrapObservation(
                binding.resource_id,
                binding.resource.operationId,
                binding.journal_id,
                binding.ownership_nonce,
                receipt.revision,
                binding.resource.name,
                binding.resource.target,
                'root_verified',
            )
        except VolumeBootstrapError:
            raise
        except Exception:
            raise VolumeBootstrapError() from None
