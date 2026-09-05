"""Real private Unix sockets and synthetic observations; no Docker/home access."""
from contextlib import contextmanager
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import socket
import struct
import tempfile
import threading
import time

import pytest

from larenor_server.plugins.catalog import load_catalog, plan
from larenor_server.plugins.preflight_models import PreflightCheck, PreflightResult
from larenor_server.plugins.preflight_ipc import (
    PreflightWorkerClient, PreflightWorkerServer, PreflightIPCError,
    read_packet, write_packet,
)


def chosen():
    catalog = load_catalog()
    return plan(catalog.entries[0], {}, 'linux/amd64')


class Inspector:
    def __init__(self):
        self.calls = 0
    def inspect(self, selected):
        self.calls += 1
        return PreflightResult(catalogDigest=selected.catalogDigest, planHash=selected.planHash,
            platform=selected.image.platform, checkedAt=datetime.now(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00','Z'),
            checks=[PreflightCheck(code='docker_engine', status='unknown')])


@contextmanager
def root():
    with tempfile.TemporaryDirectory(prefix='ln-ipc-', dir='/tmp') as directory:
        yield Path(directory).resolve()


def uid(_connection):
    return os.getuid()


@contextmanager
def running(inspector=None, **kwargs):
    with root() as folder:
        path = folder / 'worker.sock'
        worker = PreflightWorkerServer(path, inspector or Inspector(), platform='linux/amd64',
            allowed_uid=os.getuid(), peer_uid=uid, timeout=.3, **kwargs)
        worker.start()
        try:
            yield worker, PreflightWorkerClient(path, owner_uid=os.getuid(), peer_uid=uid, timeout=.5)
        finally:
            worker.close()
        assert not path.exists()


def test_unix_worker_round_trip_reports_read_only_capability_and_bound_observations():
    inspector = Inspector()
    with running(inspector) as (worker, client):
        status = client.status()
        assert status['capability'] == 'preflight'
        assert status['installationAvailable'] is False
        assert status['catalogDigest'] == load_catalog().digest
        result = client.inspect(chosen())
        assert result.checks[0].status == 'unknown'
        assert inspector.calls == 1
        assert not hasattr(worker, 'docker')


def test_worker_refuses_mutating_operation_and_rederives_tampered_plan():
    inspector = Inspector()
    with running(inspector) as (worker, _client):
        for payload in [dict(operation='install'), dict(operation='inspect', plan={**chosen().model_dump(mode='json'), 'planHash':'f'*64})]:
            with socket.socket(socket.AF_UNIX) as connection:
                connection.connect(str(worker.path))
                write_packet(connection, dict(protocol=1,requestId='a'*32, **payload), time.monotonic()+1)
                result = read_packet(connection, time.monotonic()+1)
                assert result['error'] == 'invalid_request'
        assert inspector.calls == 0


def test_client_rejects_untrusted_peer_before_sending_a_plan():
    inspector = Inspector()
    with running(inspector) as (worker, _client):
        client = PreflightWorkerClient(worker.path, owner_uid=os.getuid(), peer_uid=lambda _:os.getuid()+1)
        with pytest.raises(PreflightIPCError):
            client.inspect(chosen())
        assert inspector.calls == 0


def test_server_rejects_wrong_caller_and_redacts_internal_exception():
    with root() as folder:
        worker = PreflightWorkerServer(folder/'worker.sock', Inspector(), platform='linux/amd64',
            allowed_uid=os.getuid()+1, peer_uid=uid, timeout=.1)
        worker.start()
        try:
            client = PreflightWorkerClient(worker.path, owner_uid=os.getuid(), peer_uid=uid, timeout=.2)
            with pytest.raises(PreflightIPCError): client.status()
        finally: worker.close()
    class Broken:
        def inspect(self, _): raise RuntimeError('secret arbitrary filesystem path')
    with running(Broken()) as (_, client):
        with pytest.raises(PreflightIPCError, match='worker_unavailable') as raised:
            client.inspect(chosen())
        assert 'secret' not in str(raised.value)


@pytest.mark.parametrize('body', [b'{}', b'{"a":1,"a":2}', b'[]', b'{"a":NaN}', b'\xff'])
def test_malformed_packet_rejected(body):
    first, second = socket.socketpair()
    try:
        first.sendall(struct.pack('!I', len(body))+body)
        with pytest.raises(PreflightIPCError): read_packet(second,time.monotonic()+.2)
    finally: first.close();second.close()


def test_packet_size_truncation_and_drip_have_total_deadline():
    for packet in (struct.pack('!I',65537),struct.pack('!I',5)+b'{'):
        first, second = socket.socketpair()
        try:
            first.sendall(packet)
            started = time.monotonic()
            with pytest.raises(PreflightIPCError): read_packet(second,started+.05)
            assert time.monotonic()-started < .5
        finally:first.close();second.close()


def test_socket_symlink_and_unsafe_modes_are_rejected_without_observation():
    with running() as (worker, client):
        alias=worker.path.parent/'alias.sock';alias.symlink_to(worker.path)
        with pytest.raises(PreflightIPCError):
            PreflightWorkerClient(alias,owner_uid=os.getuid(),peer_uid=uid).status()
        worker.path.chmod(0o666)
        with pytest.raises(PreflightIPCError): client.inspect(chosen())
        worker.path.chmod(0o600)


def test_existing_worker_lock_prevents_second_daemon_from_replacing_socket():
    with running() as (worker, client):
        second=PreflightWorkerServer(worker.path,Inspector(),platform='linux/amd64',allowed_uid=os.getuid(),peer_uid=uid)
        with pytest.raises(PreflightIPCError): second.start()
        assert client.status()['installationAvailable'] is False
        second.close()
        assert client.status()['capability'] == 'preflight'


def test_stalled_inspection_cannot_release_worker_lock_early():
    entered, release = threading.Event(), threading.Event()
    class Stalled(Inspector):
        def inspect(self, selected):
            entered.set()
            assert release.wait(3)
            return super().inspect(selected)
    with root() as folder:
        path=folder/'worker.sock'
        worker=PreflightWorkerServer(path,Stalled(),platform='linux/amd64',allowed_uid=os.getuid(),peer_uid=uid,timeout=.1)
        worker.start()
        outcomes=[]
        def run():
            try:PreflightWorkerClient(path,owner_uid=os.getuid(),peer_uid=uid,timeout=.2).inspect(chosen())
            except PreflightIPCError:outcomes.append('bounded_failure')
        thread=threading.Thread(target=run);thread.start()
        try:
            assert entered.wait(1)
            with pytest.raises(PreflightIPCError):worker.close()
            second=PreflightWorkerServer(path,Inspector(),platform='linux/amd64',allowed_uid=os.getuid(),peer_uid=uid)
            with pytest.raises(PreflightIPCError):second.start()
            second.close()
        finally:
            release.set();thread.join(1);worker.close()
        assert outcomes == ['bounded_failure']


def test_real_linux_peer_credentials_or_explicit_unsupported_platform():
    with root() as folder:
        path=folder/'worker.sock'
        worker=PreflightWorkerServer(path,Inspector(),platform='linux/amd64',allowed_uid=os.getuid(),timeout=.2)
        worker.start()
        try:
            client=PreflightWorkerClient(path,owner_uid=os.getuid(),timeout=.4)
            if hasattr(socket,'SO_PEERCRED'):
                assert client.status()['capability']=='preflight'
            else:
                with pytest.raises(PreflightIPCError):client.status()
        finally:worker.close()


def test_worker_does_not_replace_unowned_socket_or_close_on_duplicate_start():
    with root() as folder:
        path=folder/'other.sock'
        with socket.socket(socket.AF_UNIX) as other:
            other.bind(str(path));os.chmod(path,0o600);other.listen(1)
            identity=path.stat().st_ino
            worker=PreflightWorkerServer(path,Inspector(),platform='linux/amd64',allowed_uid=os.getuid(),peer_uid=uid)
            try:
                with pytest.raises(PreflightIPCError):worker.start()
                assert path.stat().st_ino==identity
            finally:worker.close()
    with running() as (worker,client):
        with pytest.raises(PreflightIPCError):worker.start()
        assert client.status()['capability']=='preflight'


def test_failed_thread_start_releases_only_this_workers_socket(monkeypatch):
    with root() as folder:
        path=folder/'worker.sock'
        worker=PreflightWorkerServer(path,Inspector(),platform='linux/amd64',allowed_uid=os.getuid(),peer_uid=uid)
        with monkeypatch.context() as patch:
            patch.setattr(threading.Thread,'start',lambda _: (_ for _ in ()).throw(RuntimeError('private error')))
            with pytest.raises(PreflightIPCError) as failure:worker.start()
            assert 'private' not in str(failure.value)
        assert not path.exists()
        replacement=PreflightWorkerServer(path,Inspector(),platform='linux/amd64',allowed_uid=os.getuid(),peer_uid=uid)
        replacement.start();replacement.close()
