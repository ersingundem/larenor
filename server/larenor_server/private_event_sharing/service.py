from dataclasses import dataclass
import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import time
import uuid
from collections.abc import Callable

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..auth import Principal
from ..database import Database
from ..errors import ApiError, StartupError


MAX_COMMAND_BYTES = 32_768
MAX_SHARES = 256
MAX_EVENTS = 1_024
MAX_EXPORT = 256
MAX_ACCESS_SECONDS = 7 * 24 * 60 * 60
MASK_TYPES = {"face", "license_plate"}
METADATA_TYPES = {"device_serial", "gps", "camera_name", "network_address"}
ACCESS_MODES = {"one_time", "time_bound"}


def _canonical(value: object) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode()


def transformation_proof(key: bytes, value: dict) -> str:
    if not isinstance(key, bytes) or len(key) != 32 or not isinstance(value, dict):
        raise ValueError("invalid_transformation_proof_input")
    payload = {name: item for name, item in value.items() if name != "proof"}
    return hmac.new(
        key,
        b"larenor-private-event-transform-v1\0" + _canonical(payload),
        hashlib.sha256,
    ).hexdigest()


def _identifier(value: object) -> bool:
    return isinstance(value, str) and 1 <= len(value) <= 128 and all(
        character.isalnum() or character in "-_.:" for character in value
    )


def _revision(value: object) -> bool:
    return type(value) is int and value > 0


def _digest(value: object) -> bool:
    return isinstance(value, str) and len(value) == 64 and all(
        character in "0123456789abcdef" for character in value
    )


@dataclass(frozen=True)
class EventShareAuthority:
    core_id: str
    home_id: str
    account_id: str
    session_id: str
    core_revision: int
    home_revision: int
    account_revision: int
    members_revision: int
    camera_id: str
    camera_revision: int
    event_id: str
    event_revision: int
    session_revision: int
    share_revision: int
    member_ids: tuple[str, ...]
    can_share: bool

    def __post_init__(self) -> None:
        if (
            any(not _identifier(item) for item in (
                self.core_id, self.home_id, self.account_id, self.session_id,
                self.camera_id, self.event_id,
            ))
            or any(not _revision(item) for item in (
                self.core_revision, self.home_revision, self.account_revision,
                self.members_revision, self.camera_revision, self.event_revision,
                self.session_revision, self.share_revision,
            ))
            or not isinstance(self.member_ids, tuple)
            or not 1 <= len(self.member_ids) <= 128
            or len(set(self.member_ids)) != len(self.member_ids)
            or any(not _identifier(item) for item in self.member_ids)
            or type(self.can_share) is not bool
        ):
            raise ValueError("invalid_event_share_authority")


@dataclass(frozen=True)
class EventShareConsent:
    id: str
    revision: int
    granted_by: str
    recipient_id: str
    event_id: str
    purpose: str
    accepted_at: float
    expires_at: float
    access_mode: str
    required_masks: tuple[str, ...]
    required_metadata: tuple[str, ...]

    def __post_init__(self) -> None:
        if (
            any(not _identifier(item) for item in (
                self.id, self.granted_by, self.recipient_id, self.event_id,
            ))
            or not _revision(self.revision)
            or not isinstance(self.purpose, str)
            or not 1 <= len(self.purpose) <= 200
            or type(self.accepted_at) not in (int, float)
            or type(self.expires_at) not in (int, float)
            or self.accepted_at >= self.expires_at
            or self.access_mode not in ACCESS_MODES
            or not isinstance(self.required_masks, tuple)
            or not isinstance(self.required_metadata, tuple)
            or not set(self.required_masks).issubset(MASK_TYPES)
            or not set(self.required_metadata).issubset(METADATA_TYPES)
            or len(set(self.required_masks)) != len(self.required_masks)
            or len(set(self.required_metadata)) != len(self.required_metadata)
        ):
            raise ValueError("invalid_event_share_consent")


@dataclass(frozen=True)
class PrivateEventShare:
    id: str
    owner_id: str
    recipient_id: str
    purpose: str
    access_mode: str
    expires_at: float
    output_artifact_id: str
    output_digest: str
    pipeline_id: str
    pipeline_revision: int
    mask_types: tuple[str, ...]
    removed_metadata: tuple[str, ...]
    created_at: float
    revoked_at: float | None
    consumed_at: float | None


@dataclass(frozen=True)
class EventShareReceipt:
    audit_id: str
    command_id: str
    action: str
    share_revision: int
    share: PrivateEventShare
    access_token: str


class PrivateEventShareStore:
    def __init__(
        self,
        database: Database,
        *,
        encryption_key: bytes,
        audit_key: bytes,
        transformation_key: bytes,
        clock: Callable[[], float] = time.time,
    ):
        if any(not isinstance(key, bytes) or len(key) != 32 for key in (
            encryption_key, audit_key, transformation_key,
        )):
            raise ValueError("invalid_private_event_share_keys")
        self.database = database
        self._cipher = AESGCM(encryption_key)
        self._audit_key = audit_key
        self._transformation_key = transformation_key
        self._clock = clock

    def _fingerprint(self, domain: bytes, value: bytes) -> str:
        return hmac.new(
            self._audit_key,
            b"larenor-private-event-share-" + domain + b"-v1\0" + value,
            hashlib.sha256,
        ).hexdigest()

    def _state_hash(self, values: tuple[object, ...]) -> str:
        return self._fingerprint(b"state", _canonical(values))

    def _event_hash(self, values: tuple[object, ...]) -> str:
        return self._fingerprint(b"event", _canonical(values))

    @staticmethod
    def _parse(command_bytes: bytes, fields: set[str]) -> dict:
        if not isinstance(command_bytes, bytes) or not 1 <= len(command_bytes) <= MAX_COMMAND_BYTES:
            raise ApiError("invalid_request", 400)

        def unique(pairs: list[tuple[str, object]]) -> dict:
            result = {}
            for key, value in pairs:
                if key in result:
                    raise ValueError
                result[key] = value
            return result

        try:
            value = json.loads(command_bytes.decode(), object_pairs_hook=unique)
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
            raise ApiError("invalid_request", 400) from None
        if not isinstance(value, dict) or set(value) != fields:
            raise ApiError("invalid_request", 400)
        return value

    @staticmethod
    def _authorize(actor: Principal, authority: EventShareAuthority, *, write: bool) -> None:
        if actor.id != authority.account_id or actor.family_id != authority.session_id:
            raise ApiError("authority_changed", 409)
        if actor.role != "admin" and actor.id not in authority.member_ids:
            raise ApiError("forbidden", 403)
        if write and actor.role != "admin" and not authority.can_share:
            raise ApiError("forbidden", 403)

    @staticmethod
    def _check_scope(value: dict, authority: EventShareAuthority) -> None:
        expected = {
            "coreId": authority.core_id,
            "homeId": authority.home_id,
            "accountId": authority.account_id,
            "sessionId": authority.session_id,
            "coreRevision": authority.core_revision,
            "homeRevision": authority.home_revision,
            "accountRevision": authority.account_revision,
            "membersRevision": authority.members_revision,
            "cameraId": authority.camera_id,
            "cameraRevision": authority.camera_revision,
            "eventId": authority.event_id,
            "eventRevision": authority.event_revision,
            "sessionRevision": authority.session_revision,
            "expectedShareRevision": authority.share_revision,
        }
        if any(
            type(value.get(key)) is not type(expected_value)
            or value.get(key) != expected_value
            for key, expected_value in expected.items()
        ):
            raise ApiError("authority_changed", 409)

    @staticmethod
    def _scope(authority: EventShareAuthority) -> tuple[str, str, str, str]:
        return authority.core_id, authority.home_id, authority.camera_id, authority.event_id

    def _state(self, connection: sqlite3.Connection, scope: tuple[str, str, str, str]):
        row = connection.execute(
            "SELECT * FROM private_event_share_state WHERE core_id=? AND home_id=? "
            "AND camera_id=? AND event_id=?", scope,
        ).fetchone()
        if row is not None:
            values = (
                row["core_id"], row["home_id"], row["camera_id"], row["event_id"],
                row["base_revision"], row["revision"], row["event_count"], row["last_hash"],
            )
            if not hmac.compare_digest(row["state_hash"], self._state_hash(values)):
                raise StartupError("private_event_share_history_invalid")
        return row

    def _decrypt(self, row: sqlite3.Row, statuses: dict[str, tuple[float | None, float | None]]):
        try:
            aad = f'{row["core_id"]}\0{row["home_id"]}\0{row["camera_id"]}\0{row["event_id"]}\0{row["id"]}'.encode()
            raw = self._cipher.decrypt(row["nonce"], row["ciphertext"], aad)
            if not hmac.compare_digest(row["payload_hash"], self._fingerprint(b"payload", raw)):
                raise ValueError
            value = json.loads(raw)
            token = value.pop("access_token")
            source_digest = value.pop("source_digest")
            if (
                not _digest(source_digest)
                or not isinstance(token, str)
                or len(token) < 32
                or not hmac.compare_digest(
                    row["token_hash"], self._fingerprint(b"token", token.encode())
                )
            ):
                raise ValueError
            revoked_at, consumed_at = statuses.get(row["id"], (None, None))
            share = PrivateEventShare(
                id=row["id"],
                mask_types=tuple(value.pop("mask_types")),
                removed_metadata=tuple(value.pop("removed_metadata")),
                revoked_at=revoked_at,
                consumed_at=consumed_at,
                **value,
            )
            return share, token
        except (InvalidTag, KeyError, TypeError, ValueError, json.JSONDecodeError):
            raise StartupError("private_event_share_storage_invalid") from None

    def _verified(self, connection: sqlite3.Connection, scope: tuple[str, str, str, str]):
        state = self._state(connection, scope)
        rows = connection.execute(
            "SELECT * FROM private_event_share_events WHERE core_id=? AND home_id=? "
            "AND camera_id=? AND event_id=? ORDER BY sequence", scope,
        ).fetchall()
        records = connection.execute(
            "SELECT * FROM private_event_shares WHERE core_id=? AND home_id=? "
            "AND camera_id=? AND event_id=? ORDER BY created_at,id", scope,
        ).fetchall()
        if state is None:
            if rows or records:
                raise StartupError("private_event_share_history_invalid")
            return (), {}
        previous = ""
        creates: set[str] = set()
        create_hashes: dict[str, tuple[str, str]] = {}
        statuses: dict[str, tuple[float | None, float | None]] = {}
        access_counts: dict[str, int] = {}
        for row in rows:
            values = (
                row["sequence"], row["audit_id"], row["core_id"], row["home_id"],
                row["camera_id"], row["event_id"], row["command_id"], row["action"],
                row["actor_id"], row["recipient_id"], row["share_id"],
                row["share_revision"], row["occurred_at"], row["request_hash"],
                row["previous_hash"],
            )
            if row["previous_hash"] != previous or not hmac.compare_digest(
                row["event_hash"], self._event_hash(values)
            ):
                raise StartupError("private_event_share_history_invalid")
            share_id = row["share_id"]
            revoked, consumed = statuses.get(share_id, (None, None))
            if row["action"] == "created":
                if share_id in creates:
                    raise StartupError("private_event_share_history_invalid")
                creates.add(share_id)
                create_hashes[share_id] = row["request_hash"], row["recipient_id"]
            elif share_id not in creates or revoked is not None:
                raise StartupError("private_event_share_history_invalid")
            elif row["action"] == "revoked":
                revoked = row["occurred_at"]
            else:
                consumed = row["occurred_at"]
                access_counts[share_id] = access_counts.get(share_id, 0) + 1
                if access_counts[share_id] > 128:
                    raise StartupError("private_event_share_history_invalid")
            statuses[share_id] = revoked, consumed
            previous = row["event_hash"]
        values = {row["id"]: self._decrypt(row, statuses) for row in records}
        if (
            set(values) != creates
            or len(rows) != state["event_count"]
            or state["revision"] != state["base_revision"] + len(rows)
            or state["last_hash"] != previous
        ):
            raise StartupError("private_event_share_history_invalid")
        for row in records:
            request_hash, recipient_id = create_hashes[row["id"]]
            share, _ = values[row["id"]]
            if (
                not hmac.compare_digest(row["request_hash"], request_hash)
                or share.recipient_id != recipient_id
            ):
                raise StartupError("private_event_share_history_invalid")
        return rows, values

    def _insert_event(
        self,
        connection: sqlite3.Connection,
        *,
        scope: tuple[str, str, str, str],
        state: sqlite3.Row | None,
        base_revision: int,
        command_id: str,
        action: str,
        actor_id: str,
        recipient_id: str,
        share_id: str,
        request_hash: str,
        occurred_at: float,
    ) -> tuple[str, int]:
        current = base_revision if state is None else state["revision"]
        count = 0 if state is None else state["event_count"]
        previous = "" if state is None else state["last_hash"]
        sequence = connection.execute(
            "SELECT COALESCE(MAX(sequence),0)+1 FROM private_event_share_events"
        ).fetchone()[0]
        audit_id = uuid.uuid4().hex
        revision = current + 1
        values = (
            sequence, audit_id, *scope, command_id, action, actor_id, recipient_id,
            share_id, revision, occurred_at, request_hash, previous,
        )
        event_hash = self._event_hash(values)
        connection.execute(
            "INSERT INTO private_event_share_events VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            values + (event_hash,),
        )
        state_values = (*scope, base_revision if state is None else state["base_revision"],
                        revision, count + 1, event_hash)
        connection.execute(
            "INSERT INTO private_event_share_state VALUES(?,?,?,?,?,?,?,?,?) "
            "ON CONFLICT(core_id,home_id,camera_id,event_id) DO UPDATE SET "
            "revision=excluded.revision,event_count=excluded.event_count,"
            "last_hash=excluded.last_hash,state_hash=excluded.state_hash",
            state_values + (self._state_hash(state_values),),
        )
        return audit_id, revision

    @staticmethod
    def _find_event(connection, scope, command_id):
        return connection.execute(
            "SELECT * FROM private_event_share_events WHERE core_id=? AND home_id=? "
            "AND camera_id=? AND event_id=? AND command_id=?", (*scope, command_id),
        ).fetchone()

    def create(
        self,
        actor: Principal,
        *,
        command_bytes: bytes,
        authority: EventShareAuthority,
        consent: EventShareConsent,
    ) -> EventShareReceipt:
        self._authorize(actor, authority, write=True)
        fields = {
            "action", "commandId", "coreId", "homeId", "accountId", "sessionId",
            "coreRevision", "homeRevision", "accountRevision", "membersRevision",
            "cameraId", "cameraRevision", "eventId", "eventRevision", "sessionRevision",
            "expectedShareRevision", "consentId", "consentRevision", "recipientId",
            "purpose", "expiresAt", "accessMode", "transformation",
        }
        value = self._parse(command_bytes, fields)
        self._check_scope(value, authority)
        if value["action"] != "create" or not _identifier(value["commandId"]):
            raise ApiError("invalid_request", 400)
        now = self._clock()
        consent_expected = {
            "consentId": consent.id,
            "consentRevision": consent.revision,
            "recipientId": consent.recipient_id,
            "purpose": consent.purpose,
            "expiresAt": consent.expires_at,
            "accessMode": consent.access_mode,
        }
        if (
            consent.granted_by != actor.id
            or consent.event_id != authority.event_id
            or consent.accepted_at > now
            or consent.expires_at <= now
            or consent.expires_at - now > MAX_ACCESS_SECONDS
            or any(value.get(key) != expected for key, expected in consent_expected.items())
        ):
            raise ApiError("consent_scope_changed", 409)
        transformation = value["transformation"]
        transform_fields = {
            "sourceDigest", "outputDigest", "outputArtifactId", "pipelineId",
            "pipelineRevision", "masks", "removedMetadata", "proof",
        }
        if not isinstance(transformation, dict) or set(transformation) != transform_fields:
            raise ApiError("transformation_unverified", 409)
        masks = transformation["masks"]
        metadata = transformation["removedMetadata"]
        proof = transformation["proof"]
        if (
            not _digest(transformation["sourceDigest"])
            or not _digest(transformation["outputDigest"])
            or transformation["sourceDigest"] == transformation["outputDigest"]
            or not _identifier(transformation["outputArtifactId"])
            or not _identifier(transformation["pipelineId"])
            or not _revision(transformation["pipelineRevision"])
            or not isinstance(masks, list)
            or not isinstance(metadata, list)
            or len(set(masks)) != len(masks)
            or len(set(metadata)) != len(metadata)
            or not set(masks).issubset(MASK_TYPES)
            or not set(metadata).issubset(METADATA_TYPES)
            or not set(consent.required_masks).issubset(masks)
            or not set(consent.required_metadata).issubset(metadata)
            or not isinstance(proof, str)
            or not hmac.compare_digest(proof, transformation_proof(self._transformation_key, transformation))
        ):
            raise ApiError("transformation_unverified", 409)
        request_hash = self._fingerprint(b"request", command_bytes)
        scope = self._scope(authority)
        with self.database.transaction() as connection:
            _, shares = self._verified(connection, scope)
            replay = self._find_event(connection, scope, value["commandId"])
            if replay is not None:
                if (
                    replay["action"] != "created"
                    or replay["actor_id"] != actor.id
                    or not hmac.compare_digest(replay["request_hash"], request_hash)
                ):
                    raise ApiError("idempotency_conflict", 409)
                share, token = shares[replay["share_id"]]
                return EventShareReceipt(
                    replay["audit_id"], value["commandId"], "created",
                    replay["share_revision"], share, token,
                )
            state = self._state(connection, scope)
            current = authority.share_revision if state is None else state["revision"]
            if current != authority.share_revision:
                raise ApiError("authority_changed", 409)
            if len(shares) >= MAX_SHARES or (
                state is not None and state["event_count"] >= MAX_EVENTS
            ):
                raise ApiError("private_event_share_limit_reached", 413)
            share_id = uuid.uuid4().hex
            token = secrets.token_urlsafe(32)
            payload = {
                "owner_id": actor.id,
                "recipient_id": consent.recipient_id,
                "purpose": consent.purpose,
                "access_mode": consent.access_mode,
                "expires_at": consent.expires_at,
                "source_digest": transformation["sourceDigest"],
                "output_artifact_id": transformation["outputArtifactId"],
                "output_digest": transformation["outputDigest"],
                "pipeline_id": transformation["pipelineId"],
                "pipeline_revision": transformation["pipelineRevision"],
                "mask_types": sorted(masks),
                "removed_metadata": sorted(metadata),
                "created_at": now,
                "access_token": token,
            }
            raw = _canonical(payload)
            nonce = os.urandom(12)
            aad = f"{authority.core_id}\0{authority.home_id}\0{authority.camera_id}\0{authority.event_id}\0{share_id}".encode()
            connection.execute(
                "INSERT INTO private_event_shares VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                (
                    share_id, *scope, nonce, self._cipher.encrypt(nonce, raw, aad),
                    self._fingerprint(b"payload", raw),
                    self._fingerprint(b"token", token.encode()), request_hash, now,
                ),
            )
            audit_id, revision = self._insert_event(
                connection, scope=scope, state=state, base_revision=authority.share_revision,
                command_id=value["commandId"], action="created", actor_id=actor.id,
                recipient_id=consent.recipient_id, share_id=share_id,
                request_hash=request_hash, occurred_at=now,
            )
            share, _ = self._decrypt(
                connection.execute("SELECT * FROM private_event_shares WHERE id=?", (share_id,)).fetchone(),
                {},
            )
            return EventShareReceipt(audit_id, value["commandId"], "created", revision, share, token)

    def redeem(
        self,
        *,
        recipient_id: str,
        access_token: str,
        access_id: str,
        now: float | None = None,
    ) -> dict:
        if not _identifier(recipient_id) or not _identifier(access_id) or not isinstance(access_token, str):
            raise ApiError("share_unavailable", 404)
        token_hash = self._fingerprint(b"token", access_token.encode())
        timestamp = self._clock() if now is None else now
        with self.database.transaction() as connection:
            row = connection.execute(
                "SELECT * FROM private_event_shares WHERE token_hash=?", (token_hash,)
            ).fetchone()
            if row is None:
                raise ApiError("share_unavailable", 404)
            scope = row["core_id"], row["home_id"], row["camera_id"], row["event_id"]
            _, shares = self._verified(connection, scope)
            share, token = shares[row["id"]]
            if (
                not hmac.compare_digest(token, access_token)
                or share.recipient_id != recipient_id
                or share.revoked_at is not None
                or share.expires_at <= timestamp
                or (share.access_mode == "one_time" and share.consumed_at is not None)
            ):
                raise ApiError("share_unavailable", 404)
            request_hash = self._fingerprint(
                b"access", _canonical([recipient_id, access_id, row["id"]])
            )
            replay = self._find_event(connection, scope, access_id)
            if replay is not None:
                if replay["action"] != "redeemed" or replay["recipient_id"] != recipient_id:
                    raise ApiError("share_unavailable", 404)
            else:
                state = self._state(connection, scope)
                if state is None or state["event_count"] >= MAX_EVENTS:
                    raise ApiError("share_unavailable", 404)
                self._insert_event(
                    connection, scope=scope, state=state, base_revision=state["base_revision"],
                    command_id=access_id, action="redeemed", actor_id=recipient_id,
                    recipient_id=recipient_id, share_id=share.id,
                    request_hash=request_hash, occurred_at=timestamp,
                )
            return {
                "shareId": share.id,
                "outputArtifactId": share.output_artifact_id,
                "outputDigest": share.output_digest,
                "expiresAt": share.expires_at,
            }

    def revoke(
        self,
        actor: Principal,
        *,
        command_bytes: bytes,
        authority: EventShareAuthority,
    ) -> EventShareReceipt:
        self._authorize(actor, authority, write=True)
        fields = {
            "action", "commandId", "coreId", "homeId", "accountId", "sessionId",
            "coreRevision", "homeRevision", "accountRevision", "membersRevision",
            "cameraId", "cameraRevision", "eventId", "eventRevision", "sessionRevision",
            "expectedShareRevision", "shareId",
        }
        value = self._parse(command_bytes, fields)
        self._check_scope(value, authority)
        if value["action"] != "revoke" or not _identifier(value["commandId"]) or not _identifier(value["shareId"]):
            raise ApiError("invalid_request", 400)
        request_hash = self._fingerprint(b"request", command_bytes)
        scope = self._scope(authority)
        with self.database.transaction() as connection:
            _, shares = self._verified(connection, scope)
            replay = self._find_event(connection, scope, value["commandId"])
            if replay is not None:
                if replay["action"] != "revoked" or not hmac.compare_digest(replay["request_hash"], request_hash):
                    raise ApiError("idempotency_conflict", 409)
                share, _ = shares[replay["share_id"]]
                return EventShareReceipt(
                    replay["audit_id"], value["commandId"], "revoked",
                    replay["share_revision"], share, "",
                )
            state = self._state(connection, scope)
            if state is None or state["revision"] != authority.share_revision:
                raise ApiError("authority_changed", 409)
            pair = shares.get(value["shareId"])
            if pair is None:
                raise ApiError("not_found", 404)
            share, token = pair
            if actor.role != "admin" and share.owner_id != actor.id:
                raise ApiError("forbidden", 403)
            if share.revoked_at is not None:
                raise ApiError("share_unavailable", 409)
            now = self._clock()
            audit_id, revision = self._insert_event(
                connection, scope=scope, state=state, base_revision=state["base_revision"],
                command_id=value["commandId"], action="revoked", actor_id=actor.id,
                recipient_id=share.recipient_id, share_id=share.id,
                request_hash=request_hash, occurred_at=now,
            )
            revoked = PrivateEventShare(**{**share.__dict__, "revoked_at": now})
            return EventShareReceipt(
                audit_id, value["commandId"], "revoked", revision, revoked, ""
            )

    def export(self, actor: Principal, *, authority: EventShareAuthority, limit: int) -> dict:
        self._authorize(actor, authority, write=False)
        if type(limit) is not int or not 1 <= limit <= MAX_EXPORT:
            raise ApiError("invalid_request", 400)
        scope = self._scope(authority)
        with self.database.connection() as connection:
            connection.execute("BEGIN")
            try:
                _, shares = self._verified(connection, scope)
                state = self._state(connection, scope)
                current = authority.share_revision if state is None else state["revision"]
                if current != authority.share_revision:
                    raise ApiError("authority_changed", 409)
                visible = [pair[0] for pair in shares.values() if actor.role == "admin" or pair[0].owner_id == actor.id]
                if actor.role != "admin" and not authority.can_share:
                    raise ApiError("forbidden", 403)
                if len(visible) > limit:
                    raise ApiError("private_event_share_export_limit_reached", 413)
                return {
                    "schemaVersion": 1,
                    "coreId": authority.core_id,
                    "homeId": authority.home_id,
                    "cameraId": authority.camera_id,
                    "eventId": authority.event_id,
                    "shareRevision": current,
                    "shares": [
                        {
                            "id": share.id,
                            "recipientId": share.recipient_id,
                            "purpose": share.purpose,
                            "accessMode": share.access_mode,
                            "expiresAt": share.expires_at,
                            "outputArtifactId": share.output_artifact_id,
                            "outputDigest": share.output_digest,
                            "pipelineId": share.pipeline_id,
                            "pipelineRevision": share.pipeline_revision,
                            "maskTypes": list(share.mask_types),
                            "removedMetadata": list(share.removed_metadata),
                            "revoked": share.revoked_at is not None,
                            "consumed": share.consumed_at is not None,
                        }
                        for share in visible
                    ],
                }
            finally:
                connection.rollback()
