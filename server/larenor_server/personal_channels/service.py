"""Revision-bound personal channel scheduling over authorized media."""

import hashlib
import hmac
import json
import sqlite3
import threading
import uuid

from pydantic import ValidationError

from ..errors import ApiError, StartupError
from ..plugins.media_playback_models import (
    MediaPlaybackCommandRequest,
    MediaPlaybackIntent,
    MediaPlaybackReceipt,
    PrepareMediaPlaybackIntentRequest,
    PrivateMediaPlaybackAuthority,
)
from .models import (
    ChannelAuthority,
    ChannelExecution,
    ChannelSnapshot,
    CreateChannelRequest,
    ExpectedChannelRequest,
    PlaybackSource,
    Programme,
    RescheduleProgrammeRequest,
    ResolveProgrammeRequest,
    StartChannelExecutionRequest,
    StopChannelExecutionRequest,
)

MAX_CHANNELS_PER_ACTOR = 16
MAX_PROGRAMMES_PER_CHANNEL = 64
MAX_GUIDE_PROGRAMMES = 64
MAX_GUIDE_SECONDS = 7 * 24 * 60 * 60
DEFAULT_GUIDE_SECONDS = 60 * 60
MAX_EXECUTIONS = 256
_CHANNEL_FIELDS = (
    "id", "owner_id", "family_id", "actor_revision", "revision", "name",
    "starts_at", "loop", "cycle_seconds", "state", "create_request_id",
    "create_request_hash", "last_request_id", "last_request_hash",
    "created_at", "updated_at",
)
_PROGRAMME_FIELDS = (
    "id", "channel_id", "position", "revision", "title",
    "duration_seconds", "authority_json", "state", "reason",
)
_EXECUTION_FIELDS = (
    "channel_id", "owner_id", "family_id", "actor_revision",
    "channel_revision", "revision", "target_id", "state", "code",
    "programme_id", "programme_revision", "occurrence_starts_at",
    "occurrence_ends_at", "intent_id", "command_id", "last_request_id",
    "last_request_hash", "updated_at",
)


class PersonalChannelService:
    def __init__(self, db, auth, settings, key, context, media_playback):
        self.db, self.auth, self.settings = db, auth, settings
        self._key, self.context = key, context
        self.media_playback = media_playback
        self._tick_lock = threading.Lock()

    @staticmethod
    def _json(value):
        return json.dumps(value, sort_keys=True, separators=(",", ":"),
                          allow_nan=False)

    def _tag(self, kind, values):
        payload = self._json(values).encode()
        return hmac.new(
            self._key,
            b"larenor-personal-channel-v1\0" + kind.encode() + b"\0" + payload,
            hashlib.sha256,
        ).hexdigest()

    def _channel_tag(self, row):
        return self._tag("channel", {
            field: row[field] for field in _CHANNEL_FIELDS
        })

    def _programme_tag(self, row):
        return self._tag("programme", {
            field: row[field] for field in _PROGRAMME_FIELDS
        })

    def _execution_tag(self, row):
        return self._tag("execution", {
            field: row[field] for field in _EXECUTION_FIELDS
        })

    def _channel(self, row):
        if row is None or not hmac.compare_digest(
                row["envelope_tag"], self._channel_tag(row)):
            raise StartupError("personal_channel_storage_invalid")
        if (type(row["loop"]) is not int or row["loop"] not in (0, 1)
                or row["state"] not in {"active", "cancelled"}):
            raise StartupError("personal_channel_storage_invalid")
        return row

    def _programme(self, row):
        if row is None or not hmac.compare_digest(
                row["envelope_tag"], self._programme_tag(row)):
            raise StartupError("personal_channel_storage_invalid")
        try:
            if row["authority_json"] is not None:
                PrivateMediaPlaybackAuthority.model_validate_json(
                    row["authority_json"])
            if ((row["state"] == "scheduled")
                    != (row["authority_json"] is not None)
                    or (row["state"] == "scheduled")
                    != (row["reason"] == "available")):
                raise ValueError()
        except (ValidationError, ValueError, TypeError):
            raise StartupError("personal_channel_storage_invalid") from None
        return row

    def _execution(self, row):
        if row is None or not hmac.compare_digest(
                row["envelope_tag"], self._execution_tag(row)):
            raise StartupError("personal_channel_storage_invalid")
        values = (
            row["programme_id"], row["programme_revision"],
            row["occurrence_starts_at"], row["occurrence_ends_at"],
        )
        if (row["state"] not in {
                "active", "dispatching", "needs_attention", "cancelled"}
                or row["code"] not in {
                    "scheduled", "authenticated_readback", "effect_unknown",
                    "gap", "source_changed", "authority_changed",
                    "source_unavailable", "target_unavailable", "cancelled"}
                or (any(value is None for value in values)
                    != all(value is None for value in values))
                or ((row["intent_id"] is None)
                    != (row["command_id"] is None))):
            raise StartupError("personal_channel_storage_invalid")
        return row

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                channels = connection.execute(
                    "SELECT * FROM personal_channels LIMIT 257"
                ).fetchall()
                programmes = connection.execute(
                    "SELECT * FROM personal_channel_programmes LIMIT 1025"
                ).fetchall()
                executions = connection.execute(
                    "SELECT * FROM personal_channel_executions LIMIT 257"
                ).fetchall()
                if (len(channels) > 256 or len(programmes) > 1024
                        or len(executions) > 256):
                    raise ValueError()
                ids = {self._channel(row)["id"] for row in channels}
                counts = {}
                for raw in programmes:
                    row = self._programme(raw)
                    if row["channel_id"] not in ids:
                        raise ValueError()
                    counts[row["channel_id"]] = counts.get(
                        row["channel_id"], 0) + 1
                if any(not 1 <= count <= MAX_PROGRAMMES_PER_CHANNEL
                       for count in counts.values()):
                    raise ValueError()
                for raw in executions:
                    execution = self._execution(raw)
                    if execution["channel_id"] not in ids:
                        raise ValueError()
        except (sqlite3.Error, StartupError, ValueError, TypeError):
            raise StartupError("personal_channel_storage_invalid") from None

    def _actor(self, connection, actor):
        self.auth.assert_current(connection, actor)
        row = connection.execute(
            "SELECT id,revision,disabled,must_change_password FROM users "
            "WHERE id=?", (actor.id,),
        ).fetchone()
        if (row is None or row["disabled"] or row["must_change_password"]
                or actor.must_change_password):
            raise ApiError("invalid_session", 401)
        return row

    def _owned(self, connection, actor, channel_id, *, active=False,
               expected=None):
        row = self._channel(connection.execute(
            "SELECT * FROM personal_channels WHERE id=?", (channel_id,)
        ).fetchone())
        if row["owner_id"] != actor.id or row["family_id"] != actor.family_id:
            raise ApiError("not_found", 404)
        user = self._actor(connection, actor)
        if row["actor_revision"] != user["revision"]:
            raise ApiError("personal_channel_authority_changed", 409)
        if active and row["state"] != "active":
            raise ApiError("personal_channel_cancelled", 409)
        if expected is not None and row["revision"] != expected:
            raise ApiError("personal_channel_changed", 409)
        return row, user

    @staticmethod
    def _request_hash(body):
        return hashlib.sha256(body.model_dump_json().encode()).hexdigest()

    @staticmethod
    def _catalog_request(source, request_id):
        return PrepareMediaPlaybackIntentRequest.model_validate(
            source.playback_request(request_id))

    def _authority_state(self, actor, authority, actor_revision, programme_id):
        request_id = hashlib.sha256(
            f"{programme_id}:{actor_revision}".encode()
        ).hexdigest()[:32]
        try:
            body = PrepareMediaPlaybackIntentRequest(
                requestId=request_id,
                installationId=authority.installationId,
                expectedInstallationRevision=authority.installationRevision,
                expectedSnapshotRevision=authority.snapshotRevision,
                expectedJellyfinServiceRevision=authority.jellyfinServiceRevision,
                itemId=authority.itemId,
                mediaKey=authority.mediaKey,
            )
            current = self.media_playback._catalog(actor, body)
            if current != authority:
                return "unreachable"
            return "available"
        except ApiError as error:
            if error.code == "media_playback_item_changed":
                return "deleted"
            return "unreachable"
        except Exception:  # authority probes fail closed
            return "unreachable"

    def _update_channel(self, connection, row, **changes):
        value = dict(row)
        value.update(changes)
        value["envelope_tag"] = self._channel_tag(value)
        connection.execute(
            "UPDATE personal_channels SET revision=?,state=?,last_request_id=?,"
            "last_request_hash=?,updated_at=?,envelope_tag=? WHERE id=?",
            (value["revision"], value["state"], value["last_request_id"],
             value["last_request_hash"], value["updated_at"],
             value["envelope_tag"], value["id"]),
        )
        return value

    def _update_programme(self, connection, row, **changes):
        value = dict(row)
        value.update(changes)
        value["envelope_tag"] = self._programme_tag(value)
        connection.execute(
            "UPDATE personal_channel_programmes SET revision=?,title=?,"
            "duration_seconds=?,authority_json=?,state=?,reason=?,"
            "envelope_tag=? WHERE id=?",
            (value["revision"], value["title"], value["duration_seconds"],
             value["authority_json"], value["state"], value["reason"],
             value["envelope_tag"], value["id"]),
        )
        return value

    def _update_execution(self, connection, row, **changes):
        value = dict(row)
        value.update(changes)
        value["envelope_tag"] = self._execution_tag(value)
        changed = connection.execute(
            "UPDATE personal_channel_executions SET owner_id=?,family_id=?,"
            "actor_revision=?,channel_revision=?,revision=?,target_id=?,state=?,"
            "code=?,programme_id=?,programme_revision=?,occurrence_starts_at=?,"
            "occurrence_ends_at=?,intent_id=?,command_id=?,last_request_id=?,"
            "last_request_hash=?,updated_at=?,envelope_tag=? WHERE channel_id=? "
            "AND revision=?",
            (
                value["owner_id"], value["family_id"],
                value["actor_revision"], value["channel_revision"],
                value["revision"], value["target_id"], value["state"],
                value["code"], value["programme_id"],
                value["programme_revision"], value["occurrence_starts_at"],
                value["occurrence_ends_at"], value["intent_id"],
                value["command_id"], value["last_request_id"],
                value["last_request_hash"], value["updated_at"],
                value["envelope_tag"], value["channel_id"], row["revision"],
            ),
        ).rowcount
        if changed != 1:
            raise ApiError("personal_channel_changed", 409)
        return value

    @staticmethod
    def _occurrence(channel, rows, programme_id, starts_at):
        prior = 0
        selected = None
        for row in rows:
            if row["id"] == programme_id:
                selected = row
                break
            prior += row["duration_seconds"]
        if selected is None:
            raise ApiError("personal_channel_changed", 409)
        first = channel["starts_at"] + prior
        distance = starts_at - first
        if (distance < 0
                or (channel["loop"] and distance % channel["cycle_seconds"] != 0)
                or (not channel["loop"] and distance != 0)):
            raise ApiError("invalid_request")
        return selected, starts_at, starts_at + selected["duration_seconds"]

    @staticmethod
    def _current_occurrence(channel, rows, now):
        if now < channel["starts_at"]:
            return None
        elapsed = now - channel["starts_at"]
        if not channel["loop"] and elapsed >= channel["cycle_seconds"]:
            return None
        cycle_start = channel["starts_at"]
        if channel["loop"]:
            cycle_start += (elapsed // channel["cycle_seconds"]) * channel[
                "cycle_seconds"]
        offset = cycle_start
        for row in rows:
            end = offset + row["duration_seconds"]
            if offset <= now < end:
                return row, offset, end
            offset = end
        return None

    def _execution_snapshot(self, row):
        return ChannelExecution(
            channelId=row["channel_id"],
            channelRevision=row["channel_revision"],
            revision=row["revision"],
            targetId=row["target_id"], state=row["state"], code=row["code"],
            programmeId=row["programme_id"],
            programmeRevision=row["programme_revision"],
            occurrenceStartsAt=row["occurrence_starts_at"],
            occurrenceEndsAt=row["occurrence_ends_at"],
        )

    def _assert_execution_authority(self, connection, execution):
        now = self.settings.clock()
        authority = connection.execute(
            "SELECT u.id,u.username,u.role,u.revision,u.disabled,"
            "u.must_change_password,f.revoked_at,f.expires_at "
            "FROM users u JOIN session_families f ON f.user_id=u.id "
            "WHERE u.id=? AND f.id=?",
            (execution["owner_id"], execution["family_id"]),
        ).fetchone()
        if (authority is None or authority["disabled"]
                or authority["must_change_password"]
                or authority["revision"] != execution["actor_revision"]
                or authority["revoked_at"] is not None
                or now >= authority["expires_at"]):
            raise ApiError("invalid_session", 401)
        return authority

    def _rows(self, connection, channel_id):
        rows = [self._programme(row) for row in connection.execute(
            "SELECT * FROM personal_channel_programmes WHERE channel_id=? "
            "ORDER BY position", (channel_id,),
        ).fetchall()]
        if not rows or len(rows) > MAX_PROGRAMMES_PER_CHANNEL or any(
                row["position"] != index for index, row in enumerate(rows)):
            raise StartupError("personal_channel_storage_invalid")
        return rows

    def _snapshot(self, channel, user, rows, guide_from, guide_until):
        if (type(guide_from) is not int or type(guide_until) is not int
                or guide_from < 1 or not guide_from < guide_until
                or guide_until - guide_from > MAX_GUIDE_SECONDS):
            raise ApiError("invalid_request")
        offsets, elapsed = [], 0
        for row in rows:
            offsets.append(elapsed)
            elapsed += row["duration_seconds"]
        if elapsed != channel["cycle_seconds"]:
            raise StartupError("personal_channel_storage_invalid")
        cycle = channel["cycle_seconds"]
        first_cycle = 0
        last_cycle = 0
        if channel["loop"]:
            first_cycle = max(0, (guide_from - channel["starts_at"]) // cycle - 1)
            last_cycle = max(0, (guide_until - channel["starts_at"]) // cycle + 1)
        items = []
        for cycle_index in range(first_cycle, last_cycle + 1):
            base = channel["starts_at"] + cycle_index * cycle
            for row, offset in zip(rows, offsets):
                starts, ends = base + offset, base + offset + row["duration_seconds"]
                if ends <= guide_from or starts >= guide_until:
                    continue
                source = (None if row["authority_json"] is None else
                          PrivateMediaPlaybackAuthority.model_validate_json(
                              row["authority_json"]))
                items.append(Programme(
                    programmeId=row["id"], revision=row["revision"],
                    position=row["position"], title=row["title"],
                    itemId=None if source is None else source.itemId,
                    mediaKey=None if source is None else source.mediaKey,
                    occurrenceStartsAt=starts, occurrenceEndsAt=ends,
                    state=row["state"], reason=row["reason"],
                    canRestart=row["state"] == "scheduled",
                ))
                if len(items) > MAX_GUIDE_PROGRAMMES:
                    raise ApiError("personal_channel_guide_limit_reached", 429)
            if not channel["loop"]:
                break
        return ChannelSnapshot(
            channelId=channel["id"],
            authority=ChannelAuthority(
                coreId=self.context.coreId, homeId=self.context.homeId,
                accountId=channel["owner_id"],
                accountRevision=user["revision"],
                sessionFamilyId=channel["family_id"],
            ),
            revision=channel["revision"], name=channel["name"],
            state=channel["state"], startsAt=channel["starts_at"],
            loop=bool(channel["loop"]), cycleSeconds=cycle,
            guideFrom=guide_from, guideUntil=guide_until, programmes=items,
        )

    def _guide_window(self, guide_from=None, guide_until=None):
        start = int(self.settings.clock()) if guide_from is None else guide_from
        end = start + DEFAULT_GUIDE_SECONDS if guide_until is None else guide_until
        return start, end

    def create(self, actor, body):
        if type(body) is not CreateChannelRequest:
            raise ApiError("invalid_request")
        request_hash = self._request_hash(body)
        now = int(self.settings.clock())
        with self.db.connection() as connection:
            user = self._actor(connection, actor)
            existing = connection.execute(
                "SELECT * FROM personal_channels WHERE create_request_id=?",
                (body.requestId,),
            ).fetchone()
            if existing is not None:
                channel = self._channel(existing)
                if (channel["owner_id"] != actor.id
                        or channel["family_id"] != actor.family_id
                        or channel["create_request_hash"] != request_hash):
                    raise ApiError("idempotency_conflict", 409)
                if channel["actor_revision"] != user["revision"]:
                    raise ApiError("personal_channel_authority_changed", 409)
                rows = self._rows(connection, channel["id"])
                start, end = self._guide_window()
                return {"channel": self._snapshot(
                    channel, user, rows, start, end)}
        authorities = []
        for index, source in enumerate(body.sources):
            request_id = hashlib.sha256(
                f"{body.requestId}:{index}".encode()
            ).hexdigest()[:32]
            authorities.append(self.media_playback._catalog(
                actor, self._catalog_request(source, request_id)))
        with self.db.transaction() as connection:
            user = self._actor(connection, actor)
            existing = connection.execute(
                "SELECT * FROM personal_channels WHERE create_request_id=?",
                (body.requestId,),
            ).fetchone()
            if existing is not None:
                channel = self._channel(existing)
                if (channel["owner_id"] != actor.id
                        or channel["family_id"] != actor.family_id
                        or channel["create_request_hash"] != request_hash):
                    raise ApiError("idempotency_conflict", 409)
                if channel["actor_revision"] != user["revision"]:
                    raise ApiError("personal_channel_authority_changed", 409)
                rows = self._rows(connection, channel["id"])
                start, end = self._guide_window()
                return {"channel": self._snapshot(
                    channel, user, rows, start, end)}
            connection.execute(
                "DELETE FROM personal_channels WHERE state='cancelled' "
                "AND updated_at<=?", (now - 86_400,),
            )
            count = connection.execute(
                "SELECT COUNT(*) FROM personal_channels WHERE owner_id=? "
                "AND state='active'", (actor.id,),
            ).fetchone()[0]
            if count >= MAX_CHANNELS_PER_ACTOR:
                raise ApiError("personal_channel_limit_reached", 409)
            channel_id = uuid.uuid4().hex
            channel = {
                "id": channel_id, "owner_id": actor.id,
                "family_id": actor.family_id,
                "actor_revision": user["revision"], "revision": 1,
                "name": body.name, "starts_at": body.startsAt,
                "loop": int(body.loop),
                "cycle_seconds": sum(item.durationSeconds for item in body.sources),
                "state": "active", "create_request_id": body.requestId,
                "create_request_hash": request_hash,
                "last_request_id": None, "last_request_hash": None,
                "created_at": now, "updated_at": now,
            }
            channel["envelope_tag"] = self._channel_tag(channel)
            connection.execute(
                "INSERT INTO personal_channels VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                tuple(channel.values()),
            )
            rows = []
            for index, (source, authority) in enumerate(
                    zip(body.sources, authorities)):
                row = {
                    "id": uuid.uuid4().hex, "channel_id": channel_id,
                    "position": index, "revision": 1,
                    "title": source.title,
                    "duration_seconds": source.durationSeconds,
                    "authority_json": authority.model_dump_json(),
                    "state": "scheduled", "reason": "available",
                }
                row["envelope_tag"] = self._programme_tag(row)
                connection.execute(
                    "INSERT INTO personal_channel_programmes "
                    "VALUES(?,?,?,?,?,?,?,?,?,?)", tuple(row.values()),
                )
                rows.append(row)
            start, end = self._guide_window()
            return {"channel": self._snapshot(channel, user, rows, start, end)}

    def _reconcile(self, actor, channel_id):
        with self.db.connection() as connection:
            channel, user = self._owned(
                connection, actor, channel_id, active=True)
            rows = self._rows(connection, channel_id)
        changed = []
        for row in rows:
            if row["state"] != "scheduled":
                continue
            authority = PrivateMediaPlaybackAuthority.model_validate_json(
                row["authority_json"])
            state = self._authority_state(
                actor, authority, user["revision"], row["id"])
            if state != "available":
                changed.append((row["id"], row["revision"], state))
        if not changed:
            return
        now = int(self.settings.clock())
        with self.db.transaction() as connection:
            channel, _ = self._owned(
                connection, actor, channel_id, active=True,
                expected=channel["revision"])
            for programme_id, revision, reason in changed:
                row = self._programme(connection.execute(
                    "SELECT * FROM personal_channel_programmes WHERE id=? "
                    "AND channel_id=?", (programme_id, channel_id),
                ).fetchone())
                if row["revision"] != revision:
                    raise ApiError("personal_channel_changed", 409)
                self._update_programme(
                    connection, row, revision=revision + 1,
                    authority_json=None, state="gap", reason=reason,
                )
            self._update_channel(
                connection, channel, revision=channel["revision"] + 1,
                updated_at=now,
            )

    def read(self, actor, channel_id, guide_from=None, guide_until=None):
        self._reconcile(actor, channel_id)
        with self.db.connection() as connection:
            channel, user = self._owned(connection, actor, channel_id)
            rows = self._rows(connection, channel_id)
            start, end = self._guide_window(guide_from, guide_until)
            return {"channel": self._snapshot(
                channel, user, rows, start, end)}

    def list(self, actor):
        start, end = self._guide_window()
        with self.db.connection() as connection:
            user = self._actor(connection, actor)
            raw = connection.execute(
                "SELECT * FROM personal_channels WHERE owner_id=? "
                "AND family_id=? AND actor_revision=? AND state='active' "
                "ORDER BY updated_at DESC,id LIMIT 17",
                (actor.id, actor.family_id, user["revision"]),
            ).fetchall()
            if len(raw) > MAX_CHANNELS_PER_ACTOR:
                raise StartupError("personal_channel_storage_invalid")
            channels = []
            for value in raw:
                channel = self._channel(value)
                channels.append(self._snapshot(
                    channel, user, self._rows(connection, channel["id"]),
                    start, end))
            return {"schemaVersion": 1, "channels": channels}

    def reschedule(self, actor, channel_id, programme_id, body):
        if type(body) is not RescheduleProgrammeRequest:
            raise ApiError("invalid_request")
        request_hash = self._request_hash(body)
        with self.db.connection() as connection:
            channel, user = self._owned(
                connection, actor, channel_id, active=True)
            if channel["last_request_id"] == body.requestId:
                if channel["last_request_hash"] != request_hash:
                    raise ApiError("idempotency_conflict", 409)
                rows = self._rows(connection, channel_id)
                start, end = self._guide_window()
                return {"channel": self._snapshot(
                    channel, user, rows, start, end)}
        authority = self.media_playback._catalog(
            actor, self._catalog_request(body.source, body.requestId))
        now = int(self.settings.clock())
        with self.db.transaction() as connection:
            channel, user = self._owned(
                connection, actor, channel_id, active=True)
            if channel["last_request_id"] == body.requestId:
                if channel["last_request_hash"] != request_hash:
                    raise ApiError("idempotency_conflict", 409)
                rows = self._rows(connection, channel_id)
                start, end = self._guide_window()
                return {"channel": self._snapshot(
                    channel, user, rows, start, end)}
            if channel["revision"] != body.expectedRevision:
                raise ApiError("personal_channel_changed", 409)
            row = self._programme(connection.execute(
                "SELECT * FROM personal_channel_programmes WHERE id=? "
                "AND channel_id=?", (programme_id, channel_id),
            ).fetchone())
            if (row["revision"] != body.expectedProgrammeRevision
                    or row["state"] != "gap"):
                raise ApiError("personal_channel_changed", 409)
            self._update_programme(
                connection, row, revision=row["revision"] + 1,
                title=body.source.title,
                duration_seconds=body.source.durationSeconds,
                authority_json=authority.model_dump_json(),
                state="scheduled", reason="available",
            )
            rows = self._rows(connection, channel_id)
            cycle = sum(item["duration_seconds"] for item in rows)
            channel = self._update_channel(
                connection, channel, revision=channel["revision"] + 1,
                last_request_id=body.requestId,
                last_request_hash=request_hash, updated_at=now,
            )
            if cycle != channel["cycle_seconds"]:
                value = dict(channel)
                value["cycle_seconds"] = cycle
                value["envelope_tag"] = self._channel_tag(value)
                connection.execute(
                    "UPDATE personal_channels SET cycle_seconds=?,envelope_tag=? "
                    "WHERE id=?", (cycle, value["envelope_tag"], channel_id),
                )
                channel = value
            start, end = self._guide_window()
            return {"channel": self._snapshot(
                channel, user, rows, start, end)}

    def cancel(self, actor, channel_id, body):
        if type(body) is not ExpectedChannelRequest:
            raise ApiError("invalid_request")
        request_hash = self._request_hash(body)
        now = int(self.settings.clock())
        with self.db.transaction() as connection:
            channel, user = self._owned(connection, actor, channel_id)
            if channel["last_request_id"] == body.requestId:
                if channel["last_request_hash"] != request_hash:
                    raise ApiError("idempotency_conflict", 409)
            else:
                if channel["revision"] != body.expectedRevision:
                    raise ApiError("personal_channel_changed", 409)
                channel = self._update_channel(
                    connection, channel, revision=channel["revision"] + 1,
                    state="cancelled", last_request_id=body.requestId,
                    last_request_hash=request_hash, updated_at=now,
                )
            rows = self._rows(connection, channel_id)
            execution = connection.execute(
                "SELECT * FROM personal_channel_executions WHERE channel_id=?",
                (channel_id,),
            ).fetchone()
            if execution is not None:
                execution = self._execution(execution)
                if execution["state"] != "cancelled":
                    self._update_execution(
                        connection, execution,
                        revision=execution["revision"] + 1,
                        state="cancelled", code="cancelled",
                        last_request_id=body.requestId,
                        last_request_hash=request_hash, updated_at=now,
                    )
            start, end = self._guide_window()
            return {"channel": self._snapshot(
                channel, user, rows, start, end)}

    def start_execution(self, actor, channel_id, body):
        if type(body) is not StartChannelExecutionRequest:
            raise ApiError("invalid_request")
        request_hash = self._request_hash(body)
        now = int(self.settings.clock())
        with self.db.transaction() as connection:
            channel, user = self._owned(
                connection, actor, channel_id, active=True,
                expected=body.expectedChannelRevision,
            )
            rows = self._rows(connection, channel_id)
            programme, starts, ends = self._occurrence(
                channel, rows, body.programmeId, body.occurrenceStartsAt)
            if (programme["revision"] != body.expectedProgrammeRevision
                    or programme["state"] != "scheduled"):
                raise ApiError("personal_channel_changed", 409)
            if not starts <= now < ends:
                raise ApiError("personal_channel_programme_not_live", 409)
            existing = connection.execute(
                "SELECT * FROM personal_channel_executions WHERE channel_id=?",
                (channel_id,),
            ).fetchone()
            if existing is not None:
                existing = self._execution(existing)
                if existing["last_request_id"] == body.requestId:
                    if existing["last_request_hash"] != request_hash:
                        raise ApiError("idempotency_conflict", 409)
                    return {"execution": self._execution_snapshot(existing)}
                if existing["state"] in {"active", "dispatching"}:
                    raise ApiError("personal_channel_changed", 409)
                connection.execute(
                    "DELETE FROM personal_channel_executions WHERE channel_id=?",
                    (channel_id,),
                )
            execution = {
                "channel_id": channel_id, "owner_id": actor.id,
                "family_id": actor.family_id,
                "actor_revision": user["revision"],
                "channel_revision": channel["revision"], "revision": 1,
                "target_id": body.targetId, "state": "active",
                "code": "scheduled", "programme_id": None,
                "programme_revision": None, "occurrence_starts_at": None,
                "occurrence_ends_at": None, "intent_id": None,
                "command_id": None, "last_request_id": body.requestId,
                "last_request_hash": request_hash, "updated_at": now,
            }
            execution["envelope_tag"] = self._execution_tag(execution)
            connection.execute(
                "INSERT INTO personal_channel_executions "
                "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                tuple(execution.values()),
            )
        self.tick(channel_id)
        return self.read_execution(actor, channel_id)

    def read_execution(self, actor, channel_id):
        with self.db.connection() as connection:
            self._owned(connection, actor, channel_id)
            raw = connection.execute(
                "SELECT * FROM personal_channel_executions WHERE channel_id=?",
                (channel_id,),
            ).fetchone()
            if raw is None:
                raise ApiError("not_found", 404)
            row = self._execution(raw)
            if row["owner_id"] != actor.id or row["family_id"] != actor.family_id:
                raise ApiError("not_found", 404)
            return {"execution": self._execution_snapshot(row)}

    def stop_execution(self, actor, channel_id, body):
        if type(body) is not StopChannelExecutionRequest:
            raise ApiError("invalid_request")
        request_hash = self._request_hash(body)
        now = int(self.settings.clock())
        with self.db.transaction() as connection:
            self._owned(connection, actor, channel_id)
            raw = connection.execute(
                "SELECT * FROM personal_channel_executions WHERE channel_id=?",
                (channel_id,),
            ).fetchone()
            if raw is None:
                raise ApiError("not_found", 404)
            row = self._execution(raw)
            if row["owner_id"] != actor.id or row["family_id"] != actor.family_id:
                raise ApiError("not_found", 404)
            if row["last_request_id"] == body.requestId:
                if row["last_request_hash"] != request_hash:
                    raise ApiError("idempotency_conflict", 409)
            else:
                if row["revision"] != body.expectedExecutionRevision:
                    raise ApiError("personal_channel_changed", 409)
                row = self._update_execution(
                    connection, row, revision=row["revision"] + 1,
                    state="cancelled", code="cancelled",
                    last_request_id=body.requestId,
                    last_request_hash=request_hash, updated_at=now,
                )
            return {"execution": self._execution_snapshot(row)}

    def _mark_execution(self, channel_id, revision, **changes):
        with self.db.transaction() as connection:
            raw = connection.execute(
                "SELECT * FROM personal_channel_executions WHERE channel_id=?",
                (channel_id,),
            ).fetchone()
            if raw is None:
                return None
            row = self._execution(raw)
            if row["revision"] != revision:
                return None
            return self._update_execution(
                connection, row, revision=revision + 1,
                updated_at=int(self.settings.clock()), **changes,
            )

    def _assert_dispatch_current(self, connection, reserved, programme,
                                 intent_id, command_id):
        execution = self._execution(connection.execute(
            "SELECT * FROM personal_channel_executions WHERE channel_id=?",
            (reserved["channel_id"],),
        ).fetchone())
        self._assert_execution_authority(connection, execution)
        channel = self._channel(connection.execute(
            "SELECT * FROM personal_channels WHERE id=?",
            (reserved["channel_id"],),
        ).fetchone())
        current_programme = self._programme(connection.execute(
            "SELECT * FROM personal_channel_programmes WHERE id=? "
            "AND channel_id=?",
            (programme["id"], reserved["channel_id"]),
        ).fetchone())
        if not (
                execution["revision"] == reserved["revision"]
                and execution["state"] == "dispatching"
                and execution["intent_id"] == intent_id
                and execution["command_id"] == command_id
                and execution["programme_id"] == programme["id"]
                and execution["programme_revision"]
                == reserved["programme_revision"]
                and channel["revision"] == reserved["channel_revision"]
                and channel["state"] == "active"
                and channel["owner_id"] == reserved["owner_id"]
                and channel["family_id"] == reserved["family_id"]
                and channel["actor_revision"] == reserved["actor_revision"]
                and current_programme["revision"]
                == reserved["programme_revision"]
                and current_programme["state"] == "scheduled"
                and current_programme["authority_json"]
                == programme["authority_json"]):
            raise ApiError("personal_channel_authority_changed", 409)
        return True

    def _dispatch_current(self, reserved, programme, intent_id, command_id):
        try:
            with self.db.connection() as connection:
                return self._assert_dispatch_current(
                    connection, reserved, programme, intent_id, command_id)
        except Exception:  # every stale/corrupt authority observation fails closed
            return False

    def _tick_one(self, channel_id):
        now = int(self.settings.clock())
        with self.db.connection() as connection:
            raw = connection.execute(
                "SELECT * FROM personal_channel_executions WHERE channel_id=?",
                (channel_id,),
            ).fetchone()
            if raw is None:
                return
            execution = self._execution(raw)
            if execution["state"] in {"cancelled", "needs_attention"}:
                return
            channel = self._channel(connection.execute(
                "SELECT * FROM personal_channels WHERE id=?", (channel_id,),
            ).fetchone())
            rows = self._rows(connection, channel_id)
            try:
                self._assert_execution_authority(connection, execution)
                retired = False
            except ApiError:
                retired = True
        if retired:
            self._mark_execution(
                channel_id, execution["revision"],
                state="needs_attention", code="authority_changed",
            )
            return
        if (channel["state"] != "active"
                or channel["owner_id"] != execution["owner_id"]
                or channel["family_id"] != execution["family_id"]
                or channel["actor_revision"] != execution["actor_revision"]):
            self._mark_execution(
                channel_id, execution["revision"],
                state="needs_attention", code="authority_changed",
            )
            return
        if channel["revision"] != execution["channel_revision"]:
            self._mark_execution(
                channel_id, execution["revision"],
                state="needs_attention", code="source_changed",
            )
            return
        if execution["state"] == "dispatching":
            if now < execution["occurrence_ends_at"]:
                return
            updated = self._mark_execution(
                channel_id, execution["revision"],
                state="active", code="effect_unknown",
            )
            if updated is None:
                return
            execution = updated
        current = self._current_occurrence(channel, rows, now)
        if current is None:
            return
        programme, starts, ends = current
        if (execution["programme_id"] == programme["id"]
                and execution["programme_revision"] == programme["revision"]
                and execution["occurrence_starts_at"] == starts):
            return
        if programme["state"] != "scheduled":
            self._mark_execution(
                channel_id, execution["revision"], state="active", code="gap",
                programme_id=programme["id"],
                programme_revision=programme["revision"],
                occurrence_starts_at=starts, occurrence_ends_at=ends,
                intent_id=None, command_id=None,
            )
            return
        intent_id, command_id = uuid.uuid4().hex, uuid.uuid4().hex
        reserved = self._mark_execution(
            channel_id, execution["revision"], state="dispatching",
            code="effect_unknown", programme_id=programme["id"],
            programme_revision=programme["revision"],
            occurrence_starts_at=starts, occurrence_ends_at=ends,
            intent_id=intent_id, command_id=command_id,
        )
        if reserved is None:
            return
        authority = PrivateMediaPlaybackAuthority.model_validate_json(
            programme["authority_json"])
        request = PrepareMediaPlaybackIntentRequest(
            requestId=intent_id, installationId=authority.installationId,
            expectedInstallationRevision=authority.installationRevision,
            expectedSnapshotRevision=authority.snapshotRevision,
            expectedJellyfinServiceRevision=authority.jellyfinServiceRevision,
            itemId=authority.itemId, mediaKey=authority.mediaKey,
        )
        try:
            assert_current = lambda connection: self._assert_dispatch_current(
                connection, reserved, programme, intent_id, command_id)
            prepared = self.media_playback._prepare_scoped(
                reserved["owner_id"], reserved["family_id"],
                reserved["actor_revision"], request, assert_current)
            intent = MediaPlaybackIntent.model_validate(prepared["intent"])
            target = next((value for value in intent.targets
                           if value.targetId == reserved["target_id"]
                           and value.available), None)
            if target is None:
                self._mark_execution(
                    channel_id, reserved["revision"],
                    state="needs_attention", code="target_unavailable",
                )
                return
            command = MediaPlaybackCommandRequest(
                requestId=command_id, intentId=intent.requestId,
                expectedPlaybackRevision=intent.playbackRevision,
                targetId=target.targetId,
                expectedTargetRevision=target.targetRevision,
                startSeconds=min(now - starts,
                                 programme["duration_seconds"] - 1),
            )
            effect_gate = lambda: self._dispatch_current(
                reserved, programme, intent_id, command_id)
            dispatch_current = effect_gate()
            if not dispatch_current:
                self._mark_execution(
                    channel_id, reserved["revision"],
                    state="needs_attention", code="source_changed",
                )
                return
            result = self.media_playback._command_scoped(
                reserved["owner_id"], reserved["family_id"],
                reserved["actor_revision"], command, assert_current,
                effect_gate=effect_gate)
            receipt = MediaPlaybackReceipt.model_validate(result["receipt"])
            if (receipt.requestId != command_id
                    or receipt.intentId != intent_id
                    or receipt.itemId != authority.itemId
                    or receipt.installationId != authority.installationId
                    or receipt.targetId != target.targetId
                    or receipt.playbackRevision
                    <= command.expectedPlaybackRevision
                    or receipt.state != "succeeded"
                    or receipt.code != "authenticated_readback"):
                raise ValueError()
            self._mark_execution(
                channel_id, reserved["revision"], state="active",
                code="authenticated_readback",
            )
        except ApiError as error:
            if error.code == "media_playback_worker_unavailable":
                return
            code = ("authority_changed" if error.code == "invalid_session"
                    else "source_unavailable")
            self._mark_execution(
                channel_id, reserved["revision"],
                state="needs_attention", code=code,
            )
        except Exception:
            # The command may have crossed the private worker boundary. Keep the
            # durable dispatch reservation and never resend this occurrence.
            return

    def tick(self, channel_id=None):
        if not self._tick_lock.acquire(blocking=False):
            return
        try:
            if channel_id is None:
                with self.db.connection() as connection:
                    ids = [row["channel_id"] for row in connection.execute(
                        "SELECT channel_id FROM personal_channel_executions "
                        "WHERE state IN ('active','dispatching') "
                        "ORDER BY updated_at,channel_id LIMIT 257"
                    ).fetchall()]
                if len(ids) > MAX_EXECUTIONS:
                    raise StartupError("personal_channel_storage_invalid")
            else:
                ids = [channel_id]
            for value in ids:
                self._tick_one(value)
        finally:
            self._tick_lock.release()

    def resolve(self, actor, channel_id, body):
        if type(body) is not ResolveProgrammeRequest:
            raise ApiError("invalid_request")
        now = int(self.settings.clock())
        with self.db.connection() as connection:
            channel, _ = self._owned(
                connection, actor, channel_id, active=True,
                expected=body.expectedChannelRevision)
            row = self._programme(connection.execute(
                "SELECT * FROM personal_channel_programmes WHERE id=? "
                "AND channel_id=?", (body.programmeId, channel_id),
            ).fetchone())
            if (row["revision"] != body.expectedProgrammeRevision
                    or row["state"] != "scheduled"):
                raise ApiError("personal_channel_changed", 409)
            authority = PrivateMediaPlaybackAuthority.model_validate_json(
                row["authority_json"])
            if self._authority_state(
                    actor, authority, channel["actor_revision"], row["id"]
                    ) != "available":
                raise ApiError("personal_channel_source_unavailable", 409)
            if self._actor(connection, actor)["revision"] != channel[
                    "actor_revision"]:
                raise ApiError("personal_channel_authority_changed", 409)
            prior = connection.execute(
                "SELECT COALESCE(SUM(duration_seconds),0) FROM "
                "personal_channel_programmes WHERE channel_id=? AND position<?",
                (channel_id, row["position"]),
            ).fetchone()[0]
            first = channel["starts_at"] + prior
            distance = body.occurrenceStartsAt - first
            if (distance < 0 or (channel["loop"] and
                    distance % channel["cycle_seconds"] != 0)
                    or not channel["loop"] and distance != 0):
                raise ApiError("invalid_request")
            offset = now - body.occurrenceStartsAt
            if body.mode == "live" and not 0 <= offset < row["duration_seconds"]:
                raise ApiError("personal_channel_programme_not_live", 409)
            if (body.mode == "restart"
                    and (now < body.occurrenceStartsAt
                         or offset > MAX_GUIDE_SECONDS)):
                raise ApiError("personal_channel_programme_not_started", 409)
            start_seconds = offset if body.mode == "live" else 0
            return {"playback": PlaybackSource(
                channelId=channel_id, channelRevision=channel["revision"],
                programmeId=row["id"], programmeRevision=row["revision"],
                occurrenceStartsAt=body.occurrenceStartsAt,
                startSeconds=min(start_seconds, row["duration_seconds"] - 1),
                authority=authority,
            )}
