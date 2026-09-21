import hashlib
import hmac
import json
import os
import sqlite3
import time
import uuid
from dataclasses import asdict, dataclass
from datetime import UTC, datetime, timedelta
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..auth import Principal
from ..database import Database
from ..errors import ApiError, StartupError

MAX_COMMAND_BYTES = 16_384
MAX_OCCURRENCES = 64
MAX_RECURRENCE_DAYS = 366
MAX_RESERVATIONS = 1_000
MAX_WINDOW_DAYS = 93
MAX_READ_LIMIT = 256
MAX_CAPACITY = 64
MAX_DURATION_SECONDS = 86_400


def _identifier(value: object) -> bool:
    return isinstance(value, str) and 1 <= len(value) <= 128 and all(
        character.isalnum() or character in "-_.:" for character in value
    )


def _positive_revision(value: object) -> bool:
    return type(value) is int and value > 0


@dataclass(frozen=True)
class ResourceRule:
    id: str
    revision: int
    capacity: int
    timezone: str
    member_ids: tuple[str, ...]

    def __post_init__(self) -> None:
        try:
            ZoneInfo(self.timezone)
        except (TypeError, ZoneInfoNotFoundError):
            raise ValueError("invalid_resource_rule") from None
        if (
            not _identifier(self.id)
            or not isinstance(self.timezone, str)
            or len(self.timezone) > 128
            or not _positive_revision(self.revision)
            or type(self.capacity) is not int
            or not 1 <= self.capacity <= MAX_CAPACITY
            or not isinstance(self.member_ids, tuple)
            or not 1 <= len(self.member_ids) <= 128
            or len(set(self.member_ids)) != len(self.member_ids)
            or any(not _identifier(item) for item in self.member_ids)
        ):
            raise ValueError("invalid_resource_rule")


@dataclass(frozen=True)
class ReservationAuthority:
    core_id: str
    home_id: str
    account_id: str
    core_revision: int
    home_revision: int
    account_revision: int
    members_revision: int
    calendar_revision: int
    member_ids: tuple[str, ...]
    resource: ResourceRule

    def __post_init__(self) -> None:
        if (
            any(not _identifier(item) for item in (self.core_id, self.home_id, self.account_id))
            or any(not _positive_revision(item) for item in (
                self.core_revision,
                self.home_revision,
                self.account_revision,
                self.members_revision,
                self.calendar_revision,
            ))
            or not isinstance(self.member_ids, tuple)
            or not 1 <= len(self.member_ids) <= 128
            or len(set(self.member_ids)) != len(self.member_ids)
            or any(not _identifier(item) for item in self.member_ids)
            or not isinstance(self.resource, ResourceRule)
            or any(item not in self.member_ids for item in self.resource.member_ids)
        ):
            raise ValueError("invalid_reservation_authority")


@dataclass(frozen=True)
class Occurrence:
    start_utc: str
    end_utc: str


@dataclass(frozen=True)
class Reservation:
    id: str
    revision: int
    owner_id: str
    resource_id: str
    timezone: str
    local_start: str
    duration_seconds: int
    units: int
    occurrences: tuple[Occurrence, ...]
    created_at: float
    cancelled_at: float | None = None


@dataclass(frozen=True)
class ReservationReceipt:
    event_id: str
    command_id: str
    action: str
    calendar_revision: int
    reservation: Reservation


@dataclass(frozen=True)
class ReservationEvent:
    event_id: str
    action: str
    actor_id: str
    reservation_id: str
    calendar_revision: int
    occurred_at: float


class ReservationStore:
    """Serial, encrypted reservation calendar with a keyed audit chain."""

    def __init__(self, database: Database, *, encryption_key: bytes, audit_key: bytes):
        if (
            not isinstance(encryption_key, bytes)
            or len(encryption_key) != 32
            or not isinstance(audit_key, bytes)
            or len(audit_key) != 32
        ):
            raise ValueError("invalid_resource_reservation_keys")
        self.database = database
        self._cipher = AESGCM(encryption_key)
        self._audit_key = audit_key

    @staticmethod
    def _canonical(value: object) -> bytes:
        return json.dumps(
            value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
        ).encode()

    @staticmethod
    def _authorize(actor: Principal, authority: ReservationAuthority) -> None:
        if actor.id != authority.account_id:
            raise ApiError("authority_changed", 409)
        if actor.role != "admin" and (
            actor.id not in authority.member_ids
            or actor.id not in authority.resource.member_ids
        ):
            raise ApiError("forbidden", 403)

    @staticmethod
    def _parse(command_bytes: bytes, expected_fields: set[str]) -> dict:
        if not isinstance(command_bytes, bytes) or not 1 <= len(command_bytes) <= MAX_COMMAND_BYTES:
            raise ApiError("invalid_request", 400)

        def unique(pairs: list[tuple[str, object]]) -> dict:
            result = {}
            for key, value in pairs:
                if key in result:
                    raise ValueError("duplicate_key")
                result[key] = value
            return result

        try:
            value = json.loads(command_bytes.decode("utf-8"), object_pairs_hook=unique)
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
            raise ApiError("invalid_request", 400) from None
        if not isinstance(value, dict) or set(value) != expected_fields:
            raise ApiError("invalid_request", 400)
        return value

    @staticmethod
    def _check_scope(value: dict, authority: ReservationAuthority) -> None:
        expected = {
            "coreId": authority.core_id,
            "homeId": authority.home_id,
            "accountId": authority.account_id,
            "coreRevision": authority.core_revision,
            "homeRevision": authority.home_revision,
            "accountRevision": authority.account_revision,
            "membersRevision": authority.members_revision,
            "resourceId": authority.resource.id,
            "resourceRevision": authority.resource.revision,
            "expectedCalendarRevision": authority.calendar_revision,
        }
        if any(
            type(value.get(key)) is not type(expected_value)
            or value.get(key) != expected_value
            for key, expected_value in expected.items()
        ):
            raise ApiError("authority_changed", 409)

    @staticmethod
    def _utc_text(value: datetime) -> str:
        return value.astimezone(UTC).replace(tzinfo=None).isoformat(timespec="seconds") + "Z"

    @classmethod
    def _utc_value(cls, value: str) -> datetime:
        if not isinstance(value, str) or not value.endswith("Z"):
            raise ApiError("invalid_request", 400)
        try:
            parsed = datetime.fromisoformat(value[:-1])
        except ValueError:
            raise ApiError("invalid_request", 400) from None
        if (
            parsed.tzinfo is not None
            or parsed.microsecond
            or parsed.isoformat(timespec="seconds") != value[:-1]
        ):
            raise ApiError("invalid_request", 400)
        return parsed.replace(tzinfo=UTC)

    @classmethod
    def _local_occurrences(cls, value: dict, rule: ResourceRule) -> tuple[Occurrence, ...]:
        if (
            value.get("timezone") != rule.timezone
            or type(value.get("durationSeconds")) is not int
            or not 60 <= value["durationSeconds"] <= MAX_DURATION_SECONDS
            or type(value.get("units")) is not int
            or not 1 <= value["units"] <= rule.capacity
            or not isinstance(value.get("recurrence"), dict)
            or set(value["recurrence"]) != {"frequency", "count"}
        ):
            raise ApiError("invalid_request", 400)
        frequency = value["recurrence"]["frequency"]
        count = value["recurrence"]["count"]
        if frequency not in ("none", "daily", "weekly") or type(count) is not int:
            raise ApiError("invalid_request", 400)
        if not 1 <= count <= MAX_OCCURRENCES or (frequency == "none" and count != 1):
            raise ApiError("invalid_request", 400)
        try:
            local_start = datetime.fromisoformat(value["localStart"])
        except (TypeError, ValueError):
            raise ApiError("invalid_request", 400) from None
        if (
            local_start.tzinfo is not None
            or local_start.microsecond
            or not 1970 <= local_start.year <= 2100
        ):
            raise ApiError("invalid_request", 400)
        step = {"none": timedelta(0), "daily": timedelta(days=1), "weekly": timedelta(days=7)}[frequency]
        if count > 1 and step * (count - 1) > timedelta(days=MAX_RECURRENCE_DAYS):
            raise ApiError("invalid_request", 400)
        fold = value.get("fold")
        if fold is not None and type(fold) is not int:
            raise ApiError("invalid_request", 400)
        zone = ZoneInfo(rule.timezone)
        occurrences = []
        for index in range(count):
            local = local_start + step * index
            first = local.replace(tzinfo=zone, fold=0)
            second = local.replace(tzinfo=zone, fold=1)
            ambiguous = first.utcoffset() != second.utcoffset()
            if ambiguous:
                if fold not in (0, 1):
                    raise ApiError("invalid_local_time", 400)
                candidate = local.replace(tzinfo=zone, fold=fold)
            else:
                if fold not in (None, 0):
                    raise ApiError("invalid_local_time", 400)
                candidate = first
            back = candidate.astimezone(UTC).astimezone(zone)
            if back.replace(tzinfo=None) != local or (ambiguous and back.fold != fold):
                raise ApiError("invalid_local_time", 400)
            start = candidate.astimezone(UTC)
            end = start + timedelta(seconds=value["durationSeconds"])
            occurrences.append(Occurrence(cls._utc_text(start), cls._utc_text(end)))
        return tuple(occurrences)

    def _state_hash(self, row_values: tuple[object, ...]) -> str:
        return hmac.new(
            self._audit_key,
            b"larenor-resource-reservation-state-v1\0" + self._canonical(row_values),
            hashlib.sha256,
        ).hexdigest()

    def _event_hash(self, row_values: tuple[object, ...]) -> str:
        return hmac.new(
            self._audit_key,
            b"larenor-resource-reservation-event-v1\0" + self._canonical(row_values),
            hashlib.sha256,
        ).hexdigest()

    def _fingerprint(self, domain: bytes, value: bytes) -> str:
        return hmac.new(
            self._audit_key,
            b"larenor-resource-reservation-" + domain + b"-v1\0" + value,
            hashlib.sha256,
        ).hexdigest()

    def _state(self, connection: sqlite3.Connection, authority: ReservationAuthority) -> sqlite3.Row | None:
        row = connection.execute(
            "SELECT * FROM resource_reservation_state WHERE core_id=? AND home_id=? AND resource_id=?",
            (authority.core_id, authority.home_id, authority.resource.id),
        ).fetchone()
        if row is not None:
            values = (
                row["core_id"], row["home_id"], row["resource_id"], row["base_revision"],
                row["revision"], row["event_count"], row["last_hash"],
            )
            if not hmac.compare_digest(row["state_hash"], self._state_hash(values)):
                raise StartupError("resource_reservation_history_invalid")
        return row

    def _decrypt(self, row: sqlite3.Row, cancelled_at: float | None = None) -> Reservation:
        try:
            aad = f'{row["core_id"]}\0{row["home_id"]}\0{row["resource_id"]}\0{row["id"]}'.encode()
            raw = self._cipher.decrypt(row["nonce"], row["ciphertext"], aad)
            if not hmac.compare_digest(
                self._fingerprint(b"payload", raw), row["payload_hash"]
            ):
                raise ValueError
            value = json.loads(raw)
            occurrences = tuple(Occurrence(**item) for item in value.pop("occurrences"))
            result = Reservation(
                id=row["id"], revision=row["revision"], occurrences=occurrences,
                cancelled_at=cancelled_at, **value,
            )
            if not occurrences or result.resource_id != row["resource_id"]:
                raise ValueError
            return result
        except (InvalidTag, KeyError, TypeError, ValueError, json.JSONDecodeError):
            raise StartupError("resource_reservation_storage_invalid") from None

    def _verified(
        self, connection: sqlite3.Connection, authority: ReservationAuthority,
    ) -> tuple[tuple[ReservationEvent, ...], dict[str, Reservation]]:
        state = self._state(connection, authority)
        rows = connection.execute(
            "SELECT * FROM resource_reservation_events WHERE core_id=? AND home_id=? "
            "AND resource_id=? ORDER BY sequence",
            (authority.core_id, authority.home_id, authority.resource.id),
        ).fetchall()
        records = connection.execute(
            "SELECT * FROM resource_reservations WHERE core_id=? AND home_id=? "
            "AND resource_id=? ORDER BY created_at,id",
            (authority.core_id, authority.home_id, authority.resource.id),
        ).fetchall()
        if state is None:
            if rows or records:
                raise StartupError("resource_reservation_history_invalid")
            return (), {}
        previous = ""
        events = []
        creates: set[str] = set()
        cancellations: dict[str, float] = {}
        for row in rows:
            values = (
                row["sequence"], row["event_id"], row["core_id"], row["home_id"],
                row["resource_id"], row["command_id"], row["action"], row["actor_id"],
                row["reservation_id"], row["calendar_revision"], row["occurred_at"],
                row["request_hash"], row["previous_hash"],
            )
            if row["previous_hash"] != previous or not hmac.compare_digest(
                row["event_hash"], self._event_hash(values)
            ):
                raise StartupError("resource_reservation_history_invalid")
            if row["action"] == "created":
                if row["reservation_id"] in creates:
                    raise StartupError("resource_reservation_history_invalid")
                creates.add(row["reservation_id"])
            else:
                if row["reservation_id"] not in creates or row["reservation_id"] in cancellations:
                    raise StartupError("resource_reservation_history_invalid")
                cancellations[row["reservation_id"]] = row["occurred_at"]
            events.append(ReservationEvent(
                row["event_id"], row["action"], row["actor_id"], row["reservation_id"],
                row["calendar_revision"], row["occurred_at"],
            ))
            previous = row["event_hash"]
        reservation_map = {
            row["id"]: self._decrypt(row, cancellations.get(row["id"])) for row in records
        }
        if (
            set(reservation_map) != creates
            or len(rows) != state["event_count"]
            or state["revision"] != state["base_revision"] + len(rows)
            or state["last_hash"] != previous
        ):
            raise StartupError("resource_reservation_history_invalid")
        for row in records:
            create = next((item for item in rows if item["action"] == "created" and item["reservation_id"] == row["id"]), None)
            if create is None or not hmac.compare_digest(create["request_hash"], row["request_hash"]):
                raise StartupError("resource_reservation_history_invalid")
        return tuple(events), reservation_map

    @staticmethod
    def _event_row_values(
        sequence: int,
        event_id: str,
        authority: ReservationAuthority,
        command_id: str,
        action: str,
        actor_id: str,
        reservation_id: str,
        calendar_revision: int,
        occurred_at: float,
        request_hash: str,
        previous_hash: str,
    ) -> tuple[object, ...]:
        return (
            sequence, event_id, authority.core_id, authority.home_id, authority.resource.id,
            command_id, action, actor_id, reservation_id, calendar_revision, occurred_at,
            request_hash, previous_hash,
        )

    def _insert_event(
        self,
        connection: sqlite3.Connection,
        *,
        authority: ReservationAuthority,
        state: sqlite3.Row | None,
        command_id: str,
        action: str,
        actor_id: str,
        reservation_id: str,
        request_hash: str,
        now: float,
    ) -> tuple[str, int]:
        base_revision = authority.calendar_revision if state is None else state["base_revision"]
        current_revision = base_revision if state is None else state["revision"]
        event_count = 0 if state is None else state["event_count"]
        previous_hash = "" if state is None else state["last_hash"]
        sequence = connection.execute(
            "SELECT COALESCE(MAX(sequence),0)+1 FROM resource_reservation_events"
        ).fetchone()[0]
        event_id = uuid.uuid4().hex
        revision = current_revision + 1
        values = self._event_row_values(
            sequence, event_id, authority, command_id, action, actor_id,
            reservation_id, revision, now, request_hash, previous_hash,
        )
        event_hash = self._event_hash(values)
        connection.execute(
            "INSERT INTO resource_reservation_events VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            values + (event_hash,),
        )
        state_values = (
            authority.core_id, authority.home_id, authority.resource.id, base_revision,
            revision, event_count + 1, event_hash,
        )
        connection.execute(
            "INSERT INTO resource_reservation_state VALUES(?,?,?,?,?,?,?,?) "
            "ON CONFLICT(core_id,home_id,resource_id) DO UPDATE SET "
            "revision=excluded.revision,event_count=excluded.event_count,"
            "last_hash=excluded.last_hash,state_hash=excluded.state_hash",
            state_values + (self._state_hash(state_values),),
        )
        return event_id, revision

    @staticmethod
    def _find_replay(
        connection: sqlite3.Connection,
        authority: ReservationAuthority,
        command_id: str,
    ) -> sqlite3.Row | None:
        return connection.execute(
            "SELECT * FROM resource_reservation_events WHERE core_id=? AND home_id=? "
            "AND resource_id=? AND command_id=?",
            (authority.core_id, authority.home_id, authority.resource.id, command_id),
        ).fetchone()

    def _receipt(
        self,
        replay: sqlite3.Row,
        reservation: Reservation,
    ) -> ReservationReceipt:
        return ReservationReceipt(
            replay["event_id"], replay["command_id"], replay["action"],
            replay["calendar_revision"], reservation,
        )

    def receipt(
        self,
        actor: Principal,
        *,
        authority: ReservationAuthority,
        command_id: str,
    ) -> ReservationReceipt | None:
        """Read one actor-owned command result without replaying its mutation."""
        self._authorize(actor, authority)
        if not _identifier(command_id):
            raise ApiError("invalid_request", 400)
        with self.database.connection() as connection:
            connection.execute("BEGIN")
            try:
                _, reservations = self._verified(connection, authority)
                state = self._state(connection, authority)
                revision = authority.calendar_revision if state is None else state["revision"]
                if revision != authority.calendar_revision:
                    raise ApiError("authority_changed", 409)
                replay = self._find_replay(connection, authority, command_id)
                if replay is None:
                    return None
                if replay["actor_id"] != actor.id:
                    raise ApiError("not_found", 404)
                reservation = reservations.get(replay["reservation_id"])
                if reservation is None:
                    raise StartupError("resource_reservation_history_invalid")
                return self._receipt(replay, reservation)
            finally:
                connection.rollback()

    def create(
        self,
        actor: Principal,
        *,
        command_bytes: bytes,
        authority: ReservationAuthority,
    ) -> ReservationReceipt:
        self._authorize(actor, authority)
        fields = {
            "action", "commandId", "coreId", "homeId", "accountId", "coreRevision",
            "homeRevision", "accountRevision", "membersRevision", "resourceId",
            "resourceRevision", "expectedCalendarRevision", "timezone", "localStart",
            "fold", "durationSeconds", "units", "recurrence",
        }
        value = self._parse(command_bytes, fields)
        self._check_scope(value, authority)
        if value["action"] != "create" or not _identifier(value["commandId"]):
            raise ApiError("invalid_request", 400)
        occurrences = self._local_occurrences(value, authority.resource)
        request_hash = self._fingerprint(b"request", command_bytes)
        with self.database.transaction() as connection:
            _, reservations = self._verified(connection, authority)
            replay = self._find_replay(connection, authority, value["commandId"])
            if replay is not None:
                if (
                    replay["action"] != "created"
                    or replay["actor_id"] != actor.id
                    or not hmac.compare_digest(replay["request_hash"], request_hash)
                ):
                    raise ApiError("idempotency_conflict", 409)
                return self._receipt(replay, reservations[replay["reservation_id"]])
            state = self._state(connection, authority)
            current_revision = authority.calendar_revision if state is None else state["revision"]
            if authority.calendar_revision != current_revision:
                raise ApiError("authority_changed", 409)
            if len(reservations) >= MAX_RESERVATIONS:
                raise ApiError("reservation_limit_reached", 413)
            proposed = [
                (self._utc_value(item.start_utc), self._utc_value(item.end_utc))
                for item in occurrences
            ]
            existing = [
                (self._utc_value(item.start_utc), self._utc_value(item.end_utc), reservation.units)
                for reservation in reservations.values()
                if reservation.cancelled_at is None
                for item in reservation.occurrences
            ]
            for index, (start, end) in enumerate(proposed):
                used = value["units"]
                used += sum(
                    units
                    for old_start, old_end, units in existing
                    if start < old_end and old_start < end
                )
                used += sum(
                    value["units"]
                    for other_index, (other_start, other_end) in enumerate(proposed)
                    if other_index != index
                    and start < other_end
                    and other_start < end
                )
                if used > authority.resource.capacity:
                    raise ApiError("reservation_overlap", 409)
            now = time.time()
            reservation_id = uuid.uuid4().hex
            payload = {
                "owner_id": actor.id,
                "resource_id": authority.resource.id,
                "timezone": authority.resource.timezone,
                "local_start": value["localStart"],
                "duration_seconds": value["durationSeconds"],
                "units": value["units"],
                "occurrences": [asdict(item) for item in occurrences],
                "created_at": now,
            }
            raw = self._canonical(payload)
            nonce = os.urandom(12)
            aad = f"{authority.core_id}\0{authority.home_id}\0{authority.resource.id}\0{reservation_id}".encode()
            connection.execute(
                "INSERT INTO resource_reservations VALUES(?,?,?,?,?,?,?,?,?,?)",
                (
                    reservation_id, authority.core_id, authority.home_id,
                    authority.resource.id, 1, nonce, self._cipher.encrypt(nonce, raw, aad),
                    self._fingerprint(b"payload", raw), request_hash, now,
                ),
            )
            event_id, revision = self._insert_event(
                connection,
                authority=authority,
                state=state,
                command_id=value["commandId"],
                action="created",
                actor_id=actor.id,
                reservation_id=reservation_id,
                request_hash=request_hash,
                now=now,
            )
            return ReservationReceipt(
                event_id, value["commandId"], "created", revision,
                Reservation(
                    reservation_id,
                    1,
                    actor.id,
                    authority.resource.id,
                    authority.resource.timezone,
                    value["localStart"],
                    value["durationSeconds"],
                    value["units"],
                    occurrences,
                    now,
                ),
            )

    def cancel(
        self,
        actor: Principal,
        *,
        command_bytes: bytes,
        authority: ReservationAuthority,
    ) -> ReservationReceipt:
        self._authorize(actor, authority)
        fields = {
            "action", "commandId", "coreId", "homeId", "accountId", "coreRevision",
            "homeRevision", "accountRevision", "membersRevision", "resourceId",
            "resourceRevision", "expectedCalendarRevision", "reservationId",
        }
        value = self._parse(command_bytes, fields)
        self._check_scope(value, authority)
        if (
            value["action"] != "cancel"
            or not _identifier(value["commandId"])
            or not _identifier(value["reservationId"])
        ):
            raise ApiError("invalid_request", 400)
        request_hash = self._fingerprint(b"request", command_bytes)
        with self.database.transaction() as connection:
            _, reservations = self._verified(connection, authority)
            replay = self._find_replay(connection, authority, value["commandId"])
            if replay is not None:
                if (
                    replay["action"] != "cancelled"
                    or replay["actor_id"] != actor.id
                    or replay["reservation_id"] != value["reservationId"]
                    or not hmac.compare_digest(replay["request_hash"], request_hash)
                ):
                    raise ApiError("idempotency_conflict", 409)
                return self._receipt(replay, reservations[replay["reservation_id"]])
            state = self._state(connection, authority)
            if state is None or authority.calendar_revision != state["revision"]:
                raise ApiError("authority_changed", 409)
            reservation = reservations.get(value["reservationId"])
            if reservation is None:
                raise ApiError("not_found", 404)
            if reservation.cancelled_at is not None:
                raise ApiError("reservation_already_cancelled", 409)
            if actor.role != "admin" and reservation.owner_id != actor.id:
                raise ApiError("forbidden", 403)
            now = time.time()
            event_id, revision = self._insert_event(
                connection,
                authority=authority,
                state=state,
                command_id=value["commandId"],
                action="cancelled",
                actor_id=actor.id,
                reservation_id=reservation.id,
                request_hash=request_hash,
                now=now,
            )
            return ReservationReceipt(
                event_id, value["commandId"], "cancelled", revision,
                Reservation(**{**reservation.__dict__, "cancelled_at": now}),
            )

    def _read(
        self, actor: Principal, authority: ReservationAuthority,
    ) -> tuple[int, tuple[ReservationEvent, ...], dict[str, Reservation]]:
        self._authorize(actor, authority)
        with self.database.connection() as connection:
            connection.execute("BEGIN")
            try:
                events, reservations = self._verified(connection, authority)
                state = self._state(connection, authority)
                revision = (
                    authority.calendar_revision if state is None else state["revision"]
                )
                if revision != authority.calendar_revision:
                    raise ApiError("authority_changed", 409)
                return revision, events, reservations
            finally:
                connection.rollback()

    def history(
        self,
        actor: Principal,
        *,
        authority: ReservationAuthority,
        limit: int,
    ) -> tuple[ReservationEvent, ...]:
        if type(limit) is not int or not 1 <= limit <= MAX_READ_LIMIT:
            raise ApiError("invalid_request", 400)
        _, events, _ = self._read(actor, authority)
        return events[-limit:]

    def availability(
        self,
        actor: Principal,
        *,
        authority: ReservationAuthority,
        start_utc: str,
        end_utc: str,
        limit: int,
    ) -> dict:
        if type(limit) is not int or not 1 <= limit <= MAX_READ_LIMIT:
            raise ApiError("invalid_request", 400)
        start, end = self._utc_value(start_utc), self._utc_value(end_utc)
        if start >= end or end - start > timedelta(days=MAX_WINDOW_DAYS):
            raise ApiError("invalid_request", 400)
        revision, _, reservations = self._read(actor, authority)
        busy = []
        for reservation in reservations.values():
            if reservation.cancelled_at is not None:
                continue
            for occurrence in reservation.occurrences:
                occurrence_start = self._utc_value(occurrence.start_utc)
                occurrence_end = self._utc_value(occurrence.end_utc)
                if occurrence_start < end and start < occurrence_end:
                    busy.append({
                        "startUtc": occurrence.start_utc,
                        "endUtc": occurrence.end_utc,
                        "units": reservation.units,
                    })
        busy.sort(key=lambda item: (item["startUtc"], item["endUtc"], item["units"]))
        if len(busy) > limit:
            raise ApiError("availability_limit_reached", 413)
        return {
            "calendarRevision": revision,
            "window": {"startUtc": start_utc, "endUtc": end_utc},
            "busy": busy,
        }

    def export(
        self,
        actor: Principal,
        *,
        authority: ReservationAuthority,
        limit: int,
    ) -> dict:
        if type(limit) is not int or not 1 <= limit <= MAX_READ_LIMIT:
            raise ApiError("invalid_request", 400)
        revision, _, reservations = self._read(actor, authority)
        rows = sorted(reservations.values(), key=lambda item: (item.created_at, item.id))
        if len(rows) > limit:
            raise ApiError("reservation_export_limit_reached", 413)
        return {
            "schemaVersion": 1,
            "coreId": authority.core_id,
            "homeId": authority.home_id,
            "resourceId": authority.resource.id,
            "calendarRevision": revision,
            "reservations": [
                {
                    "id": item.id,
                    "ownerId": item.owner_id,
                    "timezone": item.timezone,
                    "localStart": item.local_start,
                    "durationSeconds": item.duration_seconds,
                    "units": item.units,
                    "occurrences": [
                        {"startUtc": occurrence.start_utc, "endUtc": occurrence.end_utc}
                        for occurrence in item.occurrences
                    ],
                    "cancelled": item.cancelled_at is not None,
                }
                for item in rows
            ],
        }
