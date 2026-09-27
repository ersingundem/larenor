"""Durable revision-safe audiobook and podcast listening state."""

import hashlib
import hmac
import json
import math
import uuid

from pydantic import ValidationError

from ..errors import ApiError, StartupError
from ..plugins.music_playback_models import ReadMusicLongformRequest
from .models import (LongformBookmark, LongformSession,
                     OpenLongformSessionRequest, UpdateLongformSessionRequest)

_FIELDS = (
    "id", "actor_id", "family_id", "actor_revision", "revision",
    "media_key", "installation_id", "installation_revision",
    "core_revision", "manager_revision", "provider_instance_id",
    "media_uri", "media_type", "title", "duration_seconds",
    "position_seconds", "playback_state", "sleep_ends_at",
    "bookmarks_json", "request_id", "request_hash", "updated_at",
)


class LongformSessionService:
    def __init__(self, db, auth, settings, key, context, music_playback):
        self.db, self.auth, self.settings = db, auth, settings
        self._key, self.context = key, context
        self.music_playback = music_playback

    @staticmethod
    def _json(value):
        return json.dumps(value, sort_keys=True, separators=(",", ":"),
                          allow_nan=False)

    def _tag(self, row):
        payload = self._json({field: row[field] for field in _FIELDS}).encode()
        return hmac.new(self._key, b"larenor-longform-session-v1\0" + payload,
                        hashlib.sha256).hexdigest()

    def _row(self, row):
        if row is None or not hmac.compare_digest(
                row["envelope_tag"], self._tag(row)):
            raise StartupError("longform_session_storage_invalid")
        try:
            bookmarks = json.loads(row["bookmarks_json"])
            if type(bookmarks) is not list:
                raise ValueError()
            [LongformBookmark.model_validate(item) for item in bookmarks]
        except (ValueError, TypeError, ValidationError):
            raise StartupError("longform_session_storage_invalid") from None
        return row

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                for row in connection.execute("SELECT * FROM longform_sessions"):
                    self._row(row)
        except (StartupError, ValueError, TypeError):
            raise StartupError("longform_session_storage_invalid") from None

    def _actor(self, connection, actor):
        self.auth.assert_current(connection, actor)
        row = connection.execute(
            "SELECT id,revision,disabled,must_change_password FROM users "
            "WHERE id=?", (actor.id,)).fetchone()
        if (row is None or row["disabled"] or row["must_change_password"]
                or actor.must_change_password):
            raise ApiError("invalid_session", 401)
        return row

    @staticmethod
    def _media_key(installation, provider, uri):
        return hashlib.sha256(
            (installation + "\0" + provider + "\0" + uri).encode()
        ).hexdigest()

    @staticmethod
    def _request_hash(body):
        value = body.model_dump(mode="json")
        return hashlib.sha256(json.dumps(
            value, sort_keys=True, separators=(",", ":"),
            allow_nan=False).encode()).hexdigest()

    def _catalog_item(self, actor, body):
        query = ReadMusicLongformRequest(
            requestId=body.requestId,
            installationId=body.installationId,
            expectedInstallationRevision=body.expectedInstallationRevision,
            expectedCoreRevision=body.expectedCoreRevision,
            expectedManagerRevision=body.expectedManagerRevision,
            limit=body.limit,
        )
        result = self.music_playback.longform(actor, query)
        matches = [item for item in result["longform"]["items"]
                   if item["uri"] == body.mediaUri
                   and item["providerInstanceId"] == body.providerInstanceId]
        if len(matches) != 1:
            raise ApiError("longform_session_authority_changed", 409)
        return matches[0]

    def _snapshot(self, row, actor):
        bookmarks = [LongformBookmark.model_validate(item) for item in
                     json.loads(row["bookmarks_json"])]
        return {"session": LongformSession(
            sessionId=row["id"], revision=row["revision"],
            coreId=self.context.coreId, homeId=self.context.homeId,
            accountId=row["actor_id"], installationId=row["installation_id"],
            installationRevision=row["installation_revision"],
            coreRevision=row["core_revision"],
            managerRevision=row["manager_revision"],
            providerInstanceId=row["provider_instance_id"],
            mediaUri=row["media_uri"], mediaType=row["media_type"],
            title=row["title"], durationSeconds=row["duration_seconds"],
            positionSeconds=row["position_seconds"],
            playbackState=row["playback_state"],
            sleepTimerEndsAt=row["sleep_ends_at"], bookmarks=bookmarks,
            ownedByCurrentSession=row["family_id"] == actor.family_id,
            updatedAt=row["updated_at"],
        )}

    def _save(self, connection, row):
        value = dict(row)
        value["envelope_tag"] = self._tag(value)
        connection.execute(
            "UPDATE longform_sessions SET family_id=?,actor_revision=?,"
            "revision=?,installation_revision=?,core_revision=?,"
            "manager_revision=?,title=?,duration_seconds=?,position_seconds=?,"
            "playback_state=?,sleep_ends_at=?,bookmarks_json=?,request_id=?,"
            "request_hash=?,updated_at=?,envelope_tag=? WHERE id=?",
            (value["family_id"], value["actor_revision"], value["revision"],
             value["installation_revision"], value["core_revision"],
             value["manager_revision"], value["title"],
             value["duration_seconds"], value["position_seconds"],
             value["playback_state"], value["sleep_ends_at"],
             value["bookmarks_json"], value["request_id"],
             value["request_hash"], value["updated_at"],
             value["envelope_tag"], value["id"]))
        return value

    def open(self, actor, body):
        if type(body) is not OpenLongformSessionRequest:
            raise ApiError("invalid_request")
        item = self._catalog_item(actor, body)
        key = self._media_key(
            body.installationId, body.providerInstanceId, body.mediaUri)
        request_hash = self._request_hash(body)
        now = int(self.settings.clock())
        with self.db.transaction() as connection:
            user = self._actor(connection, actor)
            raw = connection.execute(
                "SELECT * FROM longform_sessions WHERE actor_id=? AND media_key=?",
                (actor.id, key)).fetchone()
            if raw is not None:
                row = self._row(raw)
                if (row["request_id"] == body.requestId
                        and row["request_hash"] != request_hash):
                    raise ApiError("longform_session_request_conflict", 409)
                if row["family_id"] != actor.family_id and body.takeover:
                    row = self._save(connection, dict(
                        row, family_id=actor.family_id,
                        actor_revision=user["revision"],
                        revision=row["revision"] + 1,
                        installation_revision=body.expectedInstallationRevision,
                        core_revision=body.expectedCoreRevision,
                        manager_revision=body.expectedManagerRevision,
                        title=item["name"],
                        duration_seconds=item["durationSeconds"],
                        request_id=body.requestId, request_hash=request_hash,
                        updated_at=now))
                return self._snapshot(row, actor)
            session_id = uuid.uuid4().hex
            bookmarks = self._json([])
            row = dict(
                id=session_id, actor_id=actor.id, family_id=actor.family_id,
                actor_revision=user["revision"], revision=1, media_key=key,
                installation_id=body.installationId,
                installation_revision=body.expectedInstallationRevision,
                core_revision=body.expectedCoreRevision,
                manager_revision=body.expectedManagerRevision,
                provider_instance_id=body.providerInstanceId,
                media_uri=body.mediaUri, media_type=item["mediaType"],
                title=item["name"], duration_seconds=item["durationSeconds"],
                position_seconds=item["resumePositionSeconds"],
                playback_state="paused", sleep_ends_at=None,
                bookmarks_json=bookmarks, request_id=body.requestId,
                request_hash=request_hash, updated_at=now)
            row["envelope_tag"] = self._tag(row)
            connection.execute(
                "INSERT INTO longform_sessions VALUES(?,?,?,?,?,?,?,?,?,?,?,?,"
                "?,?,?,?,?,?,?,?,?,?,?)", tuple(row[field] for field in _FIELDS)
                + (row["envelope_tag"],))
            return self._snapshot(row, actor)

    def update(self, actor, session_id, body):
        if type(body) is not UpdateLongformSessionRequest:
            raise ApiError("invalid_request")
        item = self._catalog_item(actor, body)
        request_hash = self._request_hash(body)
        now = int(self.settings.clock())
        if (not math.isfinite(body.positionSeconds)
                or body.positionSeconds > item["durationSeconds"]
                or body.playbackState == "ended"
                and body.positionSeconds != item["durationSeconds"]
                or body.sleepTimerEndsAt is not None
                and not now + 60 <= body.sleepTimerEndsAt <= now + 86400
                or any(bookmark.positionSeconds > item["durationSeconds"]
                       for bookmark in body.bookmarks)):
            raise ApiError("invalid_request")
        with self.db.transaction() as connection:
            user = self._actor(connection, actor)
            raw = connection.execute(
                "SELECT * FROM longform_sessions WHERE id=? AND actor_id=?",
                (session_id, actor.id)).fetchone()
            if raw is None:
                raise ApiError("not_found", 404)
            row = self._row(raw)
            if row["request_id"] == body.requestId:
                if row["request_hash"] != request_hash:
                    raise ApiError("longform_session_request_conflict", 409)
                return self._snapshot(row, actor)
            if (row["revision"] != body.expectedRevision
                    or row["media_key"] != self._media_key(
                        body.installationId, body.providerInstanceId,
                        body.mediaUri)):
                raise ApiError("longform_session_conflict", 409)
            if row["family_id"] != actor.family_id and not body.takeover:
                raise ApiError("longform_session_conflict", 409)
            row = self._save(connection, dict(
                row, family_id=actor.family_id,
                actor_revision=user["revision"],
                revision=row["revision"] + 1,
                installation_revision=body.expectedInstallationRevision,
                core_revision=body.expectedCoreRevision,
                manager_revision=body.expectedManagerRevision,
                title=item["name"], duration_seconds=item["durationSeconds"],
                position_seconds=body.positionSeconds,
                playback_state=body.playbackState,
                sleep_ends_at=body.sleepTimerEndsAt,
                bookmarks_json=self._json([
                    value.model_dump(mode="json") for value in body.bookmarks]),
                request_id=body.requestId, request_hash=request_hash,
                updated_at=now))
            return self._snapshot(row, actor)
