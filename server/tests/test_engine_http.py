"""Private HTTP extraction characterization; only synthetic Unix sockets."""

from contextlib import contextmanager
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import threading
import time
from urllib.parse import quote, urlencode

import pytest

from larenor_server.plugins.docker_probe import DockerEndpoint
from larenor_server.plugins.engine_http import (
    EngineHttpError, EngineHttpLimits, EngineHttpRequest, VerifiedEngineHttp,
)


REFERENCE = 'ghcr.io/example/image@sha256:' + 'a' * 64
TARGET = '/v1.47/images/' + quote(REFERENCE, safe='') + '/json'
VERSION = {'MinAPIVersion': '1.24', 'ApiVersion': '1.47', 'Os': 'linux', 'Arch': 'amd64'}


def response(body=b'{}', *, extra=b'', status=200):
    if type(body) is dict:
        body = json.dumps(body).encode()
    return (f'HTTP/1.1 {status} test\r\nContent-Type: application/json\r\n'.encode()
            + f'Content-Length: {len(body)}\r\n'.encode() + extra + b'\r\n' + body)


@contextmanager
def server(*, version=None, reply=None, peer=None):
    with tempfile.TemporaryDirectory(prefix='leh-', dir='/private/tmp' if sys.platform == 'darwin' else '/tmp') as directory:
        path = Path(directory) / 'engine.sock'
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(path))
        path.chmod(0o600)
        listener.listen(1)
        listener.settimeout(0.1)
        calls, failures = [], []
        stopped = threading.Event()

        def read(connection):
            data = bytearray()
            while not data.endswith(b'\r\n\r\n'):
                part = connection.recv(1)
                if not part:
                    return False
                data.extend(part)
                assert len(data) < 16384
            calls.append(bytes(data))
            return True

        def run():
            try:
                while not stopped.is_set():
                    try:
                        connection, _ = listener.accept()
                    except socket.timeout:
                        continue
                    with connection:
                        connection.settimeout(2)
                        if not read(connection):
                            continue
                        value = response(VERSION) if version is None else version
                        if callable(value):
                            value(connection)
                        else:
                            connection.sendall(value)
                        if not read(connection):
                            continue
                        value = response() if reply is None else reply
                        if callable(value):
                            value(connection)
                        else:
                            connection.sendall(value)
            except (BrokenPipeError, ConnectionResetError):
                pass
            except Exception as error:
                if not stopped.is_set():
                    failures.append(error)

        worker = threading.Thread(target=run, daemon=True)
        worker.start()
        client = VerifiedEngineHttp(DockerEndpoint(str(path), os.getuid()),
                                    peer_uid=peer or (lambda _: os.getuid()))
        try:
            yield client, calls
        finally:
            stopped.set()
            listener.close()
            worker.join(3)
            assert not worker.is_alive()
            assert not failures


def exchange(client, consume=None, **options):
    limits = options.pop('limits', EngineHttpLimits(2, 1, 65536, 4096))
    return client.exchange(EngineHttpRequest('GET', TARGET),
                           consume or (lambda status, headers, chunks: (status, b''.join(chunks))),
                           platform='linux/amd64', limits=limits, **options)


def test_one_connection_checks_version_before_each_fixed_request():
    with server() as (client, calls):
        assert exchange(client) == (200, b'{}')
        assert exchange(client) == (200, b'{}')
    assert len(calls) == 4
    assert all(calls[index].startswith(b'GET /version HTTP/1.1\r\n') for index in (0, 2))
    assert all(b'Connection: keep-alive\r\n' in calls[index] for index in (0, 2))
    assert all(calls[index].startswith(('GET ' + TARGET + ' HTTP/1.1\r\n').encode()) for index in (1, 3))


def test_incompatible_version_never_sends_an_operation():
    with server(version=response({**VERSION, 'ApiVersion': '1.46'})) as (client, calls):
        with pytest.raises(EngineHttpError, match='^engine_api_unsupported$'):
            exchange(client)
    assert len(calls) == 1


def test_wrong_peer_never_sends_http():
    with server(peer=lambda _: os.getuid() + 1) as (client, calls):
        with pytest.raises(EngineHttpError, match='^engine_unavailable$'):
            exchange(client)
    assert calls == []


def test_close_version_prevents_second_request():
    with server(version=response(VERSION, extra=b'Connection: close\r\n')) as (client, calls):
        with pytest.raises(EngineHttpError, match='^engine_api_unsupported$'):
            exchange(client)
    assert len(calls) == 1


def test_consumer_iterator_cannot_escape_its_connection_scope():
    with server() as (client, calls):
        escaped = exchange(client, lambda _status, _headers, chunks: chunks)
        with pytest.raises(EngineHttpError, match='^engine_protocol$'):
            next(escaped)
    assert len(calls) == 2


@pytest.mark.parametrize('change', [
    {'method': 'DELETE'}, {'method': 'get'}, {'method': True}, {'method': 'GET\r\nX: injected'},
    {'target': 'http://localhost' + TARGET}, {'target': '//localhost' + TARGET},
    {'target': '/version'}, {'target': '/v1.47/containers/json'}, {'target': '/v1.47/networks'},
    {'target': TARGET + '?auth=secret'}, {'target': TARGET + '\r\nX: injected'},
    {'target': TARGET.replace('%2F', '/')}, {'target': TARGET.replace('%2F', '%2f')},
    {'target': TARGET.replace('sha256', 'sha512')}, {'target': TARGET.replace('a' * 64, 'latest')},
    {'target': TARGET.replace('example', '..')}, {'target': 1}, {'target': 'x' * 513},
    {'headers': {'Accept': 'application/json'}}, {'headers': (('Authorization', 'secret'),)},
    {'headers': (('Accept', 'application/json\r\nX: injected'),)},
    {'headers': (('Accept', 'application/json'), ('X-Registry-Auth', 'secret'))},
    {'headers': ()}, {'body': b'{}'}, {'body': ''},
])
def test_request_rejects_unreachable_operations_and_arbitrary_wire_options(change):
    with pytest.raises(EngineHttpError, match='^invalid_engine_request$'):
        EngineHttpRequest(**({'method': 'GET', 'target': TARGET} | change))


def pull_target(platform='linux/amd64'):
    return '/v1.47/images/create?' + urlencode({'fromImage': REFERENCE, 'platform': platform})


@pytest.mark.parametrize('target', [
    pull_target() + '&all=true', pull_target() + '&platform=linux%2Farm64',
    pull_target().replace('fromImage', 'fromSrc'), pull_target().replace('platform=', 'auth='),
    pull_target().replace('amd64', 's390x'), pull_target().replace('%40sha256', '%3Alatest%40sha256'),
    pull_target().replace('fromImage=', 'fromImage=&ignored='),
    pull_target().replace('example', '%2e%2e'), '/v1.47/containers/create',
    'https://elsewhere/' + pull_target(),
])
def test_pull_request_accepts_only_canonical_digest_and_platform_query(target):
    with pytest.raises(EngineHttpError, match='^invalid_engine_request$'):
        EngineHttpRequest('POST', target)


def test_request_repr_hides_target_headers_and_body():
    value = EngineHttpRequest('POST', pull_target())
    assert repr(value) == 'EngineHttpRequest()'
    assert REFERENCE not in repr(value)


@pytest.mark.parametrize('field,value', [
    ('total_seconds', True), ('total_seconds', 0), ('total_seconds', 3601),
    ('total_seconds', float('nan')), ('idle_seconds', float('inf')),
    ('idle_seconds', 121), ('idle_seconds', -1), ('max_total_bytes', True),
    ('max_total_bytes', 0), ('max_total_bytes', 67108865),
    ('max_chunks', 1.0), ('max_chunks', 1000001),
])
def test_limits_reject_nonfinite_nonstrict_and_unbounded_inputs(field, value):
    values = dict(total_seconds=2, idle_seconds=1, max_total_bytes=65536, max_chunks=4096)
    with pytest.raises(EngineHttpError, match='^invalid_engine_limits$'):
        EngineHttpLimits(**(values | {field: value}))


@pytest.mark.parametrize('which', ['request', 'limits', 'endpoint'])
def test_copied_or_mutated_private_records_revalidated_before_io(which):
    with server() as (client, calls):
        request = EngineHttpRequest('GET', TARGET)
        limits = EngineHttpLimits(2, 1, 65536, 4096)
        if which == 'request':
            object.__setattr__(request, 'target', '/v1.47/containers/json')
        elif which == 'limits':
            object.__setattr__(limits, 'max_total_bytes', True)
        else:
            object.__setattr__(client._endpoint, 'path', 'relative.sock')
        with pytest.raises(EngineHttpError, match='^invalid_engine_(request|limits)$'):
            client.exchange(request, lambda *_: None, platform='linux/amd64', limits=limits)
    assert calls == []


def test_pull_platform_mismatch_rejected_before_io():
    with server() as (client, calls):
        with pytest.raises(EngineHttpError, match='^invalid_engine_request$'):
            client.exchange(EngineHttpRequest('POST', pull_target('linux/arm64')), lambda *_: None,
                            platform='linux/amd64', limits=EngineHttpLimits(2, 1, 65536, 4096))
    assert calls == []


@pytest.mark.parametrize('point', ['before_connection', 'after_version'])
def test_cancellation_prevents_operation_dispatch(point, monkeypatch):
    from larenor_server.plugins import engine_http
    cancelled = threading.Event()
    if point == 'before_connection':
        cancelled.set()
    else:
        original = engine_http._compatibility

        def validated(*args):
            result = original(*args)
            cancelled.set()
            return result

        monkeypatch.setattr(engine_http, '_compatibility', validated)
    with server() as (client, calls):
        with pytest.raises(EngineHttpError, match='^engine_cancelled$'):
            exchange(client, cancelled=cancelled)
    assert len(calls) == (0 if point == 'before_connection' else 1)


@pytest.mark.parametrize('point', ['after_connect', 'after_version', 'after_consumer'])
def test_socket_and_ancestry_identity_changes_never_return_success(point, monkeypatch):
    from larenor_server.plugins import engine_http
    original = engine_http._identity
    count = 0
    changed_at = {'after_connect': 2, 'after_version': 3, 'after_consumer': 4}[point]

    def changed(endpoint):
        nonlocal count
        count += 1
        value = original(endpoint)
        return (*value, ('replacement',)) if count == changed_at else value

    monkeypatch.setattr(engine_http, '_identity', changed)
    with server() as (client, calls):
        with pytest.raises(EngineHttpError, match='^engine_unavailable$'):
            exchange(client)
    assert len(calls) == changed_at - 2


def test_actual_parent_replacement_before_operation_fails_closed():
    moved = None

    def version(connection):
        nonlocal moved
        parent = Path(client._endpoint.path).parent
        moved = parent.with_name(parent.name + '-moved')
        parent.rename(moved)
        parent.mkdir(mode=0o700)
        try:
            connection.sendall(response(VERSION))
        finally:
            # Keep the replacement visible until the client has rejected it.
            assert connection.recv(1) == b''

    try:
        with server(version=version) as (client, calls):
            with pytest.raises(EngineHttpError, match='^engine_unavailable$'):
                exchange(client)
        assert len(calls) == 1
    finally:
        if moved is not None:
            (moved / 'engine.sock').unlink()
            moved.rmdir()


def test_consumer_failure_closes_its_iterator_and_socket():
    escaped = []

    def consume(_status, _headers, chunks):
        escaped.append(chunks)
        raise ValueError('private daemon response must never escape')

    with server() as (client, _):
        with pytest.raises(EngineHttpError, match='^engine_unavailable$'):
            exchange(client, consume)
    with pytest.raises(EngineHttpError, match='^engine_protocol$'):
        next(escaped[0])


def test_redirect_status_is_delivered_once_without_following_location():
    with server(reply=response(status=301, extra=b'Location: http://elsewhere/secret\r\n')) as (client, calls):
        assert exchange(client, lambda status, _headers, _chunks: status) == 301
    assert len(calls) == 2


@pytest.mark.parametrize('raw', [
    b'HTTP/1.0 200 old\r\nContent-Length: 2\r\n\r\n{}',
    b'HTTP/1.1 100 Continue\r\n\r\n',
    response(extra=b'X-Invalid: bad\x00value\r\n'),
    response(extra=b'Invalid name: value\r\n'),
    response(extra=b'NoColon\r\n'),
    response(extra=b'X-Header: ' + b'a' * 8192 + b'\r\n'),
    response(extra=b'X-Header: x\r\n' * 101),
    response(extra=(b'X-Header: ' + b'a' * 8000 + b'\r\n') * 5),
])
def test_header_syntax_count_line_and_aggregate_bounds(raw):
    with server(reply=raw) as (client, _):
        with pytest.raises(EngineHttpError, match='^engine_protocol$'):
            exchange(client)


def test_version_bytes_have_separate_fixed_limit():
    version = b'HTTP/1.1 200 large\r\nContent-Type: application/json\r\nContent-Length: 65537\r\n\r\n'
    with server(version=version) as (client, calls):
        with pytest.raises(EngineHttpError, match='^engine_stream_limit$'):
            exchange(client, limits=EngineHttpLimits(2, 1, 67108864, 1000000))
    assert len(calls) == 1


def test_total_deadline_includes_version_and_is_not_reset_for_operation():
    def version(connection):
        time.sleep(0.1)
        connection.sendall(response(VERSION))

    def reply(connection):
        time.sleep(0.15)
        connection.sendall(response())

    with server(version=version, reply=reply) as (client, calls):
        started = time.monotonic()
        with pytest.raises(EngineHttpError, match='^engine_timeout$'):
            exchange(client, limits=EngineHttpLimits(0.18, 1, 65536, 4096))
        # The required timeout (rather than a successful delayed reply) proves
        # the shared budget. Leave scheduler tolerance for loaded native CI.
        assert time.monotonic() - started < 1
    assert len(calls) == 2


def test_environment_proxy_and_docker_host_are_unused(monkeypatch):
    for name in ('DOCKER_HOST', 'DOCKER_TLS_VERIFY', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY'):
        monkeypatch.setenv(name, 'http://127.0.0.1:1/never-contact')
    with server() as (client, calls):
        assert exchange(client) == (200, b'{}')
    assert len(calls) == 2


@pytest.mark.skipif(sys.platform != 'linux', reason='production SO_PEERCRED is Linux-only')
def test_real_linux_peer_credentials_on_synthetic_unix_connection():
    with server() as (client, _):
        assert exchange(VerifiedEngineHttp(client._endpoint)) == (200, b'{}')
