from datetime import datetime, timezone
import json

import pytest

from larenor_server.energy_priorities.history import (
    EvccReserveHistoryProvider,
    ReserveHistoryObservation,
    ReserveHistorySlot,
    analyze_reserve_history,
)
from larenor_server.evcc.provider import (
    EvccBinding,
    EvccConnection,
    EvccProviderError,
)
from larenor_server.services.transport import ProbeResponse

from test_f47_solar_battery_priorities import authority, inputs, planner


HOUR_MS = 3_600_000
NOW = 1_788_609_600
SERVICE = "a" * 32


def _iso(value_ms):
    return datetime.fromtimestamp(value_ms / 1000, timezone.utc).isoformat(
        timespec="seconds"
    ).replace("+00:00", "Z")


def _slot(start, soc=None):
    value = {
        "start": _iso(start),
        "end": _iso(start + HOUR_MS),
        "energy": 100,
        "returnEnergy": 0,
    }
    if soc is not None:
        value["socTemp"] = soc
    return value


class Transport:
    payloads = {}
    requests = []
    after_send = None

    def __init__(self, base_url, *, timeout, max_bytes):
        assert (base_url, timeout, max_bytes) == (
            "http://127.0.0.1:7070",
            8.0,
            256 * 1024,
        )

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return None

    def request(
        self,
        method,
        path,
        *,
        headers,
        before_send,
        query_parameters,
    ):
        before_send()
        assert (method, path) == ("GET", "/api/history/energy")
        assert headers == {
            "Accept": "application/json",
            "Authorization": "Bearer evcc_fixture-key",
        }
        group = query_parameters["group"]
        self.requests.append((group, dict(query_parameters)))
        if self.after_send is not None:
            self.after_send()
        return ProbeResponse(
            200,
            (("Content-Type", "application/json"),),
            json.dumps(self.payloads[group], separators=(",", ":")).encode(),
        )


def _binding(current):
    return EvccBinding(
        core_id="1" * 32,
        home_id="2" * 32,
        core_revision=1,
        home_revision=2,
        account_revision=lambda actor: (
            3
            if (actor.id, actor.family_id) == ("3" * 32, "4" * 32)
            else 0
        ),
        connection=EvccConnection(
            SERVICE,
            current.get("revision", 7),
            "http://127.0.0.1:7070",
            "evcc_fixture-key",
        ),
        validate_connection=lambda: (
            None if current["valid"] else (_ for _ in ()).throw(ValueError())
        ),
    )


def test_reads_exact_ungrouped_slot_start_soc_and_recorded_forecast():
    end = NOW * 1000 // HOUR_MS * HOUR_MS
    start = end - 168 * HOUR_MS
    Transport.requests = []
    Transport.after_send = None
    Transport.payloads = {
        "battery": [
            {
                "title": "Battery",
                "group": "battery",
                "isTemp": False,
                "data": [_slot(start, 39), _slot(start + HOUR_MS, 55)],
            }
        ],
        "forecast": [
            {
                "title": "Forecast",
                "group": "forecast",
                "isTemp": False,
                "data": [_slot(start), _slot(start + HOUR_MS)],
            }
        ],
    }
    current = {"valid": True}
    observation = EvccReserveHistoryProvider(
        lambda: _binding(current),
        lambda: NOW,
        transport_factory=Transport,
    ).observe(authority())

    assert observation.battery_series_count == 1
    assert [slot.soc_percent for slot in observation.battery_slots] == [39.0, 55.0]
    assert observation.forecast_starts_at_ms == {start, start + HOUR_MS}
    assert [request[0] for request in Transport.requests] == ["battery", "forecast"]
    for group, query in Transport.requests:
        assert query == {
            "from": _iso(start),
            "to": _iso(end),
            "aggregate": "hour",
            "grouped": "false",
            "group": group,
            "format": "json",
        }
    provider = EvccReserveHistoryProvider(
        lambda: _binding(current),
        lambda: NOW,
        transport_factory=Transport,
    )
    provider.assert_current(authority(), observation)
    current["revision"] = 8
    with pytest.raises(EvccProviderError) as changed:
        provider.assert_current(authority(), observation)
    assert changed.value.code == "provider_binding_changed"

    source = inputs()
    result = analyze_reserve_history(
        authority(), source, planner(source).plan(authority(), source), observation
    )
    assert result.observedStatus == "sample_below_reserve"
    assert result.sampleCoverage == "partial"
    assert result.forecastCoverage == "partial"
    assert result.sampleCount == 2
    assert result.missingSampleCount == 166
    assert result.belowReserveSampleCount == 1
    assert result.forecastRecordCount == 2
    assert result.minimumObservedSocPercent == 39
    assert result.historicalPreferenceCoverage == "unavailable"
    assert result.uncertaintyReasons == [
        "partial_battery_history",
        "partial_forecast_history",
        "historical_preferences_unavailable",
        "historical_capacity_unavailable",
        "historical_reserve_policy_unavailable",
    ]


def test_empty_or_multiple_battery_series_is_truthfully_uncertain():
    end = NOW * 1000 // HOUR_MS * HOUR_MS
    start = end - 168 * HOUR_MS
    source = inputs()
    plan = planner(source).plan(authority(), source)
    empty = analyze_reserve_history(
        authority(),
        source,
        plan,
        ReserveHistoryObservation(
            SERVICE, 7, NOW * 1000, start, end, 0, (), frozenset(), "0" * 64
        ),
    )
    assert (empty.observedStatus, empty.sampleCoverage) == ("uncertain", "missing")
    assert empty.minimumObservedSocPercent is None
    assert empty.uncertaintyReasons == [
        "missing_battery_history",
        "missing_forecast_history",
        "historical_preferences_unavailable",
        "historical_capacity_unavailable",
        "historical_reserve_policy_unavailable",
    ]

    multiple = analyze_reserve_history(
        authority(),
        source,
        plan,
        ReserveHistoryObservation(
            SERVICE, 7, NOW * 1000, start, end, 2, (), frozenset(), "1" * 64
        ),
    )
    assert multiple.observedStatus == "uncertain"
    assert multiple.uncertaintyReasons[0] == "multiple_battery_series"


def test_malformed_history_and_post_read_authority_drift_fail_closed():
    end = NOW * 1000 // HOUR_MS * HOUR_MS
    start = end - 168 * HOUR_MS
    Transport.requests = []
    Transport.payloads = {
        "battery": [{"group": "battery", "data": [_slot(start, float("nan"))]}],
        "forecast": [],
    }
    current = {"valid": True}
    provider = EvccReserveHistoryProvider(
        lambda: _binding(current),
        lambda: NOW,
        transport_factory=Transport,
    )
    with pytest.raises(EvccProviderError) as malformed:
        provider.observe(authority())
    assert malformed.value.code == "provider_protocol_changed"

    Transport.payloads = {"battery": None, "forecast": None}
    Transport.after_send = lambda _transport: current.update(valid=False)
    with pytest.raises(EvccProviderError) as changed:
        provider.observe(authority())
    assert changed.value.code == "provider_binding_changed"
    Transport.after_send = None
