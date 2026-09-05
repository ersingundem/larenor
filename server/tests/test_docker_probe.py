"""Docker compatibility is observed only through synthetic Unix sockets."""

from contextlib import contextmanager
from dataclasses import FrozenInstanceError
import json
import os
from pathlib import Path
import socket
import struct
import tempfile
import threading
import time
from types import SimpleNamespace

import pytest

from larenor_server.plugins.docker_probe import DockerEndpoint, DockerProbe
from larenor_server.plugins import docker_probe


VERSION = {'ApiVersion': '1.47', 'MinAPIVersion': '1.24', 'Os': 'linux', 'Arch': 'amd64'}


def response(body=None, *, status=200, headers=None):
    if body is None:
        body = json.dumps(VERSION).encode()
    fields = [('Content-Type', 'application/json'), ('Content-Length', str(len(body)))]
    if headers is not None:
        fields = headers
    return (f'HTTP/1.1 {status} Test\r\n'.encode()
            + b''.join(f'{key}: {value}\r\n'.encode() for key, value in fields)
            + b'\r\n' + body)


@contextmanager
def synthetic_engine(reply=None):
    """One bounded synthetic connection; never use a system Docker endpoint."""
    with tempfile.TemporaryDirectory(prefix='larenor-dp-', dir=str(Path('/tmp').resolve())) as directory:
        path = Path(directory) / 'engine.sock'
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(path))
        path.chmod(0o660)
        listener.listen(1)
        listener.settimeout(0.05)
        stopped = threading.Event()
        state = SimpleNamespace(path=path, requests=[], errors=[], connection=None)

        def serve():
            try:
                while True:
                    try:
                        connection, _ = listener.accept()
                        break
                    except TimeoutError:
                        if stopped.is_set():
                            return
                        continue
                state.connection = connection
                with connection:
                    connection.settimeout(0.5)
                    request = bytearray()
                    while len(request) < 8192 and not request.endswith(b'\r\n\r\n'):
                        data = connection.recv(1)
                        if not data:
                            break
                        request.extend(data)
                    state.requests.append(bytes(request))
                    if request:
                        if callable(reply):
                            reply(connection)
                        else:
                            connection.sendall(response() if reply is None else reply)
            except OSError:
                # A timed out/rejected probe deliberately closes the test peer.
                pass
            except BaseException as exc:
                state.errors.append(exc)

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        try:
            yield state
        finally:
            stopped.set()
            if state.connection is not None:
                try:
                    state.connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
            thread.join(1)
            listener.close()
            assert not thread.is_alive()
            assert not state.errors


def probe(engine, **kwargs):
    kwargs.setdefault('peer_uid', lambda connection: os.getuid())
    return DockerProbe(DockerEndpoint(str(engine.path), os.getuid()), **kwargs)


def test_endpoint_is_immutable_and_hides_the_operator_path():
    endpoint = DockerEndpoint('/run/private-docker.sock')
    assert endpoint.owner_uid == 0
    assert endpoint.path not in repr(endpoint)
    with pytest.raises(FrozenInstanceError):
        endpoint.path = '/elsewhere'


@pytest.mark.parametrize('path', [None, 3, b'/run/docker.sock', '', '/', 'relative.sock',
                                'unix:///run/docker.sock', '/run//docker.sock', '/run/./docker.sock',
                                '/run/../docker.sock', '/run/docker.sock/', '/run/a\\b',
                                '/run/a\x00b', '/run/a\nb', '/run/' + 'x' * 108])
def test_endpoint_rejects_noncanonical_or_unbounded_paths(path):
    with pytest.raises(ValueError, match='^invalid_docker_endpoint$'):
        DockerEndpoint(path)


@pytest.mark.parametrize('uid', [None, True, -1, 2**31, 1.5, '0'])
def test_endpoint_rejects_invalid_owner(uid):
    with pytest.raises(ValueError, match='^invalid_docker_endpoint$'):
        DockerEndpoint('/run/docker.sock', uid)


@pytest.mark.parametrize('timeout', [True, None, 0, -1, 2.01, float('inf'), float('nan'), '2'])
def test_deadline_configuration_cannot_exceed_two_seconds(timeout):
    with pytest.raises(ValueError, match='^invalid_docker_probe$'):
        DockerProbe(DockerEndpoint('/run/docker.sock'), timeout=timeout)


def test_bad_configuration_is_rejected_without_exposing_data():
    with pytest.raises(ValueError, match='^invalid_docker_probe$'):
        DockerProbe('/private/operator-secret.sock')
    instance = DockerProbe(DockerEndpoint('/nonexistent.sock'))
    with pytest.raises(ValueError, match='^invalid_platform$'):
        instance.inspect('linux/amd64?secret')


@pytest.mark.parametrize('architecture', ['amd64', 'arm64'])
def test_compatible_version_matches_platform_and_sends_only_fixed_read(architecture, monkeypatch):
    for name in ('DOCKER_HOST', 'DOCKER_API_VERSION', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY'):
        monkeypatch.setenv(name, 'tcp://must-not-contact.invalid:2375')
    body = dict(VERSION, Arch=architecture, Components=[{'Name': 'Engine', 'Version': '27.5.0'}],
                Platform={'Name': 'Docker Engine - Community'})
    with synthetic_engine(response(json.dumps(body).encode())) as engine:
        assert probe(engine).inspect('linux/' + architecture) == 'passed'
        assert engine.requests == [b'GET /version HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n'
                                   b'Accept-Encoding: identity\r\nAccept: application/json\r\n\r\n']


@pytest.mark.parametrize('changes,expected', [
    ({'ApiVersion': '1.47', 'MinAPIVersion': '1.47'}, 'passed'),
    ({'ApiVersion': '1.99'}, 'passed'),
    ({'ApiVersion': '1.46'}, 'failed'),
    ({'MinAPIVersion': '1.48', 'ApiVersion': '1.50'}, 'failed'),
    ({'Os': 'windows'}, 'failed'), ({'Arch': 'arm64'}, 'failed'), ({'Arch': '386'}, 'failed'),
    ({'MinAPIVersion': '1.48'}, 'unknown'), ({'ApiVersion': '01.47'}, 'unknown'),
    ({'ApiVersion': '1.47.0'}, 'unknown'), ({'ApiVersion': 1.47}, 'unknown'),
    ({'MinAPIVersion': None}, 'unknown'), ({'Os': None}, 'unknown'),
    ({'Os': 'linux\nsecret'}, 'unknown'), ({'Arch': {}}, 'unknown'),
])
def test_daemon_incompatibility_is_distinct_from_uncertain_protocol(changes, expected):
    with synthetic_engine(response(json.dumps(dict(VERSION, **changes)).encode())) as engine:
        assert probe(engine).inspect('linux/amd64') == expected


@pytest.mark.parametrize('body', [b'{}', b'[]', b'null', b'not-json', b'\xff',
                                b'{"ApiVersion":"1.47","ApiVersion":"1.47"}',
                                json.dumps(VERSION).encode() + b' extra',
                                b'{"extra":NaN}', b'{"extra":Infinity}',
                                b'{"extra":1e999}', b'[' * 1000 + b']' * 1000])
def test_invalid_or_ambiguous_json_never_produces_compatibility(body):
    with synthetic_engine(response(body)) as engine:
        assert probe(engine).inspect('linux/amd64') == 'unknown'


@pytest.mark.parametrize('status', [301, 307, 401, 403, 404, 500])
def test_http_errors_and_redirects_are_unknown_and_never_followed(status):
    with synthetic_engine(response(status=status, headers=[('Location', 'http://must-not-contact.invalid')])) as engine:
        assert probe(engine).inspect('linux/amd64') == 'unknown'
        assert len(engine.requests) == 1


@pytest.mark.parametrize('raw', [
    b'HTTP/1.1 200 OK\r\nContent-Length: 65537\r\n\r\n',
    b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}',
    b'HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 2\r\n\r\n{}',
    b'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n10001\r\n',
    b'HTTP/1.1 200 OK\r\nX-Huge: ' + b'x' * 33000 + b'\r\n\r\n',
    b'HTTP/1.1 200 OK\nContent-Length: 2\n\n{}',
    response(headers=[('Content-Type', 'application/json'), ('Content-Type', 'application/json')]),
    response(headers=[('Content-Type', 'text/html')]),
])
def test_response_framing_and_memory_are_bounded(raw):
    with synthetic_engine(raw) as engine:
        assert probe(engine).inspect('linux/amd64') == 'unknown'


@pytest.mark.parametrize('framing', ['chunked', 'eof'])
def test_valid_bounded_http_framing_is_supported(framing):
    body = json.dumps(VERSION).encode()
    headers = [('Content-Type', 'application/json')]
    if framing == 'chunked':
        headers.append(('Transfer-Encoding', 'chunked'))
        body = f'{len(body):x}\r\n'.encode() + body + b'\r\n0\r\n\r\n'
    with synthetic_engine(response(body, headers=headers)) as engine:
        assert probe(engine).inspect('linux/amd64') == 'passed'


def test_missing_and_closed_socket_are_unknown_without_retry():
    with synthetic_engine() as engine:
        path = engine.path
    instance = DockerProbe(DockerEndpoint(str(path), os.getuid()), peer_uid=lambda _: os.getuid())
    assert instance.inspect('linux/amd64') == 'unknown'
    with tempfile.TemporaryDirectory(dir=str(Path('/tmp').resolve())) as directory:
        path = Path(directory) / 'closed.sock'
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.bind(str(path))
        path.chmod(0o600)
        connection.close()
        assert DockerProbe(DockerEndpoint(str(path), os.getuid()), peer_uid=lambda _: os.getuid()).inspect('linux/amd64') == 'unknown'


@pytest.mark.parametrize('unsafe', ['file', 'directory', 'socket_symlink', 'ancestor_symlink',
                                  'world_readable', 'writable_parent', 'foreign_owner'])
def test_unsafe_socket_paths_are_rejected_before_connect(unsafe):
    with synthetic_engine() as engine:
        path = engine.path
        uid = os.getuid()
        if unsafe in {'file', 'directory', 'socket_symlink'}:
            path = path.with_name('other')
            if unsafe == 'file':
                path.write_text('private secret')
                path.chmod(0o600)
            elif unsafe == 'directory':
                path.mkdir(mode=0o700)
            else:
                path.symlink_to(engine.path)
        elif unsafe == 'ancestor_symlink':
            link = engine.path.parent / 'alias'
            link.symlink_to(engine.path.parent, target_is_directory=True)
            path = link / 'engine.sock'
        elif unsafe == 'world_readable':
            path.chmod(0o666)
        elif unsafe == 'writable_parent':
            path.parent.chmod(0o777)
        else:
            uid += 1
        def forbidden(*args):
            pytest.fail('unsafe endpoint attempted socket creation')
        assert DockerProbe(DockerEndpoint(str(path), uid), socket_factory=forbidden,
                           peer_uid=lambda _: uid).inspect('linux/amd64') == 'unknown'
        assert not engine.requests


def test_peer_uid_must_match_before_any_http_bytes_are_sent():
    with synthetic_engine() as engine:
        assert probe(engine, peer_uid=lambda _: os.getuid() + 1).inspect('linux/amd64') == 'unknown'
    assert engine.requests == [b'']


def test_unsupported_production_peer_check_does_not_connect(monkeypatch):
    monkeypatch.setattr(docker_probe.sys, 'platform', 'darwin')
    with synthetic_engine() as engine:
        def forbidden(*args):
            pytest.fail('unsupported peer verification attempted connection')
        assert DockerProbe(DockerEndpoint(str(engine.path), os.getuid()), socket_factory=forbidden).inspect('linux/amd64') == 'unknown'


def test_linux_peer_credentials_are_read_from_the_connected_socket(monkeypatch):
    monkeypatch.setattr(docker_probe.sys, 'platform', 'linux')
    monkeypatch.setattr(socket, 'SO_PEERCRED', 17, raising=False)
    class Peer:
        def getsockopt(self, level, option, length):
            assert (level, option, length) == (socket.SOL_SOCKET, 17, struct.calcsize('3i'))
            return struct.pack('3i', 123, 456, 789)
    assert docker_probe._linux_peer_uid(Peer()) == 456


@pytest.mark.parametrize('stage', ['connect', 'response'])
def test_socket_inode_replacement_invalidates_the_observation(stage):
    replacement = None
    with synthetic_engine() as engine:
        def replace_endpoint():
            nonlocal replacement
            engine.path.unlink()
            replacement = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            replacement.bind(str(engine.path))
            engine.path.chmod(0o660)
            replacement.listen(1)
        class Connection:
            def __init__(self, *args):
                self.inner = socket.socket(*args)
                self.received = 0
            def __getattr__(self, name):
                return getattr(self.inner, name)
            def connect(self, path):
                self.inner.connect(path)
                if stage == 'connect':
                    replace_endpoint()
            def recv(self, count):
                data = self.inner.recv(count)
                self.received += len(data)
                if stage == 'response' and self.received == len(response()):
                    replace_endpoint()
                return data
        try:
            assert probe(engine, socket_factory=Connection).inspect('linux/amd64') == 'unknown'
        finally:
            if replacement is not None:
                replacement.close()
    if stage == 'connect':
        assert engine.requests == [b'']


@pytest.mark.parametrize('stage', ['headers', 'body'])
def test_slow_drip_cannot_extend_the_overall_deadline(stage):
    def drip(connection):
        if stage == 'body':
            connection.sendall(b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n')
        for _ in range(30):
            connection.sendall(b'x')
            time.sleep(0.02)
    with synthetic_engine(drip) as engine:
        start = time.monotonic()
        assert probe(engine, timeout=0.08).inspect('linux/amd64') == 'unknown'
        assert time.monotonic() - start < 0.4


def test_transport_errors_are_sanitized_and_not_printed(capsys):
    with synthetic_engine() as engine:
        def broken(*args):
            raise OSError('operator-path token-secret')
        instance = probe(engine, socket_factory=broken)
        assert instance.inspect('linux/amd64') == 'unknown'
        assert engine.path.as_posix() not in repr(instance)
        assert capsys.readouterr() == ('', '')
