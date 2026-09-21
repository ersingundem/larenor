import hashlib
import hmac
import json
import uuid
from dataclasses import dataclass
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from ..auth import Principal
from ..errors import ApiError, StartupError

MAX_RESOURCES = 64


def _canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


@dataclass(frozen=True)
class ManagedResource:
    id: str
    revision: int
    label: str
    timezone: str
    capacity: int
    active: bool


class ResourceCatalog:
    def __init__(self, database, *, audit_key, clock, core_id, home_id, default_id):
        self.db, self.clock = database, clock
        self.key = audit_key
        self.core_id, self.home_id, self.default_id = core_id, home_id, default_id
        self._ensure_default()

    def _digest(self, namespace, value):
        return hmac.new(self.key, namespace + b":" + _canonical(value), hashlib.sha256).hexdigest()

    def _resource_hash(self, value):
        return self._digest(b"resource", value)

    def _state_hash(self, revision, count, last_hash):
        return self._digest(b"state", [self.core_id, self.home_id, revision, count, last_hash])

    def _event_hash(self, values):
        return self._digest(b"event", values)

    @staticmethod
    def _validate_fields(label, timezone, capacity):
        if not isinstance(label, str) or not 1 <= len(label.strip()) <= 80 or label != label.strip():
            raise ApiError("invalid_request", 400)
        if not isinstance(timezone, str) or not 1 <= len(timezone) <= 128:
            raise ApiError("invalid_request", 400)
        try:
            ZoneInfo(timezone)
        except (ZoneInfoNotFoundError, ValueError):
            raise ApiError("invalid_request", 400) from None
        if type(capacity) is not int or not 1 <= capacity <= 64:
            raise ApiError("invalid_request", 400)

    def _ensure_default(self):
        now = self.clock()
        value = [self.default_id, self.core_id, self.home_id, 1,
                 "Shared home resource", "UTC", 1, True, now, now]
        with self.db.transaction() as connection:
            state = connection.execute(
                "SELECT * FROM resource_reservation_catalog_state WHERE core_id=? AND home_id=?",
                (self.core_id, self.home_id),
            ).fetchone()
            if state is not None:
                self._verified(connection)
                return
            rows = connection.execute(
                "SELECT 1 FROM resource_reservation_catalog WHERE core_id=? AND home_id=?",
                (self.core_id, self.home_id),
            ).fetchall()
            if rows:
                raise StartupError("resource_reservation_catalog_invalid")
            connection.execute(
                "INSERT INTO resource_reservation_catalog VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                (*value[:8], self._resource_hash(value), *value[8:]),
            )
            connection.execute(
                "INSERT INTO resource_reservation_catalog_state VALUES(?,?,?,?,?,?)",
                (self.core_id, self.home_id, 1, 0, "", self._state_hash(1, 0, "")),
            )

    def _resource(self, row):
        value = [row["id"], row["core_id"], row["home_id"], row["revision"],
                 row["label"], row["timezone"], row["capacity"], bool(row["active"]),
                 row["created_at"], row["updated_at"]]
        if not hmac.compare_digest(row["payload_hash"], self._resource_hash(value)):
            raise StartupError("resource_reservation_catalog_invalid")
        self._validate_fields(row["label"], row["timezone"], row["capacity"])
        return ManagedResource(row["id"], row["revision"], row["label"], row["timezone"],
                               row["capacity"], bool(row["active"]))

    def _verified(self, connection):
        state = connection.execute(
            "SELECT * FROM resource_reservation_catalog_state WHERE core_id=? AND home_id=?",
            (self.core_id, self.home_id),
        ).fetchone()
        if state is None:
            raise StartupError("resource_reservation_catalog_invalid")
        rows = connection.execute(
            "SELECT * FROM resource_reservation_catalog WHERE core_id=? AND home_id=? ORDER BY label,id",
            (self.core_id, self.home_id),
        ).fetchall()
        resources = {row["id"]: self._resource(row) for row in rows}
        if not resources or len(resources) > MAX_RESOURCES:
            raise StartupError("resource_reservation_catalog_invalid")
        events = connection.execute(
            "SELECT * FROM resource_reservation_catalog_events WHERE core_id=? AND home_id=? ORDER BY sequence",
            (self.core_id, self.home_id),
        ).fetchall()
        previous = ""
        for index, event in enumerate(events, start=1):
            values = [event[name] for name in (
                "sequence", "event_id", "core_id", "home_id", "command_id", "actor_id",
                "action", "resource_id", "catalog_revision", "resource_revision",
                "request_hash", "occurred_at", "previous_hash",
            )]
            if event["previous_hash"] != previous or not hmac.compare_digest(
                event["event_hash"], self._event_hash(values)
            ) or event["catalog_revision"] != index + 1 or event["resource_id"] not in resources:
                raise StartupError("resource_reservation_catalog_invalid")
            previous = event["event_hash"]
        if (state["event_count"] != len(events) or state["revision"] != len(events) + 1
                or state["last_hash"] != previous or not hmac.compare_digest(
                    state["state_hash"], self._state_hash(state["revision"], len(events), previous))):
            raise StartupError("resource_reservation_catalog_invalid")
        return state, resources

    def list(self):
        with self.db.connection() as connection:
            state, resources = self._verified(connection)
        return state["revision"], tuple(sorted(resources.values(), key=lambda item: (item.label, item.id)))

    @staticmethod
    def _admin(actor):
        if actor.role != "admin":
            raise ApiError("forbidden", 403)

    def mutate(self, actor: Principal, *, command_id, expected_catalog_revision,
               action, resource_id=None, expected_resource_revision=None,
               label=None, timezone=None, capacity=None):
        self._admin(actor)
        command = {"action": action, "commandId": command_id,
                   "expectedCatalogRevision": expected_catalog_revision,
                   "resourceId": resource_id, "expectedResourceRevision": expected_resource_revision,
                   "label": label, "timezone": timezone, "capacity": capacity}
        request_hash = self._digest(b"request", command)
        now = self.clock()
        with self.db.transaction() as connection:
            state, resources = self._verified(connection)
            replay = connection.execute(
                "SELECT * FROM resource_reservation_catalog_events WHERE core_id=? AND home_id=? AND command_id=?",
                (self.core_id, self.home_id, command_id),
            ).fetchone()
            if replay is not None:
                current = resources.get(replay["resource_id"])
                if (not hmac.compare_digest(replay["request_hash"], request_hash)
                        or replay["actor_id"] != actor.id or current is None
                        or current.revision != replay["resource_revision"]):
                    raise ApiError("idempotency_conflict", 409)
                return state["revision"], current
            if expected_catalog_revision != state["revision"]:
                raise ApiError("authority_changed", 409)
            if action == "created":
                self._validate_fields(label, timezone, capacity)
                if len(resources) >= MAX_RESOURCES:
                    raise ApiError("resource_catalog_limit_reached", 413)
                resource_id = uuid.uuid4().hex
                revision, active, created = 1, True, now
            else:
                current = resources.get(resource_id)
                if current is None:
                    raise ApiError("not_found", 404)
                if expected_resource_revision != current.revision or not current.active:
                    raise ApiError("authority_changed", 409)
                revision, created = current.revision + 1, connection.execute(
                    "SELECT created_at FROM resource_reservation_catalog WHERE id=?", (resource_id,)
                ).fetchone()["created_at"]
                if action == "updated":
                    self._validate_fields(label, timezone, capacity)
                    active = True
                elif action == "deactivated":
                    if sum(item.active for item in resources.values()) <= 1:
                        raise ApiError("last_active_resource", 409)
                    label, timezone, capacity, active = current.label, current.timezone, current.capacity, False
                else:
                    raise ApiError("invalid_request", 400)
            resource_value = [resource_id, self.core_id, self.home_id, revision, label,
                              timezone, capacity, active, created, now]
            payload_hash = self._resource_hash(resource_value)
            if action == "created":
                connection.execute(
                    "INSERT INTO resource_reservation_catalog VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                    (*resource_value[:8], payload_hash, *resource_value[8:]),
                )
            else:
                connection.execute(
                    "UPDATE resource_reservation_catalog SET revision=?,label=?,timezone=?,capacity=?,active=?,payload_hash=?,updated_at=? WHERE id=? AND core_id=? AND home_id=?",
                    (revision, label, timezone, capacity, active, payload_hash, now,
                     resource_id, self.core_id, self.home_id),
                )
            catalog_revision = state["revision"] + 1
            sequence = state["event_count"] + 1
            event_id = uuid.uuid4().hex
            values = [sequence, event_id, self.core_id, self.home_id, command_id, actor.id,
                      action, resource_id, catalog_revision, revision, request_hash, now,
                      state["last_hash"]]
            event_hash = self._event_hash(values)
            connection.execute(
                "INSERT INTO resource_reservation_catalog_events VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (*values, event_hash),
            )
            connection.execute(
                "UPDATE resource_reservation_catalog_state SET revision=?,event_count=?,last_hash=?,state_hash=? WHERE core_id=? AND home_id=?",
                (catalog_revision, sequence, event_hash,
                 self._state_hash(catalog_revision, sequence, event_hash), self.core_id, self.home_id),
            )
            return catalog_revision, ManagedResource(resource_id, revision, label, timezone, capacity, active)
