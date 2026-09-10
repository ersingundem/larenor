"""Revision-bound target authority with explicitly unavailable effects."""

import hashlib
import hmac
import json
import secrets
import time
import uuid

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from pydantic import ValidationError

from ..admin.service import utc
from ..errors import ApiError, StartupError
from .music_target_authority_models import (
    CancelMusicTargetCommandRequest, ConfirmMusicTargetCommandRequest,
    CreateMusicTargetCommandPreviewRequest, MusicTarget,
    MusicTargetCommand, MusicTargetCommandPreview, MusicTargetHistoryRequest,
    MusicTargetHistoryResponse, MusicTargetIntegrityResponse,
    MusicTargetInventory, MusicTargetProviderRevision,
    ReadMusicTargetInventoryRequest,
)
from .music_target_effect_models import (
    MusicTargetEffectEnvelope, MusicTargetEffectResult,
)


MAX_PREVIEWS = 256
MAX_CIPHERTEXT = 262144
_CAPABILITY = {
    'play': 'play', 'pause': 'pause', 'stop': 'stop',
    'next': 'next_previous', 'previous': 'next_previous',
    'volume': 'volume_set', 'mute': 'volume_mute',
    'queue_add': 'queue', 'queue_replace': 'queue', 'queue_clear': 'queue',
}


class MusicTargetAuthorityManagement:
    def __init__(self, db, settings, key, playback, effect_backend=None):
        self.db, self.settings, self.playback = db, settings, playback
        self.effect_backend = effect_backend
        self.effect_available = effect_backend is not None
        self._cipher = AESGCM(key)
        self._journal_key = hmac.digest(
            key, b'larenor:music-target-journal:v2', 'sha256')

    def _event_hash(self, kind, values):
        payload = json.dumps(
            [kind, *values], ensure_ascii=True,
            separators=(',', ':')).encode('ascii')
        return hmac.digest(self._journal_key, payload, 'sha256')

    def _command_hash(self, row, preview):
        return self._event_hash('command', (
            row['id'], row['request_id'], row['actor_id'],
            row['actor_revision'], row['family_id'], row['preview_id'],
            row['target_id'], row['operation'], row['created_at'],
            preview['provider_digest'], preview['plan_hash']))

    def _verify_command(self, connection, row):
        preview = connection.execute(
            'SELECT * FROM music_target_command_previews WHERE id=?',
            (row['preview_id'],)).fetchone()
        if (preview is None or type(row['event_hash']) is not bytes
                or not hmac.compare_digest(
                    row['event_hash'], self._command_hash(row, preview))):
            raise ApiError('music_playback_storage_unavailable', 503)
        return preview

    def _cancellation_hash(self, row, command_hash):
        return self._event_hash('cancel', (
            row['command_id'], row['request_id'], row['actor_id'],
            row['actor_revision'], row['family_id'], row['created_at'],
            command_hash.hex()))

    def _verify_cancellation(self, row, command_hash):
        if (type(row['event_hash']) is not bytes
                or not hmac.compare_digest(
                    row['event_hash'],
                    self._cancellation_hash(row, command_hash))):
            raise ApiError('music_playback_storage_unavailable', 503)

    def _effect_hash(self, row):
        return self._event_hash('effect', (
            row['command_id'], row['execution_id'],
            row['dispatch_request_id'], row['actor_id'],
            row['actor_revision'], row['family_id'], row['installation_id'],
            row['installation_revision'], row['core_revision'],
            row['player_revision'], row['provider_digest'], row['state'],
            row['created_at'], row['updated_at'], row['result_hash']))

    def _verify_effect(self, row):
        if (type(row['event_hash']) is not bytes
                or not hmac.compare_digest(
                    row['event_hash'], self._effect_hash(row))):
            raise ApiError('music_playback_storage_unavailable', 503)

    def _save_effect(self, connection, row, state, result_hash):
        changed = dict(row)
        changed.update(
            state=state,
            updated_at=max(row['updated_at'], int(self.settings.clock())),
            result_hash=result_hash)
        changed['event_hash'] = self._effect_hash(changed)
        connection.execute('''UPDATE music_target_effect_attempts SET
            state=?,updated_at=?,result_hash=?,event_hash=? WHERE command_id=?''',
            (changed['state'], changed['updated_at'], changed['result_hash'],
             changed['event_hash'], changed['command_id']))
        return changed

    @staticmethod
    def _effect_receipt(row):
        state = 'succeeded' if row['state'] == 'succeeded' else 'unknown'
        return {
            'commandId': row['command_id'],
            'requestId': row['dispatch_request_id'], 'state': state,
            'code': ('authenticated_readback' if state == 'succeeded'
                     else 'effect_unknown'), 'effectAvailable': True,
            'installAvailable': False,
        }

    @staticmethod
    def _target(player):
        if player.targetKind in {'homepod', 'airplay'}:
            transport, kind = 'airplay', 'device'
        elif player.targetKind == 'airplay_group':
            transport, kind = 'airplay', 'group'
        elif player.targetKind == 'chromecast':
            transport, kind = 'chromecast', 'device'
        elif player.targetKind == 'chromecast_group':
            transport, kind = 'chromecast', 'group'
        else:
            raise ApiError('music_player_capability_unavailable', 409)
        return MusicTarget(
            id=player.playerId, name=player.name, provider=player.provider,
            transport=transport, kind=kind,
            homePod=player.targetKind == 'homepod', available=player.available,
            enabled=player.enabled, playbackState=player.playbackState,
            volumeLevel=player.volumeLevel, muted=player.muted,
            groupMemberIds=player.groupMembers, queueId=player.queueId,
            capabilities=player.capabilities)

    def _state(self, connection, body):
        self.playback._authority(
            connection, body.installationId,
            body.expectedInstallationRevision, body.expectedCoreRevision)
        row = connection.execute(
            'SELECT * FROM music_playback WHERE installation_id=?',
            (body.installationId,)).fetchone()
        if row is None:
            raise ApiError('music_player_readback_required', 409)
        if (row['installation_revision'] != body.expectedInstallationRevision
                or row['core_revision'] != body.expectedCoreRevision
                or row['revision'] != body.expectedPlayerRevision):
            raise ApiError('revision_conflict', 409)
        return row, self.playback._decode(row)

    def _providers(self, connection, body):
        current = []
        rows = connection.execute(
            'SELECT * FROM music_provider_setups WHERE installation_id=? '
            'ORDER BY sequence', (body.installationId,)).fetchall()
        for row in rows:
            stored = self.playback.providers._decode(row)
            if (row['installation_revision']
                    == body.expectedInstallationRevision
                    and stored.status == 'ready'):
                current.append(MusicTargetProviderRevision(
                    id=row['id'], providerDomain=stored.request.providerDomain,
                    revision=row['revision']))
        if not current:
            raise ApiError('music_provider_not_ready', 409)
        if current != body.expectedProviderRevisions:
            raise ApiError('revision_conflict', 409)
        return current

    @staticmethod
    def _provider_digest(providers):
        return hashlib.sha256(json.dumps(
            [item.model_dump(mode='json') for item in providers],
            sort_keys=True, separators=(',', ':')).encode()).hexdigest()

    def inventory(self, actor, body):
        if type(body) is not ReadMusicTargetInventoryRequest:
            raise ApiError('invalid_request')
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            self.playback._assert_admin(connection, actor)
            row, stored = self._state(connection, body)
            providers = self._providers(connection, body)
            inventory = MusicTargetInventory(
                installationId=row['installation_id'],
                installationRevision=row['installation_revision'],
                coreRevision=row['core_revision'], playerRevision=row['revision'],
                providerRevisions=providers,
                targets=[self._target(player) for player in stored.players],
                installAvailable=False, updatedAt=utc(row['updated_at']))
            return {'inventory': inventory.model_dump()}

    @staticmethod
    def _aad(row):
        return ('larenor:music-target-preview:v1:' + row['id'] + ':'
                + row['actor_id'] + ':' + row['family_id'] + ':'
                + row['installation_id'] + ':'
                + str(row['installation_revision']) + ':'
                + str(row['core_revision']) + ':'
                + str(row['player_revision']) + ':'
                + row['provider_digest'] + ':' + row['plan_hash']).encode()

    def _decode(self, row):
        try:
            if (len(row['nonce']) != 12
                    or len(row['ciphertext']) > MAX_CIPHERTEXT):
                raise ValueError()
            return CreateMusicTargetCommandPreviewRequest.model_validate_json(
                self._cipher.decrypt(
                    row['nonce'], row['ciphertext'], self._aad(row)))
        except (InvalidTag, ValidationError, ValueError, TypeError):
            raise ApiError('music_playback_storage_unavailable', 503) from None

    @staticmethod
    def _plan_hash(body):
        return hashlib.sha256(json.dumps(
            body.model_dump(mode='json'), sort_keys=True,
            separators=(',', ':')).encode()).hexdigest()

    def _public_preview(self, row, request, target):
        return MusicTargetCommandPreview.model_validate({
            'id': row['id'], 'revision': 1,
            'installationId': request.installationId,
            'installationRevision': request.expectedInstallationRevision,
            'coreRevision': request.expectedCoreRevision,
            'playerRevision': request.expectedPlayerRevision,
            'providerRevisions': request.expectedProviderRevisions,
            'target': target, 'operation': request.operation,
            'volumeLevel': request.volumeLevel, 'muted': request.muted,
            'mediaUris': request.mediaUris, 'planHash': row['plan_hash'],
            'effectAvailable': False, 'installAvailable': False,
            'blockers': ['effect_unavailable'],
            'createdAt': utc(row['created_at']),
            'expiresAt': utc(row['expires_at']),
        }).model_dump()

    def _exact_target(self, stored, body):
        player = self.playback._player(stored, body.targetId)
        if player is None:
            raise ApiError('music_player_changed', 409)
        target = self._target(player)
        if (not target.available or not target.enabled
                or target.provider != body.expectedProvider
                or target.transport != body.expectedTransport
                or target.kind != body.expectedKind
                or target.queueId != body.expectedQueueId
                or target.groupMemberIds != body.expectedGroupMemberIds):
            raise ApiError('music_player_changed', 409)
        if _CAPABILITY[body.operation] not in target.capabilities:
            raise ApiError('music_player_capability_unavailable', 409)
        return target

    def preview(self, actor, body):
        if type(body) is not CreateMusicTargetCommandPreviewRequest:
            raise ApiError('invalid_request')
        with self.db.transaction() as connection:
            actor_revision = self.playback.providers._assert_admin(
                connection, actor)
            previous = connection.execute(
                'SELECT * FROM music_target_command_previews '
                'WHERE actor_id=? AND request_id=?',
                (actor.id, body.requestId)).fetchone()
            if previous is not None:
                saved = self._decode(previous)
                _, stored = self._state(connection, body)
                providers = self._providers(connection, body)
                if (saved != body or previous['actor_revision'] != actor_revision
                        or previous['family_id'] != actor.family_id
                        or previous['provider_digest'] != self._provider_digest(
                            providers)
                        or previous['expires_at'] <= int(self.settings.clock())):
                    raise ApiError('music_playback_command_conflict', 409)
                return {'preview': self._public_preview(
                    previous, saved, self._exact_target(stored, saved))}
            count = connection.execute(
                'SELECT COUNT(*) FROM music_target_command_previews').fetchone()[0]
            if count >= MAX_PREVIEWS:
                raise ApiError('music_playback_command_limit_reached', 409)
            _, stored = self._state(connection, body)
            providers = self._providers(connection, body)
            target = self._exact_target(stored, body)
            now = int(self.settings.clock())
            row = {
                'id': uuid.uuid4().hex, 'request_id': body.requestId,
                'actor_id': actor.id, 'actor_revision': actor_revision,
                'family_id': actor.family_id,
                'installation_id': body.installationId,
                'installation_revision': body.expectedInstallationRevision,
                'core_revision': body.expectedCoreRevision,
                'player_revision': body.expectedPlayerRevision,
                'provider_digest': self._provider_digest(providers),
                'plan_hash': self._plan_hash(body), 'created_at': now,
                'expires_at': now + 600,
            }
            nonce = secrets.token_bytes(12)
            ciphertext = self._cipher.encrypt(
                nonce, body.model_dump_json().encode(), self._aad(row))
            connection.execute('''INSERT INTO music_target_command_previews(
                id,request_id,actor_id,actor_revision,family_id,installation_id,
                installation_revision,core_revision,player_revision,
                provider_digest,plan_hash,created_at,expires_at,nonce,ciphertext)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
                (*row.values(), nonce, ciphertext))
            return {'preview': self._public_preview(row, body, target)}

    @staticmethod
    def _public_command(row, target, cancellation=None, effect=None):
        if cancellation is not None:
            state, error, result, revision = (
                'cancelled', 'effect_unavailable', None, 2)
        elif effect is not None:
            state = ('succeeded' if effect['state'] == 'succeeded'
                     else 'unknown')
            error = None if state == 'succeeded' else 'effect_unknown'
            result = {
                'state': state,
                'code': ('authenticated_readback' if state == 'succeeded'
                         else 'effect_unknown'),
            }
            revision = 2
        else:
            state, error, result, revision = (
                'blocked', 'effect_unavailable', None, 1)
        return MusicTargetCommand.model_validate({
            'id': row['id'], 'revision': revision,
            'requestId': row['request_id'],
            'previewId': row['preview_id'], 'targetId': row['target_id'],
            'target': target, 'operation': row['operation'], 'state': state,
            'errorCode': error, 'result': result,
            'effectAvailable': effect is not None, 'installAvailable': False,
            'createdAt': utc(row['created_at']),
        }).model_dump()

    def _read_command(self, connection, row):
        preview = self._verify_command(connection, row)
        request = self._decode(preview)
        _, stored = self._state(connection, request)
        providers = self._providers(connection, request)
        if preview['provider_digest'] != self._provider_digest(providers):
            raise ApiError('revision_conflict', 409)
        target = self._exact_target(stored, request)
        cancellation = connection.execute(
            'SELECT * FROM music_target_command_cancellations '
            'WHERE command_id=?', (row['id'],)).fetchone()
        if cancellation is not None:
            self._verify_cancellation(cancellation, row['event_hash'])
        effect = connection.execute(
            'SELECT * FROM music_target_effect_attempts WHERE command_id=?',
            (row['id'],)).fetchone()
        if effect is not None:
            self._verify_effect(effect)
            if (effect['installation_id'] != preview['installation_id']
                    or effect['installation_revision']
                    != preview['installation_revision']
                    or effect['core_revision'] != preview['core_revision']
                    or effect['player_revision'] != preview['player_revision']
                    or effect['provider_digest'] != preview['provider_digest']
                    or cancellation is not None):
                raise ApiError('music_playback_storage_unavailable', 503)
        return self._public_command(row, target, cancellation, effect)

    def confirm(self, actor, body):
        if type(body) is not ConfirmMusicTargetCommandRequest:
            raise ApiError('invalid_request')
        with self.db.transaction() as connection:
            actor_revision = self.playback.providers._assert_admin(
                connection, actor)
            existing = connection.execute(
                'SELECT * FROM music_target_commands '
                'WHERE actor_id=? AND request_id=?',
                (actor.id, body.requestId)).fetchone()
            if existing is not None:
                preview = self._verify_command(connection, existing)
                if (existing['preview_id'] != body.previewId
                        or existing['actor_revision'] != actor_revision
                        or existing['family_id'] != actor.family_id
                        or preview is None
                        or preview['plan_hash'] != body.planHash):
                    raise ApiError('music_playback_command_conflict', 409)
                return {'command': self._read_command(connection, existing)}
            preview = connection.execute(
                'SELECT * FROM music_target_command_previews WHERE id=?',
                (body.previewId,)).fetchone()
            now = int(self.settings.clock())
            if (preview is None or preview['plan_hash'] != body.planHash
                    or preview['actor_id'] != actor.id
                    or preview['actor_revision'] != actor_revision
                    or preview['family_id'] != actor.family_id
                    or preview['expires_at'] <= now):
                raise ApiError('music_player_changed', 409)
            if connection.execute(
                    'SELECT 1 FROM music_target_commands WHERE preview_id=?',
                    (body.previewId,)).fetchone() is not None:
                raise ApiError('music_playback_command_conflict', 409)
            request = self._decode(preview)
            _, stored = self._state(connection, request)
            providers = self._providers(connection, request)
            if preview['provider_digest'] != self._provider_digest(providers):
                raise ApiError('revision_conflict', 409)
            target = self._exact_target(stored, request)
            values = [
                uuid.uuid4().hex, body.requestId, actor.id, actor_revision,
                actor.family_id, preview['id'], target.id,
                request.operation, now]
            sealed = dict(zip((
                'id', 'request_id', 'actor_id', 'actor_revision', 'family_id',
                'preview_id', 'target_id', 'operation', 'created_at'), values))
            values.append(self._command_hash(sealed, preview))
            connection.execute(
                'INSERT INTO music_target_commands VALUES(?,?,?,?,?,?,?,?,?,?)',
                values)
            saved = connection.execute(
                'SELECT * FROM music_target_commands WHERE id=?',
                (values[0],)).fetchone()
            return {'command': self._public_command(saved, target)}

    def get_command(self, actor, identifier):
        self.playback._identity(identifier)
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            self.playback.providers._assert_admin(connection, actor)
            row = connection.execute(
                'SELECT * FROM music_target_commands WHERE id=?',
                (identifier,)).fetchone()
            if row is None:
                raise ApiError('not_found', 404)
            return {'command': self._read_command(connection, row)}

    def cancel(self, actor, identifier, body):
        self.playback._identity(identifier)
        if type(body) is not CancelMusicTargetCommandRequest:
            raise ApiError('invalid_request')
        with self.db.transaction() as connection:
            actor_revision = self.playback.providers._assert_admin(
                connection, actor)
            row = connection.execute(
                'SELECT * FROM music_target_commands WHERE id=?',
                (identifier,)).fetchone()
            if row is None:
                raise ApiError('not_found', 404)
            self._read_command(connection, row)
            if connection.execute(
                    'SELECT 1 FROM music_target_effect_attempts '
                    'WHERE command_id=?', (identifier,)).fetchone() is not None:
                raise ApiError('music_playback_command_conflict', 409)
            existing = connection.execute(
                'SELECT * FROM music_target_command_cancellations '
                'WHERE command_id=?', (identifier,)).fetchone()
            if existing is not None:
                self._verify_cancellation(existing, row['event_hash'])
                if (existing['request_id'] != body.requestId
                        or existing['actor_id'] != actor.id
                        or existing['actor_revision'] != actor_revision
                        or existing['family_id'] != actor.family_id):
                    raise ApiError('music_playback_command_conflict', 409)
                return {'command': self._read_command(connection, row)}
            now = int(self.settings.clock())
            values = [identifier, body.requestId, actor.id, actor_revision,
                      actor.family_id, now]
            cancellation = dict(zip((
                'command_id', 'request_id', 'actor_id', 'actor_revision',
                'family_id', 'created_at'), values))
            values.append(self._cancellation_hash(
                cancellation, row['event_hash']))
            connection.execute(
                'INSERT INTO music_target_command_cancellations '
                'VALUES(?,?,?,?,?,?,?)', values)
            return {'command': self._read_command(connection, row)}

    def _journal_rows(self, connection, installation_id):
        rows = connection.execute('''SELECT * FROM music_target_commands
            WHERE preview_id IN (
              SELECT id FROM music_target_command_previews
              WHERE installation_id=?)
            ORDER BY created_at DESC,id DESC LIMIT 257''',
            (installation_id,)).fetchall()
        if len(rows) > MAX_PREVIEWS:
            raise ApiError('music_playback_storage_unavailable', 503)
        return rows

    def history(self, actor, body):
        if type(body) is not MusicTargetHistoryRequest:
            raise ApiError('invalid_request')
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            self.playback.providers._assert_admin(connection, actor)
            self._state(connection, body)
            self._providers(connection, body)
            rows = self._journal_rows(connection, body.installationId)
            offset = 0
            if body.before is not None:
                indices = [index for index, row in enumerate(rows)
                           if row['id'] == body.before]
                if not indices:
                    raise ApiError('not_found', 404)
                offset = indices[0] + 1
            selected = rows[offset:offset + body.limit]
            commands = [self._read_command(connection, row)
                        for row in selected]
            next_before = (selected[-1]['id']
                           if offset + len(selected) < len(rows) else None)
            response = MusicTargetHistoryResponse(
                commands=commands, nextBefore=next_before)
            return response.model_dump()

    def integrity(self, actor, body):
        if type(body) is not ReadMusicTargetInventoryRequest:
            raise ApiError('invalid_request')
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            self.playback.providers._assert_admin(connection, actor)
            self._state(connection, body)
            self._providers(connection, body)
            rows = list(reversed(self._journal_rows(
                connection, body.installationId)))
            digest = hashlib.sha256()
            for row in rows:
                self._read_command(connection, row)
                digest.update(row['event_hash'])
                cancellation = connection.execute(
                    'SELECT event_hash FROM music_target_command_cancellations '
                    'WHERE command_id=?', (row['id'],)).fetchone()
                effect = connection.execute(
                    'SELECT event_hash FROM music_target_effect_attempts '
                    'WHERE command_id=?', (row['id'],)).fetchone()
                if cancellation is not None:
                    digest.update(cancellation['event_hash'])
                if effect is not None:
                    digest.update(effect['event_hash'])
            response = MusicTargetIntegrityResponse.model_validate({
                'integrity': {'verified': True, 'commandCount': len(rows),
                              'headHash': digest.hexdigest(),
                              'installAvailable': False}})
            return response.model_dump()

    def execute_confirmed(self, actor, command_id, expected_revision,
                          request_id, *, gate):
        """Dispatch one confirmed command through the private worker seam."""
        if self.effect_backend is None or self.effect_available is not True:
            raise ApiError('music_target_effect_unavailable', 409)
        self.playback._identity(command_id)
        self.playback._identity(request_id)
        if (type(expected_revision) is not int or expected_revision != 1
                or not callable(gate)):
            raise ApiError('invalid_request')
        with self.db.transaction() as connection:
            actor_revision = self.playback.providers._assert_admin(
                connection, actor)
            command = connection.execute(
                'SELECT * FROM music_target_commands WHERE id=?',
                (command_id,)).fetchone()
            if command is None:
                raise ApiError('not_found', 404)
            preview = self._verify_command(connection, command)
            request = self._decode(preview)
            if connection.execute(
                    'SELECT 1 FROM music_target_command_cancellations '
                    'WHERE command_id=?', (command_id,)).fetchone() is not None:
                raise ApiError('revision_conflict', 409)
            _, stored = self._state(connection, request)
            providers = self._providers(connection, request)
            provider_digest = self._provider_digest(providers)
            if preview['provider_digest'] != provider_digest:
                raise ApiError('revision_conflict', 409)
            target = self._exact_target(stored, request)
            previous = connection.execute(
                'SELECT * FROM music_target_effect_attempts WHERE command_id=?',
                (command_id,)).fetchone()
            if previous is not None:
                self._verify_effect(previous)
                if (previous['dispatch_request_id'] != request_id
                        or previous['actor_id'] != actor.id
                        or previous['actor_revision'] != actor_revision
                        or previous['family_id'] != actor.family_id):
                    raise ApiError('music_playback_command_conflict', 409)
                if previous['state'] == 'pending':
                    previous = self._save_effect(
                        connection, previous, 'unknown', '0' * 64)
                return self._effect_receipt(previous)
            try:
                permitted = gate()
            except Exception:
                permitted = False
            if permitted is not True:
                raise ApiError('revision_conflict', 409)
            now = int(self.settings.clock())
            row = {
                'command_id': command_id, 'execution_id': uuid.uuid4().hex,
                'dispatch_request_id': request_id, 'actor_id': actor.id,
                'actor_revision': actor_revision, 'family_id': actor.family_id,
                'installation_id': request.installationId,
                'installation_revision': request.expectedInstallationRevision,
                'core_revision': request.expectedCoreRevision,
                'player_revision': request.expectedPlayerRevision,
                'provider_digest': provider_digest, 'state': 'pending',
                'created_at': now, 'updated_at': now,
                'result_hash': '0' * 64,
            }
            row['event_hash'] = self._effect_hash(row)
            connection.execute('''INSERT INTO music_target_effect_attempts(
                command_id,execution_id,dispatch_request_id,actor_id,
                actor_revision,family_id,installation_id,
                installation_revision,core_revision,player_revision,
                provider_digest,state,created_at,updated_at,result_hash,event_hash)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)''', tuple(row.values()))
            envelope = MusicTargetEffectEnvelope(
                executionId=row['execution_id'], commandId=command_id,
                requestId=request_id, previewId=preview['id'],
                installationId=request.installationId,
                installationRevision=request.expectedInstallationRevision,
                coreRevision=request.expectedCoreRevision,
                playerRevision=request.expectedPlayerRevision,
                providerRevisions=providers, target=target,
                operation=request.operation, volumeLevel=request.volumeLevel,
                muted=request.muted, mediaUris=request.mediaUris)
        deadline = time.monotonic() + 5

        def current():
            if time.monotonic() >= deadline:
                return False
            try:
                if gate() is not True:
                    return False
                with self.db.connection() as connection:
                    self.playback.providers._assert_admin(connection, actor)
                    _, saved = self._state(connection, request)
                    self._exact_target(saved, request)
                    if self._provider_digest(
                            self._providers(connection, request)
                            ) != provider_digest:
                        return False
                    attempt = connection.execute(
                        'SELECT * FROM music_target_effect_attempts '
                        'WHERE command_id=?', (command_id,)).fetchone()
                    self._verify_effect(attempt)
                    return (attempt['state'] == 'pending'
                            and attempt['dispatch_request_id'] == request_id)
            except Exception:
                return False

        try:
            result = self.effect_backend.execute_music_target_effect(
                envelope, deadline=deadline, gate=current)
            if (type(result) is not MusicTargetEffectResult
                    or result.executionId != envelope.executionId
                    or result.commandId != command_id
                    or result.requestId != request_id
                    or result.target.id != target.id
                    or result.target.provider != target.provider
                    or result.target.transport != target.transport
                    or result.target.kind != target.kind
                    or result.target.groupMemberIds != target.groupMemberIds
                    or result.target.queueId != target.queueId
                    or current() is not True):
                raise ValueError()
            result_hash = hashlib.sha256(
                result.model_dump_json().encode()).hexdigest()
        except Exception:
            with self.db.transaction() as connection:
                attempt = connection.execute(
                    'SELECT * FROM music_target_effect_attempts '
                    'WHERE command_id=?', (command_id,)).fetchone()
                if attempt is not None:
                    self._verify_effect(attempt)
                    if attempt['state'] == 'pending':
                        self._save_effect(
                            connection, attempt, 'unknown', '0' * 64)
            raise ApiError('music_playback_worker_unavailable', 503) from None
        with self.db.transaction() as connection:
            attempt = connection.execute(
                'SELECT * FROM music_target_effect_attempts WHERE command_id=?',
                (command_id,)).fetchone()
            self._verify_effect(attempt)
            if attempt['state'] != 'pending' or current() is not True:
                if attempt['state'] == 'pending':
                    self._save_effect(
                        connection, attempt, 'unknown', '0' * 64)
                raise ApiError('revision_conflict', 409)
            final = self._save_effect(
                connection, attempt, 'succeeded', result_hash)
            return self._effect_receipt(final)

    def validate_storage(self):
        try:
            with self.db.transaction() as connection:
                previews = connection.execute(
                    'SELECT * FROM music_target_command_previews LIMIT 257'
                ).fetchall()
                if len(previews) > MAX_PREVIEWS:
                    raise ApiError('music_playback_storage_unavailable', 503)
                for row in previews:
                    self._decode(row)
                commands = connection.execute(
                    'SELECT * FROM music_target_commands LIMIT 257').fetchall()
                if len(commands) > MAX_PREVIEWS:
                    raise ApiError('music_playback_storage_unavailable', 503)
                for row in commands:
                    self._verify_command(connection, row)
                cancellations = connection.execute(
                    'SELECT * FROM music_target_command_cancellations LIMIT 257'
                ).fetchall()
                effects = connection.execute(
                    'SELECT * FROM music_target_effect_attempts LIMIT 257'
                ).fetchall()
                if (len(cancellations) > MAX_PREVIEWS
                        or len(effects) > MAX_PREVIEWS):
                    raise ApiError('music_playback_storage_unavailable', 503)
                command_by_id = {row['id']: row for row in commands}
                preview_by_id = {row['id']: row for row in previews}
                cancellation_ids = set()
                for row in cancellations:
                    command = command_by_id.get(row['command_id'])
                    if command is None:
                        raise ApiError('music_playback_storage_unavailable', 503)
                    self._verify_cancellation(row, command['event_hash'])
                    cancellation_ids.add(row['command_id'])
                for row in effects:
                    command = command_by_id.get(row['command_id'])
                    preview = (None if command is None else
                               preview_by_id.get(command['preview_id']))
                    self._verify_effect(row)
                    if (command is None or preview is None
                            or row['command_id'] in cancellation_ids
                            or row['installation_id']
                            != preview['installation_id']
                            or row['installation_revision']
                            != preview['installation_revision']
                            or row['core_revision'] != preview['core_revision']
                            or row['player_revision']
                            != preview['player_revision']
                            or row['provider_digest']
                            != preview['provider_digest']):
                        raise ApiError('music_playback_storage_unavailable', 503)
                    if row['state'] == 'pending':
                        changed = dict(row)
                        changed.update(
                            state='unknown',
                            updated_at=max(
                                row['updated_at'], int(self.settings.clock())),
                            result_hash='0' * 64)
                        changed['event_hash'] = self._effect_hash(changed)
                        connection.execute('''UPDATE music_target_effect_attempts
                            SET state=?,updated_at=?,result_hash=?,event_hash=?
                            WHERE command_id=?''', (
                                changed['state'], changed['updated_at'],
                                changed['result_hash'], changed['event_hash'],
                                row['command_id']))
        except ApiError:
            raise StartupError('invalid_music_target_authority_storage') from None
