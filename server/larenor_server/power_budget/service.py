import hashlib
import hmac
import json
import math
import sqlite3
import time
import uuid
from collections.abc import Callable
from dataclasses import asdict, dataclass
from typing import Protocol

from ..auth import Principal
from ..database import Database
from ..errors import ApiError, StartupError

MAX_LOADS = 192
MAX_PREVIEWS = 256
MAX_HISTORY = 1_024
MAX_PROVIDER_AGE_SECONDS = 300
PROVIDERS = {"meter", "tariff"}


def _canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def _identifier(value: object) -> bool:
    return (
        isinstance(value, str)
        and 1 <= len(value) <= 128
        and all(character.isalnum() or character in "-_.:" for character in value)
    )


def _revision(value: object) -> bool:
    return type(value) is int and value > 0


@dataclass(frozen=True)
class BudgetAuthority:
    core_id: str
    home_id: str
    account_id: str
    session_id: str
    core_revision: int
    home_revision: int
    account_revision: int
    meter_id: str
    meter_revision: int
    tariff_revision: int
    load_registry_revision: int
    grid_limit_revision: int
    override_revision: int
    plan_revision: int
    max_grid_w: int
    max_shed_w: int
    can_control: bool

    def __post_init__(self) -> None:
        if (
            any(
                not _identifier(item)
                for item in (
                    self.core_id,
                    self.home_id,
                    self.account_id,
                    self.session_id,
                    self.meter_id,
                )
            )
            or any(
                not _revision(item)
                for item in (
                    self.core_revision,
                    self.home_revision,
                    self.account_revision,
                    self.meter_revision,
                    self.tariff_revision,
                    self.load_registry_revision,
                    self.grid_limit_revision,
                    self.override_revision,
                    self.plan_revision,
                )
            )
            or type(self.max_grid_w) is not int
            or not 1 <= self.max_grid_w <= 1_000_000
            or type(self.max_shed_w) is not int
            or not 1 <= self.max_shed_w <= self.max_grid_w
            or type(self.can_control) is not bool
        ):
            raise ValueError("invalid_power_authority")


@dataclass(frozen=True)
class ProviderState:
    name: str
    revision: int
    status: str
    observed_at: float


@dataclass(frozen=True)
class LoadState:
    load_id: str
    revision: int
    priority: int
    current_w: int
    critical: bool
    controllable: bool
    hold_until: float


@dataclass(frozen=True)
class ManualOverride:
    expires_at: float
    reason: str


@dataclass(frozen=True)
class BudgetInputs:
    meter_revision: int
    tariff_revision: int
    load_registry_revision: int
    grid_limit_revision: int
    override_revision: int
    grid_limit_w: int
    grid_import_w: int
    tariff_micros_per_kwh: int
    provider_states: tuple[ProviderState, ...]
    loads: tuple[LoadState, ...]
    manual_override: ManualOverride | None


@dataclass(frozen=True)
class SheddingAction:
    load_id: str
    load_revision: int
    reduction_w: int
    target_w: int
    priority: int


@dataclass(frozen=True)
class BudgetPreview:
    id: str
    status: str
    plan_hash: str
    plan_revision: int
    required_reduction_w: int
    actions: tuple[SheddingAction, ...]
    provider_status: dict[str, str]
    override_expires_at: float | None


@dataclass(frozen=True)
class BudgetCommandReceipt:
    command_id: str
    preview_id: str
    plan_hash: str
    status: str
    apply_count: int


class PowerWorker(Protocol):
    def apply(self, *, plan_hash: str, actions: tuple[dict, ...]) -> None: ...
    def readback(self) -> str | None: ...


class PowerBudgetService:
    def __init__(
        self,
        database: Database,
        *,
        audit_key: bytes,
        worker: PowerWorker,
        clock: Callable[[], float] = time.time,
    ):
        if not isinstance(audit_key, bytes) or len(audit_key) != 32:
            raise ValueError("invalid_power_budget_audit_key")
        self.database = database
        self._audit_key = audit_key
        self._worker = worker
        self._clock = clock

    def validate_storage(self) -> None:
        """Fail startup if any retained scope or signed record was altered."""
        with self.database.connection() as connection:
            scopes = connection.execute(
                "SELECT core_id,home_id,meter_id FROM power_budget_previews "
                "UNION SELECT core_id,home_id,meter_id FROM power_budget_commands "
                "UNION SELECT core_id,home_id,meter_id FROM power_budget_events"
            ).fetchall()
            for row in scopes:
                self._verified_history(connection, tuple(row))

    def _fingerprint(self, domain: bytes, value: bytes) -> str:
        return hmac.new(
            self._audit_key,
            b"larenor-power-budget-" + domain + b"-v1\0" + value,
            hashlib.sha256,
        ).hexdigest()

    @staticmethod
    def _authorize(actor: Principal, authority: BudgetAuthority) -> None:
        if actor.id != authority.account_id or actor.family_id != authority.session_id:
            raise ApiError("power_authority_changed", 409)
        if actor.role != "admin" and not authority.can_control:
            raise ApiError("forbidden", 403)

    @staticmethod
    def _scope(authority: BudgetAuthority) -> tuple[str, str, str]:
        return authority.core_id, authority.home_id, authority.meter_id

    def _state_hash(self, values: tuple[object, ...]) -> str:
        return self._fingerprint(b"state", _canonical(values))

    def _event_hash(self, values: tuple[object, ...]) -> str:
        return self._fingerprint(b"event", _canonical(values))

    def _record_hash(self, kind: bytes, values: tuple[object, ...]) -> str:
        return self._fingerprint(kind + b"-record", _canonical(values))

    def _verified_history(self, connection: sqlite3.Connection, scope):
        state = connection.execute(
            "SELECT * FROM power_budget_audit_state WHERE core_id=? AND home_id=? AND meter_id=?",
            scope,
        ).fetchone()
        rows = connection.execute(
            "SELECT * FROM power_budget_events WHERE core_id=? AND home_id=? AND meter_id=? "
            "ORDER BY sequence",
            scope,
        ).fetchall()
        if state is None:
            if rows:
                raise StartupError("power_budget_audit_invalid")
            return rows
        state_values = (*scope, state["event_count"], state["last_hash"])
        if not hmac.compare_digest(state["state_hash"], self._state_hash(state_values)):
            raise StartupError("power_budget_audit_invalid")
        previous = ""
        for row in rows:
            values = (
                row["sequence"],
                row["audit_id"],
                row["core_id"],
                row["home_id"],
                row["meter_id"],
                row["action"],
                row["actor_id"],
                row["object_id"],
                row["plan_hash"],
                row["occurred_at"],
                row["request_hash"],
                row["previous_hash"],
            )
            if row["previous_hash"] != previous or not hmac.compare_digest(
                row["event_hash"], self._event_hash(values)
            ):
                raise StartupError("power_budget_audit_invalid")
            previous = row["event_hash"]
        if len(rows) != state["event_count"] or previous != state["last_hash"]:
            raise StartupError("power_budget_audit_invalid")
        record_specs = (
            (
                "power_budget_previews",
                (
                    "id",
                    "core_id",
                    "home_id",
                    "meter_id",
                    "account_id",
                    "plan_revision",
                    "plan_hash",
                    "request_hash",
                    "payload",
                    "created_at",
                ),
                b"preview",
            ),
            (
                "power_budget_commands",
                (
                    "command_id",
                    "core_id",
                    "home_id",
                    "meter_id",
                    "account_id",
                    "preview_id",
                    "plan_hash",
                    "request_hash",
                    "created_at",
                ),
                b"command",
            ),
        )
        for table, fields, kind in record_specs:
            records = connection.execute(
                f"SELECT * FROM {table} WHERE core_id=? AND home_id=? AND meter_id=?",
                scope,
            ).fetchall()
            for record in records:
                values = tuple(record[field] for field in fields)
                if not hmac.compare_digest(
                    record["record_hash"], self._record_hash(kind, values)
                ):
                    raise StartupError("power_budget_audit_invalid")
        return rows

    def _event(
        self,
        connection,
        *,
        scope,
        action,
        actor_id,
        object_id,
        plan_hash,
        request_hash,
        occurred_at,
    ):
        rows = self._verified_history(connection, scope)
        if len(rows) >= MAX_HISTORY:
            raise ApiError("power_budget_history_limit_reached", 413)
        previous = "" if not rows else rows[-1]["event_hash"]
        sequence = connection.execute(
            "SELECT COALESCE(MAX(sequence),0)+1 FROM power_budget_events"
        ).fetchone()[0]
        audit_id = uuid.uuid4().hex
        values = (
            sequence,
            audit_id,
            *scope,
            action,
            actor_id,
            object_id,
            plan_hash,
            occurred_at,
            request_hash,
            previous,
        )
        event_hash = self._event_hash(values)
        connection.execute(
            "INSERT INTO power_budget_events VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
            values + (event_hash,),
        )
        state_values = (*scope, len(rows) + 1, event_hash)
        connection.execute(
            "INSERT INTO power_budget_audit_state VALUES(?,?,?,?,?,?) "
            "ON CONFLICT(core_id,home_id,meter_id) DO UPDATE SET "
            "event_count=excluded.event_count,last_hash=excluded.last_hash,"
            "state_hash=excluded.state_hash",
            state_values + (self._state_hash(state_values),),
        )

    def _validate_inputs(
        self,
        authority: BudgetAuthority,
        inputs: BudgetInputs,
    ) -> dict[str, str]:
        if (
            inputs.meter_revision != authority.meter_revision
            or inputs.tariff_revision != authority.tariff_revision
            or inputs.load_registry_revision != authority.load_registry_revision
            or inputs.grid_limit_revision != authority.grid_limit_revision
            or inputs.override_revision != authority.override_revision
        ):
            raise ApiError("power_authority_changed", 409)
        states = {state.name: state for state in inputs.provider_states}
        expected_revisions = {
            "meter": authority.meter_revision,
            "tariff": authority.tariff_revision,
        }
        now = self._clock()
        if (
            len(inputs.provider_states) != len(PROVIDERS)
            or set(states) != PROVIDERS
            or any(
                state.status != "verified"
                or state.revision != expected_revisions[name]
                or type(state.observed_at) not in (int, float)
                or not math.isfinite(state.observed_at)
                or state.observed_at > now
                or now - state.observed_at > MAX_PROVIDER_AGE_SECONDS
                for name, state in states.items()
            )
        ):
            raise ApiError("power_inputs_unverified", 409)
        if (
            type(inputs.grid_limit_w) is not int
            or not 1 <= inputs.grid_limit_w <= authority.max_grid_w
            or type(inputs.grid_import_w) is not int
            or not 0 <= inputs.grid_import_w <= 1_000_000
            or type(inputs.tariff_micros_per_kwh) is not int
            or not 0 <= inputs.tariff_micros_per_kwh <= 10_000_000
        ):
            raise ApiError("power_safety_limit", 400)
        if (
            not isinstance(inputs.loads, tuple)
            or not 1 <= len(inputs.loads) <= MAX_LOADS
        ):
            raise ApiError("power_inputs_unverified", 409)
        identifiers: set[str] = set()
        for load in inputs.loads:
            if (
                not _identifier(load.load_id)
                or load.load_id in identifiers
                or not _revision(load.revision)
                or type(load.priority) is not int
                or not 0 <= load.priority <= 100
                or type(load.current_w) is not int
                or not 0 <= load.current_w <= authority.max_grid_w
                or type(load.critical) is not bool
                or type(load.controllable) is not bool
                or type(load.hold_until) not in (int, float)
                or not math.isfinite(load.hold_until)
                or load.hold_until < 0
            ):
                raise ApiError("power_inputs_unverified", 409)
            identifiers.add(load.load_id)
        return {name: states[name].status for name in sorted(states)}

    def _preview_from_row(self, row: sqlite3.Row) -> BudgetPreview:
        try:
            fields = (
                "id",
                "core_id",
                "home_id",
                "meter_id",
                "account_id",
                "plan_revision",
                "plan_hash",
                "request_hash",
                "payload",
                "created_at",
            )
            if not hmac.compare_digest(
                row["record_hash"],
                self._record_hash(b"preview", tuple(row[field] for field in fields)),
            ):
                raise StartupError("power_budget_preview_invalid")
            value = json.loads(row["payload"])
            actions = tuple(SheddingAction(**slot) for slot in value.pop("actions"))
            return BudgetPreview(
                id=row["id"], plan_hash=row["plan_hash"], actions=actions, **value
            )
        except (KeyError, TypeError, ValueError, json.JSONDecodeError):
            raise StartupError("power_budget_preview_invalid") from None

    def preview(
        self,
        actor: Principal,
        *,
        authority: BudgetAuthority,
        inputs: BudgetInputs,
        preview_id: str,
    ) -> BudgetPreview:
        self._authorize(actor, authority)
        if not _identifier(preview_id):
            raise ApiError("invalid_request", 400)
        statuses = self._validate_inputs(authority, inputs)
        now = self._clock()
        override = inputs.manual_override
        if override is not None and (
            type(override.expires_at) not in (int, float)
            or not math.isfinite(override.expires_at)
            or not isinstance(override.reason, str)
            or not 1 <= len(override.reason) <= 200
        ):
            raise ApiError("power_safety_limit", 400)
        required_reduction_w = max(0, inputs.grid_import_w - inputs.grid_limit_w)
        if required_reduction_w > authority.max_shed_w:
            raise ApiError("power_safety_limit", 400)
        status = (
            "manual_override_active"
            if override and override.expires_at > now
            else "ready"
        )
        planned: list[SheddingAction] = []
        if status == "ready":
            remaining = required_reduction_w
            ordered = sorted(
                (
                    load
                    for load in inputs.loads
                    if not load.critical
                    and load.controllable
                    and load.hold_until <= now
                    and load.current_w > 0
                ),
                key=lambda load: (load.priority, load.load_id),
            )
            for load in ordered:
                reduction = min(remaining, load.current_w)
                planned.append(
                    SheddingAction(
                        load.load_id,
                        load.revision,
                        reduction,
                        load.current_w - reduction,
                        load.priority,
                    )
                )
                remaining -= reduction
                if remaining == 0:
                    break
            if remaining:
                raise ApiError("critical_load_protection", 409)
        payload = {
            "status": status,
            "plan_revision": authority.plan_revision,
            "required_reduction_w": required_reduction_w,
            "actions": [asdict(slot) for slot in planned],
            "provider_status": statuses,
            "override_expires_at": override.expires_at if status != "ready" else None,
        }
        plan_hash = hashlib.sha256(
            _canonical(
                {
                    "authority": asdict(authority),
                    "inputs": asdict(inputs),
                    "result": payload,
                }
            )
        ).hexdigest()
        request_hash = self._fingerprint(
            b"preview",
            _canonical({"authority": asdict(authority), "inputs": asdict(inputs)}),
        )
        scope = self._scope(authority)
        with self.database.transaction() as connection:
            self._verified_history(connection, scope)
            old = connection.execute(
                "SELECT * FROM power_budget_previews WHERE id=?", (preview_id,)
            ).fetchone()
            if old is not None:
                if old["account_id"] != actor.id or not hmac.compare_digest(
                    old["request_hash"], request_hash
                ):
                    raise ApiError("power_budget_preview_conflict", 409)
                return self._preview_from_row(old)
            count = connection.execute(
                "SELECT COUNT(*) FROM power_budget_previews WHERE core_id=? AND home_id=? AND meter_id=?",
                scope,
            ).fetchone()[0]
            if count >= MAX_PREVIEWS:
                raise ApiError("power_budget_preview_limit_reached", 413)
            values = (
                preview_id,
                *scope,
                actor.id,
                authority.plan_revision,
                plan_hash,
                request_hash,
                json.dumps(payload, sort_keys=True),
                now,
            )
            connection.execute(
                "INSERT INTO power_budget_previews VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                values + (self._record_hash(b"preview", values),),
            )
            self._event(
                connection,
                scope=scope,
                action="previewed",
                actor_id=actor.id,
                object_id=preview_id,
                plan_hash=plan_hash,
                request_hash=request_hash,
                occurred_at=now,
            )
            row = connection.execute(
                "SELECT * FROM power_budget_previews WHERE id=?", (preview_id,)
            ).fetchone()
            return self._preview_from_row(row)

    def _command_status(self, connection, scope, command_id: str) -> str:
        rows = connection.execute(
            "SELECT action FROM power_budget_events WHERE core_id=? AND home_id=? "
            "AND meter_id=? AND object_id=? ORDER BY sequence",
            (*scope, command_id),
        ).fetchall()
        if not rows:
            raise StartupError("power_budget_audit_invalid")
        return {
            "dispatch_reserved": "uncertain",
            "confirm_uncertain": "uncertain",
            "awaiting_readback": "awaiting_readback",
            "readback_mismatch": "uncertain",
            "verified": "verified",
        }.get(rows[-1]["action"], "uncertain")

    def _receipt(self, connection, row, scope) -> BudgetCommandReceipt:
        fields = (
            "command_id",
            "core_id",
            "home_id",
            "meter_id",
            "account_id",
            "preview_id",
            "plan_hash",
            "request_hash",
            "created_at",
        )
        if not hmac.compare_digest(
            row["record_hash"],
            self._record_hash(b"command", tuple(row[field] for field in fields)),
        ):
            raise StartupError("power_budget_command_invalid")
        return BudgetCommandReceipt(
            row["command_id"],
            row["preview_id"],
            row["plan_hash"],
            self._command_status(connection, scope, row["command_id"]),
            1,
        )

    def confirm(
        self,
        actor: Principal,
        *,
        authority: BudgetAuthority,
        preview_id: str,
        command_id: str,
        expected_plan_hash: str,
    ) -> BudgetCommandReceipt:
        self._authorize(actor, authority)
        if not _identifier(preview_id) or not _identifier(command_id):
            raise ApiError("invalid_request", 400)
        scope = self._scope(authority)
        request_hash = self._fingerprint(
            b"confirm",
            _canonical([asdict(authority), preview_id, command_id, expected_plan_hash]),
        )
        with self.database.transaction() as connection:
            self._verified_history(connection, scope)
            old = connection.execute(
                "SELECT * FROM power_budget_commands WHERE command_id=?", (command_id,)
            ).fetchone()
            if old is not None:
                if old["account_id"] != actor.id or not hmac.compare_digest(
                    old["request_hash"], request_hash
                ):
                    raise ApiError("power_budget_command_conflict", 409)
                return self._receipt(connection, old, scope)
            preview_row = connection.execute(
                "SELECT * FROM power_budget_previews WHERE id=?", (preview_id,)
            ).fetchone()
            if preview_row is None:
                raise ApiError("not_found", 404)
            preview = self._preview_from_row(preview_row)
            if (
                preview_row["core_id"] != authority.core_id
                or preview_row["home_id"] != authority.home_id
                or preview_row["meter_id"] != authority.meter_id
                or preview_row["account_id"] != actor.id
                or preview.plan_revision != authority.plan_revision
                or preview.status != "ready"
                or not hmac.compare_digest(preview.plan_hash, expected_plan_hash)
            ):
                raise ApiError("power_budget_preview_changed", 409)
            now = self._clock()
            values = (
                command_id,
                *scope,
                actor.id,
                preview_id,
                preview.plan_hash,
                request_hash,
                now,
            )
            connection.execute(
                "INSERT INTO power_budget_commands VALUES(?,?,?,?,?,?,?,?,?,?)",
                values + (self._record_hash(b"command", values),),
            )
            self._event(
                connection,
                scope=scope,
                action="dispatch_reserved",
                actor_id=actor.id,
                object_id=command_id,
                plan_hash=preview.plan_hash,
                request_hash=request_hash,
                occurred_at=now,
            )
        try:
            self._worker.apply(
                plan_hash=preview.plan_hash,
                actions=tuple(asdict(slot) for slot in preview.actions),
            )
            action = "awaiting_readback"
        except Exception:  # noqa: BLE001 -- hardware result is deliberately uncertain.
            action = "confirm_uncertain"
        with self.database.transaction() as connection:
            self._verified_history(connection, scope)
            self._event(
                connection,
                scope=scope,
                action=action,
                actor_id=actor.id,
                object_id=command_id,
                plan_hash=preview.plan_hash,
                request_hash=request_hash,
                occurred_at=self._clock(),
            )
            row = connection.execute(
                "SELECT * FROM power_budget_commands WHERE command_id=?", (command_id,)
            ).fetchone()
            return self._receipt(connection, row, scope)

    def readback(
        self,
        actor: Principal,
        *,
        authority: BudgetAuthority,
        command_id: str,
    ) -> BudgetCommandReceipt:
        self._authorize(actor, authority)
        scope = self._scope(authority)
        with self.database.transaction() as connection:
            self._verified_history(connection, scope)
            row = connection.execute(
                "SELECT * FROM power_budget_commands WHERE command_id=?", (command_id,)
            ).fetchone()
            if (
                row is None
                or row["account_id"] != actor.id
                or (row["core_id"], row["home_id"], row["meter_id"]) != scope
            ):
                raise ApiError("not_found", 404)
            expected_request_hash = self._fingerprint(
                b"confirm",
                _canonical(
                    [
                        asdict(authority),
                        row["preview_id"],
                        command_id,
                        row["plan_hash"],
                    ]
                ),
            )
            if not hmac.compare_digest(row["request_hash"], expected_request_hash):
                raise ApiError("power_authority_changed", 409)
            current = self._command_status(connection, scope, command_id)
            if current == "verified":
                return self._receipt(connection, row, scope)
            observed = self._worker.readback()
            action = (
                "verified"
                if observed is not None
                and hmac.compare_digest(observed, row["plan_hash"])
                else "readback_mismatch"
            )
            self._event(
                connection,
                scope=scope,
                action=action,
                actor_id=actor.id,
                object_id=command_id,
                plan_hash=row["plan_hash"],
                request_hash=self._fingerprint(
                    b"readback", _canonical([command_id, observed])
                ),
                occurred_at=self._clock(),
            )
            return self._receipt(connection, row, scope)

    def history(
        self,
        actor: Principal,
        *,
        authority: BudgetAuthority,
        limit: int,
    ) -> tuple[dict, ...]:
        self._authorize(actor, authority)
        if type(limit) is not int or not 1 <= limit <= MAX_HISTORY:
            raise ApiError("invalid_request", 400)
        with self.database.connection() as connection:
            connection.execute("BEGIN")
            try:
                rows = self._verified_history(connection, self._scope(authority))
                return tuple(
                    {
                        "auditId": row["audit_id"],
                        "action": row["action"],
                        "objectId": row["object_id"],
                        "occurredAt": row["occurred_at"],
                    }
                    for row in rows[-limit:]
                )
            finally:
                connection.rollback()
