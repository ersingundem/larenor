"""Authenticated, revision-bound Music Assistant player and queue control."""

import re
import secrets
import time

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from pydantic import ValidationError

from ..admin.service import utc
from ..errors import ApiError, StartupError
from .music_playback_models import (
    MusicCatalogWorkerResult, MusicManagerProvider, MusicManagerState,
    MusicPlaybackCommandRequest, MusicPlaybackReadback, MusicPlaybackState,
    MusicPlaybackWorkerResult, PrivateMusicPlaybackAction,
    PrivateMusicPlaybackAuthority, PrivateMusicCatalogAction,
    RefreshMusicPlaybackRequest, SearchMusicCatalogRequest,
    _StoredMusicPlayback, _StoredPlaybackCommand,
)


MAX_CIPHERTEXT = 262144
_OP_CAPABILITY = {
    'play': 'play', 'pause': 'pause', 'seek': 'seek', 'stop': 'stop',
    'next': 'next_previous', 'previous': 'next_previous',
    'volume': 'volume_set', 'mute': 'volume_mute',
    'queue_add': 'queue', 'queue_replace': 'queue', 'queue_clear': 'queue',
}


class MusicPlaybackManagement:
    def __init__(self, db, auth, settings, key, music_core, providers,
                 backend=None):
        self.db, self.auth, self.settings = db, auth, settings
        self.music_core, self.providers, self.backend = music_core, providers, backend
        self._cipher = AESGCM(key)

    @staticmethod
    def _identity(value):
        if type(value) is not str or re.fullmatch(r'[0-9a-f]{32}', value) is None:
            raise ApiError('invalid_request')

    @staticmethod
    def _aad(row):
        return ('larenor:music-playback:schema=1:installation='
                + row['installation_id'] + ':installation-revision='
                + str(row['installation_revision']) + ':core-revision='
                + str(row['core_revision']) + ':revision='
                + str(row['revision'])).encode('ascii')

    def _decode(self, row):
        try:
            self._identity(row['installation_id'])
            if (row['revision'] < 1 or row['installation_revision'] < 1
                    or row['core_revision'] < 1 or len(row['nonce']) != 12
                    or len(row['ciphertext']) > MAX_CIPHERTEXT):
                raise ValueError()
            return _StoredMusicPlayback.model_validate_json(
                self._cipher.decrypt(row['nonce'], row['ciphertext'],
                                     self._aad(row)))
        except (ApiError, InvalidTag, ValidationError, ValueError, TypeError):
            raise ApiError('music_playback_storage_unavailable', 503) from None

    def _save(self, connection, row, stored):
        nonce = secrets.token_bytes(12)
        ciphertext = self._cipher.encrypt(
            nonce, stored.model_dump_json().encode(), self._aad(row))
        values = (row['installation_id'], row['installation_revision'],
                  row['core_revision'], row['revision'], row['created_at'],
                  row['updated_at'], nonce, ciphertext)
        connection.execute('''INSERT INTO music_playback(
            installation_id,installation_revision,core_revision,revision,
            created_at,updated_at,nonce,ciphertext) VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(installation_id) DO UPDATE SET
            installation_revision=excluded.installation_revision,
            core_revision=excluded.core_revision,revision=excluded.revision,
            created_at=excluded.created_at,updated_at=excluded.updated_at,
            nonce=excluded.nonce,ciphertext=excluded.ciphertext''', values)

    def _assert_admin(self, connection, actor):
        self.providers._assert_admin(connection, actor)

    def _assert_user(self, connection, actor):
        self.auth.assert_current(connection, actor)
        if actor.must_change_password:
            raise ApiError('password_change_required', 403)

    def _authority(self, connection, installation_id,
                   installation_revision, core_revision):
        self.providers._readiness(
            connection, installation_id, installation_revision)
        core = connection.execute(
            'SELECT * FROM music_assistant_core WHERE installation_id=?',
            (installation_id,)).fetchone()
        if core is None or core['revision'] != core_revision:
            raise ApiError('music_assistant_not_ready', 409)
        ready = False
        for row in connection.execute(
                'SELECT * FROM music_provider_setups WHERE installation_id=?',
                (installation_id,)).fetchall():
            if (row['installation_revision'] == installation_revision
                    and self.providers._decode(row).status == 'ready'):
                ready = True
                break
        if not ready:
            raise ApiError('music_provider_not_ready', 409)
        token = self.music_core._decode(core).token
        return PrivateMusicPlaybackAuthority(
            installationId=installation_id, token=token)

    def _provider_bindings(self, connection, installation_id,
                           installation_revision):
        bindings = []
        for row in connection.execute(
                'SELECT * FROM music_provider_setups WHERE installation_id=? '
                'ORDER BY id', (installation_id,)).fetchall():
            stored = self.providers._decode(row)
            if (row['installation_revision'] != installation_revision
                    or stored.status != 'ready'
                    or stored.providerInstanceId is None):
                continue
            bindings.append(MusicManagerProvider(
                setupId=row['id'], revision=row['revision'],
                providerDomain=stored.request.providerDomain,
                providerInstanceId=stored.providerInstanceId,
                catalogAvailable=True))
        if not bindings:
            raise ApiError('music_provider_not_ready', 409)
        return bindings

    @staticmethod
    def _player(stored, player_id):
        return next((item for item in stored.players
                     if item.playerId == player_id), None)

    def _public(self, row, stored):
        return MusicPlaybackState.model_validate({
            'installationId': row['installation_id'],
            'installationRevision': row['installation_revision'],
            'coreRevision': row['core_revision'], 'revision': row['revision'],
            'players': [item.model_dump() for item in stored.players],
            'installAvailable': False, 'updatedAt': utc(row['updated_at']),
        }).model_dump()

    def _manager_public(self, row, stored):
        return MusicManagerState.model_validate({
            'installationId': row['installation_id'],
            'installationRevision': row['installation_revision'],
            'coreRevision': row['core_revision'], 'revision': row['revision'],
            'providers': [item.model_dump()
                          for item in stored.providerBindings],
            'queues': [item.model_dump() for item in stored.queues],
            'receivers': [item.model_dump() for item in stored.players],
            'installAvailable': False, 'updatedAt': utc(row['updated_at']),
        }).model_dump()

    @staticmethod
    def _effect_verified(request, result):
        target = result.target
        if request.operation == 'play':
            return target.playbackState == 'playing'
        if request.operation == 'pause':
            return target.playbackState == 'paused'
        if request.operation == 'seek':
            return ((target.positionSeconds is not None
                     and abs(target.positionSeconds
                             - request.positionSeconds) <= 2)
                    or (result.queue is not None
                        and result.queue.queueId == request.expectedQueueId
                        and abs(result.queue.positionSeconds
                                - request.positionSeconds) <= 2))
        if request.operation == 'queue_add':
            return (result.queue is not None
                    and result.queue.queueId == request.expectedQueueId
                    and result.queue.itemCount > 0)
        if request.operation == 'queue_replace':
            return (result.queue is not None
                    and result.queue.queueId == request.expectedQueueId
                    and result.queue.itemCount == len(request.mediaUris)
                    and result.queue.currentItemUri in request.mediaUris)
        if request.operation == 'queue_clear':
            return (result.queue is not None
                    and result.queue.queueId == request.expectedQueueId
                    and result.queue.itemCount == 0
                    and result.queue.currentItemUri is None)
        return True

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                for row in connection.execute(
                        'SELECT * FROM music_playback LIMIT 257').fetchall():
                    self._decode(row)
        except ApiError:
            raise StartupError('invalid_music_playback_storage') from None

    def refresh(self, actor, body):
        if type(body) is not RefreshMusicPlaybackRequest:
            raise ApiError('invalid_request')
        if self.backend is None:
            raise ApiError('music_playback_worker_unavailable', 503)
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            self._assert_admin(connection, actor)
            authority = self._authority(
                connection, body.installationId,
                body.expectedInstallationRevision, body.expectedCoreRevision)
            bindings = self._provider_bindings(
                connection, body.installationId,
                body.expectedInstallationRevision)
            previous = connection.execute(
                'SELECT * FROM music_playback WHERE installation_id=?',
                (body.installationId,)).fetchone()
            previous_revision = 0 if previous is None else previous['revision']
        deadline = time.monotonic() + 5

        def gate():
            if time.monotonic() >= deadline:
                return False
            try:
                with self.db.connection() as connection:
                    self._authority(
                        connection, body.installationId,
                        body.expectedInstallationRevision,
                        body.expectedCoreRevision)
                    if self._provider_bindings(
                            connection, body.installationId,
                            body.expectedInstallationRevision) != bindings:
                        return False
                    current = connection.execute(
                        'SELECT revision FROM music_playback WHERE installation_id=?',
                        (body.installationId,)).fetchone()
                    return (0 if current is None else current['revision']) == previous_revision
            except ApiError:
                return False

        try:
            readback = self.backend.read_music_players(
                authority, deadline=deadline, gate=gate)
            if type(readback) is not MusicPlaybackReadback or gate() is not True:
                raise ValueError()
        except Exception:
            raise ApiError('music_playback_worker_unavailable', 503) from None
        with self.db.transaction() as connection:
            self._assert_admin(connection, actor)
            self._authority(connection, body.installationId,
                            body.expectedInstallationRevision,
                            body.expectedCoreRevision)
            if self._provider_bindings(
                    connection, body.installationId,
                    body.expectedInstallationRevision) != bindings:
                raise ApiError('music_provider_changed', 409)
            current = connection.execute(
                'SELECT * FROM music_playback WHERE installation_id=?',
                (body.installationId,)).fetchone()
            if (0 if current is None else current['revision']) != previous_revision:
                raise ApiError('revision_conflict', 409)
            now = int(self.settings.clock())
            row = {'installation_id': body.installationId,
                   'installation_revision': body.expectedInstallationRevision,
                   'core_revision': body.expectedCoreRevision,
                   'revision': previous_revision + 1,
                   'created_at': now if current is None else current['created_at'],
                   'updated_at': now}
            previous_stored = None if current is None else self._decode(current)
            commands = ([] if previous_stored is None
                        or previous_stored.providerBindings != bindings
                        else previous_stored.commands)
            stored = _StoredMusicPlayback(
                players=readback.players, queues=readback.queues,
                providerBindings=bindings, commands=commands)
            self._save(connection, row, stored)
            saved = connection.execute(
                'SELECT * FROM music_playback WHERE installation_id=?',
                (body.installationId,)).fetchone()
            return {'playback': self._public(saved, self._decode(saved))}

    def get(self, actor, installation_id):
        self._identity(installation_id)
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            self._assert_user(connection, actor)
            row = connection.execute(
                'SELECT * FROM music_playback WHERE installation_id=?',
                (installation_id,)).fetchone()
            if row is None:
                raise ApiError('not_found', 404)
            self._authority(connection, installation_id,
                            row['installation_revision'], row['core_revision'])
            stored = self._decode(row)
            if self._provider_bindings(
                    connection, installation_id,
                    row['installation_revision']) != stored.providerBindings:
                raise ApiError('music_provider_changed', 409)
            return {'playback': self._public(row, stored)}

    def manager(self, actor, installation_id):
        self._identity(installation_id)
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            self._assert_user(connection, actor)
            row = connection.execute(
                'SELECT * FROM music_playback WHERE installation_id=?',
                (installation_id,)).fetchone()
            if row is None:
                raise ApiError('not_found', 404)
            self._authority(connection, installation_id,
                            row['installation_revision'], row['core_revision'])
            stored = self._decode(row)
            if self._provider_bindings(
                    connection, installation_id,
                    row['installation_revision']) != stored.providerBindings:
                raise ApiError('music_provider_changed', 409)
            return {'manager': self._manager_public(row, stored)}

    def search(self, actor, body):
        if type(body) is not SearchMusicCatalogRequest:
            raise ApiError('invalid_request')
        if self.backend is None:
            raise ApiError('music_catalog_worker_unavailable', 503)
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            self._assert_user(connection, actor)
            authority = self._authority(
                connection, body.installationId,
                body.expectedInstallationRevision, body.expectedCoreRevision)
            row = connection.execute(
                'SELECT * FROM music_playback WHERE installation_id=?',
                (body.installationId,)).fetchone()
            if row is None:
                raise ApiError('music_player_readback_required', 409)
            stored = self._decode(row)
            bindings = self._provider_bindings(
                connection, body.installationId,
                body.expectedInstallationRevision)
            if (row['revision'] != body.expectedManagerRevision
                    or bindings != stored.providerBindings):
                raise ApiError('music_provider_changed', 409)
            expected = next((item for item in bindings
                             if item.setupId == body.providerSetupId), None)
            if (expected is None
                    or expected.revision != body.expectedProviderRevision
                    or expected.providerDomain != body.providerDomain
                    or expected.providerInstanceId != body.providerInstanceId):
                raise ApiError('music_provider_changed', 409)
        deadline = time.monotonic() + 5

        def gate():
            if time.monotonic() >= deadline:
                return False
            try:
                with self.db.connection() as connection:
                    self._authority(
                        connection, body.installationId,
                        body.expectedInstallationRevision,
                        body.expectedCoreRevision)
                    current = connection.execute(
                        'SELECT * FROM music_playback WHERE installation_id=?',
                        (body.installationId,)).fetchone()
                    return (current is not None
                            and current['revision'] == body.expectedManagerRevision
                            and self._provider_bindings(
                                connection, body.installationId,
                                body.expectedInstallationRevision) == bindings)
            except ApiError:
                return False

        try:
            result = self.backend.search_music_catalog(
                PrivateMusicCatalogAction(request=body, token=authority.token),
                deadline=deadline, gate=gate)
            if type(result) is not MusicCatalogWorkerResult or gate() is not True:
                raise ValueError()
            if any(item.providerInstanceId != body.providerInstanceId
                   for item in result.items):
                raise ValueError()
        except Exception:
            raise ApiError('music_catalog_worker_unavailable', 503) from None
        return {'catalog': {
            'requestId': body.requestId,
            'managerRevision': body.expectedManagerRevision,
            'items': [item.model_dump() for item in result.items],
        }}

    @staticmethod
    def _receipt(command):
        return {'receipt': {
            'requestId': command.request.requestId,
            'targetId': command.request.targetId,
            'operation': command.request.operation,
            'state': ('succeeded' if command.state == 'succeeded'
                      else 'needs_attention'),
            'playerRevision': command.playerRevision,
            'code': ('authenticated_readback' if command.state == 'succeeded'
                     else 'effect_unknown'),
            'installAvailable': False,
        }}

    def command(self, actor, body):
        if type(body) is not MusicPlaybackCommandRequest:
            raise ApiError('invalid_request')
        with self.db.transaction() as connection:
            self._assert_user(connection, actor)
            authority = self._authority(
                connection, body.installationId,
                body.expectedInstallationRevision, body.expectedCoreRevision)
            row = connection.execute(
                'SELECT * FROM music_playback WHERE installation_id=?',
                (body.installationId,)).fetchone()
            if row is None:
                raise ApiError('music_player_readback_required', 409)
            stored = self._decode(row)
            bindings = self._provider_bindings(
                connection, body.installationId,
                body.expectedInstallationRevision)
            if bindings != stored.providerBindings:
                raise ApiError('music_provider_changed', 409)
            for command in stored.commands:
                if command.request.requestId != body.requestId:
                    continue
                if command.request != body or command.actorId != actor.id:
                    raise ApiError('music_playback_command_conflict', 409)
                return self._receipt(command)
            if row['revision'] != body.expectedPlayerRevision:
                raise ApiError('revision_conflict', 409)
            target = self._player(stored, body.targetId)
            if (target is None or not target.available or not target.enabled
                    or target.groupMembers != body.expectedGroupMembers
                    or target.provider != body.expectedProvider
                    or target.targetKind != body.expectedTargetKind
                    or target.queueId != body.expectedQueueId):
                raise ApiError('music_player_changed', 409)
            if _OP_CAPABILITY[body.operation] not in target.capabilities:
                raise ApiError('music_player_capability_unavailable', 409)
            if len(stored.commands) >= 256:
                raise ApiError('music_playback_command_limit_reached', 409)
            changed = dict(row)
            changed.update(revision=row['revision'] + 1,
                           updated_at=max(row['updated_at'],
                                          int(self.settings.clock())))
            pending = _StoredPlaybackCommand(
                actorId=actor.id, request=body, state='pending',
                playerRevision=changed['revision'])
            claimed = stored.model_copy(update={
                'commands': [*stored.commands, pending]})
            self._save(connection, changed, claimed)
        deadline = time.monotonic() + 5

        def gate():
            if time.monotonic() >= deadline:
                return False
            try:
                with self.db.connection() as connection:
                    self._authority(
                        connection, body.installationId,
                        body.expectedInstallationRevision,
                        body.expectedCoreRevision)
                    current = connection.execute(
                        'SELECT * FROM music_playback WHERE installation_id=?',
                        (body.installationId,)).fetchone()
                    current_stored = self._decode(current)
                    player = self._player(current_stored, body.targetId)
                    return (current['revision'] == changed['revision']
                            and self._provider_bindings(
                                connection, body.installationId,
                                body.expectedInstallationRevision) == bindings
                            and player is not None
                            and player.groupMembers == body.expectedGroupMembers
                            and player.provider == body.expectedProvider
                            and player.targetKind == body.expectedTargetKind
                            and player.queueId == body.expectedQueueId)
            except (ApiError, TypeError):
                return False

        try:
            result = self.backend.execute_music_playback(
                PrivateMusicPlaybackAction(request=body, token=authority.token),
                deadline=deadline, gate=gate)
            if (type(result) is not MusicPlaybackWorkerResult
                    or result.target.playerId != body.targetId
                    or result.target.groupMembers != body.expectedGroupMembers
                    or result.target.provider != body.expectedProvider
                    or result.target.targetKind != body.expectedTargetKind
                    or result.target.queueId != body.expectedQueueId
                    or not self._effect_verified(body, result)
                    or gate() is not True):
                raise ValueError()
        except Exception:
            raise ApiError('music_playback_worker_unavailable', 503) from None
        with self.db.transaction() as connection:
            self._assert_user(connection, actor)
            self._authority(connection, body.installationId,
                            body.expectedInstallationRevision,
                            body.expectedCoreRevision)
            if self._provider_bindings(
                    connection, body.installationId,
                    body.expectedInstallationRevision) != bindings:
                raise ApiError('music_provider_changed', 409)
            current = connection.execute(
                'SELECT * FROM music_playback WHERE installation_id=?',
                (body.installationId,)).fetchone()
            if current['revision'] != changed['revision']:
                raise ApiError('revision_conflict', 409)
            current_stored = self._decode(current)
            players = [result.target if item.playerId == body.targetId else item
                       for item in current_stored.players]
            queues = [result.queue if (result.queue is not None
                                       and item.queueId == result.queue.queueId)
                      else item for item in current_stored.queues]
            if (result.queue is not None
                    and all(item.queueId != result.queue.queueId
                            for item in current_stored.queues)):
                queues.append(result.queue)
            final_revision = current['revision'] + 1
            commands = [
                command.model_copy(update={
                    'state': 'succeeded', 'playerRevision': final_revision})
                if command.request.requestId == body.requestId else command
                for command in current_stored.commands]
            final_row = dict(current)
            final_row.update(revision=final_revision,
                             updated_at=max(current['updated_at'],
                                            int(self.settings.clock())))
            final = _StoredMusicPlayback(
                players=players, queues=queues, providerBindings=bindings,
                commands=commands)
            self._save(connection, final_row, final)
            return self._receipt(commands[-1])
