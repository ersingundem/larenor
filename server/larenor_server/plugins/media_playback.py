"""Revision-bound managed Jellyfin playback with one-use command ownership."""

import json
import time

from pydantic import ValidationError

from ..errors import ApiError, StartupError
from .media_playback_models import (
    MediaPlaybackCommandRequest,
    MediaPlaybackIntent,
    MediaPlaybackReadback,
    MediaPlaybackReceipt,
    MediaPlaybackWorkerResult,
    PrepareMediaPlaybackIntentRequest,
    PrivateMediaPlaybackAction,
    PrivateMediaPlaybackAuthority,
)

_MAX_RECORDS = 256
_RECEIPT_QUERY = '''SELECT
    r.request_id AS receipt_request_id,
    r.intent_id AS receipt_intent_id,
    r.actor_id AS receipt_actor_id,
    r.request_json AS receipt_request_json,
    r.state AS receipt_state,
    r.receipt_json AS stored_receipt_json,
    i.id AS stored_intent_id,
    i.actor_id AS intent_actor_id,
    i.installation_id AS installation_id,
    i.item_id AS item_id,
    i.playback_revision AS intent_playback_revision,
    i.targets_json AS intent_targets_json,
    i.consumed_by AS intent_consumed_by
FROM media_playback_receipts r
LEFT JOIN media_playback_intents i ON i.id=r.intent_id'''


class MediaPlaybackManagement:
    def __init__(self, db, auth, settings, archive, backend=None):
        self.db, self.auth, self.settings = db, auth, settings
        self.archive, self.backend = archive, backend

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

    @staticmethod
    def _prune_succeeded(connection, count):
        rows = connection.execute(
            "SELECT request_id,intent_id FROM media_playback_receipts "
            "WHERE state='succeeded' ORDER BY created_at,request_id LIMIT ?",
            (count,),
        ).fetchall()
        for row in rows:
            deleted_receipt = connection.execute(
                "DELETE FROM media_playback_receipts "
                "WHERE request_id=? AND intent_id=? AND state='succeeded'",
                (row['request_id'], row['intent_id']),
            ).rowcount
            deleted_intent = connection.execute(
                'DELETE FROM media_playback_intents '
                'WHERE id=? AND consumed_by=?',
                (row['intent_id'], row['request_id']),
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

    def _gate(self, actor, authority):
        try:
            with self.db.connection() as connection:
                self.auth.assert_current(connection, actor)
                if actor.must_change_password:
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

    def _readback(self, actor, authority):
        if self.backend is None:
            raise ApiError('media_playback_worker_unavailable', 503)
        deadline = time.monotonic() + 5
        gate = lambda: time.monotonic() < deadline and self._gate(actor, authority)
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

    def prepare(self, actor, body):
        if type(body) is not PrepareMediaPlaybackIntentRequest:
            raise ApiError('invalid_request')
        authority = self._catalog(actor, body)
        readback = self._readback(actor, authority)
        expires = int(self.settings.clock()) + 30
        intent = MediaPlaybackIntent(
            **body.model_dump(), playbackRevision=readback.playbackRevision,
            expiresAt=expires, targets=readback.targets)
        targets = json.dumps(
            [item.model_dump(mode='json') for item in readback.targets],
            separators=(',', ':'), sort_keys=True)
        try:
            with self.db.transaction() as connection:
                self.auth.assert_current(connection, actor)
                existing = connection.execute(
                    'SELECT 1 FROM media_playback_intents WHERE id=?',
                    (body.requestId,)).fetchone()
                if existing is not None:
                    raise ApiError('media_playback_intent_conflict', 409)
                self._make_intent_room(connection)
                connection.execute(
                    'INSERT INTO media_playback_intents VALUES('
                    '?,?,?,?,?,?,?,?,?,?,?,NULL)',
                    (body.requestId, actor.id, body.installationId,
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

    def command(self, actor, body):
        if type(body) is not MediaPlaybackCommandRequest:
            raise ApiError('invalid_request')
        encoded = self._request_json(body)
        with self.db.connection() as connection:
            self.auth.assert_current(connection, actor)
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
                        or stored_request != body
                        or receipt_row['receipt_request_json'] != encoded):
                    raise ApiError('media_playback_command_conflict', 409)
                if stored_receipt is not None:
                    return {'receipt': stored_receipt.model_dump()}
                return {'receipt': self._receipt(
                    receipt_row, stored_request, uncertain=True).model_dump()}
            row = connection.execute(
                'SELECT * FROM media_playback_intents WHERE id=?',
                (body.intentId,)).fetchone()
        if row is None or row['actor_id'] != actor.id:
            raise ApiError('media_playback_intent_unavailable', 409)
        if (row['consumed_by'] is not None
                or int(self.settings.clock()) >= row['expires_at']
                or row['playback_revision'] != body.expectedPlaybackRevision):
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
        current = self._readback(actor, authority)
        fresh = next((item for item in current.targets
                      if item.targetId == body.targetId
                      and item.targetRevision == body.expectedTargetRevision
                      and item.available), None)
        if (current.playbackRevision != body.expectedPlaybackRevision
                or fresh is None):
            raise ApiError('media_playback_authority_changed', 409)
        with self.db.transaction() as connection:
            self.auth.assert_current(connection, actor)
            receipt_count = connection.execute(
                'SELECT COUNT(*) AS count FROM media_playback_receipts'
            ).fetchone()['count']
            required = max(0, receipt_count - _MAX_RECORDS + 1)
            if (required
                    and self._prune_succeeded(connection, required) != required):
                raise ApiError('media_playback_storage_unavailable', 503)
            changed = connection.execute(
                'UPDATE media_playback_intents SET consumed_by=? '
                'WHERE id=? AND consumed_by IS NULL',
                (body.requestId, body.intentId)).rowcount
            if changed != 1:
                raise ApiError('media_playback_intent_conflict', 409)
            connection.execute(
                'INSERT INTO media_playback_receipts VALUES(?,?,?,?,?,?,?)',
                (body.requestId, body.intentId, actor.id, encoded,
                 'pending', None, int(self.settings.clock())))
        action = PrivateMediaPlaybackAction(
            **body.model_dump(), installationId=row['installation_id'],
            itemId=row['item_id'], mediaKey=row['media_key'])
        deadline = time.monotonic() + 5
        gate = lambda: time.monotonic() < deadline and self._gate(actor, authority)
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
        except Exception:  # noqa: BLE001 - dispatched effect is now uncertain
            if not self._gate(actor, authority):
                with self.db.connection() as connection:
                    self.auth.assert_current(connection, actor)
            raise ApiError('media_playback_worker_unavailable', 503) from None
        receipt = MediaPlaybackReceipt(
            requestId=body.requestId, intentId=body.intentId,
            installationId=row['installation_id'], itemId=row['item_id'],
            targetId=body.targetId, playbackRevision=result.playbackRevision,
            state='succeeded', code='authenticated_readback')
        with self.db.transaction() as connection:
            self.auth.assert_current(connection, actor)
            connection.execute(
                "UPDATE media_playback_receipts SET state='succeeded',"
                'receipt_json=? WHERE request_id=? AND state=\'pending\'',
                (self._receipt_json(receipt), body.requestId))
        return {'receipt': receipt.model_dump()}
