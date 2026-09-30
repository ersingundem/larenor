"""Explicitly authorized one-slot evcc current control with exact readback."""

import hashlib
import hmac
import json
import math
import re
import sqlite3

from ..errors import ApiError, StartupError
from ..services.transport import ProbeTransportError, ServiceTransport
from .provider import EvccHttpReader, EvccProviderError


MAX_RECORDS = 256
_POWER_LOAD = re.compile(r"evcc-lp-([1-9]|1[0-6])\Z")
TABLES = {
    "evcc_current_authorities": """CREATE TABLE evcc_current_authorities (
        service_id TEXT NOT NULL,
        loadpoint_index INTEGER NOT NULL CHECK(loadpoint_index BETWEEN 1 AND 16),
        service_revision INTEGER NOT NULL CHECK(service_revision > 0),
        authority_revision INTEGER NOT NULL CHECK(authority_revision > 0),
        enabled INTEGER NOT NULL CHECK(enabled IN (0,1)),
        updated_at REAL NOT NULL,
        record_hash TEXT NOT NULL,
        PRIMARY KEY(service_id,loadpoint_index))""",
    "evcc_current_effects": """CREATE TABLE evcc_current_effects (
        plan_hash TEXT PRIMARY KEY,
        service_id TEXT NOT NULL,
        service_revision INTEGER NOT NULL CHECK(service_revision > 0),
        charger_id TEXT NOT NULL,
        charger_revision INTEGER NOT NULL CHECK(charger_revision > 0),
        schedule_revision INTEGER NOT NULL CHECK(schedule_revision > 0),
        loadpoint_index INTEGER NOT NULL CHECK(loadpoint_index BETWEEN 1 AND 16),
        target_current_amp INTEGER NOT NULL CHECK(target_current_amp BETWEEN 1 AND 80),
        status TEXT NOT NULL CHECK(status IN ('reserved','uncertain','verified','mismatch')),
        observed_current_amp INTEGER,
        updated_at REAL NOT NULL,
        record_hash TEXT NOT NULL)""",
}


def migrate_evcc_current_control(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='evcc_current_control_schema'"
        ).fetchone()
        rows = connection.execute(
            "SELECT name,type,sql FROM sqlite_master "
            "WHERE name IN ('evcc_current_authorities','evcc_current_effects')"
        ).fetchall()
        actual = {row["name"]: row for row in rows}
        if marker is None:
            if actual:
                raise ValueError("unmarked_evcc_current_control")
            for statement in TABLES.values():
                connection.execute(statement)
            connection.execute(
                "INSERT INTO metadata VALUES('evcc_current_control_schema','1')"
            )
            return
        if (
            marker["value"] != "1"
            or set(actual) != set(TABLES)
            or any(
                row["type"] != "table"
                or " ".join(row["sql"].split()) != " ".join(TABLES[name].split())
                for name, row in actual.items()
            )
        ):
            raise ValueError("invalid_evcc_current_control")
    except (sqlite3.Error, TypeError, ValueError):
        raise StartupError("evcc_current_control_storage_invalid") from None


class EvccCurrentControl:
    def __init__(
        self,
        database,
        *,
        audit_key,
        clock,
        services,
        binding_resolver,
        energy_windows,
        transport_factory=None,
    ):
        if (
            not isinstance(audit_key, bytes)
            or len(audit_key) < 32
            or not callable(clock)
            or not callable(binding_resolver)
        ):
            raise ValueError("invalid_evcc_current_control")
        self.database = database
        self._key = audit_key
        self._clock = clock
        self._services = services
        self._binding_resolver = binding_resolver
        self._windows = energy_windows
        self._transport_factory = transport_factory

    def _hash(self, domain, values):
        return hmac.new(
            self._key,
            b"larenor-evcc-current-control-v1:" + domain + b"\0"
            + json.dumps(values, separators=(",", ":"), allow_nan=False).encode(),
            hashlib.sha256,
        ).hexdigest()

    @staticmethod
    def _authority_fields(row, *, revision=None, enabled=None, updated=None):
        return (
            row["service_id"],
            row["loadpoint_index"],
            row["service_revision"],
            row["authority_revision"] if revision is None else revision,
            row["enabled"] if enabled is None else int(enabled),
            row["updated_at"] if updated is None else updated,
        )

    @staticmethod
    def _effect_fields(row, *, status=None, observed=..., updated=None):
        return (
            row["plan_hash"],
            row["service_id"],
            row["service_revision"],
            row["charger_id"],
            row["charger_revision"],
            row["schedule_revision"],
            row["loadpoint_index"],
            row["target_current_amp"],
            row["status"] if status is None else status,
            row["observed_current_amp"] if observed is ... else observed,
            row["updated_at"] if updated is None else updated,
        )

    def _verify_authority(self, row):
        if (
            row is None
            or re.fullmatch(r"[0-9a-f]{32}", row["service_id"]) is None
            or not hmac.compare_digest(
                row["record_hash"],
                self._hash(b"authority", self._authority_fields(row)),
            )
        ):
            raise StartupError("evcc_current_control_storage_invalid")

    def _verify_effect(self, row):
        status = None if row is None else row["status"]
        observed = None if row is None else row["observed_current_amp"]
        target = None if row is None else row["target_current_amp"]
        if (
            row is None
            or re.fullmatch(r"[0-9a-f]{64}", row["plan_hash"]) is None
            or re.fullmatch(r"[0-9a-f]{32}", row["charger_id"]) is None
            or status in {"reserved", "uncertain"}
            and observed is not None
            or status == "verified"
            and observed != target
            or status == "mismatch"
            and (
                type(observed) is not int
                or not 1 <= observed <= 80
                or observed == target
            )
            or not hmac.compare_digest(
                row["record_hash"], self._hash(b"effect", self._effect_fields(row))
            )
        ):
            raise StartupError("evcc_current_control_storage_invalid")

    def validate_storage(self):
        with self.database.connection() as connection:
            authorities = connection.execute(
                "SELECT * FROM evcc_current_authorities "
                "ORDER BY service_id,loadpoint_index LIMIT ?",
                (MAX_RECORDS + 1,),
            ).fetchall()
            effects = connection.execute(
                "SELECT * FROM evcc_current_effects ORDER BY plan_hash LIMIT ?",
                (MAX_RECORDS + 1,),
            ).fetchall()
        if len(authorities) > MAX_RECORDS or len(effects) > MAX_RECORDS:
            raise StartupError("evcc_current_control_storage_invalid")
        for row in authorities:
            self._verify_authority(row)
        for row in effects:
            self._verify_effect(row)

    def authorize(
        self,
        actor,
        *,
        service_id,
        service_revision,
        loadpoint_index,
        expected_authority_revision,
        enabled,
    ):
        if (
            type(loadpoint_index) is not int
            or not 1 <= loadpoint_index <= 16
            or type(expected_authority_revision) is not int
            or not 0 <= expected_authority_revision < 2**63 - 1
            or type(enabled) is not bool
        ):
            raise ApiError("invalid_request")
        now = self._clock()
        with self.database.transaction() as connection:
            self._services._assert_admin(connection, actor)
            self._services._evcc_connection_in(connection, service_id, service_revision)
            row = connection.execute(
                "SELECT * FROM evcc_current_authorities WHERE service_id=? AND loadpoint_index=?",
                (service_id, loadpoint_index),
            ).fetchone()
            current = 0 if row is None else row["authority_revision"]
            if row is not None:
                self._verify_authority(row)
            if current != expected_authority_revision:
                raise ApiError("revision_conflict", 409)
            if (
                row is None
                and connection.execute(
                    "SELECT COUNT(*) FROM evcc_current_authorities"
                ).fetchone()[0]
                >= MAX_RECORDS
            ):
                raise ApiError("service_limit_reached", 409)
            revision = current + 1
            fields = (
                service_id,
                loadpoint_index,
                service_revision,
                revision,
                int(enabled),
                now,
            )
            connection.execute(
                "INSERT INTO evcc_current_authorities VALUES(?,?,?,?,?,?,?) "
                "ON CONFLICT(service_id,loadpoint_index) DO UPDATE SET "
                "service_revision=excluded.service_revision,"
                "authority_revision=excluded.authority_revision,enabled=excluded.enabled,"
                "updated_at=excluded.updated_at,record_hash=excluded.record_hash",
                fields + (self._hash(b"authority", fields),),
            )
        return revision

    def metadata(self, actor, *, service_id, loadpoint_index):
        with self.database.connection() as connection:
            connection.execute("BEGIN")
            self._services._assert_admin(connection, actor)
            selected = self._services._select_evcc_connection(connection)
            if selected is None or selected.id != service_id:
                raise ApiError("not_found", 404)
            row = connection.execute(
                "SELECT * FROM evcc_current_authorities WHERE service_id=? AND loadpoint_index=?",
                (service_id, loadpoint_index),
            ).fetchone()
        if row is None:
            return {
                "authorityRevision": 0,
                "authorizedServiceRevision": None,
                "currentServiceRevision": selected.revision,
                "enabled": False,
                "status": "missing",
            }
        self._verify_authority(row)
        current = row["service_revision"] == selected.revision
        return {
            "authorityRevision": row["authority_revision"],
            "authorizedServiceRevision": row["service_revision"],
            "currentServiceRevision": selected.revision,
            "enabled": bool(row["enabled"]) if current else False,
            "status": "current" if current else "service_revision_changed",
        }

    def authorized(self, observation, loadpoint_index, schedule_revision):
        with self.database.connection() as connection:
            row = connection.execute(
                "SELECT * FROM evcc_current_authorities WHERE service_id=? AND loadpoint_index=?",
                (observation.service_id, loadpoint_index),
            ).fetchone()
        if row is None:
            return False
        self._verify_authority(row)
        loadpoints = [
            item for item in observation.loadpoints if item.index == loadpoint_index
        ]
        return (
            row["enabled"] == 1
            and row["service_revision"] == observation.service_revision
            and len(loadpoints) == 1
            and loadpoints[0].connected
            and loadpoints[0].charging
            and self._windows.is_single_current_window(observation, schedule_revision)
        )

    def power_budget_authorized(self, observation, loadpoint_index):
        """Return explicit admin authority for one electrically bounded load."""
        with self.database.connection() as connection:
            row = connection.execute(
                "SELECT * FROM evcc_current_authorities "
                "WHERE service_id=? AND loadpoint_index=?",
                (observation.service_id, loadpoint_index),
            ).fetchone()
        if row is None:
            return False
        self._verify_authority(row)
        loadpoints = [
            item for item in observation.loadpoints
            if item.index == loadpoint_index
        ]
        return (
            row["enabled"] == 1
            and row["service_revision"] == observation.service_revision
            and len(loadpoints) == 1
            and loadpoints[0].connected
            and loadpoints[0].charging
            and loadpoints[0].phases_active in {1, 3}
            and loadpoints[0].voltage is not None
            and loadpoints[0].min_current_amp <= loadpoints[0].max_current_amp
        )

    @staticmethod
    def _charger_id(service_id, index):
        return hashlib.sha256(f"evcc:{service_id}:{index}".encode("ascii")).hexdigest()[:32]

    def _binding(self):
        binding = self._binding_resolver()
        if binding is None:
            raise EvccProviderError("provider_unavailable")
        binding.assert_current()
        return binding

    def _index(self, binding, charger_id):
        values = [
            index for index in range(1, 17)
            if self._charger_id(binding.connection.service_id, index) == charger_id
        ]
        if len(values) != 1:
            raise EvccProviderError("provider_binding_changed")
        return values[0]

    def _save_effect(self, plan_hash, status, observed):
        now = self._clock()
        with self.database.transaction() as connection:
            row = connection.execute(
                "SELECT * FROM evcc_current_effects WHERE plan_hash=?", (plan_hash,)
            ).fetchone()
            self._verify_effect(row)
            fields = self._effect_fields(
                row, status=status, observed=observed, updated=now
            )
            connection.execute(
                "UPDATE evcc_current_effects SET status=?,observed_current_amp=?,"
                "updated_at=?,record_hash=? WHERE plan_hash=?",
                (status, observed, now, self._hash(b"effect", fields), plan_hash),
            )

    def _post(self, binding, index, target, assert_control_current):
        transport = None
        try:
            headers = {"Accept": "application/json"}
            if binding.connection.api_key is not None:
                headers["Authorization"] = "Bearer " + binding.connection.api_key
            factory = self._transport_factory or ServiceTransport
            transport = factory(
                binding.connection.base_url, timeout=5.0, max_bytes=4096
            )
            response = transport.request(
                "POST",
                f"/api/loadpoints/{index}/maxcurrent/{target}",
                headers=headers,
                before_send=assert_control_current,
            )
            binding.assert_current()
            media = [
                value.split(";", 1)[0].strip().lower()
                for name, value in response.headers
                if name.lower() == "content-type"
            ]
            value = json.loads(response.body)
            if (
                response.status != 200
                or media != ["application/json"]
                or type(value) not in (int, float)
                or isinstance(value, bool)
                or not math.isfinite(value)
                or value != target
            ):
                raise EvccProviderError("provider_protocol_changed")
        except (ProbeTransportError, OSError, TypeError, ValueError, json.JSONDecodeError):
            raise EvccProviderError("provider_unavailable") from None
        finally:
            if transport is not None:
                transport.close()

    def _observe(self, binding, index):
        factory = self._transport_factory or ServiceTransport
        value = EvccHttpReader(
            self._clock, transport_factory=factory
        ).state(binding.connection)
        binding.assert_current()
        matches = [item for item in value.loadpoints if item.index == index]
        if len(matches) != 1:
            raise EvccProviderError("provider_protocol_changed")
        return matches[0].max_current_amp

    @staticmethod
    def _power_authority_matches(authority, observation):
        return (
            authority.meter_id == observation.service_id
            and authority.meter_revision == observation.meter_revision
            and authority.tariff_revision == observation.tariff_revision
            and authority.load_registry_revision == observation.load_registry_revision
            and authority.grid_limit_revision == observation.grid_limit_revision
            and authority.override_revision == observation.state_revision
            and authority.plan_revision == observation.state_revision
            and authority.max_grid_w == observation.physical_grid_limit_w
        )

    def _power_targets(self, observation, actions, *, require_revision):
        if (not isinstance(actions, tuple) or not 1 <= len(actions) <= 16):
            raise EvccProviderError("provider_read_only")
        loadpoints = {item.index: item for item in observation.loadpoints}
        result = []
        seen = set()
        total_reduction = 0
        for action in actions:
            if type(action) is not dict or set(action) != {
                    "load_id", "load_revision", "reduction_w", "target_w",
                    "priority"}:
                raise EvccProviderError("provider_read_only")
            match = _POWER_LOAD.fullmatch(action["load_id"])
            index = int(match.group(1)) if match is not None else 0
            item = loadpoints.get(index)
            if (index in seen or item is None
                    or require_revision and action["load_revision"] != item.revision
                    or type(action["reduction_w"]) is not int
                    or type(action["target_w"]) is not int
                    or type(action["priority"]) is not int
                    or action["priority"] != item.priority
                    or action["reduction_w"] <= 0
                    or action["target_w"] < 0
                    or require_revision
                    and action["reduction_w"] + action["target_w"]
                    != item.charge_power_w
                    or not self.power_budget_authorized(observation, index)):
                raise EvccProviderError("provider_read_only")
            denominator = item.voltage * item.phases_active
            minimum_w = denominator * item.min_current_amp
            target_current = action["target_w"] // denominator
            if (action["target_w"] < minimum_w
                    or target_current < item.min_current_amp
                    or require_revision
                    and target_current >= item.max_current_amp
                    or not require_revision
                    and target_current > item.max_current_amp
                    or target_current * denominator > action["target_w"]):
                raise EvccProviderError("provider_read_only")
            seen.add(index)
            total_reduction += action["reduction_w"]
            result.append((
                index, target_current, action["target_w"], item.revision,
                item.voltage, item.phases_active, item.min_current_amp,
            ))
        return tuple(result), total_reduction

    def apply_power_budget_authorized(
            self, authority, *, plan_hash, actions):
        if (not authority.can_control
                or re.fullmatch(r"[0-9a-f]{64}", plan_hash or "") is None):
            raise EvccProviderError("provider_read_only")
        binding = self._binding()
        observation = EvccHttpReader(
            self._clock,
            transport_factory=self._transport_factory or ServiceTransport,
        ).state(binding.connection)
        binding.assert_current()
        if not self._power_authority_matches(authority, observation):
            raise EvccProviderError("provider_snapshot_changed")
        targets, total_reduction = self._power_targets(
            observation, actions, require_revision=True)
        if total_reduction > authority.max_shed_w:
            raise EvccProviderError("provider_read_only")
        for position, target_row in enumerate(targets):
            index, target, _target_w, revision, voltage, phases, minimum = target_row

            def assert_control_current(
                    index=index, position=position, revision=revision,
                    voltage=voltage, phases=phases, minimum=minimum):
                binding.assert_current()
                fresh = EvccHttpReader(
                    self._clock,
                    transport_factory=self._transport_factory or ServiceTransport,
                ).state(binding.connection)
                binding.assert_current()
                values = {item.index: item for item in fresh.loadpoints}
                current = values.get(index)
                prior = targets[:position]
                if (fresh.service_id != observation.service_id
                        or fresh.service_revision != observation.service_revision
                        or fresh.physical_grid_limit_w
                        != observation.physical_grid_limit_w
                        or current is None or current.revision != revision
                        or (current.voltage, current.phases_active,
                            current.min_current_amp) != (voltage, phases, minimum)
                        or not self.power_budget_authorized(fresh, index)
                        or any(
                            values.get(previous_index) is None
                            or values[previous_index].max_current_amp
                            != previous_target
                            or values[previous_index].charge_power_w
                            > previous_target_w
                            for (previous_index, previous_target,
                                 previous_target_w, *_rest) in prior)):
                    raise EvccProviderError("provider_read_only")

            self._post(binding, index, target, assert_control_current)

    def readback_power_budget_authorized(
            self, authority, *, plan_hash, actions):
        if re.fullmatch(r"[0-9a-f]{64}", plan_hash or "") is None:
            return None
        binding = self._binding()
        observation = EvccHttpReader(
            self._clock,
            transport_factory=self._transport_factory or ServiceTransport,
        ).state(binding.connection)
        binding.assert_current()
        if (authority.meter_id != observation.service_id
                or authority.max_grid_w != observation.physical_grid_limit_w):
            return None
        try:
            targets, _total = self._power_targets(
                observation, actions, require_revision=False)
        except EvccProviderError:
            return None
        loadpoints = {item.index: item for item in observation.loadpoints}
        if any(loadpoints[index].max_current_amp != target
               or loadpoints[index].charge_power_w > target_w
               for index, target, target_w, *_rest in targets):
            return None
        return plan_hash

    def apply_authorized(self, authority, *, plan_hash, slots):
        now = self._clock()
        if (
            not authority.can_control
            or re.fullmatch(r"[0-9a-f]{64}", plan_hash or "") is None
            or not isinstance(slots, tuple)
            or len(slots) != 1
        ):
            raise EvccProviderError("provider_read_only")
        slot = slots[0]
        if (
            type(slot) is not dict
            or type(slot.get("current_amp")) is not int
            or not 1 <= slot["current_amp"] <= authority.max_current_amp
            or type(slot.get("start_at")) not in (int, float)
            or type(slot.get("end_at")) not in (int, float)
            or not slot["start_at"] <= now < slot["end_at"]
        ):
            raise EvccProviderError("provider_read_only")
        binding = self._binding()
        index = self._index(binding, authority.charger_id)
        factory = self._transport_factory or ServiceTransport
        observation = EvccHttpReader(
            self._clock, transport_factory=factory
        ).state(binding.connection)
        binding.assert_current()
        if not self.authorized(observation, index, authority.schedule_revision):
            raise EvccProviderError("provider_read_only")
        target = slot["current_amp"]
        fields = (
            plan_hash,
            binding.connection.service_id,
            binding.connection.revision,
            authority.charger_id,
            authority.charger_revision,
            authority.schedule_revision,
            index,
            target,
            "reserved",
            None,
            now,
        )
        with self.database.transaction() as connection:
            old = connection.execute(
                "SELECT * FROM evcc_current_effects WHERE plan_hash=?", (plan_hash,)
            ).fetchone()
            if old is not None:
                self._verify_effect(old)
                if self._effect_fields(old)[:8] != fields[:8]:
                    raise EvccProviderError("provider_snapshot_changed")
                return
            if connection.execute(
                "SELECT COUNT(*) FROM evcc_current_effects"
            ).fetchone()[0] >= MAX_RECORDS:
                raise EvccProviderError("provider_journal_full")
            connection.execute(
                "INSERT INTO evcc_current_effects VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                fields + (self._hash(b"effect", fields),),
            )
        try:
            def assert_control_current():
                binding.assert_current()
                if not self.authorized(
                    observation, index, authority.schedule_revision
                ):
                    raise EvccProviderError("provider_read_only")

            self._post(binding, index, target, assert_control_current)
            observed = self._observe(binding, index)
            self._save_effect(
                plan_hash, "verified" if observed == target else "mismatch", observed
            )
        except Exception:
            self._save_effect(plan_hash, "uncertain", None)
            raise

    def readback_authorized(self, authority, *, plan_hash):
        binding = self._binding()
        with self.database.connection() as connection:
            row = connection.execute(
                "SELECT * FROM evcc_current_effects WHERE plan_hash=?", (plan_hash,)
            ).fetchone()
        self._verify_effect(row)
        if (
            (row["service_id"], row["service_revision"])
            != (binding.connection.service_id, binding.connection.revision)
            or row["charger_id"] != authority.charger_id
            or row["charger_revision"] != authority.charger_revision
            or row["schedule_revision"] != authority.schedule_revision
        ):
            raise EvccProviderError("provider_snapshot_changed")
        if row["status"] != "verified":
            return None
        observed = self._observe(binding, row["loadpoint_index"])
        status = "verified" if observed == row["target_current_amp"] else "mismatch"
        return plan_hash if status == "verified" else None

    def apply(self, *, plan_hash, slots):
        raise EvccProviderError("provider_read_only")

    def readback(self):
        return None
