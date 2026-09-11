from dataclasses import replace
import json
import os
from pathlib import Path
import tempfile
import time

import pytest

from conftest import auth
from larenor_server.plugins.managed_container import (
    ManagedImageProof,
    ManagedNetworkProof,
    ManagedVolumeProof,
    VerifiedJellyfinResources,
)
from larenor_server.plugins.media_archive_capacity_collector import (
    CapacityEnrichedMediaArchiveCollector,
    MediaArchiveCapacityCollector,
    MediaArchiveCapacityCollectorError,
    OwnedVolumeCapacitySnapshot,
    bind_owned_jellyfin_capacity,
)
from larenor_server.plugins.media_archive_worker_ipc import (
    MediaArchiveWorkerClient,
    MediaArchiveWorkerServer,
)
from test_media_archive_core_read import BASE, configured


class Proofs:
    def __init__(self, values):
        self.values = list(values)
        self.calls = []

    def current(self, installation_id, installation_revision):
        self.calls.append((installation_id, installation_revision))
        return self.values.pop(0) if len(self.values) > 1 else self.values[0]


class CapacityReader:
    def __init__(self, result=None, change=None):
        self.result = result
        self.change = change
        self.calls = []

    def read(self, binding, *, deadline, gate):
        assert time.monotonic() < deadline and gate() is True
        self.calls.append(binding)
        if self.change is not None:
            self.change()
        return self.result or OwnedVolumeCapacitySnapshot(
            volumeResourceId=binding.volumeResourceId,
            volumeRevision=binding.volumeRevision,
            totalBytes=1_000_000_000_000,
            freeBytes=300_000_000_000,
        )


class ArchiveCollector:
    def __init__(self, result):
        self.result = result
        self.calls = []

    def collect(self, private, *, deadline, gate):
        assert time.monotonic() < deadline and gate() is True
        self.calls.append(private)
        return self.result


def volume(identifier, target):
    prefix = 'library' if target == '/media' else 'appdata'
    operation = {'7': 'c', '8': 'd', '9': 'e'}[identifier]
    nonce = {'7': '1', '8': '2', '9': '3'}[identifier]
    return ManagedVolumeProof(
        resource_id=identifier * 32,
        operation_id=operation * 32,
        revision=5,
        journal_id='a' * 32,
        ownership_nonce=nonce * 32,
        name=f'larenor-{prefix}-v1-{identifier * 32}',
        target=target,
        bootstrap_verified=True,
    )


def proof():
    return VerifiedJellyfinResources(
        stack_plan_hash='1' * 64,
        resource_plan_hash='2' * 64,
        volume_plan_hash='3' * 64,
        worker_policy_digest='4' * 64,
        image=ManagedImageProof('5' * 32, 6, '6' * 64, b'{}'),
        volumes=(volume('7', '/config'), volume('8', '/cache'),
                 volume('9', '/media')),
        network=ManagedNetworkProof(
            'c' * 32, 'd' * 32, 7, 'e' * 32, 'f' * 32,
            'larenor-media-v1-' + 'c' * 32, '7' * 64),
    )


def private_and_observation(server):
    pair, _installation, current, _reader, worker, body = configured(server)
    from larenor_server.plugins.media_archive_core_models import (
        PrivateMediaArchiveCollection,
    )
    return pair, body, PrivateMediaArchiveCollection(
        requestId=body['requestId'], authority=current), worker.result


def test_binding_accepts_only_exact_current_owned_jellyfin_library(server):
    _pair, _body, private, _observation = private_and_observation(server)
    selected = bind_owned_jellyfin_capacity(private, proof())
    assert selected.installationId == private.authority.installationId
    assert selected.volumeResourceId == '9' * 32
    assert selected.volumeName == 'larenor-library-v1-' + '9' * 32
    assert '/media' not in repr(selected)

    media = proof().volumes[-1]
    for changed in (
        replace(media, target='/foreign'),
        replace(media, name='foreign-volume'),
        replace(media, bootstrap_verified=False),
        replace(media, revision=0),
    ):
        candidate = replace(proof(), volumes=proof().volumes[:-1] + (changed,))
        with pytest.raises(
            MediaArchiveCapacityCollectorError,
            match='capacity_binding_unavailable',
        ):
            bind_owned_jellyfin_capacity(private, candidate)


def test_collector_reads_once_and_rechecks_proof_revision(server):
    _pair, _body, private, _observation = private_and_observation(server)
    proofs, reader = Proofs([proof()]), CapacityReader()
    collector = MediaArchiveCapacityCollector(proofs, reader)
    result = collector.collect(
        private, deadline=time.monotonic() + 1, gate=lambda: True)
    assert result.model_dump() == {
        'source': 'jellyfin',
        'serviceRevision': next(
            item.serviceRevision for item in private.authority.sources
            if item.serviceId == 'jellyfin'),
        'snapshotRevision': private.authority.snapshotRevision,
        'state': 'verified',
        'totalBytes': 1_000_000_000_000,
        'freeBytes': 300_000_000_000,
    }
    assert len(reader.calls) == 1 and len(proofs.calls) == 2
    assert 'volumeName' not in result.model_dump()

    changed = replace(
        proof(),
        volumes=proof().volumes[:-1] +
        (replace(proof().volumes[-1], revision=6),),
    )
    reader = CapacityReader()
    with pytest.raises(
        MediaArchiveCapacityCollectorError,
        match='capacity_authority_changed',
    ):
        MediaArchiveCapacityCollector(
            Proofs([proof(), changed]), reader,
        ).collect(private, deadline=time.monotonic() + 1, gate=lambda: True)
    assert len(reader.calls) == 1


def test_deadline_cancel_and_bad_result_fail_closed_without_retry(server):
    _pair, _body, private, _observation = private_and_observation(server)
    for deadline, gate, result, expected_calls in (
        (time.monotonic() - 1, lambda: True, None, 0),
        (time.monotonic() + 1, lambda: False, None, 0),
        (time.monotonic() + 1, lambda: True,
         {'totalBytes': 1, 'freeBytes': 1, 'token': 'private'}, 1),
        (time.monotonic() + 1, lambda: True,
         OwnedVolumeCapacitySnapshot(
             volumeResourceId='0' * 32, volumeRevision=5,
             totalBytes=100, freeBytes=10), 1),
    ):
        reader = CapacityReader(result=result)
        with pytest.raises(MediaArchiveCapacityCollectorError):
            MediaArchiveCapacityCollector(
                Proofs([proof()]), reader,
            ).collect(private, deadline=deadline, gate=gate)
        assert len(reader.calls) == expected_calls


def test_private_worker_ipc_enriches_one_read_and_core_writes_one_snapshot(
        server):
    pair, body, _private, observation = private_and_observation(server)
    reader = CapacityReader()
    collector = CapacityEnrichedMediaArchiveCollector(
        ArchiveCollector(observation),
        MediaArchiveCapacityCollector(Proofs([proof()]), reader),
    )
    parent = Path('/private/tmp') if Path('/private/tmp').is_dir() else Path('/tmp')
    directory = Path(tempfile.mkdtemp(prefix='lac-', dir=parent))
    socket_path = directory / 'a.sock'
    runtime = MediaArchiveWorkerServer(
        socket_path, collector, allowed_uid=os.getuid(),
        peer_uid=lambda _connection: os.getuid(), timeout=1)
    runtime.start()
    try:
        client = MediaArchiveWorkerClient(
            socket_path, owner_uid=os.getuid(),
            peer_uid=lambda _connection: os.getuid(), timeout=1)
        server[0].state.core.media_archive_health.backend = client
        response = server[1].post(BASE, headers=auth(pair), json=body)
    finally:
        runtime.close()
        directory.rmdir()
    assert response.status_code == 200, response.text
    trend = response.json()['archive']['weeklyTrend']
    assert trend['state'] == 'ready' and len(trend['points']) == 1
    assert len(reader.calls) == 1
    with server[0].state.core.db.connection() as connection:
        assert connection.execute(
            'SELECT COUNT(*) FROM media_archive_weekly_trends'
        ).fetchone()[0] == 1
    wire = json.dumps(response.json()).lower()
    assert all(word not in wire for word in (
        'token', 'password', 'cookie', 'mountpoint', '/media'))


def test_enricher_rejects_late_cancel_and_never_returns_partial_result(server):
    _pair, _body, private, observation = private_and_observation(server)
    active = True

    def gate():
        return active

    def retire():
        nonlocal active
        active = False

    reader = CapacityReader(change=retire)
    collector = CapacityEnrichedMediaArchiveCollector(
        ArchiveCollector(observation),
        MediaArchiveCapacityCollector(Proofs([proof()]), reader),
    )
    with pytest.raises(MediaArchiveCapacityCollectorError):
        collector.collect(private, deadline=time.monotonic() + 1, gate=gate)
    assert len(reader.calls) == 1
