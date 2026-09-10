"""Secret-free provider onboarding intents over Music Assistant setup flows."""

import json

import pytest
from fastapi.testclient import TestClient

from conftest import auth
from larenor_server.app import create_app
from larenor_server.errors import ApiError
from larenor_server.plugins.music_provider_setup_models import (
    ProviderSetupDiscovery, ProviderSetupEntry, ProviderSetupWorkerResult,
)
from test_music_assistant_core_wiring import (
    authenticated_peer, installed, readback,
)


BASE = '/api/v1/admin/media/music-assistant/providers'
FLOW = 'private-upstream-flow-id'
OAUTH = 'https://accounts.spotify.com/authorize?state=private-state'


def ready_core(server):
    app, _client, _, _ = server
    pair, installation_id, installation_revision = installed(server)
    authenticated_peer(server, pair, 'home_assistant')
    authenticated_peer(server, pair, 'jellyfin')
    app.state.core.music_assistant_core.record_authenticated_readback(
        installation_id, installation_revision, readback())
    return pair, installation_id, installation_revision


def create_setup(server, domain='spotify', request='a' * 32):
    _app, client, _, _ = server
    pair, installation_id, installation_revision = ready_core(server)
    response = client.post(BASE, headers=auth(pair), json={
        'requestId': request,
        'installationId': installation_id,
        'expectedInstallationRevision': installation_revision,
        'providerDomain': domain,
    })
    assert response.status_code == 201, response.text
    return pair, response.json()['setup']


def external(domain, step='authenticate', url=OAUTH):
    return ProviderSetupDiscovery(
        providerDomain=domain, flowId=FLOW, stepId=step,
        kind='external', externalUrl=url, expiresAt=1788610200,
        entries=[])


def form(domain, step, entries):
    return ProviderSetupDiscovery(
        providerDomain=domain, flowId=FLOW, stepId=step, kind='form',
        externalUrl=None, expiresAt=1788610200, entries=entries)


def test_capabilities_publish_exact_reviewed_domains_and_interaction_boundaries(server):
    _app, client, _, _ = server
    pair, _, _ = ready_core(server)
    response = client.get(BASE + '/capabilities', headers=auth(pair))
    assert response.status_code == 200
    assert response.json() == {
        'installAvailable': False,
        'setupEngine': 'music_assistant_setup_flow',
        'providers': [
            {'providerDomain': 'spotify', 'name': 'Spotify', 'stage': 'stable',
             'multiInstance': True, 'interaction': 'oauth_and_playback_approval'},
            {'providerDomain': 'apple_music', 'name': 'Apple Music', 'stage': 'stable',
             'multiInstance': True, 'interaction': 'musickit_or_secure_manual_token'},
            {'providerDomain': 'ytmusic', 'name': 'YouTube Music', 'stage': 'beta',
             'multiInstance': True, 'interaction': 'secure_cookie_and_po_token_service'},
        ],
    }


def test_setup_intent_is_idempotent_encrypted_and_survives_restart(server):
    app, client, settings, _ = server
    pair, setup = create_setup(server)
    assert setup['state'] == 'queued'
    assert setup['nextAction'] == 'awaiting_core_discovery'
    assert setup['providerDomain'] == 'spotify'
    assert setup['installAvailable'] is False
    assert setup['interaction'] is None and setup['fields'] == []
    response = client.post(BASE, headers=auth(pair), json={
        'requestId': setup['requestId'],
        'installationId': setup['installationId'],
        'expectedInstallationRevision': setup['installationRevision'],
        'providerDomain': 'spotify'})
    assert response.json()['setup'] == setup
    with app.state.core.db.connection() as connection:
        dump = '\n'.join(connection.iterdump())
    assert 'spotify' not in dump and setup['requestId'] not in dump
    with TestClient(create_app(settings)) as restarted:
        assert restarted.get(BASE + '/' + setup['id'], headers=auth(pair)).json() == {
            'setup': setup}


@pytest.mark.parametrize(('domain', 'observation', 'interaction', 'fields'), [
    ('spotify', external('spotify'), 'open_external', []),
    ('apple_music', form('apple_music', 'user', [
        ProviderSetupEntry(key='music_user_manual_token', type='secure_string', required=False),
    ]), 'submit_form', [
        {'key': 'music_user_manual_token', 'type': 'secure_string', 'required': False},
    ]),
    ('ytmusic', form('ytmusic', 'user', [
        ProviderSetupEntry(key='username', type='string', required=True),
        ProviderSetupEntry(key='cookie', type='secure_string', required=True),
        ProviderSetupEntry(key='po_token_server_url', type='string', required=True),
    ]), 'submit_form', [
        {'key': 'username', 'type': 'string', 'required': True},
        {'key': 'cookie', 'type': 'secure_string', 'required': True},
        {'key': 'po_token_server_url', 'type': 'string', 'required': True},
    ]),
])
def test_worker_discovery_records_only_secret_free_required_action(
        server, domain, observation, interaction, fields):
    app, client, _, _ = server
    pair, setup = create_setup(server, domain)
    result = app.state.core.music_provider_setups.record_initial_discovery(
        setup['id'], setup['revision'], observation)
    assert result['state'] == 'action_required'
    assert result['nextAction'] == 'continue_in_larenor'
    assert result['interaction'] == interaction
    assert result['fields'] == fields
    response = client.get(BASE + '/' + setup['id'], headers=auth(pair))
    assert response.json()['setup'] == result
    encoded = json.dumps(response.json())
    assert FLOW not in encoded and 'private-state' not in encoded
    with app.state.core.db.connection() as connection:
        dump = '\n'.join(connection.iterdump())
    assert FLOW not in dump and 'private-state' not in dump


@pytest.mark.parametrize('domain,observation', [
    ('spotify', form('spotify', 'user', [
        ProviderSetupEntry(key='username', type='string', required=True),
    ])),
    ('apple_music', external('apple_music', step='authenticate')),
    ('ytmusic', external('ytmusic')),
    ('ytmusic', form('ytmusic', 'user', [
        ProviderSetupEntry(key='cookie', type='string', required=True),
    ])),
])
def test_unexpected_or_unsafe_upstream_capability_fails_closed(
        server, domain, observation):
    app, client, _, _ = server
    pair, setup = create_setup(server, domain)
    with pytest.raises(ApiError, match='^music_provider_capability_changed$'):
        app.state.core.music_provider_setups.record_initial_discovery(
            setup['id'], setup['revision'], observation)
    stored = client.get(BASE + '/' + setup['id'], headers=auth(pair)).json()['setup']
    assert stored['state'] == 'queued' and stored['revision'] == 1


def test_stale_music_core_or_installation_blocks_new_and_pending_setups(server):
    app, client, _, _ = server
    pair, setup = create_setup(server)
    readiness = app.state.core.music_assistant_core.get(
        app.state.core.auth.authenticate(pair['accessToken']), setup['installationId'])['readiness']
    service_id = readiness['homeAssistant']['serviceId']
    current = client.get('/api/v1/admin/services', headers=auth(pair)).json()['services']
    service = next(item for item in current if item['id'] == service_id)
    changed = client.patch('/api/v1/admin/services/' + service_id, headers=auth(pair), json={
        'expectedRevision': service['revision'], 'name': 'Changed HA',
        'baseUrl': service['baseUrl']})
    assert changed.status_code == 200
    with pytest.raises(ApiError, match='^music_assistant_not_ready$'):
        app.state.core.music_provider_setups.record_initial_discovery(
            setup['id'], 1, external('spotify'))
    response = client.post(BASE, headers=auth(pair), json={
        'requestId': 'f' * 32, 'installationId': setup['installationId'],
        'expectedInstallationRevision': setup['installationRevision'],
        'providerDomain': 'apple_music'})
    assert response.status_code == 409
    assert response.json()['error']['code'] == 'music_assistant_not_ready'


def test_public_api_never_accepts_provider_credentials_or_completes_interaction(server):
    _app, client, _, _ = server
    pair, setup = create_setup(server, 'ytmusic')
    secret = 'private-youtube-cookie'
    for method, suffix, payload in [
        ('PATCH', '/' + setup['id'], {'cookie': secret}),
        ('POST', '/' + setup['id'] + '/complete', {'token': secret}),
    ]:
        response = client.request(method, BASE + suffix, headers=auth(pair), json=payload)
        assert response.status_code in (404, 405) and secret not in response.text
    schema = client.get('/api/v1/openapi.json', headers=auth(pair)).json()
    assert secret not in json.dumps(schema)
    response = client.post(BASE, headers=auth(pair), json={
        'requestId': 'f' * 32, 'installationId': setup['installationId'],
        'expectedInstallationRevision': setup['installationRevision'],
        'providerDomain': 'ytmusic', 'cookie': secret})
    assert response.status_code == 400 and secret not in response.text


class ProviderWorker:
    def __init__(self, result):
        self.result = result
        self.calls = []

    def execute_music_provider_setup(self, action, *, deadline, gate):
        assert gate() is True
        self.calls.append(action)
        return self.result


def test_validated_form_submission_crosses_private_worker_and_finishes_only_after_readback(server):
    app, client, _, _ = server
    pair, setup = create_setup(server, 'ytmusic')
    discovered = app.state.core.music_provider_setups.record_initial_discovery(
        setup['id'], setup['revision'], form('ytmusic', 'user', [
            ProviderSetupEntry(key='username', type='string', required=True),
            ProviderSetupEntry(key='cookie', type='secure_string', required=True),
            ProviderSetupEntry(key='po_token_server_url', type='string', required=True),
        ]))
    worker = ProviderWorker(ProviderSetupWorkerResult(
        state='ready', providerDomain='ytmusic', providerInstanceId='ytmusic--fixture'))
    app.state.core.music_provider_setups.backend = worker
    secret = 'SAPISID=private-youtube-cookie'
    response = client.post(BASE + '/' + setup['id'] + '/responses', headers=auth(pair), json={
        'expectedRevision': discovered['revision'], 'stepId': 'user',
        'values': {'username': 'family', 'cookie': secret,
                   'po_token_server_url': 'http://127.0.0.1:8096'},
    })
    assert response.status_code == 200, response.text
    final = response.json()['setup']
    assert final['state'] == 'ready' and final['nextAction'] == 'none'
    assert final['providerInstanceId'] == 'ytmusic--fixture'
    assert final['installAvailable'] is False
    assert worker.calls[0].command == 'submit'
    assert worker.calls[0].values['cookie'] == secret
    assert 'private-mass-token' not in repr(worker.calls[0])
    encoded = json.dumps(response.json())
    assert secret not in encoded and FLOW not in encoded
    with app.state.core.db.connection() as connection:
        dump = '\n'.join(connection.iterdump())
    assert secret not in dump and FLOW not in dump


def test_form_submission_rejects_wrong_fields_and_stale_or_expired_flow_without_worker(server):
    app, client, _, clock = server
    pair, setup = create_setup(server, 'apple_music')
    discovered = app.state.core.music_provider_setups.record_initial_discovery(
        setup['id'], 1, form('apple_music', 'app_token', [
            ProviderSetupEntry(key='music_app_token', type='secure_string', required=True)]))
    worker = ProviderWorker(ProviderSetupWorkerResult(
        state='ready', providerDomain='apple_music', providerInstanceId='apple_music--fixture'))
    app.state.core.music_provider_setups.backend = worker
    for body in [
        {'expectedRevision': discovered['revision'], 'stepId': 'wrong',
         'values': {'music_app_token': 'secret'}},
        {'expectedRevision': discovered['revision'], 'stepId': 'app_token',
         'values': {'music_app_token': 'secret', 'extra': 'no'}},
        {'expectedRevision': 1, 'stepId': 'app_token',
         'values': {'music_app_token': 'secret'}},
    ]:
        response = client.post(BASE + '/' + setup['id'] + '/responses',
                               headers=auth(pair), json=body)
        assert response.status_code in (400, 409)
    clock.now = 1788610201
    response = client.post(BASE + '/' + setup['id'] + '/responses', headers=auth(pair), json={
        'expectedRevision': discovered['revision'], 'stepId': 'app_token',
        'values': {'music_app_token': 'secret'}})
    assert response.status_code == 409
    assert response.json()['error']['code'] == 'music_provider_setup_expired'
    assert worker.calls == []


def test_external_callback_resume_and_explicit_cancel_are_revision_bound(server):
    app, client, _, _ = server
    pair, setup = create_setup(server)
    discovered = app.state.core.music_provider_setups.record_initial_discovery(
        setup['id'], 1, external('spotify'))
    worker = ProviderWorker(ProviderSetupWorkerResult(
        state='ready', providerDomain='spotify', providerInstanceId='spotify--fixture'))
    app.state.core.music_provider_setups.backend = worker
    response = client.post(BASE + '/' + setup['id'] + '/resume', headers=auth(pair), json={
        'expectedRevision': discovered['revision']})
    assert response.status_code == 200
    assert worker.calls[0].command == 'resume'

    _pair2, pending = create_setup(server, 'spotify', request='b' * 32)
    response = client.post(BASE + '/' + pending['id'] + '/cancel', headers=auth(pair), json={
        'expectedRevision': pending['revision']})
    assert response.status_code == 200
    assert response.json()['setup']['state'] == 'cancelled'
    assert response.json()['setup']['nextAction'] == 'none'
    stale = client.post(BASE + '/' + pending['id'] + '/cancel', headers=auth(pair), json={
        'expectedRevision': pending['revision']})
    assert stale.status_code == 409
