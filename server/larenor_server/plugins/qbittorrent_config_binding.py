"""Bind one owned qBittorrent config to a journal-proved appdata volume.

This module only creates a private in-memory contract. It has no filesystem,
Docker, IPC or network authority and cannot write the configuration. A later
worker effect must rebind the same volume intent before and after its write.
"""

from dataclasses import dataclass, field, fields
import hashlib

from .qbittorrent_owned_config import (
    QbittorrentOwnedConfigError,
    render_qbittorrent_owned_config,
    verify_qbittorrent_owned_config,
)
from .resource_journal import ResourceJournalError, _digest
from .stack_plan import verify_media_stack_plan
from .volume_create_journal import (
    VolumeCreateIntent,
    VolumeCreateJournal,
    VolumeCreateReceipt,
)
from .volume_resources import VolumeResourceError, _binding


class QbittorrentConfigBindingError(Exception):
    """Static failure; supplied credentials and config never enter errors."""

    def __init__(self):
        super().__init__('qbittorrent_config_binding_untrusted')


@dataclass(frozen=True, repr=False)
class QbittorrentConfigBinding:
    resource_id: str
    operation_id: str
    journal_id: str
    ownership_nonce: str
    revision: int
    volume_name: str
    relative_path: str
    configuration_digest: str
    configuration: bytes = field(repr=False)

    def __repr__(self):
        return 'QbittorrentConfigBinding(<private>)'


def _exact(value, cls):
    return type(value) is cls and set(vars(value)) == {
        item.name for item in fields(cls)
    }


def _source(journal, intent):
    if type(journal) is not VolumeCreateJournal or not _exact(
        intent, VolumeCreateIntent
    ):
        raise ValueError()
    selected = _binding(intent.binding)
    receipt = intent.receipt
    if not _exact(receipt, VolumeCreateReceipt):
        raise ValueError()
    plan, stack, catalog, policy = selected.source
    resource = selected.resource
    if (
        resource.kind != 'managed_appdata'
        or resource.serviceId != 'qbittorrent'
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
    component = next(
        item for item in trusted.components if item.serviceId == 'qbittorrent'
    )
    settings = {item.name: item.value for item in component.plan.settings}
    mount = next(
        item for item in component.plan.mounts
        if item.kind == 'managed_appdata' and item.target == '/config'
    )
    if (
        component.installationId != resource.installationId
        or component.plan.planHash != resource.childPlanHash
        or mount.rootId != resource.requestedRootId
        or mount.relativePath != resource.requestedRelativePath
        or mount.readOnly is not False
        or set(settings) != {
            'dataRootId', 'instanceName', 'libraryRootId',
            'torrentPort', 'webPort',
        }
    ):
        raise ValueError()
    web_port, torrent_port = settings['webPort'], settings['torrentPort']
    if (
        type(web_port) is not int
        or type(torrent_port) is not int
        or not 1024 <= web_port <= 65535
        or not 1024 <= torrent_port <= 65535
        or web_port == torrent_port
    ):
        raise ValueError()
    return selected, receipt, web_port, torrent_port


def bind_qbittorrent_owned_config(journal, intent, credential, *, api_key, salt):
    """Render config only after exact journal/source rederivation."""
    try:
        selected, receipt, web_port, torrent_port = _source(journal, intent)
        owned = render_qbittorrent_owned_config(
            credential, api_key=api_key, salt=salt,
            web_port=web_port, torrent_port=torrent_port,
        )
        digest = hashlib.sha256(owned.configuration).hexdigest()
        return QbittorrentConfigBinding(
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
        QbittorrentOwnedConfigError,
    ):
        raise QbittorrentConfigBindingError() from None


def verify_qbittorrent_config_binding(
    value, journal, intent, credential, *, api_key,
):
    """Rebind metadata and rederive config from its embedded PBKDF2 salt."""
    try:
        if not _exact(value, QbittorrentConfigBinding):
            return False
        selected, receipt, web_port, torrent_port = _source(journal, intent)
        if (
            value.resource_id != selected.resource_id
            or value.operation_id != selected.resource.operationId
            or value.journal_id != selected.journal_id
            or value.ownership_nonce != selected.ownership_nonce
            or value.revision != receipt.revision
            or value.volume_name != selected.resource.name
            or value.relative_path != 'qBittorrent/qBittorrent.conf'
            or type(value.configuration) is not bytes
            or not 1 <= len(value.configuration) <= 4096
            or type(value.configuration_digest) is not str
            or value.configuration_digest
            != hashlib.sha256(value.configuration).hexdigest()
        ):
            return False
        return verify_qbittorrent_owned_config(
            value.configuration, credential, api_key=api_key,
            web_port=web_port, torrent_port=torrent_port,
        )
    except (
        ValueError, TypeError, AttributeError, KeyError, StopIteration,
        RecursionError, ResourceJournalError, VolumeResourceError,
    ):
        return False
