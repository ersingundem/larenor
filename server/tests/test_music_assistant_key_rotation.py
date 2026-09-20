"""TDD contract for private, restart-safe Music Assistant key rotation."""

from dataclasses import replace

import pytest
from fastapi.testclient import TestClient

from larenor_server.app import create_app
from larenor_server.errors import ApiError, StartupError
from larenor_server.plugins.music_assistant_core_models import (
    AuthenticatedMusicAssistantKeyRotationReadback,
    AuthenticatedMusicAssistantReadback,
    MusicAssistantKeyRotationRequest,
)
from test_music_assistant_core_wiring import TOKEN
from test_music_provider_commands import ready_provider


NEW_TOKEN = 'new-synthetic-music-assistant-token-never-public'


def rotation(server, request_id='d' * 32):
    app, _client, _, _ = server
    pair, provider = ready_provider(server)
    actor = app.state.core.auth.authenticate(pair['accessToken'])
    context = app.state.core.context
    return pair, actor, provider, MusicAssistantKeyRotationRequest(
        requestId=request_id,
        coreId=context.coreId,
        homeId=context.homeId,
        installationId=provider['installationId'],
        expectedInstallationRevision=provider['installationRevision'],
        expectedWorkerRevision=1,
        providerSetupId=provider['id'],
        expectedProviderRevision=provider['revision'],
        providerInstanceId=provider['providerInstanceId'],
    )


def observed(request, *, retired=False):
    return AuthenticatedMusicAssistantKeyRotationReadback(
        requestId=request.requestId,
        readback=AuthenticatedMusicAssistantReadback(
            token=NEW_TOKEN, serverId='mass-fixture', serverVersion='2.8.0',
            schemaVersion=29),
        previousTokenRetired=retired,
    )


class SuccessfulWorker:
    def __init__(self, core, request):
        self.core, self.request = core, request
        self.calls = []

    def prepare_music_assistant_key_rotation(self, action, *, deadline, gate):
        assert gate() and action.request == self.request
        assert action.currentToken == TOKEN and action.replacementToken is None
        self.calls.append('prepare')
        with self.core.db.connection() as connection:
            row = connection.execute(
                'SELECT * FROM music_assistant_core WHERE installation_id=?',
                (self.request.installationId,)).fetchone()
            assert self.core._decode(row).token == TOKEN
        return observed(self.request)

    def retire_music_assistant_key(self, action, *, deadline, gate):
        assert gate() and action.request == self.request
        assert action.currentToken == TOKEN
        assert action.replacementToken == NEW_TOKEN
        self.calls.append('retire')
        with self.core.db.connection() as connection:
            row = connection.execute(
                'SELECT * FROM music_assistant_core WHERE installation_id=?',
                (self.request.installationId,)).fetchone()
            assert row['revision'] == 2
            assert self.core._decode(row).token == NEW_TOKEN
        return observed(self.request, retired=True)

    def reconcile_music_assistant_key_rotation(self, *_args, **_kwargs):
        raise AssertionError('reconcile is not needed for a certain response')


def test_rotation_is_atomic_and_exactly_bound_to_core_session_worker_and_provider(server):
    app, client, _, _ = server
    pair, actor, provider, request = rotation(server)
    worker = SuccessfulWorker(app.state.core.music_assistant_core, request)

    receipt = app.state.core.music_assistant_core.rotate_key(
        actor, request, worker)['rotation']

    assert worker.calls == ['prepare', 'retire']
    assert receipt == {
        'requestId': request.requestId,
        'installationId': request.installationId,
        'installationRevision': request.expectedInstallationRevision,
        'workerRevision': 2,
        'providerSetupId': provider['id'],
        'providerRevision': provider['revision'],
        'providerInstanceId': provider['providerInstanceId'],
        'state': 'retired',
    }
    public = client.get(
        '/api/v1/admin/media/music-assistant/' + request.installationId,
        headers={'Authorization': 'Bearer ' + pair['accessToken']})
    encoded = public.text + repr(receipt) + repr(observed(request))
    assert public.json()['readiness']['revision'] == 2
    assert TOKEN not in encoded and NEW_TOKEN not in encoded


class UncertainWorker:
    def __init__(self, request):
        self.request = request
        self.prepared = False
        self.retired = False
        self.calls = []

    def prepare_music_assistant_key_rotation(self, _action, *, deadline, gate):
        assert gate()
        self.prepared = True
        self.calls.append('prepare-lost')
        raise TimeoutError('synthetic lost response')

    def retire_music_assistant_key(self, _action, *, deadline, gate):
        assert gate()
        self.retired = True
        self.calls.append('retire-lost')
        raise TimeoutError('synthetic lost response')

    def reconcile_music_assistant_key_rotation(self, action, *, deadline, gate):
        assert gate()
        self.calls.append('reconcile-' + action.phase)
        if action.phase == 'preparing' and self.prepared:
            return observed(self.request)
        if action.phase == 'activated' and self.retired:
            return observed(self.request, retired=True)
        return None


def test_lost_responses_restart_and_replay_reconcile_without_duplicate_rotation(server):
    app, _client, settings, _ = server
    pair, actor, _provider, request = rotation(server)
    worker = UncertainWorker(request)
    with pytest.raises(ApiError, match='^music_assistant_key_rotation_uncertain$'):
        app.state.core.music_assistant_core.rotate_key(actor, request, worker)

    with TestClient(create_app(settings)) as restarted:
        current = restarted.app.state.core.auth.authenticate(pair['accessToken'])
        with pytest.raises(ApiError, match='^music_assistant_key_rotation_uncertain$'):
            restarted.app.state.core.music_assistant_core.rotate_key(
                current, request, worker)
    with TestClient(create_app(settings)) as restarted:
        current = restarted.app.state.core.auth.authenticate(pair['accessToken'])
        first = restarted.app.state.core.music_assistant_core.rotate_key(
            current, request, worker)
        replay = restarted.app.state.core.music_assistant_core.rotate_key(
            current, request, worker)
        assert first == replay
        assert first['rotation']['state'] == 'retired'
    assert worker.calls == [
        'prepare-lost', 'reconcile-preparing', 'retire-lost',
        'reconcile-activated',
    ]


class HoldingWorker:
    def prepare_music_assistant_key_rotation(self, *_args, **_kwargs):
        raise TimeoutError('hold journal open')

    def retire_music_assistant_key(self, *_args, **_kwargs):
        raise AssertionError()

    def reconcile_music_assistant_key_rotation(self, *_args, **_kwargs):
        return None


def test_rollback_tamper_foreign_session_and_concurrent_rotation_fail_closed(server):
    app, _client, settings, _ = server
    _pair, actor, provider, request = rotation(server)
    worker = HoldingWorker()

    for changed in (
        request.model_copy(update={'coreId': 'f' * 32}),
        request.model_copy(update={'homeId': 'f' * 32}),
        request.model_copy(update={'expectedWorkerRevision': 2}),
        request.model_copy(update={'expectedProviderRevision': provider['revision'] + 1}),
        request.model_copy(update={'providerInstanceId': 'foreign-provider'}),
    ):
        with pytest.raises(ApiError):
            app.state.core.music_assistant_core.rotate_key(actor, changed, worker)
    with pytest.raises(ApiError, match='^invalid_session$'):
        app.state.core.music_assistant_core.rotate_key(
            replace(actor, family_id='f' * 32), request, worker)

    with pytest.raises(ApiError, match='^music_assistant_key_rotation_uncertain$'):
        app.state.core.music_assistant_core.rotate_key(actor, request, worker)
    with pytest.raises(ApiError, match='^music_assistant_key_rotation_conflict$'):
        app.state.core.music_assistant_core.rotate_key(
            actor, request.model_copy(update={'requestId': 'e' * 32}), worker)

    with app.state.core.db.transaction() as connection:
        dump = '\n'.join(connection.iterdump())
        assert TOKEN not in dump and NEW_TOKEN not in dump
        connection.execute(
            'UPDATE music_assistant_key_rotations SET ciphertext=? WHERE request_id=?',
            (b'tampered', request.requestId))
    with pytest.raises(StartupError, match='^invalid_music_assistant_core_storage$'):
        create_app(settings)
