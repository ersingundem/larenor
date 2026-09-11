import json

import pytest

from conftest import auth
from larenor_server.plugins.media_archive_core_models import (
    MediaArchiveCollectionAuthority,
)
from test_media_archive_ingestion import NOW, binding, ingested
from test_media_service_bootstraps import installed


BASE = '/api/v1/admin/media/archive-health/read'


class BindingReader:
    def __init__(self, values=None):
        self.values = list(values or [authority()])
        self.calls = 0

    def current(self, installation_id):
        assert installation_id == 'ignored-by-fixture' or len(installation_id) == 32
        self.calls += 1
        return self.values.pop(0) if len(self.values) > 1 else self.values[0]


class Worker:
    def __init__(self, result=None, change=None):
        self.result = result or ingested()
        self.change = change
        self.calls = []

    def read_media_archive(self, private, *, deadline, gate):
        assert deadline > 0 and gate() is True
        self.calls.append(private)
        if self.change:
            self.change()
        return self.result


def authority(snapshot=4, observed=NOW - 10):
    return MediaArchiveCollectionAuthority(
        installationId='1' * 32,
        installationRevision=12,
        snapshotRevision=snapshot,
        sources=[binding(service, observed=observed, snapshot=snapshot)
                 for service in ('jellyfin', 'sonarr', 'radarr', 'qbittorrent')],
    )


def configured(server, *, reader=None, worker=None):
    app, client, _, clock = server
    pair, installation = installed(server)
    current = authority().model_copy(update={
        'installationId': installation['id'],
        'installationRevision': installation['revision'],
        'sources': [item.model_copy(update={
            'installationId': installation['id'],
            'installationRevision': installation['revision'],
        }) for item in authority().sources],
    })
    reader = reader or BindingReader([current])
    result = ingested().model_copy(update={
        name: getattr(ingested(), name).model_copy(update={
            'installationId': installation['id'],
            'installationRevision': installation['revision'],
        }) for name in ('jellyfin', 'sonarr', 'radarr', 'qbittorrent')
    })
    worker = worker or Worker(result)
    app.state.core.media_archive_health.binding_reader = reader
    app.state.core.media_archive_health.backend = worker
    clock.now = NOW
    body = {
        'requestId': 'e' * 32,
        'installationId': installation['id'],
        'expectedInstallationRevision': installation['revision'],
        'expectedSnapshotRevision': 4,
    }
    return pair, installation, current, reader, worker, body


def test_admin_reads_one_bounded_secret_free_archive_snapshot(server):
    pair, _installation, _current, reader, worker, body = configured(server)
    response = server[1].post(BASE, headers=auth(pair), json=body)
    assert response.status_code == 200, response.text
    result = response.json()
    assert result['requestId'] == 'e' * 32
    assert result['archive']['snapshotRevision'] == 4
    assert result['archive']['counts']['potentialSavingBytes'] == 4_000
    assert result['archive']['cleanupAvailable'] is False
    assert reader.calls == 2 and len(worker.calls) == 1
    assert 'token' not in json.dumps(result).lower()
    assert '/data/' not in response.text and '/media/' not in response.text
    assert 'credential' not in repr(worker.calls[0]).lower()


def test_default_core_has_no_archive_worker_and_never_claims_read_success(server):
    pair, installation = installed(server)
    response = server[1].post(BASE, headers=auth(pair), json={
        'requestId': 'e' * 32,
        'installationId': installation['id'],
        'expectedInstallationRevision': installation['revision'],
        'expectedSnapshotRevision': 4,
    })
    assert response.status_code == 503
    assert response.json()['error']['code'] == 'media_archive_worker_unavailable'


def test_member_expired_session_and_wrong_revision_never_reach_worker(server):
    app, client, _, _ = server
    pair, installation, _current, _reader, worker, body = configured(server)
    stale = client.post(BASE, headers=auth(pair), json={
        **body, 'expectedInstallationRevision': installation['revision'] + 1,
    })
    assert stale.status_code == 409
    client.post('/api/v1/auth/logout', headers=auth(pair))
    expired = client.post(BASE, headers=auth(pair), json=body)
    assert expired.status_code == 401
    assert worker.calls == []
    assert app.state.core.media_archive_health.backend is worker


def test_session_or_binding_change_during_read_discards_late_result(server):
    app, client, _, _ = server
    pair, _installation, current, reader, worker, body = configured(server)
    changed = current.model_copy(update={
        'snapshotRevision': 5,
        'sources': [item.model_copy(update={'snapshotRevision': 5})
                    for item in current.sources],
    })
    reader.values = [current, changed]
    response = client.post(BASE, headers=auth(pair), json=body)
    assert response.status_code == 409
    assert response.json()['error']['code'] == 'media_archive_authority_changed'
    assert len(worker.calls) == 1

    reader.values = [current]
    reader.calls = 0
    worker.calls.clear()
    worker.change = lambda: client.post('/api/v1/auth/logout', headers=auth(pair))
    response = client.post(BASE, headers=auth(pair), json=body)
    assert response.status_code == 401
    assert len(worker.calls) == 1


def test_stale_authority_and_invalid_worker_shape_fail_closed(server):
    pair, installation, current, reader, worker, body = configured(server)
    old = current.model_copy(update={
        'sources': [item.model_copy(update={'observedAt': NOW - 301})
                    for item in current.sources],
    })
    reader.values = [old]
    stale = server[1].post(BASE, headers=auth(pair), json=body)
    assert stale.status_code == 409
    assert stale.json()['error']['code'] == 'media_archive_snapshot_stale'
    assert worker.calls == []

    reader.values = [current]
    worker.result = {'token': 'private'}
    invalid = server[1].post(BASE, headers=auth(pair), json=body)
    assert invalid.status_code == 503
    assert invalid.json()['error']['code'] == 'media_archive_worker_unavailable'
    assert 'private' not in invalid.text


@pytest.mark.parametrize('extra', [
    {'delete': True}, {'cleanup': True}, {'token': 'private'},
    {'expectedSnapshotRevision': True},
])
def test_api_rejects_mutation_secret_and_weak_revision_fields(server, extra):
    pair, _installation, _current, _reader, worker, body = configured(server)
    response = server[1].post(BASE, headers=auth(pair), json={**body, **extra})
    assert response.status_code == 400
    assert worker.calls == []
    assert 'private' not in response.text
