"""Durable, explicitly accepted future energy windows for evcc F46 planning."""

from dataclasses import dataclass
import hashlib
import hmac
import json
import math
import re
import sqlite3

from ..errors import ApiError, StartupError
from ..ev_charging.service import EnergyInputs, EnergySlot, ProviderState
from .provider import EvccEnergyProjection, EvccObservation


MAX_SLOTS = 192
MAX_HORIZON_SECONDS = 48 * 60 * 60


TABLE = """CREATE TABLE evcc_energy_windows (
    service_id TEXT PRIMARY KEY,
    service_revision INTEGER NOT NULL CHECK(service_revision > 0),
    accepted_revision INTEGER NOT NULL CHECK(accepted_revision > 0),
    accepted_at REAL NOT NULL,
    expires_at REAL NOT NULL,
    payload TEXT NOT NULL,
    record_hash TEXT NOT NULL)"""


def migrate_evcc_energy_windows(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='evcc_energy_windows_schema'"
        ).fetchone()
        row = connection.execute(
            "SELECT type,sql FROM sqlite_master WHERE name='evcc_energy_windows'"
        ).fetchone()
        if marker is None:
            if row is not None:
                raise ValueError("unmarked_evcc_energy_windows")
            connection.execute(TABLE)
            connection.execute(
                "INSERT INTO metadata VALUES('evcc_energy_windows_schema','1')"
            )
            return
        if (
            marker["value"] != "1"
            or row is None
            or row["type"] != "table"
            or " ".join(row["sql"].split()) != " ".join(TABLE.split())
        ):
            raise ValueError("invalid_evcc_energy_windows")
    except (sqlite3.Error, TypeError, ValueError):
        raise StartupError("evcc_energy_windows_storage_invalid") from None


@dataclass(frozen=True)
class AcceptedWindowSlot:
    start_at: float
    end_at: float
    tariff_micros_per_kwh: int
    solar_surplus_w: int
    home_budget_w: int
    solar_energy_wh: int | None = None
    load_energy_wh: int | None = None
    export_tariff_micros_per_kwh: int | None = None


@dataclass(frozen=True)
class AcceptedEnergyWindows:
    tariff_revision: int
    solar_revision: int
    power_budget_revision: int
    override_revision: int
    observed_at: float
    expires_at: float
    slots: tuple[AcceptedWindowSlot, ...]


class EvccEnergyWindowStore:
    def __init__(self, database, *, audit_key, clock, services):
        if not isinstance(audit_key, bytes) or len(audit_key) < 32 or not callable(clock):
            raise ValueError("invalid_evcc_energy_window_store")
        self.database = database
        self._key = audit_key
        self._clock = clock
        self._services = services

    def _hash(self, values) -> str:
        return hmac.new(
            self._key,
            b"larenor-evcc-energy-windows-v1\0"
            + json.dumps(values, sort_keys=True, separators=(",", ":")).encode(),
            hashlib.sha256,
        ).hexdigest()

    @staticmethod
    def _finite(value) -> bool:
        return type(value) in (int, float) and math.isfinite(value)

    def _validate(self, value: AcceptedEnergyWindows, now: float) -> None:
        if not isinstance(value, AcceptedEnergyWindows):
            raise ApiError("invalid_request")
        revisions = (
            value.tariff_revision,
            value.solar_revision,
            value.power_budget_revision,
            value.override_revision,
        )
        if (
            any(type(item) is not int or not 1 <= item <= 2**63 - 1 for item in revisions)
            or not self._finite(value.observed_at)
            or not self._finite(value.expires_at)
            or value.observed_at > now
            or now - value.observed_at > 300
            or not now < value.expires_at <= now + MAX_HORIZON_SECONDS
            or not isinstance(value.slots, tuple)
            or not 1 <= len(value.slots) <= MAX_SLOTS
        ):
            raise ApiError("invalid_request")
        previous_end = now
        for slot in value.slots:
            if (
                not isinstance(slot, AcceptedWindowSlot)
                or not self._finite(slot.start_at)
                or not self._finite(slot.end_at)
                or slot.start_at < now
                or slot.start_at < previous_end
                or slot.end_at <= slot.start_at
                or slot.end_at - slot.start_at > 3600
                or slot.end_at > value.expires_at
                or type(slot.tariff_micros_per_kwh) is not int
                or not -10_000_000 <= slot.tariff_micros_per_kwh <= 10_000_000
                or type(slot.solar_surplus_w) is not int
                or not 0 <= slot.solar_surplus_w <= 100_000
                or type(slot.home_budget_w) is not int
                or not 0 <= slot.home_budget_w <= 100_000
                or (slot.solar_energy_wh is None) != (slot.load_energy_wh is None)
                or slot.solar_energy_wh is not None
                and (
                    type(slot.solar_energy_wh) is not int
                    or not 0 <= slot.solar_energy_wh <= 10**9
                    or type(slot.load_energy_wh) is not int
                    or not 0 <= slot.load_energy_wh <= 10**9
                )
                or slot.export_tariff_micros_per_kwh is not None
                and (
                    type(slot.export_tariff_micros_per_kwh) is not int
                    or not -10_000_000
                    <= slot.export_tariff_micros_per_kwh
                    <= 10_000_000
                )
            ):
                raise ApiError("invalid_request")
            previous_end = slot.end_at

    def _decode(self, row) -> AcceptedEnergyWindows:
        try:
            fields = (
                row["service_id"],
                row["service_revision"],
                row["accepted_revision"],
                row["accepted_at"],
                row["expires_at"],
                row["payload"],
            )
            if not hmac.compare_digest(row["record_hash"], self._hash(fields)):
                raise ValueError("record_hash")
            raw = json.loads(row["payload"])
            if type(raw) is not dict or set(raw) != {
                "tariff_revision",
                "solar_revision",
                "power_budget_revision",
                "override_revision",
                "observed_at",
                "slots",
            }:
                raise ValueError("payload")
            slots = raw.pop("slots")
            if type(slots) is not list:
                raise ValueError("slots")
            value = AcceptedEnergyWindows(
                **raw,
                expires_at=row["expires_at"],
                slots=tuple(AcceptedWindowSlot(**item) for item in slots),
            )
            if (
                re.fullmatch(r"[0-9a-f]{32}", row["service_id"]) is None
                or type(row["service_revision"]) is not int
                or row["service_revision"] < 1
                or type(row["accepted_revision"]) is not int
                or row["accepted_revision"] < 1
            ):
                raise ValueError("identity")
            self._validate(value, row["accepted_at"])
            return value
        except (ApiError, KeyError, TypeError, ValueError, json.JSONDecodeError):
            raise StartupError("evcc_energy_windows_storage_invalid") from None

    def validate_storage(self) -> None:
        try:
            with self.database.connection() as connection:
                rows = connection.execute(
                    "SELECT * FROM evcc_energy_windows ORDER BY service_id LIMIT 129"
                ).fetchall()
                if len(rows) > 128:
                    raise ValueError("too_many_rows")
                for row in rows:
                    self._decode(row)
        except (sqlite3.Error, ValueError, StartupError):
            raise StartupError("evcc_energy_windows_storage_invalid") from None

    def accept(
        self,
        actor,
        *,
        service_id: str,
        service_revision: int,
        expected_accepted_revision: int,
        windows: AcceptedEnergyWindows,
    ) -> int:
        now = self._clock()
        self._validate(windows, now)
        with self.database.transaction() as connection:
            self._services._assert_admin(connection, actor)
            self._services._evcc_connection_in(connection, service_id, service_revision)
            row = connection.execute(
                "SELECT * FROM evcc_energy_windows WHERE service_id=?", (service_id,)
            ).fetchone()
            current = 0 if row is None else row["accepted_revision"]
            if current != expected_accepted_revision or current >= 2**63 - 1:
                raise ApiError("revision_conflict", 409)
            revision = current + 1
            payload = json.dumps(
                {
                    "tariff_revision": windows.tariff_revision,
                    "solar_revision": windows.solar_revision,
                    "power_budget_revision": windows.power_budget_revision,
                    "override_revision": windows.override_revision,
                    "observed_at": windows.observed_at,
                    "slots": [slot.__dict__ for slot in windows.slots],
                },
                sort_keys=True,
                separators=(",", ":"),
            )
            fields = (
                service_id,
                service_revision,
                revision,
                now,
                windows.expires_at,
                payload,
            )
            connection.execute(
                "INSERT INTO evcc_energy_windows VALUES(?,?,?,?,?,?,?) "
                "ON CONFLICT(service_id) DO UPDATE SET "
                "service_revision=excluded.service_revision,"
                "accepted_revision=excluded.accepted_revision,"
                "accepted_at=excluded.accepted_at,expires_at=excluded.expires_at,"
                "payload=excluded.payload,record_hash=excluded.record_hash",
                fields + (self._hash(fields),),
            )
        return revision

    def metadata(self, actor, *, service_id: str) -> dict:
        now = self._clock()
        with self.database.connection() as connection:
            connection.execute("BEGIN")
            self._services._assert_admin(connection, actor)
            selected = self._services._select_evcc_connection(connection)
            if selected is None or selected.id != service_id:
                raise ApiError("not_found", 404)
            row = connection.execute(
                "SELECT * FROM evcc_energy_windows WHERE service_id=?", (service_id,)
            ).fetchone()
        if row is None:
            return {
                "acceptedRevision": 0,
                "acceptedServiceRevision": None,
                "currentServiceRevision": selected.revision,
                "status": "missing",
            }
        value = self._decode(row)
        if row["service_revision"] != selected.revision:
            status = "service_revision_changed"
        elif now >= value.expires_at:
            status = "expired"
        elif now - value.observed_at > 300:
            status = "stale"
        else:
            status = "current"
        return {
            "acceptedRevision": row["accepted_revision"],
            "acceptedServiceRevision": row["service_revision"],
            "currentServiceRevision": selected.revision,
            "status": status,
        }

    def projection(self, observation: EvccObservation) -> EvccEnergyProjection:
        revision, value = self.current(observation)
        inputs = EnergyInputs(
            tariff_revision=value.tariff_revision,
            solar_revision=value.solar_revision,
            power_budget_revision=value.power_budget_revision,
            override_revision=value.override_revision,
            provider_states=(
                ProviderState("tariff", value.tariff_revision, "verified", value.observed_at),
                ProviderState("solar", value.solar_revision, "verified", value.observed_at),
                ProviderState(
                    "power_budget",
                    value.power_budget_revision,
                    "verified",
                    value.observed_at,
                ),
            ),
            slots=tuple(
                EnergySlot(
                    item.start_at,
                    item.end_at,
                    item.tariff_micros_per_kwh,
                    item.solar_surplus_w,
                    item.home_budget_w,
                )
                for item in value.slots
            ),
            manual_override=None,
        )
        return EvccEnergyProjection(revision, inputs)

    def current(
        self, observation: EvccObservation
    ) -> tuple[int, AcceptedEnergyWindows]:
        now = self._clock()
        with self.database.connection() as connection:
            row = connection.execute(
                "SELECT * FROM evcc_energy_windows WHERE service_id=?",
                (observation.service_id,),
            ).fetchone()
        if row is None or row["service_revision"] != observation.service_revision:
            raise ApiError("energy_provider_unavailable", 503)
        value = self._decode(row)
        if now >= value.expires_at or now - value.observed_at > 300:
            raise ApiError("energy_provider_unavailable", 503)
        return row["accepted_revision"], value

    def is_single_current_window(
        self, observation: EvccObservation, schedule_revision: int
    ) -> bool:
        with self.database.connection() as connection:
            row = connection.execute(
                "SELECT * FROM evcc_energy_windows WHERE service_id=?",
                (observation.service_id,),
            ).fetchone()
        if (
            row is None
            or row["service_revision"] != observation.service_revision
            or row["accepted_revision"] != schedule_revision
        ):
            return False
        value = self._decode(row)
        now = self._clock()
        return (
            now < value.expires_at
            and now - value.observed_at <= 300
            and len(value.slots) == 1
            and value.slots[0].start_at <= now < value.slots[0].end_at
        )
