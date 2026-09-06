"""Synthetic Engine bytes must never authorize/adopt storage or expose host paths."""
from dataclasses import asdict, replace
import hashlib
import json
import os
import socket
import subprocess

import pytest

from larenor_server.plugins.volume_plan import build_volume_plan
from larenor_server.plugins.volume_resources import (
    VolumeResourceError, volume_binding, volume_expected_labels,
    volume_inspect_target, validate_volume_inspect,
)
from larenor_server.services.transport import ProbeResponse
from test_volume_plan import source


@pytest.fixture
def prepared(source):
    plan = build_volume_plan(*source)
    binding = volume_binding(plan, *source, plan.resources[0].resourceId,
                             journal_id='e' * 32, ownership_nonce='f' * 32)
    return binding


def body(binding):
    return {
        'Name': volume_inspect_target(binding).split('/')[-1],
        'Driver': 'local', 'Scope': 'local', 'Options': None,
        'Mountpoint': '/synthetic-private-host/DO-NOT-EXPOSE/_data',
        'Labels': volume_expected_labels(binding), 'CreatedAt': '2026-09-06T00:00:00Z',
    }


def response(value, *, status=200, extra=()):
    return ProbeResponse(status, (('content-type', 'application/json'),) + extra,
                         json.dumps(value).encode())


def inspect(binding, value):
    return validate_volume_inspect(response(value), binding,
                                   request_target=volume_inspect_target(binding))


@pytest.mark.parametrize('index', range(7))
def test_all_managed_targets_match_only_their_own_bound_labels(source, index):
    plan = build_volume_plan(*source)
    resource = plan.resources[index]
    binding = volume_binding(plan, *source, resource.resourceId,
                             journal_id='e' * 32, ownership_nonce='f' * 32)
    expected = {
        'org.larenor.volume-schema': '1', 'org.larenor.core': plan.coreId,
        'org.larenor.home': plan.homeId, 'org.larenor.preparation': plan.preparationId,
        'org.larenor.resource': resource.resourceId, 'org.larenor.operation': resource.operationId,
        'org.larenor.installation': resource.installationId,
        'org.larenor.service': resource.serviceId, 'org.larenor.child-plan': resource.childPlanHash,
        'org.larenor.volume-plan': plan.planHash, 'org.larenor.stack-plan': plan.stackPlanHash,
        'org.larenor.catalog': plan.catalogDigest,
        'org.larenor.worker-policy-version': str(plan.workerPolicyVersion),
        'org.larenor.worker-policy': plan.workerPolicyDigest,
        'org.larenor.volume-journal': 'e' * 32, 'org.larenor.ownership-nonce': 'f' * 32,
        'org.larenor.specification': hashlib.sha256(json.dumps(
            resource.model_dump(mode='json'), sort_keys=True, separators=(',', ':'),
            ensure_ascii=False).encode()).hexdigest(),
    }
    assert volume_expected_labels(binding) == expected
    target = volume_inspect_target(binding)
    assert target == '/v1.47/volumes/' + resource.name and '?' not in target
    observed = inspect(binding, body(binding))
    assert observed.state == 'labels_matched'
    assert observed.resource_id == resource.resourceId and observed.name == resource.name
    assert observed.plan_hash == plan.planHash
    assert len(observed.labels_digest) == 64
    assert not {'Mountpoint', 'mountpoint', 'created', 'ready', 'writeable', 'lease'} & asdict(observed).keys()
    assert 'DO-NOT-EXPOSE' not in repr(observed) + repr(binding) + json.dumps(asdict(observed))
    with pytest.raises((AttributeError, TypeError)):
        observed.name = 'changed'


@pytest.mark.parametrize('field,value', [
    ('Name', 'foreign-volume'), ('Driver', 'nfs'), ('Scope', 'global'),
    ('Options', {'type': 'none', 'o': 'bind', 'device': '/synthetic-private-host'}),
    ('Options', []), ('Options', False), ('Labels', None), ('Labels', []),
    ('Mountpoint', None), ('Mountpoint', []), ('Mountpoint', '/a\x00b'),
    ('Status', {'driver': 'unexpected'}), ('ClusterVolume', {}),
    ('UsageData', {'Size': 123, 'RefCount': 0}), ('DriverOpts', {}),
    ('CreatedAt', False), ('CreatedAt', 'x\ny'),
])
def test_foreign_or_unsupported_volume_is_never_adopted(prepared, field, value):
    item = {**body(prepared), field: value}
    with pytest.raises(VolumeResourceError, match='^volume_conflict$') as caught:
        inspect(prepared, item)
    assert 'synthetic-private' not in str(caught.value)


@pytest.mark.parametrize('field', ['Name', 'Driver', 'Scope', 'Options', 'Labels', 'Mountpoint'])
def test_required_engine_fields_are_not_silently_defaulted(prepared, field):
    item = body(prepared)
    del item[field]
    with pytest.raises(VolumeResourceError, match='^volume_conflict$'):
        inspect(prepared, item)


@pytest.mark.parametrize('field', [
    'core', 'home', 'preparation', 'resource', 'operation', 'installation', 'service',
    'child-plan', 'volume-plan', 'stack-plan', 'catalog', 'worker-policy-version',
    'worker-policy', 'volume-journal', 'ownership-nonce', 'specification', 'volume-schema',
])
def test_every_ownership_label_is_bound_to_current_proposal(prepared, field):
    item = body(prepared)
    item['Labels']['org.larenor.' + field] = 'foreign'
    with pytest.raises(VolumeResourceError, match='^volume_conflict$'):
        inspect(prepared, item)


def test_null_or_empty_options_and_optional_empty_local_metadata(prepared):
    for options in (None, {}):
        item = {**body(prepared), 'Options': options, 'Status': {},
                'ClusterVolume': None, 'UsageData': None}
        assert inspect(prepared, item).state == 'labels_matched'
    labels = volume_expected_labels(prepared)
    labels['org.larenor.core'] = 'altered'
    assert volume_expected_labels(prepared)['org.larenor.core'] == 'a' * 32


@pytest.mark.parametrize('mutator', ['extra', 'missing'])
def test_labels_are_exact_not_a_partial_filter(prepared, mutator):
    item = body(prepared)
    if mutator == 'extra':
        item['Labels']['foreign.owner'] = 'other'
    else:
        del item['Labels']['org.larenor.ownership-nonce']
    with pytest.raises(VolumeResourceError, match='^volume_conflict$'):
        inspect(prepared, item)


@pytest.mark.parametrize('status', [201, 204, 301, 404, 409, 500, True])
def test_create_success_missing_and_errors_are_not_inspect_observations(prepared, status):
    with pytest.raises(VolumeResourceError, match='^volume_protocol$'):
        validate_volume_inspect(response(body(prepared), status=status), prepared,
                                request_target=volume_inspect_target(prepared))


@pytest.mark.parametrize('raw', [
    b'{"Name":"first","Name":"second"}', b'{"Labels":{"x":1,"x":2}}',
    b'[]', b'null', b'{"x":NaN}', b'{"x":1.2}', b'{"x":', b'\xff',
    b'\xff\xfe{\x00}\x00', b'\xef\xbb\xbf{}', b'{"x":"\\ud800"}',
    b'{"x":' + b'[' * 20 + b'0' + b']' * 20 + b'}',
])
def test_ambiguous_or_malformed_json_is_protocol_failure(prepared, raw):
    with pytest.raises(VolumeResourceError, match='^volume_protocol$'):
        validate_volume_inspect(ProbeResponse(200, (('content-type', 'application/json'),), raw),
            prepared, request_target=volume_inspect_target(prepared))


@pytest.mark.parametrize('headers', [
    (), (('content-type', 'text/plain'),),
    (('content-type', 'application/json'), ('Content-Type', 'application/json')),
    (('content-type', 'application/json'), ('content-range', 'bytes 0-20/100')),
    (('content-type', 'application/json'), ('link', 'next-page')),
    (('content-type', 'application/json'), ('content-encoding', 'gzip')),
    (('content-type', 'application/json'), ('content-length', '2')),
    (('content-type', 'application/json'), ('transfer-encoding', 'identity')),
    (('content-type', 'application/json'), ('x-test', 'x\r\ny')),
    (('content-type', 'application/json'), ('x-test', 1)),
])
def test_partial_ambiguous_or_encoded_envelope_cannot_match(prepared, headers):
    with pytest.raises(VolumeResourceError, match='^volume_protocol$'):
        validate_volume_inspect(ProbeResponse(200, headers, json.dumps(body(prepared)).encode()),
            prepared, request_target=volume_inspect_target(prepared))


@pytest.mark.parametrize('target', ['/volumes/a', '/v1.48/volumes/a', '/v1.47/volumes', None])
def test_response_must_belong_to_generated_exact_inspect_target(prepared, target):
    with pytest.raises(VolumeResourceError, match='^volume_protocol$'):
        validate_volume_inspect(response(body(prepared)), prepared, request_target=target)


def test_response_size_has_separate_static_failure(prepared):
    with pytest.raises(VolumeResourceError, match='^volume_response_limit$'):
        validate_volume_inspect(ProbeResponse(200, (), b' ' * 65537), prepared,
                                request_target=volume_inspect_target(prepared))


@pytest.mark.parametrize('value', [None, '', 'e' * 31, 'E' * 32, 'e' * 32 + '\n', True, 'bad/private'])
def test_invalid_private_identity_never_becomes_request_target(source, value):
    plan = build_volume_plan(*source)
    for field in ['resource_id', 'journal_id', 'ownership_nonce']:
        args = dict(resource_id=plan.resources[0].resourceId, journal_id='e' * 32,
                    ownership_nonce='f' * 32)
        args[field] = value
        with pytest.raises(VolumeResourceError, match='^invalid_volume_binding$'):
            volume_binding(plan, *source, **args)


def test_forged_binding_and_mutated_source_are_rederived(prepared):
    plan, stack, catalog, policy = prepared.source
    changed = policy.model_copy(update={'workerPolicyDigest': '1' * 64})
    candidates = [None, asdict(prepared),
        replace(prepared, source=(plan, stack, catalog, changed)),
        replace(prepared, resource=plan.resources[1]),
        replace(prepared, journal_id='bad'),
        replace(prepared, source=()),
    ]
    for candidate in candidates:
        with pytest.raises(VolumeResourceError, match='^invalid_volume_binding$'):
            volume_inspect_target(candidate)


def test_observation_never_opens_host_mountpoint_or_transport(prepared, monkeypatch):
    value = body(prepared)
    def forbidden(*args, **kwargs):
        pytest.fail('volume observation touched the host or transport')
    for owner, name in [(socket, 'socket'), (subprocess, 'Popen'), (os, 'open'),
                        (os, 'mkdir'), (os, 'chown'), (os, 'stat')]:
        monkeypatch.setattr(owner, name, forbidden)
    assert inspect(prepared, value).state == 'labels_matched'
    assert prepared.source[0].installAvailable is False
