import time

import pytest

from conftest import auth
from larenor_server.plugins.media_archive_core_models import (
    PrivateMediaArchiveCollection,
    PrivateMediaArchiveWorkerCollection,
)
from larenor_server.plugins.media_archive_provider import (
    MediaArchiveWorkerProvider,
)
from test_arr_config_jobs import Backend as ArrBackend
from test_media_archive_ingestion import ingested
from test_media_installations_api import ExecutionBackend, prepared
from test_media_service_bootstraps import (
    BASE as BOOTSTRAP_BASE,
    BootstrapBackend,
    request as bootstrap_request,
)
from test_qbittorrent_config_jobs import Backend as QbittorrentBackend


class ArchiveBackend:
    def __init__(self, action=None, failure=None):
        self.action = action
        self.failure = failure
        self.calls = []

    def read_media_archive(self, private, *, deadline, gate):
        assert type(private) is PrivateMediaArchiveWorkerCollection
        assert time.monotonic() < deadline and gate() is True
        self.calls.append(private)
        if self.action is not None:
            self.action()
        if self.failure is not None:
            raise self.failure
        bindings = {item.serviceId: item for item in private.authority.sources}
        sample = ingested()
        return sample.model_copy(update={
            service: getattr(sample, service).model_copy(
                update=bindings[service].model_dump(mode='python'))
            for service in ('jellyfin', 'sonarr', 'radarr', 'qbittorrent')
        })


def provision(server):
    app, client, settings, clock = server
    pair, _preparation, _inspection, body = prepared(server)

    app.state.core.media_installations.backend = ExecutionBackend()
    response = client.post(
        '/api/v1/admin/media/installations', headers=auth(pair), json=body)
    assert response.status_code == 201, response.text
    installation = app.state.core.media_installations.tick()['installation']
    assert installation['state'] == 'container_started'

    response = client.post(
        BOOTSTRAP_BASE, headers=auth(pair),
        json=bootstrap_request(installation, 'd' * 32))
    assert response.status_code == 201, response.text
    app.state.core.media_service_bootstraps.backend = BootstrapBackend()
    bootstrap = app.state.core.media_service_bootstraps.tick()['bootstrap']
    assert (bootstrap['state'], bootstrap['credentialsConfigured'],
            bootstrap['wiringState']) == ('wiring_partial', True, 'partial')

    app.state.core.qbittorrent_configurations.backend = QbittorrentBackend()
    response = client.post(
        '/api/v1/admin/media/qbittorrent-configurations',
        headers=auth(pair), json=body | {'requestId': 'e' * 32})
    assert response.status_code == 201, response.text
    qbittorrent = app.state.core.qbittorrent_configurations.tick()[
        'configuration']
    assert qbittorrent['state'] == 'succeeded'

    app.state.core.arr_configurations.backend = ArrBackend()
    configurations = {}
    for service, request_id in (('sonarr', 'f' * 32), ('radarr', 'a' * 32)):
        response = client.post(
            '/api/v1/admin/media/arr-configurations', headers=auth(pair),
            json=body | {'requestId': request_id, 'serviceId': service})
        assert response.status_code == 201, response.text
        configurations[service] = app.state.core.arr_configurations.tick()[
            'configuration']
        assert configurations[service]['state'] == 'succeeded'
    return app, settings, clock, installation, qbittorrent, configurations


def provider(app, settings, backend):
    return MediaArchiveWorkerProvider(
        app.state.core.db, settings,
        app.state.core.media_installations,
        app.state.core.media_service_bootstraps,
        app.state.core.qbittorrent_configurations,
        app.state.core.arr_configurations,
        backend,
    )


def test_core_persists_secret_free_snapshot_and_reuses_it_after_restart(server):
    app, settings, _clock, installation, _qbittorrent, _arr = provision(server)
    backend = ArchiveBackend()
    selected = provider(app, settings, backend)

    authority = selected.current(installation['id'])
    assert authority.snapshotRevision == 1
    assert len(backend.calls) == 1
    assert [item.serviceId for item in backend.calls[0].sources] == [
        'jellyfin', 'sonarr', 'radarr', 'qbittorrent']
    assert [item.serviceRevision for item in authority.sources] == [3, 3, 3, 3]

    private = PrivateMediaArchiveCollection(
        requestId='b' * 32, authority=authority)
    observed = selected.read_media_archive(
        private, deadline=time.monotonic() + 1, gate=lambda: True)
    assert observed.jellyfin.snapshotRevision == authority.snapshotRevision

    restarted_backend = ArchiveBackend()
    restarted = provider(app, settings, restarted_backend)
    restarted.validate_storage()
    assert restarted.current(installation['id']) == authority
    assert restarted_backend.calls == []

    secrets = [item.apiKey for item in backend.calls[0].sources[1:]]
    with app.state.core.db.connection() as connection:
        stored = dict(connection.execute(
            'SELECT * FROM media_archive_snapshots').fetchone())
    encoded = repr(stored)
    assert all(secret not in encoded for secret in secrets)
    assert 'apiKey' not in stored['observation_json']


def test_refresh_atomically_retires_prior_revision_and_keeps_it_on_failure(server):
    app, settings, clock, installation, _qbittorrent, _arr = provision(server)
    backend = ArchiveBackend()
    selected = provider(app, settings, backend)
    first = selected.current(installation['id'])

    clock.now += 241
    second = selected.current(installation['id'])
    assert (first.snapshotRevision, second.snapshotRevision) == (1, 2)
    with app.state.core.db.connection() as connection:
        rows = connection.execute(
            'SELECT snapshot_revision,state,retired_at FROM '
            'media_archive_snapshots ORDER BY snapshot_revision').fetchall()
    assert [(row['snapshot_revision'], row['state']) for row in rows] == [
        (1, 'retired'), (2, 'active')]
    assert rows[0]['retired_at'] == int(clock.now)
    assert rows[1]['retired_at'] is None

    clock.now += 241
    third = selected.current(installation['id'])
    assert third.snapshotRevision == 3
    restarted = provider(app, settings, ArchiveBackend())
    restarted.validate_storage()
    assert restarted.current(installation['id']) == third
    with app.state.core.db.connection() as connection:
        rows = connection.execute(
            'SELECT snapshot_revision,state FROM media_archive_snapshots '
            'ORDER BY snapshot_revision').fetchall()
    assert [(row['snapshot_revision'], row['state']) for row in rows] == [
        (1, 'retired'), (2, 'retired'), (3, 'active')]

    clock.now += 241
    selected.backend = ArchiveBackend(failure=RuntimeError('private failure'))
    with pytest.raises(RuntimeError, match='private failure'):
        selected.current(installation['id'])
    with app.state.core.db.connection() as connection:
        active = connection.execute(
            "SELECT snapshot_revision FROM media_archive_snapshots "
            "WHERE state='active'").fetchall()
    assert [row['snapshot_revision'] for row in active] == [3]


def test_private_credential_change_during_collection_discards_result(server):
    app, settings, _clock, installation, qbittorrent, _arr = provision(server)
    manager = app.state.core.qbittorrent_configurations

    def change_private_key():
        with manager.db.transaction() as connection:
            row = manager._find(connection, qbittorrent['id'])
            payload = manager._validate_row(connection, row)
            changed = payload.private.model_copy(
                update={'apiKey': 'qbt_' + 'z' * 28})
            manager._save(
                connection, row, payload.model_copy(update={'private': changed}))

    backend = ArchiveBackend(action=change_private_key)
    selected = provider(app, settings, backend)
    with pytest.raises(ValueError, match='media_archive_worker_unavailable'):
        selected.current(installation['id'])
    with app.state.core.db.connection() as connection:
        assert connection.execute(
            'SELECT COUNT(*) FROM media_archive_snapshots').fetchone()[0] == 0
