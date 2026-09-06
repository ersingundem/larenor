"""Synthetic Unix Engine protocol, never a live Docker endpoint."""
from contextlib import contextmanager
import importlib
import importlib.util
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import threading

import pytest

from larenor_server.plugins.docker_probe import DockerEndpoint
from larenor_server.plugins.engine_http import EngineHttpRequest, EngineHttpError
from larenor_server.plugins.resource_journal import _digest
from larenor_server.plugins.volume_create_journal import VolumeCreateJournal
from larenor_server.plugins.volume_resources import volume_expected_labels, VolumeObservation
from test_engine_http import VERSION, response
from test_volume_journal import inputs, observe
from test_volume_plan import source
from test_volume_resources import body


def api():
    name = 'larenor_server.plugins.volume_effects'
    assert importlib.util.find_spec(name) is not None, 'gated volume CREATE transport is absent'
    return importlib.import_module(name)


def labels_digest(intent):
    return _digest(volume_expected_labels(intent.binding))


@pytest.fixture
def begun(tmp_path, source):
    data = inputs(source)
    with VolumeCreateJournal(tmp_path / 'create', initialize=True) as j:
        with j.locked():
            rid = data['plan'].resources[0].resourceId
            j.prepare(**data, resource_id=rid)
            yield data, j, j.begin_create(rid, 1, **data)


@contextmanager
def engine_server(reply, *, platform='amd64', version_hook=None):
    """Read every request body and bound/reap the owned local server thread."""
    with tempfile.TemporaryDirectory(prefix='lvc-', dir='/private/tmp' if sys.platform == 'darwin' else '/tmp') as directory:
        path = Path(directory) / 'engine.sock'
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(path))
        path.chmod(0o600)
        listener.listen(4)
        listener.settimeout(.05)
        calls, failures = [], []
        stop = threading.Event()
        def read(connection):
            raw = bytearray()
            while not raw.endswith(b'\r\n\r\n'):
                part = connection.recv(1)
                if not part:
                    return None
                raw.extend(part)
                assert len(raw) <= 16384
            headers = bytes(raw)
            length = next((int(line.split(b':', 1)[1]) for line in headers.split(b'\r\n')
                           if line.lower().startswith(b'content-length:')), 0)
            assert length <= 4096
            content = bytearray()
            while len(content) < length:
                part = connection.recv(length - len(content))
                if not part:
                    return None
                content.extend(part)
            calls.append((headers.split(b'\r\n', 1)[0].decode(), bytes(content)))
            return calls[-1]
        def run():
            try:
                while not stop.is_set():
                    try:
                        connection, _ = listener.accept()
                    except socket.timeout:
                        continue
                    except OSError:
                        if stop.is_set():
                            return
                        raise
                    with connection:
                        connection.settimeout(2)
                        try:
                            first = read(connection)
                            if first is None:
                                continue
                            assert first == ('GET /version HTTP/1.1', b'')
                            if version_hook is not None:
                                version_hook()
                            connection.sendall(response({**VERSION, 'Arch': platform}))
                            request = read(connection)
                            if request is None:
                                continue
                            value = reply(request, calls) if callable(reply) else reply
                            if value is not None:
                                connection.sendall(value)
                        except (BrokenPipeError, ConnectionResetError):
                            # Either EOF or reset acknowledges the client closed its owned stream.
                            continue
            except Exception as error:
                if not stop.is_set():
                    failures.append(error)
        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        try:
            yield DockerEndpoint(str(path), os.getuid()), calls
        finally:
            stop.set()
            listener.close()
            thread.join(3)
            assert not thread.is_alive()
            assert failures == []


def creator(endpoint, **kwargs):
    return api().UnixVolumeCreator(endpoint, peer_uid=lambda _: os.getuid(), **kwargs)


def test_shared_http_admits_only_new_exact_closed_volume_create(begun):
    _, _, intent = begun
    data = {'Name': intent.binding.resource.name, 'Driver': 'local', 'DriverOpts': {},
            'Labels': volume_expected_labels(intent.binding)}
    raw = json.dumps(data, sort_keys=True, separators=(',', ':')).encode()
    selected = EngineHttpRequest('POST', '/v1.47/volumes/create',
        (('Accept', 'application/json'), ('Content-Type', 'application/json')), raw)
    assert selected.body == raw
    for changed in (dict(data, Driver='nfs'), dict(data, DriverOpts={'device': '/private'}),
                    dict(data, ClusterVolumeSpec={}), dict(data, Name='foreign')):
        with pytest.raises(EngineHttpError):
            EngineHttpRequest('POST', selected.target, selected.headers,
                json.dumps(changed, sort_keys=True, separators=(',', ':')).encode())


def test_create_is_one_post_after_same_stream_version_and_literal_gate(begun):
    module = api()
    _, _, intent = begun
    gates = []
    with engine_server(response(body(intent.binding), status=201)) as (endpoint, calls):
        result = creator(endpoint).create(intent, before_dispatch=lambda: gates.append(len(calls)) or True)
    assert gates == [1]
    assert [c[0] for c in calls] == ['GET /version HTTP/1.1', 'POST /v1.47/volumes/create HTTP/1.1']
    assert calls[1][1] == module.build_volume_create_body(intent)
    assert json.loads(calls[1][1]) == {'Name': intent.binding.resource.name, 'Driver': 'local',
        'DriverOpts': {}, 'Labels': volume_expected_labels(intent.binding)}
    assert type(result) is module.VolumeCreateAcknowledgement
    assert type(result) is not VolumeObservation
    assert result.labels_digest == labels_digest(intent)
    assert 'DO-NOT-EXPOSE' not in repr(result)


@pytest.mark.parametrize('choice', [None, False, 1, 'true', 'raise'])
def test_no_gate_or_nonliteral_permission_sends_no_post(begun, choice):
    module = api()
    _, _, intent = begun
    def gate():
        if choice == 'raise':
            raise RuntimeError('synthetic-private-token')
        return choice
    with engine_server(response(body(intent.binding), status=201)) as (endpoint, calls):
        with pytest.raises(module.VolumeEffectError):
            creator(endpoint).create(intent, before_dispatch=None if choice is None else gate)
    assert all(not line.startswith('POST ') for line, _ in calls)


@pytest.mark.parametrize('chunked', [False, True])
def test_missing_requires_complete_framed_fixed_route_response(begun, chunked):
    module = api()
    _, _, intent = begun
    raw = b'{"message":"synthetic no such volume"}'
    reply = (b'HTTP/1.1 404 missing\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n'
             + f'{len(raw):x}\r\n'.encode() + raw + b'\r\n0\r\n\r\n') if chunked else response(raw, status=404)
    with engine_server(reply) as (endpoint, calls):
        absent = creator(endpoint).probe(intent)
    assert type(absent) is module.VolumeAbsent
    assert absent.resource_id == intent.binding.resource_id and absent.labels_digest == labels_digest(intent)
    assert calls[-1][0] == 'GET /v1.47/volumes/' + intent.binding.resource.name + ' HTTP/1.1'


@pytest.mark.parametrize('reply', [
    response(b'{"message":"missing"}', status=503),
    response(b'{"message":"missing","extra":true}', status=404),
    response(b'{"message":"a","message":"b"}', status=404),
    response(b'{"message":"missing"}', status=404, extra=b'Content-Range: bytes 0-1/2\r\n'),
    b'HTTP/1.1 404 missing\r\nContent-Type: application/json\r\nContent-Length: 99\r\n\r\n{}',
    b'HTTP/1.1 404 missing\r\nContent-Type: application/json\r\n\r\n{"message":"missing"}',
])
def test_unavailable_malformed_or_partial_is_not_absence(begun, reply):
    module = api()
    _, _, intent = begun
    with engine_server(reply) as (endpoint, calls):
        with pytest.raises(Exception) as caught:
            creator(endpoint).probe(intent)
        assert getattr(caught.value, 'code', None) in {'volume_protocol', 'volume_engine_unavailable', 'volume_timeout'}
    assert len(calls) == 2


def test_post_gate_cancel_and_late_source_tamper_cannot_dispatch(begun):
    module = api()
    _, _, intent = begun
    cancelled = threading.Event()
    with engine_server(response(body(intent.binding), status=201)) as (endpoint, calls):
        def cancel():
            cancelled.set()
            return True
        with pytest.raises(module.VolumeEffectError):
            creator(endpoint).create(intent, before_dispatch=cancel, cancelled=cancelled)
    assert len(calls) == 1
    with engine_server(response(body(intent.binding), status=201)) as (endpoint, calls):
        def change():
            object.__setattr__(intent, 'specification_digest', 'e' * 64)
            return True
        with pytest.raises(Exception):
            creator(endpoint).create(intent, before_dispatch=change)
    assert len(calls) == 1
