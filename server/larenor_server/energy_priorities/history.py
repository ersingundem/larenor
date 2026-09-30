"""Bounded, read-only evcc history for F47 reserve-policy review."""

from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import math
from types import SimpleNamespace

from ..evcc.provider import EvccBinding, EvccProviderError
from ..services.transport import ProbeTransportError, ServiceTransport
from .models import (
    EnergyAuthority,
    EnergyInputs,
    EnergyPlan,
    ReserveBacktestResult,
    ReserveBacktestSlot,
)


_MAX_BYTES = 256 * 1024
_MAX_SERIES = 16
_MAX_SLOTS = 168
_HOUR_MS = 60 * 60 * 1000


@dataclass(frozen=True)
class ReserveHistorySlot:
    starts_at_ms: int
    ends_at_ms: int
    soc_percent: float | None


@dataclass(frozen=True)
class ReserveHistoryObservation:
    service_id: str
    service_revision: int
    captured_at_ms: int
    starts_at_ms: int
    ends_at_ms: int
    battery_series_count: int
    battery_slots: tuple[ReserveHistorySlot, ...]
    forecast_starts_at_ms: frozenset[int]
    history_digest: str


def _canonical(value) -> bytes:
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
        allow_nan=False,
    ).encode("ascii")


def _iso(value_ms: int) -> str:
    return datetime.fromtimestamp(value_ms / 1000, timezone.utc).isoformat(
        timespec="seconds"
    ).replace("+00:00", "Z")


def _instant(value) -> int:
    if type(value) is not str or not 1 <= len(value) <= 40:
        raise ValueError("invalid_timestamp")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("invalid_timestamp")
    result = round(parsed.astimezone(timezone.utc).timestamp() * 1000)
    if not 0 <= result <= 2**63 - 1:
        raise ValueError("invalid_timestamp")
    return result


def _number(value, *, minimum=0.0, maximum=1_000_000_000.0) -> float:
    if (
        not isinstance(value, (int, float))
        or isinstance(value, bool)
        or not math.isfinite(float(value))
        or not minimum <= float(value) <= maximum
    ):
        raise ValueError("invalid_number")
    return float(value)


def _json(response):
    types = [
        value.split(";", 1)[0].strip().lower()
        for name, value in response.headers
        if name.lower() == "content-type"
    ]
    if response.status != 200 or types != ["application/json"]:
        raise ValueError("invalid_response")

    def unique(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("duplicate_key")
            result[key] = value
        return result

    value = json.loads(
        response.body.decode("utf-8"),
        object_pairs_hook=unique,
        parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
    )
    if value is None:
        return []
    if type(value) is not list or len(value) > _MAX_SERIES:
        raise ValueError("invalid_series")
    return value


def _series(raw, expected_group, starts_at_ms, ends_at_ms):
    result = []
    for item in raw:
        if type(item) is not dict or not set(item).issubset(
            {"title", "group", "isTemp", "data"}
        ):
            raise ValueError("invalid_series")
        title = item.get("title", "")
        if (
            type(title) is not str
            or len(title) > 128
            or any(ord(char) < 32 or ord(char) == 127 for char in title)
            or item.get("group") != expected_group
            or item.get("isTemp", False) is not False
            or type(item.get("data")) is not list
            or len(item["data"]) > _MAX_SLOTS
        ):
            raise ValueError("invalid_series")
        slots = []
        seen = set()
        for slot in item["data"]:
            if type(slot) is not dict or not set(slot).issubset(
                {"start", "end", "energy", "returnEnergy", "socTemp"}
            ) or not {"start", "end", "energy", "returnEnergy"}.issubset(slot):
                raise ValueError("invalid_slot")
            start, end = _instant(slot["start"]), _instant(slot["end"])
            _number(slot["energy"])
            _number(slot["returnEnergy"])
            soc = slot.get("socTemp")
            if soc is not None:
                soc = _number(soc, maximum=100.0)
            if (
                start in seen
                or start < starts_at_ms
                or end > ends_at_ms
                or end - start != _HOUR_MS
            ):
                raise ValueError("invalid_slot")
            seen.add(start)
            slots.append(ReserveHistorySlot(start, end, soc))
        slots.sort(key=lambda value: value.starts_at_ms)
        result.append((title, tuple(slots)))
    return tuple(result)


class EvccReserveHistoryProvider:
    """Read exact recorded SoC and forecast coverage from one live evcc source."""

    def __init__(self, binding_resolver, clock, *, transport_factory=None):
        if not callable(binding_resolver) or not callable(clock) or (
            transport_factory is not None and not callable(transport_factory)
        ):
            raise ValueError("invalid_evcc_reserve_history_provider")
        self._binding_resolver = binding_resolver
        self._clock = clock
        self._transport_factory = transport_factory or ServiceTransport

    def _binding(self):
        try:
            binding = self._binding_resolver()
        except Exception:
            raise EvccProviderError("provider_binding_changed") from None
        if not isinstance(binding, EvccBinding):
            raise EvccProviderError("provider_unavailable")
        return binding

    def _guard(self, expected: EvccBinding, authority: EnergyAuthority):
        current = self._binding()
        current.assert_current()
        actor = SimpleNamespace(
            id=authority.accountId, family_id=authority.sessionFamilyId
        )
        try:
            account_revision = current.account_revision(actor)
        except Exception:
            raise EvccProviderError("provider_binding_changed") from None
        if (
            (
                current.core_id,
                current.home_id,
                current.core_revision,
                current.home_revision,
                current.connection,
            )
            != (
                expected.core_id,
                expected.home_id,
                expected.core_revision,
                expected.home_revision,
                expected.connection,
            )
            or (authority.coreId, authority.homeId, authority.homeRevision)
            != (current.core_id, current.home_id, current.home_revision)
            or authority.accountRevision != account_revision
            or not authority.active
            or not authority.canPlan
        ):
            raise EvccProviderError("provider_binding_changed")

    def _read(self, binding, authority, group, starts_at_ms, ends_at_ms):
        headers = {"Accept": "application/json"}
        if binding.connection.api_key is not None:
            headers["Authorization"] = "Bearer " + binding.connection.api_key
        guard = lambda: self._guard(binding, authority)
        try:
            with self._transport_factory(
                binding.connection.base_url,
                timeout=8.0,
                max_bytes=_MAX_BYTES,
            ) as transport:
                response = transport.request(
                    "GET",
                    "/api/history/energy",
                    headers=headers,
                    before_send=guard,
                    query_parameters={
                        "from": _iso(starts_at_ms),
                        "to": _iso(ends_at_ms),
                        "aggregate": "hour",
                        "grouped": "false",
                        "group": group,
                        "format": "json",
                    },
                )
            guard()
            return _json(response)
        except EvccProviderError:
            raise
        except (
            ProbeTransportError,
            OSError,
            TypeError,
            ValueError,
            UnicodeError,
            json.JSONDecodeError,
        ):
            raise EvccProviderError("provider_protocol_changed") from None

    def observe(self, authority) -> ReserveHistoryObservation:
        authority = EnergyAuthority.model_validate(authority)
        binding = self._binding()
        self._guard(binding, authority)
        now = self._clock()
        if (
            not isinstance(now, (int, float))
            or isinstance(now, bool)
            or not math.isfinite(float(now))
            or now < 0
        ):
            raise EvccProviderError("provider_unavailable")
        captured_at_ms = round(float(now) * 1000)
        ends_at_ms = captured_at_ms // _HOUR_MS * _HOUR_MS
        starts_at_ms = ends_at_ms - _MAX_SLOTS * _HOUR_MS
        if starts_at_ms < 0:
            raise EvccProviderError("provider_unavailable")
        battery_raw = self._read(
            binding, authority, "battery", starts_at_ms, ends_at_ms
        )
        forecast_raw = self._read(
            binding, authority, "forecast", starts_at_ms, ends_at_ms
        )
        try:
            battery = _series(
                battery_raw, "battery", starts_at_ms, ends_at_ms
            )
            forecast = _series(
                forecast_raw, "forecast", starts_at_ms, ends_at_ms
            )
        except (TypeError, ValueError):
            raise EvccProviderError("provider_protocol_changed") from None
        battery_slots = battery[0][1] if len(battery) == 1 else ()
        forecast_starts = frozenset(
            slot.starts_at_ms for _title, slots in forecast for slot in slots
        )
        digest = hashlib.sha256(
            b"larenor:evcc-reserve-history:v1\0"
            + _canonical({"battery": battery_raw, "forecast": forecast_raw})
        ).hexdigest()
        return ReserveHistoryObservation(
            service_id=binding.connection.service_id,
            service_revision=binding.connection.revision,
            captured_at_ms=captured_at_ms,
            starts_at_ms=starts_at_ms,
            ends_at_ms=ends_at_ms,
            battery_series_count=len(battery),
            battery_slots=battery_slots,
            forecast_starts_at_ms=forecast_starts,
            history_digest=digest,
        )

    def assert_current(self, authority, observation):
        authority = EnergyAuthority.model_validate(authority)
        if not isinstance(observation, ReserveHistoryObservation):
            raise EvccProviderError("provider_binding_changed")
        binding = self._binding()
        self._guard(binding, authority)
        if (
            binding.connection.service_id != observation.service_id
            or binding.connection.revision != observation.service_revision
        ):
            raise EvccProviderError("provider_binding_changed")


def analyze_reserve_history(
    authority: EnergyAuthority,
    inputs: EnergyInputs,
    plan: EnergyPlan,
    observation: ReserveHistoryObservation,
) -> ReserveBacktestResult:
    """Describe recorded slot-start reserve compliance without interpolation."""
    authority = EnergyAuthority.model_validate(authority)
    inputs = EnergyInputs.model_validate(inputs)
    plan = EnergyPlan.model_validate(plan)
    if (
        inputs.coreId != authority.coreId
        or inputs.homeId != authority.homeId
        or inputs.homeRevision != authority.homeRevision
        or plan.inputDigest == ""
    ):
        raise ValueError("invalid_backtest_context")
    expected = [
        observation.starts_at_ms + index * _HOUR_MS
        for index in range(_MAX_SLOTS)
    ]
    samples = {
        slot.starts_at_ms: slot.soc_percent
        for slot in observation.battery_slots
        if slot.soc_percent is not None
    }
    reserve = inputs.reserve.backupReservePercent
    slots = [
        ReserveBacktestSlot(
            schemaVersion=1,
            startsAtMs=start,
            endsAtMs=start + _HOUR_MS,
            observedSocPercent=samples.get(start),
            forecastRecorded=start in observation.forecast_starts_at_ms,
            status=(
                "missing"
                if start not in samples
                else "below"
                if samples[start] < reserve
                else "above_or_equal"
            ),
        )
        for start in expected
    ]
    observed = [
        slot.observedSocPercent
        for slot in slots
        if slot.observedSocPercent is not None
    ]
    sample_count = len(observed)
    forecast_count = sum(slot.forecastRecorded for slot in slots)
    sample_coverage = (
        "missing"
        if sample_count == 0
        else "complete"
        if sample_count == _MAX_SLOTS
        else "partial"
    )
    forecast_coverage = (
        "missing"
        if forecast_count == 0
        else "complete"
        if forecast_count == _MAX_SLOTS
        else "partial"
    )
    below = sum(value < reserve for value in observed)
    status = (
        "sample_below_reserve"
        if below
        else "no_sample_below_reserve"
        if sample_coverage == "complete"
        else "uncertain"
    )
    reasons = []
    if observation.battery_series_count > 1:
        reasons.append("multiple_battery_series")
    if sample_coverage == "missing":
        reasons.append("missing_battery_history")
    elif sample_coverage == "partial":
        reasons.append("partial_battery_history")
    if forecast_coverage == "missing":
        reasons.append("missing_forecast_history")
    elif forecast_coverage == "partial":
        reasons.append("partial_forecast_history")
    reasons.append("historical_preferences_unavailable")
    reasons.append("historical_capacity_unavailable")
    reasons.append("historical_reserve_policy_unavailable")
    manual = (
        "none_current"
        if plan.overrideStatus == "none"
        else "active_current"
        if plan.overrideStatus == "active"
        else "expired_current"
    )
    if manual != "none_current":
        reasons.append("current_manual_preference")
    facts = {
        "authority": authority.model_dump(mode="json"),
        "serviceId": observation.service_id,
        "serviceRevision": observation.service_revision,
        "batteryId": inputs.battery.resourceId,
        "batteryRevision": inputs.battery.revision,
        "batteryProviderRevision": inputs.battery.providerRevision,
        "reserveRevision": inputs.reserve.revision,
        "reservePercent": reserve,
        "capacityWh": inputs.battery.capacityWh,
        "historyDigest": observation.history_digest,
        "capturedAtMs": observation.captured_at_ms,
        "startsAtMs": observation.starts_at_ms,
        "endsAtMs": observation.ends_at_ms,
        "sampleCoverage": sample_coverage,
        "forecastCoverage": forecast_coverage,
        "manualPreference": manual,
        "historicalCapacityCoverage": "unavailable",
        "historicalReservePolicyCoverage": "unavailable",
        "slots": [slot.model_dump(mode="json") for slot in slots],
    }
    return ReserveBacktestResult(
        schemaVersion=1,
        analysisDigest=hashlib.sha256(
            b"larenor:reserve-backtest:v1\0" + _canonical(facts)
        ).hexdigest(),
        authority=authority,
        serviceId=observation.service_id,
        serviceRevision=observation.service_revision,
        batteryId=inputs.battery.resourceId,
        batteryRevision=inputs.battery.revision,
        batteryProviderRevision=inputs.battery.providerRevision,
        reserveRevision=inputs.reserve.revision,
        reservePercent=reserve,
        capacityWh=inputs.battery.capacityWh,
        historyDigest=observation.history_digest,
        capturedAtMs=observation.captured_at_ms,
        startsAtMs=observation.starts_at_ms,
        endsAtMs=observation.ends_at_ms,
        slotDurationSeconds=3600,
        expectedSampleCount=168,
        sampleCount=sample_count,
        missingSampleCount=_MAX_SLOTS - sample_count,
        belowReserveSampleCount=below,
        forecastRecordCount=forecast_count,
        minimumObservedSocPercent=min(observed) if observed else None,
        observedStatus=status,
        sampleCoverage=sample_coverage,
        forecastCoverage=forecast_coverage,
        manualPreference=manual,
        historicalPreferenceCoverage="unavailable",
        historicalCapacityCoverage="unavailable",
        historicalReservePolicyCoverage="unavailable",
        uncertaintyReasons=reasons,
        slots=slots,
    )


__all__ = [
    "EvccReserveHistoryProvider",
    "ReserveHistoryObservation",
    "ReserveHistorySlot",
    "analyze_reserve_history",
]
