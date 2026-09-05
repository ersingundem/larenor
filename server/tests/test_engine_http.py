"""Private HTTP extraction characterization; only synthetic Unix sockets."""

from contextlib import contextmanager
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import threading
from urllib.parse import quote

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
    return client.exchange(EngineHttpRequest('GET', TARGET),
                           consume or (lambda status, headers, chunks: (status, b''.join(chunks))),
                           platform='linux/amd64', limits=EngineHttpLimits(2, 1, 65536, 4096), **options)


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
