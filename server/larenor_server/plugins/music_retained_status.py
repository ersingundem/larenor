"""Read-only projection of the retained Music Assistant component chain."""

from ..admin.service import utc
from ..errors import ApiError
from .music_retained_status_models import MusicRetainedStatusResponse


MAX_RETAINED_MUSIC_INSTALLATIONS = 64


class MusicRetainedStatusManagement:
    def __init__(self, db, installations, music_core, provider_setups):
        self.db = db
        self.installations = installations
        self.music_core = music_core
        self.provider_setups = provider_setups

    @staticmethod
    def _provider(row, stored):
        return {
            'id': row['id'], 'providerDomain': stored.request.providerDomain,
            'revision': row['revision'], 'state': stored.status,
            'updatedAt': utc(row['updated_at']),
        }

    def _bootstrap(self, connection, installation_row):
        row = connection.execute(
            'SELECT * FROM music_assistant_core WHERE installation_id=?',
            (installation_row['id'],)).fetchone()
        if row is None:
            return None, 'bootstrap_unknown'
        stored = self.music_core._decode(row)
        public = self.music_core._public(connection, row, stored)
        receipt = {
            'revision': row['revision'],
            'state': 'ready' if public['state'] == 'verified' else 'failed',
            'serverVersion': public['serverVersion'],
            'schemaVersion': public['schemaVersion'],
            'homeAssistant': public['homeAssistant'],
            'jellyfin': public['jellyfin'],
        }
        return receipt, public['errorCode']

    def read(self, actor):
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            self.music_core._assert_admin(connection, actor)
            rows = connection.execute(
                'SELECT * FROM media_installations ORDER BY sequence DESC '
                'LIMIT 257').fetchall()
            if len(rows) > 256:
                raise ApiError('media_installation_storage_unavailable', 503)
            retained = []
            for row in rows:
                payload = self.installations._decode(row)
                if payload.request.serviceId != 'music_assistant':
                    continue
                if len(retained) >= MAX_RETAINED_MUSIC_INSTALLATIONS:
                    raise ApiError('music_assistant_core_limit_reached', 409)
                providers = []
                for provider_row in connection.execute(
                        'SELECT * FROM music_provider_setups '
                        'WHERE installation_id=? ORDER BY sequence',
                        (row['id'],)).fetchall():
                    stored = self.provider_setups._decode(provider_row)
                    if provider_row['installation_revision'] != row['revision']:
                        continue
                    providers.append(self._provider(provider_row, stored))
                receipt, readiness_error = self._bootstrap(connection, row)
                if row['state'] in {'queued', 'running'}:
                    state, error, receipt = 'partial', 'installation_pending', None
                elif row['state'] != 'container_started':
                    state, error, receipt = 'failed', 'installation_failed', None
                elif receipt is None:
                    state, error = 'partial', 'bootstrap_unknown'
                elif readiness_error is not None:
                    state, error = 'failed', readiness_error
                elif any(item['state'] == 'ready' for item in providers):
                    state, error = 'ready', None
                elif any(item['state'] in {'cancelled', 'needs_attention'}
                         for item in providers):
                    state, error = 'failed', 'provider_failed'
                else:
                    state, error = 'partial', 'provider_not_ready'
                retained.append({
                    'installationId': row['id'],
                    'installationRevision': row['revision'],
                    'installationState': row['state'],
                    'state': state, 'errorCode': error,
                    'bootstrapReceipt': receipt, 'providers': providers,
                })
            overall = (
                'unknown' if not retained
                else 'failed' if any(item['state'] == 'failed'
                                     for item in retained)
                else 'ready' if all(item['state'] == 'ready'
                                    for item in retained)
                else 'partial')
            return MusicRetainedStatusResponse.model_validate({
                'schemaVersion': 1, 'state': overall,
                'installAvailable': False, 'installations': retained,
            }).model_dump()
