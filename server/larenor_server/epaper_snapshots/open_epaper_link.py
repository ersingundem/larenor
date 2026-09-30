"""Bounded Home Assistant/OpenEPaperLink observation and command adapter."""

from __future__ import annotations

import hashlib
import json
import math
import re
from dataclasses import dataclass

from ..errors import ApiError
from ..home_assistant.read_only_websocket import (
    HomeAssistantReadOnlyWebSocket,
    HomeAssistantWebSocketError,
)
from ..services.transport import ProbeTransportError, ServiceTransport
from ..vault import validate_json_bounds

_ENTITY = re.compile(r"(?:image|sensor)\.[a-z0-9_]{1,121}\Z")
_ID = re.compile(r"[0-9a-f]{32}\Z")
_MAX_JSON = 1024 * 1024
_MAX_IMAGE = 2 * 1024 * 1024


def _revision(value) -> int:
    raw = json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8")
    return int.from_bytes(hashlib.sha256(raw).digest()[:6], "big") + 1


def _json(body):
    def unique(pairs):
        value = {}
        for key, child in pairs:
            if key in value:
                raise ValueError("duplicate_key")
            value[key] = child
        return value

    value = json.loads(
        body.decode("utf-8"), object_pairs_hook=unique,
        parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
    )
    validate_json_bounds(value)
    return value


def _jpeg_size(value: bytes):
    if not isinstance(value, bytes) or not 16 <= len(value) <= _MAX_IMAGE:
        raise ValueError("invalid_jpeg")
    if value[:2] != b"\xff\xd8" or value[-2:] != b"\xff\xd9":
        raise ValueError("invalid_jpeg")
    index = 2
    dimensions = None
    scan_seen = False
    while index + 4 <= len(value):
        if value[index] != 0xFF:
            index += 1
            continue
        marker = value[index + 1]
        index += 2
        if marker in {0xD8, 0xD9} or 0xD0 <= marker <= 0xD7:
            continue
        if index + 2 > len(value):
            break
        length = int.from_bytes(value[index:index + 2], "big")
        if length < 2 or index + length > len(value):
            break
        if marker in {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
                      0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}:
            if length < 7:
                break
            height = int.from_bytes(value[index + 3:index + 5], "big")
            width = int.from_bytes(value[index + 5:index + 7], "big")
            if 32 <= height <= 2048 and 64 <= width <= 2048:
                dimensions = (width, height)
                index += length
                continue
            break
        if marker == 0xDA:
            scan_seen = index + length + 8 < len(value) - 2
            break
        index += length
    if dimensions is not None and scan_seen:
        return dimensions
    raise ValueError("invalid_jpeg")


@dataclass(frozen=True)
class OpenEpaperLinkDevice:
    service_id: str
    service_revision: int
    device_id: str
    source_revision: int
    name: str
    image_entity_id: str
    width: int
    height: int
    battery_percent: int | None
    last_seen_at_ms: int | None
    pending_updates: int | None
    update_count: int | None
    reachable: bool

    def public(self):
        return {
            "schemaVersion": 1,
            "serviceId": self.service_id,
            "serviceRevision": self.service_revision,
            "deviceId": self.device_id,
            "sourceRevision": self.source_revision,
            "name": self.name,
            "width": self.width,
            "height": self.height,
            "batteryPercent": self.battery_percent,
            "lastSeenAtMs": self.last_seen_at_ms,
            "reachable": self.reachable,
            "supportedColors": ["black", "white"],
        }


class OpenEpaperLinkProvider:
    """Uses only fixed HA registry/state/image routes and one fixed service."""

    def __init__(self, *, websocket_factory=HomeAssistantReadOnlyWebSocket,
                 transport_factory=ServiceTransport):
        self._websocket_factory = websocket_factory
        self._transport_factory = transport_factory

    @staticmethod
    def _headers(service, *, json_body=False):
        value = {
            "Authorization": "Bearer " + service.credentials["token"],
            "Accept": "application/json" if json_body else "image/jpeg",
        }
        if json_body:
            value["Content-Type"] = "application/json"
        return value

    def _states(self, service, guard):
        try:
            with self._transport_factory(
                service.base_url, timeout=8.0, max_bytes=_MAX_JSON
            ) as transport:
                response = transport.request(
                    "GET", "/api/states", headers=self._headers(service, json_body=True),
                    before_send=guard,
                )
        except (ProbeTransportError, KeyError):
            guard()
            raise ApiError("epaper_source_unavailable", 503) from None
        guard()
        types = [value.split(";", 1)[0].strip().lower()
                 for name, value in response.headers if name == "content-type"]
        if response.status != 200 or types != ["application/json"]:
            raise ApiError("epaper_source_unavailable", 503)
        try:
            value = _json(response.body)
            if (not isinstance(value, list) or len(value) > 10_000
                    or any(type(item) is not dict for item in value)):
                raise ValueError()
            result = {}
            for item in value:
                entity_id = item.get("entity_id")
                if not isinstance(entity_id, str):
                    continue
                if entity_id in result:
                    raise ValueError("duplicate_entity")
                result[entity_id] = item
            return result
        except (ValueError, TypeError, UnicodeError, json.JSONDecodeError):
            raise ApiError("epaper_source_protocol_changed", 503) from None

    def discover(self, service, guard):
        guard()
        try:
            with self._websocket_factory(service).session(
                timeout=8.0, before_io=guard, after_io=guard,
            ) as session:
                entities = session.list_entity_registry()
                devices = session.list_device_registry()
        except HomeAssistantWebSocketError:
            guard()
            raise ApiError("epaper_source_unavailable", 503) from None
        states = self._states(service, guard)
        device_rows = {}
        for item in devices:
            if (type(item.get("id")) is str and _ID.fullmatch(item["id"])
            and any(
                isinstance(identifier, (list, tuple)) and len(identifier) == 2
                and identifier[0] == "open_epaper_link"
                for identifier in item.get("identifiers", [])
            )):
                if item["id"] in device_rows:
                    raise ApiError("epaper_source_protocol_changed", 503)
                device_rows[item["id"]] = item
        grouped = {device_id: [] for device_id in device_rows}
        for item in entities:
            device_id, entity_id = item.get("device_id"), item.get("entity_id")
            if (device_id in grouped and item.get("platform") == "open_epaper_link"
                    and item.get("disabled_by") is None
                    and type(entity_id) is str and _ENTITY.fullmatch(entity_id)):
                grouped[device_id].append(item)
        result = []
        for device_id, rows in grouped.items():
            by_suffix = {}
            image = None
            for item in rows:
                unique_id = item.get("unique_id")
                if not isinstance(unique_id, str) or len(unique_id) > 255:
                    continue
                if item["entity_id"].startswith("image.") and unique_id.endswith("_display_content"):
                    if image is not None:
                        raise ApiError("epaper_source_protocol_changed", 503)
                    image = item["entity_id"]
                for suffix in ("width", "height", "battery_percentage", "last_seen",
                               "pending_updates", "update_count"):
                    if unique_id.endswith("_" + suffix):
                        if suffix in by_suffix:
                            raise ApiError("epaper_source_protocol_changed", 503)
                        by_suffix[suffix] = item["entity_id"]
            if image is None or "width" not in by_suffix or "height" not in by_suffix:
                continue
            def state(name):
                row = states.get(by_suffix.get(name))
                return None if row is None else row.get("state")
            try:
                width, height = int(state("width")), int(state("height"))
                if not (64 <= width <= 2048 and 32 <= height <= 2048):
                    continue
                def number(name, minimum, maximum):
                    raw = state(name)
                    if raw is None or raw in {"unknown", "unavailable"}:
                        return None
                    value = int(raw)
                    return value if minimum <= value <= maximum else None
                battery = number("battery_percentage", 0, 100)
                pending = number("pending_updates", 0, 2**31 - 1)
                updates = number("update_count", 0, 2**53 - 1)
                last_raw = state("last_seen")
                last_seen = None
                if isinstance(last_raw, str) and last_raw not in {"unknown", "unavailable"}:
                    from datetime import datetime
                    last_seen = int(datetime.fromisoformat(last_raw.replace("Z", "+00:00")).timestamp() * 1000)
                    if not 0 <= last_seen <= 2**63 - 1:
                        last_seen = None
            except (ValueError, TypeError, OverflowError):
                continue
            image_state = states.get(image, {}).get("state")
            reachable = image_state not in {None, "unknown", "unavailable"}
            name = device_rows[device_id].get("name_by_user") or device_rows[device_id].get("name")
            if not isinstance(name, str) or not 1 <= len(name) <= 80:
                name = "OpenEPaperLink display"
            observation = [
                service.id, service.revision, device_id, image, width, height,
            ]
            result.append(OpenEpaperLinkDevice(
                service.id, service.revision, device_id, _revision(observation),
                name, image, width, height, battery, last_seen, pending, updates,
                reachable,
            ))
        guard()
        return tuple(sorted(result, key=lambda item: (item.name, item.device_id)))

    @staticmethod
    def literal_payload(title, value, width, height):
        if (not isinstance(title, str) or not isinstance(value, str)
                or not 1 <= len(title) <= 32 or not 1 <= len(value) <= 48):
            raise ApiError("epaper_content_rejected", 400)
        if any(ord(char) < 32 or ord(char) == 127 for char in title + value):
            raise ApiError("epaper_content_rejected", 400)
        title_size = max(12, min(32, height // 6))
        value_size = max(16, min(64, height // 3))
        return [
            {"type": "text", "value": title, "x": width // 2, "y": height // 4,
             "size": title_size, "anchor": "mm", "fill": "black"},
            {"type": "text", "value": value, "x": width // 2, "y": 3 * height // 5,
             "size": value_size, "anchor": "mm", "fill": "black"},
        ]

    def draw(self, service, device, payload, ttl, *, dry_run, guard):
        body = json.dumps({
            "device_id": [device.device_id], "payload": payload,
            "background": "white", "rotate": 0, "dither": 0,
            "ttl": ttl, "refresh_type": "0", "dry-run": dry_run,
        }, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        guard()
        try:
            with self._transport_factory(service.base_url, timeout=8.0, max_bytes=_MAX_JSON) as transport:
                response = transport.request(
                    "POST", "/api/services/open_epaper_link/drawcustom",
                    headers=self._headers(service, json_body=True), body=body,
                    before_send=guard,
                )
        except (ProbeTransportError, KeyError):
            guard()
            return None
        guard()
        if response.status == 200:
            try:
                types = [value.split(";", 1)[0].strip().lower()
                         for name, value in response.headers if name == "content-type"]
                if types != ["application/json"] or not isinstance(_json(response.body), list):
                    return None
            except (ValueError, TypeError, UnicodeError, json.JSONDecodeError):
                return None
            return True
        if response.status in {400, 401, 403, 404, 405, 422}:
            return False
        return None

    def image(self, service, device, guard):
        guard()
        try:
            with self._transport_factory(service.base_url, timeout=8.0, max_bytes=_MAX_IMAGE) as transport:
                response = transport.request(
                    "GET", "/api/image_proxy/" + device.image_entity_id,
                    headers=self._headers(service), before_send=guard,
                )
        except (ProbeTransportError, KeyError):
            guard()
            raise ApiError("epaper_source_unavailable", 503) from None
        guard()
        types = [value.split(";", 1)[0].strip().lower()
                 for name, value in response.headers if name == "content-type"]
        try:
            if response.status != 200 or types != ["image/jpeg"]:
                raise ValueError()
            width, height = _jpeg_size(response.body)
            if (width, height) != (device.width, device.height):
                raise ValueError()
        except ValueError:
            raise ApiError("epaper_source_protocol_changed", 503) from None
        return response.body
