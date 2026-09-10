"""Encrypted durable Sonarr/Radarr configuration jobs."""

import time
import pytest

from conftest import auth, ready
from larenor_server.plugins.arr_config_effect import ArrConfigInstallReceipt
from larenor_server.plugins.arr_config_models import (
    ArrConfiguredInstallReceipt, ArrConfigurationExecutionError)
from test_media_installations_api import prepared
from test_qbittorrent_config_jobs import Backend as QbittorrentBackend

BASE = '/api/v1/admin/media/arr-configurations'


def receipt(service='sonarr'):
    return ArrConfigInstallReceipt(
        service, '1'*32, '2'*32, '3'*32, 3,
        'larenor-appdata-v1-'+'1'*32, '4'*64,
        service+'_config_installed')


def installed(service='sonarr'):
    return ArrConfiguredInstallReceipt(
        receipt(service), '5'*64, service+'_container_started',
        service+'_service_verified')


class Backend:
    def __init__(self, result=None):
        self.calls=[]
        self.result = installed() if result is None else result

    def install_arr(self, job, plan, private, *, deadline, gate):
        self.calls.append((job, plan, private))
        assert deadline > time.monotonic() and gate()
        if isinstance(self.result, BaseException):
            raise self.result
        return installed(private.serviceId) if self.result == installed() else self.result


def queue(server, service='sonarr', request='d'*32, backend=None):
    app, client, _, _ = server
    pair, _, _, body = prepared(server)
    app.state.core.qbittorrent_configurations.backend = QbittorrentBackend()
    qbittorrent = client.post(
        '/api/v1/admin/media/qbittorrent-configurations',
        headers=auth(pair), json=body | {'requestId': 'b' * 32})
    assert qbittorrent.status_code == 201, qbittorrent.text
    assert app.state.core.qbittorrent_configurations.tick()[
        'configuration']['state'] == 'succeeded'
    selected = backend or Backend()
    app.state.core.arr_configurations.backend = selected
    body |= {'requestId': request, 'serviceId': service}
    response = client.post(BASE, headers=auth(pair), json=body)
    assert response.status_code == 201, response.text
    return pair, body, response.json()['configuration'], selected


def test_capabilities_are_closed_to_configuration_only(server):
    app, client, _, _ = server
    pair = ready(server)
    assert client.get(BASE+'/capabilities', headers=auth(pair)).json() == {
        'executionConfigured': False, 'installAvailable': False,
        'serviceIds': ['sonarr', 'radarr']}
    app.state.core.arr_configurations.backend = Backend()
    assert client.get(BASE+'/capabilities', headers=auth(pair)).json()['executionConfigured'] is True


def test_create_requires_verified_qbittorrent_for_same_preparation(server):
    app, client, _, _ = server
    pair, _, _, body = prepared(server)
    app.state.core.arr_configurations.backend = Backend()
    response = client.post(
        BASE, headers=auth(pair),
        json=body | {'requestId': 'd' * 32, 'serviceId': 'sonarr'})
    assert response.status_code == 409
    assert response.json()['error']['code'] == (
        'media_qbittorrent_configuration_required')


@pytest.mark.parametrize('service', ['sonarr', 'radarr'])
def test_server_generates_encrypted_key_and_tick_persists_receipt(server, service):
    app, client, _, _ = server
    pair, body, record, backend = queue(server, service)
    assert record['serviceId'] == service and record['state'] == 'queued'
    assert record['containerState'] is None and record['serviceState'] is None
    private = app.state.core.arr_configurations.private_payload(record['id'])
    assert private.service_id == service and len(private.api_key) == 32
    assert private.api_key not in repr(private)+repr(record)
    with app.state.core.db.connection() as connection:
        stored = connection.execute('SELECT ciphertext FROM media_arr_configurations').fetchone()[0]
    assert private.api_key.encode() not in stored
    terminal = app.state.core.arr_configurations.tick()['configuration']
    assert terminal['state'] == 'succeeded'
    assert terminal['configurationState'] == service+'_config_installed'
    assert terminal['containerState'] == 'container_started'
    assert terminal['serviceState'] == 'verified'
    assert app.state.core.arr_configurations.private_payload(record['id']).receipt == installed(service)
    assert backend.calls[0][2].apiKey == private.api_key
    assert backend.calls[0][2].qbittorrentApiKey is not None
    assert client.post(BASE, headers=auth(pair), json=body).json()['configuration'] == terminal


def test_one_preparation_can_configure_both_services_but_not_same_service_twice(server):
    app, client, _, _ = server
    pair, body, first, _ = queue(server, 'sonarr')
    second = client.post(BASE, headers=auth(pair), json=body | {
        'requestId': 'e'*32, 'serviceId': 'radarr'})
    assert second.status_code == 201
    duplicate = client.post(BASE, headers=auth(pair), json=body | {'requestId': 'f'*32})
    assert duplicate.status_code == 409
    assert first['serviceId'] == 'sonarr'


def test_uncertain_worker_failure_needs_attention_without_secret_leak(server):
    failure = ArrConfigurationExecutionError('arr_config_write_failed', uncertain_effect=True)
    app, _, _, _ = server
    _, _, record, _ = queue(server, backend=Backend(failure))
    terminal = app.state.core.arr_configurations.tick()['configuration']
    assert terminal['state'] == 'needs_attention'
    assert terminal['errorCode'] == 'arr_config_write_failed'
    assert 'apiKey' not in repr(terminal)+repr(failure)


def test_public_api_rejects_private_or_execution_fields(server):
    _, client, _, _ = server
    pair, body, _, _ = queue(server)
    response = client.post(BASE, headers=auth(pair), json=body | {
        'requestId': 'a'*32, 'serviceId': 'radarr', 'apiKey': '0'*32})
    assert response.status_code == 400
