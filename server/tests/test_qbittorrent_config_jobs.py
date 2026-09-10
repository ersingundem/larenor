"""Encrypted durable qBittorrent configuration jobs."""

from dataclasses import replace
from fastapi.testclient import TestClient
import os
import pytest
import time

from conftest import auth, ready
from larenor_server.app import create_app
from larenor_server.plugins.qbittorrent_config_effect import (
    QbittorrentConfigInstallReceipt,
)
from larenor_server.plugins.qbittorrent_config_models import (
    QbittorrentConfigurationExecutionError,
)
from test_media_installations_api import prepared


BASE = '/api/v1/admin/media/qbittorrent-configurations'


class Backend:
    def __init__(self, result=None, action=None):
        self.calls = []
        self.result = result or QbittorrentConfigInstallReceipt(
            '1' * 32, '2' * 32, '3' * 32, 3,
            'larenor-appdata-v1-' + '1' * 32, '4' * 64,
            'qbittorrent_config_installed',
        )
        self.action = action

    def configure_qbittorrent(self, job, plan, private, *, deadline, gate):
        self.calls.append((job, plan, private, deadline, gate))
        assert deadline > time.monotonic() and gate() is True
        if self.action:
            self.action()
        if isinstance(self.result, BaseException):
            raise self.result
        return self.result


def queue(server, request_id='d' * 32, backend=None):
    app, client, _, _ = server
    pair, _preparation, _inspection, body = prepared(server)
    selected = backend or Backend()
    app.state.core.qbittorrent_configurations.backend = selected
    body = body | {'requestId': request_id}
    response = client.post(BASE, headers=auth(pair), json=body)
    assert response.status_code == 201, response.text
    return pair, body, response.json()['configuration'], selected


def test_capability_reports_private_worker_without_opening_install(server):
    app, client, _, _ = server
    pair = ready(server)
    assert client.get(BASE + '/capabilities', headers=auth(pair)).json() == {
        'executionConfigured': False,
        'installAvailable': False,
        'serviceId': 'qbittorrent',
    }
    app.state.core.qbittorrent_configurations.backend = Backend()
    assert client.get(BASE + '/capabilities', headers=auth(pair)).json() == {
        'executionConfigured': True,
        'installAvailable': False,
        'serviceId': 'qbittorrent',
    }


def test_create_encrypts_server_generated_private_values_and_is_idempotent(server):
    app, client, settings, _ = server
    pair, body, record, backend = queue(server)
    assert record == {
        'id': record['id'], 'requestId': body['requestId'],
        'preparationId': body['preparationId'], 'inspectionId': body['inspectionId'],
        'serviceId': 'qbittorrent', 'revision': 1, 'state': 'queued',
        'phase': 'queued', 'cancelRequested': False, 'configured': False,
        'configurationState': None, 'errorCode': None,
        'installAvailable': False,
        'createdAt': '2026-09-05T12:00:00.000Z',
        'updatedAt': '2026-09-05T12:00:00.000Z',
    }
    assert client.post(BASE, headers=auth(pair), json=body).json() == {
        'configuration': record}
    private = app.state.core.qbittorrent_configurations.private_payload(record['id'])
    assert len(private.credential) >= 32 and len(private.api_key) >= 32
    assert len(private.salt) == 16 and private.receipt is None
    assert private.credential not in repr(private) + repr(record)
    assert private.api_key not in repr(private) + repr(record)
    with app.state.core.db.connection() as connection:
        stored = connection.execute(
            'SELECT nonce,ciphertext FROM media_qbittorrent_configurations',
        ).fetchone()
    assert len(stored['nonce']) == 12
    assert private.credential.encode() not in stored['ciphertext']
    assert private.api_key.encode() not in stored['ciphertext']
    assert backend.calls == []
    with TestClient(create_app(settings)) as reopened:
        assert reopened.get(BASE + '/' + record['id'], headers=auth(pair)).json() == {
            'configuration': record}


def test_tick_persists_secret_free_journal_receipt(server):
    app, client, _, _ = server
    pair, _body, record, backend = queue(server)
    terminal = app.state.core.qbittorrent_configurations.tick()['configuration']
    assert terminal == record | {
        'revision': 3, 'state': 'succeeded', 'phase': 'complete',
        'configured': True,
        'configurationState': 'qbittorrent_config_installed',
    }
    private = app.state.core.qbittorrent_configurations.private_payload(record['id'])
    assert private.receipt == backend.result
    assert backend.calls[0][0] == record['id']
    assert backend.calls[0][2].credential == private.credential
    assert private.credential not in repr(terminal) + repr(private)
    assert client.get(BASE + '/' + record['id'], headers=auth(pair)).json() == {
        'configuration': terminal}


def test_lifespan_dispatches_job_over_real_uid_checked_unix_ipc(server, monkeypatch):
    from test_qbittorrent_installation_ipc import running

    _app, _client, settings, _ = server
    pair, _body, record, _backend = queue(server)
    monkeypatch.setattr(
        'larenor_server.plugins.preflight_ipc._peer_uid',
        lambda _connection: os.getuid())
    with running() as (worker_backend, worker):
        configured = replace(
            settings, installation_worker_socket=worker.path,
            installation_worker_uid=os.getuid())
        with TestClient(create_app(configured)) as reopened:
            assert reopened.app.state.qbittorrent_configuration_dispatcher is not None
            end = time.monotonic() + 5
            while True:
                terminal = reopened.get(
                    BASE + '/' + record['id'], headers=auth(pair),
                ).json()['configuration']
                if terminal['state'] not in {'queued', 'running'}:
                    break
                assert time.monotonic() < end
                time.sleep(.025)
    assert terminal['state'] == 'succeeded'
    assert terminal['configurationState'] == 'qbittorrent_config_installed'
    assert worker_backend.calls[0][0] == record['id']


def test_lifespan_waits_for_inflight_receipt_before_shutdown(server):
    from concurrent.futures import ThreadPoolExecutor
    from threading import Event

    app, client, _, _ = server
    pair, _body, record, backend = queue(server)
    entered, release, stopping, stopped = Event(), Event(), Event(), Event()

    def hold_effect():
        entered.set()
        assert release.wait(5)

    backend.action = hold_effect

    def lifecycle():
        with TestClient(app):
            assert entered.wait(5)
            stopping.set()
        stopped.set()

    with ThreadPoolExecutor(max_workers=1) as pool:
        future = pool.submit(lifecycle)
        try:
            assert entered.wait(5) and stopping.wait(5)
            assert not stopped.wait(.05)
            assert app.state.qbittorrent_configuration_dispatcher is not None
        finally:
            release.set()
        future.result(timeout=5)
    assert stopped.is_set()
    terminal = client.get(
        BASE + '/' + record['id'], headers=auth(pair)).json()['configuration']
    assert terminal['state'] == 'succeeded'


def test_lifespan_logs_only_static_dispatch_error(server, caplog):
    from threading import Event

    app, _client, _, _ = server
    _pair, _body, _record, _backend = queue(server)
    entered = Event()

    def broken_tick():
        entered.set()
        raise RuntimeError('private-qbittorrent-path')

    app.state.core.qbittorrent_configurations.tick = broken_tick
    with TestClient(app):
        assert entered.wait(5)
    assert 'qbittorrent_configuration_dispatch_unavailable' in caplog.text
    assert 'private-qbittorrent-path' not in caplog.text


def test_cancelled_queue_never_reaches_worker(server):
    app, client, _, _ = server
    pair, _body, record, backend = queue(server)
    cancelled = client.post(
        BASE + '/' + record['id'] + '/cancel', headers=auth(pair),
        json={'expectedRevision': 1},
    ).json()['configuration']
    assert cancelled['state'] == 'cancelled' and cancelled['cancelRequested']
    assert app.state.core.qbittorrent_configurations.tick() is None
    assert backend.calls == []


def test_interrupted_running_job_is_not_retried(server):
    app, _client, _, _ = server
    _pair, _body, record, backend = queue(server)
    manager = app.state.core.qbittorrent_configurations
    with manager.db.transaction() as connection:
        row = manager._find(connection, record['id'])
        manager._transition(connection, row, manager._decode(row), state='running')
    terminal = manager.tick()['configuration']
    assert terminal['state'] == 'needs_attention'
    assert terminal['errorCode'] == 'qbittorrent_config_interrupted'
    assert backend.calls == []


@pytest.mark.parametrize('failure,state', [
    (QbittorrentConfigurationExecutionError(
        'qbittorrent_config_resources_unavailable'), 'failed'),
    (QbittorrentConfigurationExecutionError(
        'qbittorrent_config_write_failed', uncertain_effect=True), 'needs_attention'),
])
def test_worker_failure_is_static_and_preserves_private_payload(server, failure, state):
    app, _client, _, _ = server
    backend = Backend(failure)
    _pair, _body, record, _ = queue(server, backend=backend)
    terminal = app.state.core.qbittorrent_configurations.tick()['configuration']
    assert terminal['state'] == state and terminal['errorCode'] == failure.code
    private = app.state.core.qbittorrent_configurations.private_payload(record['id'])
    assert private.receipt is None
    assert private.credential not in repr(failure) + repr(terminal)


def test_unknown_worker_failure_is_uncertain(server):
    app, _client, _, _ = server
    backend = Backend(RuntimeError('private-worker-detail'))
    _pair, _body, record, _ = queue(server, backend=backend)
    terminal = app.state.core.qbittorrent_configurations.tick()['configuration']
    assert terminal['state'] == 'needs_attention'
    assert terminal['errorCode'] == 'qbittorrent_config_worker_unavailable'
    assert 'private-worker-detail' not in repr(terminal)
    assert app.state.core.qbittorrent_configurations.private_payload(
        record['id']).receipt is None


def test_authority_loss_before_dispatch_never_reaches_worker(server):
    app, client, settings, _ = server
    pair, _body, _record, backend = queue(server)
    with app.state.core.db.connection() as connection:
        connection.execute('UPDATE session_families SET revoked_at=?',
                           (int(settings.clock()),))
    terminal = app.state.core.qbittorrent_configurations.tick()['configuration']
    assert terminal['state'] == 'needs_attention'
    assert terminal['errorCode'] == 'qbittorrent_config_authority_changed'
    assert backend.calls == []
    assert client.get(BASE, headers=auth(pair)).status_code == 401


def test_authority_loss_after_effect_is_needs_attention_without_receipt(server):
    app, client, _, _ = server
    pair, _body, record, backend = queue(server)
    backend.action = lambda: client.post('/api/v1/auth/logout', headers=auth(pair))
    terminal = app.state.core.qbittorrent_configurations.tick()['configuration']
    assert terminal['state'] == 'needs_attention'
    assert terminal['errorCode'] == 'qbittorrent_config_authority_changed'
    assert len(backend.calls) == 1
    assert app.state.core.qbittorrent_configurations.private_payload(record['id']).receipt is None


def test_cancel_during_effect_is_preserved_as_uncertain(server):
    app, client, _, _ = server
    pair, _body, record, backend = queue(server)
    backend.action = lambda: client.post(
        BASE + '/' + record['id'] + '/cancel', headers=auth(pair),
        json={'expectedRevision': 2})
    terminal = app.state.core.qbittorrent_configurations.tick()['configuration']
    assert terminal['state'] == 'needs_attention'
    assert terminal['errorCode'] == 'qbittorrent_config_cancellation_uncertain'
    assert terminal['cancelRequested'] and len(backend.calls) == 1
    assert app.state.core.qbittorrent_configurations.private_payload(record['id']).receipt is None


@pytest.mark.parametrize('extra', [
    {'credential': 'c' * 48}, {'apiKey': 'a' * 32},
    {'docker': {'HostConfig': {'Privileged': True}}}, {'serviceId': 'qbittorrent'},
])
def test_http_never_accepts_private_or_effect_selection(server, extra):
    app, client, _, _ = server
    pair, _preparation, _inspection, body = prepared(server)
    app.state.core.qbittorrent_configurations.backend = Backend()
    response = client.post(BASE, headers=auth(pair), json=body | extra)
    assert response.status_code == 400
    assert response.json()['error']['code'] == 'invalid_request'
    assert client.get(BASE, headers=auth(pair)).json() == {
        'configurations': [], 'nextBefore': None}


@pytest.mark.parametrize('damage', ['ciphertext', 'nonce', 'state', 'table', 'orphan'])
def test_storage_damage_fails_closed_on_restart(server, damage):
    app, _client, settings, _ = server
    _pair, _body, _record, _backend = queue(server)
    with app.state.core.db.connection() as connection:
        if damage == 'ciphertext':
            connection.execute("UPDATE media_qbittorrent_configurations SET ciphertext=x'00'")
        elif damage == 'nonce':
            connection.execute("UPDATE media_qbittorrent_configurations SET nonce=x'00'")
        elif damage == 'state':
            connection.execute('PRAGMA ignore_check_constraints=ON')
            connection.execute("UPDATE media_qbittorrent_configurations SET state='private'")
        elif damage == 'table':
            connection.execute(
                'ALTER TABLE media_qbittorrent_configurations RENAME TO media_qbittorrent_configurations_old')
        else:
            connection.execute('PRAGMA foreign_keys=OFF')
            connection.execute('DELETE FROM media_preparations')
    expected = ('media_qbittorrent_configurations_schema_unsupported'
                if damage == 'table' else 'invalid_media_qbittorrent_configurations_storage')
    with pytest.raises(Exception, match=expected):
        create_app(settings)
