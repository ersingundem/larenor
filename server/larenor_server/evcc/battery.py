"""Sealed operator limits bound to a live evcc home-battery catalogue."""

from dataclasses import dataclass
import hashlib
import hmac
import json
import math
import re
import sqlite3

from ..errors import ApiError, StartupError
from .provider import EvccHttpReader, EvccObservation, EvccProviderError


TABLE = """CREATE TABLE evcc_battery_bindings (
    service_id TEXT PRIMARY KEY,
    service_revision INTEGER NOT NULL CHECK(service_revision > 0),
    binding_revision INTEGER NOT NULL CHECK(binding_revision > 0),
    battery_catalog_revision INTEGER NOT NULL CHECK(battery_catalog_revision > 0),
    backup_reserve_percent INTEGER NOT NULL CHECK(backup_reserve_percent BETWEEN 0 AND 100),
    max_charge_power_w INTEGER NOT NULL CHECK(max_charge_power_w > 0),
    max_discharge_power_w INTEGER NOT NULL CHECK(max_discharge_power_w > 0),
    accepted_at REAL NOT NULL,
    record_hash TEXT NOT NULL)"""

_IDENTITY = re.compile(r"[0-9a-f]{32}\Z")


def migrate_evcc_battery_bindings(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='evcc_battery_bindings_schema'"
        ).fetchone()
        row = connection.execute(
            "SELECT type,sql FROM sqlite_master WHERE name='evcc_battery_bindings'"
        ).fetchone()
        if marker is None:
            if row is not None:
                raise ValueError("unmarked_evcc_battery_bindings")
            connection.execute(TABLE)
            connection.execute(
                "INSERT INTO metadata VALUES('evcc_battery_bindings_schema','1')"
            )
            return
        if (
            marker["value"] != "1"
            or row is None
            or row["type"] != "table"
            or " ".join(row["sql"].split()) != " ".join(TABLE.split())
        ):
            raise ValueError("invalid_evcc_battery_bindings")
    except (sqlite3.Error, TypeError, ValueError):
        raise StartupError("evcc_battery_bindings_storage_invalid") from None


@dataclass(frozen=True)
class EvccBatteryBinding:
    service_id: str
    service_revision: int
    binding_revision: int
    battery_catalog_revision: int
    backup_reserve_percent: int
    max_charge_power_w: int
    max_discharge_power_w: int


class EvccBatteryBindingStore:
    def __init__(
        self,
        database,
        *,
        audit_key: bytes,
        clock,
        services,
        binding_resolver,
        transport_factory=None,
    ):
        if (
            not isinstance(audit_key, bytes)
            or len(audit_key) < 32
            or not callable(clock)
            or not callable(binding_resolver)
        ):
            raise ValueError("invalid_evcc_battery_binding_store")
        self.database = database
        self._key = audit_key
        self._clock = clock
        self._services = services
        self._binding_resolver = binding_resolver
        self._reader = EvccHttpReader(clock, transport_factory=transport_factory)

    def _hash(self, values) -> str:
        return hmac.new(
            self._key,
            b"larenor-evcc-battery-binding-v1\0"
            + json.dumps(values, separators=(",", ":")).encode("ascii"),
            hashlib.sha256,
        ).hexdigest()

    def _decode(self, row) -> EvccBatteryBinding:
        try:
            values = (
                row["service_id"],
                row["service_revision"],
                row["binding_revision"],
                row["battery_catalog_revision"],
                row["backup_reserve_percent"],
                row["max_charge_power_w"],
                row["max_discharge_power_w"],
                row["accepted_at"],
            )
            if not hmac.compare_digest(row["record_hash"], self._hash(values)):
                raise ValueError("record_hash")
            value = EvccBatteryBinding(*values[:-1])
            if (
                _IDENTITY.fullmatch(value.service_id) is None
                or any(
                    type(item) is not int or not 1 <= item <= 2**63 - 1
                    for item in (
                        value.service_revision,
                        value.binding_revision,
                        value.battery_catalog_revision,
                        value.max_charge_power_w,
                        value.max_discharge_power_w,
                    )
                )
                or type(value.backup_reserve_percent) is not int
                or not 0 <= value.backup_reserve_percent <= 100
                or type(row["accepted_at"]) not in (int, float)
                or not math.isfinite(row["accepted_at"])
                or row["accepted_at"] < 0
            ):
                raise ValueError("fields")
            return value
        except (KeyError, TypeError, ValueError):
            raise StartupError("evcc_battery_bindings_storage_invalid") from None

    def validate_storage(self) -> None:
        try:
            with self.database.connection() as connection:
                rows = connection.execute(
                    "SELECT * FROM evcc_battery_bindings ORDER BY service_id LIMIT 129"
                ).fetchall()
            if len(rows) > 128:
                raise ValueError("too_many_rows")
            for row in rows:
                self._decode(row)
        except (sqlite3.Error, StartupError, ValueError):
            raise StartupError("evcc_battery_bindings_storage_invalid") from None

    def _observation(self, service_id, service_revision) -> EvccObservation:
        try:
            binding = self._binding_resolver()
            if (
                binding is None
                or binding.connection.service_id != service_id
                or binding.connection.revision != service_revision
            ):
                raise EvccProviderError("provider_binding_changed")
            binding.assert_current()
            observation = self._reader.state(binding.connection)
            binding.assert_current()
        except EvccProviderError:
            raise ApiError("energy_provider_unavailable", 503) from None
        if observation.battery is None:
            raise ApiError("energy_provider_unavailable", 503)
        return observation

    def accept(
        self,
        actor,
        *,
        service_id: str,
        service_revision: int,
        expected_binding_revision: int,
        expected_battery_catalog_revision: int,
        backup_reserve_percent: int,
        max_charge_power_w: int,
        max_discharge_power_w: int,
    ) -> int:
        if (
            _IDENTITY.fullmatch(service_id or "") is None
            or type(service_revision) is not int
            or type(expected_binding_revision) is not int
            or type(expected_battery_catalog_revision) is not int
            or type(backup_reserve_percent) is not int
            or not 0 <= backup_reserve_percent <= 100
            or type(max_charge_power_w) is not int
            or type(max_discharge_power_w) is not int
            or not 1 <= max_charge_power_w <= 1_000_000
            or not 1 <= max_discharge_power_w <= 1_000_000
        ):
            raise ApiError("invalid_request")
        observation = self._observation(service_id, service_revision)
        battery = observation.battery
        if (
            battery.catalog_revision != expected_battery_catalog_revision
            or max_charge_power_w > observation.physical_grid_limit_w
            or max_discharge_power_w > observation.physical_grid_limit_w
        ):
            raise ApiError("revision_conflict", 409)
        now = self._clock()
        with self.database.transaction() as connection:
            self._services._assert_admin(connection, actor)
            self._services._evcc_connection_in(
                connection, service_id, service_revision
            )
            row = connection.execute(
                "SELECT * FROM evcc_battery_bindings WHERE service_id=?",
                (service_id,),
            ).fetchone()
            try:
                current = 0 if row is None else self._decode(row).binding_revision
            except StartupError:
                raise ApiError("energy_provider_unavailable", 503) from None
            if current != expected_binding_revision or current >= 2**63 - 1:
                raise ApiError("revision_conflict", 409)
            revision = current + 1
            values = (
                service_id,
                service_revision,
                revision,
                battery.catalog_revision,
                backup_reserve_percent,
                max_charge_power_w,
                max_discharge_power_w,
                now,
            )
            connection.execute(
                "INSERT INTO evcc_battery_bindings VALUES(?,?,?,?,?,?,?,?,?) "
                "ON CONFLICT(service_id) DO UPDATE SET "
                "service_revision=excluded.service_revision,"
                "binding_revision=excluded.binding_revision,"
                "battery_catalog_revision=excluded.battery_catalog_revision,"
                "backup_reserve_percent=excluded.backup_reserve_percent,"
                "max_charge_power_w=excluded.max_charge_power_w,"
                "max_discharge_power_w=excluded.max_discharge_power_w,"
                "accepted_at=excluded.accepted_at,record_hash=excluded.record_hash",
                values + (self._hash(values),),
            )
        return revision

    def current(self, observation: EvccObservation) -> EvccBatteryBinding:
        battery = observation.battery
        if battery is None:
            raise EvccProviderError("provider_unavailable")
        try:
            with self.database.connection() as connection:
                row = connection.execute(
                    "SELECT * FROM evcc_battery_bindings WHERE service_id=?",
                    (observation.service_id,),
                ).fetchone()
            if row is None:
                raise EvccProviderError("provider_unavailable")
            value = self._decode(row)
        except StartupError:
            raise EvccProviderError("provider_binding_changed") from None
        if (
            value.service_revision != observation.service_revision
            or value.battery_catalog_revision != battery.catalog_revision
        ):
            raise EvccProviderError("provider_binding_changed")
        return value

    def metadata(self, actor, *, service_id: str) -> dict:
        with self.database.connection() as connection:
            connection.execute("BEGIN")
            self._services._assert_admin(connection, actor)
            selected = self._services._select_evcc_connection(connection)
            if selected is None or selected.id != service_id:
                raise ApiError("not_found", 404)
            row = connection.execute(
                "SELECT * FROM evcc_battery_bindings WHERE service_id=?",
                (service_id,),
            ).fetchone()
        observation = self._observation(service_id, selected.revision)
        battery = observation.battery
        if row is None:
            return {
                "bindingRevision": 0,
                "acceptedServiceRevision": None,
                "currentServiceRevision": selected.revision,
                "acceptedBatteryCatalogRevision": None,
                "currentBatteryCatalogRevision": battery.catalog_revision,
                "status": "missing",
            }
        value = self._decode(row)
        status = (
            "service_revision_changed"
            if value.service_revision != selected.revision
            else "battery_catalog_changed"
            if value.battery_catalog_revision != battery.catalog_revision
            else "current"
        )
        return {
            "bindingRevision": value.binding_revision,
            "acceptedServiceRevision": value.service_revision,
            "currentServiceRevision": selected.revision,
            "acceptedBatteryCatalogRevision": value.battery_catalog_revision,
            "currentBatteryCatalogRevision": battery.catalog_revision,
            "status": status,
        }
