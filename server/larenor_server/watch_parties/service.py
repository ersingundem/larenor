"""Durable, revision-bound watch-party authority and synchronization hints."""

import hashlib
import hmac
import json
import uuid

from pydantic import ValidationError

from ..errors import ApiError, StartupError
from ..plugins.media_playback_models import PrivateMediaPlaybackAuthority
from .models import (
    CommandWatchPartyRequest,
    CreateWatchPartyRequest,
    JoinWatchPartyRequest,
    LeaveWatchPartyRequest,
    ReportWatchPartyRequest,
    TransferWatchPartyLeaderRequest,
    WatchPartyAuthority,
    WatchPartyCommand,
    WatchPartyDirective,
    WatchPartyMember,
    WatchPartyPlayback,
    WatchPartySnapshot,
    WatchPartyTarget,
)

MAX_ROOMS = 64
MAX_PARTICIPANTS = 16
MAX_TTL = 6 * 60 * 60
CONNECTED_SECONDS = 30
_ROOM_FIELDS = (
    "id", "create_request_id", "create_actor_id", "create_hash",
    "leader_account_id", "leader_family_id", "revision", "authority_json",
    "invite_digest", "tolerance_ms", "command_revision", "command_json",
    "state", "expires_at", "created_at", "updated_at",
)
_PARTICIPANT_FIELDS = (
    "room_id", "account_id", "family_id", "revision", "request_id",
    "request_hash", "target_json", "playback_json", "joined_at",
    "last_seen_at",
)


class WatchPartyService:
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
            self._key, b"larenor-watch-party-v1\0" + kind.encode() + b"\0"
            + payload, hashlib.sha256).hexdigest()

    def _room_tag(self, row):
        return self._tag("room", {field: row[field] for field in _ROOM_FIELDS})

    def _participant_tag(self, row):
        return self._tag(
            "participant", {field: row[field] for field in _PARTICIPANT_FIELDS})

    def _room(self, row):
        if row is None or not hmac.compare_digest(
                row["envelope_tag"], self._room_tag(row)):
            raise StartupError("watch_party_storage_invalid")
        try:
            PrivateMediaPlaybackAuthority.model_validate_json(
                row["authority_json"])
            WatchPartyCommand.model_validate_json(row["command_json"])
        except (ValidationError, ValueError, TypeError):
            raise StartupError("watch_party_storage_invalid") from None
        return row

    def _participant(self, row):
        if row is None or not hmac.compare_digest(
                row["envelope_tag"], self._participant_tag(row)):
            raise StartupError("watch_party_storage_invalid")
        try:
            if row["target_json"] is not None:
                WatchPartyTarget.model_validate_json(row["target_json"])
            if row["playback_json"] is not None:
                WatchPartyPlayback.model_validate_json(row["playback_json"])
        except (ValidationError, ValueError, TypeError):
            raise StartupError("watch_party_storage_invalid") from None
        return row

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                for row in connection.execute("SELECT * FROM watch_party_rooms"):
                    self._room(row)
                for row in connection.execute(
                        "SELECT * FROM watch_party_participants"):
                    self._participant(row)
        except (StartupError, ValueError, TypeError):
            raise StartupError("watch_party_storage_invalid") from None

    def _actor(self, connection, actor):
        self.auth.assert_current(connection, actor)
        row = connection.execute(
            "SELECT id,revision,disabled,must_change_password FROM users "
            "WHERE id=?", (actor.id,)).fetchone()
        if (row is None or row["disabled"] or row["must_change_password"]
                or actor.must_change_password):
            raise ApiError("invalid_session", 401)
        return row

    def _invite(self, room_id):
        return hmac.new(
            self._key, b"larenor-watch-party-invite-v1\0" + room_id.encode(),
            hashlib.sha256).hexdigest()[:32]

    @staticmethod
    def _digest(value):
        return hashlib.sha256(value.encode()).hexdigest()

    def _active_room(self, connection, room_id, expected=None):
        raw = connection.execute(
            "SELECT * FROM watch_party_rooms WHERE id=?", (room_id,)
        ).fetchone()
        if raw is None:
            raise ApiError("not_found", 404)
        row = self._room(raw)
        now = int(self.settings.clock())
        if (row["state"] != "active" or now >= row["expires_at"]
                or expected is not None and row["revision"] != expected):
            raise ApiError("watch_party_authority_changed", 409)
        return row

    def _member(self, connection, actor, room):
        raw = connection.execute(
            "SELECT * FROM watch_party_participants "
            "WHERE room_id=? AND account_id=?", (room["id"], actor.id)
        ).fetchone()
        if raw is None:
            raise ApiError("not_found", 404)
        row = self._participant(raw)
        if row["family_id"] != actor.family_id:
            raise ApiError("not_found", 404)
        return row

    def _current(self, actor, room):
        authority = PrivateMediaPlaybackAuthority.model_validate_json(
            room["authority_json"])
        if self.media_playback._gate(actor, authority) is not True:
            raise ApiError("watch_party_authority_changed", 409)

    def _update_room(self, connection, row, **changes):
        value = dict(row)
        value.update(changes)
        value["envelope_tag"] = self._room_tag(value)
        connection.execute(
            "UPDATE watch_party_rooms SET leader_account_id=?,"
            "leader_family_id=?,revision=?,command_revision=?,command_json=?,"
            "state=?,updated_at=?,envelope_tag=? WHERE id=?",
            (value["leader_account_id"], value["leader_family_id"],
             value["revision"], value["command_revision"],
             value["command_json"], value["state"], value["updated_at"],
             value["envelope_tag"], value["id"]))
        return value

    def _update_participant(self, connection, row, **changes):
        value = dict(row)
        value.update(changes)
        value["envelope_tag"] = self._participant_tag(value)
        connection.execute(
            "UPDATE watch_party_participants SET family_id=?,revision=?,"
            "request_id=?,request_hash=?,target_json=?,playback_json=?,"
            "last_seen_at=?,envelope_tag=? WHERE room_id=? AND account_id=?",
            (value["family_id"], value["revision"], value["request_id"],
             value["request_hash"], value["target_json"],
             value["playback_json"], value["last_seen_at"],
             value["envelope_tag"], value["room_id"], value["account_id"]))
        return value

    def _snapshot(self, connection, room, actor, directive=False):
        authority = PrivateMediaPlaybackAuthority.model_validate_json(
            room["authority_json"])
        rows = [self._participant(row) for row in connection.execute(
            "SELECT * FROM watch_party_participants WHERE room_id=? "
            "ORDER BY joined_at,account_id", (room["id"],)).fetchall()]
        now = int(self.settings.clock())
        members = []
        current = None
        for row in rows:
            target = (None if row["target_json"] is None else
                      WatchPartyTarget.model_validate_json(row["target_json"]))
            playback = (None if row["playback_json"] is None else
                         WatchPartyPlayback.model_validate_json(
                             row["playback_json"]))
            member = WatchPartyMember(
                accountId=row["account_id"], revision=row["revision"],
                isLeader=row["account_id"] == room["leader_account_id"],
                connected=now - row["last_seen_at"] <= CONNECTED_SECONDS,
                target=target, playback=playback,
                lastSeenAt=row["last_seen_at"])
            members.append(member)
            if row["account_id"] == actor.id:
                current = row
        if current is None:
            raise ApiError("not_found", 404)
        command = WatchPartyCommand.model_validate_json(room["command_json"])
        hint = self._directive(room, command, current, now) if directive else None
        return WatchPartySnapshot(
            authority=WatchPartyAuthority(
                coreId=self.context.coreId, homeId=self.context.homeId,
                roomId=room["id"],
                **authority.model_dump(mode="python")),
            revision=room["revision"], state=room["state"],
            leaderAccountId=room["leader_account_id"],
            expiresAt=room["expires_at"], toleranceMs=room["tolerance_ms"],
            command=command, participants=members, directive=hint)

    @staticmethod
    def _directive(room, command, participant, now):
        target_json, playback_json = (
            participant["target_json"], participant["playback_json"])
        if target_json is None or playback_json is None:
            return WatchPartyDirective(
                commandRevision=command.revision, action="none", positionMs=0,
                skewMs=0, toleranceMs=room["tolerance_ms"])
        target = WatchPartyTarget.model_validate_json(target_json)
        playback = WatchPartyPlayback.model_validate_json(playback_json)
        desired = command.positionMs
        if command.action == "play":
            desired += max(0, now * 1000 - command.issuedAtMs)
            desired += playback.measuredRoundTripMs // 2
        desired = min(desired, 8_640_000_000)
        skew = desired - playback.positionMs
        if participant["account_id"] == room["leader_account_id"]:
            action = "none"
        elif command.action == "pause":
            action = "pause" if playback.state != "paused" and target.canPause else "none"
        elif playback.state != "playing":
            action = "play" if target.canSeek else "unsupported"
        elif abs(skew) > room["tolerance_ms"]:
            action = "seek_and_play" if target.canSeek else "unsupported"
        else:
            action = "none"
        return WatchPartyDirective(
            commandRevision=command.revision, action=action,
            positionMs=desired, skewMs=skew,
            toleranceMs=room["tolerance_ms"])

    def create(self, actor, body):
        if type(body) is not CreateWatchPartyRequest:
            raise ApiError("invalid_request")
        now = int(self.settings.clock())
        if not now < body.expiresAt <= now + MAX_TTL:
            raise ApiError("invalid_request")
        encoded = body.model_dump_json()
        request_hash = hashlib.sha256(encoded.encode()).hexdigest()
        with self.db.transaction() as connection:
            self._actor(connection, actor)
            existing = connection.execute(
                "SELECT * FROM watch_party_rooms WHERE create_request_id=?",
                (body.requestId,)).fetchone()
            if existing is not None:
                room = self._room(existing)
                if (room["create_actor_id"] != actor.id
                        or room["create_hash"] != request_hash):
                    raise ApiError("idempotency_conflict", 409)
                member = self._member(connection, actor, room)
                return {"snapshot": self._snapshot(connection, room, actor),
                        "inviteCode": self._invite(room["id"])}
            connection.execute(
                "DELETE FROM watch_party_rooms WHERE state='closed' OR expires_at<=?",
                (now,))
            if connection.execute(
                    "SELECT COUNT(*) FROM watch_party_rooms").fetchone()[0] >= MAX_ROOMS:
                raise ApiError("watch_party_limit_reached", 409)
            authority = self.media_playback._catalog(actor, body)
            room_id = uuid.uuid4().hex
            invite = self._invite(room_id)
            command = WatchPartyCommand(
                revision=1, action="pause", positionMs=0,
                issuedAtMs=int(self.settings.clock() * 1000))
            room = {
                "id": room_id, "create_request_id": body.requestId,
                "create_actor_id": actor.id, "create_hash": request_hash,
                "leader_account_id": actor.id,
                "leader_family_id": actor.family_id, "revision": 1,
                "authority_json": authority.model_dump_json(),
                "invite_digest": self._digest(invite),
                "tolerance_ms": body.toleranceMs, "command_revision": 1,
                "command_json": command.model_dump_json(), "state": "active",
                "expires_at": body.expiresAt, "created_at": now,
                "updated_at": now,
            }
            room["envelope_tag"] = self._room_tag(room)
            connection.execute(
                "INSERT INTO watch_party_rooms VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                tuple(room.values()))
            participant = {
                "room_id": room_id, "account_id": actor.id,
                "family_id": actor.family_id, "revision": 1,
                "request_id": body.requestId, "request_hash": request_hash,
                "target_json": None, "playback_json": None,
                "joined_at": now, "last_seen_at": now,
            }
            participant["envelope_tag"] = self._participant_tag(participant)
            connection.execute(
                "INSERT INTO watch_party_participants VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                tuple(participant.values()))
            return {"snapshot": self._snapshot(connection, room, actor),
                    "inviteCode": invite}

    def join(self, actor, room_id, body):
        if type(body) is not JoinWatchPartyRequest:
            raise ApiError("invalid_request")
        request_hash = hashlib.sha256(body.model_dump_json().encode()).hexdigest()
        now = int(self.settings.clock())
        with self.db.transaction() as connection:
            self._actor(connection, actor)
            room = self._active_room(connection, room_id, body.expectedRoomRevision)
            self._current(actor, room)
            if not hmac.compare_digest(
                    room["invite_digest"], self._digest(body.inviteCode)):
                raise ApiError("not_found", 404)
            existing = connection.execute(
                "SELECT * FROM watch_party_participants WHERE room_id=? "
                "AND account_id=?", (room_id, actor.id)).fetchone()
            if existing is None:
                count = connection.execute(
                    "SELECT COUNT(*) FROM watch_party_participants WHERE room_id=?",
                    (room_id,)).fetchone()[0]
                if count >= MAX_PARTICIPANTS:
                    raise ApiError("watch_party_limit_reached", 409)
                participant = {
                    "room_id": room_id, "account_id": actor.id,
                    "family_id": actor.family_id, "revision": 1,
                    "request_id": body.requestId, "request_hash": request_hash,
                    "target_json": None, "playback_json": None,
                    "joined_at": now, "last_seen_at": now,
                }
                participant["envelope_tag"] = self._participant_tag(participant)
                connection.execute(
                    "INSERT INTO watch_party_participants VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                    tuple(participant.values()))
            else:
                participant = self._participant(existing)
                if (participant["request_id"] == body.requestId
                        and participant["request_hash"] != request_hash):
                    raise ApiError("idempotency_conflict", 409)
                if (participant["request_id"] == body.requestId
                        and participant["request_hash"] == request_hash
                        and participant["family_id"] == actor.family_id):
                    return {"snapshot": self._snapshot(
                        connection, room, actor)}
                participant = self._update_participant(
                    connection, participant, family_id=actor.family_id,
                    revision=participant["revision"] + 1,
                    request_id=body.requestId, request_hash=request_hash,
                    target_json=None, playback_json=None, last_seen_at=now)
            room_changes = {
                "revision": room["revision"] + 1,
                "updated_at": now,
            }
            if room["leader_account_id"] == actor.id:
                room_changes["leader_family_id"] = actor.family_id
            room = self._update_room(connection, room, **room_changes)
            return {"snapshot": self._snapshot(connection, room, actor)}

    def snapshot(self, actor, room_id):
        with self.db.connection() as connection:
            self._actor(connection, actor)
            room = self._active_room(connection, room_id)
            self._current(actor, room)
            self._member(connection, actor, room)
            return {"snapshot": self._snapshot(
                connection, room, actor, directive=True)}

    def report(self, actor, room_id, body):
        if type(body) is not ReportWatchPartyRequest:
            raise ApiError("invalid_request")
        now = int(self.settings.clock())
        with self.db.transaction() as connection:
            self._actor(connection, actor)
            room = self._active_room(connection, room_id, body.expectedRoomRevision)
            self._current(actor, room)
            participant = self._member(connection, actor, room)
            if participant["revision"] != body.expectedParticipantRevision:
                raise ApiError("watch_party_authority_changed", 409)
            participant = self._update_participant(
                connection, participant, revision=participant["revision"] + 1,
                request_id=body.requestId,
                request_hash=hashlib.sha256(body.model_dump_json().encode()).hexdigest(),
                target_json=body.target.model_dump_json(),
                playback_json=body.playback.model_dump_json(), last_seen_at=now)
            return {"snapshot": self._snapshot(
                connection, room, actor, directive=True)}

    def command(self, actor, room_id, body):
        if type(body) is not CommandWatchPartyRequest:
            raise ApiError("invalid_request")
        now = int(self.settings.clock())
        with self.db.transaction() as connection:
            self._actor(connection, actor)
            room = self._active_room(connection, room_id, body.expectedRoomRevision)
            self._current(actor, room)
            leader = self._member(connection, actor, room)
            if (room["leader_account_id"] != actor.id
                    or room["leader_family_id"] != actor.family_id
                    or leader["revision"] != body.expectedLeaderRevision):
                raise ApiError("forbidden", 403)
            action = "pause" if body.action == "pause" else "play"
            command = WatchPartyCommand(
                revision=room["command_revision"] + 1, action=action,
                positionMs=body.positionMs,
                issuedAtMs=int(self.settings.clock() * 1000))
            room = self._update_room(
                connection, room, revision=room["revision"] + 1,
                command_revision=command.revision,
                command_json=command.model_dump_json(), updated_at=now)
            return {"snapshot": self._snapshot(connection, room, actor)}

    def transfer(self, actor, room_id, body):
        if type(body) is not TransferWatchPartyLeaderRequest:
            raise ApiError("invalid_request")
        now = int(self.settings.clock())
        with self.db.transaction() as connection:
            self._actor(connection, actor)
            room = self._active_room(connection, room_id, body.expectedRoomRevision)
            self._current(actor, room)
            leader = self._member(connection, actor, room)
            if (room["leader_account_id"] != actor.id
                    or leader["revision"] != body.expectedLeaderRevision):
                raise ApiError("forbidden", 403)
            raw = connection.execute(
                "SELECT * FROM watch_party_participants WHERE room_id=? "
                "AND account_id=?", (room_id, body.nextLeaderAccountId)
            ).fetchone()
            if raw is None:
                raise ApiError("not_found", 404)
            selected = self._participant(raw)
            if (selected["revision"] != body.expectedNextLeaderRevision
                    or now - selected["last_seen_at"] > CONNECTED_SECONDS):
                raise ApiError("watch_party_authority_changed", 409)
            room = self._update_room(
                connection, room,
                leader_account_id=selected["account_id"],
                leader_family_id=selected["family_id"],
                revision=room["revision"] + 1, updated_at=now)
            return {"snapshot": self._snapshot(connection, room, actor)}

    def leave(self, actor, room_id, body):
        if type(body) is not LeaveWatchPartyRequest:
            raise ApiError("invalid_request")
        now = int(self.settings.clock())
        with self.db.transaction() as connection:
            self._actor(connection, actor)
            room = self._active_room(connection, room_id, body.expectedRoomRevision)
            self._current(actor, room)
            participant = self._member(connection, actor, room)
            if participant["revision"] != body.expectedParticipantRevision:
                raise ApiError("watch_party_authority_changed", 409)
            connection.execute(
                "DELETE FROM watch_party_participants WHERE room_id=? "
                "AND account_id=?", (room_id, actor.id))
            remaining = [self._participant(row) for row in connection.execute(
                "SELECT * FROM watch_party_participants WHERE room_id=? "
                "ORDER BY last_seen_at DESC,joined_at,account_id",
                (room_id,)).fetchall()]
            connected = [row for row in remaining
                         if now - row["last_seen_at"] <= CONNECTED_SECONDS]
            leader_leaving = room["leader_account_id"] == actor.id
            if not remaining or leader_leaving and not connected:
                room = self._update_room(
                    connection, room, state="closed",
                    revision=room["revision"] + 1, updated_at=now)
                return {"schemaVersion": 1, "state": "closed",
                        "roomRevision": room["revision"],
                        "nextLeaderAccountId": None}
            changes = {"revision": room["revision"] + 1, "updated_at": now}
            if leader_leaving:
                changes.update(
                    leader_account_id=connected[0]["account_id"],
                    leader_family_id=connected[0]["family_id"])
            room = self._update_room(connection, room, **changes)
            return {"schemaVersion": 1, "state": "active",
                    "roomRevision": room["revision"],
                    "nextLeaderAccountId": room["leader_account_id"]}
