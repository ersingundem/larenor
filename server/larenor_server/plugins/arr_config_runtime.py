"""Rebind one Sonarr/Radarr config effect inside the installation worker.

The caller supplies only a verified stack, one closed service identity and its
private API key. This adapter re-derives the packaged appdata resource, reads
the current worker-owned volume journal and delegates one effect through the
retained supervisor gate. It has no public API, host path or Docker operation.
"""

from dataclasses import fields
import re
import threading

from .arr_config_binding import (
    ArrConfigBindingError,
    bind_arr_owned_config,
)
from .arr_config_effect import (
    ArrConfigEffectError,
    ArrConfigInstallReceipt,
    ArrConfigInstaller,
)
from .arr_owned_config import is_arr_api_key
from .docker_probe import DockerEndpoint
from .models import Catalog
from .resource_journal import ResourceJournalError
from .resource_models import WorkerPolicyBinding
from .stack_plan import MediaStackPlan, verify_media_stack_plan
from .volume_create_journal import VolumeCreateJournal
from .volume_plan import build_volume_plan


_IMAGE_ID = re.compile(r'sha256:[0-9a-f]{64}\Z')
_SERVICES = frozenset({'sonarr', 'radarr'})


class ArrConfigRuntimeError(Exception):
    """Static worker error; API keys and journal data stay hidden."""

    def __init__(self, code='arr_config_runtime_untrusted', *,
                 uncertain_effect=False):
        self.code = code if code in {
            'arr_config_runtime_untrusted',
            'arr_config_runtime_configuration_invalid',
            'arr_config_runtime_effect_failed',
            'arr_config_runtime_result_invalid',
        } else 'arr_config_runtime_untrusted'
        self.uncertain_effect = uncertain_effect is True
        super().__init__(self.code)

    def __repr__(self):
        return (f'ArrConfigRuntimeError({self.code!r}, '
                f'uncertain_effect={self.uncertain_effect!r})')


def _require(value, code='arr_config_runtime_untrusted'):
    if not value:
        raise ArrConfigRuntimeError(code)


def _exact(value, cls):
    return type(value) is cls and set(vars(value)) == {
        item.name for item in fields(cls)
    }


class ArrConfigRuntime:
    """Resolve current appdata intent and execute one private config write."""

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
                     'arr_config_runtime_configuration_invalid')
            self._endpoint = endpoint
            self._journal = journal
            self._catalog = Catalog.model_validate(
                catalog.model_dump(mode='python'))
            self._policy = WorkerPolicyBinding.model_validate(
                policy.model_dump(mode='python'))
            self._helper_image_id = helper_image_id
            self._platform = platform
            self._installer = (
                ArrConfigInstaller(
                    endpoint, helper_image_id, platform, peer_uid=peer_uid)
                if installer_factory is None else installer_factory(endpoint)
            )
            _require(getattr(self._installer, '_endpoint', None) is endpoint
                     and callable(getattr(self._installer, 'install', None)),
                     'arr_config_runtime_configuration_invalid')
        except ArrConfigRuntimeError:
            raise
        except Exception:
            raise ArrConfigRuntimeError(
                'arr_config_runtime_configuration_invalid') from None

    def __repr__(self):
        return 'ArrConfigRuntime(<private>)'

    def install(self, stack, service_id, *, api_key, cancelled,
                before_dispatch):
        try:
            _require(type(stack) is MediaStackPlan
                     and type(service_id) is str
                     and service_id in _SERVICES
                     and is_arr_api_key(api_key)
                     and type(cancelled) is threading.Event
                     and not cancelled.is_set()
                     and callable(before_dispatch))
            trusted = verify_media_stack_plan(stack, self._catalog)
            plan = build_volume_plan(trusted, self._catalog, self._policy)
            targets = tuple(
                item for item in plan.resources
                if item.serviceId == service_id
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
            binding = bind_arr_owned_config(
                self._journal, intent, api_key=api_key)
            _require(binding.service_id == service_id)
        except ArrConfigRuntimeError:
            raise
        except (
            ValueError, TypeError, AttributeError, StopIteration,
            ResourceJournalError, ArrConfigBindingError,
        ):
            raise ArrConfigRuntimeError() from None
        try:
            result = self._installer.install(
                binding, self._journal, intent, api_key=api_key,
                cancelled=cancelled, before_dispatch=before_dispatch,
            )
        except ArrConfigEffectError:
            raise
        except Exception:
            raise ArrConfigRuntimeError(
                'arr_config_runtime_effect_failed',
                uncertain_effect=True,
            ) from None
        if not _exact(result, ArrConfigInstallReceipt):
            raise ArrConfigRuntimeError(
                'arr_config_runtime_result_invalid',
                uncertain_effect=True,
            )
        try:
            copied = ArrConfigInstallReceipt(**vars(result))
            _require(copied.service_id == service_id,
                     'arr_config_runtime_result_invalid')
            return copied
        except (TypeError, ValueError, ArrConfigEffectError,
                ArrConfigRuntimeError):
            raise ArrConfigRuntimeError(
                'arr_config_runtime_result_invalid',
                uncertain_effect=True,
            ) from None
