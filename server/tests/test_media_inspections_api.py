"""HTTP contract for durable, aggregate read-only media inspections."""

import pytest
from fastapi.testclient import TestClient

from conftest import auth, login, ready
from test_admin import TEMPORARY, activate, create as create_user
from test_media_preparations_api import create_preparation
from test_media_inspections import Backend
from larenor_server.app import create_app


BASE = '/api/v1/admin/media/inspections'


def prepare(server):
    app, client, _, _ = server
    pair = ready(server)
    _, prep = create_preparation(client, pair)
    body = {'requestId': 'b' * 32, 'preparationId': prep['id'], 'expectedRevision': 1,
            'planHash': prep['plan']['planHash']}
    app.state.core.media_inspections.backend = Backend()
    return pair, prep, body


def test_real_http_contract_keeps_preparation_unchanged_across_restart(server):
    app, client, settings, _ = server
    pair, prep, body = prepare(server)
    assert client.get(BASE + '/capabilities', headers=auth(pair)).json() == {
        'inspectionConfigured': True, 'installAvailable': False}
    response = client.post(BASE, headers=auth(pair), json=body)
    assert response.status_code == 201
    record = response.json()['inspection']
    assert set(record) == {'id', 'requestId', 'preparationId', 'preparationRevision', 'coreId', 'homeId',
                           'catalogDigest', 'planHash', 'platform', 'revision', 'state', 'phase',
                           'cancelRequested', 'createdAt', 'updatedAt', 'result', 'errorCode'}
    app.state.core.media_inspections.tick()
    observed = client.get(BASE + '/' + record['id'], headers=auth(pair)).json()['inspection']
    assert observed['state'] == 'succeeded' and observed['result']['checks'][0]['status'] == 'failed'
    assert observed['result']['planHash'] == prep['plan']['planHash']
    assert client.get('/api/v1/admin/media/preparations/' + prep['id'], headers=auth(pair)).json() == {'preparation': prep}
    with TestClient(create_app(settings)) as reopened:
        assert reopened.get(BASE + '/' + record['id'], headers=auth(pair)).json() == {'inspection': observed}
        assert reopened.post(BASE, headers=auth(pair), json=body).json() == {'inspection': observed}
        assert reopened.get(BASE, headers=auth(pair)).json() == {'inspections': [observed], 'nextBefore': None}
        assert reopened.get(BASE + '/capabilities', headers=auth(pair)).json()['inspectionConfigured'] is False


def test_routes_require_current_ready_admin_and_allow_admin_history_and_cancel(server):
    _, client, _, _ = server
    pair, _, body = prepare(server)
    record = client.post(BASE, headers=auth(pair), json=body).json()['inspection']
    create_user(client, pair, 'viewer', 'member')
    member = activate(client, 'viewer')
    create_user(client, pair, 'newadmin', 'admin')
    initial = login(client, 'newadmin', TEMPORARY).json()
    for headers, status in (({}, 401), (auth(member), 403), (auth(initial), 403)):
        for method, path, payload in (('GET', BASE, None), ('GET', BASE + '/capabilities', None),
                                      ('GET', BASE + '/' + record['id'], None), ('POST', BASE, body),
                                      ('POST', BASE + '/' + record['id'] + '/cancel', {'expectedRevision': 1})):
            assert client.request(method, path, headers=headers, json=payload).status_code == status
    other = activate(client, 'newadmin')
    assert client.post('/api/v1/auth/logout', headers=auth(pair)).status_code == 204
    assert client.get(BASE + '/' + record['id'], headers=auth(other)).status_code == 200
    cancelled = client.post(BASE + '/' + record['id'] + '/cancel', headers=auth(other),
                            json={'expectedRevision': 1}).json()['inspection']
    assert cancelled['state'] == 'cancelled'
    assert client.post(BASE, headers=auth(pair), json=body).status_code == 401


@pytest.mark.parametrize('change', [{'extra': 'secret-sentinel'}, {'requestId': 'X' * 32},
                                  {'expectedRevision': True}, {'expectedRevision': 1.0},
                                  {'expectedRevision': 0}, {'planHash': 'secret-sentinel'},
                                  {'preparationId': 'secret-sentinel'}])
def test_invalid_requests_do_not_echo_input(server, change):
    _, client, _, _ = server
    pair, _, body = prepare(server)
    response = client.post(BASE, headers=auth(pair), json=body | change)
    assert response.status_code == 400 and response.json()['error']['code'] == 'invalid_request'
    assert 'secret-sentinel' not in response.text
    assert client.get(BASE, headers=auth(pair)).json()['inspections'] == []


@pytest.mark.parametrize('query', ['limit=0', 'limit=11', 'before=0', 'before=9223372036854775808'])
def test_paging_is_bounded_at_http_boundary(server, query):
    pair, _, _ = prepare(server)
    assert server[1].get(BASE + '?' + query, headers=auth(pair)).status_code == 400


def test_unconfigured_new_request_is_unavailable_without_receipt(server):
    app, client, _, _ = server
    pair, _, body = prepare(server)
    app.state.core.media_inspections.backend = None
    response = client.post(BASE, headers=auth(pair), json=body)
    assert response.status_code == 503 and response.json()['error']['code'] == 'plugin_worker_unavailable'
    assert client.get(BASE, headers=auth(pair)).json()['inspections'] == []
