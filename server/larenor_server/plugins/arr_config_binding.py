"""Bind one owned Sonarr/Radarr config to journal-proved appdata.

This pure module has no filesystem, Docker, IPC or network authority.  A later
worker effect must rebind the same resource intent before and after invoking the
closed volume helper.
"""

from dataclasses import dataclass, field, fields
import hashlib
import hmac
from typing import Literal

from .arr_owned_config import (
    ArrOwnedConfigError,
    render_arr_owned_config,
    verify_arr_owned_config,
)
from .resource_journal import ResourceJournalError, _digest
from .stack_plan import verify_media_stack_plan
from .volume_create_journal import (
    VolumeCreateIntent,
    VolumeCreateJournal,
    VolumeCreateReceipt,
)
from .volume_resources import VolumeResourceError, _binding


_SERVICE = {
    'sonarr': (8989, 'larenor-sonarr'),
    'radarr': (7878, 'larenor-radarr'),
}


class ArrConfigBindingError(Exception):
    """Static failure; supplied API keys and config never enter errors."""

    def __init__(self):
        super().__init__('arr_config_binding_untrusted')


@dataclass(frozen=True, repr=False)
class ArrConfigBinding:
    service_id: Literal['sonarr', 'radarr']
    resource_id: str
    operation_id: str
    journal_id: str
    ownership_nonce: str
    revision: int
    volume_name: str
    relative_path: Literal['config.xml']
    configuration_digest: str
    configuration: bytes = field(repr=False)

    def __repr__(self):
        return 'ArrConfigBinding(<private>)'


def _exact(value, cls):
    return type(value) is cls and set(vars(value)) == {
        item.name for item in fields(cls)
    }


def _source(journal, intent):
    if type(journal) is not VolumeCreateJournal or not _exact(
            intent, VolumeCreateIntent):
        raise ValueError()
    selected = _binding(intent.binding)
    receipt = intent.receipt
    if not _exact(receipt, VolumeCreateReceipt):
        raise ValueError()
    plan, stack, catalog, policy = selected.source
    resource = selected.resource
    service_id = resource.serviceId
    if (
        service_id not in _SERVICE
        or resource.kind != 'managed_appdata'
        or resource.target != '/config'
        or resource.readOnly is not False
        or resource.noCopy is not True
        or resource.containerUser != '1000:1000'
        or receipt.resource_id != selected.resource_id
        or receipt.operation_id != resource.operationId
        or receipt.preparation_id != plan.preparationId
        or receipt.plan_hash != plan.planHash
        or receipt.worker_policy_digest != policy.workerPolicyDigest
        or receipt.state != 'observed_requires_bootstrap'
        or type(receipt.revision) is not int
        or not 3 <= receipt.revision <= 2**63 - 2
        or intent.specification_digest
        != _digest(resource.model_dump(mode='json'))
    ):
        raise ValueError()
    with journal.locked():
        current = journal.bind(
            selected.resource_id, receipt.revision,
            plan=plan, stack=stack, catalog=catalog, policy=policy,
        )
    if current != intent:
        raise ValueError()
    trusted = verify_media_stack_plan(stack, catalog)
    components = tuple(
        item for item in trusted.components if item.serviceId == service_id)
    if len(components) != 1:
        raise ValueError()
    component = components[0]
    settings = {item.name: item.value for item in component.plan.settings}
    mounts = tuple(
        item for item in component.plan.mounts
        if item.kind == 'managed_appdata' and item.target == '/config')
    expected_port, expected_instance = _SERVICE[service_id]
    if (
        len(mounts) != 1
        or component.installationId != resource.installationId
        or component.plan.planHash != resource.childPlanHash
        or component.plan.security.user != '1000:1000'
        or mounts[0].rootId != resource.requestedRootId
        or mounts[0].relativePath != resource.requestedRelativePath
        or mounts[0].readOnly is not False
        or set(settings) != {
            'dataRootId', 'instanceName', 'libraryRootId', 'webPort'}
        or settings['webPort'] != expected_port
        or settings['instanceName'] != expected_instance
    ):
        raise ValueError()
    return selected, receipt, service_id


def bind_arr_owned_config(journal, intent, *, api_key):
    """Render config only after exact current-journal rederivation."""
    try:
        selected, receipt, service_id = _source(journal, intent)
        owned = render_arr_owned_config(service_id, api_key)
        digest = hashlib.sha256(owned.configuration).hexdigest()
        return ArrConfigBinding(
            service_id,
            selected.resource_id,
            selected.resource.operationId,
            selected.journal_id,
            selected.ownership_nonce,
            receipt.revision,
            selected.resource.name,
            owned.relative_path,
            digest,
            owned.configuration,
        )
    except (
        ValueError, TypeError, AttributeError, KeyError, StopIteration,
        RecursionError, ResourceJournalError, VolumeResourceError,
        ArrOwnedConfigError,
    ):
        raise ArrConfigBindingError() from None


def verify_arr_config_binding(value, journal, intent, *, api_key):
    """Rebind source metadata and reproduce the exact owned configuration."""
    try:
        if not _exact(value, ArrConfigBinding):
            return False
        selected, receipt, service_id = _source(journal, intent)
        if (
            value.service_id != service_id
            or value.resource_id != selected.resource_id
            or value.operation_id != selected.resource.operationId
            or value.journal_id != selected.journal_id
            or value.ownership_nonce != selected.ownership_nonce
            or value.revision != receipt.revision
            or value.volume_name != selected.resource.name
            or value.relative_path != 'config.xml'
            or type(value.configuration) is not bytes
            or not 1 <= len(value.configuration) <= 4096
            or type(value.configuration_digest) is not str
            or not hmac.compare_digest(
                value.configuration_digest,
                hashlib.sha256(value.configuration).hexdigest())
        ):
            return False
        return verify_arr_owned_config(
            value.configuration, service_id, api_key=api_key)
    except (
        ValueError, TypeError, AttributeError, KeyError, StopIteration,
        RecursionError, ResourceJournalError, VolumeResourceError,
    ):
        return False
