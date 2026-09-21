from dataclasses import asdict, dataclass
import hashlib
import hmac
import json
import math
import sqlite3
import time
import uuid
from collections.abc import Callable

from ..auth import Principal
from ..database import Database
from ..errors import ApiError, StartupError


MAX_FLOORS = 8
MAX_ROOMS = 128
MAX_ANCHORS = 512
MAX_VECTORS = 512
MAX_POINTS = 4_096
MAX_REQUESTS = 512
MAX_HISTORY = 1_024
MAX_STATE_AGE_SECONDS = 300
ENTITY_STATES = {"on", "off", "open", "closed", "playing", "idle", "unavailable"}


def _canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def _identifier(value: object) -> bool:
    return isinstance(value, str) and 1 <= len(value) <= 128 and all(
        character.isalnum() or character in "-_.:" for character in value
    )


def _revision(value: object, *, allow_zero: bool = False) -> bool:
    return type(value) is int and value >= (0 if allow_zero else 1)


def _label(value: object) -> bool:
    return isinstance(value, str) and 1 <= len(value) <= 80 and all(
        ord(character) >= 32 for character in value
    )


def _coordinate(value: object) -> bool:
    return type(value) in (int, float) and math.isfinite(value) and 0 <= value <= 1


@dataclass(frozen=True)
class FloorPlanAuthority:
    core_id: str
    home_id: str
    account_id: str
    session_id: str
    core_revision: int
    home_revision: int
    account_revision: int
    layout_revision: int
    entity_registry_revision: int
    resource_revision: int
    grant_revision: int
    can_read: bool
    can_edit: bool

    def __post_init__(self) -> None:
        if (
            any(not _identifier(item) for item in (
                self.core_id, self.home_id, self.account_id, self.session_id,
            ))
            or any(not _revision(item) for item in (
                self.core_revision, self.home_revision, self.account_revision,
                self.entity_registry_revision, self.resource_revision,
                self.grant_revision,
            ))
            or not _revision(self.layout_revision, allow_zero=True)
            or type(self.can_read) is not bool
            or type(self.can_edit) is not bool
        ):
            raise ValueError("invalid_floor_plan_authority")


@dataclass(frozen=True)
class Point:
    x: float
    y: float


@dataclass(frozen=True)
class Floor:
    floor_id: str
    label: str
    order: int


@dataclass(frozen=True)
class Room:
    room_id: str
    floor_id: str
    label: str
    polygon: tuple[Point, ...]


@dataclass(frozen=True)
class Anchor:
    anchor_id: str
    room_id: str
    target_kind: str
    target_id: str
    target_revision: int
    x: float
    y: float
    rotation: float


@dataclass(frozen=True)
class VectorShape:
    shape_id: str
    floor_id: str
    kind: str
    points: tuple[Point, ...]


@dataclass(frozen=True)
class FloorPlanLayout:
    floors: tuple[Floor, ...]
    rooms: tuple[Room, ...]
    anchors: tuple[Anchor, ...]
    vectors: tuple[VectorShape, ...]


@dataclass(frozen=True)
class LayoutReceipt:
    request_id: str
    revision: int
    status: str = "saved"


@dataclass(frozen=True)
class StoredLayout:
    revision: int
    layout: FloorPlanLayout


@dataclass(frozen=True)
class EntitySnapshot:
    entity_id: str
    entity_revision: int
    registry_revision: int
    source_status: str
    state: str
    observed_at: float


@dataclass(frozen=True)
class EntityProjection:
    entity_id: str
    entity_revision: int
    state: str
    status: str


class FloorPlanService:
    def __init__(
        self,
        database: Database,
        *,
        audit_key: bytes,
        clock: Callable[[], float] = time.time,
    ):
        if not isinstance(audit_key, bytes) or len(audit_key) != 32:
            raise ValueError("invalid_floor_plan_audit_key")
        self.database = database
        self._audit_key = audit_key
        self._clock = clock

    def _fingerprint(self, domain: bytes, value: bytes) -> str:
        return hmac.new(
            self._audit_key,
            b"larenor-floor-plan-" + domain + b"-v1\0" + value,
            hashlib.sha256,
        ).hexdigest()

    @staticmethod
    def _authorize(
        actor: Principal, authority: FloorPlanAuthority, *, edit: bool,
    ) -> None:
        if actor.id != authority.account_id or actor.family_id != authority.session_id:
            raise ApiError("floor_plan_authority_changed", 409)
        allowed = authority.can_edit if edit else authority.can_read
        if not allowed:
            raise ApiError("forbidden", 403)

    @staticmethod
    def _scope(authority: FloorPlanAuthority) -> tuple[str, str]:
        return authority.core_id, authority.home_id

    def _state_hash(self, values: tuple[object, ...]) -> str:
        return self._fingerprint(b"state", _canonical(values))

    def _event_hash(self, values: tuple[object, ...]) -> str:
        return self._fingerprint(b"event", _canonical(values))

    def _record_hash(self, kind: bytes, values: tuple[object, ...]) -> str:
        return self._fingerprint(kind + b"-record", _canonical(values))

    def _verified_history(self, connection: sqlite3.Connection, scope):
        state = connection.execute(
            "SELECT * FROM floor_plan_audit_state WHERE core_id=? AND home_id=?",
            scope,
        ).fetchone()
        rows = connection.execute(
            "SELECT * FROM floor_plan_events WHERE core_id=? AND home_id=? "
            "ORDER BY sequence", scope,
        ).fetchall()
        if state is None:
            if rows:
                raise StartupError("floor_plan_audit_invalid")
        else:
            state_values = (*scope, state["event_count"], state["last_hash"])
            if not hmac.compare_digest(
                state["state_hash"], self._state_hash(state_values)
            ):
                raise StartupError("floor_plan_audit_invalid")
            previous = ""
            for row in rows:
                values = (
                    row["sequence"], row["audit_id"], row["core_id"],
                    row["home_id"], row["action"], row["actor_id"],
                    row["object_id"], row["layout_revision"],
                    row["occurred_at"], row["request_hash"],
                    row["previous_hash"],
                )
                if row["previous_hash"] != previous or not hmac.compare_digest(
                    row["event_hash"], self._event_hash(values)
                ):
                    raise StartupError("floor_plan_audit_invalid")
                previous = row["event_hash"]
            if len(rows) != state["event_count"] or previous != state["last_hash"]:
                raise StartupError("floor_plan_audit_invalid")
        records = (
            (
                "floor_plan_layouts",
                (
                    "core_id", "home_id", "account_id", "core_revision",
                    "home_revision", "revision", "entity_registry_revision",
                    "resource_revision", "payload", "updated_at",
                ),
                b"layout",
            ),
            (
                "floor_plan_requests",
                (
                    "request_id", "core_id", "home_id", "account_id", "session_id",
                    "request_hash", "result_revision", "created_at",
                ),
                b"request",
            ),
        )
        for table, fields, kind in records:
            found = connection.execute(
                f"SELECT * FROM {table} WHERE core_id=? AND home_id=?", scope
            ).fetchall()
            for record in found:
                values = tuple(record[field] for field in fields)
                if not hmac.compare_digest(
                    record["record_hash"], self._record_hash(kind, values)
                ):
                    raise StartupError("floor_plan_audit_invalid")
        return rows

    def _event(
        self, connection, *, scope, actor_id, request_id, revision,
        request_hash, occurred_at,
    ) -> None:
        rows = self._verified_history(connection, scope)
        if len(rows) >= MAX_HISTORY:
            raise ApiError("floor_plan_history_limit_reached", 413)
        previous = "" if not rows else rows[-1]["event_hash"]
        sequence = connection.execute(
            "SELECT COALESCE(MAX(sequence),0)+1 FROM floor_plan_events"
        ).fetchone()[0]
        values = (
            sequence, uuid.uuid4().hex, *scope, "layout_replaced", actor_id,
            request_id, revision, occurred_at, request_hash, previous,
        )
        event_hash = self._event_hash(values)
        connection.execute(
            "INSERT INTO floor_plan_events VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
            values + (event_hash,),
        )
        state_values = (*scope, len(rows) + 1, event_hash)
        connection.execute(
            "INSERT INTO floor_plan_audit_state VALUES(?,?,?,?,?) "
            "ON CONFLICT(core_id,home_id) DO UPDATE SET "
            "event_count=excluded.event_count,last_hash=excluded.last_hash,"
            "state_hash=excluded.state_hash",
            state_values + (self._state_hash(state_values),),
        )

    @staticmethod
    def _validate_layout(layout: FloorPlanLayout) -> None:
        if (
            not isinstance(layout, FloorPlanLayout)
            or not isinstance(layout.floors, tuple)
            or not 1 <= len(layout.floors) <= MAX_FLOORS
            or not isinstance(layout.rooms, tuple)
            or not 1 <= len(layout.rooms) <= MAX_ROOMS
            or not isinstance(layout.anchors, tuple)
            or len(layout.anchors) > MAX_ANCHORS
            or not isinstance(layout.vectors, tuple)
            or len(layout.vectors) > MAX_VECTORS
        ):
            raise ApiError("floor_plan_invalid", 400)
        floor_ids: set[str] = set()
        orders: set[int] = set()
        for floor in layout.floors:
            if (
                not _identifier(floor.floor_id)
                or floor.floor_id in floor_ids
                or not _label(floor.label)
                or type(floor.order) is not int
                or not 0 <= floor.order < MAX_FLOORS
                or floor.order in orders
            ):
                raise ApiError("floor_plan_invalid", 400)
            floor_ids.add(floor.floor_id)
            orders.add(floor.order)
        room_ids: set[str] = set()
        point_count = 0
        for room in layout.rooms:
            if (
                not _identifier(room.room_id)
                or room.room_id in room_ids
                or room.floor_id not in floor_ids
                or not _label(room.label)
                or not isinstance(room.polygon, tuple)
                or not 3 <= len(room.polygon) <= 64
                or any(not _coordinate(point.x) or not _coordinate(point.y)
                       for point in room.polygon)
            ):
                raise ApiError("floor_plan_invalid", 400)
            room_ids.add(room.room_id)
            point_count += len(room.polygon)
        anchor_ids: set[str] = set()
        targets: set[tuple[str, str]] = set()
        for anchor in layout.anchors:
            target = (anchor.target_kind, anchor.target_id)
            if (
                not _identifier(anchor.anchor_id)
                or anchor.anchor_id in anchor_ids
                or anchor.room_id not in room_ids
                or anchor.target_kind not in {"entity", "resource"}
                or not _identifier(anchor.target_id)
                or target in targets
                or not _revision(anchor.target_revision)
                or not _coordinate(anchor.x)
                or not _coordinate(anchor.y)
                or type(anchor.rotation) not in (int, float)
                or not math.isfinite(anchor.rotation)
                or not -360 <= anchor.rotation <= 360
            ):
                raise ApiError("floor_plan_invalid", 400)
            anchor_ids.add(anchor.anchor_id)
            targets.add(target)
        vector_ids: set[str] = set()
        for vector in layout.vectors:
            if (
                not _identifier(vector.shape_id)
                or vector.shape_id in vector_ids
                or vector.floor_id not in floor_ids
                or vector.kind not in {"wall", "door", "window", "path"}
                or not isinstance(vector.points, tuple)
                or not 2 <= len(vector.points) <= 128
                or any(not _coordinate(point.x) or not _coordinate(point.y)
                       for point in vector.points)
            ):
                raise ApiError("floor_plan_invalid", 400)
            vector_ids.add(vector.shape_id)
            point_count += len(vector.points)
        if point_count > MAX_POINTS:
            raise ApiError("floor_plan_invalid", 400)

    @staticmethod
    def _decode_layout(payload: str) -> FloorPlanLayout:
        try:
            value = json.loads(payload)
            return FloorPlanLayout(
                floors=tuple(Floor(**item) for item in value["floors"]),
                rooms=tuple(Room(
                    room_id=item["room_id"], floor_id=item["floor_id"],
                    label=item["label"],
                    polygon=tuple(Point(**point) for point in item["polygon"]),
                ) for item in value["rooms"]),
                anchors=tuple(Anchor(**item) for item in value["anchors"]),
                vectors=tuple(VectorShape(
                    shape_id=item["shape_id"], floor_id=item["floor_id"],
                    kind=item["kind"],
                    points=tuple(Point(**point) for point in item["points"]),
                ) for item in value["vectors"]),
            )
        except (KeyError, TypeError, ValueError, json.JSONDecodeError):
            raise StartupError("floor_plan_layout_invalid") from None

    def replace_layout(
        self,
        actor: Principal,
        *,
        authority: FloorPlanAuthority,
        request_id: str,
        expected_layout_revision: int,
        layout: FloorPlanLayout,
    ) -> LayoutReceipt:
        self._authorize(actor, authority, edit=True)
        if not _identifier(request_id) or not _revision(
            expected_layout_revision, allow_zero=True
        ):
            raise ApiError("invalid_request", 400)
        self._validate_layout(layout)
        request_hash = self._fingerprint(b"request", _canonical({
            "authority": asdict(authority),
            "expectedLayoutRevision": expected_layout_revision,
            "layout": asdict(layout),
        }))
        scope = self._scope(authority)
        now = self._clock()
        with self.database.transaction() as connection:
            self._verified_history(connection, scope)
            old_request = connection.execute(
                "SELECT * FROM floor_plan_requests WHERE request_id=?", (request_id,)
            ).fetchone()
            if old_request is not None:
                if (
                    (old_request["core_id"], old_request["home_id"]) != scope
                    or old_request["account_id"] != actor.id
                    or old_request["session_id"] != actor.family_id
                    or not hmac.compare_digest(old_request["request_hash"], request_hash)
                ):
                    raise ApiError("floor_plan_edit_conflict", 409)
                return LayoutReceipt(request_id, old_request["result_revision"])
            current = connection.execute(
                "SELECT * FROM floor_plan_layouts WHERE core_id=? AND home_id=?",
                scope,
            ).fetchone()
            current_revision = 0 if current is None else current["revision"]
            if (
                expected_layout_revision != authority.layout_revision
                or current_revision != expected_layout_revision
            ):
                raise ApiError("floor_plan_revision_changed", 409)
            count = connection.execute(
                "SELECT COUNT(*) FROM floor_plan_requests WHERE core_id=? AND home_id=?",
                scope,
            ).fetchone()[0]
            if count >= MAX_REQUESTS:
                raise ApiError("floor_plan_request_limit_reached", 413)
            revision = current_revision + 1
            payload = json.dumps(asdict(layout), sort_keys=True)
            layout_values = (
                *scope, actor.id, authority.core_revision, authority.home_revision,
                revision, authority.entity_registry_revision,
                authority.resource_revision, payload, now,
            )
            connection.execute(
                "INSERT INTO floor_plan_layouts VALUES(?,?,?,?,?,?,?,?,?,?,?) "
                "ON CONFLICT(core_id,home_id) DO UPDATE SET "
                "account_id=excluded.account_id,"
                "core_revision=excluded.core_revision,"
                "home_revision=excluded.home_revision,"
                "revision=excluded.revision,"
                "entity_registry_revision=excluded.entity_registry_revision,"
                "resource_revision=excluded.resource_revision,"
                "payload=excluded.payload,updated_at=excluded.updated_at,"
                "record_hash=excluded.record_hash",
                layout_values + (self._record_hash(b"layout", layout_values),),
            )
            request_values = (
                request_id, *scope, actor.id, actor.family_id, request_hash,
                revision, now,
            )
            connection.execute(
                "INSERT INTO floor_plan_requests VALUES(?,?,?,?,?,?,?,?,?)",
                request_values + (self._record_hash(b"request", request_values),),
            )
            self._event(
                connection, scope=scope, actor_id=actor.id, request_id=request_id,
                revision=revision, request_hash=request_hash, occurred_at=now,
            )
            return LayoutReceipt(request_id, revision)

    def read(
        self, actor: Principal, *, authority: FloorPlanAuthority,
    ) -> StoredLayout:
        self._authorize(actor, authority, edit=False)
        scope = self._scope(authority)
        with self.database.connection() as connection:
            connection.execute("BEGIN")
            try:
                self._verified_history(connection, scope)
                row = connection.execute(
                    "SELECT * FROM floor_plan_layouts WHERE core_id=? AND home_id=?",
                    scope,
                ).fetchone()
                if row is None:
                    raise ApiError("not_found", 404)
                if row["revision"] != authority.layout_revision:
                    raise ApiError("floor_plan_revision_changed", 409)
                if (
                    row["core_revision"] != authority.core_revision
                    or row["home_revision"] != authority.home_revision
                    or row["entity_registry_revision"]
                    != authority.entity_registry_revision
                    or row["resource_revision"] != authority.resource_revision
                ):
                    raise ApiError("floor_plan_authority_changed", 409)
                layout = self._decode_layout(row["payload"])
                self._validate_layout(layout)
                return StoredLayout(row["revision"], layout)
            finally:
                connection.rollback()

    def export(self, actor: Principal, *, authority: FloorPlanAuthority) -> dict:
        stored = self.read(actor, authority=authority)
        return {
            "formatVersion": 1,
            "homeId": authority.home_id,
            "layoutRevision": stored.revision,
            "entityRegistryRevision": authority.entity_registry_revision,
            "resourceRevision": authority.resource_revision,
            "layout": asdict(stored.layout),
        }

    def project_entities(
        self,
        actor: Principal,
        *,
        authority: FloorPlanAuthority,
        snapshots: tuple[EntitySnapshot, ...],
    ) -> tuple[EntityProjection, ...]:
        stored = self.read(actor, authority=authority)
        if not isinstance(snapshots, tuple) or len(snapshots) > MAX_ANCHORS:
            raise ApiError("floor_plan_projection_invalid", 400)
        anchors = {
            anchor.target_id: anchor for anchor in stored.layout.anchors
            if anchor.target_kind == "entity"
        }
        supplied: dict[str, EntitySnapshot] = {}
        now = self._clock()
        for snapshot in snapshots:
            if (
                not _identifier(snapshot.entity_id)
                or snapshot.entity_id not in anchors
                or snapshot.entity_id in supplied
                or not _revision(snapshot.entity_revision)
                or not _revision(snapshot.registry_revision)
                or snapshot.source_status not in {"verified", "stale", "unavailable"}
                or snapshot.state not in ENTITY_STATES
                or type(snapshot.observed_at) not in (int, float)
                or not math.isfinite(snapshot.observed_at)
                or snapshot.observed_at > now
            ):
                raise ApiError("floor_plan_projection_invalid", 400)
            anchor = anchors[snapshot.entity_id]
            if (
                snapshot.entity_revision != anchor.target_revision
                or snapshot.registry_revision != authority.entity_registry_revision
            ):
                raise ApiError("floor_plan_authority_changed", 409)
            supplied[snapshot.entity_id] = snapshot
        projections = []
        for entity_id, anchor in sorted(anchors.items()):
            snapshot = supplied.get(entity_id)
            if snapshot is None:
                projections.append(EntityProjection(
                    entity_id, anchor.target_revision, "unavailable", "stale"
                ))
                continue
            live = (
                snapshot.source_status == "verified"
                and now - snapshot.observed_at <= MAX_STATE_AGE_SECONDS
            )
            projections.append(EntityProjection(
                entity_id, snapshot.entity_revision, snapshot.state,
                "live" if live else "stale",
            ))
        return tuple(projections)

    def history(
        self, actor: Principal, *, authority: FloorPlanAuthority, limit: int,
    ) -> tuple[dict, ...]:
        self._authorize(actor, authority, edit=False)
        if type(limit) is not int or not 1 <= limit <= MAX_HISTORY:
            raise ApiError("invalid_request", 400)
        with self.database.connection() as connection:
            connection.execute("BEGIN")
            try:
                rows = self._verified_history(connection, self._scope(authority))
                return tuple({
                    "auditId": row["audit_id"],
                    "action": row["action"],
                    "actorId": row["actor_id"],
                    "layoutRevision": row["layout_revision"],
                    "occurredAt": row["occurred_at"],
                } for row in rows[-limit:])
            finally:
                connection.rollback()
