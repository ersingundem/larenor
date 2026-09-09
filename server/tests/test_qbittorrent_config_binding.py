"""Owned qBittorrent config must stay tied to one verified appdata intent."""

from dataclasses import replace
import hashlib
import inspect
import socket
import subprocess

import pytest

from larenor_server.context import ContextResponse
from larenor_server.plugins.catalog import load_catalog
from larenor_server.plugins.qbittorrent_config_binding import (
    QbittorrentConfigBindingError,
    bind_qbittorrent_owned_config,
    verify_qbittorrent_config_binding,
)
from larenor_server.plugins.qbittorrent_owned_config import (
    verify_qbittorrent_owned_config,
)
from larenor_server.plugins.resource_models import WorkerPolicyBinding
from larenor_server.plugins.stack_plan import build_media_stack_plan
from larenor_server.plugins.volume_create_journal import VolumeCreateJournal
from larenor_server.plugins.volume_plan import build_volume_plan
from test_managed_resource_proof import volume_observation


PRIVATE_PASSWORD = 'p' * 40
PRIVATE_BEARER = 'k' * 40
SALT = bytes(range(16))


def source(tmp_path):
    catalog = load_catalog()
    stack = build_media_stack_plan(
        catalog,
        {},
        'linux/amd64',
        ContextResponse(schemaVersion=1, coreId='a' * 32, homeId='b' * 32),
        'c' * 32,
    )
    policy = WorkerPolicyBinding(
        schemaVersion=1, workerPolicyVersion=3,
        workerPolicyDigest='d' * 64,
    )
    plan = build_volume_plan(stack, catalog, policy)
    resource = next(
        item for item in plan.resources
        if item.serviceId == 'qbittorrent' and item.target == '/config'
    )
    journal = VolumeCreateJournal(tmp_path / 'volumes', initialize=True)
    context = dict(plan=plan, stack=stack, catalog=catalog, policy=policy)
    with journal.locked():
        receipt = journal.prepare(resource_id=resource.resourceId, **context)
        begun = journal.begin_create(
            resource.resourceId, receipt.revision, **context)
        observed = journal.reconcile(
            resource.resourceId, begun.receipt.revision,
            volume_observation, **context)
        intent = journal.bind(
            resource.resourceId, observed.revision, **context)
    return journal, intent


def test_binding_derives_ports_and_exact_config_from_journal_source(tmp_path):
    journal, intent = source(tmp_path)
    with journal.locked():
        before = journal.list()

    result = bind_qbittorrent_owned_config(
        journal, intent, PRIVATE_PASSWORD, api_key=PRIVATE_BEARER, salt=SALT)

    binding = intent.binding
    assert result.resource_id == binding.resource_id
    assert result.operation_id == binding.resource.operationId
    assert result.journal_id == binding.journal_id
    assert result.ownership_nonce == binding.ownership_nonce
    assert result.revision == intent.receipt.revision
    assert result.volume_name == binding.resource.name
    assert result.relative_path == 'qBittorrent/qBittorrent.conf'
    assert result.configuration_digest == hashlib.sha256(
        result.configuration).hexdigest()
    assert verify_qbittorrent_owned_config(
        result.configuration, PRIVATE_PASSWORD, api_key=PRIVATE_BEARER,
        web_port=8080, torrent_port=6881)
    assert verify_qbittorrent_config_binding(
        result, journal, intent, PRIVATE_PASSWORD, api_key=PRIVATE_BEARER)
    assert PRIVATE_PASSWORD not in repr(result)
    assert PRIVATE_BEARER not in repr(result)
    assert result.configuration not in repr(result).encode()
    with journal.locked():
        assert journal.list() == before


@pytest.mark.parametrize('damage', [
    'state', 'revision', 'resource', 'operation', 'journal', 'nonce',
    'specification', 'target', 'service', 'kind', 'read_only',
])
def test_forged_or_unready_intent_cannot_bind_private_config(tmp_path, damage):
    journal, intent = source(tmp_path)
    if damage in {'state', 'revision', 'resource', 'operation'}:
        changes = {
            'state': {'state': 'uncertain'},
            'revision': {'revision': intent.receipt.revision - 1},
            'resource': {'resource_id': '9' * 32},
            'operation': {'operation_id': '9' * 32},
        }[damage]
        intent = replace(intent, receipt=replace(intent.receipt, **changes))
    elif damage in {'journal', 'nonce'}:
        key = 'journal_id' if damage == 'journal' else 'ownership_nonce'
        intent = replace(intent, binding=replace(
            intent.binding, **{key: '9' * 32}))
    elif damage == 'specification':
        intent = replace(intent, specification_digest='9' * 64)
    else:
        changes = {
            'target': {'target': '/foreign'},
            'service': {'serviceId': 'jellyfin'},
            'kind': {'kind': 'managed_library'},
            'read_only': {'readOnly': True},
        }[damage]
        intent = replace(intent, binding=replace(
            intent.binding,
            resource=intent.binding.resource.model_copy(update=changes),
        ))
    with pytest.raises(
        QbittorrentConfigBindingError,
        match='^qbittorrent_config_binding_untrusted$',
    ):
        bind_qbittorrent_owned_config(
            journal, intent, PRIVATE_PASSWORD,
            api_key=PRIVATE_BEARER, salt=SALT)


def test_binding_has_no_host_or_network_effect(tmp_path, monkeypatch):
    journal, intent = source(tmp_path)
    def forbidden(*_args, **_kwargs):
        pytest.fail('pure binding attempted a host effect')
    for owner, name in [
        (socket, 'socket'), (subprocess, 'Popen'),
    ]:
        monkeypatch.setattr(owner, name, forbidden)
    result = bind_qbittorrent_owned_config(
        journal, intent, PRIVATE_PASSWORD,
        api_key=PRIVATE_BEARER, salt=SALT)
    assert result.relative_path == 'qBittorrent/qBittorrent.conf'


def test_verifier_rejects_config_or_source_drift_without_echoing_secrets(tmp_path):
    journal, intent = source(tmp_path)
    result = bind_qbittorrent_owned_config(
        journal, intent, PRIVATE_PASSWORD,
        api_key=PRIVATE_BEARER, salt=SALT)
    wrong_password = PRIVATE_PASSWORD[:-1] + 'x'
    wrong_bearer = PRIVATE_BEARER[:-1] + 'x'
    changed = replace(
        result, configuration=result.configuration + b'Hidden\\Option=true\n')
    assert not verify_qbittorrent_config_binding(
        changed, journal, intent, PRIVATE_PASSWORD, api_key=PRIVATE_BEARER)
    assert not verify_qbittorrent_config_binding(
        result, journal, intent, wrong_password, api_key=PRIVATE_BEARER)
    assert not verify_qbittorrent_config_binding(
        result, journal, intent, PRIVATE_PASSWORD, api_key=wrong_bearer)
    assert not verify_qbittorrent_config_binding(
        result, journal, replace(intent, specification_digest='9' * 64),
        PRIVATE_PASSWORD, api_key=PRIVATE_BEARER)


def test_closed_api_has_no_path_or_policy_override():
    parameters = inspect.signature(bind_qbittorrent_owned_config).parameters
    assert set(parameters) == {
        'journal', 'intent', 'credential', 'api_key', 'salt'}
    assert not {'path', 'volume', 'web_port', 'torrent_port', 'stack', 'catalog',
                'policy', 'writer', 'filesystem'} & set(parameters)
