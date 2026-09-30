"""Bounded read-only Home Assistant Thread dataset/router diagnostics.

This uses Home Assistant's documented WebSocket commands
``thread/list_datasets`` and ``thread/discover_routers``.  Dataset TLV bytes,
Thread credentials, Matter ownership, and every mutation command are outside
this contract.
"""

from __future__ import annotations

from dataclasses import dataclass
import math
import time

from ..home_assistant.read_only_websocket import (
    HomeAssistantReadOnlyWebSocket,
    HomeAssistantWebSocketError,
)
from ..services.service import ServiceConnection
MAX_DATASETS = 64
MAX_ROUTERS = 128


class ThreadDiagnosticsError(RuntimeError):
    def __init__(self, code="unavailable"):
        self.code = code if code in {
            "unavailable", "unauthorized", "unsupported", "invalid_response",
            "timeout", "authority_changed",
        } else "unavailable"
        super().__init__(self.code)


@dataclass(frozen=True)
class ThreadDatasetDiagnostic:
    datasetId: str
    networkName: str
    channel: int
    panId: int
    extendedPanId: str
    preferred: bool
    source: str
    preferredBorderAgentId: str | None
    preferredExtendedAddress: str | None


@dataclass(frozen=True)
class ThreadRouterDiagnostic:
    routerId: str
    networkName: str | None
    extendedAddress: str
    extendedPanId: str
    borderAgentId: str | None
    brand: str | None
    modelName: str | None
    threadVersion: str | None
    vendorName: str | None
    unconfigured: bool | None


@dataclass(frozen=True)
class ThreadDiagnosticSnapshot:
    serviceId: str
    serviceRevision: int
    capturedAtMs: int
    datasets: tuple[ThreadDatasetDiagnostic, ...]
    routers: tuple[ThreadRouterDiagnostic, ...]
    readOnly: bool = True


def _text(value, maximum=128, *, optional=False):
    if value is None and optional:
        return None
    if (
        not isinstance(value, str)
        or not 1 <= len(value.encode("utf-8")) <= maximum
        or any(ord(char) < 32 or ord(char) == 127 for char in value)
    ):
        raise ThreadDiagnosticsError("invalid_response")
    return value


def _hex(value, lengths):
    value = _text(value, max(lengths))
    if len(value) not in lengths or any(char not in "0123456789abcdefABCDEF" for char in value):
        raise ThreadDiagnosticsError("invalid_response")
    return value.lower()


def _datasets(value):
    if not isinstance(value, dict) or set(value) != {"datasets"}:
        raise ThreadDiagnosticsError("invalid_response")
    raw = value["datasets"]
    if not isinstance(raw, list) or len(raw) > MAX_DATASETS:
        raise ThreadDiagnosticsError("invalid_response")
    result = []
    seen = set()
    for item in raw:
        if not isinstance(item, dict):
            raise ThreadDiagnosticsError("invalid_response")
        dataset_id = _text(item.get("dataset_id"))
        if dataset_id in seen:
            raise ThreadDiagnosticsError("invalid_response")
        seen.add(dataset_id)
        channel = item.get("channel")
        pan_id = item.get("pan_id")
        preferred = item.get("preferred")
        if (
            type(channel) is not int
            or not 11 <= channel <= 26
            or type(pan_id) is not int
            or not 0 <= pan_id <= 65535
            or type(preferred) is not bool
        ):
            raise ThreadDiagnosticsError("invalid_response")
        result.append(ThreadDatasetDiagnostic(
            datasetId=dataset_id,
            networkName=_text(item.get("network_name"), 64),
            channel=channel,
            panId=pan_id,
            extendedPanId=_hex(item.get("extended_pan_id"), {16}),
            preferred=preferred,
            source=_text(item.get("source"), 64),
            preferredBorderAgentId=(
                None if item.get("preferred_border_agent_id") is None
                else _hex(item["preferred_border_agent_id"], {32})
            ),
            preferredExtendedAddress=(
                None if item.get("preferred_extended_address") is None
                else _hex(item["preferred_extended_address"], {16})
            ),
        ))
    return tuple(result)


def _router(key, value):
    if not isinstance(value, dict):
        raise ThreadDiagnosticsError("invalid_response")
    return ThreadRouterDiagnostic(
        routerId=_hex(key, {16}),
        networkName=_text(value.get("network_name"), 64, optional=True),
        extendedAddress=_hex(value.get("extended_address"), {16}),
        extendedPanId=_hex(value.get("extended_pan_id"), {16}),
        borderAgentId=(
            None if value.get("border_agent_id") is None
            else _hex(value["border_agent_id"], {32})
        ),
        brand=_text(value.get("brand"), 64, optional=True),
        modelName=_text(value.get("model_name"), 64, optional=True),
        threadVersion=_text(value.get("thread_version"), 32, optional=True),
        vendorName=_text(value.get("vendor_name"), 64, optional=True),
        unconfigured=(
            None if value.get("unconfigured") is None
            else value["unconfigured"]
            if type(value["unconfigured"]) is bool
            else (_ for _ in ()).throw(ThreadDiagnosticsError("invalid_response"))
        ),
    )


class HomeAssistantThreadDiagnosticsTransport:
    def __init__(
        self,
        connection: ServiceConnection,
        *,
        resolver=None,
        connector=None,
        address_guard=None,
        clock=time.time,
    ):
        try:
            self._client = HomeAssistantReadOnlyWebSocket(
                connection,
                resolver=resolver,
                connector=connector,
                address_guard=address_guard,
            )
        except HomeAssistantWebSocketError as error:
            raise ThreadDiagnosticsError(error.code) from None
        self.connection = connection
        self._clock = clock

    def observe(
        self,
        *,
        timeout=8.0,
        discovery_window=0.5,
        before_io=lambda: None,
        after_io=lambda: None,
    ):
        if (
            type(timeout) not in (int, float)
            or isinstance(timeout, bool)
            or not math.isfinite(timeout)
            or not 0 < timeout <= 15
            or type(discovery_window) not in (int, float)
            or not 0 <= discovery_window <= 2
        ):
            raise ThreadDiagnosticsError("unavailable")
        try:
            with self._client.session(
                timeout=timeout,
                before_io=before_io,
                after_io=after_io,
            ) as session:
                datasets = _datasets(session.list_thread_datasets())
                routers = {}
                for payload in session.discover_thread_routers(discovery_window):
                    kind = payload.get("type")
                    key = payload.get("key")
                    if kind == "router_discovered":
                        router_id = _hex(key, {16})
                        if len(routers) >= MAX_ROUTERS and router_id not in routers:
                            raise ThreadDiagnosticsError("invalid_response")
                        routers[router_id] = _router(
                            router_id, payload.get("data")
                        )
                    elif kind == "router_removed":
                        routers.pop(_hex(key, {16}), None)
                    else:
                        raise ThreadDiagnosticsError("invalid_response")
            return ThreadDiagnosticSnapshot(
                serviceId=self.connection.id,
                serviceRevision=self.connection.revision,
                capturedAtMs=int(self._clock() * 1_000),
                datasets=datasets,
                routers=tuple(routers[key] for key in sorted(routers)),
            )
        except ThreadDiagnosticsError:
            raise
        except HomeAssistantWebSocketError as error:
            raise ThreadDiagnosticsError(error.code) from None
