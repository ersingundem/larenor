"""Read-only network transport through synthetic Unix Engine and private journal."""

from dataclasses import replace
import json
import os
from pathlib import Path
import socket
import sys
import threading
import time

import pytest

from larenor_server.context import ContextResponse
from larenor_server.plugins.catalog import load_catalog
from larenor_server.plugins.docker_probe import DockerEndpoint
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
def prepared(tmp_path, request):
    catalog = load_catalog()
    policy = WorkerPolicyBinding(schemaVersion=1, workerPolicyVersion=3, workerPolicyDigest='d' * 64)
    stack = build_media_stack_plan(catalog, {}, getattr(request, 'param', 'linux/amd64'),
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
@pytest.mark.parametrize('prepared', ['linux/amd64', 'linux/arm64'], indirect=True)
def test_complete_empty_list_is_missing_and_never_dispatches_a_followup(prepared, chunked):
    source, binding, intent, journal = prepared
    before = journal.get(binding.resource.resourceId)
    version = response({**VERSION, 'Arch': source['plan'].platform.split('/')[1]})
    with server(version=version, reply=framed([], chunked=chunked)) as (client, calls):
        observed = engine(client).list(binding, intent)
    assert (observed.state, observed.network_id) == ('missing', None)
    assert len(calls) == 2
    assert calls[1].startswith(('GET ' + network_list_target(binding) + ' HTTP/1.1\r\n').encode())
    assert journal.get(binding.resource.resourceId) == before


@pytest.mark.parametrize('chunked', [False, True])
@pytest.mark.parametrize('prepared', ['linux/amd64', 'linux/arm64'], indirect=True)
def test_candidate_requires_separate_full_id_inspect_and_preserves_journal(prepared, chunked):
    source, binding, intent, journal = prepared
    before = journal.get(binding.resource.resourceId)
    value = network(prepared)
    summary = dict(value)
    summary.pop('Containers')
    replies = iter((framed([summary], chunked=chunked), framed(value, chunked=chunked)))
    version = response({**VERSION, 'Arch': source['plan'].platform.split('/')[1]})
    with server(version=version, reply=lambda connection: connection.sendall(next(replies))) as (client, calls):
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


@pytest.mark.parametrize('mode', ['list', 'inspect'])
@pytest.mark.parametrize('status', [206, 301, 401, 403, 404, 500])
def test_non_200_cannot_prove_absence_or_ownership_and_never_follows_redirect(prepared, mode, status):
    _, binding, intent, _ = prepared
    with server(reply=response(b'private daemon error', status=status,
                               extra=b'Location: http://private.example/secret\r\n')) as (client, calls):
        with pytest.raises(NetworkTransportError, match='^network_engine_unavailable$'):
            if mode == 'list':
                engine(client).list(binding, intent)
            else:
                engine(client).inspect(binding, intent, '1' * 64)
    assert len(calls) == 2 and all(call.startswith(b'GET ') for call in calls)


@pytest.mark.parametrize('change', ['foreign', 'two_ids', 'duplicate_id', 'attached', 'missing_containers', 'id_mismatch'])
def test_runtime_conflicts_are_never_downgraded_to_missing(prepared, change):
    _, binding, intent, _ = prepared
    value = network(prepared)
    if change == 'foreign':
        value['Labels'] = {}
        values = [value]
    elif change == 'two_ids':
        values = [value, {**value, 'Id': '2' * 64}]
    elif change == 'duplicate_id':
        values = [value, value]
    elif change == 'attached':
        value['Containers'] = {'foreign-id': {'Name': 'private-container'}}
        values = value
    elif change == 'missing_containers':
        value.pop('Containers')
        values = value
    else:
        value['Id'] = '2' * 64
        values = value
    with server(reply=framed(values)) as (client, _):
        with pytest.raises(NetworkResourceError, match='^network_(conflict|multiple)$'):
            if type(values) is list:
                engine(client).list(binding, intent)
            else:
                engine(client).inspect(binding, intent, '1' * 64)


def test_endpoint_attached_after_candidate_is_rejected_by_separate_inspect(prepared):
    _, binding, intent, journal = prepared
    before = journal.get(binding.resource.resourceId)
    value = network(prepared)
    summary = dict(value)
    summary.pop('Containers')
    changed = {**value, 'Containers': {'foreign': {'Name': 'private attachment'}}}
    replies = iter((framed([summary]), framed(changed)))
    with server(reply=lambda connection: connection.sendall(next(replies))) as (client, calls):
        reader = engine(client)
        candidate = reader.list(binding, intent)
        assert candidate.state == 'candidate' and len(calls) == 2
        with pytest.raises(NetworkResourceError, match='^network_conflict$'):
            reader.inspect(binding, intent, candidate.network_id)
    assert len(calls) == 4 and all(call.startswith(b'GET ') for call in calls)
    assert journal.get(binding.resource.resourceId) == before


@pytest.mark.parametrize('damage', ['policy', 'catalog', 'resource', 'nonce', 'specification',
                                  'journal_id', 'prepared', 'revision_bool', 'intent_extra', 'binding_extra'])
def test_invalid_binding_or_intent_fails_before_any_http(prepared, damage):
    source, binding, intent, _ = prepared
    if damage == 'policy':
        object.__setattr__(source['policy'], 'workerPolicyVersion', True)
    elif damage == 'catalog':
        object.__setattr__(binding.source[0], 'catalogDigest', 'f' * 64)
    elif damage == 'resource':
        object.__setattr__(binding.resource, 'internal', 1)
    elif damage in ('nonce', 'specification', 'journal_id'):
        field = {'nonce': 'ownership_nonce', 'specification': 'specification_digest', 'journal_id': 'journal_id'}[damage]
        intent = replace(intent, **{field: 'private invalid value'})
    elif damage == 'prepared':
        intent = replace(intent, receipt=replace(intent.receipt, state='prepared', revision=1, code='resource_prepared'))
    elif damage == 'revision_bool':
        intent = replace(intent, receipt=replace(intent.receipt, revision=True))
    else:
        object.__setattr__(intent if damage == 'intent_extra' else binding, 'secret', 'hidden')
    with server() as (client, calls):
        with pytest.raises(NetworkResourceError, match='^invalid_network_binding$'):
            engine(client).list(binding, intent)
    assert calls == []


def test_binding_uses_its_verified_plan_snapshot_not_an_unbound_original_copy(prepared):
    source, binding, intent, _ = prepared
    assert source['plan'] is not binding.source[0]
    object.__setattr__(source['plan'], 'catalogDigest', 'f' * 64)
    with server(reply=framed([])) as (client, calls):
        assert engine(client).list(binding, intent).state == 'missing'
    assert len(calls) == 2


@pytest.mark.parametrize('network_id', ['1' * 12, 'A' * 64, '1' * 65, '../private', '1' * 64 + '?verbose=true',
                                       '%31' * 64, None, True, b'1' * 64])
def test_inspect_id_rejected_before_any_http(prepared, network_id):
    _, binding, intent, _ = prepared
    with server() as (client, calls):
        with pytest.raises(NetworkResourceError, match='^invalid_network_binding$'):
            engine(client).inspect(binding, intent, network_id)
    assert calls == []


def test_uncertain_intent_remains_read_only_and_does_not_update_journal(prepared):
    _, binding, intent, journal = prepared
    value = network(prepared)
    uncertain = journal.mark_uncertain(binding.resource.resourceId, intent.receipt.revision)
    intent = replace(intent, receipt=uncertain)
    with server(reply=framed(value)) as (client, calls):
        assert engine(client).inspect(binding, intent, '1' * 64).network_id == '1' * 64
    assert all(call.startswith(b'GET ') for call in calls)
    assert journal.get(binding.resource.resourceId) == uncertain


def test_source_changed_during_response_is_revalidated_before_return(prepared):
    _, binding, intent, _ = prepared

    def reply(connection):
        object.__setattr__(intent, 'ownership_nonce', 'changed after dispatch')
        connection.sendall(framed([]))

    with server(reply=reply) as (client, calls):
        with pytest.raises(NetworkResourceError, match='^invalid_network_binding$'):
            engine(client).list(binding, intent)
    assert len(calls) == 2


@pytest.mark.parametrize('chunked', [False, True])
def test_original_http_framing_headers_are_given_to_pure_validator(prepared, chunked, monkeypatch):
    from larenor_server.plugins import network_transport
    _, binding, intent, _ = prepared
    original = network_transport.validate_network_list
    observed = []

    def validate(value, *args, **kwargs):
        observed.append(value)
        return original(value, *args, **kwargs)

    monkeypatch.setattr(network_transport, 'validate_network_list', validate)
    with server(reply=framed([], chunked=chunked)) as (client, _):
        assert engine(client).list(binding, intent).state == 'missing'
    assert observed[0].body == b'[]'
    headers = dict(observed[0].headers)
    assert headers['content-type'] == 'application/json'
    if chunked:
        assert headers['transfer-encoding'] == 'chunked' and 'content-length' not in headers
    else:
        assert headers['content-length'] == '2' and 'transfer-encoding' not in headers


@pytest.mark.parametrize('raw', [
    response(b'[]', extra=b'Link: <private>; rel=next\r\n'),
    response(b'[]', extra=b'Content-Range: items 0-1/3\r\n'),
    response(b'[]', extra=b'Content-Encoding: gzip\r\n'),
    response(b'[]', extra=b'Content-Length: 2\r\n'),
    response(b'[]', extra=b'Transfer-Encoding: chunked\r\n'),
    b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n[]',
    b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 3\r\n\r\n[]',
    b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n[]\r\n',
    b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n[]\r\n0\r\nX: trailer\r\n\r\n',
    response(b'[{"Name":"one","Name":"other"}]'), response(b'{"items":[],"next":"private"}'),
    response(b'[{"Name":true,"Id":"' + b'1' * 64 + b'"}]'),
])
def test_partial_or_ambiguous_runtime_list_is_never_missing(prepared, raw):
    _, binding, intent, _ = prepared
    with server(reply=raw) as (client, _):
        with pytest.raises(NetworkResourceError, match='^network_protocol$'):
            engine(client).list(binding, intent)


@pytest.mark.parametrize('mode,maximum', [('list', 131072), ('inspect', 65536)])
@pytest.mark.parametrize('chunked', [False, True])
def test_fixed_body_limit_is_enforced_before_accumulation(prepared, mode, maximum, chunked):
    _, binding, intent, _ = prepared
    header = b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n'
    raw = (header + b'Transfer-Encoding: chunked\r\n\r\n' + f'{maximum + 1:x}\r\n'.encode()
           if chunked else header + f'Content-Length: {maximum + 1}\r\n\r\n'.encode())
    with server(reply=raw) as (client, _):
        with pytest.raises(NetworkResourceError, match='^network_response_limit$'):
            if mode == 'list':
                engine(client).list(binding, intent)
            else:
                engine(client).inspect(binding, intent, '1' * 64)


def test_entry_cap_and_chunk_cap_are_independent(prepared):
    _, binding, intent, _ = prepared
    values = [{'Name': f'other-{index}', 'Id': f'{index:064x}'} for index in range(129)]
    with server(reply=framed(values)) as (client, _):
        with pytest.raises(NetworkResourceError, match='^network_response_limit$'):
            engine(client).list(binding, intent)
    raw = (b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n'
           b'1\r\n[\r\n1\r\n]\r\n0\r\n\r\n')
    with server(reply=raw) as (client, _):
        with pytest.raises(NetworkResourceError, match='^network_response_limit$'):
            engine(client, limits=NetworkReadLimits(max_chunks=1)).list(binding, intent)


@pytest.mark.parametrize('field,value', [('total_seconds', True), ('total_seconds', 10.01), ('total_seconds', 0),
    ('total_seconds', float('nan')), ('idle_seconds', float('inf')), ('idle_seconds', 2.01),
    ('idle_seconds', -1), ('max_chunks', True), ('max_chunks', 1.0), ('max_chunks', 4097), ('max_chunks', 0)])
def test_private_limits_can_only_reduce_safe_defaults(field, value):
    with pytest.raises(NetworkTransportError, match='^invalid_network_limits$'):
        NetworkReadLimits(**{field: value})


@pytest.mark.parametrize('damage', ['bad_type', 'mutated', 'extra'])
def test_limits_are_revalidated_per_exchange(prepared, damage):
    _, binding, intent, _ = prepared
    with server() as (client, calls):
        reader = engine(client)
        if damage == 'bad_type':
            reader._limits = {'total_seconds': 1}
        else:
            object.__setattr__(reader._limits, 'max_chunks' if damage == 'mutated' else 'secret', True)
        with pytest.raises(NetworkTransportError, match='^invalid_network_limits$'):
            reader.list(binding, intent)
    assert calls == []


@pytest.mark.parametrize('when', ['before', 'after_version', 'after_validation'])
def test_cancel_cannot_return_a_read_observation(prepared, when, monkeypatch):
    from larenor_server.plugins import engine_http, network_transport
    _, binding, intent, _ = prepared
    cancelled = threading.Event()
    if when == 'before':
        cancelled.set()
    else:
        module, name = ((engine_http, '_compatibility') if when == 'after_version'
                        else (network_transport, 'validate_network_list'))
        original = getattr(module, name)

        def observed(*args, **kwargs):
            value = original(*args, **kwargs)
            cancelled.set()
            return value

        monkeypatch.setattr(module, name, observed)
    with server(reply=framed([])) as (client, calls):
        with pytest.raises(NetworkTransportError, match='^network_cancelled$'):
            engine(client).list(binding, intent, cancelled=cancelled)
    assert len(calls) == {'before': 0, 'after_version': 1, 'after_validation': 2}[when]


@pytest.mark.parametrize('disconnect', ['native', 'reset'])
def test_cancel_during_stalled_read_closes_socket(prepared, disconnect):
    _, binding, intent, _ = prepared
    cancelled = threading.Event()
    closed = threading.Event()

    def reply(connection):
        connection.sendall(b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n')
        cancelled.set()

        def receive_disconnect():
            value = connection.recv(1)
            # Model Linux's unread-data close on every test host, but only
            # after the real connection has demonstrably disconnected.
            if value == b'' and disconnect == 'reset':
                raise ConnectionResetError('synthetic unread-data disconnect')
            return value

        assert receive_disconnect() == b''
        closed.set()

    with server(reply=reply) as (client, _):
        with pytest.raises(NetworkTransportError, match='^network_cancelled$'):
            engine(client).list(binding, intent, cancelled=cancelled)
        assert closed.wait(1)


@pytest.mark.skipif(sys.platform != 'linux', reason='Linux unread Unix stream close semantics')
def test_linux_unread_unix_stream_close_reports_connection_reset():
    # unix_release_sock sets ECONNRESET when a stream closes with unread data:
    # https://github.com/torvalds/linux/blob/v6.8/net/unix/af_unix.c#L605-L610
    receiver, sender = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    with receiver, sender:
        sender.settimeout(1)
        sender.sendall(b'unread')
        receiver.close()
        with pytest.raises(ConnectionResetError):
            sender.recv(1)


@pytest.mark.parametrize('limits', [NetworkReadLimits(total_seconds=0.1, idle_seconds=1),
                                    NetworkReadLimits(total_seconds=1, idle_seconds=0.05)])
def test_total_and_idle_timeouts_are_static_and_close_connection(prepared, limits):
    _, binding, intent, _ = prepared

    def reply(connection):
        assert connection.recv(1) == b''

    with server(reply=reply) as (client, _):
        started = time.monotonic()
        with pytest.raises(NetworkTransportError, match='^network_timeout$'):
            engine(client, limits=limits).list(binding, intent)
        assert time.monotonic() - started < 1


@pytest.mark.parametrize('when', ['version', 'body'])
def test_changed_socket_ancestry_blocks_operation_or_result(prepared, when):
    _, binding, intent, _ = prepared

    def reply(connection):
        Path(client._endpoint.path).parent.chmod(0o777)
        connection.sendall(response(VERSION) if when == 'version' else framed([]))

    with server(**({'version': reply} if when == 'version' else {'reply': reply})) as (client, calls):
        with pytest.raises(NetworkTransportError, match='^network_engine_unavailable$'):
            engine(client).list(binding, intent)
    assert len(calls) == (1 if when == 'version' else 2)


@pytest.mark.parametrize('version', [{**VERSION, 'ApiVersion': '1.46'}, {**VERSION, 'MinAPIVersion': '1.48'},
                                     {**VERSION, 'Os': 'windows'}, {**VERSION, 'Arch': 'arm64'}])
def test_wrong_api_or_platform_blocks_network_request(prepared, version):
    _, binding, intent, _ = prepared
    with server(version=response(version)) as (client, calls):
        with pytest.raises(NetworkTransportError, match='^network_api_unsupported$'):
            engine(client).list(binding, intent)
    assert len(calls) == 1


@pytest.mark.parametrize('peer', [True, None, -1])
def test_wrong_peer_sends_no_http(prepared, peer):
    _, binding, intent, _ = prepared
    with server() as (client, calls):
        reader = UnixNetworkEngine(client._endpoint, peer_uid=lambda _: peer)
        with pytest.raises(NetworkTransportError, match='^network_engine_unavailable$'):
            reader.list(binding, intent)
    assert calls == []


def test_invalid_endpoint_cancel_and_limit_inputs_have_static_errors(prepared):
    _, binding, intent, _ = prepared
    with pytest.raises(NetworkResourceError, match='^invalid_network_binding$'):
        UnixNetworkEngine('secret socket path')
    with server() as (client, calls):
        with pytest.raises(NetworkResourceError, match='^invalid_network_binding$'):
            UnixNetworkEngine(client._endpoint, peer_uid=True)
        with pytest.raises(NetworkTransportError, match='^invalid_network_limits$'):
            UnixNetworkEngine(client._endpoint, limits={})
        with pytest.raises(NetworkResourceError, match='^invalid_network_binding$'):
            engine(client).list(binding, intent, cancelled=True)
    assert calls == []


def test_environment_options_and_raw_errors_never_change_dispatch(prepared, monkeypatch):
    _, binding, intent, _ = prepared
    for key in ('DOCKER_HOST', 'DOCKER_TLS_VERIFY', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY'):
        monkeypatch.setenv(key, 'http://127.0.0.1:1/secret')
    with server(reply=framed([])) as (client, calls):
        assert engine(client).list(binding, intent).state == 'missing'
    assert all(b'Authorization' not in call and b'X-Registry-Auth' not in call for call in calls)
    assert str(NetworkTransportError('private unknown')) == 'network_engine_unavailable'
    reader = UnixNetworkEngine(DockerEndpoint('/missing-private-engine.sock', os.getuid()), peer_uid=lambda _: os.getuid())
    with pytest.raises(NetworkTransportError, match='^network_engine_unavailable$'):
        reader.list(binding, intent)


@pytest.mark.skipif(sys.platform != 'linux', reason='production SO_PEERCRED is Linux-only')
def test_linux_real_peer_uid_and_network_read(prepared):
    _, binding, intent, _ = prepared
    with server(reply=framed([])) as (client, calls):
        assert UnixNetworkEngine(client._endpoint).list(binding, intent).state == 'missing'
    assert len(calls) == 2
