"""Revision-bound provider configuration authority without execution effects."""

import hashlib
import json
import uuid

from ..admin.service import utc
from ..errors import ApiError
from .music_provider_command_models import (
    ConfirmMusicProviderCommandRequest, CreateMusicProviderCommandPreviewRequest,
    MusicProviderCommand, MusicProviderCommandPreview,
)


MAX_ACTIVE_PREVIEWS = 64
MAX_COMMANDS = 256
PREVIEW_TTL_SECONDS = 600


class MusicProviderCommandManagement:
    def __init__(self, db, settings, provider_setups):
        self.db, self.settings, self.provider_setups = db, settings, provider_setups

    def _provider(self, connection, body):
        row = connection.execute(
            'SELECT * FROM music_provider_setups WHERE id=?',
            (body.providerSetupId,)).fetchone()
        if row is None:
            raise ApiError('music_provider_not_ready', 409)
        stored = self.provider_setups._decode(row)
        if (row['revision'] != body.expectedProviderRevision
                or row['installation_id'] != body.installationId
                or row['installation_revision'] != body.expectedInstallationRevision
                or stored.request.providerDomain != body.providerDomain):
            raise ApiError('revision_conflict', 409)
        if stored.status != 'ready':
            raise ApiError('music_provider_not_ready', 409)
        self.provider_setups._readiness(
            connection, body.installationId, body.expectedInstallationRevision)
        return row

    @staticmethod
    def _preview(row):
        return MusicProviderCommandPreview.model_validate({
            'id': row['id'], 'revision': row['revision'],
            'installationId': row['installation_id'],
            'installationRevision': row['installation_revision'],
            'providerSetupId': row['provider_setup_id'],
            'providerRevision': row['provider_revision'],
            'providerDomain': row['provider_domain'], 'command': row['command'],
            'settings': {}, 'planHash': row['plan_hash'],
            'effectAvailable': False, 'installAvailable': False,
            'blockers': ['effect_unavailable'], 'createdAt': utc(row['created_at']),
            'expiresAt': utc(row['expires_at']),
        }).model_dump()

    @staticmethod
    def _command(row):
        return MusicProviderCommand.model_validate({
            'id': row['id'], 'revision': row['revision'],
            'requestId': row['request_id'], 'previewId': row['preview_id'],
            'installationId': row['installation_id'],
            'installationRevision': row['installation_revision'],
            'providerSetupId': row['provider_setup_id'],
            'providerRevision': row['provider_revision'],
            'providerDomain': row['provider_domain'], 'command': row['command'],
            'state': row['state'], 'errorCode': row['error_code'],
            'effectAvailable': False, 'installAvailable': False,
            'createdAt': utc(row['created_at']),
        }).model_dump()

    @staticmethod
    def _cleanup_expired_previews(connection, now):
        connection.execute(
            'DELETE FROM music_provider_command_previews '
            'WHERE expires_at<=? AND NOT EXISTS ('
            'SELECT 1 FROM music_provider_commands '
            'WHERE music_provider_commands.preview_id='
            'music_provider_command_previews.id)', (now,))

    def preview(self, actor, body):
        if type(body) is not CreateMusicProviderCommandPreviewRequest:
            raise ApiError('invalid_request')
        with self.db.transaction() as connection:
            actor_revision = self.provider_setups._assert_admin(connection, actor)
            now = int(self.settings.clock())
            self._cleanup_expired_previews(connection, now)
            previous = connection.execute(
                'SELECT * FROM music_provider_command_previews WHERE actor_id=? AND request_id=?',
                (actor.id, body.requestId)).fetchone()
            canonical = body.model_dump(mode='json')
            plan_hash = hashlib.sha256(json.dumps(
                canonical, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
            if previous is not None:
                if (previous['actor_revision'] != actor_revision
                        or previous['family_id'] != actor.family_id
                        or previous['plan_hash'] != plan_hash):
                    raise ApiError('music_provider_command_conflict', 409)
                return {'preview': self._preview(previous)}
            self._provider(connection, body)
            active = connection.execute(
                'SELECT COUNT(*) FROM music_provider_command_previews p '
                'WHERE NOT EXISTS (SELECT 1 FROM music_provider_commands c '
                'WHERE c.preview_id=p.id)').fetchone()[0]
            if active >= MAX_ACTIVE_PREVIEWS:
                raise ApiError('music_provider_preview_limit_reached', 409)
            row = (uuid.uuid4().hex, body.requestId, 1, actor.id,
                   actor_revision, actor.family_id, body.installationId,
                   body.expectedInstallationRevision, body.providerSetupId,
                   body.expectedProviderRevision, body.providerDomain,
                   body.command, plan_hash, now, now + PREVIEW_TTL_SECONDS)
            connection.execute(
                'INSERT INTO music_provider_command_previews VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)', row)
            saved = connection.execute(
                'SELECT * FROM music_provider_command_previews WHERE id=?', (row[0],)).fetchone()
            return {'preview': self._preview(saved)}

    def confirm(self, actor, body):
        if type(body) is not ConfirmMusicProviderCommandRequest:
            raise ApiError('invalid_request')
        with self.db.transaction() as connection:
            actor_revision = self.provider_setups._assert_admin(connection, actor)
            now = int(self.settings.clock())
            self._cleanup_expired_previews(connection, now)
            existing = connection.execute(
                'SELECT * FROM music_provider_commands WHERE actor_id=? AND request_id=?',
                (actor.id, body.requestId)).fetchone()
            if existing is not None:
                if (existing['actor_revision'] != actor_revision
                        or existing['family_id'] != actor.family_id
                        or existing['preview_id'] != body.previewId):
                    raise ApiError('music_provider_command_conflict', 409)
                preview = connection.execute(
                    'SELECT * FROM music_provider_command_previews WHERE id=?',
                    (existing['preview_id'],)).fetchone()
                if preview is None or preview['plan_hash'] != body.planHash:
                    raise ApiError('music_provider_command_conflict', 409)
                return {'command': self._command(existing)}
            preview = connection.execute(
                'SELECT * FROM music_provider_command_previews WHERE id=?',
                (body.previewId,)).fetchone()
            if (preview is None or preview['revision'] != body.expectedPreviewRevision
                    or preview['plan_hash'] != body.planHash
                    or preview['actor_id'] != actor.id
                    or preview['actor_revision'] != actor_revision
                    or preview['family_id'] != actor.family_id
                    or preview['expires_at'] <= now):
                raise ApiError('music_provider_preview_invalid', 409)
            class Exact:
                providerSetupId = preview['provider_setup_id']
                expectedProviderRevision = preview['provider_revision']
                installationId = preview['installation_id']
                expectedInstallationRevision = preview['installation_revision']
                providerDomain = preview['provider_domain']
            self._provider(connection, Exact)
            if connection.execute(
                    'SELECT COUNT(*) FROM music_provider_commands').fetchone()[0] >= MAX_COMMANDS:
                raise ApiError('music_provider_command_limit_reached', 409)
            row = (uuid.uuid4().hex, body.requestId, 1, actor.id,
                   actor_revision, actor.family_id, preview['id'],
                   preview['installation_id'], preview['installation_revision'],
                   preview['provider_setup_id'], preview['provider_revision'],
                   preview['provider_domain'], preview['command'], 'blocked',
                   'effect_unavailable', now)
            connection.execute(
                'INSERT INTO music_provider_commands VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)', row)
            saved = connection.execute(
                'SELECT * FROM music_provider_commands WHERE id=?', (row[0],)).fetchone()
            return {'command': self._command(saved)}
