from dataclasses import asdict, dataclass
import hashlib
import hmac
import json
import math
import sqlite3
import time
import uuid
from collections.abc import Callable
from typing import Protocol

from ..auth import Principal
from ..database import Database
from ..errors import ApiError, StartupError


MAX_SLOTS = 192
MAX_PREVIEWS = 256
MAX_HISTORY = 1_024
MAX_PROVIDER_AGE_SECONDS = 300
PROVIDERS = {"tariff", "solar", "power_budget"}


def _canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def _identifier(value: object) -> bool:
    return isinstance(value, str) and 1 <= len(value) <= 128 and all(
        character.isalnum() or character in "-_.:" for character in value
    )


def _revision(value: object) -> bool:
    return type(value) is int and value > 0


@dataclass(frozen=True)
class ChargeAuthority:
    core_id: str
    home_id: str
    account_id: str
    session_id: str
    core_revision: int
    home_revision: int
    account_revision: int
    charger_id: str
    charger_revision: int
    tariff_revision: int
    solar_revision: int
    power_budget_revision: int
    override_revision: int
    schedule_revision: int
    max_current_amp: int
    voltage: int
    max_session_wh: int
    can_control: bool

    def __post_init__(self) -> None:
        if (
            any(not _identifier(item) for item in (
                self.core_id, self.home_id, self.account_id, self.session_id,
                self.charger_id,
            ))
            or any(not _revision(item) for item in (
                self.core_revision, self.home_revision, self.account_revision,
                self.charger_revision, self.tariff_revision, self.solar_revision,
                self.power_budget_revision, self.override_revision,
                self.schedule_revision,
            ))
            or type(self.max_current_amp) is not int
            or not 1 <= self.max_current_amp <= 80
            or type(self.voltage) is not int
            or not 100 <= self.voltage <= 500
            or type(self.max_session_wh) is not int
            or not 1 <= self.max_session_wh <= 500_000
            or type(self.can_control) is not bool
        ):
            raise ValueError("invalid_charge_authority")


@dataclass(frozen=True)
class ProviderState:
    name: str
    revision: int
    status: str
    observed_at: float


@dataclass(frozen=True)
class EnergySlot:
    start_at: float
    end_at: float
    tariff_micros_per_kwh: int
    solar_surplus_w: int
    home_budget_w: int


@dataclass(frozen=True)
class ManualOverride:
    expires_at: float
    max_current_amp: int
    reason: str


@dataclass(frozen=True)
class EnergyInputs:
    tariff_revision: int
    solar_revision: int
    power_budget_revision: int
    override_revision: int
    provider_states: tuple[ProviderState, ...]
    slots: tuple[EnergySlot, ...]
    manual_override: ManualOverride | None


@dataclass(frozen=True)
class ChargeGoal:
    departure_at: float
    current_soc: int
    minimum_soc: int
    target_soc: int
    battery_capacity_wh: int
    max_current_amp: int


@dataclass(frozen=True)
class PlannedChargeSlot:
    start_at: float
    end_at: float
    current_amp: int
    energy_wh: int
    tariff_micros_per_kwh: int
    solar_surplus_w: int


@dataclass(frozen=True)
class ChargePreview:
    id: str
    status: str
    plan_hash: str
    schedule_revision: int
    required_wh: int
    slots: tuple[PlannedChargeSlot, ...]
    provider_status: dict[str, str]
    override_expires_at: float | None


@dataclass(frozen=True)
class ChargeCommandReceipt:
    command_id: str
    preview_id: str
    plan_hash: str
    status: str
    apply_count: int


class ChargerGateway(Protocol):
    def apply(self, *, plan_hash: str, slots: tuple[dict, ...]) -> None: ...
    def readback(self) -> str | None: ...


class ChargePlanner:
    def __init__(
        self,
        database: Database,
        *,
        audit_key: bytes,
        charger: ChargerGateway,
        clock: Callable[[], float] = time.time,
    ):
        if not isinstance(audit_key, bytes) or len(audit_key) != 32:
            raise ValueError("invalid_ev_charge_audit_key")
        self.database = database
        self._audit_key = audit_key
        self._charger = charger
        self._clock = clock

    def _fingerprint(self, domain: bytes, value: bytes) -> str:
        return hmac.new(
            self._audit_key,
            b"larenor-ev-charge-" + domain + b"-v1\0" + value,
            hashlib.sha256,
        ).hexdigest()

    @staticmethod
    def _authorize(actor: Principal, authority: ChargeAuthority) -> None:
        if actor.id != authority.account_id or actor.family_id != authority.session_id:
            raise ApiError("energy_authority_changed", 409)
        if actor.role != "admin" and not authority.can_control:
            raise ApiError("forbidden", 403)

    @staticmethod
    def _scope(authority: ChargeAuthority) -> tuple[str, str, str]:
        return authority.core_id, authority.home_id, authority.charger_id

    def _state_hash(self, values: tuple[object, ...]) -> str:
        return self._fingerprint(b"state", _canonical(values))

    def _event_hash(self, values: tuple[object, ...]) -> str:
        return self._fingerprint(b"event", _canonical(values))

    def _record_hash(self, kind: bytes, values: tuple[object, ...]) -> str:
        return self._fingerprint(kind + b"-record", _canonical(values))

    def _verified_history(self, connection: sqlite3.Connection, scope):
        state = connection.execute(
            "SELECT * FROM ev_charge_audit_state WHERE core_id=? AND home_id=? AND charger_id=?",
            scope,
        ).fetchone()
        rows = connection.execute(
            "SELECT * FROM ev_charge_events WHERE core_id=? AND home_id=? AND charger_id=? "
            "ORDER BY sequence", scope,
        ).fetchall()
        if state is None:
            if rows:
                raise StartupError("ev_charge_audit_invalid")
            return rows
        state_values = (*scope, state["event_count"], state["last_hash"])
        if not hmac.compare_digest(state["state_hash"], self._state_hash(state_values)):
            raise StartupError("ev_charge_audit_invalid")
        previous = ""
        for row in rows:
            values = (
                row["sequence"], row["audit_id"], row["core_id"], row["home_id"],
                row["charger_id"], row["action"], row["actor_id"], row["object_id"],
                row["plan_hash"], row["occurred_at"], row["request_hash"],
                row["previous_hash"],
            )
            if row["previous_hash"] != previous or not hmac.compare_digest(
                row["event_hash"], self._event_hash(values)
            ):
                raise StartupError("ev_charge_audit_invalid")
            previous = row["event_hash"]
        if len(rows) != state["event_count"] or previous != state["last_hash"]:
            raise StartupError("ev_charge_audit_invalid")
        record_specs = (
            (
                "ev_charge_previews",
                (
                    "id", "core_id", "home_id", "charger_id", "account_id",
                    "schedule_revision", "plan_hash", "request_hash", "payload",
                    "created_at",
                ),
                b"preview",
            ),
            (
                "ev_charge_commands",
                (
                    "command_id", "core_id", "home_id", "charger_id", "account_id",
                    "preview_id", "plan_hash", "request_hash", "created_at",
                ),
                b"command",
            ),
        )
        for table, fields, kind in record_specs:
            records = connection.execute(
                f"SELECT * FROM {table} WHERE core_id=? AND home_id=? AND charger_id=?",
                scope,
            ).fetchall()
            for record in records:
                values = tuple(record[field] for field in fields)
                if not hmac.compare_digest(
                    record["record_hash"], self._record_hash(kind, values)
                ):
                    raise StartupError("ev_charge_audit_invalid")
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
            raise ApiError("ev_charge_history_limit_reached", 413)
        previous = "" if not rows else rows[-1]["event_hash"]
        sequence = connection.execute(
            "SELECT COALESCE(MAX(sequence),0)+1 FROM ev_charge_events"
        ).fetchone()[0]
        audit_id = uuid.uuid4().hex
        values = (
            sequence, audit_id, *scope, action, actor_id, object_id, plan_hash,
            occurred_at, request_hash, previous,
        )
        event_hash = self._event_hash(values)
        connection.execute(
            "INSERT INTO ev_charge_events VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
            values + (event_hash,),
        )
        state_values = (*scope, len(rows) + 1, event_hash)
        connection.execute(
            "INSERT INTO ev_charge_audit_state VALUES(?,?,?,?,?,?) "
            "ON CONFLICT(core_id,home_id,charger_id) DO UPDATE SET "
            "event_count=excluded.event_count,last_hash=excluded.last_hash,"
            "state_hash=excluded.state_hash",
            state_values + (self._state_hash(state_values),),
        )

    def _validate_inputs(
        self, authority: ChargeAuthority, inputs: EnergyInputs, goal: ChargeGoal,
    ) -> dict[str, str]:
        if (
            inputs.tariff_revision != authority.tariff_revision
            or inputs.solar_revision != authority.solar_revision
            or inputs.power_budget_revision != authority.power_budget_revision
            or inputs.override_revision != authority.override_revision
        ):
            raise ApiError("energy_authority_changed", 409)
        states = {state.name: state for state in inputs.provider_states}
        expected_revisions = {
            "tariff": authority.tariff_revision,
            "solar": authority.solar_revision,
            "power_budget": authority.power_budget_revision,
        }
        now = self._clock()
        if len(inputs.provider_states) != len(PROVIDERS) or set(states) != PROVIDERS or any(
            state.status != "verified"
            or state.revision != expected_revisions[name]
            or type(state.observed_at) not in (int, float)
            or not math.isfinite(state.observed_at)
            or state.observed_at > now
            or now - state.observed_at > MAX_PROVIDER_AGE_SECONDS
            for name, state in states.items()
        ):
            raise ApiError("energy_inputs_unverified", 409)
        if (
            type(goal.current_soc) is not int
            or type(goal.minimum_soc) is not int
            or type(goal.target_soc) is not int
            or not 0 <= goal.current_soc <= goal.minimum_soc <= goal.target_soc <= 100
            or type(goal.battery_capacity_wh) is not int
            or not 1 <= goal.battery_capacity_wh <= 500_000
            or type(goal.max_current_amp) is not int
            or not 1 <= goal.max_current_amp <= authority.max_current_amp
            or type(goal.departure_at) not in (int, float)
            or not math.isfinite(goal.departure_at)
            or goal.departure_at <= now
        ):
            raise ApiError("charge_safety_limit", 400)
        if not isinstance(inputs.slots, tuple) or not 1 <= len(inputs.slots) <= MAX_SLOTS:
            raise ApiError("energy_inputs_unverified", 409)
        previous_end = now
        for slot in inputs.slots:
            if (
                type(slot.tariff_micros_per_kwh) is not int
                or not 0 <= slot.tariff_micros_per_kwh <= 10_000_000
                or type(slot.solar_surplus_w) is not int
                or not 0 <= slot.solar_surplus_w <= 100_000
                or type(slot.home_budget_w) is not int
                or not 0 <= slot.home_budget_w <= 100_000
                or type(slot.start_at) not in (int, float)
                or type(slot.end_at) not in (int, float)
                or not math.isfinite(slot.start_at)
                or not math.isfinite(slot.end_at)
                or slot.start_at < now
                or slot.start_at < previous_end
                or slot.end_at <= slot.start_at
                or slot.end_at - slot.start_at > 3600
                or slot.end_at > goal.departure_at
            ):
                raise ApiError("energy_inputs_unverified", 409)
            previous_end = slot.end_at
        return {name: states[name].status for name in sorted(states)}

    def _preview_from_row(self, row: sqlite3.Row) -> ChargePreview:
        try:
            fields = (
                "id", "core_id", "home_id", "charger_id", "account_id",
                "schedule_revision", "plan_hash", "request_hash", "payload",
                "created_at",
            )
            if not hmac.compare_digest(
                row["record_hash"],
                self._record_hash(b"preview", tuple(row[field] for field in fields)),
            ):
                raise StartupError("ev_charge_preview_invalid")
            value = json.loads(row["payload"])
            slots = tuple(PlannedChargeSlot(**slot) for slot in value.pop("slots"))
            return ChargePreview(id=row["id"], plan_hash=row["plan_hash"], slots=slots, **value)
        except (KeyError, TypeError, ValueError, json.JSONDecodeError):
            raise StartupError("ev_charge_preview_invalid") from None

    def preview(
        self,
        actor: Principal,
        *,
        authority: ChargeAuthority,
        inputs: EnergyInputs,
        goal: ChargeGoal,
        preview_id: str,
    ) -> ChargePreview:
        self._authorize(actor, authority)
        if not _identifier(preview_id):
            raise ApiError("invalid_request", 400)
        statuses = self._validate_inputs(authority, inputs, goal)
        now = self._clock()
        override = inputs.manual_override
        if override is not None and (
            type(override.expires_at) not in (int, float)
            or not math.isfinite(override.expires_at)
            or type(override.max_current_amp) is not int
            or not 1 <= override.max_current_amp <= authority.max_current_amp
            or not isinstance(override.reason, str)
            or not 1 <= len(override.reason) <= 200
        ):
            raise ApiError("charge_safety_limit", 400)
        required_wh = math.ceil(
            goal.battery_capacity_wh * (goal.target_soc - goal.current_soc) / 100
        )
        if required_wh > authority.max_session_wh:
            raise ApiError("charge_safety_limit", 400)
        status = "manual_override_active" if override and override.expires_at > now else "ready"
        planned: list[PlannedChargeSlot] = []
        if status == "ready":
            remaining = required_wh
            ordered = sorted(
                inputs.slots,
                key=lambda slot: (
                    slot.tariff_micros_per_kwh,
                    -slot.solar_surplus_w,
                    slot.start_at,
                ),
            )
            max_power = goal.max_current_amp * authority.voltage
            for slot in ordered:
                available_power = min(
                    max_power, slot.home_budget_w + slot.solar_surplus_w
                )
                current_amp = min(
                    goal.max_current_amp, math.floor(available_power / authority.voltage)
                )
                if current_amp <= 0:
                    continue
                capacity_wh = math.floor(
                    current_amp * authority.voltage
                    * (slot.end_at - slot.start_at) / 3600
                )
                energy = min(remaining, capacity_wh)
                if energy <= 0:
                    continue
                planned.append(PlannedChargeSlot(
                    slot.start_at, slot.end_at, current_amp, energy,
                    slot.tariff_micros_per_kwh, slot.solar_surplus_w,
                ))
                remaining -= energy
                if remaining == 0:
                    break
            if remaining:
                raise ApiError("charge_target_unreachable", 409)
        payload = {
            "status": status,
            "schedule_revision": authority.schedule_revision,
            "required_wh": required_wh,
            "slots": [asdict(slot) for slot in planned],
            "provider_status": statuses,
            "override_expires_at": override.expires_at if status != "ready" else None,
        }
        plan_hash = hashlib.sha256(_canonical({
            "authority": asdict(authority),
            "goal": asdict(goal),
            "inputs": asdict(inputs),
            "result": payload,
        })).hexdigest()
        request_hash = self._fingerprint(b"preview", _canonical({
            "authority": asdict(authority), "goal": asdict(goal), "inputs": asdict(inputs)
        }))
        scope = self._scope(authority)
        with self.database.transaction() as connection:
            self._verified_history(connection, scope)
            old = connection.execute(
                "SELECT * FROM ev_charge_previews WHERE id=?", (preview_id,)
            ).fetchone()
            if old is not None:
                if old["account_id"] != actor.id or not hmac.compare_digest(old["request_hash"], request_hash):
                    raise ApiError("charge_preview_conflict", 409)
                return self._preview_from_row(old)
            count = connection.execute(
                "SELECT COUNT(*) FROM ev_charge_previews WHERE core_id=? AND home_id=? AND charger_id=?",
                scope,
            ).fetchone()[0]
            if count >= MAX_PREVIEWS:
                raise ApiError("charge_preview_limit_reached", 413)
            values = (
                preview_id, *scope, actor.id, authority.schedule_revision,
                plan_hash, request_hash, json.dumps(payload, sort_keys=True), now,
            )
            connection.execute(
                "INSERT INTO ev_charge_previews VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                values + (self._record_hash(b"preview", values),),
            )
            self._event(
                connection, scope=scope, action="previewed", actor_id=actor.id,
                object_id=preview_id, plan_hash=plan_hash, request_hash=request_hash,
                occurred_at=now,
            )
            row = connection.execute(
                "SELECT * FROM ev_charge_previews WHERE id=?", (preview_id,)
            ).fetchone()
            return self._preview_from_row(row)

    def _command_status(self, connection, scope, command_id: str) -> str:
        rows = connection.execute(
            "SELECT action FROM ev_charge_events WHERE core_id=? AND home_id=? "
            "AND charger_id=? AND object_id=? ORDER BY sequence", (*scope, command_id),
        ).fetchall()
        if not rows:
            raise StartupError("ev_charge_audit_invalid")
        return {
            "dispatch_reserved": "uncertain",
            "confirm_uncertain": "uncertain",
            "awaiting_readback": "awaiting_readback",
            "readback_mismatch": "uncertain",
            "verified": "verified",
        }.get(rows[-1]["action"], "uncertain")

    def _receipt(self, connection, row, scope) -> ChargeCommandReceipt:
        fields = (
            "command_id", "core_id", "home_id", "charger_id", "account_id",
            "preview_id", "plan_hash", "request_hash", "created_at",
        )
        if not hmac.compare_digest(
            row["record_hash"],
            self._record_hash(b"command", tuple(row[field] for field in fields)),
        ):
            raise StartupError("ev_charge_command_invalid")
        return ChargeCommandReceipt(
            row["command_id"], row["preview_id"], row["plan_hash"],
            self._command_status(connection, scope, row["command_id"]), 1,
        )

    def confirm(
        self,
        actor: Principal,
        *,
        authority: ChargeAuthority,
        preview_id: str,
        command_id: str,
        expected_plan_hash: str,
    ) -> ChargeCommandReceipt:
        self._authorize(actor, authority)
        if not _identifier(preview_id) or not _identifier(command_id):
            raise ApiError("invalid_request", 400)
        scope = self._scope(authority)
        request_hash = self._fingerprint(
            b"confirm", _canonical([asdict(authority), preview_id, command_id, expected_plan_hash])
        )
        with self.database.transaction() as connection:
            self._verified_history(connection, scope)
            old = connection.execute(
                "SELECT * FROM ev_charge_commands WHERE command_id=?", (command_id,)
            ).fetchone()
            if old is not None:
                if old["account_id"] != actor.id or not hmac.compare_digest(old["request_hash"], request_hash):
                    raise ApiError("charge_command_conflict", 409)
                return self._receipt(connection, old, scope)
            preview_row = connection.execute(
                "SELECT * FROM ev_charge_previews WHERE id=?", (preview_id,)
            ).fetchone()
            if preview_row is None:
                raise ApiError("not_found", 404)
            preview = self._preview_from_row(preview_row)
            if (
                preview_row["core_id"] != authority.core_id
                or preview_row["home_id"] != authority.home_id
                or preview_row["charger_id"] != authority.charger_id
                or preview_row["account_id"] != actor.id
                or preview.schedule_revision != authority.schedule_revision
                or preview.status != "ready"
                or not hmac.compare_digest(preview.plan_hash, expected_plan_hash)
            ):
                raise ApiError("charge_preview_changed", 409)
            now = self._clock()
            values = (
                command_id, *scope, actor.id, preview_id, preview.plan_hash,
                request_hash, now,
            )
            connection.execute(
                "INSERT INTO ev_charge_commands VALUES(?,?,?,?,?,?,?,?,?,?)",
                values + (self._record_hash(b"command", values),),
            )
            self._event(
                connection, scope=scope, action="dispatch_reserved", actor_id=actor.id,
                object_id=command_id, plan_hash=preview.plan_hash,
                request_hash=request_hash, occurred_at=now,
            )
        try:
            self._charger.apply(
                plan_hash=preview.plan_hash,
                slots=tuple(asdict(slot) for slot in preview.slots),
            )
            action = "awaiting_readback"
        except Exception:
            action = "confirm_uncertain"
        with self.database.transaction() as connection:
            self._verified_history(connection, scope)
            self._event(
                connection, scope=scope, action=action, actor_id=actor.id,
                object_id=command_id, plan_hash=preview.plan_hash,
                request_hash=request_hash, occurred_at=self._clock(),
            )
            row = connection.execute(
                "SELECT * FROM ev_charge_commands WHERE command_id=?", (command_id,)
            ).fetchone()
            return self._receipt(connection, row, scope)

    def readback(
        self,
        actor: Principal,
        *,
        authority: ChargeAuthority,
        command_id: str,
    ) -> ChargeCommandReceipt:
        self._authorize(actor, authority)
        scope = self._scope(authority)
        with self.database.transaction() as connection:
            self._verified_history(connection, scope)
            row = connection.execute(
                "SELECT * FROM ev_charge_commands WHERE command_id=?", (command_id,)
            ).fetchone()
            if row is None or row["account_id"] != actor.id or (
                row["core_id"], row["home_id"], row["charger_id"]
            ) != scope:
                raise ApiError("not_found", 404)
            expected_request_hash = self._fingerprint(
                b"confirm",
                _canonical([
                    asdict(authority), row["preview_id"], command_id,
                    row["plan_hash"],
                ]),
            )
            if not hmac.compare_digest(row["request_hash"], expected_request_hash):
                raise ApiError("energy_authority_changed", 409)
            current = self._command_status(connection, scope, command_id)
            if current == "verified":
                return self._receipt(connection, row, scope)
            observed = self._charger.readback()
            action = "verified" if observed is not None and hmac.compare_digest(
                observed, row["plan_hash"]
            ) else "readback_mismatch"
            self._event(
                connection, scope=scope, action=action, actor_id=actor.id,
                object_id=command_id, plan_hash=row["plan_hash"],
                request_hash=self._fingerprint(b"readback", _canonical([command_id, observed])),
                occurred_at=self._clock(),
            )
            return self._receipt(connection, row, scope)

    def history(
        self, actor: Principal, *, authority: ChargeAuthority, limit: int,
    ) -> tuple[dict, ...]:
        self._authorize(actor, authority)
        if type(limit) is not int or not 1 <= limit <= MAX_HISTORY:
            raise ApiError("invalid_request", 400)
        with self.database.connection() as connection:
            connection.execute("BEGIN")
            try:
                rows = self._verified_history(connection, self._scope(authority))
                return tuple({
                    "auditId": row["audit_id"],
                    "action": row["action"],
                    "objectId": row["object_id"],
                    "occurredAt": row["occurred_at"],
                } for row in rows[-limit:])
            finally:
                connection.rollback()
