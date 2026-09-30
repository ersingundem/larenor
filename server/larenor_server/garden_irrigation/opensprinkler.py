"""Durable OpenSprinkler 2.2.1 timed station executor.

The firmware timer owns automatic closure. A command is durably marked as
dispatching before the mutating `/cm` request, so an indeterminate response is
reconciled and never resent. Applied receipts require one isolated manual run,
the same controller boot, a closed station, and measured flow-pulse delta.
"""

from dataclasses import dataclass, field
from contextvars import ContextVar
from decimal import Decimal, ROUND_HALF_UP
import hashlib
import hmac
import json
import re
import sqlite3
import time

from ..errors import ApiError, StartupError
from ..services.transport import ProbeResponse, ProbeTransportError, ServiceTransport
from ..vault import validate_json_bounds
from .models import (
    IrrigationZone,
    ValveReadback,
    ValveStopCommand,
    ValveWorkerCommand,
    WorkerValveReadback,
    WorkerValveStopReadback,
)


_ID = re.compile(r"[0-9a-f]{32}\Z")
_MD5 = re.compile(r"[0-9a-f]{32}\Z")
_MAX_BYTES = 65_536
_TIMEOUT = 5.0
_MAX_COMMANDS = 4096
_CONTROL_GUARD = ContextVar('opensprinkler_control_guard', default=None)


@dataclass(frozen=True)
class OpenSprinklerConnection:
    id: str
    revision: int
    base_url: str = field(repr=False)
    password_md5: str = field(repr=False)


@dataclass(frozen=True)
class OpenSprinklerBinding:
    connection: OpenSprinklerConnection = field(repr=False)
    station_index: int
    zone: IrrigationZone


class OpenSprinklerError(Exception):
    pass


def migrate_opensprinkler_commands(connection):
    row = connection.execute(
        "SELECT value FROM metadata WHERE key='opensprinkler_commands_schema'"
    ).fetchone()
    if row is not None and row["value"] != "1":
        raise ValueError("invalid_opensprinkler_commands_schema")
    connection.execute(
        """
        CREATE TABLE IF NOT EXISTS opensprinkler_commands (
            command_id TEXT PRIMARY KEY,
            request_hash TEXT NOT NULL,
            kind TEXT NOT NULL CHECK(kind IN ('run','stop')),
            state TEXT NOT NULL CHECK(state IN ('preparing','dispatching','final')),
            request_json TEXT NOT NULL,
            result_json TEXT,
            envelope_tag TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        )
        """
    )
    connection.execute(
        "INSERT OR REPLACE INTO metadata(key,value) VALUES"
        "('opensprinkler_commands_schema','1')"
    )


def _canonical(value):
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":"),
        allow_nan=False,
    )


def _unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError
        result[key] = value
    return result


def _object(response):
    if (
        not isinstance(response, ProbeResponse)
        or response.status != 200
        or not isinstance(response.body, bytes)
        or len(response.body) > _MAX_BYTES
    ):
        raise OpenSprinklerError()
    content_types = [
        value.split(";", 1)[0].strip().lower()
        for name, value in response.headers
        if name.lower() == "content-type"
    ]
    if content_types != ["application/json"]:
        raise OpenSprinklerError()
    try:
        value = json.loads(
            response.body.decode("utf-8"), object_pairs_hook=_unique,
            parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
        )
        validate_json_bounds(value)
    except (ValueError, TypeError, UnicodeError, RecursionError, json.JSONDecodeError):
        raise OpenSprinklerError() from None
    if type(value) is not dict:
        raise OpenSprinklerError()
    return value


class OpenSprinklerCommandStore:
    def __init__(self, db, key, clock):
        self._db, self._key, self._clock = db, key, clock

    def _tag(self, values):
        return hmac.new(
            self._key,
            b"larenor-opensprinkler-command-v1\0" + _canonical(values).encode(),
            hashlib.sha256,
        ).hexdigest()

    @staticmethod
    def _values(row):
        return [
            row["command_id"], row["request_hash"], row["kind"], row["state"],
            row["request_json"], row["result_json"], row["created_at"],
            row["updated_at"],
        ]

    def _validate(self, row):
        if (
            row is None or _ID.fullmatch(row["command_id"] or "") is None
            or not hmac.compare_digest(row["envelope_tag"], self._tag(self._values(row)))
        ):
            raise ValueError("invalid_opensprinkler_command")
        return row

    def validate_storage(self):
        try:
            with self._db.connection() as connection:
                rows = connection.execute(
                    "SELECT * FROM opensprinkler_commands LIMIT ?",
                    (_MAX_COMMANDS + 1,),
                ).fetchall()
                if len(rows) > _MAX_COMMANDS:
                    raise ValueError
                for row in rows:
                    self._validate(row)
        except (sqlite3.Error, ValueError, TypeError):
            raise StartupError("invalid_opensprinkler_command_storage") from None

    def begin(self, command, kind, request):
        request_json = _canonical(request)
        request_hash = hashlib.sha256(request_json.encode()).hexdigest()
        now = self._clock()
        try:
            with self._db.transaction() as connection:
                old = connection.execute(
                    "SELECT * FROM opensprinkler_commands WHERE command_id=?",
                    (command.commandId,),
                ).fetchone()
                if old is not None:
                    old = self._validate(old)
                    if old["request_hash"] != request_hash or old["kind"] != kind:
                        raise ApiError("idempotency_conflict", 409)
                    return old["state"], old["request_json"], old["result_json"]
                if connection.execute(
                    "SELECT COUNT(*) FROM opensprinkler_commands"
                ).fetchone()[0] >= _MAX_COMMANDS:
                    raise ApiError("irrigation_command_limit", 429)
                values = [
                    command.commandId, request_hash, kind, "preparing",
                    request_json, None, now, now,
                ]
                connection.execute(
                    "INSERT INTO opensprinkler_commands VALUES(?,?,?,?,?,?,?,?,?)",
                    (*values[:6], self._tag(values), *values[6:]),
                )
                return "new", request_json, None
        except ApiError:
            raise
        except (sqlite3.Error, ValueError, TypeError):
            raise ApiError("irrigation_command_storage_unavailable", 503) from None

    def finish(self, command_id, result):
        result_json = result.model_dump_json()
        now = self._clock()
        try:
            with self._db.transaction() as connection:
                row = self._validate(connection.execute(
                    "SELECT * FROM opensprinkler_commands WHERE command_id=?",
                    (command_id,),
                ).fetchone())
                if row["state"] == "final":
                    if row["result_json"] != result_json:
                        raise ValueError
                    return result
                values = [
                    row["command_id"], row["request_hash"], row["kind"], "final",
                    row["request_json"], result_json, row["created_at"], now,
                ]
                connection.execute(
                    "UPDATE opensprinkler_commands SET state='final',result_json=?,"
                    "envelope_tag=?,updated_at=? WHERE command_id=?",
                    (result_json, self._tag(values), now, command_id),
                )
                return result
        except (sqlite3.Error, ValueError, TypeError):
            raise ApiError("irrigation_command_storage_unavailable", 503) from None

    def prepare_dispatch(self, command_id, request):
        request_json = _canonical(request)
        now = self._clock()
        try:
            with self._db.transaction() as connection:
                row = self._validate(connection.execute(
                    "SELECT * FROM opensprinkler_commands WHERE command_id=?",
                    (command_id,),
                ).fetchone())
                if row["state"] != "preparing":
                    raise ValueError("invalid_opensprinkler_command_state")
                values = [
                    row["command_id"], row["request_hash"], row["kind"],
                    "dispatching", request_json, row["result_json"],
                    row["created_at"], now,
                ]
                connection.execute(
                    "UPDATE opensprinkler_commands SET state='dispatching',"
                    "request_json=?,envelope_tag=?,updated_at=? WHERE command_id=?",
                    (request_json, self._tag(values), now, command_id),
                )
                return request_json
        except (sqlite3.Error, ValueError, TypeError):
            raise ApiError("irrigation_command_storage_unavailable", 503) from None


class OpenSprinklerExecutor:
    def __init__(
        self, db, key, clock, binding_resolver, *, transport_factory=None,
        sleep=time.sleep, poll_seconds=1.0,
    ):
        if not callable(binding_resolver) or not callable(clock) or not callable(sleep):
            raise ValueError("invalid_opensprinkler_executor")
        self._clock, self._resolve, self._sleep = clock, binding_resolver, sleep
        self._poll = poll_seconds
        if not isinstance(poll_seconds, (int, float)) or not 0 < poll_seconds <= 5:
            raise ValueError("invalid_opensprinkler_executor")
        self._factory = transport_factory or ServiceTransport
        self._store = OpenSprinklerCommandStore(db, key, clock)
        self._store.validate_storage()

    @staticmethod
    def _binding(value, zone):
        if (
            not isinstance(value, OpenSprinklerBinding) or value.zone != zone
            or _ID.fullmatch(value.connection.id or "") is None
            or type(value.connection.revision) is not int
            or not 1 <= value.connection.revision <= 2**63 - 1
            or _MD5.fullmatch(value.connection.password_md5 or "") is None
            or type(value.station_index) is not int
            or not 0 <= value.station_index <= 255
        ):
            raise ApiError("irrigation_binding_changed", 409)
        return value

    def _request(self, binding, path, parameters):
        transport = None
        query = {"pw": binding.connection.password_md5, **parameters}
        def current():
            guard = _CONTROL_GUARD.get()
            if guard is not None:
                guard()
                if self._binding(self._resolve(binding.zone), binding.zone) != binding:
                    raise ApiError('irrigation_binding_changed', 409)
        try:
            current()
            transport = self._factory(
                binding.connection.base_url, timeout=_TIMEOUT, max_bytes=_MAX_BYTES
            )
            response = transport.request(
                "GET", path, headers={"Accept": "application/json"},
                query_parameters=query,
                before_send=current,
            )
            current()
            return _object(response)
        except (ProbeTransportError, OSError, ValueError, TypeError):
            raise OpenSprinklerError() from None
        finally:
            if transport is not None:
                transport.close()

    def _snapshot(self, binding, *, with_options=False):
        options = self._request(binding, "/jo", {}) if with_options else None
        attributes = self._request(binding, "/jn", {}) if with_options else None
        status = self._request(binding, "/jc", {})
        stations = self._request(binding, "/js", {})
        try:
            count = stations["nstations"]
            sn = stations["sn"]
            ps = status["ps"]
            if (
                type(count) is not int or not 1 <= count <= 256
                or type(sn) is not list or len(sn) != count
                or any(type(item) is not int or item not in (0, 1) for item in sn)
                or type(ps) is not list or len(ps) != count
                or any(
                    type(item) is not list or len(item) != 4
                    or any(type(child) is not int or child < 0 for child in item)
                    for item in ps
                )
                or binding.station_index >= count
                or type(status["lupt"]) is not int or status["lupt"] < 0
                or type(status["devt"]) is not int
                or not 1 <= status["devt"] <= 2**63 - 1
                or type(status["flcto"]) is not int or status["flcto"] < 0
                or type(status["flcrt"]) is not int or status["flcrt"] < 0
                or type(status["flwrt"]) is not int or status["flwrt"] <= 0
                or type(status["nq"]) is not int or status["nq"] < 0
                or status["en"] not in (0, 1) or type(status["en"]) is not int
                or type(status["ocs"]) is not int or not 0 <= status["ocs"] <= 255
            ):
                raise ValueError
            lrun = status["lrun"]
            sbits = status["sbits"]
            groups = (count + 7) // 8
            if (
                type(lrun) is not list or len(lrun) != 4
                or any(type(item) is not int or item < 0 for item in lrun)
                or type(sbits) is not list or len(sbits) != groups
                or any(type(item) is not int or not 0 <= item <= 255 for item in sbits)
                or any(
                    bool(sbits[index // 8] & (1 << (index % 8))) != bool(sn[index])
                    for index in range(count)
                )
                or status["nq"] != sum(item[0] != 0 for item in ps)
            ):
                raise ValueError
            if options is not None:
                if (
                    options.get("fwv") != 221
                    or options.get("fwm") != 5
                    or options.get("sn1t") != 2
                    or any(type(options.get(name)) is not int
                           or not 0 <= options[name] <= 255
                           for name in ("fpr0", "fpr1"))
                    or type(options.get("mas")) is not int
                    or any(options.get(name, 0) != 0
                           for name in ("mas", "mas2", "mas3", "mas4"))
                ):
                    raise ValueError
                if type(attributes) is not dict:
                    raise ValueError
                for name in ("stn_dis", "stn_spe"):
                    bits = attributes.get(name)
                    if (
                        type(bits) is not list or len(bits) != groups
                        or any(type(item) is not int or not 0 <= item <= 255
                               for item in bits)
                        or bits[binding.station_index // 8]
                        & (1 << (binding.station_index % 8))
                    ):
                        raise ValueError
                pulse_liters = Decimal(
                    (options["fpr1"] << 8) + options["fpr0"]
                ) / Decimal(100)
                if not Decimal("0.01") <= pulse_liters <= Decimal("655.35"):
                    raise ValueError
            else:
                pulse_liters = None
        except (KeyError, TypeError, ValueError):
            raise OpenSprinklerError() from None
        return {
            "options": options,
            "attributes": attributes,
            "pulseLiters": pulse_liters,
            "status": status,
            "stations": stations,
            "sn": sn,
            "ps": ps,
        }

    @staticmethod
    def _isolated(snapshot, station, *, running=None):
        active = {index for index, value in enumerate(snapshot["sn"]) if value}
        queued = {index for index, value in enumerate(snapshot["ps"]) if value[0]}
        if running is True:
            return active == {station} and queued == {station} and snapshot["ps"][station][0] == 99
        if running is False:
            return not active and not queued and snapshot["status"]["nq"] == 0
        return active <= {station} and queued <= {station}

    def readback(self, zone):
        binding = self._binding(self._resolve(zone), zone)
        value = self._snapshot(binding, with_options=True)
        if self._binding(self._resolve(zone), zone) != binding:
            raise OpenSprinklerError()
        station = binding.station_index
        return ValveReadback(
            schemaVersion=1, coreId=zone.coreId, homeId=zone.homeId, zone=zone,
            stateRevision=value["status"]["devt"],
            valveOpen=bool(value["sn"][station]),
            observedAtMs=int(self._clock() * 1000),
        )

    def run(self, command, *, cancelled=lambda: False, guard=lambda: None):
        token = _CONTROL_GUARD.set(guard)
        try:
            guard()
            result = self._run(command, cancelled=cancelled)
            guard()
            return result
        finally:
            _CONTROL_GUARD.reset(token)

    def _run(self, command, *, cancelled=lambda: False):
        command = ValveWorkerCommand.model_validate(command)
        binding = self._binding(self._resolve(command.zone), command.zone)
        request = {
            "command": command.model_dump(mode="json"),
            "connectionId": binding.connection.id,
            "connectionRevision": binding.connection.revision,
            "stationIndex": binding.station_index,
        }
        state, stored_request, result_json = self._store.begin(command, "run", request)
        if state == "final":
            return WorkerValveReadback.model_validate_json(result_json)
        if state in {"new", "preparing"}:
            before = self._snapshot(binding, with_options=True)
            if (
                before["status"]["en"] != 1 or before["status"]["ocs"] != 0
                or not self._isolated(before, binding.station_index, running=False)
            ):
                raise ApiError("revision_conflict", 409)
            request["before"] = {
                "boot": before["status"]["lupt"],
                "deviceTime": before["status"]["devt"],
                "flow": before["status"]["flcto"],
                "lastRun": before["status"]["lrun"],
                "pulseLiters": str(before["pulseLiters"]),
            }
            # Persist the reconciliation evidence before the only mutation.
            stored_request = self._store.prepare_dispatch(
                command.commandId, request
            )
            try:
                accepted = self._request(binding, "/cm", {
                    "sid": str(binding.station_index), "en": "1",
                    "t": str(command.durationSeconds), "qo": "1",
                })
                if accepted != {"result": 1}:
                    raise OpenSprinklerError()
            except OpenSprinklerError:
                pass
        persisted = json.loads(stored_request)
        before = persisted.get("before")
        if type(before) is not dict:
            raise ApiError("irrigation_command_unknown", 409)
        result = self._reconcile_run(binding, command, before, cancelled)
        return self._store.finish(command.commandId, result)

    def _reconcile_run(self, binding, command, before, cancelled):
        deadline = self._clock() + command.durationSeconds + 30
        observed_running = False
        latest = None
        while self._clock() <= deadline:
            if cancelled():
                raise OpenSprinklerError()
            try:
                latest = self._snapshot(binding)
            except OpenSprinklerError:
                self._sleep(self._poll)
                continue
            if latest["status"]["lupt"] != before["boot"]:
                break
            if self._isolated(latest, binding.station_index, running=True):
                observed_running = True
            elif self._isolated(latest, binding.station_index, running=False):
                break
            elif not self._isolated(latest, binding.station_index):
                break
            self._sleep(self._poll)
        completed = None if latest is None else latest["status"]["lrun"]
        exact_completed = (
            type(completed) is list
            and completed != before["lastRun"]
            and completed[0] == binding.station_index
            and completed[1] == 99
            and completed[2] == command.durationSeconds
            and before["deviceTime"] <= completed[3] <= latest["status"]["devt"]
        )
        if (
            latest is None or not (observed_running or exact_completed)
            or latest["status"]["lupt"] != before["boot"]
            or not self._isolated(latest, binding.station_index, running=False)
            or latest["status"]["flcto"] <= before["flow"]
            or not exact_completed
            or latest["status"]["devt"] <= command.expectedStateRevision
        ):
            raise OpenSprinklerError()
        delivered = (
            Decimal(latest["status"]["flcto"] - before["flow"])
            * Decimal(before["pulseLiters"]) * 1000
        ).quantize(Decimal("1"), rounding=ROUND_HALF_UP)
        if not 1 <= delivered <= 10_000_000_000:
            raise OpenSprinklerError()
        if self._binding(self._resolve(command.zone), command.zone) != binding:
            raise OpenSprinklerError()
        return WorkerValveReadback(
            schemaVersion=1, commandId=command.commandId, zone=command.zone,
            stateRevision=latest["status"]["devt"],
            valveOpen=False, deliveredMl=int(delivered), flowVerified=True,
            observedAtMs=int(self._clock() * 1000),
        )

    def stop(self, command, *, guard=lambda: None):
        token = _CONTROL_GUARD.set(guard)
        try:
            guard()
            result = self._stop(command)
            guard()
            return result
        finally:
            _CONTROL_GUARD.reset(token)

    def _stop(self, command):
        command = ValveStopCommand.model_validate(command)
        binding = self._binding(self._resolve(command.zone), command.zone)
        request = {
            "command": command.model_dump(mode="json"),
            "connectionId": binding.connection.id,
            "connectionRevision": binding.connection.revision,
            "stationIndex": binding.station_index,
        }
        state, stored_request, result_json = self._store.begin(command, "stop", request)
        if state == "final":
            return WorkerValveStopReadback.model_validate_json(result_json)
        if state in {"new", "preparing"}:
            before = self._snapshot(binding, with_options=True)
            request["before"] = {
                "boot": before["status"]["lupt"],
                "deviceTime": before["status"]["devt"],
            }
            stored_request = self._store.prepare_dispatch(
                command.commandId, request
            )
            try:
                accepted = self._request(binding, "/cm", {
                    "sid": str(binding.station_index), "en": "0", "ssta": "0",
                })
                if accepted != {"result": 1}:
                    raise OpenSprinklerError()
            except OpenSprinklerError:
                pass
        before = json.loads(stored_request).get("before")
        if type(before) is not dict:
            raise ApiError("irrigation_command_unknown", 409)
        result = self._reconcile_stop(binding, command, before)
        return self._store.finish(command.commandId, result)

    def _reconcile_stop(self, binding, command, before):
        deadline = self._clock() + 30
        latest = None
        while self._clock() <= deadline:
            try:
                latest = self._snapshot(binding)
            except OpenSprinklerError:
                self._sleep(self._poll)
                continue
            if (
                latest["status"]["lupt"] == before["boot"]
                and self._isolated(latest, binding.station_index, running=False)
                and latest["status"]["flcrt"] == 0
                and latest["status"]["devt"] > max(
                    before["deviceTime"], command.expectedStateRevision
                )
            ):
                if self._binding(self._resolve(command.zone), command.zone) != binding:
                    raise OpenSprinklerError()
                return WorkerValveStopReadback(
                    schemaVersion=1, commandId=command.commandId, zone=command.zone,
                    stateRevision=latest["status"]["devt"],
                    valveOpen=False, flowActive=False,
                    observedAtMs=int(self._clock() * 1000),
                )
            self._sleep(self._poll)
        raise OpenSprinklerError()
