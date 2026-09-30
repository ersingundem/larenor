"""Strict evcc state reader and read-only F46/F48 projections.

The upstream `/api/state` object is explicitly not a stable compatibility API.
This module therefore accepts only the small, bounded subset used below and
fails closed when any required field changes.  It never turns possession of an
evcc API key into a control permission: evcc's state and loadpoint routes are
registered outside its authenticated configuration/database route groups.
"""

from collections import OrderedDict
from collections.abc import Callable
from dataclasses import dataclass, field
import hashlib
import json
import math
import re
import threading
from typing import Protocol

from ..ev_charging.runtime import (
    ChargeDeviceCapability,
    ChargeProviderCapability,
    ChargeProviderSnapshot,
)
from ..ev_charging.service import ChargeAuthority, EnergyInputs
from ..power_budget.service import (
    BudgetAuthority,
    BudgetInputs,
    LoadState,
    ProviderState as BudgetProviderState,
)
from ..services.transport import ProbeResponse, ProbeTransportError, ServiceTransport


_IDENTIFIER = re.compile(r"[A-Za-z0-9_.:-]{1,128}\Z")
_SERVICE_ID = re.compile(r"[0-9a-f]{32}\Z")
_API_KEY = re.compile(r"evcc_[A-Za-z0-9_-]{1,2043}\Z")
_TIMEOUT = 5.0
_MAX_BYTES = 512 * 1024
_MAX_LOADPOINTS = 16
_CACHE_SIZE = 32


class EvccProviderError(Exception):
    _CODES = frozenset(
        {
            "provider_binding_changed",
            "provider_protocol_changed",
            "provider_unavailable",
            "provider_snapshot_changed",
            "provider_read_only",
        }
    )

    def __init__(self, code="provider_unavailable"):
        self.code = code if code in self._CODES else "provider_unavailable"
        super().__init__(self.code)


@dataclass(frozen=True)
class EvccConnection:
    service_id: str
    revision: int
    base_url: str = field(repr=False)
    api_key: str | None = field(default=None, repr=False)

    def __post_init__(self):
        if (
            _SERVICE_ID.fullmatch(self.service_id) is None
            or type(self.revision) is not int
            or not 1 <= self.revision <= 2**63 - 1
            or not isinstance(self.base_url, str)
            or not self.base_url
            or self.api_key is not None
            and _API_KEY.fullmatch(self.api_key) is None
        ):
            raise ValueError("invalid_evcc_connection")


@dataclass(frozen=True)
class EvccBinding:
    core_id: str
    home_id: str
    core_revision: int
    home_revision: int
    account_revision: Callable[[object], int]
    connection: EvccConnection
    validate_connection: Callable[[], None]

    def __post_init__(self):
        if (
            _IDENTIFIER.fullmatch(self.core_id) is None
            or _IDENTIFIER.fullmatch(self.home_id) is None
            or type(self.core_revision) is not int
            or not 1 <= self.core_revision <= 2**63 - 1
            or type(self.home_revision) is not int
            or not 1 <= self.home_revision <= 2**63 - 1
            or not callable(self.account_revision)
            or not isinstance(self.connection, EvccConnection)
            or not callable(self.validate_connection)
        ):
            raise ValueError("invalid_evcc_binding")

    def assert_current(self):
        try:
            self.validate_connection()
        except Exception:
            raise EvccProviderError("provider_binding_changed") from None


@dataclass(frozen=True)
class EvccLoadpoint:
    index: int
    name: str
    title: str
    revision: int
    charge_power_w: int
    priority: int
    connected: bool
    charging: bool
    vehicle_soc: int | None
    vehicle_capacity_wh: int | None
    max_current_amp: int
    phases_active: int
    voltage: int | None


@dataclass(frozen=True)
class EvccObservation:
    service_id: str
    service_revision: int
    observed_at: float
    upstream_version: str
    state_revision: int
    meter_revision: int
    tariff_revision: int
    load_registry_revision: int
    grid_limit_revision: int
    grid_import_w: int
    physical_grid_limit_w: int
    grid_limit_w: int
    tariff_micros_per_kwh: int
    currency: str
    loadpoints: tuple[EvccLoadpoint, ...]


@dataclass(frozen=True)
class EvccEnergyProjection:
    schedule_revision: int
    inputs: EnergyInputs

    def __post_init__(self):
        if (
            type(self.schedule_revision) is not int
            or not 1 <= self.schedule_revision <= 2**63 - 1
            or not isinstance(self.inputs, EnergyInputs)
        ):
            raise ValueError("invalid_evcc_energy_projection")


class EnergyWindowSource(Protocol):
    """Trusted F46 tariff/solar/budget projections; no values are synthesized."""

    def projection(self, observation: EvccObservation) -> EvccEnergyProjection: ...


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate_key")
        result[key] = value
    return result


def _invalid_constant(_value):
    raise ValueError("invalid_number")


def _digest(value) -> str:
    return hashlib.sha256(
        json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
            allow_nan=False,
        ).encode("utf-8")
    ).hexdigest()


def _revision(value) -> int:
    return int(_digest(value)[:15], 16) + 1


def _number(value, *, minimum=-1_000_000.0, maximum=1_000_000.0) -> float:
    if (
        not isinstance(value, (int, float))
        or isinstance(value, bool)
        or not math.isfinite(float(value))
        or not minimum <= float(value) <= maximum
    ):
        raise EvccProviderError("provider_protocol_changed")
    return float(value)


def _integer_number(value, *, minimum=0, maximum=1_000_000) -> int:
    number = _number(value, minimum=minimum, maximum=maximum)
    if not number.is_integer():
        raise EvccProviderError("provider_protocol_changed")
    return int(number)


def _text(value, *, maximum=128, pattern=None) -> str:
    if (
        not isinstance(value, str)
        or not 1 <= len(value) <= maximum
        or any(ord(char) < 32 or ord(char) == 127 for char in value)
        or pattern is not None
        and pattern.fullmatch(value) is None
    ):
        raise EvccProviderError("provider_protocol_changed")
    return value


def _object(response) -> dict:
    if (
        not isinstance(response, ProbeResponse)
        or response.status != 200
        or not isinstance(response.body, bytes)
        or len(response.body) > _MAX_BYTES
    ):
        raise EvccProviderError("provider_protocol_changed")
    types = [
        value
        for name, value in response.headers
        if isinstance(name, str) and name.lower() == "content-type"
    ]
    if (
        len(types) != 1
        or types[0].split(";", 1)[0].strip().lower() != "application/json"
    ):
        raise EvccProviderError("provider_protocol_changed")
    try:
        value = json.loads(
            response.body.decode("utf-8"),
            object_pairs_hook=_unique_object,
            parse_constant=_invalid_constant,
        )
    except (UnicodeError, ValueError, TypeError, json.JSONDecodeError):
        raise EvccProviderError("provider_protocol_changed") from None
    if type(value) is not dict:
        raise EvccProviderError("provider_protocol_changed")
    return value


class EvccHttpReader:
    """One bounded GET of the fixed `/api/state` route."""

    def __init__(self, clock, *, transport_factory=None):
        if not callable(clock) or transport_factory is not None and not callable(transport_factory):
            raise ValueError("invalid_evcc_reader")
        self._clock = clock
        self._factory = transport_factory or ServiceTransport

    def _request(self, connection):
        transport = None
        try:
            headers = {"Accept": "application/json"}
            if connection.api_key is not None:
                headers["Authorization"] = "Bearer " + connection.api_key
            transport = self._factory(
                connection.base_url, timeout=_TIMEOUT, max_bytes=_MAX_BYTES
            )
            return transport.request("GET", "/api/state", headers=headers)
        except (ProbeTransportError, OSError, TypeError, ValueError):
            raise EvccProviderError("provider_unavailable") from None
        finally:
            if transport is not None:
                transport.close()

    @staticmethod
    def _grid_limit(state):
        circuits = state.get("circuits")
        if type(circuits) is not dict or not 1 <= len(circuits) <= 64:
            raise EvccProviderError("provider_protocol_changed")
        roots = []
        for name, circuit in circuits.items():
            if type(name) is not str or type(circuit) is not dict:
                raise EvccProviderError("provider_protocol_changed")
            parent = circuit.get("parent", "")
            if parent in {"", None}:
                roots.append(circuit)
        if len(roots) != 1:
            raise EvccProviderError("provider_protocol_changed")
        physical_limit = _integer_number(roots[0].get("maxPower"), minimum=1)
        effective_limit = physical_limit
        hems = state.get("hems")
        if hems is not None:
            if type(hems) is not dict:
                raise EvccProviderError("provider_protocol_changed")
            status = hems.get("status")
            if status is None:
                return physical_limit, effective_limit
            if type(status) is not dict:
                raise EvccProviderError("provider_protocol_changed")
            dimmed = status.get("dimmed")
            if type(dimmed) is not bool:
                raise EvccProviderError("provider_protocol_changed")
            if dimmed:
                effective_limit = min(
                    effective_limit,
                    _integer_number(status.get("maxConsumptionPower"), minimum=1),
                )
        return physical_limit, effective_limit

    @staticmethod
    def _loadpoints(state):
        raw = state.get("loadpoints")
        vehicles = state.get("vehicles")
        if (
            type(raw) is not list
            or not 1 <= len(raw) <= _MAX_LOADPOINTS
            or type(vehicles) is not dict
            or len(vehicles) > 64
        ):
            raise EvccProviderError("provider_protocol_changed")
        result = []
        for index, item in enumerate(raw, 1):
            if type(item) is not dict:
                raise EvccProviderError("provider_protocol_changed")
            name = _text(item.get("name"), pattern=_IDENTIFIER)
            title = _text(item.get("title"), maximum=80)
            power = round(_number(item.get("chargePower"), minimum=0))
            priority = _integer_number(item.get("priority"), maximum=100)
            connected, charging = item.get("connected"), item.get("charging")
            if type(connected) is not bool or type(charging) is not bool:
                raise EvccProviderError("provider_protocol_changed")
            max_current = _number(item.get("maxCurrent"), minimum=1, maximum=80)
            if not max_current.is_integer():
                raise EvccProviderError("provider_protocol_changed")
            phases = _integer_number(item.get("phasesActive"), maximum=3)
            if phases not in {0, 1, 3}:
                raise EvccProviderError("provider_protocol_changed")
            voltage = None
            raw_voltages = item.get("chargeVoltages")
            if isinstance(raw_voltages, list) and 1 <= len(raw_voltages) <= 3:
                measured = [
                    _number(value, minimum=0, maximum=500) for value in raw_voltages
                ]
                nonzero = [value for value in measured if value >= 100]
                if nonzero:
                    average = sum(nonzero) / len(nonzero)
                    if average.is_integer():
                        voltage = int(average)
            vehicle_soc = None
            capacity_wh = None
            vehicle_name = item.get("vehicleName")
            if connected and isinstance(vehicle_name, str) and vehicle_name:
                vehicle = vehicles.get(vehicle_name)
                if type(vehicle) is dict and "capacity" in vehicle:
                    soc = _number(item.get("vehicleSoc"), minimum=0, maximum=100)
                    capacity = _number(vehicle["capacity"], minimum=0.001, maximum=500)
                    if soc.is_integer() and (capacity * 1000).is_integer():
                        vehicle_soc = int(soc)
                        capacity_wh = int(capacity * 1000)
            facts = {
                "index": index,
                "name": name,
                "chargePower": power,
                "priority": priority,
                "connected": connected,
                "charging": charging,
                "vehicleSoc": vehicle_soc,
                "vehicleCapacityWh": capacity_wh,
                "maxCurrent": int(max_current),
                "phasesActive": phases,
                "voltage": voltage,
            }
            result.append(
                EvccLoadpoint(
                    index,
                    name,
                    title,
                    _revision(facts),
                    power,
                    priority,
                    connected,
                    charging,
                    vehicle_soc,
                    capacity_wh,
                    int(max_current),
                    phases,
                    voltage,
                )
            )
        return tuple(result)

    def state(self, connection: EvccConnection) -> EvccObservation:
        if not isinstance(connection, EvccConnection):
            raise EvccProviderError("provider_binding_changed")
        state = _object(self._request(connection))
        if state.get("startupCompleted") is not True or state.get("apiReady") is not True:
            raise EvccProviderError("provider_unavailable")
        if state.get("gridConfigured") is not True:
            raise EvccProviderError("provider_protocol_changed")
        version = _text(state.get("version"), maximum=64)
        currency = _text(state.get("currency"), maximum=3)
        grid = state.get("grid")
        if type(grid) is not dict:
            raise EvccProviderError("provider_protocol_changed")
        grid_power = _number(grid.get("power"))
        grid_import = max(0, round(grid_power))
        price = _number(state.get("tariffGrid"), minimum=-10, maximum=10)
        price_micros = round(price * 1_000_000)
        physical_limit, effective_limit = self._grid_limit(state)
        loads = self._loadpoints(state)
        if grid_import > 1_000_000 or any(
            load.charge_power_w > physical_limit for load in loads
        ):
            raise EvccProviderError("provider_protocol_changed")
        meter_facts = {"grid": grid_power}
        tariff_facts = {"currency": currency, "tariffGrid": price}
        load_facts = [load.__dict__ for load in loads]
        limit_facts = {
            "physicalGridLimitW": physical_limit,
            "effectiveGridLimitW": effective_limit,
        }
        state_facts = {
            "version": version,
            "meter": meter_facts,
            "tariff": tariff_facts,
            "loads": load_facts,
            "limit": limit_facts,
        }
        observed_at = self._clock()
        if (
            not isinstance(observed_at, (int, float))
            or isinstance(observed_at, bool)
            or not math.isfinite(float(observed_at))
            or observed_at < 0
        ):
            raise EvccProviderError("provider_unavailable")
        return EvccObservation(
            connection.service_id,
            connection.revision,
            float(observed_at),
            version,
            _revision(state_facts),
            _revision(meter_facts),
            _revision(tariff_facts),
            _revision(load_facts),
            _revision(limit_facts),
            grid_import,
            physical_limit,
            effective_limit,
            price_micros,
            currency,
            loads,
        )


class _SnapshotCache:
    def __init__(self, reader, connection):
        self._reader, self._connection = reader, connection
        self._lock = threading.RLock()
        self._values = OrderedDict()

    def refresh(self, key):
        value = self._reader.state(self._connection)
        with self._lock:
            self._values[key] = value
            self._values.move_to_end(key)
            while len(self._values) > _CACHE_SIZE:
                self._values.popitem(last=False)
        return value

    def exact(self, key, revision):
        with self._lock:
            value = self._values.get(key)
        if value is None or value.state_revision != revision:
            raise EvccProviderError("provider_snapshot_changed")
        return value


def _actor_key(actor):
    actor_id = getattr(actor, "id", None)
    family = getattr(actor, "family_id", None)
    if _SERVICE_ID.fullmatch(actor_id or "") is None or _SERVICE_ID.fullmatch(family or "") is None:
        raise EvccProviderError("provider_binding_changed")
    return actor_id, family


class EvccPowerBudgetProvider:
    def __init__(self, binding, cache):
        self._binding, self._cache = binding, cache

    def authority(self, actor):
        self._binding.assert_current()
        key = _actor_key(actor)
        account_revision = self._binding.account_revision(actor)
        if type(account_revision) is not int or account_revision < 1:
            raise EvccProviderError("provider_binding_changed")
        value = self._cache.refresh(key)
        return BudgetAuthority(
            self._binding.core_id,
            self._binding.home_id,
            key[0],
            key[1],
            self._binding.core_revision,
            self._binding.home_revision,
            account_revision,
            value.service_id,
            value.meter_revision,
            value.tariff_revision,
            value.load_registry_revision,
            value.grid_limit_revision,
            value.state_revision,
            value.state_revision,
            value.physical_grid_limit_w,
            value.grid_limit_w,
            False,
        )

    def inputs(self, actor, authority):
        self._binding.assert_current()
        key = _actor_key(actor)
        value = self._cache.exact(key, authority.plan_revision)
        if (
            authority.account_id != key[0]
            or authority.session_id != key[1]
            or authority.meter_revision != value.meter_revision
            or authority.tariff_revision != value.tariff_revision
            or authority.load_registry_revision != value.load_registry_revision
            or authority.grid_limit_revision != value.grid_limit_revision
        ):
            raise EvccProviderError("provider_snapshot_changed")
        return BudgetInputs(
            value.meter_revision,
            value.tariff_revision,
            value.load_registry_revision,
            value.grid_limit_revision,
            value.state_revision,
            value.grid_limit_w,
            value.grid_import_w,
            value.tariff_micros_per_kwh,
            (
                BudgetProviderState("meter", value.meter_revision, "verified", value.observed_at),
                BudgetProviderState("tariff", value.tariff_revision, "verified", value.observed_at),
            ),
            tuple(
                LoadState(
                    f"evcc-lp-{item.index}",
                    item.revision,
                    item.priority,
                    item.charge_power_w,
                    False,
                    False,
                    0,
                )
                for item in value.loadpoints
            ),
            None,
        )

    def load_labels(self, actor, authority):
        self._binding.assert_current()
        value = self._cache.exact(_actor_key(actor), authority.plan_revision)
        return {f"evcc-lp-{item.index}": item.title for item in value.loadpoints}

    @staticmethod
    def control_capability(actor, authority):
        return "read_only"

    @staticmethod
    def manual_control_enabled(actor, authority):
        return False

    @staticmethod
    def apply(*, plan_hash, actions):
        raise EvccProviderError("provider_read_only")

    @staticmethod
    def readback():
        return None


class EvccChargeProvider:
    def __init__(self, binding, cache, energy_windows):
        self._binding, self._cache, self._energy_windows = binding, cache, energy_windows

    @staticmethod
    def _charger_id(service_id, index):
        return hashlib.sha256(f"evcc:{service_id}:{index}".encode("ascii")).hexdigest()[:32]

    def _devices(self, observation, projection):
        inputs = projection.inputs
        return tuple(
            ChargeDeviceCapability(
                self._charger_id(observation.service_id, item.index),
                item.title,
                item.revision,
                projection.schedule_revision,
                inputs.tariff_revision,
                inputs.power_budget_revision,
                item.vehicle_soc,
                item.vehicle_capacity_wh,
                item.max_current_amp,
            )
            for item in observation.loadpoints
            if item.connected
            and item.vehicle_soc is not None
            and item.vehicle_capacity_wh is not None
            and item.voltage is not None
        )

    def capability(self):
        try:
            self._binding.assert_current()
        except EvccProviderError:
            return ChargeProviderCapability(
                "unavailable", "evcc", False, False, "provider_unreachable"
            )
        if self._energy_windows is None:
            return ChargeProviderCapability(
                "unavailable", "evcc", False, False, "provider_unreachable"
            )
        try:
            observation = self._cache.refresh(("capability", "evcc"))
            projection = self._energy_windows.projection(observation)
            if not isinstance(projection, EvccEnergyProjection):
                raise EvccProviderError("provider_protocol_changed")
            devices = self._devices(observation, projection)
            if not devices:
                return ChargeProviderCapability(
                    "unavailable", "evcc", False, False, "provider_unreachable"
                )
            return ChargeProviderCapability(
                "ready", "evcc", True, False, "charger_read_only", devices
            )
        except Exception:
            return ChargeProviderCapability(
                "unavailable", "evcc", False, False, "provider_unreachable"
            )

    def snapshot(self, *, actor_id, session_family_id, charger_id):
        self._binding.assert_current()
        if _SERVICE_ID.fullmatch(actor_id or "") is None or _SERVICE_ID.fullmatch(session_family_id or "") is None:
            raise EvccProviderError("provider_binding_changed")
        observation = self._cache.refresh((actor_id, session_family_id))
        if self._energy_windows is None:
            raise EvccProviderError("provider_unavailable")
        projection = self._energy_windows.projection(observation)
        if not isinstance(projection, EvccEnergyProjection):
            raise EvccProviderError("provider_protocol_changed")
        inputs = projection.inputs
        devices = [
            item
            for item in self._devices(observation, projection)
            if item.charger_id == charger_id
        ]
        if len(devices) != 1:
            raise EvccProviderError("provider_binding_changed")
        device = devices[0]

        class _Actor:
            id = actor_id
            family_id = session_family_id

        account_revision = self._binding.account_revision(_Actor())
        if type(account_revision) is not int or account_revision < 1:
            raise EvccProviderError("provider_binding_changed")
        return ChargeProviderSnapshot(
            ChargeAuthority(
                self._binding.core_id,
                self._binding.home_id,
                actor_id,
                session_family_id,
                self._binding.core_revision,
                self._binding.home_revision,
                account_revision,
                charger_id,
                device.charger_revision,
                inputs.tariff_revision,
                inputs.solar_revision,
                inputs.power_budget_revision,
                inputs.override_revision,
                device.schedule_revision,
                device.max_current_amp,
                next(
                    item.voltage
                    for item in observation.loadpoints
                    if self._charger_id(observation.service_id, item.index)
                    == charger_id
                ),
                device.battery_capacity_wh,
                False,
            ),
            inputs,
        )


class EvccRuntimeProviders:
    """Composition seam used by Core once a private evcc connection is bound."""

    def __init__(
        self,
        binding: EvccBinding,
        *,
        clock,
        energy_windows: EnergyWindowSource | None = None,
        transport_factory=None,
    ):
        if not isinstance(binding, EvccBinding) or (
            energy_windows is not None
            and not callable(getattr(energy_windows, "projection", None))
        ):
            raise ValueError("invalid_evcc_runtime")
        reader = EvccHttpReader(clock, transport_factory=transport_factory)
        cache = _SnapshotCache(reader, binding.connection)
        self.power_budget = EvccPowerBudgetProvider(binding, cache)
        self.ev_charging = EvccChargeProvider(binding, cache, energy_windows)


class _ResolvedChargeProvider:
    def __init__(self, owner):
        self._owner = owner

    def capability(self):
        runtime = self._owner._runtime()
        if runtime is None:
            return ChargeProviderCapability(
                "unavailable", "none", False, False, "provider_not_configured"
            )
        return runtime.ev_charging.capability()

    def snapshot(self, *, actor_id, session_family_id, charger_id):
        runtime = self._owner._runtime()
        if runtime is None:
            raise EvccProviderError("provider_unavailable")
        return runtime.ev_charging.snapshot(
            actor_id=actor_id,
            session_family_id=session_family_id,
            charger_id=charger_id,
        )


class _ResolvedPowerBudgetProvider:
    def __init__(self, owner):
        self._owner = owner
        self._lock = threading.RLock()
        self._providers = OrderedDict()

    def authority(self, actor):
        runtime = self._owner._runtime()
        if runtime is None:
            raise EvccProviderError("provider_unavailable")
        provider = runtime.power_budget
        authority = provider.authority(actor)
        with self._lock:
            self._providers[authority] = provider
            self._providers.move_to_end(authority)
            while len(self._providers) > _CACHE_SIZE:
                self._providers.popitem(last=False)
        return authority

    def _provider(self, authority):
        with self._lock:
            provider = self._providers.get(authority)
            if provider is not None:
                self._providers.move_to_end(authority)
        if provider is None:
            raise EvccProviderError("provider_snapshot_changed")
        return provider

    def inputs(self, actor, authority):
        return self._provider(authority).inputs(actor, authority)

    def load_labels(self, actor, authority):
        return self._provider(authority).load_labels(actor, authority)

    def control_capability(self, actor, authority):
        return self._provider(authority).control_capability(actor, authority)

    def manual_control_enabled(self, actor, authority):
        return self._provider(authority).manual_control_enabled(actor, authority)

    def communication_loss_behaviors(self, actor, authority):
        provider = self._provider(authority)
        method = getattr(provider, "communication_loss_behaviors", None)
        if not callable(method):
            raise EvccProviderError("provider_protocol_changed")
        return method(actor, authority)

    @staticmethod
    def apply(*, plan_hash, actions):
        raise EvccProviderError("provider_read_only")

    @staticmethod
    def readback():
        return None


class EvccRuntimeResolver:
    """Resolve one immutable evcc binding at each request boundary.

    The selected provider instance is never mutated or rebound.  A later
    service change therefore produces a new instance, while every operation on
    an existing instance continues to enforce its exact id/revision guard.
    """

    def __init__(
        self,
        binding_resolver,
        *,
        clock,
        energy_windows: EnergyWindowSource | None = None,
        transport_factory=None,
    ):
        if not callable(binding_resolver):
            raise ValueError("invalid_evcc_runtime_resolver")
        self._binding_resolver = binding_resolver
        self._clock = clock
        self._energy_windows = energy_windows
        self._transport_factory = transport_factory
        self.ev_charging = _ResolvedChargeProvider(self)
        self.power_budget = _ResolvedPowerBudgetProvider(self)

    def _runtime(self):
        binding = self._binding_resolver()
        if binding is None:
            return None
        if not isinstance(binding, EvccBinding):
            raise EvccProviderError("provider_binding_changed")
        return EvccRuntimeProviders(
            binding,
            clock=self._clock,
            energy_windows=self._energy_windows,
            transport_factory=self._transport_factory,
        )
