"""Private create transport: synthetic Unix server, never a real Docker daemon."""

from contextlib import contextmanager
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import threading

import pytest

from larenor_server.plugins.docker_probe import DockerEndpoint
from larenor_server.plugins.network_resources import build_network_create_body

from test_engine_http import VERSION, response
from test_network_transport import prepared  # Shared real temporary journal fixture.


ACK = {'Id': '1' * 64, 'Warning': ''}


def ack_response(value=ACK, *, chunked=False, status=201):
    raw = json.dumps(value).encode() if type(value) is dict else value
    if not chunked:
        return response(raw, status=status)
    return (f'HTTP/1.1 {status} OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n'.encode()
            + f'{len(raw):x}\r\n'.encode() + raw + b'\r\n0\r\n\r\n')


@contextmanager
def create_server(*, version=None, reply=None):
    with tempfile.TemporaryDirectory(prefix='lne-', dir='/private/tmp' if sys.platform == 'darwin' else '/tmp') as directory:
        path = Path(directory) / 'engine.sock'
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(path))
        path.chmod(0o600)
        listener.listen(2)
        listener.settimeout(0.1)
        stopped = threading.Event()
        calls, failures = [], []

        def read(connection):
            head = bytearray()
            while not head.endswith(b'\r\n\r\n'):
                part = connection.recv(1)
                if not part:
                    return False
                head.extend(part)
                assert len(head) <= 8192
            call = {'head': bytes(head), 'body': b''}
            calls.append(call)
            headers = dict(line.split(b': ', 1) for line in bytes(head).split(b'\r\n')[1:-2])
            size = int(headers.get(b'Content-Length', b'0'))
            assert 0 <= size <= 4096
            body = bytearray()
            while len(body) < size:
                part = connection.recv(size - len(body))
                if not part:
                    return False
                body.extend(part)
            call['body'] = bytes(body)
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
                        value(connection) if callable(value) else connection.sendall(value)
                        if not read(connection):
                            continue
                        value = ack_response() if reply is None else reply
                        value(connection) if callable(value) else connection.sendall(value)
            except (BrokenPipeError, ConnectionResetError):
                pass
            except Exception as error:
                if not stopped.is_set():
                    failures.append(error)

        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        try:
            yield DockerEndpoint(str(path), os.getuid()), calls
        finally:
            stopped.set()
            listener.close()
            thread.join(3)
            assert not thread.is_alive() and not failures


def creator(endpoint, **options):
    from larenor_server.plugins.network_effects import UnixNetworkCreator
    return UnixNetworkCreator(endpoint, peer_uid=lambda _: os.getuid(), **options)


@pytest.mark.parametrize('chunked', [False, True])
@pytest.mark.parametrize('prepared', ['linux/amd64', 'linux/arm64'], indirect=True)
def test_create_checks_version_then_gate_then_sends_only_bound_canonical_body(prepared, chunked):
    source, binding, intent, journal = prepared
    expected = build_network_create_body(binding, intent)
    before = journal.get(binding.resource.resourceId)
    gates = []
    version = response({**VERSION, 'Arch': source['plan'].platform.split('/')[1]})
    with create_server(version=version, reply=ack_response(chunked=chunked)) as (endpoint, calls):
        def gate():
            gates.append(len(calls))
            return True

        result = creator(endpoint).create(binding, intent, before_dispatch=gate)
    assert result.network_id == ACK['Id'] and '1' * 64 not in repr(result)
    assert gates == [1] and len(calls) == 2
    assert calls[0]['head'].startswith(b'GET /version HTTP/1.1\r\n')
    assert calls[1]['head'].startswith(b'POST /v1.47/networks/create HTTP/1.1\r\n')
    assert b'Content-Type: application/json\r\n' in calls[1]['head']
    assert b'Content-Length: ' + str(len(expected)).encode() + b'\r\n' in calls[1]['head']
    assert calls[1]['body'] == expected
    assert journal.get(binding.resource.resourceId) == before


def test_denied_gate_runs_after_version_and_sends_no_post(prepared):
    from larenor_server.plugins.network_effects import NetworkCreateError
    _, binding, intent, _ = prepared
    with create_server() as (endpoint, calls):
        with pytest.raises(NetworkCreateError, match='^network_create_not_authorized$'):
            creator(endpoint).create(binding, intent, before_dispatch=lambda: False)
    assert len(calls) == 1
