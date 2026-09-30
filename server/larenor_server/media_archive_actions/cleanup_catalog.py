"""Sealed private provenance for duplicate and torrent-retention cleanup."""

from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
import hashlib
import hmac
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import threading
import time

from ..plugins.worker import _safe_path
from .cleanup_executor import (
    ResolvedDuplicateCleanup, ResolvedDuplicateCleanupItem,
    ResolvedRetentionCleanup,
)
from .journal import action_command_digest
from .models import ArchiveActionAuthority, PrivateArchiveActionCommand
from .source_resolver import PrivateArchiveResolverCatalog


_ITEM = re.compile(r"[0-9a-f]{32}\Z")
_TORRENT = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")
_MEDIA_KEY = re.compile(r"(?:movie:tmdb|episode:tvdb):[1-9][0-9]{0,18}(?::[0-9]{1,8}){0,2}\Z")
_MAX_ROWS = 4096
_MAX_BYTES = 8 * 1024 * 1024


class ArchiveCleanupCatalogError(RuntimeError):
    def __init__(self, code="archive_cleanup_unavailable"):
        self.code = code
        super().__init__(code)


def _require(value, code="archive_cleanup_unavailable"):
    if not value:
        raise ArchiveCleanupCatalogError(code)


def _canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=True, allow_nan=False).encode("ascii")


@dataclass(frozen=True, repr=False)
class AuthenticatedArchiveCleanupItem:
    itemId: str
    mediaKey: str
    sourcePath: str
    sourceSizeBytes: int
    service: str
    serviceFileId: int
    servicePath: str

    def __repr__(self):
        return "AuthenticatedArchiveCleanupItem(<private>)"


@dataclass(frozen=True, repr=False)
class AuthenticatedArchiveTorrent:
    torrentId: str
    importedMediaKey: str | None
    contentPath: str
    contentBytes: int
    state: str
    importedConfirmed: bool
    retentionPolicySatisfied: bool

    def __repr__(self):
        return "AuthenticatedArchiveTorrent(<private>)"


@dataclass(frozen=True, repr=False)
class _Mount:
    mountId: str
    serviceRoot: str
    hostRoot: Path
    device: int
    inode: int


class PrivateArchiveCleanupCatalog:
    """Atomic HMAC-sealed catalogue; paths stay private to the worker."""

    def __init__(self, catalog, *, authority_reader=None):
        if type(catalog) is not PrivateArchiveResolverCatalog:
            raise ArchiveCleanupCatalogError()
        self._directory = Path(catalog.storeRoot).absolute()
        self._path = self._directory / "media-archive-cleanup.json"
        self._lock_path = self._directory / "media-archive-cleanup.lock"
        self._mutex = threading.Lock()
        self._authority_reader = authority_reader
        self._key = hmac.new(
            catalog.authenticationKey, b"larenor-media-archive-cleanup-v1",
            hashlib.sha256).digest()
        self._mounts = tuple(self._mount(value) for value in catalog.approvedMounts)
        _require(1 <= len(self._mounts) <= 16)
        _safe_path(self._directory, uid=os.getuid(), kind=stat.S_ISDIR, private=True)
        if not os.path.lexists(self._lock_path):
            descriptor = os.open(self._lock_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                                 | os.O_NOFOLLOW, 0o600)
            os.close(descriptor)
        _safe_path(self._lock_path, uid=os.getuid(), kind=stat.S_ISREG, private=True)
        self._lock_fd = os.open(self._lock_path, os.O_RDWR | os.O_NOFOLLOW)

    def close(self):
        if self._lock_fd is not None:
            os.close(self._lock_fd)
            self._lock_fd = None

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.close()

    @staticmethod
    def _mount(value):
        root = Path(value.hostRoot).absolute()
        _safe_path(root, uid=os.getuid(), kind=stat.S_ISDIR, private=False)
        info = root.stat()
        service = PurePosixPath(value.serviceRoot)
        _require(service.is_absolute() and ".." not in service.parts)
        return _Mount(value.mountId, str(service), root, info.st_dev, info.st_ino)

    @contextmanager
    def _locked(self):
        _require(self._lock_fd is not None and self._mutex.acquire(blocking=False),
                 "archive_cleanup_busy")
        acquired = False
        try:
            fcntl.flock(self._lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            acquired = True
            yield
        except OSError:
            raise ArchiveCleanupCatalogError("archive_cleanup_busy") from None
        finally:
            if acquired:
                fcntl.flock(self._lock_fd, fcntl.LOCK_UN)
            self._mutex.release()

    def _translate(self, source):
        path = PurePosixPath(source)
        matches = []
        for mount in self._mounts:
            root = PurePosixPath(mount.serviceRoot)
            try:
                relative = path.relative_to(root)
            except ValueError:
                continue
            if relative.parts and ".." not in relative.parts:
                matches.append((mount, str(relative)))
        _require(len(matches) == 1, "source_path_rejected")
        return matches[0]

    @staticmethod
    def _mount_service_path(mount, relative):
        return mount.serviceRoot.rstrip("/") + "/" + relative

    @staticmethod
    def _stat_relative(mount, relative, *, required=True):
        parts = PurePosixPath(relative).parts
        _require(parts and ".." not in parts and "." not in parts,
                 "source_path_rejected")
        descriptor = os.open(
            mount.hostRoot, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            root = os.fstat(descriptor)
            _require((root.st_dev, root.st_ino) == (mount.device, mount.inode),
                     "source_path_rejected")
            for part in parts[:-1]:
                child = os.open(
                    part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                    dir_fd=descriptor)
                os.close(descriptor)
                descriptor = child
            try:
                return os.stat(parts[-1], dir_fd=descriptor,
                               follow_symlinks=False)
            except FileNotFoundError:
                _require(not required, "evidence_changed")
                return None
        except ArchiveCleanupCatalogError:
            raise
        except OSError:
            raise ArchiveCleanupCatalogError("source_path_rejected") from None
        finally:
            os.close(descriptor)

    @staticmethod
    def _authority(authority):
        return ArchiveActionAuthority(
            installationId=authority.installationId,
            installationRevision=authority.installationRevision,
            snapshotRevision=authority.snapshotRevision,
            sourceRevisions={item.serviceId: item.serviceRevision
                             for item in authority.sources},
        )

    def _tag(self, value):
        return hmac.new(self._key, _canonical(value), hashlib.sha256).hexdigest()

    def _read(self):
        _safe_path(self._path, uid=os.getuid(), kind=stat.S_ISREG, private=True)
        descriptor = os.open(self._path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            info = os.fstat(descriptor)
            _require(info.st_nlink == 1 and 1 <= info.st_size <= _MAX_BYTES)
            raw = os.read(descriptor, _MAX_BYTES + 1)
            _require(len(raw) == info.st_size)
            value = json.loads(raw.decode("ascii"))
            _require(type(value) is dict and set(value) == {"payload", "tag"}
                     and hmac.compare_digest(value["tag"], self._tag(value["payload"])))
            payload = value["payload"]
            _require(type(payload) is dict and set(payload) == {
                "version", "generation", "authority", "items", "torrents"}
                     and payload["version"] == 1
                     and type(payload["generation"]) is int
                     and 1 <= payload["generation"] <= 2**63 - 1
                     and type(payload["items"]) is list
                     and type(payload["torrents"]) is list
                     and len(payload["items"]) <= _MAX_ROWS
                     and len(payload["torrents"]) <= _MAX_ROWS)
            ArchiveActionAuthority.model_validate(payload["authority"])
            return payload
        except ArchiveCleanupCatalogError:
            raise
        except Exception:
            raise ArchiveCleanupCatalogError() from None
        finally:
            os.close(descriptor)

    def replace_collection_authenticated(
            self, authority, items, torrents, *, deadline, gate):
        _require(time.monotonic() < deadline and callable(gate) and gate() is True)
        selected = self._authority(authority)
        item_rows = []
        seen_items = set()
        for raw in items:
            _require(type(raw) is AuthenticatedArchiveCleanupItem
                     and _ITEM.fullmatch(raw.itemId) is not None
                     and _MEDIA_KEY.fullmatch(raw.mediaKey) is not None
                     and raw.service in {"sonarr", "radarr"}
                     and type(raw.serviceFileId) is int and raw.serviceFileId > 0
                     and type(raw.sourceSizeBytes) is int and raw.sourceSizeBytes > 0
                     and type(raw.servicePath) is str
                     and raw.servicePath.startswith("/data/")
                     and "//" not in raw.servicePath
                     and ".." not in PurePosixPath(raw.servicePath).parts
                     and raw.itemId not in seen_items)
            seen_items.add(raw.itemId)
            mount, relative = self._translate(raw.sourcePath)
            info = self._stat_relative(mount, relative)
            _require(stat.S_ISREG(info.st_mode) and info.st_size == raw.sourceSizeBytes,
                     "evidence_changed")
            item_rows.append({
                "itemId": raw.itemId, "mediaKey": raw.mediaKey,
                "mountId": mount.mountId, "relativePath": relative,
                "sourceSizeBytes": raw.sourceSizeBytes, "service": raw.service,
                "serviceFileId": raw.serviceFileId,
                "servicePath": raw.servicePath,
            })
        torrent_rows = []
        seen_torrents = set()
        for raw in torrents:
            _require(type(raw) is AuthenticatedArchiveTorrent
                     and _TORRENT.fullmatch(raw.torrentId) is not None
                     and (raw.importedMediaKey is None
                          or _MEDIA_KEY.fullmatch(raw.importedMediaKey) is not None)
                     and raw.state in {"downloading", "seeding", "complete", "paused", "error"}
                     and type(raw.contentBytes) is int and raw.contentBytes >= 0
                     and type(raw.contentPath) is str
                     and (raw.contentPath.startswith("/data/downloads/movies/")
                          or raw.contentPath.startswith("/data/downloads/tv/"))
                     and "//" not in raw.contentPath
                     and ".." not in PurePosixPath(raw.contentPath).parts
                     and type(raw.importedConfirmed) is bool
                     and type(raw.retentionPolicySatisfied) is bool
                     and raw.torrentId not in seen_torrents)
            seen_torrents.add(raw.torrentId)
            torrent_rows.append({
                "torrentId": raw.torrentId,
                "importedMediaKey": raw.importedMediaKey,
                "contentPath": raw.contentPath,
                "contentBytes": raw.contentBytes, "state": raw.state,
                "importedConfirmed": raw.importedConfirmed,
                "retentionPolicySatisfied": raw.retentionPolicySatisfied,
            })
        item_rows.sort(key=lambda value: value["itemId"])
        torrent_rows.sort(key=lambda value: value["torrentId"])
        _require(gate() is True and time.monotonic() < deadline)
        with self._locked():
            generation = 1
            if os.path.lexists(self._path):
                generation = self._read()["generation"] + 1
            payload = {
                "version": 1, "generation": generation,
                "authority": selected.model_dump(mode="json"),
                "items": item_rows, "torrents": torrent_rows,
            }
            envelope = _canonical({"payload": payload, "tag": self._tag(payload)})
            temporary = self._directory / (".media-archive-cleanup-" + os.urandom(8).hex())
            descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                                 | os.O_NOFOLLOW, 0o600)
            try:
                os.write(descriptor, envelope)
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            os.replace(temporary, self._path)
            directory = os.open(self._directory, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        return generation

    def _current(self, command, deadline):
        _require(self._authority_reader is not None and time.monotonic() < deadline,
                 "authority_changed")
        current = self._authority_reader.current_archive_action_authority(
            command.authority.installationId, deadline=deadline)
        _require(current == command.authority, "authority_changed")

    def resolve(self, command, *, deadline, require_delete_present=True):
        _require(type(command) is PrivateArchiveActionCommand
                 and command.operation in {"cleanup_duplicate", "cleanup_retention"})
        self._current(command, deadline)
        with self._locked():
            payload = self._read()
        _require(ArchiveActionAuthority.model_validate(payload["authority"])
                 == command.authority, "authority_changed")
        items = {row["itemId"]: row for row in payload["items"]}
        torrents = {row["torrentId"]: row for row in payload["torrents"]}

        def resolved(value, *, required=True):
            matches = [mount for mount in self._mounts
                       if mount.mountId == value["mountId"]]
            _require(len(matches) == 1, "evidence_changed")
            mount = matches[0]
            info = self._stat_relative(
                mount, value["relativePath"], required=required)
            if info is not None:
                _require(stat.S_ISREG(info.st_mode)
                         and info.st_size == value["sourceSizeBytes"], "evidence_changed")
            return ResolvedDuplicateCleanupItem(
                value["itemId"], value["mediaKey"], value["service"],
                value["serviceFileId"],
                self._mount_service_path(mount, value["relativePath"]),
                value["servicePath"],
                value["sourceSizeBytes"])

        if command.operation == "cleanup_duplicate":
            target = command.target
            _require(target.targetType == "duplicate"
                     and target.keepItemId in items
                     and all(value in items for value in target.deleteItemIds))
            keep = resolved(items[target.keepItemId])
            deleted = tuple(resolved(
                items[value], required=require_delete_present)
                for value in target.deleteItemIds)
            _require(len({(value.service, value.serviceFileId) for value in (keep, *deleted)})
                     == 1 + len(deleted)
                     and len({(items[value]["mountId"],
                               items[value]["relativePath"])
                              for value in (target.keepItemId,
                                            *target.deleteItemIds)})
                     == 1 + len(deleted)
                     and not any(row["importedMediaKey"] in {value.mediaKey for value in deleted}
                                 and row["state"] in {"downloading", "seeding", "paused"}
                                 for row in payload["torrents"]), "evidence_changed")
            observed = keep.sourceSizeBytes + sum(value.sourceSizeBytes for value in deleted)
            _require((observed, keep.sourceSizeBytes, sum(value.sourceSizeBytes for value in deleted))
                     == (command.candidate.comparison.observedBytes,
                         command.candidate.comparison.estimatedRetainedBytes,
                         command.candidate.potentialBytes), "evidence_changed")
            plan_value = {
                "command": action_command_digest(command),
                "keep": keep.itemId,
                "delete": [value.itemId for value in deleted],
                "generation": payload["generation"],
            }
            return ResolvedDuplicateCleanup(
                action_command_digest(command), hashlib.sha256(_canonical(plan_value)).hexdigest(),
                keep, deleted)
        target = command.target
        _require(target.targetType == "retention" and target.torrentId in torrents)
        torrent = torrents[target.torrentId]
        library = [value for value in items.values()
                   if value["mediaKey"] == target.importedMediaKey]
        _require(torrent["importedMediaKey"] == target.importedMediaKey
                 and torrent["state"] == "complete"
                 and torrent["importedConfirmed"] is True
                 and torrent["retentionPolicySatisfied"] is True
                 and torrent["contentBytes"] == command.candidate.potentialBytes
                 and len(library) >= 1, "evidence_changed")
        library.sort(key=lambda value: value["itemId"])
        library_item = resolved(library[0])
        plan_value = {
            "command": action_command_digest(command),
            "torrent": torrent["torrentId"], "library": library_item.itemId,
            "generation": payload["generation"],
        }
        return ResolvedRetentionCleanup(
            action_command_digest(command), hashlib.sha256(_canonical(plan_value)).hexdigest(),
            torrent["torrentId"], torrent["importedMediaKey"],
            torrent["contentPath"], torrent["contentBytes"], library_item)

    def authorize(self, command, plan, *, deadline):
        try:
            current = self.resolve(
                command, deadline=deadline, require_delete_present=False)
            return (current.planDigest == plan.planDigest
                    and current.commandDigest == plan.commandDigest)
        except Exception:
            return False


def build_private_archive_cleanup_catalog(catalog_path, *, authority_reader=None):
    return PrivateArchiveCleanupCatalog(
        PrivateArchiveResolverCatalog.load(catalog_path),
        authority_reader=authority_reader)
