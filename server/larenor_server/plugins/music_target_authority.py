"""Revision-bound target authority with explicitly unavailable effects."""

import hashlib
import json
import secrets
import uuid

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from pydantic import ValidationError

from ..admin.service import utc
from ..errors import ApiError, StartupError
from .music_target_authority_models import (
    ConfirmMusicTargetCommandRequest, CreateMusicTargetCommandPreviewRequest,
    MusicTarget, MusicTargetCommand, MusicTargetCommandPreview,
    MusicTargetInventory, MusicTargetProviderRevision,
    ReadMusicTargetInventoryRequest,
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
    def __init__(self, db, settings, key, playback):
        self.db, self.settings, self.playback = db, settings, playback
        self._cipher = AESGCM(key)

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
    def _public_command(row, target):
        return MusicTargetCommand.model_validate({
            'id': row['id'], 'revision': 1, 'requestId': row['request_id'],
            'previewId': row['preview_id'], 'targetId': row['target_id'],
            'target': target, 'operation': row['operation'], 'state': 'blocked',
            'errorCode': 'effect_unavailable', 'result': None,
            'effectAvailable': False, 'installAvailable': False,
            'createdAt': utc(row['created_at']),
        }).model_dump()

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
                preview = connection.execute(
                    'SELECT * FROM music_target_command_previews WHERE id=?',
                    (existing['preview_id'],)).fetchone()
                if (existing['preview_id'] != body.previewId
                        or existing['actor_revision'] != actor_revision
                        or existing['family_id'] != actor.family_id
                        or preview is None
                        or preview['plan_hash'] != body.planHash):
                    raise ApiError('music_playback_command_conflict', 409)
                request = self._decode(preview)
                _, stored = self._state(connection, request)
                self._providers(connection, request)
                return {'command': self._public_command(
                    existing, self._exact_target(stored, request))}
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
            values = (
                uuid.uuid4().hex, body.requestId, actor.id, actor_revision,
                actor.family_id, preview['id'], target.id,
                request.operation, now)
            connection.execute(
                'INSERT INTO music_target_commands VALUES(?,?,?,?,?,?,?,?,?)',
                values)
            saved = connection.execute(
                'SELECT * FROM music_target_commands WHERE id=?',
                (values[0],)).fetchone()
            return {'command': self._public_command(saved, target)}

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
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
                    if connection.execute(
                            'SELECT 1 FROM music_target_command_previews WHERE id=?',
                            (row['preview_id'],)).fetchone() is None:
                        raise ApiError('music_playback_storage_unavailable', 503)
        except ApiError:
            raise StartupError('invalid_music_target_authority_storage') from None
