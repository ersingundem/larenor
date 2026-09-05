"""Read-only network transport through synthetic Unix Engine and private journal."""

import json
import os

import pytest

from larenor_server.context import ContextResponse
from larenor_server.plugins.catalog import load_catalog
from larenor_server.plugins.network_resources import (
    NetworkResourceError, build_network_create_body, network_binding, network_list_target,
)
from larenor_server.plugins.network_transport import (
    NetworkReadLimits, NetworkTransportError, UnixNetworkEngine,
)
from larenor_server.plugins.resource_journal import ResourceJournal
from larenor_server.plugins.resource_models import WorkerPolicyBinding
from larenor_server.plugins.resource_plan import build_resource_plan
from larenor_server.plugins.stack_plan import build_media_stack_plan

from test_engine_http import VERSION, response, server


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
        yield source, binding, intent, journal


def network(prepared):
    _, binding, intent, _ = prepared
    return {**json.loads(build_network_create_body(binding, intent)), 'Id': '1' * 64,
            'Containers': {}, 'Options': None, 'ConfigFrom': {'Network': ''},
            'IPAM': {'Driver': 'default', 'Options': None,
                     'Config': [{'Subnet': '172.28.0.0/16', 'Gateway': '172.28.0.1'}]}}


def framed(value, *, chunked=False):
    body = json.dumps(value, separators=(',', ':')).encode()
    if not chunked:
        return response(body)
    return (b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n'
            + f'{len(body):x}\r\n'.encode() + body + b'\r\n0\r\n\r\n')


def engine(client, **kwargs):
    return UnixNetworkEngine(client._endpoint, peer_uid=lambda _: os.getuid(), **kwargs)


@pytest.mark.parametrize('chunked', [False, True])
def test_complete_empty_list_is_missing_and_never_dispatches_a_followup(prepared, chunked):
    _, binding, intent, journal = prepared
    before = journal.get(binding.resource.resourceId)
    with server(reply=framed([], chunked=chunked)) as (client, calls):
        observed = engine(client).list(binding, intent)
    assert (observed.state, observed.network_id) == ('missing', None)
    assert len(calls) == 2
    assert calls[1].startswith(('GET ' + network_list_target(binding) + ' HTTP/1.1\r\n').encode())
    assert journal.get(binding.resource.resourceId) == before


@pytest.mark.parametrize('chunked', [False, True])
def test_candidate_requires_separate_full_id_inspect_and_preserves_journal(prepared, chunked):
    _, binding, intent, journal = prepared
    before = journal.get(binding.resource.resourceId)
    value = network(prepared)
    summary = dict(value)
    summary.pop('Containers')
    replies = iter((framed([summary], chunked=chunked), framed(value, chunked=chunked)))
    with server(reply=lambda connection: connection.sendall(next(replies))) as (client, calls):
        reader = engine(client)
        candidate = reader.list(binding, intent)
        assert candidate.state == 'candidate'
        assert len(calls) == 2
        observed = reader.inspect(binding, intent, candidate.network_id)
    assert observed.network_id == value['Id']
    assert len(calls) == 4
    assert calls[2].startswith(b'GET /version HTTP/1.1\r\n')
    assert calls[3].startswith(('GET /v1.47/networks/' + value['Id'] + ' HTTP/1.1\r\n').encode())
    assert all(call.startswith(b'GET ') for call in calls)
    assert journal.get(binding.resource.resourceId) == before


def test_inspect_not_found_is_unavailable_without_name_fallback_or_creation(prepared):
    _, binding, intent, _ = prepared
    with server(reply=response(b'private error', status=404)) as (client, calls):
        with pytest.raises(NetworkTransportError, match='^network_engine_unavailable$'):
            engine(client).inspect(binding, intent, '1' * 64)
    assert len(calls) == 2 and all(call.startswith(b'GET ') for call in calls)
