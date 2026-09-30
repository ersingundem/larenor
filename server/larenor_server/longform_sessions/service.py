"""Durable revision-safe audiobook and podcast listening state."""

import hashlib
import hmac
import json
import math
import threading
import uuid

from pydantic import ValidationError

from ..errors import ApiError, StartupError
from ..plugins.music_playback_models import (
    MusicPlaybackCommandRequest,
    ReadMusicLongformRequest,
)
from .models import (
    LongformBookmark,
    LongformSession,
    LongformSleepTarget,
    OpenLongformSessionRequest,
    UpdateLongformSessionRequest,
)

_FIELDS = (
    "id", "actor_id", "family_id", "actor_revision", "revision",
    "media_key", "installation_id", "installation_revision",
    "core_revision", "manager_revision", "provider_instance_id",
    "media_uri", "media_type", "title", "duration_seconds",
    "position_seconds", "playback_state", "sleep_ends_at",
    "bookmarks_json", "request_id", "request_hash", "updated_at",
)
_TIMER_FIELDS = (
    "id", "session_id", "generation", "actor_id", "family_id",
    "actor_revision", "session_revision", "state", "deadline",
    "installation_id", "installation_revision", "core_revision",
    "player_revision", "target_id", "provider", "target_kind",
    "queue_id", "group_members_json", "outcome", "created_at", "updated_at",
)
_TERMINAL_TIMER_STATES = {"succeeded", "needs_attention", "cancelled"}


class LongformSessionService:
    def __init__(self, db, auth, settings, key, context, music_playback):
        self.db, self.auth, self.settings = db, auth, settings
        self._key, self.context = key, context
        self.music_playback = music_playback
        self._tick_lock = threading.Lock()

    @staticmethod
    def _json(value):
        return json.dumps(value, sort_keys=True, separators=(",", ":"),
                          allow_nan=False)

    def _tag(self, row):
        payload = self._json({field: row[field] for field in _FIELDS}).encode()
        return hmac.new(self._key, b"larenor-longform-session-v1\0" + payload,
                        hashlib.sha256).hexdigest()

    def _timer_tag(self, row):
        payload = self._json(
            {field: row[field] for field in _TIMER_FIELDS}).encode()
        return hmac.new(self._key, b"larenor-longform-sleep-v1\0" + payload,
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

    def _timer_row(self, row):
        if row is None or not hmac.compare_digest(
                row["envelope_tag"], self._timer_tag(row)):
            raise StartupError("longform_session_storage_invalid")
        try:
            members = json.loads(row["group_members_json"])
            LongformSleepTarget(
                targetId=row["target_id"], expectedProvider=row["provider"],
                expectedTargetKind=row["target_kind"],
                expectedQueueId=row["queue_id"],
                expectedGroupMembers=members,
            )
            if ((row["state"] in {"pending", "dispatching"})
                    != (row["outcome"] == "scheduled")
                    or (row["state"] == "succeeded")
                    != (row["outcome"] == "authenticated_readback")
                    or row["state"] == "needs_attention"
                    and row["outcome"] != "effect_unknown"
                    or row["state"] == "cancelled"
                    and row["outcome"] not in {
                        "cancelled", "authority_retired"}):
                raise ValueError()
        except (ValueError, TypeError, ValidationError):
            raise StartupError("longform_session_storage_invalid") from None
        return row

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                for row in connection.execute("SELECT * FROM longform_sessions"):
                    self._row(row)
                for row in connection.execute(
                        "SELECT * FROM longform_sleep_timers"):
                    self._timer_row(row)
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

    def _assert_timer_owner(self, connection, timer):
        row = connection.execute(
            "SELECT u.revision,u.disabled,u.must_change_password,"
            "f.revoked_at,f.expires_at FROM users u "
            "JOIN session_families f ON f.user_id=u.id "
            "WHERE u.id=? AND f.id=?",
            (timer["actor_id"], timer["family_id"]),
        ).fetchone()
        if (row is None or row["revision"] != timer["actor_revision"]
                or row["disabled"] or row["must_change_password"]
                or row["revoked_at"] is not None
                or self.settings.clock() >= row["expires_at"]):
            raise ApiError("invalid_session", 401)

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

    def _current_timer(self, connection, session_id):
        row = connection.execute(
            "SELECT * FROM longform_sleep_timers WHERE session_id=? "
            "ORDER BY generation DESC LIMIT 1", (session_id,),
        ).fetchone()
        return None if row is None else self._timer_row(row)

    @staticmethod
    def _timer_public(timer):
        if timer is None:
            return None, "off", None, None
        if timer["state"] in {"pending", "dispatching"}:
            return (timer["deadline"], "scheduled", "scheduled",
                    timer["target_id"])
        if timer["state"] == "succeeded":
            return None, "enforced", "authenticated_readback", None
        if timer["state"] == "needs_attention":
            return None, "needs_attention", "effect_unknown", None
        return None, "cancelled", timer["outcome"], None

    def _snapshot(self, connection, row, actor):
        bookmarks = [LongformBookmark.model_validate(item) for item in
                     json.loads(row["bookmarks_json"])]
        timer = self._current_timer(connection, row["id"])
        deadline, state, code, target = self._timer_public(timer)
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
            sleepTimerEndsAt=deadline, sleepTimerState=state,
            sleepTimerCode=code, sleepTimerTargetId=target,
            bookmarks=bookmarks,
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

    def _save_timer(self, connection, row):
        value = dict(row)
        value["envelope_tag"] = self._timer_tag(value)
        connection.execute(
            "UPDATE longform_sleep_timers SET actor_id=?,family_id=?,"
            "actor_revision=?,session_revision=?,state=?,deadline=?,"
            "installation_id=?,installation_revision=?,core_revision=?,"
            "player_revision=?,target_id=?,provider=?,target_kind=?,queue_id=?,"
            "group_members_json=?,outcome=?,created_at=?,updated_at=?,"
            "envelope_tag=? WHERE id=?",
            tuple(value[field] for field in _TIMER_FIELDS[3:])
            + (value["envelope_tag"], value["id"]),
        )
        return value

    def _insert_timer(self, connection, session, actor, user, body, now):
        target = body.sleepTimerTarget
        generation = connection.execute(
            "SELECT COALESCE(MAX(generation),0)+1 FROM longform_sleep_timers "
            "WHERE session_id=?", (session["id"],),
        ).fetchone()[0]
        timer = {
            "id": uuid.uuid4().hex, "session_id": session["id"],
            "generation": generation, "actor_id": actor.id,
            "family_id": actor.family_id,
            "actor_revision": user["revision"],
            "session_revision": session["revision"], "state": "pending",
            "deadline": body.sleepTimerEndsAt,
            "installation_id": body.installationId,
            "installation_revision": body.expectedInstallationRevision,
            "core_revision": body.expectedCoreRevision,
            "player_revision": body.expectedManagerRevision,
            "target_id": target.targetId,
            "provider": target.expectedProvider,
            "target_kind": target.expectedTargetKind,
            "queue_id": target.expectedQueueId,
            "group_members_json": self._json(target.expectedGroupMembers),
            "outcome": "scheduled", "created_at": now, "updated_at": now,
        }
        timer["envelope_tag"] = self._timer_tag(timer)
        connection.execute(
            "INSERT INTO longform_sleep_timers VALUES(" + ",".join(
                "?" for _ in range(len(_TIMER_FIELDS) + 1)) + ")",
            tuple(timer[field] for field in _TIMER_FIELDS)
            + (timer["envelope_tag"],),
        )
        connection.execute(
            "DELETE FROM longform_sleep_timers WHERE id IN ("
            "SELECT id FROM longform_sleep_timers WHERE session_id=? "
            "AND state IN ('succeeded','needs_attention','cancelled') "
            "ORDER BY generation DESC LIMIT -1 OFFSET 64)",
            (session["id"],),
        )
        return timer

    def _cancel_timer(self, connection, timer, now, outcome="cancelled"):
        if timer is None or timer["state"] in _TERMINAL_TIMER_STATES:
            return timer
        return self._save_timer(connection, dict(
            timer, state="cancelled", outcome=outcome, updated_at=now))

    @staticmethod
    def _same_pending_timer(timer, body):
        target = body.sleepTimerTarget
        return (timer is not None and timer["state"] == "pending"
                and target is not None
                and timer["deadline"] == body.sleepTimerEndsAt
                and timer["target_id"] == target.targetId
                and timer["provider"] == target.expectedProvider
                and timer["target_kind"] == target.expectedTargetKind
                and timer["queue_id"] == target.expectedQueueId
                and json.loads(timer["group_members_json"])
                == target.expectedGroupMembers)

    @staticmethod
    def _command(timer):
        return MusicPlaybackCommandRequest(
            requestId=timer["id"], installationId=timer["installation_id"],
            expectedInstallationRevision=timer["installation_revision"],
            expectedCoreRevision=timer["core_revision"],
            expectedPlayerRevision=timer["player_revision"],
            targetId=timer["target_id"],
            expectedProvider=timer["provider"],
            expectedTargetKind=timer["target_kind"],
            expectedQueueId=timer["queue_id"],
            expectedGroupMembers=json.loads(timer["group_members_json"]),
            operation="pause",
        )

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
                timer = self._current_timer(connection, row["id"])
                taking_over = row["family_id"] != actor.family_id
                if taking_over and not body.takeover:
                    return self._snapshot(connection, row, actor)
                if taking_over:
                    if timer is not None and timer["state"] == "dispatching":
                        raise ApiError(
                            "longform_sleep_timer_dispatch_in_progress", 409)
                    self._cancel_timer(
                        connection, timer, now, "authority_retired")
                    timer = None
                if (row["request_id"] != body.requestId
                        or row["installation_revision"]
                        != body.expectedInstallationRevision
                        or row["core_revision"] != body.expectedCoreRevision
                        or row["manager_revision"] != body.expectedManagerRevision
                        or row["title"] != item["name"]
                        or row["duration_seconds"] != item["durationSeconds"]
                        or taking_over):
                    row = self._save(connection, dict(
                        row, family_id=actor.family_id,
                        actor_revision=user["revision"],
                        revision=row["revision"] + 1,
                        installation_revision=body.expectedInstallationRevision,
                        core_revision=body.expectedCoreRevision,
                        manager_revision=body.expectedManagerRevision,
                        title=item["name"],
                        duration_seconds=item["durationSeconds"],
                        sleep_ends_at=(None if taking_over
                                      else row["sleep_ends_at"]),
                        request_id=body.requestId, request_hash=request_hash,
                        updated_at=now))
                    if timer is not None and timer["state"] == "pending":
                        self._save_timer(connection, dict(
                            timer, actor_revision=user["revision"],
                            session_revision=row["revision"], updated_at=now))
                return self._snapshot(connection, row, actor)
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
            return self._snapshot(connection, row, actor)

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
                and body.sleepTimerEndsAt > now + 86400
                or (body.sleepTimerEndsAt is None)
                != (body.sleepTimerTarget is None)
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
                return self._snapshot(connection, row, actor)
            if (row["revision"] != body.expectedRevision
                    or row["media_key"] != self._media_key(
                        body.installationId, body.providerInstanceId,
                        body.mediaUri)):
                raise ApiError("longform_session_conflict", 409)
            if row["family_id"] != actor.family_id and not body.takeover:
                raise ApiError("longform_session_conflict", 409)
            timer = self._current_timer(connection, row["id"])
            if timer is not None and timer["state"] == "dispatching":
                raise ApiError("longform_sleep_timer_dispatch_in_progress", 409)
            same_timer = self._same_pending_timer(timer, body)
            if (body.sleepTimerEndsAt is not None
                    and body.sleepTimerEndsAt < now + 60
                    and not same_timer):
                raise ApiError("invalid_request")
            if body.sleepTimerEndsAt is not None:
                target = body.sleepTimerTarget
                command = MusicPlaybackCommandRequest(
                    requestId=body.requestId,
                    installationId=body.installationId,
                    expectedInstallationRevision=body.expectedInstallationRevision,
                    expectedCoreRevision=body.expectedCoreRevision,
                    expectedPlayerRevision=body.expectedManagerRevision,
                    targetId=target.targetId,
                    expectedProvider=target.expectedProvider,
                    expectedTargetKind=target.expectedTargetKind,
                    expectedQueueId=target.expectedQueueId,
                    expectedGroupMembers=target.expectedGroupMembers,
                    operation="pause",
                )
                self.music_playback._assert_scheduled_pause(
                    connection, command, body.mediaUri,
                    {body.expectedManagerRevision},
                )
            updated = self._save(connection, dict(
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
            if same_timer:
                self._save_timer(connection, dict(
                    timer, actor_revision=user["revision"],
                    session_revision=updated["revision"],
                    installation_revision=body.expectedInstallationRevision,
                    core_revision=body.expectedCoreRevision,
                    player_revision=body.expectedManagerRevision,
                    updated_at=now,
                ))
            else:
                self._cancel_timer(connection, timer, now)
            if body.sleepTimerEndsAt is not None and not same_timer:
                self._insert_timer(connection, updated, actor, user, body, now)
            return self._snapshot(connection, updated, actor)

    def _claim_due(self):
        now = int(self.settings.clock())
        with self.db.transaction() as connection:
            stale = connection.execute(
                "SELECT * FROM longform_sleep_timers "
                "WHERE state='dispatching' ORDER BY updated_at,id LIMIT 16"
            ).fetchall()
            for raw in stale:
                timer = self._timer_row(raw)
                self._save_timer(connection, dict(
                    timer, state="needs_attention", outcome="effect_unknown",
                    updated_at=now))
            raw = connection.execute(
                "SELECT * FROM longform_sleep_timers WHERE state='pending' "
                "AND deadline<=? ORDER BY deadline,id LIMIT 1", (now,),
            ).fetchone()
            if raw is None:
                return None
            timer = self._timer_row(raw)
            session = self._row(connection.execute(
                "SELECT * FROM longform_sessions WHERE id=?",
                (timer["session_id"],),
            ).fetchone())
            try:
                self._assert_timer_owner(connection, timer)
            except ApiError:
                self._cancel_timer(
                    connection, timer, now, "authority_retired")
                return None
            command = self._command(timer)
            try:
                self.music_playback._assert_scheduled_pause(
                    connection, command, session["media_uri"],
                    {timer["player_revision"]},
                )
            except ApiError:
                self._save_timer(connection, dict(
                    timer, state="needs_attention", outcome="effect_unknown",
                    updated_at=now))
                return None
            claimed = self._save_timer(connection, dict(
                timer, state="dispatching", updated_at=now))
            return claimed, session["media_uri"]

    def _dispatch_guard(self, timer_id):
        def assert_current(connection):
            timer = self._timer_row(connection.execute(
                "SELECT * FROM longform_sleep_timers WHERE id=?", (timer_id,),
            ).fetchone())
            if timer["state"] != "dispatching":
                raise ApiError("longform_sleep_timer_retired", 409)
            session = self._row(connection.execute(
                "SELECT * FROM longform_sessions WHERE id=?",
                (timer["session_id"],),
            ).fetchone())
            if (session["revision"] != timer["session_revision"]
                    or session["actor_id"] != timer["actor_id"]
                    or session["family_id"] != timer["family_id"]
                    or session["installation_id"] != timer["installation_id"]):
                raise ApiError("longform_sleep_timer_retired", 409)
            self._assert_timer_owner(connection, timer)
            self.music_playback._assert_scheduled_pause(
                connection, self._command(timer), session["media_uri"],
                {timer["player_revision"], timer["player_revision"] + 1},
            )
        return assert_current

    def _finish(self, timer_id, succeeded):
        now = int(self.settings.clock())
        with self.db.transaction() as connection:
            raw = connection.execute(
                "SELECT * FROM longform_sleep_timers WHERE id=?", (timer_id,),
            ).fetchone()
            timer = self._timer_row(raw)
            if timer["state"] != "dispatching":
                return
            self._save_timer(connection, dict(
                timer, state="succeeded" if succeeded else "needs_attention",
                outcome=("authenticated_readback" if succeeded
                         else "effect_unknown"), updated_at=now))

    def tick(self):
        if not self._tick_lock.acquire(blocking=False):
            return False
        try:
            claimed = self._claim_due()
            if claimed is None:
                return False
            timer, media_uri = claimed
            try:
                receipt = self.music_playback._command_scoped(
                    timer["actor_id"], self._command(timer),
                    self._dispatch_guard(timer["id"]),
                    expected_current_item_uri=media_uri,
                )
                succeeded = receipt["receipt"]["state"] == "succeeded"
            except Exception:
                succeeded = False
            self._finish(timer["id"], succeeded)
            return succeeded
        finally:
            self._tick_lock.release()
