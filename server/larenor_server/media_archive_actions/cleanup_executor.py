"""Private, bounded service mutations for explicitly confirmed F30 cleanup.

Credentials are leased only in memory by an authenticated archive collection.
The durable journal stores opaque effect IDs and readback proof, never secrets
or service/host paths.  Every mutation is preceded and followed by an exact
read; an HTTP success status alone is not accepted as deletion proof.
"""

from dataclasses import dataclass
import hashlib
import json
import socket
import threading
import time
from urllib.parse import urlencode

from ..plugins.media_archive_core_models import PrivateMediaArchiveWorkerCollection
from ..services.transport import (
    ProbeTransportError, _Deadline, _remaining, _request_bytes,
)
from ..plugins.jellyfin_startup import _ConnectionLost, _StartupReader, _response
from .journal import action_command_digest
from .models import ArchiveActionAuthority


_MAX_RESPONSE = 2 * 1024 * 1024
_SERVICES = frozenset({"jellyfin", "sonarr", "radarr", "qbittorrent"})


class ArchiveCleanupExecutorError(RuntimeError):
    _CODES = frozenset({
        "cleanup_unavailable", "authority_changed", "evidence_changed",
        "effect_unknown", "deadline_exceeded",
    })

    def __init__(self, code="cleanup_unavailable"):
        self.code = code if code in self._CODES else "cleanup_unavailable"
        super().__init__(self.code)


@dataclass(frozen=True, repr=False)
class ResolvedDuplicateCleanupItem:
    itemId: str
    mediaKey: str
    service: str
    serviceFileId: int
    jellyfinPath: str
    arrPath: str
    sourceSizeBytes: int

    def __repr__(self):
        return "ResolvedDuplicateCleanupItem(<private>)"


@dataclass(frozen=True, repr=False)
class ResolvedDuplicateCleanup:
    commandDigest: str
    planDigest: str
    keep: ResolvedDuplicateCleanupItem
    delete: tuple[ResolvedDuplicateCleanupItem, ...]

    def __repr__(self):
        return "ResolvedDuplicateCleanup(<private>)"


@dataclass(frozen=True, repr=False)
class ResolvedRetentionCleanup:
    commandDigest: str
    planDigest: str
    torrentId: str
    importedMediaKey: str
    contentPath: str
    contentBytes: int
    libraryItem: ResolvedDuplicateCleanupItem

    def __repr__(self):
        return "ResolvedRetentionCleanup(<private>)"


@dataclass(frozen=True, repr=False)
class ArchiveCleanupEffect:
    effectId: str
    service: str
    kind: str
    itemId: str | None = None
    fileId: int | None = None
    torrentId: str | None = None

    def __repr__(self):
        return "ArchiveCleanupEffect(<private>)"


def cleanup_effects(plan):
    if type(plan) is ResolvedDuplicateCleanup:
        result = []
        for item in plan.delete:
            result.extend((
                ArchiveCleanupEffect(
                    hashlib.sha256(("arr\0" + item.service + "\0" +
                                    str(item.serviceFileId)).encode()).hexdigest(),
                    item.service, "arr_file", fileId=item.serviceFileId),
                ArchiveCleanupEffect(
                    hashlib.sha256(("jellyfin\0" + item.itemId).encode()).hexdigest(),
                    "jellyfin", "jellyfin_item", itemId=item.itemId),
            ))
        return tuple(result)
    if type(plan) is ResolvedRetentionCleanup:
        return (ArchiveCleanupEffect(
            hashlib.sha256(("qbittorrent\0" + plan.torrentId).encode()).hexdigest(),
            "qbittorrent", "torrent", torrentId=plan.torrentId),)
    raise ArchiveCleanupExecutorError("evidence_changed")


class _MutationTransport:
    """Numeric-loopback HTTP with bounded bodies, no redirects or retries."""

    def request(self, service, port, method, path, api_key, *, deadline, body=b"",
                text=False):
        if (service not in _SERVICES or type(port) is not int
                or not 1024 <= port <= 65535 or method not in {"GET", "POST", "DELETE"}
                or type(path) is not str or not path.startswith("/")
                or "\r" in path or "\n" in path or type(body) is not bytes):
            raise ArchiveCleanupExecutorError()
        headers = {"Accept": "application/json"}
        if service == "jellyfin":
            headers["Authorization"] = (
                'MediaBrowser Client="Larenor Core", Device="Larenor Core", '
                'DeviceId="archive-cleanup", Version="0.1.0", Token="' + api_key + '"')
        elif service in {"sonarr", "radarr"}:
            headers["X-Api-Key"] = api_key
        else:
            headers["Authorization"] = "Bearer " + api_key
        if body:
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        connection = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        scope = _Deadline(deadline)
        try:
            scope.attach(connection)
            connection.settimeout(_remaining(deadline))
            connection.connect(("127.0.0.1", port))
            connection.settimeout(_remaining(deadline))
            connection.sendall(_request_bytes(
                method, path, service, headers, body or None,
                allow_delete=method == "DELETE"))
            success_type = ("text/plain" if text else
                "text/plain" if service == "qbittorrent" and method == "POST"
                else "application/json")
            status, raw, _closes = _response(
                _StartupReader(connection, deadline), _MAX_RESPONSE,
                content_type=success_type, error_content_type="text/plain")
            if status in {401, 403}:
                raise ArchiveCleanupExecutorError("authority_changed")
            return status, raw
        except ArchiveCleanupExecutorError:
            raise
        except (socket.timeout, TimeoutError):
            raise ArchiveCleanupExecutorError("deadline_exceeded") from None
        except (ProbeTransportError, _ConnectionLost, OSError, RuntimeError,
                ValueError, UnicodeError):
            raise ArchiveCleanupExecutorError() from None
        finally:
            scope.finish()


class PrivateArchiveDeleteExecutor:
    """Short-lived credential lease plus exact upstream mutation/readback."""

    LEASE_SECONDS = 60

    def __init__(self, transport=None, *, clock=None):
        self._transport = transport or _MutationTransport()
        self._clock = clock or time.monotonic
        self._lock = threading.Lock()
        self._lease = None
        if not callable(getattr(self._transport, "request", None)) or not callable(self._clock):
            raise ArchiveCleanupExecutorError()

    def refresh_authenticated(self, private, ports, *, deadline, gate):
        if (type(private) is not PrivateMediaArchiveWorkerCollection
                or type(ports) is not dict or set(ports) != _SERVICES
                or any(type(value) is not int or not 1024 <= value <= 65535
                       for value in ports.values()) or not callable(gate)
                or time.monotonic() >= deadline or gate() is not True):
            raise ArchiveCleanupExecutorError("authority_changed")
        sources = {item.serviceId: item for item in private.sources}
        authority = ArchiveActionAuthority(
            installationId=private.authority.installationId,
            installationRevision=private.authority.installationRevision,
            snapshotRevision=private.authority.snapshotRevision,
            sourceRevisions={item.serviceId: item.serviceRevision
                             for item in private.authority.sources},
        ).model_dump(mode="json")
        with self._lock:
            self._lease = (
                authority, dict(ports),
                {name: sources[name].apiKey for name in _SERVICES},
                {name: (sources[name].serverId, sources[name].containerId)
                 for name in _SERVICES},
                self._clock() + self.LEASE_SECONDS,
            )
        return True

    def _grant(self, authority):
        with self._lock:
            lease = self._lease
            if (lease is None or self._clock() >= lease[4]
                    or lease[0] != authority.model_dump(mode="json")):
                raise ArchiveCleanupExecutorError("authority_changed")
            return lease[1], lease[2], lease[3]

    @staticmethod
    def _json(raw):
        try:
            return json.loads(raw.decode("utf-8"))
        except (UnicodeError, ValueError, TypeError):
            raise ArchiveCleanupExecutorError("effect_unknown") from None

    def _request(self, authority, service, method, path, deadline, body=b"",
                 text=False):
        ports, credentials, _identities = self._grant(authority)
        if time.monotonic() >= deadline:
            raise ArchiveCleanupExecutorError("deadline_exceeded")
        return self._transport.request(
            service, ports[service], method, path, credentials[service],
            deadline=deadline, body=body, text=text)

    def _identity(self, authority, service, deadline):
        _ports, _credentials, identities = self._grant(authority)
        if service == "jellyfin":
            status, raw = self._request(
                authority, service, "GET", "/System/Info", deadline)
            value = self._json(raw) if status == 200 else None
            if (type(value) is not dict
                    or value.get("Id") != identities[service][0]
                    or value.get("ProductName") != "Jellyfin Server"
                    or value.get("Version") != "10.11.11"):
                raise ArchiveCleanupExecutorError("authority_changed")
        elif service in {"sonarr", "radarr"}:
            status, raw = self._request(
                authority, service, "GET", "/api/v3/system/status", deadline)
            value = self._json(raw) if status == 200 else None
            expected = (("Sonarr", "4.0.19.2979") if service == "sonarr"
                        else ("Radarr", "6.3.0.10514"))
            if (type(value) is not dict
                    or (value.get("appName"), value.get("version")) != expected):
                raise ArchiveCleanupExecutorError("authority_changed")
        else:
            status, raw = self._request(
                authority, service, "GET", "/api/v2/app/version", deadline,
                text=True)
            if status != 200 or raw != b"v5.2.3":
                raise ArchiveCleanupExecutorError("authority_changed")

    def _jellyfin(self, authority, item, deadline):
        status, raw = self._request(
            authority, "jellyfin", "GET",
            "/Items/" + item.itemId + "?Fields=Path,MediaSources", deadline)
        if status == 404:
            return False
        if status != 200:
            raise ArchiveCleanupExecutorError()
        value = self._json(raw)
        sources = value.get("MediaSources") if type(value) is dict else None
        if (value.get("Id") != item.itemId or value.get("Path") != item.jellyfinPath
                or type(sources) is not list or len(sources) != 1
                or sources[0].get("Size") != item.sourceSizeBytes):
            raise ArchiveCleanupExecutorError("evidence_changed")
        return True

    def _arr(self, authority, item, deadline):
        endpoint = "episodefile" if item.service == "sonarr" else "moviefile"
        status, raw = self._request(
            authority, item.service, "GET",
            f"/api/v3/{endpoint}/{item.serviceFileId}", deadline)
        if status == 404:
            return False
        if status != 200:
            raise ArchiveCleanupExecutorError()
        value = self._json(raw)
        if (type(value) is not dict or value.get("id") != item.serviceFileId
                or value.get("path") != item.arrPath
                or value.get("size") not in {None, item.sourceSizeBytes}):
            raise ArchiveCleanupExecutorError("evidence_changed")
        return True

    def _torrent(self, authority, plan, deadline):
        status, raw = self._request(
            authority, "qbittorrent", "GET",
            "/api/v2/torrents/info?" + urlencode({"hashes": plan.torrentId}),
            deadline)
        if status != 200:
            raise ArchiveCleanupExecutorError()
        values = self._json(raw)
        if type(values) is not list or len(values) > 1:
            raise ArchiveCleanupExecutorError("effect_unknown")
        if not values:
            return False
        value = values[0]
        if (type(value) is not dict or value.get("hash", "").lower() != plan.torrentId
                or value.get("content_path") != plan.contentPath
                or value.get("total_size") != plan.contentBytes
                or value.get("state") not in {"stoppedUP", "completed"}):
            raise ArchiveCleanupExecutorError("evidence_changed")
        return True

    def preflight(self, command, plan, *, deadline):
        if (plan.commandDigest != action_command_digest(command)
                or command.operation == "cleanup_duplicate"
                and type(plan) is not ResolvedDuplicateCleanup
                or command.operation == "cleanup_retention"
                and type(plan) is not ResolvedRetentionCleanup):
            raise ArchiveCleanupExecutorError("evidence_changed")
        if type(plan) is ResolvedDuplicateCleanup:
            if not self._jellyfin(command.authority, plan.keep, deadline):
                raise ArchiveCleanupExecutorError("evidence_changed")
            for item in plan.delete:
                if (not self._jellyfin(command.authority, item, deadline)
                        or not self._arr(command.authority, item, deadline)):
                    raise ArchiveCleanupExecutorError("evidence_changed")
        else:
            if (not self._torrent(command.authority, plan, deadline)
                    or not self._jellyfin(command.authority, plan.libraryItem, deadline)
                    or not self._arr(command.authority, plan.libraryItem, deadline)):
                raise ArchiveCleanupExecutorError("evidence_changed")
        return plan.planDigest

    def authorize(self, command, plan, *, deadline):
        self._grant(command.authority)
        if type(plan) is ResolvedDuplicateCleanup:
            return (self._jellyfin(command.authority, plan.keep, deadline)
                    and self._arr(command.authority, plan.keep, deadline))
        if type(plan) is ResolvedRetentionCleanup:
            return (self._jellyfin(command.authority, plan.libraryItem, deadline)
                    and self._arr(command.authority, plan.libraryItem, deadline))
        raise ArchiveCleanupExecutorError("evidence_changed")

    def observe(self, command, plan, effect, *, deadline):
        if effect not in cleanup_effects(plan):
            raise ArchiveCleanupExecutorError("evidence_changed")
        if effect.kind == "arr_file":
            item = next(item for item in plan.delete
                        if item.service == effect.service and item.serviceFileId == effect.fileId)
            return self._arr(command.authority, item, deadline)
        if effect.kind == "jellyfin_item":
            item = next(item for item in plan.delete if item.itemId == effect.itemId)
            return self._jellyfin(command.authority, item, deadline)
        return self._torrent(command.authority, plan, deadline)

    def mutate(self, command, plan, effect, *, deadline):
        if effect not in cleanup_effects(plan):
            raise ArchiveCleanupExecutorError("evidence_changed")
        self._identity(command.authority, effect.service, deadline)
        if self.authorize(command, plan, deadline=deadline) is not True:
            raise ArchiveCleanupExecutorError("authority_changed")
        # Re-read the exact mutation target after identity and keep-set checks.
        # A target that changed or vanished in that window must not be treated
        # as this worker's deletion.
        if not self.observe(command, plan, effect, deadline=deadline):
            raise ArchiveCleanupExecutorError("evidence_changed")
        if effect.kind == "arr_file":
            item = next(item for item in plan.delete
                        if item.service == effect.service and item.serviceFileId == effect.fileId)
            endpoint = "episodefile" if item.service == "sonarr" else "moviefile"
            status, _raw = self._request(
                command.authority, item.service, "DELETE",
                f"/api/v3/{endpoint}/{item.serviceFileId}", deadline)
        elif effect.kind == "jellyfin_item":
            status, _raw = self._request(
                command.authority, "jellyfin", "DELETE",
                "/Items/" + effect.itemId, deadline)
        else:
            status, _raw = self._request(
                command.authority, "qbittorrent", "POST",
                "/api/v2/torrents/delete", deadline,
                urlencode({"hashes": effect.torrentId,
                           "deleteFiles": "true"}).encode("ascii"))
        if status not in {200, 202, 204}:
            raise ArchiveCleanupExecutorError("effect_unknown")
        if self.observe(command, plan, effect, deadline=deadline):
            raise ArchiveCleanupExecutorError("effect_unknown")
        return True
