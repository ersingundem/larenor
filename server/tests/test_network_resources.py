"""Pure network contracts with a real private intent; no Docker/socket effects."""

from dataclasses import replace
import json
from urllib.parse import parse_qs, urlsplit

import pytest

from larenor_server.context import ContextResponse
from larenor_server.plugins.catalog import load_catalog
from larenor_server.plugins.resource_journal import ResourceJournal
from larenor_server.plugins.resource_models import WorkerPolicyBinding
from larenor_server.plugins.resource_plan import build_resource_plan
from larenor_server.plugins.stack_plan import build_media_stack_plan
from larenor_server.plugins.network_resources import (
    NetworkResourceError, build_network_create_body, network_binding,
    network_list_target, validate_network_list, validate_network_inspect,
)
from larenor_server.services.transport import ProbeResponse


@pytest.fixture
def prepared(tmp_path):
    catalog = load_catalog()
    policy = WorkerPolicyBinding(schemaVersion=1, workerPolicyVersion=3, workerPolicyDigest='d' * 64)
    stack = build_media_stack_plan(catalog, {}, 'linux/amd64',
        ContextResponse(schemaVersion=1, coreId='a' * 32, homeId='b' * 32), 'c' * 32)
    plan = build_resource_plan(stack, catalog, policy)
    source = dict(plan=plan, stack=stack, catalog=catalog, policy=policy)
    resource_id = plan.resources[-1].resourceId
    binding = network_binding(**source, resource_id=resource_id)
    with ResourceJournal(tmp_path / 'journal', initialize=True) as journal, journal.locked():
        receipt = journal.prepare(**source, resource_id=resource_id)
        intent = journal.begin(resource_id, receipt.revision, **source)
        yield source, binding, intent


def response(value, status=200):
    return ProbeResponse(status, (('content-type', 'application/json'),), json.dumps(value).encode())


def network(prepared):
    _, binding, intent = prepared
    body = json.loads(build_network_create_body(binding, intent))
    return {**body, 'Id': '1' * 64, 'Created': '2026-09-05T09:00:00.000000001Z',
            'Containers': {}, 'Options': None, 'ConfigFrom': {'Network': ''},
            'IPAM': {'Driver': 'default', 'Options': None,
                     'Config': [{'Subnet': '172.28.0.0/16', 'Gateway': '172.28.0.1'}]}}


def listed(prepared, value, **kwargs):
    _, binding, intent = prepared
    return validate_network_list(response(value), binding, intent,
                                 request_target=network_list_target(binding), **kwargs)


def inspected(prepared, value, **kwargs):
    _, binding, intent = prepared
    return validate_network_inspect(response(value), binding, intent, expected_id='1' * 64, **kwargs)


def test_create_is_fixed_canonical_and_binds_the_complete_private_intent(prepared):
    source, binding, intent = prepared
    raw = build_network_create_body(binding, intent)
    body = json.loads(raw)
    assert raw == json.dumps(body, sort_keys=True, separators=(',', ':')).encode()
    assert set(body) == {'Name', 'Driver', 'Scope', 'Internal', 'Attachable', 'Ingress',
                         'ConfigOnly', 'EnableIPv6', 'Labels'}
    assert body['Name'] == source['plan'].resources[-1].name
    assert (body['Driver'], body['Scope'], body['Internal']) == ('bridge', 'local', True)
    assert all(body[key] is False for key in ('Attachable', 'Ingress', 'ConfigOnly', 'EnableIPv6'))
    assert body['Labels'] == {
        'org.larenor.resource-schema': '1', 'org.larenor.core': source['plan'].coreId,
        'org.larenor.home': source['plan'].homeId, 'org.larenor.preparation': source['plan'].preparationId,
        'org.larenor.resource': intent.resource.resourceId, 'org.larenor.operation': intent.resource.operationId,
        'org.larenor.worker-journal': intent.journal_id, 'org.larenor.ownership-nonce': intent.ownership_nonce,
        'org.larenor.specification': intent.specification_digest, 'org.larenor.plan': source['plan'].planHash,
        'org.larenor.stack-plan': source['stack'].planHash, 'org.larenor.catalog': source['catalog'].digest,
        'org.larenor.worker-policy-version': '3', 'org.larenor.worker-policy': source['policy'].workerPolicyDigest,
    }
    assert intent.ownership_nonce not in repr(binding)
    target = urlsplit(network_list_target(binding))
    assert target.path == '/v1.47/networks'
    assert json.loads(parse_qs(target.query)['filters'][0]) == {'name': [body['Name']]}


@pytest.mark.parametrize('field', ['core', 'policy', 'resource', 'hidden'])
def test_full_source_is_rederived_before_any_body_or_observation(prepared, field):
    source, binding, intent = prepared
    if field == 'core':
        object.__setattr__(source['stack'], 'coreId', 'e' * 32)
    elif field == 'policy':
        object.__setattr__(source['policy'], 'workerPolicyVersion', True)
    elif field == 'resource':
        object.__setattr__(binding.resource, 'internal', False)
    else:
        object.__setattr__(binding, 'secret_extra', 'private')
    with pytest.raises(NetworkResourceError, match='^invalid_network_binding$'):
        build_network_create_body(binding, intent)


@pytest.mark.parametrize('damage', [
    {'journal_id': 'bad'}, {'ownership_nonce': True}, {'specification_digest': 'e' * 64},
    {'receipt': 'secret'},
])
def test_forged_intent_is_static_and_rejected(prepared, damage):
    _, binding, intent = prepared
    with pytest.raises(NetworkResourceError, match='^invalid_network_binding$'):
        build_network_create_body(binding, replace(intent, **damage))


@pytest.mark.parametrize('state,code,revision', [
    ('prepared', 'resource_prepared', 1), ('uncertain', 'effect_uncertain', 3),
    ('ready', 'resource_matched', 3), ('mutating', 'effect_started', True),
])
def test_create_body_never_reauthorizes_an_old_or_uncertain_intent(prepared, state, code, revision):
    _, binding, intent = prepared
    intent = replace(intent, receipt=replace(intent.receipt, state=state, code=code, revision=revision))
    with pytest.raises(NetworkResourceError, match='^invalid_network_binding$'):
        build_network_create_body(binding, intent)


def test_list_is_only_a_candidate_and_inspect_proves_no_attached_endpoints(prepared):
    value = network(prepared)
    summary = dict(value)
    summary.pop('Containers')
    result = listed(prepared, [summary])
    assert (result.state, result.network_id) == ('candidate', value['Id'])
    assert inspected(prepared, value).network_id == value['Id']
    with pytest.raises(NetworkResourceError, match='^network_conflict$'):
        inspected(prepared, summary)
    value['Containers'] = {'ep-' + '2' * 64: {'Name': 'foreign endpoint'}}
    with pytest.raises(NetworkResourceError, match='^network_conflict$'):
        inspected(prepared, value)


def test_missing_requires_complete_bounded_200_list_and_exact_name_query(prepared):
    _, binding, intent = prepared
    assert listed(prepared, []).state == 'missing'
    other = network(prepared)
    other['Name'] += '-other'
    assert listed(prepared, [other]).state == 'missing'
    for reply, target in [(response([], 404), network_list_target(binding)),
                          (response([], 206), network_list_target(binding)),
                          (response([]), '/v1.47/networks?filters=label-only'),
                          (response({'items': [], 'next': 'private'}), network_list_target(binding))]:
        with pytest.raises(NetworkResourceError, match='^network_protocol$'):
            validate_network_list(reply, binding, intent, request_target=target)
    with pytest.raises(NetworkResourceError, match='^network_protocol$'):
        validate_network_inspect(response({}, 404), binding, intent, expected_id='1' * 64)


def test_same_name_foreign_or_multiple_networks_never_become_missing_or_owned(prepared):
    value = network(prepared)
    foreign = {**value, 'Id': '2' * 64, 'Labels': {}}
    with pytest.raises(NetworkResourceError, match='^network_conflict$'):
        listed(prepared, [foreign])
    for values in ([value, foreign], [value, {**value, 'Id': '2' * 64}], [value, value]):
        with pytest.raises(NetworkResourceError, match='^network_multiple$'):
            listed(prepared, values)


@pytest.mark.parametrize('field,value', [
    ('Name', 'foreign'), ('Id', '1' * 63), ('Id', 'A' * 64), ('Id', '2' * 64),
    ('Driver', 'overlay'), ('Scope', 'swarm'), ('Internal', 1), ('Internal', False),
    ('Attachable', True), ('Ingress', True), ('ConfigOnly', True), ('EnableIPv6', True),
    ('EnableIPv4', False), ('EnableIPv4', 1), ('Options', {'driver-secret': 'private'}),
    ('ConfigFrom', {'Network': 'foreign'}), ('Peers', [{'IP': 'private'}]),
    ('Services', {'foreign': {}}), ('Labels', {}), ('UnknownFeature', True),
])
def test_inspect_rejects_wrong_identity_ownership_and_features(prepared, field, value):
    item = network(prepared)
    item[field] = value
    with pytest.raises(NetworkResourceError, match='^network_conflict$'):
        inspected(prepared, item)


@pytest.mark.parametrize('field', ['journal', 'nonce', 'core', 'home', 'plan', 'resource', 'specification'])
def test_each_owner_label_is_checked_not_just_the_name(prepared, field):
    item = network(prepared)
    key = {'journal': 'worker-journal', 'nonce': 'ownership-nonce'}.get(field, field)
    item['Labels']['org.larenor.' + key] = 'e' * 32
    with pytest.raises(NetworkResourceError, match='^network_conflict$'):
        inspected(prepared, item)


@pytest.mark.parametrize('options,config_from,ipv4', [(None, {'Network': ''}, None), ({}, {}, True)])
def test_real_empty_default_options_and_allocated_ipam_are_accepted(prepared, options, config_from, ipv4):
    item = network(prepared)
    item['Options'] = item['IPAM']['Options'] = options
    item['ConfigFrom'] = config_from
    item['IPAM']['Config'][0].update(IPRange='', AuxiliaryAddresses=None)
    if ipv4 is not None:
        item['EnableIPv4'] = ipv4
    assert inspected(prepared, item).network_id == '1' * 64


@pytest.mark.parametrize('ipam', [
    None, {}, {'Driver': 'foreign', 'Config': []}, {'Driver': 'default', 'Config': []},
    {'Driver': 'default', 'Config': None},
    {'Driver': 'default', 'Options': {'secret': 'private'}, 'Config': []},
    {'Driver': 'default', 'Config': [{'Subnet': 'fd00::/64'}]},
    {'Driver': 'default', 'Config': [{'Subnet': '172.28.0.1/16'}]},
    {'Driver': 'default', 'Config': [{'Subnet': '172.28.0.0/16', 'IPRange': '172.28.1.0/24'}]},
    {'Driver': 'default', 'Config': [{'Subnet': '172.28.0.0/16', 'AuxiliaryAddresses': {'host': '172.28.0.8'}}]},
    {'Driver': 'default', 'Config': [{'Subnet': '172.28.0.0/16', 'Gateway': '172.29.0.1'}]},
])
def test_unproven_or_custom_ipam_never_certifies_a_private_default_bridge(prepared, ipam):
    item = network(prepared)
    if type(ipam) is dict and 'Driver' in ipam and 'Options' not in ipam:
        ipam = {**ipam, 'Options': None}
    item['IPAM'] = ipam
    with pytest.raises(NetworkResourceError, match='^network_conflict$'):
        inspected(prepared, item)


@pytest.mark.parametrize('raw', [b'null', b'[', b'[{"Name":"one","Name":"two"}]',
    b'[{"Name":NaN}]', b'[' * 40 + b']' * 40, b'\xff'])
def test_malformed_list_never_becomes_a_missing_receipt(prepared, raw):
    _, binding, intent = prepared
    reply = ProbeResponse(200, (('content-type', 'application/json'),), raw)
    with pytest.raises(NetworkResourceError, match='^network_protocol$'):
        validate_network_list(reply, binding, intent, request_target=network_list_target(binding))


def test_list_byte_and_entry_limits_are_independent_and_no_silent_truncation(prepared):
    _, binding, intent = prepared
    for raw in (b' ' * 131073, json.dumps([{'Name': 'other', 'Id': f'{n:064x}'} for n in range(129)]).encode()):
        with pytest.raises(NetworkResourceError, match='^network_response_limit$'):
            validate_network_list(ProbeResponse(200, (('content-type', 'application/json'),), raw), binding, intent,
                                  request_target=network_list_target(binding))


def test_diagnostics_and_results_never_reflect_network_values(prepared):
    assert str(NetworkResourceError('private')) == 'network_protocol'
    result = listed(prepared, [network(prepared)])
    assert '1' * 64 not in repr(result)
    assert 'larenor-control' not in repr(result)


@pytest.mark.parametrize('field', ['Options', 'IPAM.Options'])
def test_omitted_engine_option_observation_is_not_proof_of_default_settings(prepared, field):
    item = network(prepared)
    if field == 'Options':
        item.pop(field)
    else:
        item['IPAM'].pop('Options')
    with pytest.raises(NetworkResourceError, match='^network_conflict$'):
        inspected(prepared, item)


@pytest.mark.parametrize('configs', [None, []])
def test_incomplete_list_ipam_is_only_a_candidate_never_an_inspect_proof(prepared, configs):
    item = network(prepared)
    item['IPAM']['Config'] = configs
    assert listed(prepared, [item]).state == 'candidate'
    with pytest.raises(NetworkResourceError, match='^network_conflict$'):
        inspected(prepared, item)


def test_uncertain_intent_can_only_be_inspected_without_reissuing_create_body(prepared):
    _, binding, intent = prepared
    item = network(prepared)
    resumed = replace(intent, receipt=replace(intent.receipt, state='uncertain',
                                             code='effect_uncertain', revision=3))
    assert validate_network_inspect(response(item), binding, resumed, expected_id='1' * 64).network_id == '1' * 64
    with pytest.raises(NetworkResourceError, match='^invalid_network_binding$'):
        build_network_create_body(binding, resumed)


@pytest.mark.parametrize('headers', [(), (('content-type', 'text/plain'),),
    (('content-type', 'application/json'), ('content-type', 'application/json')),
    (('content-type', 'application/json'), ('link', '<private>; rel=next')),
    (('content-type', 'application/json'), ('content-range', 'items 0-2/10')),
])
def test_non_json_or_partial_list_envelopes_cannot_prove_missing(prepared, headers):
    _, binding, intent = prepared
    with pytest.raises(NetworkResourceError, match='^network_protocol$'):
        validate_network_list(ProbeResponse(200, headers, b'[]'), binding, intent,
                              request_target=network_list_target(binding))


@pytest.mark.parametrize('value', [None, {}, {'Name': 'foreign', 'Id': 'short'},
                                 {'Name': 'foreign\nprivate', 'Id': '2' * 64}])
def test_malformed_unrelated_list_rows_cannot_hide_a_name_collision(prepared, value):
    with pytest.raises(NetworkResourceError, match='^network_protocol$'):
        listed(prepared, [value])


def test_nonunique_unrelated_ids_are_not_a_complete_list(prepared):
    with pytest.raises(NetworkResourceError, match='^network_protocol$'):
        listed(prepared, [{'Name': name, 'Id': '2' * 64} for name in ('one', 'two')])


def test_short_expected_id_and_foreign_resource_cannot_select_an_inspect_target(prepared):
    source, binding, intent = prepared
    with pytest.raises(NetworkResourceError, match='^invalid_network_binding$'):
        validate_network_inspect(response(network(prepared)), binding, intent, expected_id='1' * 12)
    with pytest.raises(NetworkResourceError, match='^invalid_network_binding$'):
        network_binding(**source, resource_id=source['plan'].resources[0].resourceId)


def test_helpers_never_observe_host_or_dispatch_a_docker_effect(prepared, monkeypatch):
    import os
    import socket
    from pathlib import Path

    def forbidden(*_, **__):
        pytest.fail('pure network helper attempted host I/O')
    item = network(prepared)
    for owner, name in ((os, 'open'), (socket, 'socket'), (Path, 'read_bytes'), (Path, 'write_bytes')):
        monkeypatch.setattr(owner, name, forbidden)
    assert inspected(prepared, item).network_id == '1' * 64
    assert listed(prepared, [item]).state == 'candidate'
    assert listed(prepared, []).state == 'missing'
    assert build_network_create_body(prepared[1], prepared[2])


@pytest.mark.parametrize('extra', [
    (('content-length', '10'),), (('content-length', '-1'),),
    (('content-length', '2'), ('content-length', '2')),
    (('content-encoding', 'gzip'),), (('transfer-encoding', 'unknown'),),
    (('content-length', '2'), ('transfer-encoding', 'chunked')),
])
def test_contradictory_framing_metadata_never_establishes_a_complete_empty_list(prepared, extra):
    _, binding, intent = prepared
    with pytest.raises(NetworkResourceError, match='^network_protocol$'):
        validate_network_list(ProbeResponse(200, (('content-type', 'application/json'),) + extra, b'[]'),
                              binding, intent, request_target=network_list_target(binding))


def test_regular_complete_metadata_and_missing_optional_gateway_are_accepted(prepared):
    _, binding, intent = prepared
    item = network(prepared)
    item['IPAM']['Config'][0].pop('Gateway')
    raw = json.dumps(item).encode()
    reply = ProbeResponse(200, (('content-type', 'application/json'), ('content-length', str(len(raw))),
                               ('date', 'Sat, 05 Sep 2026 09:00:00 GMT')), raw)
    assert validate_network_inspect(reply, binding, intent, expected_id='1' * 64).network_id == '1' * 64
