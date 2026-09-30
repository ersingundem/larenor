"""Bounded OctoPrint and Moonraker job control.

The adapter uses only fixed, documented job routes.  It has no redirect,
proxy, cookie, retry, arbitrary G-code, file selection, or print-start surface.
Every mutation is preceded by an exact upstream snapshot check and followed by
a fresh GET.  A successful POST is therefore never treated as proof by itself.
"""

from collections import OrderedDict
from collections.abc import Mapping
import hashlib
import json
import math
import re
import threading

from ..services.transport import ProbeResponse, ProbeTransportError, ServiceTransport
from .models import WorkshopCommand


_IDENTITY = re.compile(r"[0-9a-f]{32}\Z")
_HEATER_OBJECT = re.compile(r"(?:extruder[0-9]*|heater_bed)\Z")
_CACHE_LIMIT = 128
_CACHE_TTL = 30.0
_TIMEOUT = 5.0
_MAX_BYTES = 65536


class WorkshopProviderError(Exception):
    """Stable provider failures which never contain credentials or upstream data."""

    _CODES = frozenset({
        "provider_binding_changed",
        "provider_snapshot_changed",
        "provider_protocol_changed",
        "provider_unavailable",
    })

    def __init__(self, code="provider_unavailable"):
        self.code = code if code in self._CODES else "provider_unavailable"
        super().__init__(self.code)


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate_key")
        result[key] = value
    return result


def _invalid_constant(_value):
    raise ValueError("invalid_number")


def _object(response, expected_status=200):
    if (
        not isinstance(response, ProbeResponse)
        or type(response.status) is not int
        or response.status != expected_status
        or not isinstance(response.body, bytes)
        or len(response.body) > _MAX_BYTES
    ):
        raise WorkshopProviderError("provider_protocol_changed")
    content_types = [
        value for name, value in response.headers
        if isinstance(name, str) and name.lower() == "content-type"
    ]
    if (
        len(content_types) != 1
        or content_types[0].split(";", 1)[0].strip().lower()
        != "application/json"
    ):
        raise WorkshopProviderError("provider_protocol_changed")
    try:
        value = json.loads(
            response.body.decode("utf-8"),
            object_pairs_hook=_unique_object,
            parse_constant=_invalid_constant,
        )
    except (UnicodeError, ValueError, TypeError, json.JSONDecodeError):
        raise WorkshopProviderError("provider_protocol_changed") from None
    if type(value) is not dict:
        raise WorkshopProviderError("provider_protocol_changed")
    return value


def _finite(value, *, minimum=0.0, maximum=10**12):
    if (
        not isinstance(value, (int, float))
        or isinstance(value, bool)
        or not math.isfinite(float(value))
        or not minimum <= float(value) <= maximum
    ):
        raise WorkshopProviderError("provider_protocol_changed")
    return float(value)


def _optional_seconds(value):
    if value is None:
        return None
    return min(31_536_000, int(_finite(value, maximum=31_536_000)))


def _target_temperature(value):
    if value is None:
        return None
    return _finite(value, minimum=-273.15, maximum=1000.0)


def _temperatures(value, *, expected=None, actual_key="actual"):
    if type(value) is not dict or len(value) > 16:
        raise WorkshopProviderError("provider_protocol_changed")
    result = []
    for name, item in value.items():
        name = _text(name, 128)
        if name == "history" or type(item) is not dict:
            raise WorkshopProviderError("provider_protocol_changed")
        if actual_key not in item or "target" not in item:
            raise WorkshopProviderError("provider_protocol_changed")
        result.append({
            "name": name,
            "actualC": _finite(
                item[actual_key], minimum=-273.15, maximum=1000.0
            ),
            "targetC": _target_temperature(item["target"]),
        })
    result.sort(key=lambda item: item["name"])
    if expected is not None and [item["name"] for item in result] != sorted(expected):
        raise WorkshopProviderError("provider_protocol_changed")
    return result


def _text(value, maximum=1024, *, empty=False):
    if (
        not isinstance(value, str)
        or len(value) > maximum
        or (not empty and not value)
        or any(ord(char) < 32 or ord(char) == 127
               or 0xD800 <= ord(char) <= 0xDFFF for char in value)
    ):
        raise WorkshopProviderError("provider_protocol_changed")
    return value


def _digest(value):
    encoded = json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _revision(snapshot):
    # This is a content version of the actual upstream snapshot, not a guessed
    # sequence.  It fits the public positive signed-64-bit revision contract.
    return int(_digest(snapshot)[:15], 16) + 1


def _job_identity(kind, value):
    return _digest([kind, value])[:32]


class WorkshopHttpProvider:
    """Concrete provider for authenticated OctoPrint and Moonraker services."""

    exact_observations = True

    def __init__(self, clock, *, transport_factory=None):
        if not callable(clock) or transport_factory is not None and not callable(transport_factory):
            raise ValueError("invalid_workshop_provider")
        self._clock = clock
        self._factory = transport_factory or ServiceTransport
        self._lock = threading.RLock()
        self._snapshots = OrderedDict()

    @staticmethod
    def _actor(actor):
        if (
            actor is None
            or _IDENTITY.fullmatch(getattr(actor, "id", "")) is None
            or getattr(actor, "role", None) != "admin"
            or getattr(actor, "must_change_password", True) is not False
        ):
            raise WorkshopProviderError("provider_binding_changed")
        return actor.id

    @staticmethod
    def _binding(binding):
        if (
            binding is None
            or _IDENTITY.fullmatch(getattr(binding, "id", "")) is None
            or type(getattr(binding, "revision", None)) is not int
            or not 1 <= binding.revision <= 2**63 - 1
            or getattr(binding, "kind", None) not in {"octoprint", "moonraker"}
            or not isinstance(getattr(binding, "base_url", None), str)
            or not isinstance(getattr(binding, "credentials", None), Mapping)
            or set(binding.credentials) != {"apiKey"}
            or not isinstance(binding.credentials["apiKey"], str)
            or not 1 <= len(binding.credentials["apiKey"]) <= 2048
        ):
            raise WorkshopProviderError("provider_binding_changed")
        try:
            binding.credentials["apiKey"].encode("latin-1")
        except UnicodeError:
            raise WorkshopProviderError("provider_binding_changed") from None
        return binding

    @staticmethod
    def _printer(printer_id):
        if not isinstance(printer_id, str) or _IDENTITY.fullmatch(printer_id) is None:
            raise WorkshopProviderError("provider_binding_changed")
        return printer_id

    @staticmethod
    def _headers(binding, *, body=False):
        value = {
            "Accept": "application/json",
            "X-Api-Key": binding.credentials["apiKey"],
        }
        if body:
            value["Content-Type"] = "application/json"
        return value

    def _request(self, binding, method, path, *, body=None, query=None):
        transport = None
        try:
            transport = self._factory(
                binding.base_url, timeout=_TIMEOUT, max_bytes=_MAX_BYTES
            )
            return transport.request(
                method,
                path,
                headers=self._headers(binding, body=body is not None),
                body=body,
                query_parameters=query,
            )
        except WorkshopProviderError:
            raise
        except (ProbeTransportError, OSError, TypeError, ValueError):
            raise WorkshopProviderError("provider_unavailable") from None
        finally:
            if transport is not None:
                transport.close()

    def _octoprint(self, binding):
        data = _object(self._request(binding, "GET", "/api/job"))
        try:
            job = data["job"]
            progress = data["progress"]
            state_text = _text(data["state"], 80)
            if type(job) is not dict or type(progress) is not dict:
                raise KeyError
        except (KeyError, TypeError):
            raise WorkshopProviderError("provider_protocol_changed") from None

        printer = _object(self._request(
            binding, "GET", "/api/printer", query={"exclude": "sd"}
        ))
        try:
            printer_state = printer["state"]
            temperatures = printer["temperature"]
            if type(printer_state) is not dict:
                raise KeyError
            printer_text = _text(printer_state["text"], 80)
            flags = printer_state["flags"]
            if type(flags) is not dict:
                raise KeyError
            flag_names = (
                "operational", "paused", "printing", "cancelling",
                "pausing", "error", "ready", "closedOrError",
            )
            if any(type(flags.get(name)) is not bool for name in flag_names):
                raise KeyError
            temperatures = _temperatures(temperatures)
        except (KeyError, TypeError):
            raise WorkshopProviderError("provider_protocol_changed") from None

        states = {
            "Printing": "printing", "Pausing": "printing",
            "Paused": "paused", "Cancelling": "printing",
            "Operational": "idle", "Offline": "error",
            "Offline after error": "error", "Error": "error",
        }
        if state_text not in states:
            raise WorkshopProviderError("provider_protocol_changed")
        expected_flag = {
            "Printing": "printing",
            "Pausing": "pausing",
            "Paused": "paused",
            "Cancelling": "cancelling",
            "Operational": "operational",
            "Offline": "closedOrError",
            "Offline after error": "closedOrError",
            "Error": "error",
        }[state_text]
        # Both endpoints document textual state as presentation text with a
        # non-exhaustive vocabulary.  Bind the snapshot to each text value,
        # but use the stable state flag to corroborate the job state.
        if flags[expected_flag] is not True:
            raise WorkshopProviderError("provider_protocol_changed")
        state = states[state_text]
        active = state in {"printing", "paused"}
        identity = None
        if active or state == "error":
            try:
                file = job["file"]
                if type(file) is not dict:
                    raise KeyError
                path = file.get("path") or file.get("name")
                path = _text(path, 2048)
                origin = _text(file["origin"], 32)
                size = file.get("size")
                date = file.get("date")
                if size is not None:
                    if type(size) is not int:
                        raise TypeError
                    size = int(_finite(size, maximum=2**63 - 1))
                if date is not None:
                    date = _finite(date)
                identity = [origin, path, size, date]
            except (KeyError, TypeError, ValueError):
                raise WorkshopProviderError("provider_protocol_changed") from None
        completion = progress.get("completion")
        permille = 0 if completion is None else round(
            _finite(completion, maximum=100.0) * 10
        )
        remaining = _optional_seconds(progress.get("printTimeLeft"))
        if state == "idle":
            permille, remaining = 0, None
        connectivity = "offline" if flags["closedOrError"] else "online"
        thermal = "unknown"
        emergency = "unknown"
        supported = []
        if state_text == "Printing":
            supported = ["pause", "cancel"]
        elif state_text == "Paused":
            supported = ["cancel"]
        raw = {
            "kind": "octoprint", "identity": identity, "state": state_text,
            "connectivity": connectivity, "printerState": printer_text,
        }
        return self._observation(raw, state, identity, permille, remaining,
                                 connectivity, thermal, emergency, temperatures,
                                 supported)

    def _moonraker_object(self, binding):
        query = {
            "print_stats": "", "virtual_sdcard": "", "webhooks": "",
            "heaters": "available_heaters",
        }
        envelope = _object(self._request(
            binding, "GET", "/printer/objects/query", query=query
        ))
        try:
            result = envelope["result"]
            status = result["status"]
            eventtime = _finite(result["eventtime"])
            webhooks = status["webhooks"]
            virtual = status["virtual_sdcard"]
            stats = status["print_stats"]
            heaters = status["heaters"]
            if not all(
                type(item) is dict
                for item in (result, status, webhooks, virtual, stats, heaters)
            ):
                raise KeyError
            klippy = _text(webhooks["state"], 32)
            state_text = _text(stats["state"], 32)
            filename = _text(stats.get("filename", ""), 2048, empty=True)
            progress = _finite(virtual["progress"], maximum=1.0)
            available_heaters = heaters["available_heaters"]
            if (
                type(available_heaters) is not list
                or len(available_heaters) > 16
                or any(not isinstance(item, str) for item in available_heaters)
                or len(set(available_heaters)) != len(available_heaters)
            ):
                raise KeyError
            safe_heaters = sorted(
                _text(item, 128)
                for item in available_heaters
                if _HEATER_OBJECT.fullmatch(item) is not None
            )
        except (KeyError, TypeError):
            raise WorkshopProviderError("provider_protocol_changed") from None
        temperatures = []
        if safe_heaters:
            thermal_envelope = _object(self._request(
                binding,
                "GET",
                "/printer/objects/query",
                query={name: "temperature,target" for name in safe_heaters},
            ))
            try:
                thermal_result = thermal_envelope["result"]
                thermal_status = thermal_result["status"]
                _finite(thermal_result["eventtime"])
                temperatures = _temperatures(
                    thermal_status,
                    expected=safe_heaters,
                    actual_key="temperature",
                )
            except (KeyError, TypeError):
                raise WorkshopProviderError("provider_protocol_changed") from None
        states = {
            "standby": "idle", "printing": "printing", "paused": "paused",
            "complete": "completed", "cancelled": "completed", "error": "error",
        }
        if state_text not in states:
            raise WorkshopProviderError("provider_protocol_changed")
        state = states[state_text]
        identity = None
        metadata = None
        if state_text != "standby":
            if not filename:
                raise WorkshopProviderError("provider_protocol_changed")
            metadata_envelope = _object(self._request(
                binding, "GET", "/server/files/metadata",
                query={"filename": filename},
            ))
            try:
                metadata = metadata_envelope["result"]
                if type(metadata) is not dict or metadata.get("filename") != filename:
                    raise KeyError
                job_id = _text(metadata["job_id"], 128)
                start = _finite(metadata["print_start_time"])
                identity = [job_id, filename, start]
            except (KeyError, TypeError):
                raise WorkshopProviderError("provider_protocol_changed") from None
        permille = round(progress * 1000)
        remaining = None
        if metadata is not None and metadata.get("estimated_time") is not None:
            estimate = _finite(metadata["estimated_time"], maximum=31_536_000)
            printed = _finite(stats.get("print_duration", 0), maximum=31_536_000)
            remaining = min(31_536_000, round(max(0.0, estimate - printed)))
        if state == "idle":
            permille, remaining = 0, None
        connectivity = "online" if klippy == "ready" else "offline"
        thermal = "unknown"
        emergency = "unknown"
        supported = []
        if connectivity == "online" and state_text == "printing":
            supported = ["pause", "cancel"]
        elif connectivity == "online" and state_text == "paused":
            supported = ["cancel"]
        raw = {
            "kind": "moonraker", "identity": identity,
            "state": state_text, "connectivity": connectivity,
            "heaterObjects": safe_heaters,
        }
        return self._observation(raw, state, identity, permille, remaining,
                                 connectivity, thermal, emergency, temperatures,
                                 supported)

    def _observation(self, raw, state, identity, permille, remaining,
                     connectivity, thermal, emergency, temperatures, supported):
        observed_at = float(self._clock())
        if not math.isfinite(observed_at):
            raise WorkshopProviderError("provider_unavailable")
        return {
            "schemaVersion": 1,
            "providerRevision": _revision(raw),
            "jobId": None if identity is None else _job_identity(raw["kind"], identity),
            "jobState": state,
            "progressPermille": permille,
            "remainingSeconds": remaining,
            "connectivity": connectivity,
            "thermal": thermal,
            # Neither generic API provides authoritative switch state for these.
            "filament": "unknown",
            "door": "unknown",
            "emergency": emergency,
            "temperatures": temperatures,
            "supportedActions": supported,
            "observedAt": observed_at,
        }

    def _fetch(self, binding):
        if binding.kind == "octoprint":
            return self._octoprint(binding)
        return self._moonraker_object(binding)

    @staticmethod
    def _key(actor_id, binding, printer_id):
        return actor_id, binding.id, binding.revision, printer_id

    def _remember(self, key, observation):
        with self._lock:
            self._snapshots[key] = dict(observation)
            self._snapshots.move_to_end(key)
            while len(self._snapshots) > _CACHE_LIMIT:
                self._snapshots.popitem(last=False)

    def observe(self, actor, binding, printer_id):
        actor_id = self._actor(actor)
        binding = self._binding(binding)
        printer_id = self._printer(printer_id)
        observation = self._fetch(binding)
        self._remember(self._key(actor_id, binding, printer_id), observation)
        return dict(observation)

    def capability(self, actor, binding, printer_id):
        actor_id = self._actor(actor)
        binding = self._binding(binding)
        printer_id = self._printer(printer_id)
        key = self._key(actor_id, binding, printer_id)
        now = float(self._clock())
        with self._lock:
            observation = self._snapshots.get(key)
            if observation is None:
                raise WorkshopProviderError("provider_snapshot_changed")
            observation = dict(observation)
        if (
            not math.isfinite(now)
            or observation["observedAt"] > now + 5
            or now - observation["observedAt"] > _CACHE_TTL
            or not observation["supportedActions"]
        ):
            raise WorkshopProviderError("provider_snapshot_changed")
        return {
            "schemaVersion": 1,
            "providerRevision": observation["providerRevision"],
            "supportedActions": list(observation["supportedActions"]),
            "observedAt": observation["observedAt"],
        }

    def execute(self, actor, binding, value):
        actor_id = self._actor(actor)
        binding = self._binding(binding)
        try:
            command = WorkshopCommand.model_validate(value)
        except Exception:
            raise WorkshopProviderError("provider_binding_changed") from None
        if (
            command.actorId != actor_id
            or command.serviceId != binding.id
            or command.serviceRevision != binding.revision
        ):
            raise WorkshopProviderError("provider_binding_changed")
        key = self._key(actor_id, binding, command.printerId)
        with self._lock:
            expected = self._snapshots.get(key)
            expected = None if expected is None else dict(expected)
        if (
            expected is None
            or expected["providerRevision"] != command.providerRevision
            or expected["jobId"] != command.expectedJobId
            or command.action not in expected["supportedActions"]
        ):
            raise WorkshopProviderError("provider_snapshot_changed")
        current = self._fetch(binding)
        if (
            current["providerRevision"] != expected["providerRevision"]
            or current["jobId"] != expected["jobId"]
            or command.action not in current["supportedActions"]
        ):
            raise WorkshopProviderError("provider_snapshot_changed")

        if binding.kind == "octoprint":
            body = (
                {"command": "pause", "action": "pause"}
                if command.action == "pause" else {"command": "cancel"}
            )
            encoded = json.dumps(
                body, sort_keys=True, separators=(",", ":")
            ).encode("ascii")
            reply = self._request(binding, "POST", "/api/job", body=encoded)
            if (
                not isinstance(reply, ProbeResponse)
                or reply.status != 204
                or reply.body != b""
            ):
                raise WorkshopProviderError("provider_protocol_changed")
        else:
            path = "/printer/print/pause" if command.action == "pause" else "/printer/print/cancel"
            reply = _object(self._request(binding, "POST", path))
            if reply != {"result": "ok"}:
                raise WorkshopProviderError("provider_protocol_changed")

        observed = self._fetch(binding)
        self._remember(key, observed)
        return {
            "schemaVersion": 1,
            "commandId": command.commandId,
            "printerId": command.printerId,
            "action": command.action,
            "providerRevision": command.providerRevision,
            "observation": observed,
        }
