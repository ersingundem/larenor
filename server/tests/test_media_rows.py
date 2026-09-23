"""Account-bound recent and resume Core API."""

import json

from conftest import auth
from larenor_server.plugins.jellyfin_media_rows_executor import (
    JellyfinMediaRowsExecutionError,
)
from larenor_server.plugins.media_rows_models import (
    MediaRowItem,
    MediaRowsReadback,
)
from test_admin import activate
from test_admin import create as create_user
from test_media_service_bootstraps import (
    BASE as BOOTSTRAPS,
    BootstrapBackend,
    installed,
    request as bootstrap_request,
)


BASE = '/api/v1/media/rows/read'
TARGET = '/api/v1/media/rows/target'


class RowsWorker:
    def __init__(self):
        self.calls = []
        self.change = None
        self.failure = None
        self.malformed = False

    def read_media_rows(self, private, *, deadline, gate):
        assert deadline > 0 and gate() is True
        self.calls.append(private)
        if self.failure is not None:
            raise self.failure
        if self.malformed:
            return {'private': 'malformed-worker-detail'}
        if self.change is not None:
            self.change()
        return MediaRowsReadback(
            revision=17,
            recent=[MediaRowItem(
                itemId='5' * 32,
                title='Arrival',
                mediaKind='movie',
                addedAt=1788609000,
                runtimeSeconds=6960,
                positionSeconds=0,
            )],
            resume=[MediaRowItem(
                itemId='6' * 32,
                title='Interstellar',
                mediaKind='movie',
                addedAt=1788608000,
                runtimeSeconds=10140,
                positionSeconds=1800,
            )],
        )


def configured(server):
    app, client, _, _ = server
    pair, installation = installed(server)
    created = client.post(
        BOOTSTRAPS,
        headers=auth(pair),
        json=bootstrap_request(installation),
    )
    assert created.status_code == 201
    app.state.core.media_service_bootstraps.backend = BootstrapBackend()
    terminal = app.state.core.media_service_bootstraps.tick()['bootstrap']
    assert terminal['state'] == 'wiring_partial'
    worker = RowsWorker()
    app.state.core.media_rows.backend = worker
    body = {
        'requestId': 'e' * 32,
        'installationId': installation['id'],
        'expectedInstallationRevision': installation['revision'],
    }
    return pair, installation, worker, body


def target_request(body):
    return {
        'installationId': body['installationId'],
        'expectedInstallationRevision': body['expectedInstallationRevision'],
    }


def test_ready_owner_reads_secret_free_target_without_worker(server):
    _app, client, _, _ = server
    pair, installation, worker, body = configured(server)

    response = client.post(
        TARGET,
        headers=auth(pair),
        json=target_request(body),
    )

    assert response.status_code == 200, response.text
    assert response.json() == {
        'schemaVersion': 1,
        'installationId': installation['id'],
        'installationRevision': installation['revision'],
        'bindingRevision': 1,
    }
    serialized = response.text.lower()
    assert all(word not in serialized for word in (
        'apikey', 'userid', 'token', 'password', 'bootstrap', 'endpoint', 'url'))
    assert '1' * 32 not in response.text and 'c' * 32 not in response.text
    assert worker.calls == []


def test_target_stale_or_unbound_authority_is_static_and_skips_worker(server):
    _app, client, _, _ = server
    pair, _installation, worker, body = configured(server)

    stale = client.post(
        TARGET,
        headers=auth(pair),
        json=target_request(body) | {
            'expectedInstallationRevision':
            body['expectedInstallationRevision'] + 1,
        },
    )
    assert stale.status_code == 409
    assert stale.json()['error']['code'] == 'media_rows_authority_changed'
    assert body['installationId'] not in stale.text

    create_user(client, pair)
    member = activate(client, 'member')
    unbound = client.post(
        TARGET,
        headers=auth(member),
        json=target_request(body),
    )
    assert unbound.status_code == 409
    assert unbound.json()['error']['code'] == 'media_rows_authority_changed'
    assert body['installationId'] not in unbound.text
    assert worker.calls == []


def test_target_body_rejects_private_and_read_fields_without_worker(server):
    _app, client, _, _ = server
    pair, _installation, worker, body = configured(server)

    for field, value in (
        ('requestId', 'e' * 32),
        ('bindingRevision', 1),
        ('userId', '1' * 32),
        ('apiKey', 'c' * 32),
    ):
        response = client.post(
            TARGET,
            headers=auth(pair),
            json=target_request(body) | {field: value},
        )
        assert response.status_code == 400
        if type(value) is str:
            assert value not in response.text
    assert worker.calls == []


def test_ready_owner_reads_bounded_recent_and_resume_without_private_identity(server):
    app, client, _, _ = server
    pair, installation, worker, body = configured(server)

    response = client.post(BASE, headers=auth(pair), json=body)

    assert response.status_code == 200, response.text
    payload = response.json()
    assert payload['requestId'] == body['requestId']
    assert payload['installationId'] == installation['id']
    assert payload['installationRevision'] == installation['revision']
    assert payload['bindingRevision'] == 1
    assert payload['rows']['revision'] == 17
    assert payload['rows']['recent'][0]['title'] == 'Arrival'
    assert payload['rows']['resume'][0]['positionSeconds'] == 1800
    private = worker.calls[0]
    assert private.bindingRevision == 1 and private.bootstrapRevision == 3
    serialized = json.dumps(payload).lower()
    assert all(word not in serialized for word in (
        'apikey', 'userid', 'token', 'password', 'endpoint', 'url'))
    assert 'c' * 32 not in repr(private)


def test_stale_installation_or_unbound_account_never_reaches_worker(server):
    app, client, _, _ = server
    pair, _installation, worker, body = configured(server)

    stale = client.post(
        BASE,
        headers=auth(pair),
        json=body | {
            'requestId': 'f' * 32,
            'expectedInstallationRevision':
            body['expectedInstallationRevision'] + 1,
        },
    )
    assert stale.status_code == 409
    assert stale.json()['error']['code'] == 'media_rows_authority_changed'

    create_user(client, pair)
    member = activate(client, 'member')
    unbound = client.post(
        BASE,
        headers=auth(member),
        json=body | {'requestId': 'a' * 32},
    )
    assert unbound.status_code == 409
    assert unbound.json()['error']['code'] == 'media_rows_authority_changed'
    assert worker.calls == []


def test_client_cannot_select_upstream_user_or_credential(server):
    _app, client, _, _ = server
    pair, _installation, worker, body = configured(server)

    for field, value in (
        ('userId', '1' * 32),
        ('apiKey', 'c' * 32),
        ('bindingRevision', 1),
    ):
        response = client.post(
            BASE,
            headers=auth(pair),
            json=body | {field: value},
        )
        assert response.status_code == 400
        if type(value) is str:
            assert value not in response.text
    assert worker.calls == []


def test_authority_loss_after_worker_read_discards_rows(server):
    _app, client, _, _ = server
    pair, _installation, worker, body = configured(server)
    worker.change = lambda: client.post(
        '/api/v1/auth/logout', headers=auth(pair))

    response = client.post(BASE, headers=auth(pair), json=body)

    assert response.status_code == 409
    assert response.json()['error']['code'] == 'media_rows_authority_changed'
    assert len(worker.calls) == 1
    assert 'Arrival' not in response.text


def test_private_worker_failure_is_static_and_never_exposes_detail(server):
    _app, client, _, _ = server
    pair, _installation, worker, body = configured(server)
    worker.failure = JellyfinMediaRowsExecutionError(
        'jellyfin_media_rows_endpoint_changed')

    response = client.post(BASE, headers=auth(pair), json=body)

    assert response.status_code == 503
    assert response.json()['error']['code'] == 'media_rows_worker_unavailable'
    assert 'endpoint_changed' not in response.text
    assert len(worker.calls) == 1


def test_malformed_worker_result_is_unavailable_not_authority_drift(server):
    _app, client, _, _ = server
    pair, _installation, worker, body = configured(server)
    worker.malformed = True

    response = client.post(BASE, headers=auth(pair), json=body)

    assert response.status_code == 503
    assert response.json()['error']['code'] == 'media_rows_worker_unavailable'
    assert 'malformed-worker-detail' not in response.text
    assert len(worker.calls) == 1


def test_deadline_expiry_after_valid_result_is_worker_unavailable(
    server, monkeypatch
):
    app, client, _, _ = server
    pair, _installation, worker, body = configured(server)
    readings = iter((100.0, 106.0))
    monkeypatch.setattr(
        app.state.core.media_rows, '_monotonic', lambda: next(readings))

    response = client.post(BASE, headers=auth(pair), json=body)

    assert response.status_code == 503
    assert response.json()['error']['code'] == 'media_rows_worker_unavailable'
    assert len(worker.calls) == 1
