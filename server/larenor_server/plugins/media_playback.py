"""Revision-bound managed Jellyfin playback with one-use command ownership."""

from dataclasses import dataclass
import hmac
import json
import secrets
import threading
import time

from pydantic import ValidationError

from ..errors import ApiError, StartupError
from .jellyfin_playback_executor import JellyfinPlaybackExecutionError
from .media_playback_models import (
    MediaPlaybackCommandRequest,
    MediaPlaybackIntent,
    MediaPlaybackReadback,
    MediaPlaybackReceipt,
    MediaPlaybackWorkerResult,
    OfflineMediaChunkReadback,
    PlaybackInfoReadback,
    PlaybackInfoRequest,
    MediaSegmentsAuthority,
    MediaSegmentsReadback,
    MediaSegmentsRequest,
    MediaSegmentsResponse,
    PrepareMediaPlaybackIntentRequest,
    PrivateJellyfinMediaSegmentsAuthority,
    PrivateJellyfinOfflineMediaChunkAuthority,
    PrivateJellyfinPlaybackInfoAuthority,
    PrivateJellyfinPlaybackAction,
    PrivateJellyfinPlaybackAuthority,
    PrivateMediaPlaybackAction,
    PrivateMediaPlaybackAuthority,
    local_playback_profile_digest,
)
from .media_archive_core_models import PrivateMediaArchiveCollection
from .media_installations import MAX_INSTALLATIONS

_MAX_RECORDS = 256
_MAX_PLAYBACK_INFO_OBSERVATIONS = 256
_MAX_PLAYBACK_INFO_OBSERVATIONS_PER_ACTOR = 32
_PLAYBACK_INFO_TTL = 30
_RECEIPT_QUERY = '''SELECT
    r.request_id AS receipt_request_id,
    r.intent_id AS receipt_intent_id,
    r.actor_id AS receipt_actor_id,
    r.request_json AS receipt_request_json,
    r.state AS receipt_state,
    r.receipt_json AS stored_receipt_json,
    i.id AS stored_intent_id,
    i.actor_id AS intent_actor_id,
    i.actor_revision AS intent_actor_revision,
    i.family_id AS intent_family_id,
    i.installation_id AS installation_id,
    i.item_id AS item_id,
    i.playback_revision AS intent_playback_revision,
    i.targets_json AS intent_targets_json,
    i.consumed_by AS intent_consumed_by
FROM media_playback_receipts r
LEFT JOIN media_playback_intents i ON i.id=r.intent_id'''


@dataclass(frozen=True)
class _DurablePlaybackScope:
    actor_id: str
    family_id: str
    actor_revision: int
    assert_current: object

    @property
    def id(self):
        return self.actor_id


class MediaPlaybackWorkerProvider:
    """Add encrypted bootstrap authority only at the private worker boundary."""

    def __init__(self, backend, bootstraps):
        if (not callable(getattr(backend, 'read_media_playback', None))
                or not callable(getattr(backend, 'execute_media_playback', None))
                or not callable(getattr(bootstraps, 'playback_private', None))):
            raise ValueError('invalid_media_playback_provider')
        self.backend = backend
        self.bootstraps = bootstraps

    def __repr__(self):
        return 'MediaPlaybackWorkerProvider(<private>)'

    def _retained(self, installation_id, installation_revision, selected,
                  gate):
        try:
            if gate() is not True:
                return False
            current = self.bootstraps.playback_private(
                installation_id, installation_revision)
            return (current.bootstrap_revision == selected.bootstrap_revision
                    and current.plan == selected.plan
                    and hmac.compare_digest(
                        current.api_key, selected.api_key)
                    and hmac.compare_digest(
                        current.user_id, selected.user_id))
        except Exception:
            return False

    def read_media_playback(self, authority, *, deadline, gate):
        private = self.bootstraps.playback_private(
            authority.installationId, authority.installationRevision)
        retained = lambda: self._retained(
            authority.installationId, authority.installationRevision,
            private, gate)
        if retained() is not True:
            raise ValueError('media_playback_authority_changed')
        result = self.backend.read_media_playback(
            PrivateJellyfinPlaybackAuthority(
                authority=authority, plan=private.plan,
                apiKey=private.api_key),
            deadline=deadline, gate=retained)
        if retained() is not True:
            raise ValueError('media_playback_authority_changed')
        return result

    def execute_media_playback(self, action, *, deadline, gate):
        private = self.bootstraps.playback_private(
            action.installationId, action.installationRevision)
        retained = lambda: self._retained(
            action.installationId, action.installationRevision,
            private, gate)
        if retained() is not True:
            raise ValueError('media_playback_authority_changed')
        result = self.backend.execute_media_playback(
            PrivateJellyfinPlaybackAction(
                action=action, plan=private.plan,
                apiKey=private.api_key),
            deadline=deadline, gate=retained)
        if retained() is not True:
            raise ValueError('media_playback_authority_changed')
        return result

    def read_media_segments(self, authority, *, request_id, deadline, gate):
        reader = getattr(self.backend, 'read_media_segments', None)
        if not callable(reader):
            raise ValueError('media_playback_worker_unavailable')
        private = self.bootstraps.playback_private(
            authority.installationId, authority.installationRevision)
        retained = lambda: self._retained(
            authority.installationId, authority.installationRevision,
            private, gate)
        if retained() is not True:
            raise ValueError('media_playback_authority_changed')
        result = reader(
            PrivateJellyfinMediaSegmentsAuthority(
                requestId=request_id, authority=authority, plan=private.plan,
                apiKey=private.api_key),
            deadline=deadline, gate=retained)
        if retained() is not True:
            raise ValueError('media_playback_authority_changed')
        return result

    def read_offline_media_chunk(self, authority, *, request_id, offset,
                                 length, deadline, gate):
        reader = getattr(self.backend, 'read_offline_media_chunk', None)
        if not callable(reader):
            raise ValueError('media_playback_worker_unavailable')
        private = self.bootstraps.playback_private(
            authority.installationId, authority.installationRevision)
        retained = lambda: self._retained(
            authority.installationId, authority.installationRevision,
            private, gate)
        if retained() is not True:
            raise ValueError('media_playback_authority_changed')
        result = reader(
            PrivateJellyfinOfflineMediaChunkAuthority(
                requestId=request_id, authority=authority, offset=offset,
                length=length, plan=private.plan, apiKey=private.api_key),
            deadline=deadline, gate=retained)
        if retained() is not True or type(result) is not OfflineMediaChunkReadback:
            raise ValueError('media_playback_authority_changed')
        return result

    def read_playback_info(self, authority, *, request_id, profile,
                           expected_content_length, deadline, gate):
        reader = getattr(self.backend, 'read_playback_info', None)
        if not callable(reader):
            raise ValueError('media_playback_worker_unavailable')
        private = self.bootstraps.playback_private(
            authority.installationId, authority.installationRevision)
        retained = lambda: self._retained(
            authority.installationId, authority.installationRevision,
            private, gate)
        if retained() is not True:
            raise ValueError('media_playback_authority_changed')
        result = reader(
            PrivateJellyfinPlaybackInfoAuthority(
                requestId=request_id, authority=authority, profile=profile,
                expectedContentLength=expected_content_length,
                plan=private.plan, apiKey=private.api_key,
                userId=private.user_id),
            deadline=deadline, gate=retained)
        if (retained() is not True
                or type(result) is not PlaybackInfoReadback
                or result.profileDigest
                != local_playback_profile_digest(profile)):
            raise ValueError('media_playback_authority_changed')
        return result


class MediaPlaybackManagement:
    def __init__(self, db, auth, settings, archive, backend=None, context=None):
        self.db, self.auth, self.settings = db, auth, settings
        self.archive, self.backend, self.context = archive, backend, context
        self._playback_info_observations = {}
        self._playback_info_lock = threading.RLock()

    def _prune_playback_info(self, now):
        expired = [
            key for key, value in self._playback_info_observations.items()
            if value['expires_at'] <= now
        ]
        for key in expired:
            self._playback_info_observations.pop(key, None)

    def record_playback_info_observation(
            self, actor, actor_revision, authority, profile, readback):
        if (self.context is None
                or type(authority) is not PrivateMediaPlaybackAuthority
                or type(readback) is not PlaybackInfoReadback
                or readback.itemId != authority.itemId
                or readback.profileDigest
                != local_playback_profile_digest(profile)
                or self._gate(actor, authority, actor_revision) is not True):
            raise ApiError('media_playback_authority_changed', 409)
        now = int(self.settings.clock())
        with self._playback_info_lock:
            self._prune_playback_info(now)
            owned = sum(
                value['actor_id'] == actor.id
                for value in self._playback_info_observations.values())
            if (owned >= _MAX_PLAYBACK_INFO_OBSERVATIONS_PER_ACTOR
                    or len(self._playback_info_observations)
                    >= _MAX_PLAYBACK_INFO_OBSERVATIONS):
                raise ApiError('media_playback_observation_limit_reached', 429)
            observation_id = None
            for _ in range(8):
                observation_id = secrets.token_hex(16)
                if observation_id not in self._playback_info_observations:
                    break
            if (observation_id is None
                    or observation_id in self._playback_info_observations):
                raise ApiError(
                    'media_playback_observation_limit_reached', 429)
            self._playback_info_observations[observation_id] = {
                'id': observation_id,
                'actor_id': actor.id,
                'family_id': actor.family_id,
                'actor_revision': actor_revision,
                'core_id': self.context.coreId,
                'home_id': self.context.homeId,
                'authority': authority,
                'profile_digest': readback.profileDigest,
                'outcome': readback.originalByteOutcome,
                'expires_at': now + _PLAYBACK_INFO_TTL,
            }
        return observation_id, now, now + _PLAYBACK_INFO_TTL

    def consume_playback_info_observation(
            self, actor, observation_id, authority):
        now = int(self.settings.clock())
        with self._playback_info_lock:
            self._prune_playback_info(now)
            stored = self._playback_info_observations.get(observation_id)
            if (stored is None or stored['actor_id'] != actor.id
                    or stored['family_id'] != actor.family_id):
                raise ApiError('not_found', 404)
            row = dict(stored)
        if (row['core_id'] != self.context.coreId
                or row['home_id'] != self.context.homeId
                or row['authority'] != authority):
            raise ApiError('offline_media_authority_changed', 409)
        with self.db.connection() as connection:
            actor_revision = self._current_actor_revision(connection, actor)
        if (actor_revision != row['actor_revision']
                or self._gate(actor, authority, actor_revision) is not True):
            raise ApiError('offline_media_authority_changed', 409)
        with self._playback_info_lock:
            # The DB and current authority checks may cross the inclusive
            # observation expiry. Recheck under the consuming CAS lock.
            self._prune_playback_info(int(self.settings.clock()))
            current = self._playback_info_observations.get(observation_id)
            if current is None:
                raise ApiError('not_found', 404)
            if current != stored:
                raise ApiError('offline_media_authority_changed', 409)
            self._playback_info_observations.pop(observation_id, None)
        if row['outcome'] != 'direct_play_supported':
            raise ApiError('offline_media_unavailable', 409)
        return row

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                rows = connection.execute(
                    'SELECT targets_json FROM media_playback_intents LIMIT ?',
                    (_MAX_RECORDS + 1,),
                ).fetchall()
                receipt_rows = connection.execute(
                    _RECEIPT_QUERY + ' LIMIT ?',
                    (_MAX_RECORDS + 1,),
                ).fetchall()
                if len(rows) > _MAX_RECORDS or len(receipt_rows) > _MAX_RECORDS:
                    raise ValueError()
                for row in rows:
                    targets = json.loads(row['targets_json'])
                    MediaPlaybackReadback(
                        playbackRevision=1, targets=targets)
                for row in receipt_rows:
                    self._validated_receipt_row(row)
        except (ValidationError, ValueError, TypeError, json.JSONDecodeError):
            raise StartupError('invalid_media_playback_storage') from None

    @classmethod
    def _prune_succeeded(cls, connection, count):
        rows = connection.execute(
            _RECEIPT_QUERY
            + " WHERE r.state='succeeded' ORDER BY r.created_at,r.request_id "
            'LIMIT ?',
            (count,),
        ).fetchall()
        for row in rows:
            cls._validated_receipt_row(row)
        for row in rows:
            deleted_receipt = connection.execute(
                "DELETE FROM media_playback_receipts "
                "WHERE request_id=? AND intent_id=? AND state='succeeded'",
                (row['receipt_request_id'], row['receipt_intent_id']),
            ).rowcount
            deleted_intent = connection.execute(
                'DELETE FROM media_playback_intents '
                'WHERE id=? AND consumed_by=?',
                (row['receipt_intent_id'], row['receipt_request_id']),
            ).rowcount
            if deleted_receipt != 1 or deleted_intent != 1:
                raise ApiError('media_playback_storage_unavailable', 503)
        return len(rows)

    def _make_intent_room(self, connection):
        connection.execute(
            'DELETE FROM media_playback_intents '
            'WHERE consumed_by IS NULL AND expires_at<=?',
            (int(self.settings.clock()),),
        )
        count = connection.execute(
            'SELECT COUNT(*) AS count FROM media_playback_intents'
        ).fetchone()['count']
        required = max(0, count - _MAX_RECORDS + 1)
        if required and self._prune_succeeded(connection, required) != required:
            raise ApiError('media_playback_storage_unavailable', 503)

    def _catalog(self, actor, body):
        if type(actor) is _DurablePlaybackScope:
            return self._scoped_catalog(actor, body)
        authority, observation = self.archive._collect(
            actor, body, member=True)
        jellyfin = next(
            item for item in authority.sources if item.serviceId == 'jellyfin')
        if jellyfin.serviceRevision != body.expectedJellyfinServiceRevision:
            raise ApiError('media_playback_authority_changed', 409)
        item = next((item for item in observation.jellyfin.items
                     if item.itemId == body.itemId
                     and item.mediaKey == body.mediaKey
                     and item.integrity == 'playable'), None)
        if item is None:
            raise ApiError('media_playback_item_changed', 409)
        return PrivateMediaPlaybackAuthority(
            installationId=authority.installationId,
            installationRevision=authority.installationRevision,
            snapshotRevision=authority.snapshotRevision,
            jellyfinServiceRevision=jellyfin.serviceRevision,
            itemId=item.itemId,
            mediaKey=item.mediaKey,
        )

    @staticmethod
    def _scope(actor_id, family_id, actor_revision, assert_current):
        if (type(actor_id) is not str or len(actor_id) != 32
                or type(family_id) is not str or len(family_id) != 32
                or type(actor_revision) is not int or actor_revision < 1
                or not callable(assert_current)):
            raise ApiError('invalid_request')
        return _DurablePlaybackScope(
            actor_id, family_id, actor_revision, assert_current)

    def _assert_scoped_resource(self, connection, scope, authority):
        scope.assert_current(connection)
        rows = connection.execute(
            'SELECT * FROM media_installations ORDER BY sequence DESC LIMIT ?',
            (MAX_INSTALLATIONS + 1,),
        ).fetchall()
        if len(rows) > MAX_INSTALLATIONS:
            raise ApiError('media_playback_authority_changed', 409)
        candidates = []
        for row in rows:
            payload = self.archive.installations._decode(row)
            public = self.archive.installations._public(row, payload)
            if (public['serviceId'] == 'jellyfin'
                    and row['state'] == 'container_started'
                    and row['phase'] == 'complete'
                    and not row['cancel_requested']
                    and row['error_code'] is None):
                candidates.append(row)
        if (len(candidates) != 1
                or candidates[0]['id'] != authority.installationId
                or candidates[0]['revision']
                != authority.installationRevision):
            raise ApiError('media_playback_authority_changed', 409)

    def _scoped_gate(self, scope, authority):
        try:
            with self.db.connection() as connection:
                self._assert_scoped_resource(connection, scope, authority)

            class Body:
                installationId = authority.installationId
                expectedInstallationRevision = authority.installationRevision
                expectedSnapshotRevision = authority.snapshotRevision

            current = self.archive._authority(Body(), int(self.settings.clock()))
            jellyfin = next(
                item for item in current.sources if item.serviceId == 'jellyfin')
            return jellyfin.serviceRevision == authority.jellyfinServiceRevision
        except Exception:  # durable authority callbacks fail closed
            return False

    def _scoped_catalog(self, scope, body):
        if self.archive.binding_reader is None or self.archive.backend is None:
            raise ApiError('media_archive_worker_unavailable', 503)
        expected = PrivateMediaPlaybackAuthority(
            installationId=body.installationId,
            installationRevision=body.expectedInstallationRevision,
            snapshotRevision=body.expectedSnapshotRevision,
            jellyfinServiceRevision=body.expectedJellyfinServiceRevision,
            itemId=body.itemId, mediaKey=body.mediaKey,
        )
        with self.db.connection() as connection:
            self._assert_scoped_resource(connection, scope, expected)
        current = self.archive._authority(body, int(self.settings.clock()))
        jellyfin = next(
            item for item in current.sources if item.serviceId == 'jellyfin')
        if jellyfin.serviceRevision != expected.jellyfinServiceRevision:
            raise ApiError('media_playback_authority_changed', 409)
        deadline = time.monotonic() + 5
        gate = lambda: (
            time.monotonic() < deadline
            and self._scoped_gate(scope, expected))
        try:
            observed = self.archive.backend.read_media_archive(
                PrivateMediaArchiveCollection(
                    requestId=body.requestId, authority=current),
                deadline=deadline, gate=gate)
            if gate() is not True:
                raise ValueError()
            current_after = self.archive._authority(
                body, int(self.settings.clock()))
            if current_after != current:
                raise ValueError()
            observation = self.archive._observation(observed)
            self.archive._match(current_after, observation)
        except ApiError:
            raise
        except Exception:
            raise ApiError('media_archive_worker_unavailable', 503) from None
        item = next((item for item in observation.jellyfin.items
                     if item.itemId == body.itemId
                     and item.mediaKey == body.mediaKey
                     and item.integrity == 'playable'), None)
        if item is None:
            raise ApiError('media_playback_item_changed', 409)
        return expected

    def _gate(self, actor, authority, actor_revision=None):
        if type(actor) is _DurablePlaybackScope:
            return (actor_revision in (None, actor.actor_revision)
                    and self._scoped_gate(actor, authority))
        try:
            with self.db.connection() as connection:
                self.auth.assert_current(connection, actor)
                row = connection.execute(
                    'SELECT revision FROM users WHERE id=?',
                    (actor.id,)).fetchone()
                if (actor.must_change_password or row is None
                        or actor_revision is not None
                        and row['revision'] != actor_revision):
                    return False
            class Body:
                installationId = authority.installationId
                expectedInstallationRevision = authority.installationRevision
                expectedSnapshotRevision = authority.snapshotRevision
            self.archive._session_gate(actor, Body(), member=True)
            current = self.archive._authority(
                Body(), int(self.settings.clock()))
            jellyfin = next(
                item for item in current.sources if item.serviceId == 'jellyfin')
            return jellyfin.serviceRevision == authority.jellyfinServiceRevision
        except Exception:  # noqa: BLE001 - authority callbacks fail closed
            return False

    def _readback(self, actor, authority, actor_revision=None):
        if self.backend is None:
            raise ApiError('media_playback_worker_unavailable', 503)
        deadline = time.monotonic() + 5
        gate = lambda: (
            time.monotonic() < deadline
            and self._gate(actor, authority, actor_revision))
        try:
            result = self.backend.read_media_playback(
                authority, deadline=deadline, gate=gate)
            if type(result) is not MediaPlaybackReadback or gate() is not True:
                raise ValueError()
            return MediaPlaybackReadback.model_validate(
                result.model_dump(mode='python'))
        except ApiError:
            raise
        except Exception:  # noqa: BLE001 - private worker errors stay private
            raise ApiError('media_playback_worker_unavailable', 503) from None

    def _current_actor_revision(self, connection, actor):
        if type(actor) is _DurablePlaybackScope:
            actor.assert_current(connection)
            return actor.actor_revision
        self.auth.assert_current(connection, actor)
        row = connection.execute(
            'SELECT revision FROM users WHERE id=?',
            (actor.id,)).fetchone()
        if row is None or actor.must_change_password:
            raise ApiError('invalid_session', 401)
        return row['revision']

    def _actor_revision(self, actor):
        with self.db.connection() as connection:
            return self._current_actor_revision(connection, actor)

    def segments(self, actor, body):
        if type(body) is not MediaSegmentsRequest or self.context is None:
            raise ApiError('invalid_request')
        actor_revision = self._actor_revision(actor)
        authority = self._catalog(actor, body)
        if self.backend is None:
            raise ApiError('media_playback_worker_unavailable', 503)
        deadline = time.monotonic() + 5
        gate = lambda: (
            time.monotonic() < deadline
            and self._gate(actor, authority, actor_revision))
        try:
            result = self.backend.read_media_segments(
                authority, request_id=body.requestId,
                deadline=deadline, gate=gate)
            if type(result) is not MediaSegmentsReadback or gate() is not True:
                raise ValueError()
            readback = MediaSegmentsReadback.model_validate(
                result.model_dump(mode='python'))
        except ApiError:
            raise
        except Exception:  # noqa: BLE001 - private worker errors stay private
            raise ApiError('media_playback_worker_unavailable', 503) from None
        if self._actor_revision(actor) != actor_revision:
            raise ApiError('media_playback_authority_changed', 409)
        public = MediaSegmentsAuthority(
            schemaVersion=1,
            coreId=self.context.coreId,
            homeId=self.context.homeId,
            accountId=actor.id,
            accountRevision=actor_revision,
            sessionFamilyId=actor.family_id,
            installationId=authority.installationId,
            installationRevision=authority.installationRevision,
            snapshotRevision=authority.snapshotRevision,
            jellyfinServiceRevision=authority.jellyfinServiceRevision,
            itemId=authority.itemId,
            mediaKey=authority.mediaKey,
        )
        response = MediaSegmentsResponse(
            schemaVersion=1, requestId=body.requestId, authority=public,
            supported=readback.supported, reason=readback.reason,
            segments=readback.segments)
        return response.model_dump(mode='python')

    def playback_info(self, actor, body):
        if type(body) is not PlaybackInfoRequest or self.context is None:
            raise ApiError('invalid_request')
        actor_revision = self._actor_revision(actor)
        current, observation = self.archive._collect(
            actor, body, member=True)
        jellyfin = next(
            item for item in current.sources if item.serviceId == 'jellyfin')
        if jellyfin.serviceRevision != body.expectedJellyfinServiceRevision:
            raise ApiError('media_playback_authority_changed', 409)
        item = next((item for item in observation.jellyfin.items
                     if item.itemId == body.itemId
                     and item.mediaKey == body.mediaKey
                     and item.integrity == 'playable'), None)
        if item is None or item.sizeBytes < 1:
            raise ApiError('media_playback_item_changed', 409)
        authority = PrivateMediaPlaybackAuthority(
            installationId=current.installationId,
            installationRevision=current.installationRevision,
            snapshotRevision=current.snapshotRevision,
            jellyfinServiceRevision=jellyfin.serviceRevision,
            itemId=item.itemId, mediaKey=item.mediaKey)
        reader = getattr(self.backend, 'read_playback_info', None)
        if not callable(reader):
            raise ApiError('media_playback_worker_unavailable', 503)
        deadline = time.monotonic() + 5

        def gate():
            return (time.monotonic() < deadline
                    and self._gate(actor, authority, actor_revision))

        try:
            result = reader(
                authority, request_id=body.requestId, profile=body.profile,
                expected_content_length=item.sizeBytes,
                deadline=deadline, gate=gate)
            if type(result) is not PlaybackInfoReadback:
                raise ValueError()
            if result.profileDigest != local_playback_profile_digest(
                    body.profile):
                raise ValueError()
            if gate() is not True:
                raise ApiError('media_playback_authority_changed', 409)
        except ApiError:
            raise
        except JellyfinPlaybackExecutionError as error:
            if error.code == 'jellyfin_playback_authority_changed':
                raise ApiError(
                    'media_playback_authority_changed', 409) from None
            raise ApiError('media_playback_worker_unavailable', 503) from None
        except ValueError as error:
            if str(error) == 'media_playback_authority_changed':
                raise ApiError(
                    'media_playback_authority_changed', 409) from None
            raise ApiError('media_playback_worker_unavailable', 503) from None
        except Exception:
            raise ApiError('media_playback_worker_unavailable', 503) from None
        if self._actor_revision(actor) != actor_revision:
            raise ApiError('media_playback_authority_changed', 409)
        return actor_revision, authority, result

    def prepare(self, actor, body):
        if type(body) is not PrepareMediaPlaybackIntentRequest:
            raise ApiError('invalid_request')
        actor_revision = self._actor_revision(actor)
        authority = self._catalog(actor, body)
        readback = self._readback(actor, authority, actor_revision)
        expires = int(self.settings.clock()) + 30
        intent = MediaPlaybackIntent(
            **body.model_dump(), playbackRevision=readback.playbackRevision,
            expiresAt=expires, targets=readback.targets)
        targets = json.dumps(
            [item.model_dump(mode='json') for item in readback.targets],
            separators=(',', ':'), sort_keys=True)
        try:
            with self.db.transaction() as connection:
                if (self._current_actor_revision(connection, actor)
                        != actor_revision):
                    raise ApiError('media_playback_authority_changed', 409)
                existing = connection.execute(
                    'SELECT 1 FROM media_playback_intents WHERE id=?',
                    (body.requestId,)).fetchone()
                if existing is not None:
                    raise ApiError('media_playback_intent_conflict', 409)
                self._make_intent_room(connection)
                connection.execute(
                    'INSERT INTO media_playback_intents('
                    'id,actor_id,actor_revision,family_id,installation_id,'
                    'installation_revision,snapshot_revision,'
                    'jellyfin_service_revision,item_id,media_key,'
                    'playback_revision,targets_json,expires_at,consumed_by) '
                    'VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,NULL)',
                    (body.requestId, actor.id, actor_revision, actor.family_id,
                     body.installationId,
                     body.expectedInstallationRevision,
                     body.expectedSnapshotRevision,
                     body.expectedJellyfinServiceRevision,
                     body.itemId, body.mediaKey, readback.playbackRevision,
                     targets, expires))
        except ApiError:
            raise
        except Exception:  # noqa: BLE001 - storage details never cross HTTP
            raise ApiError('media_playback_storage_unavailable', 503) from None
        return {'intent': intent.model_dump()}

    def _prepare_scoped(self, actor_id, family_id, actor_revision, body,
                        assert_current):
        return self.prepare(
            self._scope(actor_id, family_id, actor_revision, assert_current),
            body,
        )

    @staticmethod
    def _request_json(body):
        return json.dumps(body.model_dump(mode='json'), separators=(',', ':'),
                          sort_keys=True)

    @staticmethod
    def _receipt_json(receipt):
        return json.dumps(receipt.model_dump(mode='json'), separators=(',', ':'),
                          sort_keys=True)

    @classmethod
    def _validated_receipt_row(cls, row):
        if row is None or row['stored_intent_id'] is None:
            raise ValueError()
        request = MediaPlaybackCommandRequest.model_validate_json(
            row['receipt_request_json'])
        if (cls._request_json(request) != row['receipt_request_json']
                or request.requestId != row['receipt_request_id']
                or request.intentId != row['receipt_intent_id']
                or row['receipt_intent_id'] != row['stored_intent_id']
                or row['receipt_actor_id'] != row['intent_actor_id']
                or type(row['intent_actor_revision']) is not int
                or row['intent_actor_revision'] < 1
                or type(row['intent_family_id']) is not str
                or len(row['intent_family_id']) != 32
                or row['intent_consumed_by'] != row['receipt_request_id']
                or request.expectedPlaybackRevision
                != row['intent_playback_revision']):
            raise ValueError()
        targets = MediaPlaybackReadback(
            playbackRevision=row['intent_playback_revision'],
            targets=json.loads(row['intent_targets_json'])).targets
        if not any(
                item.targetId == request.targetId
                and item.targetRevision == request.expectedTargetRevision
                and item.available for item in targets):
            raise ValueError()
        if row['receipt_state'] == 'pending':
            if row['stored_receipt_json'] is not None:
                raise ValueError()
            return request, None
        if row['receipt_state'] != 'succeeded' or row['stored_receipt_json'] is None:
            raise ValueError()
        receipt = MediaPlaybackReceipt.model_validate_json(
            row['stored_receipt_json'])
        if (cls._receipt_json(receipt) != row['stored_receipt_json']
                or receipt.requestId != request.requestId
                or receipt.intentId != request.intentId
                or receipt.installationId != row['installation_id']
                or receipt.itemId != row['item_id']
                or receipt.targetId != request.targetId
                or receipt.playbackRevision <= request.expectedPlaybackRevision
                or receipt.state != 'succeeded'
                or receipt.code != 'authenticated_readback'):
            raise ValueError()
        return request, receipt

    @staticmethod
    def _receipt(row, body, *, uncertain=False):
        return MediaPlaybackReceipt(
            requestId=body.requestId, intentId=body.intentId,
            installationId=row['installation_id'], itemId=row['item_id'],
            targetId=body.targetId,
            playbackRevision=(body.expectedPlaybackRevision if uncertain
                              else body.expectedPlaybackRevision + 1),
            state='needs_attention' if uncertain else 'succeeded',
            code='effect_unknown' if uncertain else 'authenticated_readback',
        )

    def _retire_no_effect(self, actor, body, encoded):
        try:
            with self.db.transaction() as connection:
                row = connection.execute(
                    _RECEIPT_QUERY + ' WHERE r.request_id=?',
                    (body.requestId,),
                ).fetchone()
                stored_request, stored_receipt = self._validated_receipt_row(row)
                if (stored_receipt is not None or stored_request != body
                        or row['receipt_actor_id'] != actor.id
                        or row['receipt_request_json'] != encoded):
                    raise ValueError()
                deleted_receipt = connection.execute(
                    "DELETE FROM media_playback_receipts "
                    "WHERE request_id=? AND intent_id=? AND actor_id=? "
                    "AND request_json=? AND state='pending' "
                    "AND receipt_json IS NULL",
                    (body.requestId, body.intentId, actor.id, encoded),
                ).rowcount
                deleted_intent = connection.execute(
                    'DELETE FROM media_playback_intents '
                    'WHERE id=? AND actor_id=? AND consumed_by=?',
                    (body.intentId, actor.id, body.requestId),
                ).rowcount
                if deleted_receipt != 1 or deleted_intent != 1:
                    raise ValueError()
        except ApiError:
            raise
        except (ValidationError, ValueError, TypeError, json.JSONDecodeError):
            raise ApiError('media_playback_storage_unavailable', 503) from None

    def command(self, actor, body, *, effect_gate=None):
        if (type(body) is not MediaPlaybackCommandRequest
                or effect_gate is not None and not callable(effect_gate)):
            raise ApiError('invalid_request')
        effect_current = lambda: (
            effect_gate is None or effect_gate() is True)
        try:
            if effect_current() is not True:
                raise ValueError()
        except Exception:
            raise ApiError('media_playback_authority_changed', 409) from None
        encoded = self._request_json(body)
        with self.db.connection() as connection:
            actor_revision = self._current_actor_revision(connection, actor)
            receipt_row = connection.execute(
                _RECEIPT_QUERY + ' WHERE r.request_id=?',
                (body.requestId,)).fetchone()
            if receipt_row is not None:
                try:
                    stored_request, stored_receipt = (
                        self._validated_receipt_row(receipt_row))
                except (ValidationError, ValueError, TypeError,
                        json.JSONDecodeError):
                    raise ApiError(
                        'media_playback_storage_unavailable', 503) from None
                if (receipt_row['receipt_actor_id'] != actor.id
                        or receipt_row['intent_actor_revision']
                        != actor_revision
                        or receipt_row['intent_family_id'] != actor.family_id
                        or stored_request != body
                        or receipt_row['receipt_request_json'] != encoded):
                    raise ApiError('media_playback_command_conflict', 409)
                if stored_receipt is not None:
                    return {'receipt': stored_receipt.model_dump()}
                return {'receipt': self._receipt(
                    receipt_row, stored_request, uncertain=True).model_dump()}
            now = int(self.settings.clock())
            row = connection.execute(
                'SELECT * FROM media_playback_intents '
                'WHERE id=? AND actor_id=? AND actor_revision=? '
                'AND family_id=? AND consumed_by IS NULL '
                'AND expires_at>? AND playback_revision=?',
                (body.intentId, actor.id, actor_revision, actor.family_id,
                 now, body.expectedPlaybackRevision)).fetchone()
            if row is None:
                binding = connection.execute(
                    'SELECT actor_id,actor_revision,family_id '
                    'FROM media_playback_intents WHERE id=?',
                    (body.intentId,)).fetchone()
                if (binding is None or binding['actor_id'] != actor.id
                        or binding['actor_revision'] != actor_revision
                        or binding['family_id'] != actor.family_id):
                    raise ApiError('media_playback_intent_unavailable', 409)
                raise ApiError('media_playback_intent_conflict', 409)
        targets = MediaPlaybackReadback(
            playbackRevision=row['playback_revision'],
            targets=json.loads(row['targets_json'])).targets
        target = next((item for item in targets
                       if item.targetId == body.targetId
                       and item.targetRevision == body.expectedTargetRevision
                       and item.available), None)
        if target is None:
            raise ApiError('media_playback_target_changed', 409)
        authority = PrivateMediaPlaybackAuthority(
            installationId=row['installation_id'],
            installationRevision=row['installation_revision'],
            snapshotRevision=row['snapshot_revision'],
            jellyfinServiceRevision=row['jellyfin_service_revision'],
            itemId=row['item_id'], mediaKey=row['media_key'])
        current = self._readback(actor, authority, actor_revision)
        fresh = next((item for item in current.targets
                      if item.targetId == body.targetId
                      and item.targetRevision == body.expectedTargetRevision
                      and item.available), None)
        if (current.playbackRevision != body.expectedPlaybackRevision
                or fresh is None):
            raise ApiError('media_playback_authority_changed', 409)
        with self.db.transaction() as connection:
            fresh_actor_revision = self._current_actor_revision(
                connection, actor)
            receipt_count = connection.execute(
                'SELECT COUNT(*) AS count FROM media_playback_receipts'
            ).fetchone()['count']
            required = max(0, receipt_count - _MAX_RECORDS + 1)
            try:
                if (required and self._prune_succeeded(
                        connection, required) != required):
                    raise ValueError()
            except (ValidationError, ValueError, TypeError,
                    json.JSONDecodeError):
                raise ApiError(
                    'media_playback_storage_unavailable', 503) from None
            changed = connection.execute(
                'UPDATE media_playback_intents SET consumed_by=? '
                'WHERE id=? AND actor_id=? AND actor_revision=? '
                'AND family_id=? AND playback_revision=? '
                'AND consumed_by IS NULL AND expires_at>?',
                (body.requestId, body.intentId, actor.id,
                 fresh_actor_revision, actor.family_id,
                 body.expectedPlaybackRevision,
                 int(self.settings.clock()))).rowcount
            if changed != 1:
                raise ApiError('media_playback_intent_conflict', 409)
            connection.execute(
                'INSERT INTO media_playback_receipts VALUES(?,?,?,?,?,?,?)',
                (body.requestId, body.intentId, actor.id, encoded,
                 'pending', None, int(self.settings.clock())))
        action = PrivateMediaPlaybackAction(
            **body.model_dump(), installationId=row['installation_id'],
            installationRevision=row['installation_revision'],
            snapshotRevision=row['snapshot_revision'],
            jellyfinServiceRevision=row['jellyfin_service_revision'],
            itemId=row['item_id'], mediaKey=row['media_key'])
        deadline = time.monotonic() + 5
        gate = lambda: (
            time.monotonic() < deadline
            and self._gate(actor, authority, actor_revision)
            and effect_current())
        try:
            result = self.backend.execute_media_playback(
                action, deadline=deadline, gate=gate)
            if type(result) is not MediaPlaybackWorkerResult:
                raise ValueError()
            result = MediaPlaybackWorkerResult.model_validate(
                result.model_dump(mode='python'))
            if (gate() is not True
                    or result.playbackRevision <= body.expectedPlaybackRevision
                    or result.target.targetId != body.targetId
                    or result.target.targetRevision <= body.expectedTargetRevision
                    or result.target.currentItemId != row['item_id']
                    or abs(result.target.positionSeconds-body.startSeconds) > 2):
                raise ValueError()
        except JellyfinPlaybackExecutionError as error:
            if error.uncertain_effect:
                if not self._gate(actor, authority, actor_revision):
                    with self.db.connection() as connection:
                        self._current_actor_revision(connection, actor)
                raise ApiError(
                    'media_playback_worker_unavailable', 503) from None
            self._retire_no_effect(actor, body, encoded)
            if error.code == 'jellyfin_playback_authority_changed':
                if not self._gate(actor, authority, actor_revision):
                    with self.db.connection() as connection:
                        self._current_actor_revision(connection, actor)
                raise ApiError('media_playback_authority_changed', 409) from None
            raise ApiError('media_playback_worker_unavailable', 503) from None
        except Exception:  # noqa: BLE001 - dispatched effect is now uncertain
            if not self._gate(actor, authority, actor_revision):
                with self.db.connection() as connection:
                    self._current_actor_revision(connection, actor)
            raise ApiError('media_playback_worker_unavailable', 503) from None
        receipt = MediaPlaybackReceipt(
            requestId=body.requestId, intentId=body.intentId,
            installationId=row['installation_id'], itemId=row['item_id'],
            targetId=body.targetId, playbackRevision=result.playbackRevision,
            state='succeeded', code='authenticated_readback')
        with self.db.transaction() as connection:
            # Keep a caller-owned authority fence inside the final transaction:
            # cancellation after worker readback must retain the pending attempt.
            try:
                if effect_current() is not True:
                    raise ValueError()
            except Exception:
                raise ApiError('media_playback_worker_unavailable', 503) from None
            if (self._current_actor_revision(connection, actor)
                    != actor_revision):
                raise ApiError('media_playback_worker_unavailable', 503)
            try:
                stored_row = connection.execute(
                    _RECEIPT_QUERY + ' WHERE r.request_id=?',
                    (body.requestId,),
                ).fetchone()
                stored_request, stored_receipt = (
                    self._validated_receipt_row(stored_row))
                if (stored_receipt is not None
                        or stored_request != body
                        or stored_row['receipt_actor_id'] != actor.id
                        or stored_row['intent_actor_revision']
                        != actor_revision
                        or stored_row['intent_family_id'] != actor.family_id):
                    raise ValueError()
            except (ValidationError, ValueError, TypeError,
                    json.JSONDecodeError):
                raise ApiError(
                    'media_playback_worker_unavailable', 503) from None
            changed = connection.execute(
                "UPDATE media_playback_receipts SET state='succeeded',"
                'receipt_json=? WHERE request_id=? AND intent_id=? '
                'AND actor_id=? AND request_json=? AND state=\'pending\' '
                'AND receipt_json IS NULL',
                (self._receipt_json(receipt), body.requestId, body.intentId,
                 actor.id, encoded)).rowcount
            if changed != 1:
                raise ApiError('media_playback_worker_unavailable', 503)
        return {'receipt': receipt.model_dump()}

    def _command_scoped(self, actor_id, family_id, actor_revision, body,
                        assert_current, *, effect_gate=None):
        return self.command(
            self._scope(actor_id, family_id, actor_revision, assert_current),
            body, effect_gate=effect_gate,
        )
