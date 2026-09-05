"""Private create transport: synthetic Unix server, never a real Docker daemon."""

from contextlib import contextmanager
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import threading
import time

import pytest

from larenor_server.plugins.docker_probe import DockerEndpoint
from larenor_server.plugins.network_resources import build_network_create_body
from larenor_server.plugins.network_effects import (
    NetworkCreateAcknowledgement, NetworkCreateError, NetworkCreateLimits, UnixNetworkCreator,
)
from larenor_server.plugins.network_resources import NetworkResourceError

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


@pytest.mark.parametrize('gate', [None, False, 1, 'true'])
def test_missing_callable_gate_never_opens_connection(prepared, gate):
    _, binding, intent, _ = prepared
    with create_server() as (endpoint, calls):
        with pytest.raises(NetworkCreateError, match='^network_create_not_authorized$'):
            creator(endpoint).create(binding, intent, before_dispatch=gate)
    assert calls == []


@pytest.mark.parametrize('answer', [None, False, 1, 'true', [], {'authorized': True}])
def test_gate_requires_literal_true_after_handshake(prepared, answer):
    _, binding, intent, _ = prepared
    with create_server() as (endpoint, calls):
        with pytest.raises(NetworkCreateError, match='^network_create_not_authorized$'):
            creator(endpoint).create(binding, intent, before_dispatch=lambda: answer)
    assert len(calls) == 1


def test_throwing_gate_has_static_error_and_no_effect(prepared):
    _, binding, intent, _ = prepared
    def gate():
        raise RuntimeError('secret token and /operator/socket')
    with create_server() as (endpoint, calls):
        with pytest.raises(NetworkCreateError, match='^network_create_not_authorized$') as caught:
            creator(endpoint).create(binding, intent, before_dispatch=gate)
    assert len(calls) == 1 and 'secret' not in repr(caught.value)


@pytest.mark.parametrize('version,code', [
    ({**VERSION, 'ApiVersion': '1.46'}, 'network_create_api_unsupported'),
    ({**VERSION, 'MinAPIVersion': '1.48'}, 'network_create_api_unsupported'),
    ({**VERSION, 'Arch': 'arm64'}, 'network_create_api_unsupported'),
    ({**VERSION, 'Os': 'windows'}, 'network_create_api_unsupported'),
])
def test_incompatible_daemon_never_calls_authority_or_effect(prepared, version, code):
    _, binding, intent, _ = prepared
    gates = []
    with create_server(version=response(version)) as (endpoint, calls):
        with pytest.raises(NetworkCreateError, match='^' + code + '$'):
            creator(endpoint).create(binding, intent, before_dispatch=lambda: gates.append(True))
    assert len(calls) == 1 and gates == []


def test_wrong_peer_sends_no_http_or_authority(prepared):
    _, binding, intent, _ = prepared
    gates = []
    with create_server() as (endpoint, calls):
        with pytest.raises(NetworkCreateError, match='^network_create_unavailable$'):
            UnixNetworkCreator(endpoint, peer_uid=lambda _: os.getuid() + 1).create(
                binding, intent, before_dispatch=lambda: gates.append(True))
    assert calls == [] and gates == []


@pytest.mark.parametrize('when', ['before', 'handshake', 'gate', 'response'])
def test_cancellation_never_returns_ack_and_pre_send_cancel_sends_no_post(prepared, when):
    _, binding, intent, _ = prepared
    cancelled = threading.Event()
    if when == 'before':
        cancelled.set()
    def version(connection):
        if when == 'handshake':
            cancelled.set()
        connection.sendall(response(VERSION))
    def gate():
        if when == 'gate':
            cancelled.set()
        return True
    def reply(connection):
        if when == 'response':
            cancelled.set()
        connection.sendall(ack_response())
    with create_server(version=version, reply=reply) as (endpoint, calls):
        with pytest.raises(NetworkCreateError, match='^network_create_cancelled$'):
            creator(endpoint).create(binding, intent, before_dispatch=gate, cancelled=cancelled)
    assert len(calls) == {'before': 0, 'handshake': 1, 'gate': 1, 'response': 2}[when]


def test_expired_deadline_inside_trusted_gate_never_sends_post(prepared):
    _, binding, intent, _ = prepared
    def gate():
        time.sleep(0.15)
        return True
    with create_server() as (endpoint, calls):
        started = time.monotonic()
        with pytest.raises(NetworkCreateError, match='^network_create_timeout$'):
            creator(endpoint, limits=NetworkCreateLimits(0.1, 0.1)).create(
                binding, intent, before_dispatch=gate)
    assert len(calls) == 1 and time.monotonic() - started < 1


@pytest.mark.parametrize('field', ['ownership_nonce', 'specification_digest', 'resource'])
@pytest.mark.parametrize('when', ['handshake', 'gate', 'response'])
def test_intent_changes_are_revalidated_around_gate_and_after_body(prepared, field, when):
    _, binding, intent, _ = prepared
    gates = []
    def change():
        value = {'ownership_nonce': 'f' * 32, 'specification_digest': 'f' * 64,
                 'resource': binding.resource.model_copy(update={'internal': False})}[field]
        object.__setattr__(intent, field, value)
    def version(connection):
        if when == 'handshake':
            change()
        connection.sendall(response(VERSION))
    def gate():
        gates.append(True)
        if when == 'gate':
            change()
        return True
    def reply(connection):
        if when == 'response':
            change()
        connection.sendall(ack_response())
    with create_server(version=version, reply=reply) as (endpoint, calls):
        with pytest.raises((NetworkCreateError, NetworkResourceError)):
            creator(endpoint).create(binding, intent, before_dispatch=gate)
    assert len(calls) == (2 if when == 'response' else 1)
    assert len(gates) == (0 if when == 'handshake' else 1)


@pytest.mark.parametrize('when', ['before', 'handshake', 'gate', 'response'])
def test_bound_plan_snapshot_tampering_never_returns_success(prepared, when):
    _, binding, intent, _ = prepared
    def change():
        object.__setattr__(binding.source[0], 'workerPolicyVersion', True)
    if when == 'before':
        change()
    def version(connection):
        if when == 'handshake':
            change()
        connection.sendall(response(VERSION))
    def gate():
        if when == 'gate':
            change()
        return True
    def reply(connection):
        if when == 'response':
            change()
        connection.sendall(ack_response())
    with create_server(version=version, reply=reply) as (endpoint, calls):
        with pytest.raises((NetworkCreateError, NetworkResourceError)):
            creator(endpoint).create(binding, intent, before_dispatch=gate)
    assert len(calls) == {'before': 0, 'handshake': 1, 'gate': 1, 'response': 2}[when]


def test_uncertain_intent_cannot_create_even_with_literal_true_gate(prepared):
    _, binding, intent, journal = prepared
    receipt = journal.mark_uncertain(binding.resource.resourceId, intent.receipt.revision)
    object.__setattr__(intent, 'receipt', receipt)
    with create_server() as (endpoint, calls):
        with pytest.raises(NetworkResourceError, match='^invalid_network_binding$'):
            creator(endpoint).create(binding, intent, before_dispatch=lambda: True)
    assert calls == [] and journal.get(binding.resource.resourceId) == receipt


def test_journal_reentry_changes_intent_receipt_inside_gate_and_prevents_post(prepared):
    _, binding, intent, journal = prepared
    def gate():
        receipt = journal.mark_uncertain(binding.resource.resourceId, intent.receipt.revision)
        object.__setattr__(intent, 'receipt', receipt)
        return True
    with create_server() as (endpoint, calls):
        with pytest.raises(NetworkCreateError, match='^network_create_not_authorized$'):
            creator(endpoint).create(binding, intent, before_dispatch=gate)
    assert len(calls) == 1 and journal.get(binding.resource.resourceId).state == 'uncertain'


@pytest.mark.parametrize('status', [200, 202, 204, 206, 301, 307, 400, 403, 404, 409, 500])
def test_only_created_status_is_acknowledgement_without_retry_or_redirect(prepared, status):
    _, binding, intent, journal = prepared
    before = journal.get(binding.resource.resourceId)
    with create_server(reply=response(b'private daemon body', status=status,
                                      extra=b'Location: http://private.example/token\r\n')) as (endpoint, calls):
        with pytest.raises(NetworkCreateError, match='^network_create_failed$'):
            creator(endpoint).create(binding, intent, before_dispatch=lambda: True)
    assert len(calls) == 2 and journal.get(binding.resource.resourceId) == before


@pytest.mark.parametrize('body', [
    b'{}', b'[]', b'null', b'truncated', b'\xff', b'{"Id":"1","Id":"2","Warning":""}',
    {'Id': '1' * 64}, {'Warning': ''}, {**ACK, 'Warnings': []},
    {**ACK, 'Warning': None}, {**ACK, 'Warning': []}, {**ACK, 'Warning': 0},
    {**ACK, 'Id': None}, {**ACK, 'Id': True}, {**ACK, 'Id': '1' * 63}, {**ACK, 'Id': 'A' * 64},
])
def test_acknowledgement_is_exact_bounded_typed_record(prepared, body):
    _, binding, intent, _ = prepared
    with create_server(reply=ack_response(body)) as (endpoint, calls):
        with pytest.raises(NetworkCreateError, match='^network_create_protocol$'):
            creator(endpoint).create(binding, intent, before_dispatch=lambda: True)
    assert len(calls) == 2


def test_warning_is_failure_and_never_leaks_daemon_text(prepared):
    _, binding, intent, _ = prepared
    with create_server(reply=ack_response({**ACK, 'Warning': 'secret operator path'})) as (endpoint, _):
        with pytest.raises(NetworkCreateError, match='^network_create_warning$') as caught:
            creator(endpoint).create(binding, intent, before_dispatch=lambda: True)
    assert 'secret' not in repr(caught.value)


@pytest.mark.parametrize('extra', [b'Content-Range: bytes 0-4/99\r\n', b'Link: </secret>; rel=next\r\n',
    b'Content-Encoding: gzip\r\n', b'Content-Length: 100\r\n'])
def test_ambiguous_partial_or_encoded_acknowledgement_is_rejected(prepared, extra):
    _, binding, intent, _ = prepared
    with create_server(reply=response(ACK, status=201, extra=extra)) as (endpoint, _):
        with pytest.raises(NetworkCreateError, match='^network_create_protocol$'):
            creator(endpoint).create(binding, intent, before_dispatch=lambda: True)


@pytest.mark.parametrize('reply,code', [
    (ack_response(b' ' * 4097), 'network_create_response_limit'),
    (ack_response(b' ' * 4097, chunked=True), 'network_create_response_limit'),
    (b'HTTP/1.1 201 OK\r\nContent-Type: application/json\r\n\r\n' + json.dumps(ACK).encode(), 'network_create_protocol'),
    (b'HTTP/1.1 201 OK\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{}', 'network_create_protocol'),
    (b'HTTP/1.1 201 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n2;x=y\r\n{}\r\n0\r\n\r\n', 'network_create_protocol'),
    (b'HTTP/1.1 201 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\nX: secret\r\n\r\n', 'network_create_protocol'),
])
def test_strict_create_framing_excludes_image_pull_eof_exception(prepared, reply, code):
    _, binding, intent, _ = prepared
    with create_server(reply=reply) as (endpoint, calls):
        with pytest.raises(NetworkCreateError, match='^' + code + '$'):
            creator(endpoint).create(binding, intent, before_dispatch=lambda: True)
    assert len(calls) == 2


def test_chunk_count_is_bounded_even_for_small_acknowledgement(prepared):
    _, binding, intent, _ = prepared
    raw = json.dumps(ACK).encode()
    reply = (b'HTTP/1.1 201 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n'
             + b''.join(b'1\r\n' + bytes([byte]) + b'\r\n' for byte in raw) + b'0\r\n\r\n')
    with create_server(reply=reply) as (endpoint, _):
        with pytest.raises(NetworkCreateError, match='^network_create_response_limit$'):
            creator(endpoint, limits=NetworkCreateLimits(max_chunks=2)).create(
                binding, intent, before_dispatch=lambda: True)


@pytest.mark.parametrize('field,value', [
    ('total_seconds', True), ('total_seconds', 0), ('total_seconds', 10.1),
    ('total_seconds', float('nan')), ('total_seconds', float('inf')),
    ('idle_seconds', True), ('idle_seconds', 0), ('idle_seconds', 2.1),
    ('max_chunks', True), ('max_chunks', 1.0), ('max_chunks', 0), ('max_chunks', 129),
])
def test_create_limits_cannot_widen_private_caps_or_normalize_types(field, value):
    with pytest.raises(NetworkCreateError, match='^invalid_network_create_limits$'):
        NetworkCreateLimits(**{field: value})


@pytest.mark.parametrize('forged', ['limit_value', 'limit_extra', 'limit_type', 'endpoint'])
def test_forged_creator_configuration_revalidated_before_socket_io(prepared, forged):
    _, binding, intent, _ = prepared
    with create_server() as (endpoint, calls):
        client = creator(endpoint)
        if forged == 'limit_value':
            object.__setattr__(client._limits, 'total_seconds', True)
        elif forged == 'limit_extra':
            object.__setattr__(client._limits, 'extra', 'secret')
        elif forged == 'limit_type':
            client._limits = {'total_seconds': 10}
        else:
            object.__setattr__(client._http._endpoint, 'path', 'relative')
        with pytest.raises(NetworkCreateError, match='^invalid_network_(create_limits|binding)$'):
            client.create(binding, intent, before_dispatch=lambda: True)
    assert calls == []


def test_closed_socket_and_constructor_errors_are_static(prepared):
    _, binding, intent, _ = prepared
    with tempfile.TemporaryDirectory(prefix='lne-', dir='/private/tmp' if sys.platform == 'darwin' else '/tmp') as folder:
        with pytest.raises(NetworkCreateError, match='^network_create_unavailable$'):
            creator(DockerEndpoint(str(Path(folder) / 'absent.sock'), os.getuid())).create(
                binding, intent, before_dispatch=lambda: True)
    with pytest.raises(NetworkCreateError, match='^invalid_network_binding$'):
        UnixNetworkCreator(object())
    assert str(NetworkCreateError('private secret')) == 'network_create_unavailable'


@pytest.mark.parametrize('when', ['gate', 'response'])
def test_socket_replacement_after_version_is_not_accepted(prepared, when):
    _, binding, intent, _ = prepared
    def change():
        path = Path(endpoint.path)
        path.unlink()
        path.write_text('foreign object', encoding='utf-8')
        path.chmod(0o600)
    def gate():
        if when == 'gate':
            change()
        return True
    def reply(connection):
        if when == 'response':
            change()
        connection.sendall(ack_response())
    with create_server(reply=reply) as (endpoint, calls):
        with pytest.raises(NetworkCreateError, match='^network_create_unavailable$'):
            creator(endpoint).create(binding, intent, before_dispatch=gate)
    assert len(calls) == (1 if when == 'gate' else 2)


def test_idle_deadline_after_post_preserves_mutating_receipt_for_future_reconciliation(prepared):
    _, binding, intent, journal = prepared
    before = journal.get(binding.resource.resourceId)
    closed = threading.Event()
    def reply(connection):
        # No bytes: EOF proves our client closed after its idle budget.
        if connection.recv(1) == b'':
            closed.set()
    with create_server(reply=reply) as (endpoint, calls):
        started = time.monotonic()
        with pytest.raises(NetworkCreateError, match='^network_create_timeout$'):
            creator(endpoint, limits=NetworkCreateLimits(1, 0.1)).create(
                binding, intent, before_dispatch=lambda: True)
        assert closed.wait(1)
    assert time.monotonic() - started < 2 and len(calls) == 2
    assert journal.get(binding.resource.resourceId) == before


def test_proxy_environment_and_docker_host_do_not_change_fixed_unix_target(prepared, monkeypatch):
    _, binding, intent, _ = prepared
    for name in ('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'DOCKER_HOST', 'DOCKER_TLS_VERIFY'):
        monkeypatch.setenv(name, 'http://127.0.0.1:1/never')
    with create_server() as (endpoint, calls):
        assert creator(endpoint).create(binding, intent, before_dispatch=lambda: True).network_id == ACK['Id']
    assert len(calls) == 2 and b'Host: localhost\r\n' in calls[1]['head']


@pytest.mark.skipif(sys.platform != 'linux', reason='Production SO_PEERCRED needs Linux')
def test_real_linux_peer_for_create_uses_synthetic_socket_only(prepared):
    _, binding, intent, _ = prepared
    with create_server() as (endpoint, calls):
        result = UnixNetworkCreator(endpoint).create(binding, intent, before_dispatch=lambda: True)
    assert result == NetworkCreateAcknowledgement(ACK['Id']) and len(calls) == 2
