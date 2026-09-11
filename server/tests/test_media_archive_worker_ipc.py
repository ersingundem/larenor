from contextlib import contextmanager
import os
from pathlib import Path
import socket
import struct
import time

import pytest

from larenor_server.plugins.media_archive_core_models import (
    PrivateMediaArchiveCollection,
)
from larenor_server.plugins.media_archive_worker_ipc import (
    MediaArchiveWorkerClient,
    MediaArchiveWorkerError,
    MediaArchiveWorkerServer,
    read_frame,
)
from test_media_archive_core_read import authority
from test_media_archive_ingestion import ingested


class Collector:
    def __init__(self, result=None):
        self.result = result or ingested()
        self.calls = []
        self.lifecycle = []

    def open(self, deadline):
        assert time.monotonic() < deadline
        self.lifecycle.append('open')

    def collect(self, private, *, deadline, gate):
        assert gate() is True and time.monotonic() < deadline
        self.calls.append(private)
        return self.result

    def close(self):
        self.lifecycle.append('close')


def private(request_id='a' * 32):
    return PrivateMediaArchiveCollection(
        requestId=request_id, authority=authority())


@contextmanager
def running(tmp_path, collector=None):
    path = tmp_path / 'archive.sock'
    selected = collector if collector is not None else Collector()
    server = MediaArchiveWorkerServer(
        path, selected, allowed_uid=os.getuid(),
        peer_uid=lambda _connection: os.getuid(), timeout=.5)
    server.start()
    try:
        yield selected, server, MediaArchiveWorkerClient(
            path, owner_uid=os.getuid(),
            peer_uid=lambda _connection: os.getuid(), timeout=.5)
    finally:
        server.close()


def test_uid_private_roundtrip_carries_exact_authority_and_safe_observation(tmp_path):
    with running(tmp_path) as (collector, _server, client):
        assert client.status() == {
            'state': 'ready', 'readAvailable': True,
            'mutationAvailable': False,
        }
        result = client.read_media_archive(
            private(), deadline=time.monotonic() + .5, gate=lambda: True)
    assert result == ingested()
    assert len(collector.calls) == 1
    assert collector.calls[0].authority == authority()
    assert collector.lifecycle == ['open', 'close']
    assert 'credential' not in repr(collector.calls[0]).lower()


def test_default_runtime_is_supervised_but_read_effect_is_unavailable(tmp_path):
    path = tmp_path / 'archive.sock'
    server = MediaArchiveWorkerServer(
        path, None, allowed_uid=os.getuid(),
        peer_uid=lambda _connection: os.getuid(), timeout=.5)
    server.start()
    try:
        client = MediaArchiveWorkerClient(
            path, owner_uid=os.getuid(),
            peer_uid=lambda _connection: os.getuid(), timeout=.5)
        assert client.status() == {
            'state': 'unavailable', 'readAvailable': False,
            'mutationAvailable': False,
        }
        with pytest.raises(MediaArchiveWorkerError, match='worker_unavailable'):
            client.read_media_archive(
                private(), deadline=time.monotonic() + .5, gate=lambda: True)
    finally:
        server.close()
    assert not path.exists()


def test_replay_is_consumed_once_even_when_read_only(tmp_path):
    with running(tmp_path) as (collector, _server, client):
        request = private()
        client.read_media_archive(
            request, deadline=time.monotonic() + .5, gate=lambda: True)
        with pytest.raises(MediaArchiveWorkerError, match='replay_rejected'):
            client.read_media_archive(
                request, deadline=time.monotonic() + .5, gate=lambda: True)
    assert len(collector.calls) == 1


@pytest.mark.parametrize('uid_side', ['client_owner', 'server_peer'])
def test_wrong_uid_never_reaches_collector(tmp_path, uid_side):
    path = tmp_path / 'archive.sock'
    collector = Collector()
    server = MediaArchiveWorkerServer(
        path, collector, allowed_uid=os.getuid(),
        peer_uid=(lambda _connection: os.getuid() + 1)
        if uid_side == 'server_peer' else (lambda _connection: os.getuid()),
        timeout=.5)
    server.start()
    try:
        client = MediaArchiveWorkerClient(
            path,
            owner_uid=os.getuid() + 1
            if uid_side == 'client_owner' else os.getuid(),
            peer_uid=lambda _connection: os.getuid(), timeout=.5)
        with pytest.raises(MediaArchiveWorkerError, match='worker_unavailable'):
            client.read_media_archive(
                private(), deadline=time.monotonic() + .5, gate=lambda: True)
    finally:
        server.close()
    assert collector.calls == []


def test_partial_oversize_and_expired_frames_fail_closed_without_payload_echo():
    left, right = socket.socketpair()
    try:
        left.sendall(struct.pack('!I', 9) + b'{"token"')
        left.shutdown(socket.SHUT_WR)
        with pytest.raises(MediaArchiveWorkerError) as partial:
            read_frame(right, time.monotonic() + .2)
        assert 'token' not in repr(partial.value)
    finally:
        left.close()
        right.close()

    left, right = socket.socketpair()
    try:
        left.sendall(struct.pack('!I', 8 * 1024 * 1024 + 1))
        with pytest.raises(MediaArchiveWorkerError, match='invalid_frame'):
            read_frame(right, time.monotonic() + .2)
        with pytest.raises(MediaArchiveWorkerError, match='deadline_exceeded'):
            read_frame(right, time.monotonic() - 1)
    finally:
        left.close()
        right.close()


@pytest.mark.parametrize('gate', [
    lambda: False,
    lambda: (_ for _ in ()).throw(RuntimeError('private cancellation')),
])
def test_cancelled_gate_opens_no_socket_and_has_no_retry(tmp_path, gate):
    with running(tmp_path) as (collector, _server, client):
        with pytest.raises(MediaArchiveWorkerError, match='cancelled'):
            client.read_media_archive(
                private(), deadline=time.monotonic() + .5, gate=gate)
    assert collector.calls == []


def test_invalid_operation_and_secret_fields_are_rejected_without_collector(tmp_path):
    with running(tmp_path) as (collector, server, _client):
        response = server.answer({
            'protocol': 1, 'requestId': 'f' * 32,
            'operation': 'delete', 'token': 'private-secret',
        }, deadline=time.monotonic() + .5)
    assert response == {
        'protocol': 1, 'requestId': 'f' * 32,
        'error': 'invalid_request',
    }
    assert collector.calls == []
    assert 'private-secret' not in repr(response)
