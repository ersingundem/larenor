"""Revision-bound provider configuration previews with unavailable effects."""

import pytest

from conftest import auth, bootstrap_password, login, ready
from larenor_server.app import create_app
from larenor_server.errors import StartupError
from larenor_server.plugins.music_provider_setup_models import (
    ProviderSetupDiscovery, ProviderSetupWorkerResult,
)
from test_admin import activate, create as create_user
from test_music_assistant_core_wiring import authenticated_peer, installed, readback


BASE = '/api/v1/admin/media/music-assistant/provider-commands'


class Worker:
    def execute_music_provider_setup(self, _action, *, deadline, gate):
        assert gate()
        return ProviderSetupWorkerResult(
            state='ready', providerDomain='spotify',
            providerInstanceId='spotify--fixture')


def ready_provider(server, domain='spotify', request_id='a' * 32):
    app, client, _, _ = server
    pair, installation_id, installation_revision = installed(server)
    authenticated_peer(server, pair, 'home_assistant')
    authenticated_peer(server, pair, 'jellyfin')
    app.state.core.music_assistant_core.record_authenticated_readback(
        installation_id, installation_revision, readback())
    created = client.post(
        '/api/v1/admin/media/music-assistant/providers', headers=auth(pair),
        json={'requestId': request_id, 'installationId': installation_id,
              'expectedInstallationRevision': installation_revision,
              'providerDomain': domain}).json()['setup']
    if domain != 'spotify':
        with app.state.core.db.transaction() as connection:
            row = connection.execute(
                'SELECT * FROM music_provider_setups WHERE id=?',
                (created['id'],)).fetchone()
            stored = app.state.core.music_provider_setups._decode(row)
            app.state.core.music_provider_setups._save(
                connection, row, stored.model_copy(
                    update={'status': 'ready',
                            'providerInstanceId': domain + '--fixture'}))
            saved = connection.execute(
                'SELECT * FROM music_provider_setups WHERE id=?',
                (created['id'],)).fetchone()
            return pair, app.state.core.music_provider_setups._public(
                saved, app.state.core.music_provider_setups._decode(saved))
    discovered = app.state.core.music_provider_setups.record_initial_discovery(
        created['id'], 1, ProviderSetupDiscovery(
            providerDomain='spotify', flowId='private-flow',
            stepId='authenticate', kind='external',
            externalUrl='https://accounts.spotify.com/authorize?state=private',
            expiresAt=1788610200, entries=[]))
    app.state.core.music_provider_setups.backend = Worker()
    ready = client.post(
        f'/api/v1/admin/media/music-assistant/providers/{created["id"]}/resume',
        headers=auth(pair), json={'expectedRevision': discovered['revision']}
    ).json()['setup']
    return pair, ready


def test_preview_and_confirm_are_exact_idempotent_and_effect_unavailable(server):
    _app, client, _, _ = server
    pair, provider = ready_provider(server)
    body = {
        'requestId': 'b' * 32,
        'installationId': provider['installationId'],
        'expectedInstallationRevision': provider['installationRevision'],
        'providerSetupId': provider['id'],
        'expectedProviderRevision': provider['revision'],
        'providerDomain': 'spotify', 'command': 'disable', 'settings': {},
    }
    response = client.post(BASE + '/previews', headers=auth(pair), json=body)
    assert response.status_code == 201, response.text
    preview = response.json()['preview']
    assert preview['effectAvailable'] is False
    assert preview['installAvailable'] is False
    assert preview['blockers'] == ['effect_unavailable']
    assert preview['settings'] == {}
    confirm = {
        'requestId': 'c' * 32, 'previewId': preview['id'],
        'expectedPreviewRevision': preview['revision'],
        'planHash': preview['planHash'],
    }
    first = client.post(BASE, headers=auth(pair), json=confirm)
    second = client.post(BASE, headers=auth(pair), json=confirm)
    assert first.status_code == 201 and second.json() == first.json()
    command = first.json()['command']
    assert command['state'] == 'blocked'
    assert command['errorCode'] == 'effect_unavailable'
    assert command['providerSetupId'] == provider['id']
    assert command['providerRevision'] == provider['revision']


def test_preview_rejects_revision_drift_and_secret_shaped_settings(server):
    _app, client, _, _ = server
    pair, provider = ready_provider(server)
    base = {
        'requestId': 'b' * 32,
        'installationId': provider['installationId'],
        'expectedInstallationRevision': provider['installationRevision'],
        'providerSetupId': provider['id'],
        'expectedProviderRevision': provider['revision'],
        'providerDomain': 'spotify', 'command': 'enable', 'settings': {},
    }
    for changed in [
        base | {'expectedProviderRevision': provider['revision'] - 1},
        base | {'settings': {'token': 'secret'}},
        base | {'cookie': 'secret'},
    ]:
        response = client.post(BASE + '/previews', headers=auth(pair), json=changed)
        assert response.status_code in (400, 409)
        assert 'secret' not in response.text


def command_body(provider, *, request_id='b' * 32, command='disable'):
    return {
        'requestId': request_id,
        'installationId': provider['installationId'],
        'expectedInstallationRevision': provider['installationRevision'],
        'providerSetupId': provider['id'],
        'expectedProviderRevision': provider['revision'],
        'providerDomain': provider['providerDomain'],
        'command': command, 'settings': {},
    }


def preview(client, pair, provider, **changes):
    body = command_body(provider) | changes
    response = client.post(BASE + '/previews', headers=auth(pair), json=body)
    assert response.status_code == 201, response.text
    return response.json()['preview']


@pytest.mark.parametrize('domain', ['apple_music', 'ytmusic'])
def test_reviewed_apple_and_youtube_provider_intents_remain_effect_free(
        server, domain):
    _app, client, _, _ = server
    pair, provider = ready_provider(server, domain)
    result = preview(client, pair, provider)
    assert result['providerDomain'] == domain
    assert result['effectAvailable'] is False
    assert result['blockers'] == ['effect_unavailable']


def test_command_routes_reject_anonymous_member_and_initial_password(server):
    _app, client, settings, _ = server
    changing = login(client, 'admin', bootstrap_password(settings)).json()
    assert client.post(BASE + '/previews', headers=auth(changing), json={}).status_code == 403

    admin, provider = ready_provider(server)
    create_user(client, admin, 'provider-reader')
    member = activate(client, 'provider-reader')
    body = command_body(provider)
    assert client.post(BASE + '/previews', json=body).status_code == 401
    assert client.post(
        BASE + '/previews', headers=auth(member), json=body).status_code == 403


def test_expired_preview_is_rejected_then_cleaned_before_reusing_capacity(server):
    app, client, _, clock = server
    pair, provider = ready_provider(server)
    expired = preview(client, pair, provider)
    clock.now += 601
    rejected = client.post(BASE, headers=auth(pair), json={
        'requestId': 'c' * 32, 'previewId': expired['id'],
        'expectedPreviewRevision': 1, 'planHash': expired['planHash'],
    })
    assert rejected.status_code == 409
    assert rejected.json()['error']['code'] == 'music_provider_preview_invalid'
    current = preview(
        client, pair, provider, requestId='d' * 32, command='enable')
    with app.state.core.db.connection() as connection:
        ids = {row['id'] for row in connection.execute(
            'SELECT id FROM music_provider_command_previews')}
    assert ids == {current['id']}


def test_preview_and_immutable_command_quotas_fail_closed(server, monkeypatch):
    from larenor_server.plugins import music_provider_commands as authority

    monkeypatch.setattr(authority, 'MAX_ACTIVE_PREVIEWS', 1)
    monkeypatch.setattr(authority, 'MAX_COMMANDS', 1)
    _app, client, _, clock = server
    pair, provider = ready_provider(server)
    first = preview(client, pair, provider)
    denied = client.post(
        BASE + '/previews', headers=auth(pair),
        json=command_body(provider, request_id='d' * 32, command='enable'))
    assert denied.status_code == 409
    assert denied.json()['error']['code'] == 'music_provider_preview_limit_reached'

    clock.now += 601
    second = preview(
        client, pair, provider, requestId='d' * 32, command='enable')
    confirmed = client.post(BASE, headers=auth(pair), json={
        'requestId': 'e' * 32, 'previewId': second['id'],
        'expectedPreviewRevision': 1, 'planHash': second['planHash'],
    })
    assert confirmed.status_code == 201
    third = preview(client, pair, provider, requestId='f' * 32)
    denied = client.post(BASE, headers=auth(pair), json={
        'requestId': '1' * 32, 'previewId': third['id'],
        'expectedPreviewRevision': 1, 'planHash': third['planHash'],
    })
    assert denied.status_code == 409
    assert denied.json()['error']['code'] == 'music_provider_command_limit_reached'
    replay = client.post(BASE, headers=auth(pair), json={
        'requestId': 'e' * 32, 'previewId': second['id'],
        'expectedPreviewRevision': 1, 'planHash': second['planHash'],
    })
    assert replay.status_code == 201
    assert replay.json() == confirmed.json()
    assert first['id'] != second['id']


def test_preview_and_confirm_are_bound_to_the_exact_session_family(server):
    _app, client, _, _ = server
    pair, provider = ready_provider(server)
    saved = preview(client, pair, provider)
    other_family = login(
        client, 'admin', 'Synthetic new password 2026', 'DeX').json()
    denied = client.post(BASE, headers=auth(other_family), json={
        'requestId': 'c' * 32, 'previewId': saved['id'],
        'expectedPreviewRevision': 1, 'planHash': saved['planHash'],
    })
    assert denied.status_code == 409
    assert denied.json()['error']['code'] == 'music_provider_preview_invalid'
    conflict = client.post(
        BASE + '/previews', headers=auth(other_family),
        json=command_body(provider))
    assert conflict.status_code == 409
    assert conflict.json()['error']['code'] == 'music_provider_command_conflict'


def test_preview_request_id_is_exactly_idempotent(server):
    _app, client, _, _ = server
    pair, provider = ready_provider(server)
    first = preview(client, pair, provider)
    assert preview(client, pair, provider) == first
    conflict = client.post(
        BASE + '/previews', headers=auth(pair),
        json=command_body(provider, command='enable'))
    assert conflict.status_code == 409
    assert conflict.json()['error']['code'] == 'music_provider_command_conflict'


def test_schema_shape_tamper_blocks_core_startup(server):
    app, _client, settings, _ = server
    ready(server)
    with app.state.core.db.transaction() as connection:
        connection.execute(
            'ALTER TABLE music_provider_commands ADD COLUMN unexpected TEXT')
    with pytest.raises(
            StartupError, match='^music_provider_commands_schema_unsupported$'):
        create_app(settings)
