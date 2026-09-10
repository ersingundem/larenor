"""Synthetic Unix Engine streams only; no Docker daemon or real secret."""

from contextlib import contextmanager
import json
import os
from pathlib import Path
import socket
import tempfile
import threading

import pytest

from larenor_server.plugins.docker_probe import DockerEndpoint
from larenor_server.plugins.engine_stdin import (
    EngineStdinError,
    EngineStdinLimits,
    UnixEngineStdin,
)


CONTAINER = 'a' * 64
INPUT = b'private-config-fixture\n'
VERSION = {
    'MinAPIVersion': '1.24',
    'ApiVersion': '1.47',
    'Os': 'linux',
    'Arch': 'amd64',
}


def response(body, status=200, extra=b''):
    body = json.dumps(body, separators=(',', ':')).encode()
    return (f'HTTP/1.1 {status} test\r\nContent-Type: application/json\r\n'
            f'Content-Length: {len(body)}\r\n'.encode() + extra + b'\r\n' + body)


def frame(stream, body):
    return bytes((stream, 0, 0, 0)) + len(body).to_bytes(4, 'big') + body


@contextmanager
def engine(*, upgrade=None, output=None, peer=None):
    with tempfile.TemporaryDirectory(
        prefix='les-', dir='/private/tmp' if os.uname().sysname == 'Darwin' else '/tmp',
    ) as directory:
        path = Path(directory) / 'engine.sock'
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(path))
        path.chmod(0o600)
        listener.listen(1)
        listener.settimeout(0.1)
        stopped = threading.Event()
        calls, received, failures = [], [], []

        def read_headers(connection):
            data = bytearray()
            while not data.endswith(b'\r\n\r\n'):
                piece = connection.recv(1)
                if not piece:
                    return None
                data.extend(piece)
                assert len(data) <= 32768
            calls.append(bytes(data))
            return bytes(data)

        def serve():
            try:
                while not stopped.is_set():
                    try:
                        connection, _ = listener.accept()
                    except socket.timeout:
                        continue
                    with connection:
                        connection.settimeout(2)
                        if read_headers(connection) is None:
                            continue
                        connection.sendall(response(VERSION, extra=b'Connection: keep-alive\r\n'))
                        if read_headers(connection) is None:
                            continue
                        raw_upgrade = (b'HTTP/1.1 101 UPGRADED\r\n'
                            b'Connection: Upgrade\r\nUpgrade: tcp\r\n'
                            b'Content-Type: application/vnd.docker.raw-stream\r\n\r\n'
                            if upgrade is None else upgrade)
                        connection.sendall(raw_upgrade)
                        content = bytearray()
                        while True:
                            piece = connection.recv(4096)
                            if not piece:
                                break
                            content.extend(piece)
                        received.append(bytes(content))
                        payload = frame(1, b'{"state":"installed"}\n') if output is None else output
                        connection.sendall(payload)
            except (BrokenPipeError, ConnectionResetError):
                pass
            except Exception as error:
                if not stopped.is_set():
                    failures.append(error)

        worker = threading.Thread(target=serve, daemon=True)
        worker.start()
        client = UnixEngineStdin(
            DockerEndpoint(str(path), os.getuid()),
            peer_uid=peer or (lambda _: os.getuid()),
        )
        try:
            yield client, calls, received
        finally:
            stopped.set()
            listener.close()
            worker.join(8)
            assert not worker.is_alive()
            assert not failures


def exchange(client, **options):
    before_dispatch = options.pop('before_dispatch', lambda: True)
    return client.exchange(
        CONTAINER, INPUT, lambda stdout, stderr: (stdout, stderr),
        platform='linux/amd64', limits=EngineStdinLimits(2, 1, 4096, 8),
        before_dispatch=before_dispatch, **options,
    )


def test_exact_version_and_attach_share_one_verified_connection():
    with engine() as (client, calls, received):
        assert exchange(client) == (b'{"state":"installed"}\n', b'')
    assert len(calls) == 2
    assert calls[0].startswith(b'GET /version HTTP/1.1\r\n')
    assert calls[1].startswith(
        f'POST /v1.47/containers/{CONTAINER}/attach?stream=1&stdin=1&stdout=1&stderr=1 '
        'HTTP/1.1\r\n'.encode())
    assert b'Connection: Upgrade\r\n' in calls[1]
    assert b'Upgrade: tcp\r\n' in calls[1]
    assert INPUT not in b''.join(calls)
    assert received == [INPUT]


def test_stdout_and_stderr_frames_are_bounded_and_kept_separate():
    output = frame(1, b'one') + frame(2, b'two') + frame(1, b'three')
    with engine(output=output) as (client, _calls, _received):
        assert exchange(client) == (b'onethree', b'two')


@pytest.mark.parametrize('change', [
    {'container_id': 'short'}, {'container_id': '../' + CONTAINER},
    {'container_id': True}, {'input_bytes': b''}, {'input_bytes': b'x' * 4097},
    {'input_bytes': 'secret'}, {'platform': 'linux/s390x'},
    {'consume': None}, {'before_dispatch': None},
])
def test_invalid_inputs_never_connect_or_expose_bytes(change):
    client = UnixEngineStdin(
        DockerEndpoint('/tmp/never-larenor-engine.sock', os.getuid()),
        peer_uid=lambda _: os.getuid())
    values = dict(container_id=CONTAINER, input_bytes=INPUT,
                  consume=lambda *_: None, platform='linux/amd64',
                  limits=EngineStdinLimits(2, 1, 4096, 8),
                  before_dispatch=lambda: True)
    with pytest.raises(EngineStdinError, match='^engine_stdin_invalid$') as raised:
        client.exchange(**(values | change))
    assert INPUT.decode().strip() not in repr(raised.value)


def test_denied_gate_and_wrong_peer_send_no_attach_or_input():
    with engine() as (client, calls, received):
        with pytest.raises(EngineStdinError, match='^engine_stdin_dispatch_denied$'):
            exchange(client, before_dispatch=lambda: False)
    assert len(calls) == 1 and received == []
    with engine(peer=lambda _: os.getuid() + 1) as (client, calls, received):
        with pytest.raises(EngineStdinError, match='^engine_stdin_unavailable$'):
            exchange(client)
    assert calls == [] and received == []


def test_authority_loss_after_attach_still_sends_no_private_input():
    decisions = iter((True, False))
    with engine() as (client, calls, received):
        with pytest.raises(EngineStdinError, match='^engine_stdin_dispatch_denied$'):
            exchange(client, before_dispatch=lambda: next(decisions))
    assert len(calls) == 2
    # Linux may report the peer close while the fixture is entering recv, so
    # the synthetic server can observe either no completed read or one EOF.
    assert len(received) <= 1 and b''.join(received) == b''


@pytest.mark.parametrize('upgrade', [
    b'HTTP/1.1 200 OK\r\nContent-Type: application/vnd.docker.raw-stream\r\n\r\n',
    b'HTTP/1.1 101 UPGRADED\r\nConnection: close\r\nUpgrade: tcp\r\n\r\n',
    b'HTTP/1.1 101 UPGRADED\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n',
])
def test_invalid_upgrade_never_sends_private_input(upgrade):
    with engine(upgrade=upgrade) as (client, calls, received):
        with pytest.raises(
                EngineStdinError, match='^engine_stdin_attach_protocol$'):
            exchange(client)
    assert len(calls) == 2
    assert len(received) <= 1 and b''.join(received) == b''


@pytest.mark.parametrize('output', [
    bytes((3, 0, 0, 0, 0, 0, 0, 1)) + b'x',
    bytes((1, 1, 0, 0, 0, 0, 0, 1)) + b'x',
    bytes((1, 0, 0, 0, 0, 0, 16, 1)) + b'x' * 4097,
    bytes((1, 0, 0, 0, 0, 0, 0, 4)) + b'xx',
])
def test_invalid_multiplex_stream_fails_closed(output):
    with engine(output=output) as (client, _calls, received):
        with pytest.raises(
                EngineStdinError,
                match='^engine_stdin_(frames_protocol|response_limit)$'):
            exchange(client)
    assert received == [INPUT]


def test_cancellation_and_limits_are_exact_types():
    with pytest.raises(EngineStdinError, match='^engine_stdin_invalid_limits$'):
        EngineStdinLimits(True, 1, 4096, 8)
    with pytest.raises(EngineStdinError, match='^engine_stdin_invalid_limits$'):
        EngineStdinLimits(2, 1, 0, 8)
    cancelled = threading.Event()
    cancelled.set()
    client = UnixEngineStdin(
        DockerEndpoint('/tmp/never-larenor-engine.sock', os.getuid()),
        peer_uid=lambda _: os.getuid())
    with pytest.raises(EngineStdinError, match='^engine_stdin_cancelled$'):
        exchange(client, cancelled=cancelled)
