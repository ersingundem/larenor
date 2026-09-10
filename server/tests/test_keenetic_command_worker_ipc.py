"""Private Keenetic command IPC without a router transport implementation."""

from contextlib import contextmanager
import os
from pathlib import Path
import socket
import struct
import tempfile
import threading
import time

import pytest
from pydantic import ValidationError

from larenor_server.keenetic_commands.service import (
    KeeneticCommandAuthority, KeeneticEffectError,
)
from larenor_server.keenetic_commands.worker_ipc import (
    KeeneticCommandWorkerClient, KeeneticCommandWorkerServer,
)
from larenor_server.keenetic_commands.worker_models import (
    KeeneticWorkerCommand, KeeneticWorkerResult, preview_receipt,
)
from larenor_server.plugins.preflight_ipc import (
    MAX_PACKET, PreflightIPCError, read_packet, write_packet,
)

from conftest import auth, ready
from test_keenetic_command_authority import Actor, Harness, authority, request, state
from test_keenetic_command_http_journal import scoped_request


@contextmanager
def socket_directory():
    with tempfile.TemporaryDirectory(prefix='lnr-k-', dir='/tmp') as raw:
        directory = Path(raw).resolve()
        directory.chmod(0o700)
        yield directory


def worker_command(action='guest_wifi_enable', current=None, timeout_ms=500):
    return KeeneticWorkerCommand.from_request(
        request(action, current=current), timeout_ms=timeout_ms)


def resulting(command):
    values = {
        'guest_wifi_enable': 'enabled',
        'guest_wifi_disable': 'disabled',
        'client_internet_pause': 'paused',
        'client_internet_resume': 'allowed',
        'wan_reconnect': 'online',
    }
    return command.target.model_copy(update={
        'stateRevision': command.target.stateRevision + 1,
        'value': values[command.action],
    })


class Handler:
    def __init__(self, error=None):
        self.calls = []
        self.error = error

    def execute(self, command, *, deadline, cancelled):
        assert time.monotonic() < deadline and cancelled() is False
        self.calls.append(command)
        if self.error is not None:
            raise self.error
        return KeeneticWorkerResult.for_command(command, {
            'schemaVersion': 1, 'requestId': command.requestId,
            'action': command.action, 'target': command.target,
            'previewReceipt': command.previewReceipt,
            'status': 'succeeded', 'code': 'keenetic_effect_succeeded',
            'observedState': resulting(command),
        })


def packet(command, packet_id='f' * 32, operation='keenetic_command_execute'):
    return {
        'protocol': 1, 'requestId': packet_id, 'operation': operation,
        'command': command.model_dump(mode='json'),
    }


def exchange(path, body):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.connect(str(path))
        deadline = time.monotonic() + 1
        write_packet(connection, body, deadline)
        return read_packet(connection, deadline)


def test_wire_models_bind_exact_revision_and_exclude_secrets_and_reason():
    body = request()
    command = KeeneticWorkerCommand.from_request(body, timeout_ms=500)
    wire = command.model_dump(mode='json')
    assert wire['previewReceipt'] == preview_receipt(body)
    assert set(wire) == {
        'schemaVersion', 'requestId', 'action', 'target',
        'expectedUserRevision', 'previewReceipt', 'timeoutMs',
    }
    assert body.idempotencyKey not in str(wire)
    assert body.reason not in str(wire)
    with pytest.raises(ValidationError):
        KeeneticWorkerCommand.model_validate(wire | {'token': 'private-secret'})


def test_result_rejects_wrong_receipt_revision_and_observation():
    command = worker_command()
    good = {
        'schemaVersion': 1, 'requestId': command.requestId,
        'action': command.action, 'target': command.target.model_dump(),
        'previewReceipt': command.previewReceipt, 'status': 'succeeded',
        'code': 'keenetic_effect_succeeded',
        'observedState': resulting(command).model_dump(),
    }
    KeeneticWorkerResult.for_command(command, good)
    for change in (
        {'previewReceipt': '0' * 64},
        {'target': command.target.model_copy(
            update={'serviceRevision': 7}).model_dump()},
        {'observedState': command.target.model_dump()},
    ):
        with pytest.raises((ValidationError, KeeneticEffectError)):
            KeeneticWorkerResult.for_command(command, good | change)


def test_owned_worker_round_trip_is_single_dispatch_and_uid_checked():
    handler = Handler()
    with socket_directory() as directory:
        path = directory / 'keenetic.sock'
        worker = KeeneticCommandWorkerServer(
            path, handler, allowed_uid=os.getuid(),
            peer_uid=lambda _connection: os.getuid(), timeout=.5)
        worker.start()
        try:
            client = KeeneticCommandWorkerClient(
                path, owner_uid=os.getuid(),
                peer_uid=lambda _connection: os.getuid(), timeout=.5)
            command = worker_command()
            assert client.execute(command, guard=lambda: None) == resulting(command)
            assert handler.calls == [command]
            assert path.stat().st_mode & 0o777 == 0o600
        finally:
            worker.close()
        assert not path.exists()


def test_client_rejects_wrong_worker_uid_before_sending():
    handler = Handler()
    with socket_directory() as directory:
        worker = KeeneticCommandWorkerServer(
            directory / 'keenetic.sock', handler,
            allowed_uid=os.getuid(),
            peer_uid=lambda _connection: os.getuid(), timeout=.5)
        worker.start()
        try:
            client = KeeneticCommandWorkerClient(
                worker.path, owner_uid=os.getuid(),
                peer_uid=lambda _connection: os.getuid() + 1, timeout=.5)
            with pytest.raises(
                    KeeneticEffectError,
                    match='^keenetic_effect_unavailable$') as caught:
                client.execute(worker_command(), guard=lambda: None)
            assert caught.value.uncertain is False
            assert handler.calls == []
        finally:
            worker.close()


def test_server_rejects_wrong_client_uid_before_read_or_dispatch():
    handler = Handler()
    with socket_directory() as directory:
        worker = KeeneticCommandWorkerServer(
            directory / 'keenetic.sock', handler,
            allowed_uid=os.getuid(),
            peer_uid=lambda _connection: os.getuid() + 1, timeout=.2)
        worker.start()
        try:
            with pytest.raises((OSError, PreflightIPCError)):
                exchange(worker.path, packet(worker_command()))
            assert handler.calls == []
        finally:
            worker.close()


def test_disconnect_after_dispatch_is_unknown_and_never_retried():
    calls = []

    def drop_once(listener):
        connection, _ = listener.accept()
        with connection:
            calls.append(read_packet(connection, time.monotonic() + 1))
        listener.close()

    with socket_directory() as directory:
        path = directory / 'keenetic.sock'
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(path))
        os.chmod(path, 0o600)
        listener.listen(1)
        thread = threading.Thread(target=drop_once, args=(listener,), daemon=True)
        thread.start()
        client = KeeneticCommandWorkerClient(
            path, owner_uid=os.getuid(),
            peer_uid=lambda _connection: os.getuid(), timeout=.3)
        with pytest.raises(KeeneticEffectError) as caught:
            client.execute(worker_command(), guard=lambda: None)
        thread.join(1)
        assert caught.value.code == 'keenetic_effect_unknown'
        assert caught.value.uncertain is True
        assert len(calls) == 1


def test_partial_client_write_is_unknown_and_never_retried(monkeypatch):
    handler = Handler()
    calls = []

    def partial(_connection, _body, _deadline):
        calls.append('partial')
        raise PreflightIPCError('invalid_request')

    with socket_directory() as directory:
        worker = KeeneticCommandWorkerServer(
            directory / 'keenetic.sock', handler,
            allowed_uid=os.getuid(),
            peer_uid=lambda _connection: os.getuid(), timeout=.3)
        worker.start()
        try:
            monkeypatch.setattr(
                'larenor_server.keenetic_commands.worker_ipc.write_packet',
                partial)
            client = KeeneticCommandWorkerClient(
                worker.path, owner_uid=os.getuid(),
                peer_uid=lambda _connection: os.getuid(), timeout=.3)
            with pytest.raises(KeeneticEffectError) as caught:
                client.execute(worker_command(), guard=lambda: None)
            assert caught.value.uncertain is True
            assert calls == ['partial'] and handler.calls == []
        finally:
            worker.close()


@pytest.mark.parametrize('framing', ['missing', 'oversized'])
def test_incomplete_or_oversized_frame_never_dispatches(framing):
    handler = Handler()
    with socket_directory() as directory:
        worker = KeeneticCommandWorkerServer(
            directory / 'keenetic.sock', handler,
            allowed_uid=os.getuid(),
            peer_uid=lambda _connection: os.getuid(), timeout=.15)
        worker.start()
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.connect(str(worker.path))
                if framing == 'missing':
                    connection.sendall(struct.pack('!I', 20) + b'{')
                else:
                    connection.sendall(struct.pack('!I', MAX_PACKET + 1))
                connection.shutdown(socket.SHUT_WR)
                assert connection.recv(1) == b''
            assert handler.calls == []
        finally:
            worker.close()


def test_unknown_operation_and_replayed_packet_fail_closed():
    handler = Handler()
    command = worker_command()
    with socket_directory() as directory:
        worker = KeeneticCommandWorkerServer(
            directory / 'keenetic.sock', handler,
            allowed_uid=os.getuid(),
            peer_uid=lambda _connection: os.getuid(), timeout=.3)
        worker.start()
        try:
            unknown = exchange(
                worker.path, packet(command, packet_id='e' * 32,
                                    operation='router_raw_command'))
            assert unknown['error'] == 'invalid_request'
            first = exchange(worker.path, packet(command))
            assert 'result' in first
            replay = exchange(worker.path, packet(command))
            assert replay['error'] == 'invalid_request'
            assert handler.calls == [command]
        finally:
            worker.close()


def test_worker_timeout_is_unknown_after_single_dispatch():
    handler = Handler(KeeneticEffectError(
        'keenetic_effect_timeout', uncertain=True))
    with socket_directory() as directory:
        worker = KeeneticCommandWorkerServer(
            directory / 'keenetic.sock', handler,
            allowed_uid=os.getuid(),
            peer_uid=lambda _connection: os.getuid(), timeout=.3)
        worker.start()
        try:
            client = KeeneticCommandWorkerClient(
                worker.path, owner_uid=os.getuid(),
                peer_uid=lambda _connection: os.getuid(), timeout=.3)
            with pytest.raises(
                    KeeneticEffectError,
                    match='^keenetic_effect_timeout$') as caught:
                client.execute(worker_command(), guard=lambda: None)
            assert caught.value.uncertain is True
            assert len(handler.calls) == 1
        finally:
            worker.close()


def test_worker_result_is_persisted_in_current_integrity_journal(server):
    app, client, _, _ = server
    pair = ready(server)
    harness = Harness(state().model_copy(update={
        'coreId': app.state.core.context.coreId,
        'homeId': app.state.core.context.homeId,
    }))

    def actor_revision(actor):
        with app.state.core.db.connection() as connection:
            app.state.core.auth.assert_current(connection, actor)
            return connection.execute(
                'SELECT revision FROM users WHERE id=?',
                (actor.id,)).fetchone()['revision']

    handler = Handler()
    with socket_directory() as directory:
        worker = KeeneticCommandWorkerServer(
            directory / 'keenetic.sock', handler,
            allowed_uid=os.getuid(),
            peer_uid=lambda _connection: os.getuid(), timeout=.5)
        worker.start()
        try:
            effect = KeeneticCommandWorkerClient(
                worker.path, owner_uid=os.getuid(),
                peer_uid=lambda _connection: os.getuid(), timeout=.5)
            app.state.core.keenetic_commands = KeeneticCommandAuthority(
                authorize=harness.authorize, observe=harness.observe,
                effect=effect, journal=app.state.core.keenetic_command_journal,
                actor_revision=actor_revision,
                wall_clock=app.state.core.settings.clock)
            body = scoped_request(app)
            root = (
                f"/api/v1/admin/homes/{body['target']['coreId']}/"
                f"{body['target']['homeId']}/resources/"
                f"{body['target']['resourceId']}/keenetic/commands")
            preview = client.post(
                root + '/preview', headers=auth(pair), json=body).json()['preview']
            confirmed = client.post(
                root + f"/{preview['id']}/confirm", headers=auth(pair),
                json={'token': preview['confirmToken']})
            assert confirmed.json()['receipt']['status'] == 'succeeded'
            history = client.get(root + '/history', headers=auth(pair)).json()
            assert [event['status'] for event in history['events']] == [
                'accepted', 'executing', 'succeeded']
            assert history['verified'] is True
        finally:
            worker.close()
