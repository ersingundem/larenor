import hashlib
import hmac
import json
import sqlite3
import uuid

from pydantic import ValidationError

from ..errors import ApiError, StartupError
from .models import EpgProgramme, SourceSnapshotRequest
from .runtime import (
    LiveTvProviderCapability,
    LiveTvRecordingCommand,
    LiveTvRecordingReadback,
    LiveTvRecordingReceipt,
)


MAX_RECORDINGS = 256
BYTES_PER_SECOND_RESERVATION = 1_000_000


class LiveTvService:
    def __init__(self, db, auth, settings, context, provider=None, recorder=None):
        self.db, self.auth, self.settings, self.context = db, auth, settings, context
        self.provider, self.recorder = provider, recorder

    @staticmethod
    def _hash(body):
        return hashlib.sha256(body.model_dump_json().encode()).hexdigest()

    def _actor(self, connection, actor):
        self.auth.assert_current(connection, actor)
        row = connection.execute(
            "SELECT id,revision,disabled,must_change_password FROM users WHERE id=?",
            (actor.id,),
        ).fetchone()
        if row is None or row["disabled"] or row["must_change_password"]:
            raise ApiError("invalid_session", 401)
        return row

    @staticmethod
    def _source(row):
        if row is None:
            raise ApiError("live_tv_source_unavailable", 503)
        try:
            body = SourceSnapshotRequest.model_validate_json(row["snapshot_json"])
            digest = hashlib.sha256(row["snapshot_json"].encode()).hexdigest()
            if (row["revision"] < 1 or row["request_id"] != body.requestId
                    or not hmac.compare_digest(row["request_hash"], digest)):
                raise ValueError()
            return body
        except (ValidationError, ValueError, TypeError):
            raise StartupError("live_tv_storage_invalid") from None

    @staticmethod
    def _programme(row):
        try:
            return EpgProgramme.model_validate_json(
                row["programme_json"]
            ).model_dump()
        except (ValidationError, ValueError, TypeError):
            raise StartupError("live_tv_storage_invalid") from None

    def _capability(self, source=None):
        if self.provider is None or self.recorder is None:
            raise ApiError("live_tv_source_unavailable", 503)
        try:
            value = self.provider.capability()
        except ApiError:
            raise
        except Exception:
            raise ApiError("live_tv_source_unavailable", 503) from None
        if (not isinstance(value, LiveTvProviderCapability)
                or not self._safe_provider_id(value.provider_id)
                or value.provider_kind not in ("tuner", "iptv")
                or type(value.provider_revision) is not int
                or value.provider_revision < 1
                or type(value.parallel_tuners) is not int
                or not 1 <= value.parallel_tuners <= 8
                or type(value.quota_bytes) is not int
                or not 1_073_741_824 <= value.quota_bytes <= 10_995_116_277_760):
            raise ApiError("live_tv_source_unavailable", 503)
        if source is not None and (
                value.provider_id != source.providerId
                or value.provider_kind != source.providerKind
                or value.provider_revision != source.providerRevision
                or value.parallel_tuners != source.parallelTuners
                or value.quota_bytes != source.quotaBytes):
            raise ApiError("live_tv_source_changed", 409)
        return value

    @staticmethod
    def _safe_provider_id(value):
        return (isinstance(value, str) and 1 <= len(value) <= 128
                and all(char.isalnum() or char in "-_.:" for char in value))

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                source = connection.execute(
                    "SELECT * FROM live_tv_source WHERE singleton=1"
                ).fetchone()
                if source is not None:
                    self._source(source)
                rows = connection.execute(
                    "SELECT * FROM live_tv_recordings LIMIT ?", (MAX_RECORDINGS + 1,)
                ).fetchall()
                if len(rows) > MAX_RECORDINGS:
                    raise ValueError()
                for row in rows:
                    self._programme(row)
                    if (row["revision"] < 1 or row["actor_revision"] < 1
                            or row["source_revision"] < 1
                            or not self._safe_provider_id(row["provider_id"])
                            or row["provider_revision"] < 1
                            or row["readback_revision"] < 1
                            or not self._safe_provider_id(row["provider_recording_id"])
                            or row["restart_count"] < 0
                            or row["restart_count"] > 16):
                        raise ValueError()
        except (sqlite3.Error, StartupError, ValueError, TypeError):
            raise StartupError("live_tv_storage_invalid") from None

    def configure(self, actor, body):
        if type(body) is not SourceSnapshotRequest:
            raise ApiError("invalid_request")
        now = int(self.settings.clock())
        self._fresh(body, now)
        self._capability(body)
        digest = self._hash(body)
        with self.db.transaction() as connection:
            self._actor(connection, actor)
            self._refresh_states(connection, now)
            used = connection.execute(
                "SELECT COALESCE(SUM(bytes_written),0) FROM live_tv_recordings "
                "WHERE state!='cancelled'"
            ).fetchone()[0]
            if used > body.quotaBytes:
                raise ApiError("live_tv_quota_exceeded", 409)
            active = connection.execute(
                "SELECT * FROM live_tv_recordings WHERE state IN "
                "('scheduled','recording')"
            ).fetchall()
            events = []
            for row in active:
                programme = self._programme(row)
                events.extend(((programme["startsAt"], 1),
                               (programme["endsAt"], -1)))
            concurrent = peak = 0
            for _, delta in sorted(events, key=lambda item: (item[0], item[1])):
                concurrent += delta
                peak = max(peak, concurrent)
            if peak > body.parallelTuners:
                raise ApiError("live_tv_recording_conflict", 409)
            old = connection.execute(
                "SELECT * FROM live_tv_source WHERE singleton=1"
            ).fetchone()
            if old is not None and old["request_id"] == body.requestId:
                if old["request_hash"] != digest:
                    raise ApiError("idempotency_conflict", 409)
                return self._snapshot(connection, actor, old)
            actual = 0 if old is None else old["revision"]
            if body.expectedRevision != actual:
                raise ApiError("live_tv_source_changed", 409)
            if old is not None:
                previous = self._source(old)
                active_count = connection.execute(
                    "SELECT COUNT(*) FROM live_tv_recordings WHERE state IN "
                    "('scheduled','recording','interrupted','uncertain')"
                ).fetchone()[0]
                if (active_count and (previous.providerId != body.providerId
                                      or previous.providerRevision
                                      != body.providerRevision)):
                    raise ApiError("live_tv_source_changed", 409)
            revision = actual + 1
            connection.execute(
                "INSERT INTO live_tv_source VALUES(1,?,?,?,?,?) "
                "ON CONFLICT(singleton) DO UPDATE SET revision=excluded.revision,"
                "request_id=excluded.request_id,request_hash=excluded.request_hash,"
                "snapshot_json=excluded.snapshot_json,updated_at=excluded.updated_at",
                (revision, body.requestId, digest, body.model_dump_json(), now),
            )
            current = connection.execute(
                "SELECT * FROM live_tv_source WHERE singleton=1"
            ).fetchone()
            return self._snapshot(connection, actor, current)

    @staticmethod
    def _fresh(source, now):
        if source.capturedAt > now + 300 or source.capturedAt < now - 604_800:
            raise ApiError("live_tv_epg_stale", 409)

    def _refresh_states(self, connection, now):
        rows = connection.execute(
            "SELECT * FROM live_tv_recordings WHERE state IN "
            "('scheduled','recording','interrupted','uncertain')"
        ).fetchall()
        for row in rows:
            try:
                if self.recorder is None:
                    raise ValueError()
                value = self.recorder.readback(row["provider_recording_id"])
                readback = self._readback(value, row, now)
                source = self._source(connection.execute(
                    "SELECT * FROM live_tv_source WHERE singleton=1"
                ).fetchone())
                if (self._quota_load(connection, now, exclude_id=row["id"])
                        + readback.bytes_written > source.quotaBytes):
                    raise ValueError("live_tv_quota_exceeded")
                state = readback.state
                if state == "interrupted" and now >= self._programme(row)["endsAt"]:
                    state = "partial"
                if (state != row["state"]
                        or readback.bytes_written != row["bytes_written"]
                        or readback.readback_revision != row["readback_revision"]):
                    connection.execute(
                        "UPDATE live_tv_recordings SET revision=revision+1,state=?,"
                        "bytes_written=?,readback_revision=?,updated_at=? WHERE id=?",
                        (state, readback.bytes_written, readback.readback_revision,
                         now, row["id"]),
                    )
            except Exception:
                if row["state"] != "uncertain":
                    connection.execute(
                        "UPDATE live_tv_recordings SET revision=revision+1,"
                        "state='uncertain',updated_at=? WHERE id=?", (now, row["id"])
                    )

    def _readback(self, value, row, now):
        if (not isinstance(value, LiveTvRecordingReadback)
                or value.provider_recording_id != row["provider_recording_id"]
                or value.provider_revision != row["provider_revision"]
                or value.readback_revision < row["readback_revision"]
                or (value.readback_revision == row["readback_revision"]
                    and (value.state != row["state"]
                         or value.bytes_written != row["bytes_written"]))
                or value.state not in ("scheduled", "recording", "interrupted",
                                       "completed", "cancelled", "partial", "uncertain")
                or type(value.bytes_written) is not int
                or not row["bytes_written"] <= value.bytes_written <= 10_995_116_277_760
                or type(value.observed_at) is not int
                or value.observed_at > now + 300 or value.observed_at < now - 604_800):
            raise ValueError("invalid_live_tv_readback")
        return value

    @staticmethod
    def _prune_history(connection):
        """Keep the bounded contract while retaining the newest finished rows."""
        rows = connection.execute(
            "SELECT id FROM live_tv_recordings WHERE state IN "
            "('completed','cancelled','partial') "
            "ORDER BY updated_at DESC"
        ).fetchall()
        for row in rows[MAX_RECORDINGS // 2:]:
            connection.execute(
                "DELETE FROM live_tv_recordings WHERE id=?", (row["id"],)
            )

    def _quota_load(self, connection, now, *, exclude_id=None):
        rows = connection.execute(
            "SELECT * FROM live_tv_recordings WHERE state!='cancelled'"
        ).fetchall()
        total = sum(row["bytes_written"] for row in rows)
        for row in rows:
            if row["id"] == exclude_id or row["state"] not in ("scheduled", "recording"):
                continue
            programme = self._programme(row)
            total += max(0, programme["endsAt"] - max(now, programme["startsAt"])) * BYTES_PER_SECOND_RESERVATION
        return total

    def _recording(self, row):
        programme = self._programme(row)
        return {
            "schemaVersion": 1,
            "recordingId": row["id"],
            "revision": row["revision"],
            "providerRevision": row["provider_revision"],
            "readbackRevision": row["readback_revision"],
            "programmeId": programme["programmeId"],
            "channelId": programme["channelId"],
            "channelName": programme["channelName"],
            "title": programme["title"],
            "startsAt": programme["startsAt"],
            "endsAt": programme["endsAt"],
            "state": row["state"],
            "bytesWritten": row["bytes_written"],
            "restartCount": row["restart_count"],
        }

    def _dispatch(self, actor, *, request_id, action, recording_id,
                  recording_revision, source, guide_revision, programme, now,
                  provider_recording_id=None):
        if self.recorder is None:
            raise ApiError("live_tv_source_unavailable", 503)
        command = LiveTvRecordingCommand(
            request_id=request_id, action=action, recording_id=recording_id,
            provider_recording_id=provider_recording_id,
            recording_revision=recording_revision,
            provider_id=source.providerId,
            provider_revision=source.providerRevision,
            guide_revision=guide_revision, account_id=actor.id,
            session_family_id=actor.family_id, programme=programme,
        )
        try:
            receipt = self.recorder.apply(command)
        except ApiError:
            raise
        except Exception:
            raise ApiError("live_tv_recorder_unavailable", 503) from None
        if (not isinstance(receipt, LiveTvRecordingReceipt)
                or receipt.request_id != request_id
                or receipt.action != action
                or receipt.recording_id != recording_id
                or receipt.provider_revision != source.providerRevision
                or not self._safe_provider_id(receipt.provider_recording_id)
                or not isinstance(receipt.readback, LiveTvRecordingReadback)
                or receipt.readback.provider_recording_id != receipt.provider_recording_id
                or receipt.readback.provider_revision != source.providerRevision
                or receipt.readback.readback_revision < 1
                or receipt.readback.state not in (
                    "scheduled", "recording", "interrupted", "completed",
                    "cancelled", "partial", "uncertain")
                or type(receipt.readback.bytes_written) is not int
                or not 0 <= receipt.readback.bytes_written <= 10_995_116_277_760
                or type(receipt.readback.observed_at) is not int
                or receipt.readback.observed_at > now + 300
                or receipt.readback.observed_at < now - 604_800):
            raise ApiError("live_tv_recorder_invalid", 503)
        return receipt

    def _snapshot(self, connection, actor, source_row):
        source = self._source(source_row)
        user = self._actor(connection, actor)
        now = int(self.settings.clock())
        self._fresh(source, now)
        self._capability(source)
        self._refresh_states(connection, now)
        rows = connection.execute(
            "SELECT * FROM live_tv_recordings WHERE owner_id=? AND family_id=? "
            "ORDER BY updated_at DESC LIMIT ?",
            (actor.id, actor.family_id, MAX_RECORDINGS),
        ).fetchall()
        used = connection.execute(
            "SELECT COALESCE(SUM(bytes_written),0) FROM live_tv_recordings "
            "WHERE state!='cancelled'"
        ).fetchone()[0]
        return {"schemaVersion": 1, "snapshot": {
            "schemaVersion": 1,
            "authority": {"schemaVersion": 1,
                "coreId": self.context.coreId, "homeId": self.context.homeId,
                "accountId": actor.id, "accountRevision": user["revision"],
                "sessionFamilyId": actor.family_id,
                "sourceRevision": source_row["revision"],
                "providerRevision": source.providerRevision},
            "providerId": source.providerId, "providerKind": source.providerKind,
            "timeZone": source.timeZone, "parallelTuners": source.parallelTuners,
            "quotaBytes": source.quotaBytes, "usedBytes": used,
            "capturedAt": source.capturedAt,
            "programmes": [item.model_dump() for item in source.programmes],
            "recordings": [self._recording(row) for row in rows],
        }}

    def read(self, actor):
        with self.db.transaction() as connection:
            self._actor(connection, actor)
            source = connection.execute(
                "SELECT * FROM live_tv_source WHERE singleton=1"
            ).fetchone()
            return self._snapshot(connection, actor, source)

    def schedule(self, actor, body):
        now = int(self.settings.clock())
        digest = self._hash(body)
        with self.db.transaction() as connection:
            user = self._actor(connection, actor)
            source_row = connection.execute(
                "SELECT * FROM live_tv_source WHERE singleton=1"
            ).fetchone()
            source = self._source(source_row)
            self._fresh(source, now)
            self._capability(source)
            if (source_row["revision"] != body.expectedSourceRevision
                    or source.providerRevision != body.expectedProviderRevision):
                raise ApiError("live_tv_source_changed", 409)
            existing = connection.execute(
                "SELECT * FROM live_tv_recordings WHERE request_id=?", (body.requestId,)
            ).fetchone()
            if existing is not None:
                if (existing["owner_id"] != actor.id
                        or existing["family_id"] != actor.family_id
                        or existing["request_hash"] != digest):
                    raise ApiError("idempotency_conflict", 409)
                return {"schemaVersion": 1, "recording": self._recording(existing)}
            programme = next((item for item in source.programmes
                              if item.programmeId == body.programmeId), None)
            if programme is None or programme.endsAt <= now:
                raise ApiError("live_tv_programme_unavailable", 409)
            self._refresh_states(connection, now)
            self._prune_history(connection)
            active = connection.execute(
                "SELECT * FROM live_tv_recordings WHERE state IN ('scheduled','recording','interrupted')"
            ).fetchall()
            overlaps = sum(1 for row in active if
                row["state"] in ("scheduled", "recording") and
                self._programme(row)["startsAt"] < programme.endsAt and
                programme.startsAt < self._programme(row)["endsAt"])
            if overlaps >= source.parallelTuners:
                raise ApiError("live_tv_recording_conflict", 409)
            if len(active) >= MAX_RECORDINGS:
                raise ApiError("live_tv_recording_limit_reached", 409)
            total = connection.execute(
                "SELECT COUNT(*) FROM live_tv_recordings"
            ).fetchone()[0]
            if total >= MAX_RECORDINGS:
                raise ApiError("live_tv_recording_limit_reached", 409)
            used = self._quota_load(connection, now)
            reserved = (programme.endsAt - max(now, programme.startsAt)) * BYTES_PER_SECOND_RESERVATION
            if used + reserved > source.quotaBytes:
                raise ApiError("live_tv_quota_exceeded", 409)
            recording_id = uuid.uuid4().hex
            programme_json = json.dumps(programme.model_dump(), separators=(",", ":"),
                                        sort_keys=True)
            receipt = self._dispatch(
                actor, request_id=body.requestId, action="schedule",
                recording_id=recording_id, recording_revision=1, source=source,
                guide_revision=source_row["revision"],
                programme=programme.model_dump(), now=now,
            )
            if receipt.readback.state not in ("scheduled", "recording"):
                raise ApiError("live_tv_recorder_invalid", 503)
            if used + reserved + receipt.readback.bytes_written > source.quotaBytes:
                raise ApiError("live_tv_quota_exceeded", 409)
            connection.execute(
                "INSERT INTO live_tv_recordings VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (recording_id, actor.id, actor.family_id, user["revision"],
                 source_row["revision"], source.providerId,
                 source.providerRevision, 1,
                 body.requestId, digest, programme_json,
                 receipt.provider_recording_id, receipt.readback.readback_revision,
                 receipt.readback.state, receipt.readback.bytes_written, 0,
                 None, None, now),
            )
            row = connection.execute(
                "SELECT * FROM live_tv_recordings WHERE id=?", (recording_id,)
            ).fetchone()
            return {"schemaVersion": 1, "recording": self._recording(row)}

    def _mutate(self, actor, recording_id, body, action, *, admin=False,
                provider_action=None):
        now = int(self.settings.clock())
        digest = self._hash(body)
        with self.db.transaction() as connection:
            user = self._actor(connection, actor)
            row = connection.execute(
                "SELECT * FROM live_tv_recordings WHERE id=?", (recording_id,)
            ).fetchone()
            if row is None or (not admin and (row["owner_id"] != actor.id
                                              or row["family_id"] != actor.family_id)):
                raise ApiError("not_found", 404)
            if row["actor_revision"] != user["revision"] and not admin:
                raise ApiError("live_tv_authority_changed", 409)
            if row["last_request_id"] == body.requestId:
                if row["last_request_hash"] != digest:
                    raise ApiError("idempotency_conflict", 409)
                return {"schemaVersion": 1, "recording": self._recording(row)}
            if row["revision"] != body.expectedRevision:
                raise ApiError("live_tv_recording_changed", 409)
            changes = action(connection, row, now)
            if provider_action is not None:
                source_row = connection.execute(
                    "SELECT * FROM live_tv_source WHERE singleton=1"
                ).fetchone()
                source = self._source(source_row)
                self._capability(source)
                if (source.providerId != row["provider_id"]
                        or source.providerRevision != row["provider_revision"]):
                    raise ApiError("live_tv_source_changed", 409)
                receipt = self._dispatch(
                    actor, request_id=body.requestId, action=provider_action,
                    recording_id=row["id"], recording_revision=row["revision"],
                    source=source, guide_revision=row["source_revision"],
                    programme=self._programme(row), now=now,
                    provider_recording_id=row["provider_recording_id"],
                )
                if (receipt.provider_recording_id != row["provider_recording_id"]
                        or receipt.readback.readback_revision
                        <= row["readback_revision"]):
                    raise ApiError("live_tv_recorder_invalid", 503)
                changes.update({
                    "state": receipt.readback.state,
                    "bytes_written": receipt.readback.bytes_written,
                    "readback_revision": receipt.readback.readback_revision,
                })
                if (provider_action == "cancel"
                        and receipt.readback.state != "cancelled"):
                    raise ApiError("live_tv_recorder_invalid", 503)
                if (provider_action == "restart"
                        and receipt.readback.state not in ("scheduled", "recording")):
                    raise ApiError("live_tv_recorder_invalid", 503)
            revision = row["revision"] + 1
            connection.execute(
                "UPDATE live_tv_recordings SET revision=?,state=?,bytes_written=?,"
                "restart_count=?,readback_revision=?,last_request_id=?,"
                "last_request_hash=?,updated_at=? WHERE id=?",
                (revision, changes.get("state", row["state"]),
                 changes.get("bytes_written", row["bytes_written"]),
                 changes.get("restart_count", row["restart_count"]),
                 changes.get("readback_revision", row["readback_revision"]),
                 body.requestId, digest, now, recording_id),
            )
            updated = connection.execute(
                "SELECT * FROM live_tv_recordings WHERE id=?", (recording_id,)
            ).fetchone()
            return {"schemaVersion": 1, "recording": self._recording(updated)}

    def cancel(self, actor, recording_id, body):
        def action(_connection, row, _now):
            if row["state"] in ("completed", "cancelled"):
                raise ApiError("live_tv_recording_inactive", 409)
            return {"state": "cancelled"}
        return self._mutate(
            actor, recording_id, body, action, provider_action="cancel")

    def interrupt(self, actor, recording_id, body):
        def action(connection, row, now):
            if (row["state"] != "recording"
                    or body.bytesWritten < row["bytes_written"]
                    or body.providerRevision != row["provider_revision"]
                    or body.readbackRevision <= row["readback_revision"]):
                raise ApiError("live_tv_recording_inactive", 409)
            source = self._source(connection.execute(
                "SELECT * FROM live_tv_source WHERE singleton=1"
            ).fetchone())
            load = self._quota_load(connection, now, exclude_id=row["id"])
            if load + body.bytesWritten > source.quotaBytes:
                raise ApiError("live_tv_quota_exceeded", 409)
            return {"state": "interrupted", "bytes_written": body.bytesWritten,
                    "readback_revision": body.readbackRevision}
        return self._mutate(actor, recording_id, body, action, admin=True)

    def restart(self, actor, recording_id, body):
        def action(connection, row, now):
            programme = self._programme(row)
            if row["state"] != "interrupted" or now >= programme["endsAt"]:
                raise ApiError("live_tv_recording_inactive", 409)
            source_row = connection.execute(
                "SELECT * FROM live_tv_source WHERE singleton=1"
            ).fetchone()
            source = self._source(source_row)
            if row["restart_count"] >= 16:
                raise ApiError("live_tv_restart_limit_reached", 409)
            active = connection.execute(
                "SELECT * FROM live_tv_recordings WHERE id!=? "
                "AND state IN ('scheduled','recording')", (row["id"],)
            ).fetchall()
            overlaps = sum(1 for item in active if
                self._programme(item)["startsAt"] < programme["endsAt"] and
                programme["startsAt"] < self._programme(item)["endsAt"])
            if overlaps >= source.parallelTuners:
                raise ApiError("live_tv_recording_conflict", 409)
            used = self._quota_load(connection, now, exclude_id=row["id"])
            reserve = (programme["endsAt"] - now) * BYTES_PER_SECOND_RESERVATION
            if used + reserve > source.quotaBytes:
                raise ApiError("live_tv_quota_exceeded", 409)
            return {"state": "recording", "restart_count": row["restart_count"] + 1}
        return self._mutate(
            actor, recording_id, body, action, provider_action="restart")
