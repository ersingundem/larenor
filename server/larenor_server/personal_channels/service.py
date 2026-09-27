"""Revision-bound personal channel scheduling over authorized media."""

import hashlib
import hmac
import json
import sqlite3
import uuid

from pydantic import ValidationError

from ..errors import ApiError, StartupError
from ..plugins.media_playback_models import (
    PrepareMediaPlaybackIntentRequest,
    PrivateMediaPlaybackAuthority,
)
from .models import (
    ChannelAuthority,
    ChannelSnapshot,
    CreateChannelRequest,
    ExpectedChannelRequest,
    PlaybackSource,
    Programme,
    RescheduleProgrammeRequest,
    ResolveProgrammeRequest,
)

MAX_CHANNELS_PER_ACTOR = 16
MAX_PROGRAMMES_PER_CHANNEL = 64
MAX_GUIDE_PROGRAMMES = 64
MAX_GUIDE_SECONDS = 7 * 24 * 60 * 60
DEFAULT_GUIDE_SECONDS = 60 * 60
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


class PersonalChannelService:
    def __init__(self, db, auth, settings, key, context, media_playback):
        self.db, self.auth, self.settings = db, auth, settings
        self._key, self.context = key, context
        self.media_playback = media_playback

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

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                channels = connection.execute(
                    "SELECT * FROM personal_channels LIMIT 257"
                ).fetchall()
                programmes = connection.execute(
                    "SELECT * FROM personal_channel_programmes LIMIT 1025"
                ).fetchall()
                if len(channels) > 256 or len(programmes) > 1024:
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
            start, end = self._guide_window()
            return {"channel": self._snapshot(
                channel, user, rows, start, end)}

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
