"""Rebind one qBittorrent config effect inside the installation worker.

The caller supplies only an already verified stack and private credentials.
This adapter re-derives the packaged qBittorrent appdata resource, reads the
current worker-owned volume journal and delegates one effect through the
retained supervisor gate. It has no public API, host path or Docker operation.
"""

from dataclasses import fields
import re
import threading

from .docker_probe import DockerEndpoint
from .models import Catalog
from .qbittorrent_config_binding import (
    QbittorrentConfigBindingError,
    bind_qbittorrent_owned_config,
)
from .qbittorrent_config_effect import (
    QbittorrentConfigEffectError,
    QbittorrentConfigInstallReceipt,
    QbittorrentConfigInstaller,
)
from .resource_journal import ResourceJournalError
from .resource_models import WorkerPolicyBinding
from .stack_plan import MediaStackPlan, verify_media_stack_plan
from .volume_create_journal import VolumeCreateJournal
from .volume_plan import build_volume_plan


_PRIVATE = re.compile(r'[A-Za-z0-9_-]{32,128}\Z')
_IMAGE_ID = re.compile(r'sha256:[0-9a-f]{64}\Z')


class QbittorrentConfigRuntimeError(Exception):
    """Static worker boundary error; credentials and journal data stay hidden."""

    def __init__(self, code='qbittorrent_config_runtime_untrusted', *,
                 uncertain_effect=False):
        self.code = code if code in {
            'qbittorrent_config_runtime_untrusted',
            'qbittorrent_config_runtime_configuration_invalid',
            'qbittorrent_config_runtime_effect_failed',
            'qbittorrent_config_runtime_result_invalid',
        } else 'qbittorrent_config_runtime_untrusted'
        self.uncertain_effect = uncertain_effect is True
        super().__init__(self.code)


def _require(value, code='qbittorrent_config_runtime_untrusted'):
    if not value:
        raise QbittorrentConfigRuntimeError(code)


def _exact(value, cls):
    return type(value) is cls and set(vars(value)) == {
        item.name for item in fields(cls)
    }


class QbittorrentConfigRuntime:
    """Resolve the current appdata intent and execute one private config write."""

    def __init__(self, endpoint, journal, catalog, policy, helper_image_id,
                 platform, *, installer_factory=None, peer_uid=None):
        try:
            _require(type(endpoint) is DockerEndpoint
                     and type(journal) is VolumeCreateJournal
                     and type(catalog) is Catalog
                     and type(policy) is WorkerPolicyBinding
                     and type(helper_image_id) is str
                     and _IMAGE_ID.fullmatch(helper_image_id) is not None
                     and platform in {'linux/amd64', 'linux/arm64'}
                     and (installer_factory is None
                          or callable(installer_factory))
                     and (peer_uid is None or callable(peer_uid))
                     and not (installer_factory is not None
                              and peer_uid is not None),
                     'qbittorrent_config_runtime_configuration_invalid')
            self._endpoint = endpoint
            self._journal = journal
            self._catalog = Catalog.model_validate(
                catalog.model_dump(mode='python'))
            self._policy = WorkerPolicyBinding.model_validate(
                policy.model_dump(mode='python'))
            self._helper_image_id = helper_image_id
            self._platform = platform
            self._installer = (
                QbittorrentConfigInstaller(
                    endpoint, helper_image_id, platform, peer_uid=peer_uid)
                if installer_factory is None else installer_factory(endpoint)
            )
            _require(getattr(self._installer, '_endpoint', None) is endpoint
                     and callable(getattr(self._installer, 'install', None)),
                     'qbittorrent_config_runtime_configuration_invalid')
        except QbittorrentConfigRuntimeError:
            raise
        except Exception:
            raise QbittorrentConfigRuntimeError(
                'qbittorrent_config_runtime_configuration_invalid') from None

    def __repr__(self):
        return 'QbittorrentConfigRuntime(<private>)'

    def install(self, stack, credential, *, api_key, salt, cancelled,
                before_dispatch):
        try:
            _require(type(stack) is MediaStackPlan
                     and type(credential) is str
                     and _PRIVATE.fullmatch(credential) is not None
                     and type(api_key) is str
                     and _PRIVATE.fullmatch(api_key) is not None
                     and type(salt) is bytes and len(salt) == 16
                     and type(cancelled) is threading.Event
                     and not cancelled.is_set()
                     and callable(before_dispatch))
            trusted = verify_media_stack_plan(stack, self._catalog)
            plan = build_volume_plan(trusted, self._catalog, self._policy)
            targets = tuple(
                item for item in plan.resources
                if item.serviceId == 'qbittorrent'
                and item.kind == 'managed_appdata'
                and item.target == '/config'
            )
            _require(len(targets) == 1)
            target = targets[0]
            with self._journal.locked():
                receipt = self._journal.get(target.resourceId)
                intent = self._journal.bind(
                    target.resourceId, receipt.revision,
                    plan=plan, stack=trusted, catalog=self._catalog,
                    policy=self._policy,
                )
            binding = bind_qbittorrent_owned_config(
                self._journal, intent, credential,
                api_key=api_key, salt=salt,
            )
        except QbittorrentConfigRuntimeError:
            raise
        except (
            ValueError, TypeError, AttributeError, StopIteration,
            ResourceJournalError, QbittorrentConfigBindingError,
        ):
            raise QbittorrentConfigRuntimeError() from None
        try:
            result = self._installer.install(
                binding, self._journal, intent, credential,
                api_key=api_key, cancelled=cancelled,
                before_dispatch=before_dispatch,
            )
        except QbittorrentConfigEffectError:
            raise
        except Exception:
            raise QbittorrentConfigRuntimeError(
                'qbittorrent_config_runtime_effect_failed',
                uncertain_effect=True,
            ) from None
        if not _exact(result, QbittorrentConfigInstallReceipt):
            raise QbittorrentConfigRuntimeError(
                'qbittorrent_config_runtime_result_invalid',
                uncertain_effect=True,
            )
        try:
            return QbittorrentConfigInstallReceipt(**vars(result))
        except (TypeError, ValueError, QbittorrentConfigEffectError):
            raise QbittorrentConfigRuntimeError(
                'qbittorrent_config_runtime_result_invalid',
                uncertain_effect=True,
            ) from None
