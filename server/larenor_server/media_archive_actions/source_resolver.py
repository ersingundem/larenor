"""Private, sealed source resolution for F30 archive actions.

The public action command carries Jellyfin item identity and source evidence,
never a host path or an Unmanic library number.  This store accepts paths only
from an authenticated worker collection, translates the fixed Jellyfin mount
to an approved host mount, and seals that mapping for restart recovery.

Unmanic library identity is read from the pinned service on every publish and
resolution.  A configured number is deliberately not accepted: the exact
library ID, work root and complete library configuration digest must still
match the durable snapshot.
"""

from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
import hashlib
import hmac
import json
import os
from pathlib import Path, PurePosixPath
import re
import sqlite3
import stat
import threading
import time
from typing import Protocol, runtime_checkable

from ..plugins.media_archive_core_models import MediaArchiveCollectionAuthority
from ..plugins.worker import _safe_path
from .engine import ResolvedArchiveActionSource
from .journal import action_command_digest
from .models import ArchiveActionAuthority, PrivateArchiveActionCommand
from .unmanic import UnmanicRequest, UnmanicResponse, _decode


_ID = re.compile(r"[0-9a-f]{32}\Z")
_DIGEST = re.compile(r"[0-9a-f]{64}\Z")
_MOUNT_ID = re.compile(r"[a-z][a-z0-9_-]{0,31}\Z")
_MEDIA_KEY = re.compile(r"(?:movie:tmdb|episode:tvdb):[1-9][0-9]{0,18}(?::[1-9][0-9]{0,8}){0,2}\Z")
_CODECS = frozenset({"h264", "mpeg2", "vc1"})
_SUFFIXES = frozenset({".mkv", ".mp4", ".m4v", ".avi", ".mov", ".mpeg", ".mpg", ".ts", ".webm"})
_MAX_SOURCES = 4096
_MAX_DATABASE_BYTES = 8 * 1024 * 1024
_SCHEMA = (
    """CREATE TABLE metadata(
        singleton INTEGER PRIMARY KEY CHECK(singleton=1),
        version INTEGER NOT NULL,
        generation INTEGER NOT NULL,
        authority BLOB NOT NULL,
        library_id INTEGER NOT NULL,
        unmanic_config_digest TEXT NOT NULL,
        policy_digest TEXT NOT NULL,
        source_count INTEGER NOT NULL,
        rows_digest TEXT NOT NULL,
        authentication_tag TEXT NOT NULL)""",
    """CREATE TABLE sources(
        source_item_id TEXT PRIMARY KEY,
        media_key TEXT NOT NULL,
        mount_id TEXT NOT NULL,
        relative_path TEXT NOT NULL,
        source_size_bytes INTEGER NOT NULL,
        source_codec TEXT NOT NULL,
        source_bitrate INTEGER NOT NULL,
        duration_seconds INTEGER NOT NULL,
        authentication_tag TEXT NOT NULL)""",
)


class ArchiveSourceResolverError(RuntimeError):
    """Secret-free, stable failure at the private action boundary."""

    _CODES = frozenset({
        "archive_source_unavailable", "archive_source_busy",
        "authority_changed", "evidence_changed", "source_path_rejected",
        "unmanic_authority_changed",
    })

    def __init__(self, code="archive_source_unavailable"):
        self.code = code if code in self._CODES else "archive_source_unavailable"
        super().__init__(self.code)

    def __repr__(self):
        return f"ArchiveSourceResolverError({self.code!r})"


def _require(condition, code="archive_source_unavailable"):
    if not condition:
        raise ArchiveSourceResolverError(code)


def _canonical(value):
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True,
        allow_nan=False,
    ).encode("ascii")


def _json(value):
    return json.loads(value)


def _deadline(deadline):
    _require(type(deadline) in (int, float) and type(deadline) is not bool
             and time.monotonic() < deadline, "authority_changed")


@dataclass(frozen=True, repr=False)
class ApprovedArchiveMount:
    """Fixed Jellyfin service path to one approved host library mount."""

    mountId: str
    serviceRoot: str
    hostRoot: str

    def __repr__(self):
        return "ApprovedArchiveMount(<private>)"


@dataclass(frozen=True, repr=False)
class AuthenticatedArchiveSourceRecord:
    """One private Jellyfin/Arr joined source from the authenticated read."""

    sourceItemId: str
    mediaKey: str
    sourcePath: str
    sourceSizeBytes: int
    sourceCodec: str
    sourceBitrate: int
    durationSeconds: int

    def __repr__(self):
        return "AuthenticatedArchiveSourceRecord(<private>)"


@dataclass(frozen=True, repr=False)
class VerifiedUnmanicLibrary:
    """Exact result of GET libraries plus POST library/read."""

    libraryId: int
    workRoot: str
    configDigest: str

    def __repr__(self):
        return "VerifiedUnmanicLibrary(<private>)"


@dataclass(frozen=True, repr=False)
class PrivateArchiveResolverCatalog:
    """Admin-provisioned worker paths; never accepted over action IPC."""

    storeRoot: str
    workRoot: str
    retainedRoot: str
    authenticationKey: bytes
    approvedMounts: tuple[ApprovedArchiveMount, ...]

    def __repr__(self):
        return "PrivateArchiveResolverCatalog(<private>)"

    @classmethod
    def load(cls, path):
        """Read one exact 0600 catalog and its exact 0600 raw key file."""
        try:
            raw = _read_private(path, maximum=16 * 1024)
            value = json.loads(
                raw.decode("utf-8"), object_pairs_hook=_unique_pairs,
                parse_constant=lambda _item: (_ for _ in ()).throw(ValueError()))
            _require(type(value) is dict and set(value) == {
                "schemaVersion", "storeRoot", "workRoot", "retainedRoot",
                "authenticationKeyFile", "approvedMounts",
            } and value["schemaVersion"] == 1
                     and type(value["approvedMounts"]) is list
                     and 1 <= len(value["approvedMounts"]) <= 16)
            path_fields = (
                value["storeRoot"], value["workRoot"], value["retainedRoot"],
                value["authenticationKeyFile"],
            )
            _require(all(type(item) is str and Path(item).is_absolute()
                         and ".." not in Path(item).parts
                         and not any(ord(char) < 32 or ord(char) == 127
                                     for char in item)
                         for item in path_fields))
            mounts = []
            for item in value["approvedMounts"]:
                _require(type(item) is dict and set(item) == {
                    "mountId", "jellyfinRoot", "hostRoot"})
                mounts.append(ApprovedArchiveMount(
                    mountId=item["mountId"], serviceRoot=item["jellyfinRoot"],
                    hostRoot=item["hostRoot"]))
            key = _read_private(
                value["authenticationKeyFile"], maximum=32)
            _require(len(key) == 32)
            return cls(
                storeRoot=value["storeRoot"], workRoot=value["workRoot"],
                retainedRoot=value["retainedRoot"], authenticationKey=key,
                approvedMounts=tuple(mounts))
        except ArchiveSourceResolverError:
            raise
        except Exception:
            raise ArchiveSourceResolverError() from None


def _unique_pairs(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError
        value[key] = item
    return value


def _read_private(value, *, maximum):
    path = Path(value).absolute()
    _safe_path(path, uid=os.getuid(), kind=stat.S_ISREG, private=True)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        before = os.fstat(descriptor)
        _require(before.st_nlink == 1 and 1 <= before.st_size <= maximum)
        raw = os.read(descriptor, maximum + 1)
        after = os.fstat(descriptor)
        entry = os.stat(path, follow_symlinks=False)
        identity = lambda item: (
            item.st_dev, item.st_ino, item.st_size,
            item.st_mtime_ns, item.st_ctime_ns)
        _require(len(raw) == before.st_size <= maximum
                 and identity(before) == identity(after) == identity(entry))
        return raw
    except ArchiveSourceResolverError:
        raise
    except OSError:
        raise ArchiveSourceResolverError() from None
    finally:
        os.close(descriptor)


@runtime_checkable
class ArchiveActionAuthorityReader(Protocol):
    def current_archive_action_authority(
        self, installation_id: str, *, deadline: float
    ) -> ArchiveActionAuthority:
        """Read Core's current exact four-source authority."""


@runtime_checkable
class UnmanicLibraryReader(Protocol):
    def read_verified_library(self, *, deadline: float) -> VerifiedUnmanicLibrary:
        """Read the actual Unmanic library ID and complete config."""


class CoreArchiveActionAuthorityReader:
    """Narrow adapter over Core's credential-backed snapshot provider."""

    def __init__(self, provider):
        if not callable(getattr(provider, "current", None)):
            raise ArchiveSourceResolverError()
        self._provider = provider

    def current_archive_action_authority(self, installation_id, *, deadline):
        _deadline(deadline)
        try:
            current = self._provider.current(installation_id)
            if type(current) is not MediaArchiveCollectionAuthority:
                raise ValueError
            result = ArchiveActionAuthority(
                installationId=current.installationId,
                installationRevision=current.installationRevision,
                snapshotRevision=current.snapshotRevision,
                sourceRevisions={item.serviceId: item.serviceRevision
                                 for item in current.sources},
            )
            _deadline(deadline)
            return result
        except ArchiveSourceResolverError:
            raise
        except Exception:
            raise ArchiveSourceResolverError("authority_changed") from None


class UnmanicLibraryReadback:
    """Bounded read-only verification against Unmanic 0.4.1 API v2."""

    _PREFIX = "/unmanic/api/v2"

    def __init__(self, exchange, work_root):
        self._exchange = exchange
        self._work_root = str(Path(work_root).absolute())
        if not callable(exchange) or not Path(self._work_root).is_absolute():
            raise ArchiveSourceResolverError()

    @staticmethod
    def _request(method, path, body=b""):
        headers = (("Accept", "application/json"),)
        if body:
            headers += (("Content-Type", "application/json"),)
        return UnmanicRequest(method, path, headers, body)

    def read_verified_library(self, *, deadline):
        _deadline(deadline)
        try:
            response = self._exchange(self._request(
                "GET", self._PREFIX + "/settings/libraries"), deadline)
            _require(type(response) is UnmanicResponse and response.status == 200,
                     "unmanic_authority_changed")
            listed = _decode(response)
            libraries = listed.get("libraries")
            _require(type(libraries) is list and 1 <= len(libraries) <= 64,
                     "unmanic_authority_changed")
            matches = []
            for item in libraries:
                _require(type(item) is dict, "unmanic_authority_changed")
                identifier, path = item.get("id"), item.get("path")
                _require(type(identifier) is int and type(identifier) is not bool
                         and 1 <= identifier <= 2**63 - 1
                         and type(path) is str and Path(path).is_absolute(),
                         "unmanic_authority_changed")
                if path == self._work_root:
                    matches.append(identifier)
            _require(len(matches) == 1, "unmanic_authority_changed")
            body = _canonical({"id": matches[0]})
            response = self._exchange(self._request(
                "POST", self._PREFIX + "/settings/library/read", body),
                deadline)
            _require(type(response) is UnmanicResponse and response.status == 200,
                     "unmanic_authority_changed")
            detail = _decode(response)
            _require(set(detail) == {"library_config", "plugins"}
                     and type(detail["library_config"]) is dict
                     and type(detail["plugins"]) is dict,
                     "unmanic_authority_changed")
            config = detail["library_config"]
            _require(config.get("id") == matches[0]
                     and config.get("path") == self._work_root,
                     "unmanic_authority_changed")
            result = VerifiedUnmanicLibrary(
                libraryId=matches[0], workRoot=self._work_root,
                configDigest=hashlib.sha256(_canonical(detail)).hexdigest())
            _deadline(deadline)
            return result
        except ArchiveSourceResolverError:
            raise
        except Exception:
            raise ArchiveSourceResolverError(
                "unmanic_authority_changed") from None


@dataclass(frozen=True, repr=False)
class _Mount:
    mountId: str
    serviceRoot: str
    hostRoot: Path
    device: int
    inode: int

    def __repr__(self):
        return "_Mount(<private>)"


class PrivateMediaArchiveSourceResolver:
    """Durable sourceItemId resolver owned only by the archive worker."""

    def __init__(self, directory, key, *, approved_mounts, work_root,
                 retained_root, authority_reader, unmanic_reader):
        self.directory = Path(directory).absolute()
        self.database_path = self.directory / "media-archive-sources.sqlite"
        self.lock_path = self.directory / "media-archive-sources.lock"
        self._mutex = threading.Lock()
        self._closed = False
        self._db = None
        self._lock_fd = None
        try:
            _require(type(key) is bytes and len(key) >= 32
                     and (authority_reader is None
                          or isinstance(
                              authority_reader, ArchiveActionAuthorityReader))
                     and isinstance(unmanic_reader, UnmanicLibraryReader))
            self._key = hmac.new(
                key, b"larenor-media-archive-source-resolver-v1",
                hashlib.sha256).digest()
            self._authority_reader = authority_reader
            self._unmanic_reader = unmanic_reader
            _safe_path(self.directory, uid=os.getuid(), kind=stat.S_ISDIR,
                       private=True)
            self._work = self._observe_root(work_root, private=True)
            self._retained = self._observe_root(retained_root, private=True)
            mounts = tuple(self._approved(item) for item in approved_mounts)
            _require(1 <= len(mounts) <= 16
                     and len({item.mountId for item in mounts}) == len(mounts)
                     and len({item.serviceRoot for item in mounts}) == len(mounts)
                     and len({item.hostRoot for item in mounts}) == len(mounts))
            self._mounts = {item.mountId: item for item in mounts}
            roots = (self._work[0], self._retained[0],
                     *(item.hostRoot for item in mounts))
            _require(len(set(roots)) == len(roots)
                     and all(not left.is_relative_to(right)
                             for left in roots for right in roots
                             if left != right))
            self._policy_digest = hashlib.sha256(_canonical({
                "work": self._root_values(self._work),
                "retained": self._root_values(self._retained),
                "mounts": [{
                    "mountId": item.mountId,
                    "serviceRoot": item.serviceRoot,
                    "hostRoot": str(item.hostRoot),
                    "device": item.device,
                    "inode": item.inode,
                } for item in mounts],
            })).hexdigest()
            new_db = not os.path.lexists(self.database_path)
            new_lock = not os.path.lexists(self.lock_path)
            _require(new_db == new_lock)
            if new_db:
                for path in (self.database_path, self.lock_path):
                    descriptor = os.open(
                        path, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                        | os.O_NOFOLLOW, 0o600)
                    os.close(descriptor)
            for path in (self.database_path, self.lock_path):
                _safe_path(path, uid=os.getuid(), kind=stat.S_ISREG,
                           private=True)
            info = self.database_path.stat()
            self._file_identity = info.st_dev, info.st_ino
            self._lock_fd = os.open(self.lock_path, os.O_RDWR | os.O_NOFOLLOW)
            self._db = sqlite3.connect(
                self.database_path, isolation_level=None, timeout=2,
                check_same_thread=False)
            self._db.row_factory = sqlite3.Row
            self._db.execute("PRAGMA journal_mode=DELETE")
            self._db.execute("PRAGMA synchronous=FULL")
            with self._locked():
                if new_db:
                    self._db.execute("BEGIN IMMEDIATE")
                    for statement in _SCHEMA:
                        self._db.execute(statement)
                    self._db.execute("COMMIT")
                    descriptor = os.open(
                        self.directory, os.O_RDONLY | os.O_DIRECTORY)
                    try:
                        os.fsync(descriptor)
                    finally:
                        os.close(descriptor)
                self._validate_storage()
        except Exception:
            self.close()
            raise ArchiveSourceResolverError() from None

    def __repr__(self):
        return "PrivateMediaArchiveSourceResolver(<private>)"

    @staticmethod
    def _root_values(root):
        return {"path": str(root[0]), "device": root[1], "inode": root[2]}

    @staticmethod
    def _observe_root(value, *, private):
        path = Path(value).absolute()
        _safe_path(path, uid=os.getuid(), kind=stat.S_ISDIR, private=private)
        descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            info = os.fstat(descriptor)
            return path, info.st_dev, info.st_ino
        finally:
            os.close(descriptor)

    @classmethod
    def _approved(cls, value):
        _require(type(value) is ApprovedArchiveMount
                 and _MOUNT_ID.fullmatch(value.mountId) is not None)
        service = PurePosixPath(value.serviceRoot)
        _require(service.is_absolute() and service != PurePosixPath("/")
                 and ".." not in service.parts
                 and str(service) == value.serviceRoot)
        root = cls._observe_root(value.hostRoot, private=False)
        return _Mount(value.mountId, value.serviceRoot, *root)

    @staticmethod
    def _check_root(root, *, private):
        path, device, inode = root
        _safe_path(path, uid=os.getuid(), kind=stat.S_ISDIR, private=private)
        descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            info = os.fstat(descriptor)
            _require((info.st_dev, info.st_ino) == (device, inode),
                     "source_path_rejected")
        finally:
            os.close(descriptor)

    def _paths(self):
        self._check_root(self._work, private=True)
        self._check_root(self._retained, private=True)
        for mount in self._mounts.values():
            self._check_root(
                (mount.hostRoot, mount.device, mount.inode), private=False)
        _safe_path(self.directory, uid=os.getuid(), kind=stat.S_ISDIR,
                   private=True)
        for path in (self.database_path, self.lock_path):
            _safe_path(path, uid=os.getuid(), kind=stat.S_ISREG,
                       private=True)
        database = self.database_path.stat()
        lock = self.lock_path.stat()
        opened = os.fstat(self._lock_fd)
        _require((database.st_dev, database.st_ino) == self._file_identity
                 and database.st_size <= _MAX_DATABASE_BYTES
                 and (lock.st_dev, lock.st_ino) ==
                 (opened.st_dev, opened.st_ino))

    @contextmanager
    def _locked(self):
        _require(not self._closed and self._mutex.acquire(blocking=False),
                 "archive_source_busy")
        acquired = False
        try:
            self._paths()
            try:
                fcntl.flock(self._lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                acquired = True
            except OSError:
                raise ArchiveSourceResolverError(
                    "archive_source_busy") from None
            yield
        finally:
            if acquired:
                fcntl.flock(self._lock_fd, fcntl.LOCK_UN)
            self._mutex.release()

    def close(self):
        if self._closed:
            return
        self._closed = True
        if self._db is not None:
            self._db.close()
        if self._lock_fd is not None:
            os.close(self._lock_fd)

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.close()

    def _tag(self, domain, value):
        return hmac.new(
            self._key, domain + b"\0" + _canonical(value),
            hashlib.sha256).hexdigest()

    @staticmethod
    def _authority_value(authority):
        return authority.model_dump(mode="json")

    @staticmethod
    def _row_values(row):
        return {key: row[key] for key in (
            "source_item_id", "media_key", "mount_id", "relative_path",
            "source_size_bytes", "source_codec", "source_bitrate",
            "duration_seconds")}

    def _decode_row(self, row):
        values = self._row_values(row)
        _require(type(values["source_item_id"]) is str
                 and _ID.fullmatch(values["source_item_id"]) is not None
                 and type(values["media_key"]) is str
                 and _MEDIA_KEY.fullmatch(values["media_key"]) is not None
                 and values["mount_id"] in self._mounts
                 and self._relative(values["relative_path"]) is not None
                 and type(values["source_size_bytes"]) is int
                 and 1 <= values["source_size_bytes"] <= 2**63 - 1
                 and values["source_codec"] in _CODECS
                 and type(values["source_bitrate"]) is int
                 and 1 <= values["source_bitrate"] <= 1_000_000_000
                 and type(values["duration_seconds"]) is int
                 and 1 <= values["duration_seconds"] <= 31_536_000
                 and type(row["authentication_tag"]) is str
                 and hmac.compare_digest(
                     row["authentication_tag"],
                     self._tag(b"source", values)))
        return values

    def _validate_storage(self):
        try:
            _require(self._db.execute(
                "PRAGMA integrity_check").fetchone()[0] == "ok")
            schemas = self._db.execute(
                "SELECT sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' "
                "ORDER BY name").fetchall()
            _require([" ".join(row[0].split()) for row in schemas]
                     == [" ".join(item.split()) for item in _SCHEMA])
            rows = self._db.execute(
                "SELECT * FROM sources ORDER BY source_item_id LIMIT ?",
                (_MAX_SOURCES + 1,)).fetchall()
            _require(len(rows) <= _MAX_SOURCES)
            for row in rows:
                self._decode_row(row)
            metadata = self._db.execute("SELECT * FROM metadata").fetchall()
            _require(len(metadata) <= 1)
            if not metadata:
                _require(not rows)
                return
            marker = metadata[0]
            authority_raw = marker["authority"]
            _require(type(authority_raw) is bytes
                     and len(authority_raw) <= 4096
                     and marker["singleton"] == 1
                     and marker["version"] == 1
                     and type(marker["generation"]) is int
                     and 1 <= marker["generation"] <= 2**63 - 1
                     and type(marker["library_id"]) is int
                     and 1 <= marker["library_id"] <= 2**63 - 1
                     and _DIGEST.fullmatch(
                         marker["unmanic_config_digest"] or "") is not None
                     and marker["policy_digest"] == self._policy_digest
                     and marker["source_count"] == len(rows))
            authority_value = _json(authority_raw)
            authority = ArchiveActionAuthority.model_validate(authority_value)
            _require(_canonical(authority_value) == authority_raw)
            row_tags = [row["authentication_tag"] for row in rows]
            rows_digest = hashlib.sha256(_canonical(row_tags)).hexdigest()
            _require(marker["rows_digest"] == rows_digest)
            values = {
                "version": 1,
                "generation": marker["generation"],
                "authority": self._authority_value(authority),
                "libraryId": marker["library_id"],
                "unmanicConfigDigest": marker["unmanic_config_digest"],
                "policyDigest": marker["policy_digest"],
                "sourceCount": marker["source_count"],
                "rowsDigest": rows_digest,
            }
            _require(hmac.compare_digest(
                marker["authentication_tag"], self._tag(b"metadata", values)))
        except ArchiveSourceResolverError:
            raise
        except Exception:
            raise ArchiveSourceResolverError() from None

    @staticmethod
    def _relative(value):
        if type(value) is not str:
            return None
        path = PurePosixPath(value)
        if (path.is_absolute() or not path.parts or ".." in path.parts
                or "." in path.parts or str(path) != value
                or len(value) > 2048
                or path.suffix.lower() not in _SUFFIXES):
            return None
        return path

    def _translate(self, service_path):
        _require(type(service_path) is str and len(service_path) <= 4096,
                 "source_path_rejected")
        path = PurePosixPath(service_path)
        _require(path.is_absolute() and ".." not in path.parts
                 and str(path) == service_path, "source_path_rejected")
        matches = []
        for mount in self._mounts.values():
            root = PurePosixPath(mount.serviceRoot)
            try:
                relative = path.relative_to(root)
            except ValueError:
                continue
            if relative.parts:
                matches.append((mount, relative))
        _require(len(matches) == 1, "source_path_rejected")
        mount, relative = matches[0]
        _require(self._relative(str(relative)) is not None,
                 "source_path_rejected")
        return mount, str(relative)

    @contextmanager
    def _file(self, mount, relative):
        parts = self._relative(relative)
        _require(parts is not None, "source_path_rejected")
        descriptor = None
        file_descriptor = None
        try:
            self._check_root(
                (mount.hostRoot, mount.device, mount.inode), private=False)
            descriptor = os.open(
                mount.hostRoot, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            for part in parts.parts[:-1]:
                next_descriptor = os.open(
                    part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                    dir_fd=descriptor)
                os.close(descriptor)
                descriptor = next_descriptor
            file_descriptor = os.open(
                parts.parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                dir_fd=descriptor)
            info = os.fstat(file_descriptor)
            entry = os.stat(
                parts.parts[-1], dir_fd=descriptor, follow_symlinks=False)
            _require(stat.S_ISREG(info.st_mode)
                     and (info.st_dev, info.st_ino) ==
                     (entry.st_dev, entry.st_ino), "source_path_rejected")
            yield str(mount.hostRoot.joinpath(*parts.parts)), info
        except ArchiveSourceResolverError:
            raise
        except OSError:
            raise ArchiveSourceResolverError("source_path_rejected") from None
        finally:
            if file_descriptor is not None:
                os.close(file_descriptor)
            if descriptor is not None:
                os.close(descriptor)

    @staticmethod
    def _verified_unmanic(value, work_root):
        _require(type(value) is VerifiedUnmanicLibrary
                 and type(value.libraryId) is int
                 and type(value.libraryId) is not bool
                 and 1 <= value.libraryId <= 2**63 - 1
                 and value.workRoot == str(work_root)
                 and _DIGEST.fullmatch(value.configDigest or "") is not None,
                 "unmanic_authority_changed")
        return value

    def _current(self, authority, deadline):
        _deadline(deadline)
        _require(self._authority_reader is not None, "authority_changed")
        try:
            current = self._authority_reader.current_archive_action_authority(
                authority.installationId, deadline=deadline)
        except ArchiveSourceResolverError:
            raise
        except Exception:
            raise ArchiveSourceResolverError("authority_changed") from None
        _require(type(current) is ArchiveActionAuthority
                 and current == authority, "authority_changed")
        return current

    def _unmanic(self, deadline):
        _deadline(deadline)
        try:
            value = self._unmanic_reader.read_verified_library(
                deadline=deadline)
        except ArchiveSourceResolverError:
            raise
        except Exception:
            raise ArchiveSourceResolverError(
                "unmanic_authority_changed") from None
        return self._verified_unmanic(value, self._work[0])

    @staticmethod
    def _grant(gate, deadline):
        _deadline(deadline)
        try:
            allowed = gate()
        except Exception:
            allowed = False
        _require(allowed is True, "authority_changed")

    @staticmethod
    def _record(value):
        _require(type(value) is AuthenticatedArchiveSourceRecord
                 and _ID.fullmatch(value.sourceItemId or "") is not None
                 and _MEDIA_KEY.fullmatch(value.mediaKey or "") is not None
                 and type(value.sourceSizeBytes) is int
                 and type(value.sourceSizeBytes) is not bool
                 and 1 <= value.sourceSizeBytes <= 2**63 - 1
                 and value.sourceCodec in _CODECS
                 and type(value.sourceBitrate) is int
                 and type(value.sourceBitrate) is not bool
                 and 1 <= value.sourceBitrate <= 1_000_000_000
                 and type(value.durationSeconds) is int
                 and type(value.durationSeconds) is not bool
                 and 1 <= value.durationSeconds <= 31_536_000,
                 "evidence_changed")
        return value

    def replace_collection_authenticated(
            self, authority, records, *, deadline, gate):
        """Publish records from one exact private collector grant."""
        _require(type(authority) is MediaArchiveCollectionAuthority)
        action_authority = ArchiveActionAuthority(
            installationId=authority.installationId,
            installationRevision=authority.installationRevision,
            snapshotRevision=authority.snapshotRevision,
            sourceRevisions={item.serviceId: item.serviceRevision
                             for item in authority.sources},
        )
        return self.replace_authenticated(
            action_authority, records, deadline=deadline, gate=gate)

    def replace_authenticated(
            self, authority, records, *, deadline, gate=None):
        """Atomically replace the private cache after one coherent collection."""
        _deadline(deadline)
        _require(type(authority) is ArchiveActionAuthority
                 and type(records) in (tuple, list)
                 and len(records) <= _MAX_SOURCES
                 and (gate is None or callable(gate)))
        if gate is None:
            self._current(authority, deadline)
        else:
            self._grant(gate, deadline)
        unmanic = self._unmanic(deadline)
        rows = []
        identifiers = set()
        for raw in records:
            record = self._record(raw)
            _require(record.sourceItemId not in identifiers,
                     "evidence_changed")
            identifiers.add(record.sourceItemId)
            mount, relative = self._translate(record.sourcePath)
            with self._file(mount, relative) as (_path, info):
                _require(info.st_size == record.sourceSizeBytes,
                         "evidence_changed")
            values = {
                "source_item_id": record.sourceItemId,
                "media_key": record.mediaKey,
                "mount_id": mount.mountId,
                "relative_path": relative,
                "source_size_bytes": record.sourceSizeBytes,
                "source_codec": record.sourceCodec,
                "source_bitrate": record.sourceBitrate,
                "duration_seconds": record.durationSeconds,
            }
            rows.append((*values.values(), self._tag(b"source", values)))
        rows.sort(key=lambda item: item[0])
        if gate is None:
            self._current(authority, deadline)
        else:
            self._grant(gate, deadline)
        latest_unmanic = self._unmanic(deadline)
        _require(latest_unmanic == unmanic, "unmanic_authority_changed")
        authority_raw = _canonical(self._authority_value(authority))
        row_tags = [row[-1] for row in rows]
        rows_digest = hashlib.sha256(_canonical(row_tags)).hexdigest()
        with self._locked():
            self._validate_storage()
            marker = self._db.execute(
                "SELECT generation FROM metadata").fetchone()
            generation = 1 if marker is None else marker[0] + 1
            values = {
                "version": 1,
                "generation": generation,
                "authority": self._authority_value(authority),
                "libraryId": unmanic.libraryId,
                "unmanicConfigDigest": unmanic.configDigest,
                "policyDigest": self._policy_digest,
                "sourceCount": len(rows),
                "rowsDigest": rows_digest,
            }
            try:
                self._db.execute("BEGIN IMMEDIATE")
                self._db.execute("DELETE FROM sources")
                self._db.execute("DELETE FROM metadata")
                self._db.executemany(
                    "INSERT INTO sources VALUES(?,?,?,?,?,?,?,?,?)", rows)
                self._db.execute(
                    "INSERT INTO metadata VALUES(1,?,?,?,?,?,?,?,?,?)",
                    (1, generation, authority_raw, unmanic.libraryId,
                     unmanic.configDigest, self._policy_digest, len(rows),
                     rows_digest, self._tag(b"metadata", values)))
                if gate is None:
                    self._current(authority, deadline)
                else:
                    self._grant(gate, deadline)
                self._db.execute("COMMIT")
            except Exception:
                if self._db.in_transaction:
                    self._db.execute("ROLLBACK")
                raise
            self._validate_storage()
        return generation

    def _lookup(self, command, deadline, *, exact_profile):
        _deadline(deadline)
        _require(type(command) is PrivateArchiveActionCommand
                 and command.operation == "stage_transcode"
                 and command.target.targetType == "transcode",
                 "evidence_changed")
        authority = command.authority
        self._current(authority, deadline)
        unmanic = self._unmanic(deadline)
        with self._locked():
            self._validate_storage()
            marker = self._db.execute("SELECT * FROM metadata").fetchone()
            _require(marker is not None, "evidence_changed")
            stored_authority = ArchiveActionAuthority.model_validate(
                _json(marker["authority"]))
            _require(stored_authority == authority
                     and marker["library_id"] == unmanic.libraryId
                     and hmac.compare_digest(
                         marker["unmanic_config_digest"],
                         unmanic.configDigest), "authority_changed")
            row = self._db.execute(
                "SELECT * FROM sources WHERE source_item_id=?",
                (command.target.sourceItemId,)).fetchone()
            _require(row is not None, "evidence_changed")
            source = self._decode_row(row)
        target = command.target
        _require((source["source_item_id"], source["media_key"])
                 == (target.sourceItemId, target.mediaKey),
                 "evidence_changed")
        if exact_profile:
            _require((source["source_size_bytes"], source["source_codec"],
                      source["source_bitrate"], source["duration_seconds"])
                     == (target.sourceSizeBytes, target.sourceCodec,
                         target.sourceBitrate, target.durationSeconds),
                     "evidence_changed")
        mount = self._mounts[source["mount_id"]]
        with self._file(mount, source["relative_path"]) as (path, info):
            if exact_profile:
                _require(info.st_size == target.sourceSizeBytes,
                         "evidence_changed")
        _deadline(deadline)
        return path, source, unmanic.libraryId

    def resolve(self, command, *, deadline):
        path, source, library_id = self._lookup(
            command, deadline, exact_profile=True)
        return ResolvedArchiveActionSource(
            commandDigest=action_command_digest(command),
            path=path,
            libraryId=library_id,
            sourceItemId=source["source_item_id"],
            mediaKey=source["media_key"],
            sourceSizeBytes=source["source_size_bytes"],
            sourceCodec=source["source_codec"],
            durationSeconds=source["duration_seconds"],
        )

    def authorize(self, command, *, deadline):
        """Renew authority for recovery after an installed file changed profile."""
        try:
            self._lookup(command, deadline, exact_profile=False)
            return True
        except Exception:
            return False


def build_private_media_archive_source_resolver(
        catalog_path, *, authority_reader, unmanic_exchange):
    """Runtime factory with all path/key/ID policy outside CLI requests."""
    catalog = PrivateArchiveResolverCatalog.load(catalog_path)
    return PrivateMediaArchiveSourceResolver(
        catalog.storeRoot, catalog.authenticationKey,
        approved_mounts=catalog.approvedMounts,
        work_root=catalog.workRoot,
        retained_root=catalog.retainedRoot,
        authority_reader=authority_reader,
        unmanic_reader=UnmanicLibraryReadback(
            unmanic_exchange, catalog.workRoot),
    )


def build_private_media_archive_source_publisher(
        catalog_path, *, unmanic_exchange):
    """Collector-side writer; its per-call grant supplies Core authority."""
    catalog = PrivateArchiveResolverCatalog.load(catalog_path)
    return PrivateMediaArchiveSourceResolver(
        catalog.storeRoot, catalog.authenticationKey,
        approved_mounts=catalog.approvedMounts,
        work_root=catalog.workRoot,
        retained_root=catalog.retainedRoot,
        authority_reader=None,
        unmanic_reader=UnmanicLibraryReadback(
            unmanic_exchange, catalog.workRoot),
    )
