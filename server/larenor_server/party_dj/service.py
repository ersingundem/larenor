"""Durable session-scoped party DJ state and safe playback effects."""

import hashlib
import hmac
import json
import math
import uuid

from pydantic import ValidationError

from ..errors import ApiError, StartupError
from ..plugins.music_playback_models import (
    MusicPlaybackCommandRequest,
    SearchMusicCatalogRequest,
)
from .models import (
    CreatePartyDjRoomRequest,
    DecidePartyDjProposalRequest,
    DismissPartyDjProposalRequest,
    DismissPartyDjSkipRequest,
    HeartbeatPartyDjRequest,
    JoinPartyDjRoomRequest,
    LeavePartyDjRequest,
    LeavePartyDjResponse,
    PARTY_DJ_REQUIRED_CAPABILITIES,
    PartyDjAuthority,
    PartyDjParticipant,
    PartyDjProposal,
    PartyDjRoom,
    ProposePartyDjTrackRequest,
    VotePartyDjProposalRequest,
    VotePartyDjSkipRequest,
)

MAX_ROOMS = 32
MAX_PARTICIPANTS = 16
MAX_PROPOSALS = 64
MAX_REQUESTS = 256
# Keep one slot per participant for explicit uncertain-effect recovery and one
# more for leave/room closure. The signed journal still fails closed at 256.
RECOVERY_REQUEST_LIMIT = MAX_REQUESTS - MAX_PARTICIPANTS
REGULAR_REQUEST_LIMIT = RECOVERY_REQUEST_LIMIT - MAX_PARTICIPANTS
MAX_TTL = 12 * 60 * 60
CONNECTED_SECONDS = 45
EFFECT_PENDING_SECONDS = 10

_ROOM_FIELDS = (
    "id", "create_request_id", "create_actor_id", "create_family_id",
    "create_hash", "host_account_id", "host_family_id", "revision",
    "authority_json", "invite_digest", "proposal_limit",
    "skip_quorum_percent", "skip_generation", "skip_state",
    "skip_request_id", "skip_request_hash", "state", "expires_at",
    "created_at", "updated_at",
)
_PARTICIPANT_FIELDS = (
    "room_id", "account_id", "family_id", "revision", "request_id",
    "request_hash", "joined_at", "last_seen_at",
)
_PROPOSAL_FIELDS = (
    "id", "room_id", "account_id", "family_id", "revision", "media_uri",
    "name", "provider_setup_id", "provider_revision", "provider_domain",
    "provider_instance_id", "manager_revision", "status",
    "decision_request_id", "decision_request_hash", "created_at", "updated_at",
)
_PROPOSAL_VOTE_FIELDS = (
    "proposal_id", "account_id", "family_id", "created_at")
_SKIP_VOTE_FIELDS = (
    "room_id", "generation", "account_id", "family_id", "created_at")
_REQUEST_FIELDS = (
    "room_id", "request_id", "actor_id", "family_id", "request_hash",
    "result_json", "created_at")


class PartyDjService:
    def __init__(self, db, auth, settings, key, context, music_playback):
        self.db, self.auth, self.settings = db, auth, settings
        self._key, self.context = key, context
        self.music_playback = music_playback

    @staticmethod
    def _json(value):
        if hasattr(value, "model_dump"):
            value = value.model_dump(mode="json")
        return json.dumps(value, sort_keys=True, separators=(",", ":"),
                          allow_nan=False, default=lambda item: item.model_dump(
                              mode="json"))

    @classmethod
    def _hash(cls, value):
        return hashlib.sha256(cls._json(value).encode()).hexdigest()

    def _tag(self, kind, values):
        return hmac.new(
            self._key,
            b"larenor-party-dj-v1\0" + kind.encode() + b"\0"
            + self._json(values).encode(), hashlib.sha256).hexdigest()

    def _room_tag(self, row):
        return self._tag("room", {field: row[field] for field in _ROOM_FIELDS})

    def _participant_tag(self, row):
        return self._tag(
            "participant", {field: row[field] for field in _PARTICIPANT_FIELDS})

    def _proposal_tag(self, row):
        return self._tag(
            "proposal", {field: row[field] for field in _PROPOSAL_FIELDS})

    def _proposal_vote_tag(self, row):
        return self._tag("proposal-vote", {
            field: row[field] for field in _PROPOSAL_VOTE_FIELDS})

    def _skip_vote_tag(self, row):
        return self._tag("skip-vote", {
            field: row[field] for field in _SKIP_VOTE_FIELDS})

    def _request_tag(self, row):
        return self._tag("request", {
            field: row[field] for field in _REQUEST_FIELDS})

    def _room_row(self, row):
        if row is None or not hmac.compare_digest(
                row["envelope_tag"], self._room_tag(row)):
            raise StartupError("party_dj_storage_invalid")
        try:
            PartyDjAuthority.model_validate_json(row["authority_json"])
        except (ValidationError, ValueError, TypeError):
            raise StartupError("party_dj_storage_invalid") from None
        return row

    def _participant_row(self, row):
        if row is None or not hmac.compare_digest(
                row["envelope_tag"], self._participant_tag(row)):
            raise StartupError("party_dj_storage_invalid")
        return row

    def _proposal_row(self, row):
        if row is None or not hmac.compare_digest(
                row["envelope_tag"], self._proposal_tag(row)):
            raise StartupError("party_dj_storage_invalid")
        try:
            PartyDjProposal(
                proposalId=row["id"], revision=row["revision"],
                accountId=row["account_id"], mediaUri=row["media_uri"],
                name=row["name"],
                providerSetupId=row["provider_setup_id"],
                providerRevision=row["provider_revision"],
                providerDomain=row["provider_domain"],
                providerInstanceId=row["provider_instance_id"],
                managerRevision=row["manager_revision"],
                status=row["status"], upVotes=0,
                submittedByCurrentUser=False, votedByCurrentUser=False,
                createdAt=row["created_at"])
        except (ValidationError, ValueError, TypeError):
            raise StartupError("party_dj_storage_invalid") from None
        return row

    def _proposal_vote_row(self, row):
        if row is None or not hmac.compare_digest(
                row["envelope_tag"], self._proposal_vote_tag(row)):
            raise StartupError("party_dj_storage_invalid")
        return row

    def _skip_vote_row(self, row):
        if row is None or not hmac.compare_digest(
                row["envelope_tag"], self._skip_vote_tag(row)):
            raise StartupError("party_dj_storage_invalid")
        return row

    def _request_row(self, row):
        if row is None or not hmac.compare_digest(
                row["envelope_tag"], self._request_tag(row)):
            raise StartupError("party_dj_storage_invalid")
        return row

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                rooms = connection.execute(
                    "SELECT * FROM party_dj_rooms LIMIT ?", (MAX_ROOMS + 1,)
                ).fetchall()
                if len(rooms) > MAX_ROOMS:
                    raise ValueError()
                for raw in rooms:
                    room = self._room_row(raw)
                    participants = connection.execute(
                        "SELECT * FROM party_dj_participants WHERE room_id=?",
                        (room["id"],)).fetchall()
                    proposals = connection.execute(
                        "SELECT * FROM party_dj_proposals WHERE room_id=?",
                        (room["id"],)).fetchall()
                    requests = connection.execute(
                        "SELECT COUNT(*) FROM party_dj_requests WHERE room_id=?",
                        (room["id"],)).fetchone()[0]
                    if (len(participants) > MAX_PARTICIPANTS
                            or room["state"] == "active"
                            and not participants
                            or room["state"] == "closed"
                            and participants
                            or len(proposals) > MAX_PROPOSALS
                            or requests > MAX_REQUESTS):
                        raise ValueError()
                    members = {row["account_id"] for row in participants}
                    if (room["state"] == "active"
                            and room["host_account_id"] not in members):
                        raise ValueError()
                    for row in participants:
                        self._participant_row(row)
                    for row in proposals:
                        self._proposal_row(row)
                proposal_votes = connection.execute(
                    "SELECT * FROM party_dj_proposal_votes").fetchall()
                skip_votes = connection.execute(
                    "SELECT * FROM party_dj_skip_votes").fetchall()
                requests = connection.execute(
                    "SELECT * FROM party_dj_requests").fetchall()
                if (len(proposal_votes)
                        > MAX_ROOMS * MAX_PROPOSALS * MAX_PARTICIPANTS
                        or len(skip_votes) > MAX_ROOMS * MAX_PARTICIPANTS
                        or len(requests) > MAX_ROOMS * MAX_REQUESTS):
                    raise ValueError()
                for row in proposal_votes:
                    self._proposal_vote_row(row)
                for row in skip_votes:
                    self._skip_vote_row(row)
                for row in requests:
                    self._request_row(row)
        except (StartupError, ValidationError, ValueError, TypeError):
            raise StartupError("party_dj_storage_invalid") from None

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
            self._key, b"larenor-party-dj-invite-v1\0" + room_id.encode(),
            hashlib.sha256).hexdigest()[:32]

    @staticmethod
    def _digest(value):
        return hashlib.sha256(value.encode()).hexdigest()

    def _active_room(self, connection, room_id, expected=None):
        raw = connection.execute(
            "SELECT * FROM party_dj_rooms WHERE id=?", (room_id,)).fetchone()
        if raw is None:
            raise ApiError("not_found", 404)
        row = self._room_row(raw)
        if (row["state"] != "active"
                or int(self.settings.clock()) >= row["expires_at"]
                or expected is not None and row["revision"] != expected):
            raise ApiError("party_dj_authority_changed", 409)
        return row

    def _member(self, connection, actor, room):
        raw = connection.execute(
            "SELECT * FROM party_dj_participants WHERE room_id=? "
            "AND account_id=?", (room["id"], actor.id)).fetchone()
        if raw is None:
            raise ApiError("not_found", 404)
        row = self._participant_row(raw)
        if row["family_id"] != actor.family_id:
            raise ApiError("party_dj_session_changed", 409)
        return row

    def _replay(self, connection, actor, room_id, body):
        row = connection.execute(
            "SELECT * FROM party_dj_requests WHERE room_id=? AND request_id=?",
            (room_id, body.requestId)).fetchone()
        if row is None:
            return None
        row = self._request_row(row)
        if (row["actor_id"] != actor.id or row["family_id"] != actor.family_id
                or row["request_hash"] != self._hash(body)):
            raise ApiError("party_dj_request_conflict", 409)
        try:
            value = json.loads(row["result_json"])
            if type(value) is not dict:
                raise ValueError()
            return value
        except (ValueError, TypeError):
            raise StartupError("party_dj_storage_invalid") from None

    def _record(self, connection, actor, room_id, body, result):
        count = connection.execute(
            "SELECT COUNT(*) FROM party_dj_requests WHERE room_id=?",
            (room_id,)).fetchone()[0]
        if count >= MAX_REQUESTS:
            raise ApiError("party_dj_request_limit_reached", 409)
        row = dict(
            room_id=room_id, request_id=body.requestId, actor_id=actor.id,
            family_id=actor.family_id, request_hash=self._hash(body),
            result_json=self._json(result), created_at=int(self.settings.clock()))
        row["envelope_tag"] = self._request_tag(row)
        connection.execute(
            "INSERT INTO party_dj_requests VALUES(?,?,?,?,?,?,?,?)",
            tuple(row[field] for field in _REQUEST_FIELDS)
            + (row["envelope_tag"],))
        return result

    @staticmethod
    def _request_capacity(connection, room_id, *, recovery=False):
        limit = RECOVERY_REQUEST_LIMIT if recovery else REGULAR_REQUEST_LIMIT
        if connection.execute(
                "SELECT COUNT(*) FROM party_dj_requests WHERE room_id=?",
                (room_id,)).fetchone()[0] >= limit:
            raise ApiError("party_dj_request_limit_reached", 409)

    def _update_room(self, connection, row, **changes):
        value = dict(row)
        value.update(changes)
        value["envelope_tag"] = self._room_tag(value)
        connection.execute(
            "UPDATE party_dj_rooms SET host_account_id=?,host_family_id=?,"
            "revision=?,authority_json=?,skip_generation=?,skip_state=?,"
            "skip_request_id=?,skip_request_hash=?,state=?,updated_at=?,"
            "envelope_tag=? WHERE id=?",
            (value["host_account_id"], value["host_family_id"],
             value["revision"], value["authority_json"],
             value["skip_generation"], value["skip_state"],
             value["skip_request_id"], value["skip_request_hash"],
             value["state"], value["updated_at"], value["envelope_tag"],
             value["id"]))
        return value

    def _update_participant(self, connection, row, **changes):
        value = dict(row)
        value.update(changes)
        value["envelope_tag"] = self._participant_tag(value)
        connection.execute(
            "UPDATE party_dj_participants SET family_id=?,revision=?,"
            "request_id=?,request_hash=?,last_seen_at=?,envelope_tag=? "
            "WHERE room_id=? AND account_id=?",
            (value["family_id"], value["revision"], value["request_id"],
             value["request_hash"], value["last_seen_at"],
             value["envelope_tag"], value["room_id"], value["account_id"]))
        return value

    def _update_proposal(self, connection, row, **changes):
        value = dict(row)
        value.update(changes)
        value["envelope_tag"] = self._proposal_tag(value)
        connection.execute(
            "UPDATE party_dj_proposals SET revision=?,status=?,"
            "decision_request_id=?,decision_request_hash=?,updated_at=?,"
            "envelope_tag=? WHERE id=?",
            (value["revision"], value["status"],
             value["decision_request_id"], value["decision_request_hash"],
             value["updated_at"], value["envelope_tag"], value["id"]))
        return value

    def _insert_proposal_vote(self, connection, proposal_id, actor, now):
        row = dict(proposal_id=proposal_id, account_id=actor.id,
                   family_id=actor.family_id, created_at=now)
        row["envelope_tag"] = self._proposal_vote_tag(row)
        connection.execute(
            "INSERT INTO party_dj_proposal_votes VALUES(?,?,?,?,?)",
            tuple(row[field] for field in _PROPOSAL_VOTE_FIELDS)
            + (row["envelope_tag"],))

    def _insert_skip_vote(self, connection, room, actor, now):
        row = dict(room_id=room["id"], generation=room["skip_generation"],
                   account_id=actor.id, family_id=actor.family_id,
                   created_at=now)
        row["envelope_tag"] = self._skip_vote_tag(row)
        connection.execute(
            "INSERT INTO party_dj_skip_votes VALUES(?,?,?,?,?,?)",
            tuple(row[field] for field in _SKIP_VOTE_FIELDS)
            + (row["envelope_tag"],))

    @staticmethod
    def _required_skip(connected, percent):
        return max(1, min(MAX_PARTICIPANTS, math.ceil(connected * percent / 100)))

    def _snapshot(self, connection, room, actor):
        authority = PartyDjAuthority.model_validate_json(room["authority_json"])
        now = int(self.settings.clock())
        rows = [self._participant_row(row) for row in connection.execute(
            "SELECT * FROM party_dj_participants WHERE room_id=? "
            "ORDER BY joined_at,account_id", (room["id"],)).fetchall()]
        current = next((row for row in rows if row["account_id"] == actor.id
                        and row["family_id"] == actor.family_id), None)
        if current is None:
            raise ApiError("not_found", 404)
        participants = [PartyDjParticipant(
            accountId=row["account_id"], revision=row["revision"],
            isHost=row["account_id"] == room["host_account_id"],
            connected=now - row["last_seen_at"] <= CONNECTED_SECONDS,
            lastSeenAt=row["last_seen_at"],
            ownedByCurrentSession=(row["account_id"] == actor.id
                                   and row["family_id"] == actor.family_id))
            for row in rows]
        proposal_rows = [self._proposal_row(row) for row in connection.execute(
            "SELECT * FROM party_dj_proposals WHERE room_id=? "
            "ORDER BY created_at,id", (room["id"],)).fetchall()]
        proposal_ids = [row["id"] for row in proposal_rows]
        votes = {}
        voted = set()
        if proposal_ids:
            placeholders = ",".join("?" for _ in proposal_ids)
            for vote in connection.execute(
                    f"SELECT v.* FROM "
                    f"party_dj_proposal_votes v JOIN party_dj_participants p "
                    f"ON p.room_id=? AND p.account_id=v.account_id "
                    f"AND p.family_id=v.family_id WHERE "
                    f"v.proposal_id IN ({placeholders}) AND p.last_seen_at>=?",
                    (room["id"], *proposal_ids, now - CONNECTED_SECONDS)):
                vote = self._proposal_vote_row(vote)
                votes[vote["proposal_id"]] = votes.get(vote["proposal_id"], 0) + 1
                if vote["account_id"] == actor.id:
                    voted.add(vote["proposal_id"])
        proposals = [PartyDjProposal(
            proposalId=row["id"], revision=row["revision"],
            accountId=row["account_id"], mediaUri=row["media_uri"],
            name=row["name"], providerSetupId=row["provider_setup_id"],
            providerRevision=row["provider_revision"],
            providerDomain=row["provider_domain"],
            providerInstanceId=row["provider_instance_id"],
            managerRevision=row["manager_revision"],
            status=row["status"], upVotes=votes.get(row["id"], 0),
            submittedByCurrentUser=row["account_id"] == actor.id,
            votedByCurrentUser=row["id"] in voted,
            createdAt=row["created_at"]) for row in proposal_rows]
        connected = sum(item.connected for item in participants)
        skip_vote_rows = connection.execute(
            "SELECT v.* FROM party_dj_skip_votes v "
            "JOIN party_dj_participants p ON p.room_id=v.room_id "
            "AND p.account_id=v.account_id AND p.family_id=v.family_id "
            "WHERE v.room_id=? AND v.generation=? AND p.last_seen_at>=?",
            (room["id"], room["skip_generation"], now - CONNECTED_SECONDS)
        ).fetchall()
        for vote in skip_vote_rows:
            self._skip_vote_row(vote)
        skip_votes = len(skip_vote_rows)
        return {"room": PartyDjRoom(
            authority=authority, revision=room["revision"],
            state=room["state"], hostAccountId=room["host_account_id"],
            expiresAt=room["expires_at"],
            proposalLimitPerUser=room["proposal_limit"],
            skipQuorumPercent=room["skip_quorum_percent"],
            skipVotes=skip_votes,
            skipVotesRequired=self._required_skip(
                connected, room["skip_quorum_percent"]),
            skipNeedsAttention=room["skip_state"] == "needs_attention",
            participants=participants, proposals=proposals,
            currentParticipantRevision=current["revision"])}

    def _current_music(self, actor, request):
        playback = self.music_playback.get(actor, request.installationId)["playback"]
        manager = self.music_playback.manager(actor, request.installationId)["manager"]
        if (playback["installationRevision"]
                != request.expectedInstallationRevision
                or playback["coreRevision"] != request.expectedCoreRevision
                or playback["revision"] != request.expectedPlayerRevision
                or manager["revision"] != request.expectedManagerRevision
                or manager["installationRevision"]
                != request.expectedInstallationRevision
                or manager["coreRevision"] != request.expectedCoreRevision):
            raise ApiError("party_dj_authority_changed", 409)
        target = next((item for item in playback["players"]
                       if item["playerId"] == request.targetId), None)
        if (target is None or not target["available"] or not target["enabled"]
                or target["provider"] != request.expectedProvider
                or target["targetKind"] != request.expectedTargetKind
                or target["queueId"] != request.expectedQueueId
                or target["groupMembers"] != request.expectedGroupMembers):
            raise ApiError("party_dj_target_changed", 409)
        if not PARTY_DJ_REQUIRED_CAPABILITIES <= set(target["capabilities"]):
            raise ApiError("party_dj_target_capability_unavailable", 409)
        return playback, manager

    def _latest_music_authority(self, actor, authority):
        """Rebind to an authenticated readback without issuing an effect."""
        playback = self.music_playback.get(
            actor, authority.installationId)["playback"]
        manager = self.music_playback.manager(
            actor, authority.installationId)["manager"]
        if (playback["installationRevision"] != authority.installationRevision
                or playback["coreRevision"] != authority.coreRevision
                or manager["installationRevision"]
                != authority.installationRevision
                or manager["coreRevision"] != authority.coreRevision
                or playback["revision"] != manager["revision"]):
            raise ApiError("party_dj_authority_changed", 409)
        target = next((item for item in playback["players"]
                       if item["playerId"] == authority.targetId), None)
        if (target is None or not target["available"] or not target["enabled"]
                or target["provider"] != authority.provider
                or target["targetKind"] != authority.targetKind
                or target["queueId"] != authority.queueId
                or target["groupMembers"] != authority.groupMembers):
            raise ApiError("party_dj_target_changed", 409)
        if not PARTY_DJ_REQUIRED_CAPABILITIES <= set(target["capabilities"]):
            raise ApiError("party_dj_target_capability_unavailable", 409)
        return authority.model_copy(update={
            "managerRevision": manager["revision"],
            "playerRevision": playback["revision"],
        })

    def create(self, actor, body):
        if type(body) is not CreatePartyDjRoomRequest:
            raise ApiError("invalid_request")
        now = int(self.settings.clock())
        if not now < body.expiresAt <= now + MAX_TTL:
            raise ApiError("invalid_request")
        request_hash = self._hash(body)
        with self.db.connection() as connection:
            self._actor(connection, actor)
            existing = connection.execute(
                "SELECT * FROM party_dj_rooms WHERE create_request_id=?",
                (body.requestId,)).fetchone()
            if existing is not None:
                room = self._room_row(existing)
                if (room["create_actor_id"] != actor.id
                        or room["create_family_id"] != actor.family_id
                        or room["create_hash"] != request_hash):
                    raise ApiError("party_dj_request_conflict", 409)
                return {**self._snapshot(connection, room, actor),
                        "inviteCode": self._invite(room["id"])}
        self._current_music(actor, body)
        with self.db.transaction() as connection:
            self._actor(connection, actor)
            existing = connection.execute(
                "SELECT * FROM party_dj_rooms WHERE create_request_id=?",
                (body.requestId,)).fetchone()
            if existing is not None:
                room = self._room_row(existing)
                if (room["create_actor_id"] != actor.id
                        or room["create_family_id"] != actor.family_id
                        or room["create_hash"] != request_hash):
                    raise ApiError("party_dj_request_conflict", 409)
                return {**self._snapshot(connection, room, actor),
                        "inviteCode": self._invite(room["id"])}
            connection.execute(
                "DELETE FROM party_dj_rooms WHERE state='closed' OR expires_at<=?",
                (now,))
            if connection.execute(
                    "SELECT COUNT(*) FROM party_dj_rooms").fetchone()[0] >= MAX_ROOMS:
                raise ApiError("party_dj_room_limit_reached", 409)
            room_id = uuid.uuid4().hex
            authority = PartyDjAuthority(
                coreId=self.context.coreId, homeId=self.context.homeId,
                roomId=room_id, installationId=body.installationId,
                installationRevision=body.expectedInstallationRevision,
                coreRevision=body.expectedCoreRevision,
                managerRevision=body.expectedManagerRevision,
                playerRevision=body.expectedPlayerRevision,
                targetId=body.targetId, provider=body.expectedProvider,
                targetKind=body.expectedTargetKind,
                queueId=body.expectedQueueId,
                groupMembers=body.expectedGroupMembers)
            room = dict(
                id=room_id, create_request_id=body.requestId,
                create_actor_id=actor.id, create_family_id=actor.family_id,
                create_hash=request_hash, host_account_id=actor.id,
                host_family_id=actor.family_id, revision=1,
                authority_json=authority.model_dump_json(),
                invite_digest=self._digest(self._invite(room_id)),
                proposal_limit=body.proposalLimitPerUser,
                skip_quorum_percent=body.skipQuorumPercent,
                skip_generation=1, skip_state="open", skip_request_id=None,
                skip_request_hash=None, state="active", expires_at=body.expiresAt,
                created_at=now, updated_at=now)
            room["envelope_tag"] = self._room_tag(room)
            connection.execute(
                "INSERT INTO party_dj_rooms VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,"
                "?,?,?,?,?,?,?,?)", tuple(room[field] for field in _ROOM_FIELDS)
                + (room["envelope_tag"],))
            participant = dict(
                room_id=room_id, account_id=actor.id,
                family_id=actor.family_id, revision=1,
                request_id=None, request_hash=None,
                joined_at=now, last_seen_at=now)
            participant["envelope_tag"] = self._participant_tag(participant)
            connection.execute(
                "INSERT INTO party_dj_participants VALUES(?,?,?,?,?,?,?,?,?)",
                tuple(participant[field] for field in _PARTICIPANT_FIELDS)
                + (participant["envelope_tag"],))
            return {**self._snapshot(connection, room, actor),
                    "inviteCode": self._invite(room_id)}

    def join(self, actor, room_id, body):
        if type(body) is not JoinPartyDjRoomRequest:
            raise ApiError("invalid_request")
        now = int(self.settings.clock())
        with self.db.transaction() as connection:
            self._actor(connection, actor)
            replay = self._replay(connection, actor, room_id, body)
            if replay is not None:
                return replay
            self._request_capacity(connection, room_id)
            room = self._active_room(connection, room_id, body.expectedRoomRevision)
            if not hmac.compare_digest(
                    room["invite_digest"], self._digest(body.inviteCode)):
                raise ApiError("not_found", 404)
            raw = connection.execute(
                "SELECT * FROM party_dj_participants WHERE room_id=? "
                "AND account_id=?", (room_id, actor.id)).fetchone()
            if raw is None:
                if connection.execute(
                        "SELECT COUNT(*) FROM party_dj_participants WHERE room_id=?",
                        (room_id,)).fetchone()[0] >= MAX_PARTICIPANTS:
                    raise ApiError("party_dj_participant_limit_reached", 409)
                member = dict(
                    room_id=room_id, account_id=actor.id,
                    family_id=actor.family_id, revision=1,
                    request_id=None, request_hash=None,
                    joined_at=now, last_seen_at=now)
                member["envelope_tag"] = self._participant_tag(member)
                connection.execute(
                    "INSERT INTO party_dj_participants VALUES(?,?,?,?,?,?,?,?,?)",
                    tuple(member[field] for field in _PARTICIPANT_FIELDS)
                    + (member["envelope_tag"],))
            else:
                member = self._participant_row(raw)
                if (member["family_id"] != actor.family_id
                        and now - member["last_seen_at"] <= CONNECTED_SECONDS):
                    raise ApiError("party_dj_session_changed", 409)
                changed_family = member["family_id"] != actor.family_id
                member = self._update_participant(
                    connection, member, family_id=actor.family_id,
                    revision=member["revision"] + 1, request_id=None,
                    request_hash=None, last_seen_at=now)
                if changed_family:
                    proposal_votes = connection.execute(
                        "SELECT v.* FROM party_dj_proposal_votes v "
                        "JOIN party_dj_proposals p ON p.id=v.proposal_id "
                        "WHERE p.room_id=? AND v.account_id=?",
                        (room_id, actor.id)).fetchall()
                    for raw_vote in proposal_votes:
                        vote = dict(self._proposal_vote_row(raw_vote))
                        vote["family_id"] = actor.family_id
                        vote["envelope_tag"] = self._proposal_vote_tag(vote)
                        connection.execute(
                            "UPDATE party_dj_proposal_votes SET family_id=?,"
                            "envelope_tag=? WHERE proposal_id=? AND account_id=?",
                            (vote["family_id"], vote["envelope_tag"],
                             vote["proposal_id"], vote["account_id"]))
                    skip_votes = connection.execute(
                        "SELECT * FROM party_dj_skip_votes WHERE room_id=? "
                        "AND account_id=?", (room_id, actor.id)).fetchall()
                    for raw_vote in skip_votes:
                        vote = dict(self._skip_vote_row(raw_vote))
                        vote["family_id"] = actor.family_id
                        vote["envelope_tag"] = self._skip_vote_tag(vote)
                        connection.execute(
                            "UPDATE party_dj_skip_votes SET family_id=?,"
                            "envelope_tag=? WHERE room_id=? AND generation=? "
                            "AND account_id=?", (vote["family_id"],
                             vote["envelope_tag"], vote["room_id"],
                             vote["generation"], vote["account_id"]))
            room_changes = dict(
                revision=room["revision"] + 1, updated_at=now)
            if (room["host_account_id"] == actor.id
                    and room["host_family_id"] != actor.family_id):
                room_changes["host_family_id"] = actor.family_id
            room = self._update_room(connection, room, **room_changes)
            result = self._snapshot(connection, room, actor)
            return self._record(connection, actor, room_id, body, result)

    def dismiss_proposal(self, actor, room_id, proposal_id, body):
        """Terminally dismiss an uncertain add without replaying playback."""
        if type(body) is not DismissPartyDjProposalRequest:
            raise ApiError("invalid_request")
        self._reconcile_effects(actor, room_id)
        room_authority = self._room_authority(actor, room_id)
        authority = self._latest_music_authority(actor, room_authority)
        now = int(self.settings.clock())
        with self.db.transaction() as connection:
            self._actor(connection, actor)
            replay = self._replay(connection, actor, room_id, body)
            if replay is not None:
                return replay
            room = self._active_room(
                connection, room_id, body.expectedRoomRevision)
            self._member(connection, actor, room)
            self._assert_room_authority(room, room_authority)
            self._assert_music_revision(connection, authority)
            if (room["host_account_id"] != actor.id
                    or room["host_family_id"] != actor.family_id):
                raise ApiError("forbidden", 403)
            proposal = self._proposal_row(connection.execute(
                "SELECT * FROM party_dj_proposals WHERE id=? AND room_id=?",
                (proposal_id, room_id)).fetchone())
            if (proposal["revision"] != body.expectedProposalRevision
                    or proposal["status"] != "needs_attention"):
                raise ApiError("party_dj_proposal_changed", 409)
            self._request_capacity(connection, room_id, recovery=True)
            self._update_proposal(
                connection, proposal, revision=proposal["revision"] + 1,
                status="rejected", updated_at=now)
            room = self._update_room(
                connection, room, revision=room["revision"] + 1,
                authority_json=authority.model_dump_json(), updated_at=now)
            result = self._snapshot(connection, room, actor)
            return self._record(connection, actor, room_id, body, result)

    def snapshot(self, actor, room_id):
        self._reconcile_effects(actor, room_id)
        with self.db.connection() as connection:
            self._actor(connection, actor)
            room = self._active_room(connection, room_id)
            self._member(connection, actor, room)
            return self._snapshot(connection, room, actor)

    def heartbeat(self, actor, room_id, body):
        if type(body) is not HeartbeatPartyDjRequest:
            raise ApiError("invalid_request")
        now = int(self.settings.clock())
        with self.db.transaction() as connection:
            self._actor(connection, actor)
            room = self._active_room(connection, room_id)
            member = self._member(connection, actor, room)
            request_hash = self._hash(body)
            if member["request_id"] == body.requestId:
                if member["request_hash"] != request_hash:
                    raise ApiError("party_dj_request_conflict", 409)
                return self._snapshot(connection, room, actor)
            if (room["revision"] != body.expectedRoomRevision
                    or member["revision"] != body.expectedParticipantRevision):
                raise ApiError("party_dj_participant_changed", 409)
            self._update_participant(
                connection, member, revision=member["revision"] + 1,
                request_id=body.requestId, request_hash=request_hash,
                last_seen_at=now)
            return self._snapshot(connection, room, actor)

    def propose(self, actor, room_id, body):
        if type(body) is not ProposePartyDjTrackRequest:
            raise ApiError("invalid_request")
        with self.db.connection() as connection:
            self._actor(connection, actor)
            replay = self._replay(connection, actor, room_id, body)
            if replay is not None:
                return replay
        room_authority = self._room_authority(actor, room_id)
        catalog_request = SearchMusicCatalogRequest(
            requestId=body.catalogRequestId,
            installationId=room_authority.installationId,
            expectedInstallationRevision=room_authority.installationRevision,
            expectedCoreRevision=room_authority.coreRevision,
            expectedManagerRevision=room_authority.managerRevision,
            providerSetupId=body.providerSetupId,
            expectedProviderRevision=body.expectedProviderRevision,
            providerDomain=body.providerDomain,
            providerInstanceId=body.providerInstanceId,
            query=body.catalogQuery,
            mediaTypes=["track"], limit=100, libraryOnly=False)
        catalog = self.music_playback.search(actor, catalog_request)["catalog"]
        verified_item = next((item for item in catalog["items"]
                              if item["uri"] == body.mediaUri
                              and item["name"] == body.name
                              and item["mediaType"] == "track"
                              and item["providerInstanceId"]
                              == body.providerInstanceId), None)
        if (catalog["requestId"] != body.catalogRequestId
                or catalog["managerRevision"] != room_authority.managerRevision
                or verified_item is None):
            raise ApiError("party_dj_authority_changed", 409)
        manager = self.music_playback.manager(
            actor, room_authority.installationId)["manager"]
        now = int(self.settings.clock())
        with self.db.transaction() as connection:
            self._actor(connection, actor)
            replay = self._replay(connection, actor, room_id, body)
            if replay is not None:
                return replay
            self._request_capacity(connection, room_id)
            room = self._active_room(connection, room_id, body.expectedRoomRevision)
            member = self._member(connection, actor, room)
            authority = PartyDjAuthority.model_validate_json(room["authority_json"])
            binding = next((item for item in manager["providers"]
                            if item["providerInstanceId"]
                            == body.providerInstanceId), None)
            if (manager["installationId"] != authority.installationId
                    or manager["installationRevision"] != authority.installationRevision
                    or manager["coreRevision"] != authority.coreRevision
                    or manager["revision"] != authority.managerRevision
                    or binding is None
                    or binding["setupId"] != body.providerSetupId
                    or binding["revision"] != body.expectedProviderRevision
                    or binding["providerDomain"] != body.providerDomain
                    or body.mediaUri.split("://", 1)[0]
                    not in {body.providerDomain, "library"}):
                raise ApiError("party_dj_authority_changed", 409)
            pending = connection.execute(
                "SELECT COUNT(*) FROM party_dj_proposals WHERE room_id=? "
                "AND account_id=? AND status IN "
                "('pending','approving','needs_attention')",
                (room_id, actor.id)).fetchone()[0]
            total = connection.execute(
                "SELECT COUNT(*) FROM party_dj_proposals WHERE room_id=?",
                (room_id,)).fetchone()[0]
            if pending >= room["proposal_limit"]:
                raise ApiError("party_dj_proposal_limit_reached", 409)
            if total >= MAX_PROPOSALS:
                raise ApiError("party_dj_room_proposal_limit_reached", 409)
            duplicate = connection.execute(
                "SELECT 1 FROM party_dj_proposals WHERE room_id=? "
                "AND account_id=? AND media_uri=? "
                "AND status IN ('pending','approving','needs_attention')",
                (room_id, actor.id, body.mediaUri)).fetchone()
            if duplicate is not None:
                raise ApiError("party_dj_proposal_conflict", 409)
            self._update_participant(
                connection, member, revision=member["revision"] + 1,
                request_id=None, request_hash=None, last_seen_at=now)
            proposal = dict(
                id=uuid.uuid4().hex, room_id=room_id, account_id=actor.id,
                family_id=actor.family_id, revision=1, media_uri=body.mediaUri,
                name=body.name, provider_setup_id=body.providerSetupId,
                provider_revision=body.expectedProviderRevision,
                provider_domain=body.providerDomain,
                provider_instance_id=body.providerInstanceId,
                manager_revision=authority.managerRevision,
                status="pending", decision_request_id=None,
                decision_request_hash=None, created_at=now, updated_at=now)
            proposal["envelope_tag"] = self._proposal_tag(proposal)
            connection.execute(
                "INSERT INTO party_dj_proposals VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                tuple(proposal[field] for field in _PROPOSAL_FIELDS)
                + (proposal["envelope_tag"],))
            self._insert_proposal_vote(connection, proposal["id"], actor, now)
            room = self._update_room(
                connection, room, revision=room["revision"] + 1,
                updated_at=now)
            result = self._snapshot(connection, room, actor)
            return self._record(connection, actor, room_id, body, result)

    def _room_authority(self, actor, room_id):
        with self.db.connection() as connection:
            self._actor(connection, actor)
            room = self._active_room(connection, room_id)
            self._member(connection, actor, room)
            return PartyDjAuthority.model_validate_json(room["authority_json"])

    def _recorded_command_receipt(self, command, *, actor_id=None):
        """Read the durable playback journal without invoking the worker."""
        with self.db.connection() as connection:
            row = connection.execute(
                "SELECT * FROM music_playback WHERE installation_id=?",
                (command.installationId,)).fetchone()
            if row is None:
                return None
            stored = self.music_playback._decode(row)
            recorded = next((item for item in stored.commands
                             if item.request.requestId == command.requestId), None)
            if recorded is None:
                return None
            if ((actor_id is not None and recorded.actorId != actor_id)
                    or recorded.request != command):
                return None
            return {
                "requestId": command.requestId,
                "targetId": command.targetId,
                "operation": command.operation,
                "state": recorded.state,
                "playerRevision": recorded.playerRevision,
                "code": ("authenticated_readback"
                         if recorded.state == "succeeded" else "effect_unknown"),
                "installAvailable": False,
            }

    def _effect_receipt(self, authority, request_id, operation,
                        media_uris=None):
        """Resolve a claimed effect from the durable music journal only."""
        with self.db.connection() as connection:
            row = connection.execute(
                "SELECT * FROM music_playback WHERE installation_id=?",
                (authority.installationId,)).fetchone()
            if row is None:
                raise StartupError("party_dj_storage_invalid")
            stored = self.music_playback._decode(row)
            recorded = next((item for item in stored.commands
                             if item.request.requestId == request_id), None)
            if recorded is None:
                return None
            request = recorded.request
            expected_media = media_uris or []
            if (request.installationId != authority.installationId
                    or request.expectedInstallationRevision
                    != authority.installationRevision
                    or request.expectedCoreRevision != authority.coreRevision
                    or request.expectedPlayerRevision != authority.playerRevision
                    or request.targetId != authority.targetId
                    or request.expectedProvider != authority.provider
                    or request.expectedTargetKind != authority.targetKind
                    or request.expectedQueueId != authority.queueId
                    or request.expectedGroupMembers != authority.groupMembers
                    or request.operation != operation
                    or request.mediaUris != expected_media):
                raise StartupError("party_dj_storage_invalid")
            return {
                "state": ("succeeded" if recorded.state == "succeeded"
                          else "pending"),
                "playerRevision": recorded.playerRevision,
            }

    def _assert_music_revision(self, connection, authority):
        row = connection.execute(
            "SELECT * FROM music_playback WHERE installation_id=?",
            (authority.installationId,)).fetchone()
        if (row is None or row["installation_revision"]
                != authority.installationRevision
                or row["core_revision"] != authority.coreRevision
                or row["revision"] != authority.playerRevision):
            raise ApiError("party_dj_authority_changed", 409)
        self.music_playback._decode(row)

    @staticmethod
    def _assert_room_authority(room, authority):
        if PartyDjAuthority.model_validate_json(
                room["authority_json"]) != authority:
            raise ApiError("party_dj_authority_changed", 409)

    def _rollback_proposal_claim(self, actor, room_id, proposal_id, body):
        now = int(self.settings.clock())
        with self.db.transaction() as connection:
            self._actor(connection, actor)
            room = self._active_room(connection, room_id)
            self._member(connection, actor, room)
            proposal = self._proposal_row(connection.execute(
                "SELECT * FROM party_dj_proposals WHERE id=? AND room_id=?",
                (proposal_id, room_id)).fetchone())
            if (proposal["status"] != "approving"
                    or proposal["decision_request_id"] != body.requestId
                    or proposal["decision_request_hash"] != self._hash(body)):
                raise ApiError("party_dj_proposal_changed", 409)
            self._update_proposal(
                connection, proposal, revision=proposal["revision"] + 1,
                status="pending", decision_request_id=None,
                decision_request_hash=None, updated_at=now)
            self._update_room(
                connection, room, revision=room["revision"] + 1,
                updated_at=now)

    def _rollback_skip_claim(self, actor, room_id, body):
        now = int(self.settings.clock())
        with self.db.transaction() as connection:
            self._actor(connection, actor)
            room = self._active_room(connection, room_id)
            self._member(connection, actor, room)
            if (room["skip_state"] != "executing"
                    or room["skip_request_id"] != body.requestId
                    or room["skip_request_hash"] != self._hash(body)):
                raise ApiError("party_dj_authority_changed", 409)
            self._update_room(
                connection, room, revision=room["revision"] + 1,
                skip_state="open", skip_request_id=None,
                skip_request_hash=None, updated_at=now)

    def _reconcile_effects(self, actor, room_id):
        """Settle durable claims from the music journal without replay."""
        now = int(self.settings.clock())
        with self.db.connection() as connection:
            self._actor(connection, actor)
            room = self._active_room(connection, room_id)
            self._member(connection, actor, room)
            authority = PartyDjAuthority.model_validate_json(
                room["authority_json"])
            proposals = [self._proposal_row(row) for row in connection.execute(
                "SELECT * FROM party_dj_proposals WHERE room_id=? "
                "AND status IN ('approving','needs_attention')",
                (room_id,)).fetchall()]
            skip_claim = (dict(room) if room["skip_state"] in {
                "executing", "needs_attention"} and room["skip_request_id"]
                          is not None else None)

        proposal_outcomes = []
        requires_latest = False
        for proposal in proposals:
            receipt = self._effect_receipt(
                authority, proposal["decision_request_id"], "queue_add",
                [proposal["media_uri"]])
            if receipt is None:
                outcome = ("no_journal" if proposal["status"]
                           == "needs_attention" or now - proposal["updated_at"]
                           >= EFFECT_PENDING_SECONDS else "in_progress")
            elif receipt["state"] == "succeeded":
                outcome = "succeeded"
                requires_latest = True
            elif (proposal["status"] == "needs_attention"
                  or now - proposal["updated_at"]
                  >= EFFECT_PENDING_SECONDS):
                outcome = "needs_attention"
            else:
                outcome = "in_progress"
            proposal_outcomes.append((proposal, outcome))

        skip_outcome = None
        if skip_claim is not None:
            receipt = self._effect_receipt(
                authority, skip_claim["skip_request_id"], "next")
            if receipt is None:
                skip_outcome = ("no_journal" if skip_claim["skip_state"]
                                == "needs_attention"
                                or now - skip_claim["updated_at"]
                                >= EFFECT_PENDING_SECONDS else "in_progress")
            elif receipt["state"] == "succeeded":
                skip_outcome = "succeeded"
                requires_latest = True
            elif (skip_claim["skip_state"] == "needs_attention"
                  or now - skip_claim["updated_at"]
                  >= EFFECT_PENDING_SECONDS):
                skip_outcome = "needs_attention"
            else:
                skip_outcome = "in_progress"

        actionable = [item for item in proposal_outcomes
                      if item[1] in {"succeeded", "no_journal"}
                      or item[1] == "needs_attention"
                      and item[0]["status"] != "needs_attention"
                      or item[1] == "in_progress"
                      and item[0]["status"] != "approving"]
        skip_actionable = (
            skip_outcome in {"succeeded", "no_journal"}
            or skip_outcome == "needs_attention" and skip_claim is not None
            and skip_claim["skip_state"] != "needs_attention"
            or skip_outcome == "in_progress" and skip_claim is not None
            and skip_claim["skip_state"] != "executing")
        if not actionable and not skip_actionable:
            return
        latest = (self._latest_music_authority(actor, authority)
                  if requires_latest else None)

        with self.db.transaction() as connection:
            self._actor(connection, actor)
            room = self._active_room(connection, room_id)
            self._member(connection, actor, room)
            self._assert_room_authority(room, authority)
            if latest is not None:
                self._assert_music_revision(connection, latest)
            changed = False
            for claimed, outcome in actionable:
                raw = connection.execute(
                    "SELECT * FROM party_dj_proposals WHERE id=? AND room_id=?",
                    (claimed["id"], room_id)).fetchone()
                if raw is None:
                    raise StartupError("party_dj_storage_invalid")
                current = self._proposal_row(raw)
                if (current["status"] != claimed["status"]
                        or current["decision_request_id"]
                        != claimed["decision_request_id"]
                        or current["decision_request_hash"]
                        != claimed["decision_request_hash"]):
                    continue
                changes = dict(
                    revision=current["revision"] + 1, updated_at=now)
                if outcome == "succeeded":
                    changes["status"] = "approved"
                elif outcome == "needs_attention":
                    changes["status"] = "needs_attention"
                elif outcome == "no_journal":
                    changes.update(
                        status="pending", decision_request_id=None,
                        decision_request_hash=None)
                else:
                    changes["status"] = "approving"
                self._update_proposal(connection, current, **changes)
                changed = True

            if skip_actionable:
                current_request_id = room["skip_request_id"]
                current_request_hash = room["skip_request_hash"]
                if (room["skip_state"] == skip_claim["skip_state"]
                        and current_request_id == skip_claim["skip_request_id"]
                        and current_request_hash == skip_claim["skip_request_hash"]):
                    if skip_outcome == "succeeded":
                        connection.execute(
                            "DELETE FROM party_dj_skip_votes WHERE room_id=? "
                            "AND generation=?",
                            (room_id, room["skip_generation"]))
                        room = dict(room)
                        room.update(
                            skip_state="open", skip_request_id=None,
                            skip_request_hash=None,
                            skip_generation=room["skip_generation"] + 1)
                    elif skip_outcome == "needs_attention":
                        room = dict(room)
                        room["skip_state"] = "needs_attention"
                    elif skip_outcome == "no_journal":
                        room = dict(room)
                        room.update(skip_state="open", skip_request_id=None,
                                    skip_request_hash=None)
                    else:
                        room = dict(room)
                        room["skip_state"] = "executing"
                    changed = True
            if changed:
                changes = dict(
                    revision=room["revision"] + 1, updated_at=now)
                if latest is not None:
                    changes["authority_json"] = latest.model_dump_json()
                self._update_room(connection, room, **changes)

    def vote(self, actor, room_id, proposal_id, body):
        if type(body) is not VotePartyDjProposalRequest:
            raise ApiError("invalid_request")
        now = int(self.settings.clock())
        with self.db.transaction() as connection:
            self._actor(connection, actor)
            replay = self._replay(connection, actor, room_id, body)
            if replay is not None:
                return replay
            self._request_capacity(connection, room_id)
            room = self._active_room(connection, room_id, body.expectedRoomRevision)
            member = self._member(connection, actor, room)
            raw = connection.execute(
                "SELECT * FROM party_dj_proposals WHERE id=? AND room_id=?",
                (proposal_id, room_id)).fetchone()
            if raw is None:
                raise ApiError("not_found", 404)
            proposal = self._proposal_row(raw)
            if (proposal["revision"] != body.expectedProposalRevision
                    or proposal["status"] != "pending"):
                raise ApiError("party_dj_proposal_changed", 409)
            current = connection.execute(
                "SELECT * FROM party_dj_proposal_votes WHERE proposal_id=? "
                "AND account_id=?", (proposal_id, actor.id)).fetchone()
            if current is not None:
                self._proposal_vote_row(current)
            if body.vote == "up" and current is None:
                self._insert_proposal_vote(connection, proposal_id, actor, now)
            elif body.vote == "remove" and current is not None:
                connection.execute(
                    "DELETE FROM party_dj_proposal_votes WHERE proposal_id=? "
                    "AND account_id=?", (proposal_id, actor.id))
            self._update_participant(
                connection, member, revision=member["revision"] + 1,
                request_id=None, request_hash=None, last_seen_at=now)
            proposal = self._update_proposal(
                connection, proposal, revision=proposal["revision"] + 1,
                updated_at=now)
            room = self._update_room(
                connection, room, revision=room["revision"] + 1,
                updated_at=now)
            result = self._snapshot(connection, room, actor)
            return self._record(connection, actor, room_id, body, result)

    def decide(self, actor, room_id, proposal_id, body):
        if type(body) is not DecidePartyDjProposalRequest:
            raise ApiError("invalid_request")
        now = int(self.settings.clock())
        with self.db.transaction() as connection:
            self._actor(connection, actor)
            replay = self._replay(connection, actor, room_id, body)
            if replay is not None:
                return replay
            room = self._active_room(connection, room_id)
            member = self._member(connection, actor, room)
            if (room["host_account_id"] != actor.id
                    or room["host_family_id"] != actor.family_id):
                raise ApiError("forbidden", 403)
            raw = connection.execute(
                "SELECT * FROM party_dj_proposals WHERE id=? AND room_id=?",
                (proposal_id, room_id)).fetchone()
            if raw is None:
                raise ApiError("not_found", 404)
            proposal = self._proposal_row(raw)
            request_hash = self._hash(body)
            resuming = (body.decision == "approve"
                        and proposal["status"] == "approving"
                        and proposal["decision_request_id"] == body.requestId
                        and proposal["decision_request_hash"] == request_hash)
            if not resuming and (
                    room["revision"] != body.expectedRoomRevision
                    or proposal["revision"] != body.expectedProposalRevision
                    or proposal["status"] != "pending"):
                raise ApiError("party_dj_proposal_changed", 409)
            self._request_capacity(connection, room_id)
            if not resuming:
                self._update_participant(
                    connection, member, revision=member["revision"] + 1,
                    request_id=None, request_hash=None, last_seen_at=now)
            if body.decision == "reject" and not resuming:
                proposal = self._update_proposal(
                    connection, proposal, revision=proposal["revision"] + 1,
                    status="rejected", decision_request_id=body.requestId,
                    decision_request_hash=request_hash, updated_at=now)
                room = self._update_room(
                    connection, room, revision=room["revision"] + 1,
                    updated_at=now)
                result = self._snapshot(connection, room, actor)
                return self._record(connection, actor, room_id, body, result)
            authority = PartyDjAuthority.model_validate_json(room["authority_json"])
            if body.expectedPlayerRevision != authority.playerRevision:
                raise ApiError("party_dj_authority_changed", 409)
            if not resuming:
                proposal = self._update_proposal(
                    connection, proposal, revision=proposal["revision"] + 1,
                    status="approving", decision_request_id=body.requestId,
                    decision_request_hash=request_hash, updated_at=now)
                room = self._update_room(
                    connection, room, revision=room["revision"] + 1,
                    updated_at=now)
        command = self._command(
            authority, body.requestId, "queue_add", [proposal["media_uri"]])
        try:
            receipt = self.music_playback.command(actor, command)["receipt"]
            if receipt["state"] != "succeeded":
                receipt = self._recorded_command_receipt(
                    command, actor_id=actor.id)
                if receipt is None:
                    raise StartupError("party_dj_storage_invalid")
        except StartupError:
            raise
        except ApiError:
            receipt = self._recorded_command_receipt(
                command, actor_id=actor.id)
            if receipt is None:
                self._rollback_proposal_claim(
                    actor, room_id, proposal_id, body)
                raise
            if receipt["state"] == "pending":
                return self.snapshot(actor, room_id)
        except Exception:
            receipt = self._recorded_command_receipt(
                command, actor_id=actor.id)
            if receipt is None:
                self._rollback_proposal_claim(
                    actor, room_id, proposal_id, body)
                raise ApiError(
                    "music_playback_worker_unavailable", 503) from None
            if receipt["state"] == "pending":
                return self.snapshot(actor, room_id)
        if receipt["state"] == "pending":
            return self.snapshot(actor, room_id)
        with self.db.transaction() as connection:
            self._actor(connection, actor)
            room = self._active_room(connection, room_id)
            self._member(connection, actor, room)
            proposal = self._proposal_row(connection.execute(
                "SELECT * FROM party_dj_proposals WHERE id=? AND room_id=?",
                (proposal_id, room_id)).fetchone())
            if (proposal["decision_request_id"] != body.requestId
                    or proposal["decision_request_hash"] != self._hash(body)
                    or proposal["status"] != "approving"):
                raise ApiError("party_dj_proposal_changed", 409)
            succeeded = receipt is not None and receipt["state"] == "succeeded"
            proposal = self._update_proposal(
                connection, proposal, revision=proposal["revision"] + 1,
                status="approved" if succeeded else "needs_attention",
                updated_at=int(self.settings.clock()))
            changes = dict(revision=room["revision"] + 1,
                           updated_at=int(self.settings.clock()))
            if succeeded:
                authority = authority.model_copy(update={
                    "managerRevision": receipt["playerRevision"],
                    "playerRevision": receipt["playerRevision"]})
                changes["authority_json"] = authority.model_dump_json()
            room = self._update_room(connection, room, **changes)
            result = self._snapshot(connection, room, actor)
            return self._record(connection, actor, room_id, body, result)

    @staticmethod
    def _command(authority, request_id, operation, media_uris=None):
        return MusicPlaybackCommandRequest(
            requestId=request_id, installationId=authority.installationId,
            expectedInstallationRevision=authority.installationRevision,
            expectedCoreRevision=authority.coreRevision,
            expectedPlayerRevision=authority.playerRevision,
            targetId=authority.targetId,
            expectedProvider=authority.provider,
            expectedTargetKind=authority.targetKind,
            expectedQueueId=authority.queueId,
            expectedGroupMembers=authority.groupMembers,
            operation=operation, mediaUris=media_uris or [])

    def skip(self, actor, room_id, body):
        if type(body) is not VotePartyDjSkipRequest:
            raise ApiError("invalid_request")
        now = int(self.settings.clock())
        execute = False
        with self.db.transaction() as connection:
            self._actor(connection, actor)
            replay = self._replay(connection, actor, room_id, body)
            if replay is not None:
                return replay
            room = self._active_room(connection, room_id)
            member = self._member(connection, actor, room)
            authority = PartyDjAuthority.model_validate_json(room["authority_json"])
            request_hash = self._hash(body)
            resuming = (room["skip_state"] == "executing"
                        and room["skip_request_id"] == body.requestId
                        and room["skip_request_hash"] == request_hash)
            if not resuming and (
                    room["revision"] != body.expectedRoomRevision
                    or member["revision"] != body.expectedParticipantRevision
                    or body.expectedPlayerRevision != authority.playerRevision):
                raise ApiError("party_dj_authority_changed", 409)
            if not resuming and room["skip_state"] != "open":
                raise ApiError("party_dj_skip_needs_attention", 409)
            self._request_capacity(connection, room_id)
            if resuming:
                execute = True
            else:
                self._update_participant(
                    connection, member, revision=member["revision"] + 1,
                    request_id=None, request_hash=None, last_seen_at=now)
                current_vote = connection.execute(
                    "SELECT * FROM party_dj_skip_votes WHERE room_id=? "
                    "AND generation=? AND account_id=?", (room_id,
                     room["skip_generation"], actor.id)).fetchone()
                if current_vote is None:
                    self._insert_skip_vote(connection, room, actor, now)
                else:
                    self._skip_vote_row(current_vote)
                connected = connection.execute(
                    "SELECT COUNT(*) FROM party_dj_participants WHERE room_id=? "
                    "AND last_seen_at>=?", (room_id, now - CONNECTED_SECONDS)
                ).fetchone()[0]
                vote_rows = connection.execute(
                    "SELECT v.* FROM party_dj_skip_votes v "
                    "JOIN party_dj_participants p ON p.room_id=v.room_id "
                    "AND p.account_id=v.account_id AND p.family_id=v.family_id "
                    "WHERE v.room_id=? AND v.generation=? "
                    "AND p.last_seen_at>=?",
                    (room_id, room["skip_generation"], now - CONNECTED_SECONDS)
                ).fetchall()
                for vote in vote_rows:
                    self._skip_vote_row(vote)
                votes = len(vote_rows)
                execute = votes >= self._required_skip(
                    connected, room["skip_quorum_percent"])
                changes = dict(revision=room["revision"] + 1, updated_at=now)
                if execute:
                    changes.update(skip_state="executing",
                                   skip_request_id=body.requestId,
                                   skip_request_hash=request_hash)
                room = self._update_room(connection, room, **changes)
                if not execute:
                    result = self._snapshot(connection, room, actor)
                    return self._record(connection, actor, room_id, body, result)
        command = self._command(authority, body.requestId, "next")
        try:
            receipt = self.music_playback.command(actor, command)["receipt"]
            if receipt["state"] != "succeeded":
                receipt = self._recorded_command_receipt(
                    command, actor_id=actor.id)
                if receipt is None:
                    raise StartupError("party_dj_storage_invalid")
        except StartupError:
            raise
        except ApiError:
            receipt = self._recorded_command_receipt(
                command, actor_id=actor.id)
            if receipt is None:
                self._rollback_skip_claim(actor, room_id, body)
                raise
            if receipt["state"] == "pending":
                return self.snapshot(actor, room_id)
        except Exception:
            receipt = self._recorded_command_receipt(
                command, actor_id=actor.id)
            if receipt is None:
                self._rollback_skip_claim(actor, room_id, body)
                raise ApiError(
                    "music_playback_worker_unavailable", 503) from None
            if receipt["state"] == "pending":
                return self.snapshot(actor, room_id)
        if receipt["state"] == "pending":
            return self.snapshot(actor, room_id)
        with self.db.transaction() as connection:
            self._actor(connection, actor)
            room = self._active_room(connection, room_id)
            self._member(connection, actor, room)
            if (room["skip_state"] != "executing"
                    or room["skip_request_id"] != body.requestId
                    or room["skip_request_hash"] != self._hash(body)):
                raise ApiError("party_dj_authority_changed", 409)
            succeeded = receipt is not None and receipt["state"] == "succeeded"
            changes = dict(
                revision=room["revision"] + 1,
                skip_state="open" if succeeded else "needs_attention",
                skip_request_id=None if succeeded else body.requestId,
                skip_request_hash=None if succeeded else self._hash(body),
                skip_generation=room["skip_generation"] + (1 if succeeded else 0),
                updated_at=int(self.settings.clock()))
            if succeeded:
                authority = authority.model_copy(update={
                    "managerRevision": receipt["playerRevision"],
                    "playerRevision": receipt["playerRevision"]})
                changes["authority_json"] = authority.model_dump_json()
            room = self._update_room(connection, room, **changes)
            result = self._snapshot(connection, room, actor)
            return self._record(connection, actor, room_id, body, result)

    def dismiss_skip(self, actor, room_id, body):
        """Release an uncertain skip gate without issuing another skip."""
        if type(body) is not DismissPartyDjSkipRequest:
            raise ApiError("invalid_request")
        self._reconcile_effects(actor, room_id)
        room_authority = self._room_authority(actor, room_id)
        authority = self._latest_music_authority(actor, room_authority)
        now = int(self.settings.clock())
        with self.db.transaction() as connection:
            self._actor(connection, actor)
            replay = self._replay(connection, actor, room_id, body)
            if replay is not None:
                return replay
            room = self._active_room(
                connection, room_id, body.expectedRoomRevision)
            member = self._member(connection, actor, room)
            self._assert_room_authority(room, room_authority)
            self._assert_music_revision(connection, authority)
            if (room["host_account_id"] != actor.id
                    or room["host_family_id"] != actor.family_id):
                raise ApiError("forbidden", 403)
            if (member["revision"] != body.expectedParticipantRevision
                    or room["skip_state"] != "needs_attention"):
                raise ApiError("party_dj_skip_needs_attention", 409)
            self._request_capacity(connection, room_id, recovery=True)
            self._update_participant(
                connection, member, revision=member["revision"] + 1,
                request_id=None, request_hash=None, last_seen_at=now)
            connection.execute(
                "DELETE FROM party_dj_skip_votes WHERE room_id=? AND generation=?",
                (room_id, room["skip_generation"]))
            room = self._update_room(
                connection, room, revision=room["revision"] + 1,
                skip_generation=room["skip_generation"] + 1,
                skip_state="open", skip_request_id=None,
                skip_request_hash=None,
                authority_json=authority.model_dump_json(), updated_at=now)
            result = self._snapshot(connection, room, actor)
            return self._record(connection, actor, room_id, body, result)

    def leave(self, actor, room_id, body):
        if type(body) is not LeavePartyDjRequest:
            raise ApiError("invalid_request")
        now = int(self.settings.clock())
        with self.db.transaction() as connection:
            self._actor(connection, actor)
            replay = self._replay(connection, actor, room_id, body)
            if replay is not None:
                return replay
            room = self._active_room(connection, room_id, body.expectedRoomRevision)
            member = self._member(connection, actor, room)
            if member["revision"] != body.expectedParticipantRevision:
                raise ApiError("party_dj_participant_changed", 409)
            connection.execute(
                "DELETE FROM party_dj_proposal_votes WHERE account_id=? "
                "AND proposal_id IN (SELECT id FROM party_dj_proposals "
                "WHERE room_id=?)", (actor.id, room_id))
            connection.execute(
                "DELETE FROM party_dj_skip_votes WHERE room_id=? AND account_id=?",
                (room_id, actor.id))
            connection.execute(
                "DELETE FROM party_dj_participants WHERE room_id=? AND account_id=?",
                (room_id, actor.id))
            remaining = connection.execute(
                "SELECT * FROM party_dj_participants WHERE room_id=? "
                "ORDER BY CASE WHEN last_seen_at>=? THEN 0 ELSE 1 END,"
                "joined_at,account_id", (room_id, now - CONNECTED_SECONDS)
            ).fetchall()
            changes = dict(revision=room["revision"] + 1, updated_at=now)
            next_host = room["host_account_id"]
            if not remaining:
                changes["state"] = "closed"
                next_host = None
            elif actor.id == room["host_account_id"]:
                chosen = self._participant_row(remaining[0])
                changes.update(host_account_id=chosen["account_id"],
                               host_family_id=chosen["family_id"])
                next_host = chosen["account_id"]
            room = self._update_room(connection, room, **changes)
            result = LeavePartyDjResponse(
                state=room["state"], roomRevision=room["revision"],
                nextHostAccountId=next_host).model_dump(mode="json")
            return self._record(connection, actor, room_id, body, result)
