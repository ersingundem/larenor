"""Bounded Jellyfin Live TV guide and timer adapter.

Official Jellyfin 10.11 API/source reviewed 2026-09-30:
https://github.com/jellyfin/jellyfin/blob/v10.11.1/Jellyfin.Api/Controllers/LiveTvController.cs
https://github.com/jellyfin/jellyfin/blob/v10.11.1/src/Jellyfin.LiveTv/LiveTvManager.cs
"""

from datetime import datetime, timezone
import hashlib
import hmac
import json
import math
import re
import socket
import ssl
import time

from ..errors import ApiError
from ..services.transport import (
    ProbeTransportError, ServiceTransport, _Deadline, _Reader, _path, _query,
    _remaining, _request_bytes, _resolve, _response,
)
from .models import EpgProgramme, SourceSnapshotRequest
from .runtime import (
    LiveTvProviderCapability, LiveTvRecordingReadback, LiveTvRecordingReceipt,
)


_PROVIDER = re.compile(
    r"jellyfin:([0-9a-f]{32}):([1-9][0-9]{0,18}):([0-9a-f]{16})\Z"
)
_TIMER = re.compile(r"jf:([0-9a-f]{32}):([1-9][0-9]{0,18}):([A-Za-z0-9_.:-]{1,64})\Z")
_UPSTREAM_ID = re.compile(r"[0-9A-Fa-f-]{32,36}\Z")
_SAFE_TIMER = re.compile(r"[A-Za-z0-9_.:-]{1,64}\Z")
_MAX_BYTES = 2 * 1024 * 1024
_MAX_TIMERS = 256
_MAX_RECORDING_BYTES = 10_995_116_277_760
_MARKER = "\n\n[Larenor request:{}]"
_STATE_RANK = {
    "scheduled": 0, "recording": 1, "interrupted": 2,
    "completed": 3, "cancelled": 4, "uncertain": 5,
}


def _object(raw):
    def pairs(values):
        result = {}
        for key, value in values:
            if key in result:
                raise ValueError()
            result[key] = value
        return result

    try:
        return json.loads(
            raw.decode("utf-8"), object_pairs_hook=pairs,
            parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
        )
    except (UnicodeError, ValueError, TypeError):
        raise ApiError("live_tv_source_unavailable", 503) from None


def _instant(value):
    if not isinstance(value, str) or not 10 <= len(value) <= 40:
        raise ValueError()
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (ValueError, OverflowError):
        raise ValueError() from None
    if parsed.tzinfo is None:
        raise ValueError()
    result = int(parsed.astimezone(timezone.utc).timestamp())
    if not 1 <= result <= 253402300799:
        raise ValueError()
    return result


def _public_id(value):
    if not isinstance(value, str) or _UPSTREAM_ID.fullmatch(value) is None:
        raise ValueError()
    normalized = value.replace("-", "").lower()
    if not re.fullmatch(r"[0-9a-f]{32}", normalized):
        raise ValueError()
    return normalized


class _JellyfinTransport(ServiceTransport):
    """ServiceTransport with DELETE enabled only for this fixed adapter."""

    def request(self, method, path, headers=None, body=None, *, before_send=None,
                query_parameters=None):
        if method != "DELETE":
            return super().request(
                method, path, headers, body, before_send=before_send,
                query_parameters=query_parameters,
            )
        if before_send is not None and not callable(before_send):
            raise ProbeTransportError("invalid_request")
        deadline = time.monotonic() + self._timeout
        route = self._prefix + _path(path) + _query(query_parameters)
        if len(route) > 4096:
            raise ProbeTransportError("invalid_path")
        message = _request_bytes(
            "DELETE", route, self._authority, headers, None, allow_delete=True
        )
        with self._lock:
            if self._closed:
                raise ProbeTransportError("transport_closed")
        family, address = _resolve(
            self._resolver, self._host, self._port, deadline, self._address_guard
        )
        scope = _Deadline(deadline)
        with self._lock:
            if self._closed:
                scope.finish()
                raise ProbeTransportError("transport_closed")
            self._active.add(scope)
        error = result = before_error = None
        try:
            if self._address_guard is not None:
                try:
                    self._address_guard(address[0])
                except BaseException as caught:
                    before_error = caught
                    raise ProbeTransportError("address_blocked") from None
            if self._connector is None:
                connection = socket.socket(family, socket.SOCK_STREAM)
                scope.attach(connection)
                connection.settimeout(_remaining(deadline))
                connection.connect(address)
            else:
                connection = self._connector(family, address, _remaining(deadline))
                scope.attach(connection)
            if self._scheme == "https":
                connection = ssl.create_default_context().wrap_socket(
                    connection, server_hostname=self._host, do_handshake_on_connect=False
                )
                scope.attach(connection)
                connection.settimeout(_remaining(deadline))
                connection.do_handshake()
            if self._address_guard is not None and connection.getpeername() != address:
                raise ProbeTransportError("address_blocked")
            if before_send is not None:
                try:
                    before_send()
                except BaseException as caught:
                    before_error = caught
                    raise ProbeTransportError("request_failed") from None
            connection.settimeout(_remaining(deadline))
            connection.sendall(message)
            result = _response(_Reader(connection, deadline), self._max_bytes)
            _remaining(deadline)
        except ProbeTransportError as caught:
            error = caught
        except TimeoutError:
            error = ProbeTransportError("request_timeout")
        except ssl.SSLError:
            error = ProbeTransportError("tls_failed")
        except Exception:
            error = ProbeTransportError("request_failed")
        finally:
            expired = scope.expired.is_set()
            scope.finish()
            with self._lock:
                self._active.discard(scope)
                closed = self._closed
        if closed:
            raise ProbeTransportError("transport_closed")
        if before_error is not None:
            raise before_error
        if expired or time.monotonic() >= deadline:
            raise ProbeTransportError("request_timeout")
        if error is not None:
            raise error
        return result


class JellyfinLiveTvProvider:
    def __init__(self, db, auth, settings, services, key, *, transport_factory=None):
        self.db, self.auth, self.settings, self.services = db, auth, settings, services
        self._key = hmac.new(key, b"larenor-jellyfin-live-tv-v1", hashlib.sha256).digest()
        self._transport_factory = transport_factory or _JellyfinTransport

    def _service(self, service_id, revision, *, actor=None):
        with self.db.connection() as connection:
            connection.execute("BEGIN")
            if actor is not None:
                self.auth.assert_current(connection, actor)
                if actor.must_change_password:
                    raise ApiError("password_change_required", 403)
                if actor.role != "admin":
                    raise ApiError("forbidden", 403)
            try:
                row, record = self.services._record(connection, service_id, revision)
            except ApiError:
                raise ApiError("live_tv_source_changed", 409) from None
            keys = set(record["credentials"])
            if (record["kind"] != "jellyfin"
                    or record["verification"]["state"] != "authenticated"
                    or keys not in ({"apiKey"}, {"token"})):
                raise ApiError("live_tv_source_changed", 409)
            return self.services._private(row, record), record["verification"]["version"]

    def _guard(self, service_id, revision):
        def current():
            self._service(service_id, revision)
            return True
        return current

    @staticmethod
    def _headers(service, *, json_body=False):
        key = "apiKey" if "apiKey" in service.credentials else "token"
        value = service.credentials[key]
        if (not isinstance(value, str) or not 1 <= len(value) <= 2048
                or any(ord(char) < 32 or ord(char) == 127 for char in value)):
            raise ApiError("live_tv_source_unavailable", 503)
        result = {"Accept": "application/json", "X-Emby-Token": value}
        if json_body:
            result["Content-Type"] = "application/json"
        return result

    def _request(self, service, method, path, *, query=None, body=None, statuses=(200,)):
        guard = self._guard(service.id, service.revision)
        encoded = None
        if body is not None:
            encoded = json.dumps(
                body, ensure_ascii=False, sort_keys=True, separators=(",", ":")
            ).encode("utf-8")
            if len(encoded) > 65536:
                raise ApiError("live_tv_recorder_unavailable", 503)
        transport = None
        try:
            transport = self._transport_factory(
                service.base_url, timeout=5, max_bytes=_MAX_BYTES
            )
            response = transport.request(
                method, path, headers=self._headers(service, json_body=body is not None),
                body=encoded, query_parameters=query, before_send=guard,
            )
            guard()
            if response.status not in statuses:
                raise ApiError("live_tv_recorder_unavailable", 503)
            if response.status == 404:
                return None
            if response.status == 204:
                return None
            content_types = [
                value.split(";", 1)[0].strip().lower()
                for name, value in response.headers if name.lower() == "content-type"
            ]
            if content_types != ["application/json"]:
                raise ApiError("live_tv_source_unavailable", 503)
            return _object(response.body)
        except ApiError:
            raise
        except (ProbeTransportError, ValueError, TypeError):
            raise ApiError("live_tv_recorder_unavailable", 503) from None
        finally:
            if transport is not None:
                transport.close()

    def _identity(self, service):
        info = self._request(service, "GET", "/System/Info")
        live = self._request(service, "GET", "/LiveTv/Info")
        if (type(info) is not dict or info.get("ProductName") not in {
                "Jellyfin Server", "Jellyfin"}
                or info.get("StartupWizardCompleted") is not True
                or not isinstance(info.get("Version"), str)
                or not re.fullmatch(r"10\.11\.[0-9]{1,6}", info["Version"])
                or type(live) is not dict or live.get("IsEnabled") is not True):
            raise ApiError("live_tv_source_unavailable", 503)
        try:
            server_id = _public_id(info.get("Id"))
        except ValueError:
            raise ApiError("live_tv_source_unavailable", 503) from None
        fingerprint = hmac.new(
            self._key,
            (service.id + "\0" + str(service.revision) + "\0" +
             server_id + "\0" + info["Version"]).encode(),
            hashlib.sha256,
        ).hexdigest()[:16]
        revision = int.from_bytes(bytes.fromhex(fingerprint[:12]), "big") + 1
        return fingerprint, revision

    def _provider(self, service, fingerprint):
        current, revision = self._identity(service)
        if fingerprint is not None and not hmac.compare_digest(current, fingerprint):
            raise ApiError("live_tv_source_changed", 409)
        return f"jellyfin:{service.id}:{service.revision}:{current}", revision

    def _from_provider(self, provider_id):
        match = _PROVIDER.fullmatch(provider_id or "")
        if match is None:
            raise ApiError("live_tv_source_changed", 409)
        service_id, raw_revision, fingerprint = match.groups()
        revision = int(raw_revision)
        if revision >= 2**63:
            raise ApiError("live_tv_source_changed", 409)
        service, _version = self._service(service_id, revision)
        provider_id, provider_revision = self._provider(service, fingerprint)
        return service, provider_id, provider_revision

    def source_options(self, actor):
        services = []
        for item in self.services.list(actor)["services"]:
            if (item["kind"] == "jellyfin"
                    and item["verification"]["state"] == "authenticated"
                    and isinstance(item["verification"]["version"], str)
                    and re.fullmatch(
                        r"10\.11\.[0-9]{1,6}",
                        item["verification"]["version"],
                    )):
                services.append({
                    "serviceId": item["id"], "serviceRevision": item["revision"],
                    "name": item["name"], "version": item["verification"]["version"],
                })
        return {"schemaVersion": 1, "services": services}

    def observe_source(self, actor, request):
        service, _version = self._service(
            request.serviceId, request.expectedServiceRevision, actor=actor
        )
        provider_id, provider_revision = self._provider(service, None)
        now = int(self.settings.clock())
        end = datetime.fromtimestamp(now + 7 * 86400, timezone.utc)
        start = datetime.fromtimestamp(max(1, now - 3600), timezone.utc)
        result = self._request(service, "GET", "/LiveTv/Programs", query={
            "minStartDate": start.isoformat().replace("+00:00", "Z"),
            "maxStartDate": end.isoformat().replace("+00:00", "Z"),
            "startIndex": "0", "limit": "2048", "sortBy": "StartDate",
            "sortOrder": "Ascending", "enableImages": "false",
            "enableUserData": "false", "enableTotalRecordCount": "true",
        })
        if type(result) is not dict or type(result.get("Items")) is not list:
            raise ApiError("live_tv_source_unavailable", 503)
        if len(result["Items"]) > 2048 or result.get("TotalRecordCount") != len(result["Items"]):
            raise ApiError("live_tv_source_unavailable", 503)
        programmes = []
        try:
            for value in result["Items"]:
                if type(value) is not dict:
                    raise ValueError()
                programmes.append(EpgProgramme(
                    programmeId=_public_id(value.get("Id")),
                    channelId=_public_id(value.get("ChannelId")),
                    channelName=value.get("ChannelName"), title=value.get("Name"),
                    startsAt=_instant(value.get("StartDate")),
                    endsAt=_instant(value.get("EndDate")),
                ))
        except (ValueError, TypeError):
            raise ApiError("live_tv_source_unavailable", 503) from None
        return SourceSnapshotRequest(
            requestId=request.requestId, expectedRevision=request.expectedRevision,
            providerId=provider_id, providerKind=request.providerKind,
            providerRevision=provider_revision, timeZone=request.timeZone,
            parallelTuners=1, quotaBytes=request.quotaBytes, capturedAt=now,
            programmes=programmes,
        )

    def capability(self, source=None):
        if source is None:
            raise ApiError("live_tv_source_unavailable", 503)
        _service, provider_id, revision = self._from_provider(source.providerId)
        return LiveTvProviderCapability(
            provider_id=provider_id, provider_kind=source.providerKind,
            provider_revision=revision, parallel_tuners=1,
            quota_bytes=source.quotaBytes,
        )

    def _marker(self, request_id):
        digest = hmac.new(
            self._key, ("timer\0" + request_id).encode(), hashlib.sha256
        ).hexdigest()[:32]
        return _MARKER.format(digest)

    def _timers(self, service):
        value = self._request(service, "GET", "/LiveTv/Timers")
        if (type(value) is not dict or type(value.get("Items")) is not list
                or len(value["Items"]) > _MAX_TIMERS
                or value.get("TotalRecordCount") != len(value["Items"])
                or any(type(item) is not dict for item in value["Items"])):
            raise ApiError("live_tv_recorder_unavailable", 503)
        return value["Items"]

    def _marked(self, service, request_id):
        marker = self._marker(request_id)
        values = [item for item in self._timers(service)
                  if isinstance(item.get("Overview"), str)
                  and item["Overview"].endswith(marker)]
        if len(values) > 1:
            raise ApiError("live_tv_recorder_unavailable", 503)
        return values[0] if values else None

    def _timer_id(self, value):
        timer_id = value.get("Id")
        if not isinstance(timer_id, str) or _SAFE_TIMER.fullmatch(timer_id) is None:
            raise ApiError("live_tv_recorder_unavailable", 503)
        return timer_id

    @staticmethod
    def _composite(service, timer_id):
        value = f"jf:{service.id}:{service.revision}:{timer_id}"
        if len(value) > 128:
            raise ApiError("live_tv_recorder_unavailable", 503)
        return value

    def _parse_recording_id(self, value):
        match = _TIMER.fullmatch(value or "")
        if match is None:
            raise ApiError("live_tv_recorder_unavailable", 503)
        service_id, raw_revision, timer_id = match.groups()
        revision = int(raw_revision)
        if revision >= 2**63:
            raise ApiError("live_tv_recorder_unavailable", 503)
        service, _version = self._service(service_id, revision)
        return service, timer_id

    def _recordings(self, service, *, in_progress=False):
        query = {
            "startIndex": "0", "limit": "256", "fields": "MediaSources",
            "enableImages": "false", "enableUserData": "false",
            "enableTotalRecordCount": "true",
        }
        if in_progress:
            query["isInProgress"] = "true"
        value = self._request(service, "GET", "/LiveTv/Recordings", query={
            **query,
        })
        if (type(value) is not dict or type(value.get("Items")) is not list
                or len(value["Items"]) > 256
                or value.get("TotalRecordCount") != len(value["Items"])
                or any(type(item) is not dict for item in value["Items"])):
            raise ApiError("live_tv_recorder_unavailable", 503)
        return value["Items"]

    @staticmethod
    def _recording_size(item):
        sources = item.get("MediaSources")
        if type(sources) is not list or not 1 <= len(sources) <= 32:
            raise ApiError("live_tv_recorder_unavailable", 503)
        sizes = [source.get("Size") for source in sources if type(source) is dict]
        if (len(sizes) != len(sources) or any(type(size) is not int or size < 0 for size in sizes)
                or sum(sizes) > _MAX_RECORDING_BYTES):
            raise ApiError("live_tv_recorder_unavailable", 503)
        return sum(sizes)

    def storage_usage(self, source):
        service, _provider_id, revision = self._from_provider(source.providerId)
        if revision != source.providerRevision:
            raise ApiError("live_tv_source_changed", 409)
        # Include recordings made outside Larenor and retained partial files.
        size = sum(self._recording_size(item) for item in self._recordings(service))
        if size > _MAX_RECORDING_BYTES:
            raise ApiError("live_tv_recorder_unavailable", 503)
        return size

    def _recording(self, service, timer_id):
        matches = [item for item in self._recordings(service)
                   if item.get("TimerId") == timer_id]
        if len(matches) > 1:
            raise ApiError("live_tv_recorder_unavailable", 503)
        if not matches:
            return False, 0
        return True, self._recording_size(matches[0])

    def _read_timer(self, service, timer_id, provider_revision, *, cancelled=False):
        value = self._request(
            service, "GET", f"/LiveTv/Timers/{timer_id}", statuses=(200, 404)
        )
        if value is None:
            exists, size = self._recording(service, timer_id)
            state = "completed" if exists else "cancelled"
            if cancelled:
                if any(item.get("TimerId") == timer_id
                       for item in self._recordings(service, in_progress=True)):
                    raise ApiError("live_tv_recorder_unavailable", 503)
                state = "cancelled"
        else:
            status = value.get("Status") if type(value) is dict else None
            state = {
                "New": "scheduled", "InProgress": "recording",
                "Completed": "completed", "Cancelled": "cancelled",
                "ConflictedOk": "interrupted", "ConflictedNotOk": "interrupted",
                "Error": "interrupted",
            }.get(status)
            if state is None:
                raise ApiError("live_tv_recorder_unavailable", 503)
            if state in {"recording", "completed", "interrupted"}:
                _exists, size = self._recording(service, timer_id)
            else:
                size = 0
        revision = _STATE_RANK[state] * (_MAX_RECORDING_BYTES + 1) + size + 1
        return LiveTvRecordingReadback(
            provider_recording_id=self._composite(service, timer_id),
            provider_revision=provider_revision, readback_revision=revision,
            state=state, bytes_written=size, observed_at=int(self.settings.clock()),
        )

    def _create(self, service, command):
        existing = self._marked(service, command.request_id)
        if existing is None:
            defaults = self._request(
                service, "GET", "/LiveTv/Timers/Defaults",
                query={"programId": command.programme["programmeId"]},
            )
            if type(defaults) is not dict:
                raise ApiError("live_tv_recorder_unavailable", 503)
            programme = command.programme
            try:
                coherent = (
                    _public_id(defaults.get("ProgramId"))
                    == programme["programmeId"]
                    and _public_id(defaults.get("ChannelId"))
                    == programme["channelId"]
                    and _instant(defaults.get("StartDate"))
                    == programme["startsAt"]
                    and _instant(defaults.get("EndDate"))
                    == programme["endsAt"]
                )
            except (KeyError, TypeError, ValueError):
                coherent = False
            if not coherent:
                raise ApiError("live_tv_recorder_unavailable", 503)
            overview = defaults.get("Overview")
            if overview is None:
                overview = ""
            if not isinstance(overview, str) or any(
                    ord(char) < 32 and char not in "\n\r\t" for char in overview):
                raise ApiError("live_tv_recorder_unavailable", 503)
            marker = self._marker(command.request_id)
            defaults["Overview"] = overview[:1024 - len(marker)] + marker
            try:
                self._request(
                    service, "POST", "/LiveTv/Timers", body=defaults,
                    statuses=(204,),
                )
            except ApiError:
                # The response may be lost after Jellyfin committed. Do not send
                # again here; the same request id reconciles on the next attempt.
                raise
            existing = self._marked(service, command.request_id)
        if existing is None:
            raise ApiError("live_tv_recorder_unavailable", 503)
        return self._timer_id(existing)

    def apply(self, command):
        service, provider_id, provider_revision = self._from_provider(command.provider_id)
        if provider_revision != command.provider_revision:
            raise ApiError("live_tv_source_changed", 409)
        if command.action == "restart":
            previous_service, previous_timer_id = self._parse_recording_id(
                command.provider_recording_id
            )
            if ((previous_service.id, previous_service.revision)
                    != (service.id, service.revision)):
                raise ApiError("live_tv_source_changed", 409)
            previous = self._request(
                service, "GET", f"/LiveTv/Timers/{previous_timer_id}",
                statuses=(200, 404),
            )
            if (previous is not None
                    and (type(previous) is not dict
                         or previous.get("Status") not in {
                             "Error", "ConflictedOk", "ConflictedNotOk",
                             "Cancelled",
                         })):
                raise ApiError("live_tv_recording_inactive", 409)
            timer_id = self._create(service, command)
        elif command.action == "schedule":
            timer_id = self._create(service, command)
        elif command.action == "cancel":
            recording_service, timer_id = self._parse_recording_id(
                command.provider_recording_id
            )
            if ((recording_service.id, recording_service.revision)
                    != (service.id, service.revision)):
                raise ApiError("live_tv_source_changed", 409)
            current = self._request(
                service, "GET", f"/LiveTv/Timers/{timer_id}", statuses=(200, 404)
            )
            if current is not None:
                self._request(
                    service, "DELETE", f"/LiveTv/Timers/{timer_id}", statuses=(204,)
                )
        else:
            raise ApiError("live_tv_recorder_unavailable", 503)
        readback = self._read_timer(
            service, timer_id, provider_revision,
            cancelled=command.action == "cancel",
        )
        return LiveTvRecordingReceipt(
            request_id=command.request_id, action=command.action,
            recording_id=command.recording_id,
            provider_recording_id=readback.provider_recording_id,
            provider_revision=provider_revision, readback=readback,
        )

    def readback(self, provider_recording_id):
        service, timer_id = self._parse_recording_id(provider_recording_id)
        _provider, revision = self._provider(service, None)
        return self._read_timer(service, timer_id, revision)
