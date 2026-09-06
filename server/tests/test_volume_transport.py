"""Real temporary Unix streams; no host Engine or volume effects."""
from dataclasses import asdict, replace
import json
import os
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
