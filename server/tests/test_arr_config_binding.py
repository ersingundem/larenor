"""Owned Arr config must remain tied to one verified appdata intent."""

from dataclasses import replace
import hashlib
import inspect
import socket
import subprocess

import pytest

from larenor_server.context import ContextResponse
from larenor_server.plugins.arr_config_binding import (
    ArrConfigBindingError,
    bind_arr_owned_config,
    verify_arr_config_binding,
)
from larenor_server.plugins.arr_owned_config import verify_arr_owned_config
from larenor_server.plugins.catalog import load_catalog
from larenor_server.plugins.resource_models import WorkerPolicyBinding
from larenor_server.plugins.stack_plan import build_media_stack_plan
from larenor_server.plugins.volume_create_journal import VolumeCreateJournal
from larenor_server.plugins.volume_plan import build_volume_plan
from test_managed_resource_proof import volume_observation


API_KEY = '01234567' * 4


def source(tmp_path, service_id):
    catalog = load_catalog()
    stack = build_media_stack_plan(
        catalog, {}, 'linux/amd64',
        ContextResponse(
            schemaVersion=1, coreId='a' * 32, homeId='b' * 32),
        'c' * 32,
    )
    policy = WorkerPolicyBinding(
        schemaVersion=1, workerPolicyVersion=3,
        workerPolicyDigest='d' * 64,
    )
    plan = build_volume_plan(stack, catalog, policy)
    resource = next(
        item for item in plan.resources
        if item.serviceId == service_id and item.target == '/config'
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


@pytest.mark.parametrize('service_id', ['sonarr', 'radarr'])
def test_binding_derives_exact_config_from_the_journal_source(
        tmp_path, service_id):
    journal, intent = source(tmp_path, service_id)
    with journal.locked():
        before = journal.list()

    result = bind_arr_owned_config(journal, intent, api_key=API_KEY)

    binding = intent.binding
    assert result.service_id == service_id
    assert result.resource_id == binding.resource_id
    assert result.operation_id == binding.resource.operationId
    assert result.journal_id == binding.journal_id
    assert result.ownership_nonce == binding.ownership_nonce
    assert result.revision == intent.receipt.revision
    assert result.volume_name == binding.resource.name
    assert result.relative_path == 'config.xml'
    assert result.configuration_digest == hashlib.sha256(
        result.configuration).hexdigest()
    assert verify_arr_owned_config(
        result.configuration, service_id, api_key=API_KEY)
    assert verify_arr_config_binding(
        result, journal, intent, api_key=API_KEY)
    assert API_KEY not in repr(result)
    assert result.configuration not in repr(result).encode()
    with journal.locked():
        assert journal.list() == before


@pytest.mark.parametrize('service_id', ['sonarr', 'radarr'])
@pytest.mark.parametrize('damage', [
    'state', 'revision', 'resource', 'operation', 'journal', 'nonce',
    'specification', 'target', 'service', 'kind', 'read_only',
])
def test_forged_or_unready_intent_cannot_bind_private_config(
        tmp_path, service_id, damage):
    journal, intent = source(tmp_path, service_id)
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
        ArrConfigBindingError, match='^arr_config_binding_untrusted$',
    ):
        bind_arr_owned_config(journal, intent, api_key=API_KEY)


@pytest.mark.parametrize('service_id', ['sonarr', 'radarr'])
def test_binding_has_no_host_or_network_effect(
        tmp_path, monkeypatch, service_id):
    journal, intent = source(tmp_path, service_id)
    def forbidden(*_args, **_kwargs):
        pytest.fail('pure binding attempted a host effect')
    for owner, name in [(socket, 'socket'), (subprocess, 'Popen')]:
        monkeypatch.setattr(owner, name, forbidden)
    result = bind_arr_owned_config(journal, intent, api_key=API_KEY)
    assert result.relative_path == 'config.xml'


@pytest.mark.parametrize('service_id', ['sonarr', 'radarr'])
def test_verifier_rejects_config_source_and_api_key_drift(
        tmp_path, service_id):
    journal, intent = source(tmp_path, service_id)
    result = bind_arr_owned_config(journal, intent, api_key=API_KEY)
    changed = replace(
        result, configuration=result.configuration + b'<Hidden/>\n')
    assert not verify_arr_config_binding(
        changed, journal, intent, api_key=API_KEY)
    assert not verify_arr_config_binding(
        result, journal, intent, api_key='f' * 32)
    assert not verify_arr_config_binding(
        result, journal, replace(intent, specification_digest='9' * 64),
        api_key=API_KEY)
    other = 'radarr' if service_id == 'sonarr' else 'sonarr'
    assert not verify_arr_owned_config(
        result.configuration, other, api_key=API_KEY)


@pytest.mark.parametrize('field,value', [
    ('service_id', 'radarr'),
    ('resource_id', '9' * 32),
    ('operation_id', '9' * 32),
    ('journal_id', '9' * 32),
    ('ownership_nonce', '9' * 32),
    ('revision', 99),
    ('volume_name', 'foreign'),
    ('relative_path', '../config.xml'),
    ('configuration_digest', '9' * 64),
    ('configuration', b'<Config/>'),
])
def test_every_saved_binding_field_is_reverified(tmp_path, field, value):
    journal, intent = source(tmp_path, 'sonarr')
    result = bind_arr_owned_config(journal, intent, api_key=API_KEY)
    changed = replace(result, **{field: value})
    assert not verify_arr_config_binding(
        changed, journal, intent, api_key=API_KEY)


@pytest.mark.parametrize('api_key', ['', 'f' * 31, 'G' * 32, True, None])
def test_binding_rejects_invalid_api_keys_without_echoing_them(
        tmp_path, api_key):
    journal, intent = source(tmp_path, 'sonarr')
    with pytest.raises(
        ArrConfigBindingError, match='^arr_config_binding_untrusted$',
    ) as caught:
        bind_arr_owned_config(journal, intent, api_key=api_key)
    assert repr(api_key) not in str(caught.value)


def test_closed_api_has_no_service_path_port_or_policy_override():
    parameters = inspect.signature(bind_arr_owned_config).parameters
    assert set(parameters) == {'journal', 'intent', 'api_key'}
    assert not {
        'service_id', 'path', 'volume', 'web_port', 'stack', 'catalog',
        'policy', 'writer', 'filesystem',
    } & set(parameters)
