"""Real temporary Unix streams; no host Engine or volume effects."""
from dataclasses import asdict, replace
import json
import os
import sys
import threading

import pytest

from larenor_server.plugins.engine_http import EngineHttpError, EngineHttpRequest
from larenor_server.plugins.volume_resources import VolumeResourceError, volume_inspect_target
from larenor_server.plugins.volume_transport import UnixVolumeReader, VolumeReadLimits, VolumeTransportError
from test_engine_http import VERSION, response, server
from test_volume_plan import source
from test_volume_resources import prepared, body


def reader(client, **kwargs):
    return UnixVolumeReader(client._endpoint, peer_uid=lambda _: os.getuid(), **kwargs)


def framed(value, *, chunked=False):
    raw = json.dumps(value).encode() if isinstance(value, dict) else value
    if not chunked:
        return response(raw)
    return (b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n'
            + f'{len(raw):x}\r\n'.encode() + raw + b'\r\n0\r\n\r\n')


def test_only_exact_generated_volume_get_is_newly_accepted(prepared):
    target = volume_inspect_target(prepared)
    request = EngineHttpRequest('GET', target)
    assert request.target == target and request.body is None
    assert request.headers == (('Accept', 'application/json'),)


@pytest.mark.parametrize('method,target,body_value', [
    ('POST', '/v1.47/volumes/create', None), ('DELETE', '/v1.47/volumes/larenor-appdata-v1-' + 'a' * 32, None),
    ('GET', '/v1.47/volumes', None), ('GET', '/v1.47/volumes?filters={}', None),
    ('GET', '/v1.47/volumes/foreign', None), ('GET', '/v1.47/volumes/larenor-appdata-v1-' + 'A' * 32, None),
    ('GET', '/v1.47/volumes/larenor-appdata-v1-' + 'a' * 31, None),
    ('GET', '/v1.47/volumes/larenor-appdata-v1-' + 'a' * 33, None),
    ('GET', '/v1.47/volumes/larenor-appdata-v1-' + 'a' * 32 + '?force=1', None),
    ('GET', '/v1.47/volumes/larenor-appdata-v1-' + 'a' * 32 + '/json', None),
    ('GET', '/v1.47/volumes/larenor-appdata-v1-%61' + 'a' * 31, None),
    ('GET', '/v1.47/volumes/larenor-appdata-v1-' + 'a' * 32, b'{}'),
])
def test_list_arbitrary_name_mutations_query_and_body_are_closed(method, target, body_value):
    with pytest.raises(EngineHttpError, match='^invalid_engine_request$'):
        EngineHttpRequest(method, target, body=body_value)


@pytest.mark.parametrize('chunked', [False, True])
def test_one_stream_version_then_exact_inspect_returns_only_typed_labels(prepared, chunked):
    with server(reply=framed(body(prepared), chunked=chunked)) as (client, calls):
        result = reader(client).inspect(prepared)
    assert result.state == 'labels_matched' and result.resource_id == prepared.resource_id
    assert len(calls) == 2
    assert calls[0].startswith(b'GET /version HTTP/1.1\r\n')
    assert calls[1].startswith(('GET ' + volume_inspect_target(prepared) + ' HTTP/1.1\r\n').encode())
    assert 'DO-NOT-EXPOSE' not in repr(result) + json.dumps(asdict(result))
    assert not {'Mountpoint', 'ready', 'created', 'lease'} & asdict(result).keys()


@pytest.mark.parametrize('status', [201, 301, 401, 404, 500])
def test_no_create_missing_or_redirect_adoption_and_no_retry(prepared, status):
    with server(reply=response(b'private-error', status=status, extra=b'Location: http://private.invalid/\r\n')) as (client, calls):
        with pytest.raises(VolumeTransportError, match='^volume_engine_unavailable$'):
            reader(client).inspect(prepared)
    assert len(calls) == 2


@pytest.mark.parametrize('field', ['volume-journal', 'ownership-nonce', 'core', 'specification'])
def test_other_scope_nonce_or_specification_is_never_adopted(prepared, field):
    value = body(prepared)
    value['Labels']['org.larenor.' + field] = 'e' * 64
    with server(reply=framed(value)) as (client, calls):
        with pytest.raises(VolumeResourceError, match='^volume_conflict$'):
            reader(client).inspect(prepared)
    assert len(calls) == 2


def test_forged_binding_never_opens_transport(prepared):
    changed = replace(prepared, resource_id='d' * 32)
    with server() as (client, calls):
        with pytest.raises(VolumeResourceError, match='^invalid_volume_binding$'):
            reader(client).inspect(changed)
    assert calls == []


@pytest.mark.parametrize('raw,code', [
    (b'{"Name":"a","Name":"b"}', 'volume_protocol'),
    (b'x' * 65537, 'volume_response_limit'),
], ids=['duplicate-json', 'oversize'])
def test_bounded_corrupt_body_is_static(prepared, raw, code):
    with server(reply=framed(raw)) as (client, calls):
        with pytest.raises(VolumeResourceError, match='^' + code + '$'):
            reader(client).inspect(prepared)
    assert len(calls) == 2


@pytest.mark.parametrize('version', [{**VERSION, 'ApiVersion': '1.46'}, {**VERSION, 'Arch': 'arm64'}])
def test_version_or_platform_mismatch_sends_no_inspect(prepared, version):
    with server(version=response(version)) as (client, calls):
        with pytest.raises(VolumeTransportError, match='^volume_api_unsupported$'):
            reader(client).inspect(prepared)
    assert len(calls) == 1


def test_pre_cancel_does_not_open_socket(prepared):
    event = threading.Event()
    event.set()
    with server() as (client, calls):
        with pytest.raises(VolumeTransportError, match='^volume_cancelled$'):
            reader(client).inspect(prepared, cancelled=event)
    assert calls == []


@pytest.mark.parametrize('platform', ['linux/amd64', 'linux/arm64'])
def test_selected_plan_platform_controls_handshake(source, platform):
    from larenor_server.context import ContextResponse
    from larenor_server.plugins.stack_plan import build_media_stack_plan
    from larenor_server.plugins.volume_plan import build_volume_plan
    from larenor_server.plugins.volume_resources import volume_binding
    original, catalog, policy = source
    stack = build_media_stack_plan(catalog, {}, platform,
        ContextResponse(schemaVersion=1, coreId=original.coreId, homeId=original.homeId), original.preparationId)
    plan = build_volume_plan(stack, catalog, policy)
    binding = volume_binding(plan, stack, catalog, policy, plan.resources[0].resourceId,
                             journal_id='e' * 32, ownership_nonce='f' * 32)
    with server(version=response({**VERSION, 'Arch': platform.split('/')[1]}),
                reply=framed(body(binding))) as (client, calls):
        assert reader(client).inspect(binding).state == 'labels_matched'
    assert len(calls) == 2


@pytest.mark.parametrize('peer', [True, None, -1, 'private-peer'])
def test_wrong_peer_sends_no_http(prepared, peer):
    with server() as (client, calls):
        with pytest.raises(VolumeTransportError, match='^volume_engine_unavailable$'):
            UnixVolumeReader(client._endpoint, peer_uid=lambda _: peer).inspect(prepared)
    assert calls == []


@pytest.mark.parametrize('when', ['version', 'body'])
def test_replaced_socket_blocks_request_or_return(prepared, when):
    from pathlib import Path
    import socket
    replacement = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    def change(connection):
        path = Path(client._endpoint.path)
        path.unlink()
        replacement.bind(str(path))
        path.chmod(0o600)
        connection.sendall(response(VERSION) if when == 'version' else framed(body(prepared)))
    with replacement, server(**({'version': change} if when == 'version' else {'reply': change})) as (client, calls):
        with pytest.raises(VolumeTransportError, match='^volume_engine_unavailable$'):
            reader(client).inspect(prepared)
    assert len(calls) == (1 if when == 'version' else 2)


@pytest.mark.parametrize('when', ['after_version', 'after_validation'])
def test_late_cancel_cannot_publish_valid_labels(prepared, when, monkeypatch):
    from larenor_server.plugins import engine_http, volume_transport
    event = threading.Event()
    module, name = ((engine_http, '_compatibility') if when == 'after_version'
                    else (volume_transport, 'validate_volume_inspect'))
    original = getattr(module, name)
    def cancel(*args, **kwargs):
        result = original(*args, **kwargs)
        event.set()
        return result
    monkeypatch.setattr(module, name, cancel)
    with server(reply=framed(body(prepared))) as (client, calls):
        with pytest.raises(VolumeTransportError, match='^volume_cancelled$'):
            reader(client).inspect(prepared, cancelled=event)
    assert len(calls) == (1 if when == 'after_version' else 2)


def test_cancellation_during_stalled_body_closes_socket(prepared):
    event, closed = threading.Event(), threading.Event()
    def stall(connection):
        connection.sendall(b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n')
        event.set()
        try:
            remaining = connection.recv(1)
        except ConnectionResetError:
            remaining = b''  # Linux may close with unread response headers.
        assert remaining == b''
        closed.set()
    with server(reply=stall) as (client, calls):
        with pytest.raises(VolumeTransportError, match='^volume_cancelled$'):
            reader(client).inspect(prepared, cancelled=event)
        assert closed.wait(1)
    assert len(calls) == 2


@pytest.mark.parametrize('limits,phase', [
    (VolumeReadLimits(total_seconds=0.1, idle_seconds=1), 'version'),
    (VolumeReadLimits(total_seconds=0.1, idle_seconds=1), 'body'),
    (VolumeReadLimits(total_seconds=1, idle_seconds=0.05), 'body'),
])
def test_total_and_idle_deadlines_close_socket_without_retry(prepared, limits, phase):
    import time
    closed = threading.Event()
    def stall(connection):
        assert connection.recv(1) == b''
        closed.set()
    with server(**({'version': stall} if phase == 'version' else {'reply': stall})) as (client, calls):
        start = time.monotonic()
        with pytest.raises(VolumeTransportError, match='^volume_timeout$'):
            reader(client, limits=limits).inspect(prepared)
        assert time.monotonic() - start < 1 and closed.wait(1)
    assert len(calls) == (1 if phase == 'version' else 2)


@pytest.mark.parametrize('damage', ['duplicate-length', 'range', 'encoding', 'truncated', 'chunk-trailer'])
def test_original_response_framing_is_not_rewritten_to_a_good_envelope(prepared, damage):
    raw = json.dumps(body(prepared)).encode()
    wire = {
        'duplicate-length': response(raw, extra=f'Content-Length: {len(raw)}\r\n'.encode()),
        'range': response(raw, extra=b'Content-Range: bytes 0-100/999\r\n'),
        'encoding': response(raw, extra=b'Content-Encoding: gzip\r\n'),
        'truncated': response(raw)[:-2],
        'chunk-trailer': framed(raw, chunked=True)[:-2] + b'X-Private: hidden\r\n\r\n',
    }[damage]
    with server(reply=wire) as (client, calls):
        with pytest.raises(VolumeResourceError, match='^volume_protocol$'):
            reader(client).inspect(prepared)
    assert len(calls) == 2


def test_chunk_count_is_bounded_independently_of_bytes(prepared):
    raw = json.dumps(body(prepared)).encode()
    chunks = b''.join(b'1\r\n' + raw[i:i+1] + b'\r\n' for i in range(len(raw)))
    wire = b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n' + chunks + b'0\r\n\r\n'
    with server(reply=wire) as (client, calls):
        with pytest.raises(VolumeResourceError, match='^volume_response_limit$'):
            reader(client, limits=VolumeReadLimits(max_chunks=1)).inspect(prepared)
    assert len(calls) == 2


@pytest.mark.parametrize('when', ['in_body', 'after_validation'])
def test_binding_alias_cannot_change_observation_scope(prepared, when, monkeypatch):
    from larenor_server.plugins import volume_transport
    raw = framed(body(prepared))
    if when == 'after_validation':
        original = volume_transport.validate_volume_inspect
        def mutate(*args, **kwargs):
            result = original(*args, **kwargs)
            object.__setattr__(prepared, 'journal_id', '1' * 32)
            return result
        monkeypatch.setattr(volume_transport, 'validate_volume_inspect', mutate)
        reply = raw
    else:
        def reply(connection):
            object.__setattr__(prepared, 'journal_id', '1' * 32)
            connection.sendall(raw)
    with server(reply=reply) as (client, calls):
        with pytest.raises(VolumeResourceError, match='^(volume_conflict|invalid_volume_binding)$'):
            reader(client).inspect(prepared)
    assert len(calls) == 2


@pytest.mark.parametrize('name,value', [
    ('total_seconds', True), ('total_seconds', 11), ('total_seconds', float('nan')),
    ('total_seconds', 0), ('total_seconds', 'private'), ('idle_seconds', -1),
    ('idle_seconds', 3), ('idle_seconds', float('inf')), ('max_chunks', True),
    ('max_chunks', 0), ('max_chunks', 4097), ('max_chunks', 1.5),
])
def test_trusted_limits_can_only_reduce_defaults(name, value):
    with pytest.raises(VolumeTransportError, match='^invalid_volume_limits$'):
        VolumeReadLimits(**{name: value})


@pytest.mark.parametrize('damage', ['wrong_type', 'mutated', 'extra'])
def test_limits_are_revalidated_on_use(prepared, damage):
    with server() as (client, calls):
        actual = reader(client)
        if damage == 'wrong_type':
            actual._limits = {}
        else:
            object.__setattr__(actual._limits, 'max_chunks' if damage == 'mutated' else 'private', True)
        with pytest.raises(VolumeTransportError, match='^invalid_volume_limits$'):
            actual.inspect(prepared)
    assert calls == []


def test_invalid_constructor_and_cancel_are_static_without_io(prepared):
    with pytest.raises(VolumeResourceError, match='^invalid_volume_binding$'):
        UnixVolumeReader('private socket')
    with server() as (client, calls):
        with pytest.raises(VolumeResourceError, match='^invalid_volume_binding$'):
            UnixVolumeReader(client._endpoint, peer_uid=True)
        with pytest.raises(VolumeTransportError, match='^invalid_volume_limits$'):
            UnixVolumeReader(client._endpoint, limits={})
        with pytest.raises(VolumeResourceError, match='^invalid_volume_binding$'):
            reader(client).inspect(prepared, cancelled=True)
    assert calls == []


def test_environment_does_not_enable_other_transports_or_raw_errors(prepared, monkeypatch):
    from larenor_server.plugins.docker_probe import DockerEndpoint
    for key in ('DOCKER_HOST', 'DOCKER_TLS_VERIFY', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY'):
        monkeypatch.setenv(key, 'http://private.invalid/secret')
    with server(reply=framed(body(prepared))) as (client, calls):
        assert reader(client).inspect(prepared).state == 'labels_matched'
    assert all(b'Authorization' not in request and b'X-Registry-Auth' not in request for request in calls)
    assert str(VolumeTransportError('private-error')) == 'volume_engine_unavailable'
    with pytest.raises(VolumeTransportError, match='^volume_engine_unavailable$'):
        UnixVolumeReader(DockerEndpoint('/missing-private.sock', os.getuid()), peer_uid=lambda _: os.getuid()).inspect(prepared)


@pytest.mark.skipif(sys.platform != 'linux', reason='production SO_PEERCRED is Linux-only')
def test_linux_real_peer_credentials_and_read(prepared):
    with server(reply=framed(body(prepared))) as (client, calls):
        assert UnixVolumeReader(client._endpoint).inspect(prepared).state == 'labels_matched'
    assert len(calls) == 2


def test_cancel_during_final_binding_validation_cannot_escape_engine_guard(prepared, monkeypatch):
    from larenor_server.plugins import volume_transport
    event = threading.Event()
    original = volume_transport.volume_expected_labels
    checks = []
    def labels(binding):
        result = original(binding)
        checks.append(1)
        if len(checks) == 2:  # Final re-derivation, after validating the HTTP body.
            event.set()
        return result
    monkeypatch.setattr(volume_transport, 'volume_expected_labels', labels)
    with server(reply=framed(body(prepared))) as (client, calls):
        with pytest.raises(VolumeTransportError, match='^volume_cancelled$'):
            reader(client).inspect(prepared, cancelled=event)
    assert len(checks) == len(calls) == 2
