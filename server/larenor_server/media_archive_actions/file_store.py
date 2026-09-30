"""Protected originals and isolated Unmanic work files.

Paths are supplied only by the trusted Jellyfin item resolver and must lie in
configured library roots. The wire command contains item IDs, never host paths.
The source is read without following symlinks; replacement uses a sibling file
and preserves a separately verified original until explicit cleanup.
"""

from contextlib import contextmanager
from dataclasses import asdict, dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import stat

from ..plugins.worker import _safe_path
from .journal import action_command_digest


_ID = re.compile(r"[0-9a-f]{32}\Z")
_DIGEST = re.compile(r"[0-9a-f]{64}\Z")
_SUFFIXES = {".mkv", ".mp4", ".m4v", ".avi", ".mov", ".mpeg", ".mpg", ".ts", ".webm"}
_CHUNK = 1024 * 1024


class ArchiveFileStoreError(RuntimeError):
    def __init__(self, code="archive_file_store_unavailable"):
        self.code = code
        super().__init__(code)


def _require(condition, code="archive_file_store_unavailable"):
    if not condition:
        raise ArchiveFileStoreError(code)


def _canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")


def _unchanged(info):
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns


def _digest_fd(fd, cancelled):
    digest = hashlib.sha256()
    os.lseek(fd, 0, os.SEEK_SET)
    length = 0
    while True:
        _require(not cancelled(), "cancelled")
        chunk = os.read(fd, _CHUNK)
        if not chunk:
            break
        digest.update(chunk)
        length += len(chunk)
    return digest.hexdigest(), length


@dataclass(frozen=True, repr=False)
class ArchiveSourceFile:
    path: str
    device: int
    inode: int
    byteLength: int
    mtimeNs: int
    ctimeNs: int
    sha256: str

    def __repr__(self):
        return "ArchiveSourceFile(<private>)"

    @property
    def identity(self):
        return self.device, self.inode, self.byteLength, self.mtimeNs, self.ctimeNs


@dataclass(frozen=True, repr=False)
class ArchiveStagedFiles:
    operationId: str
    commandDigest: str
    source: ArchiveSourceFile
    retainedPath: str
    workPath: str
    retainedDevice: int
    retainedInode: int

    def __repr__(self):
        return "ArchiveStagedFiles(<private>)"


@dataclass(frozen=True, repr=False)
class ArchiveRetainedCleanupProof:
    operationId: str
    commandDigest: str
    retainedDevice: int
    retainedInode: int
    retainedDigest: str
    retainedBytes: int
    outputDigest: str
    outputBytes: int

    def __repr__(self):
        return "ArchiveRetainedCleanupProof(<private>)"


class MediaArchiveFileStore:
    """Effect methods require the worker journal's exclusive effect lease."""

    def __init__(self, retained_root, work_root, library_roots, *, quota_bytes):
        try:
            self.retained_root = Path(retained_root).absolute()
            self.work_root = Path(work_root).absolute()
            self.library_roots = tuple(Path(path).absolute() for path in library_roots)
            _require(type(quota_bytes) is int and 1 <= quota_bytes <= 10 * 1024**4)
            self.quota_bytes = quota_bytes
            _require(1 <= len(self.library_roots) <= 16)
            roots = (self.retained_root, self.work_root, *self.library_roots)
            _require(len(set(roots)) == len(roots))
            _require(all(not left.is_relative_to(right) for left in roots for right in roots if left != right))
            for path in (self.retained_root, self.work_root):
                _safe_path(path, uid=os.getuid(), kind=stat.S_ISDIR, private=True)
            for path in self.library_roots:
                _safe_path(path, uid=os.getuid(), kind=stat.S_ISDIR)
        except Exception:
            raise ArchiveFileStoreError() from None

    def _operation(self, operation_id):
        _require(type(operation_id) is str and _ID.fullmatch(operation_id))
        return operation_id

    @contextmanager
    def _library_parent(self, path):
        """Walk descriptor-relative so a renamed/symlink parent cannot escape."""
        path = Path(path)
        _require(path.is_absolute() and ".." not in path.parts, "source_path_rejected")
        matches = [root for root in self.library_roots if path.is_relative_to(root) and path != root]
        _require(len(matches) == 1, "source_path_rejected")
        root = matches[0]
        parts = path.relative_to(root).parts
        fd = None
        try:
            _safe_path(root, uid=os.getuid(), kind=stat.S_ISDIR)
            fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            for part in parts[:-1]:
                next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                os.close(fd)
                fd = next_fd
            yield fd, parts[-1]
        except OSError:
            raise ArchiveFileStoreError("source_path_rejected") from None
        finally:
            if fd is not None:
                os.close(fd)

    @contextmanager
    def _source_fd(self, source):
        with self._library_parent(source.path) as (parent, name):
            fd = None
            try:
                fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
                info = os.fstat(fd)
                _require(stat.S_ISREG(info.st_mode) and _unchanged(info) == source.identity,
                         "source_changed")
                yield fd, parent, name
            except OSError:
                raise ArchiveFileStoreError("source_changed") from None
            finally:
                if fd is not None:
                    os.close(fd)

    def observe_source(self, trusted_path, *, expected_bytes, cancelled=lambda: False):
        _require(type(expected_bytes) is int and expected_bytes > 0)
        with self._library_parent(trusted_path) as (parent, name):
            fd = None
            try:
                fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
                info = os.fstat(fd)
                _require(stat.S_ISREG(info.st_mode) and info.st_size == expected_bytes, "source_changed")
                digest, length = _digest_fd(fd, cancelled)
                _require(_unchanged(os.fstat(fd)) == _unchanged(info) and length == expected_bytes,
                         "source_changed")
                entry = os.stat(name, dir_fd=parent, follow_symlinks=False)
                _require(_unchanged(entry) == _unchanged(info), "source_changed")
                return ArchiveSourceFile(str(trusted_path), info.st_dev, info.st_ino,
                                         length, info.st_mtime_ns, info.st_ctime_ns, digest)
            except OSError:
                raise ArchiveFileStoreError("source_path_rejected") from None
            finally:
                if fd is not None:
                    os.close(fd)

    def _op_dir(self, root, operation_id, *, create=False):
        self._operation(operation_id)
        _safe_path(root, uid=os.getuid(), kind=stat.S_ISDIR, private=True)
        path = root / operation_id
        if create:
            path.mkdir(mode=0o700)
            fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
        _safe_path(path, uid=os.getuid(), kind=stat.S_ISDIR, private=True)
        return path

    @staticmethod
    def _capacity(root, length):
        value = os.statvfs(root)
        _require(value.f_bavail * value.f_frsize >= length, "archive_capacity_exceeded")

    def retained_bytes(self):
        total = 0
        for entry in self.retained_root.iterdir():
            self._operation(entry.name)
            directory = self._op_dir(self.retained_root, entry.name)
            files = list(directory.iterdir())
            _require(all(path.name in {"original", "stage.json"} for path in files))
            for path in files:
                _safe_path(path, uid=os.getuid(), kind=stat.S_ISREG, private=True)
                if path.name == "original":
                    total += path.stat().st_size
        return total

    @staticmethod
    def _copy(fd, destination, *, expected_digest, expected_bytes, cancelled):
        output_fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            os.lseek(fd, 0, os.SEEK_SET)
            digest = hashlib.sha256()
            length = 0
            while True:
                _require(not cancelled(), "cancelled")
                chunk = os.read(fd, _CHUNK)
                if not chunk:
                    break
                length += len(chunk)
                _require(length <= expected_bytes, "source_changed")
                digest.update(chunk)
                view = memoryview(chunk)
                while view:
                    written = os.write(output_fd, view)
                    _require(written > 0)
                    view = view[written:]
            _require(length == expected_bytes and digest.hexdigest() == expected_digest, "source_changed")
            os.fsync(output_fd)
        finally:
            os.close(output_fd)
        parent_fd = os.open(Path(destination).parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(parent_fd)
        finally:
            os.close(parent_fd)

    @staticmethod
    def _verify(path, digest, length, cancelled):
        _safe_path(path, uid=os.getuid(), kind=stat.S_ISREG, private=True)
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            before = os.fstat(fd)
            actual = _digest_fd(fd, cancelled)
            _require(_unchanged(before) == _unchanged(os.fstat(fd))
                     and actual == (digest, length), "artifact_changed")
            return before
        finally:
            os.close(fd)

    def retain_and_stage(self, command, source, *, cancelled=lambda: False):
        _require(command.operation == "stage_transcode" and type(source) is ArchiveSourceFile)
        _require(source.byteLength == command.target.sourceSizeBytes
                 and command.reservedBytes == source.byteLength)
        _require(self.retained_bytes() + source.byteLength <= self.quota_bytes, "archive_quota_exceeded")
        suffix = Path(source.path).suffix.lower()
        _require(suffix in _SUFFIXES, "unsupported_source_format")
        self._capacity(self.retained_root, source.byteLength)
        self._capacity(self.work_root, source.byteLength)
        if self.retained_root.stat().st_dev == self.work_root.stat().st_dev:
            self._capacity(self.work_root, source.byteLength * 2)
        retained = self._op_dir(self.retained_root, command.operationId, create=True)
        work = self._op_dir(self.work_root, command.operationId, create=True)
        original, staged = retained / "original", work / ("media" + suffix)
        with self._source_fd(source) as (source_fd, _parent, _name):
            self._copy(source_fd, original, expected_digest=source.sha256,
                       expected_bytes=source.byteLength, cancelled=cancelled)
            _require(_unchanged(os.fstat(source_fd)) == source.identity, "source_changed")
        retained_info = self._verify(
            original, source.sha256, source.byteLength, cancelled)
        fd = os.open(original, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            self._copy(fd, staged, expected_digest=source.sha256,
                       expected_bytes=source.byteLength, cancelled=cancelled)
        finally:
            os.close(fd)
        self._verify(staged, source.sha256, source.byteLength, cancelled)
        binding = ArchiveStagedFiles(
            command.operationId, action_command_digest(command), source,
            str(original), str(staged), retained_info.st_dev,
            retained_info.st_ino)
        payload = _canonical({"operationId": binding.operationId,
                              "commandDigest": binding.commandDigest,
                              "source": asdict(source),
                              "workName": staged.name,
                              "retainedDevice": binding.retainedDevice,
                              "retainedInode": binding.retainedInode})
        fd = os.open(retained / "stage.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            _require(os.write(fd, payload) == len(payload))
            os.fsync(fd)
        finally:
            os.close(fd)
        fd = os.open(retained, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
        return binding

    def lookup(self, command):
        retained = self._op_dir(self.retained_root, command.operationId)
        work = self._op_dir(self.work_root, command.operationId)
        path = retained / "stage.json"
        _safe_path(path, uid=os.getuid(), kind=stat.S_ISREG, private=True)
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            payload = os.read(fd, 16385)
            _require(len(payload) <= 16384)
            value = json.loads(payload)
            _require(type(value) is dict and set(value) == {
                         "operationId", "commandDigest", "source", "workName",
                         "retainedDevice", "retainedInode"}
                     and _canonical(value) == payload)
            _require(value["operationId"] == command.operationId
                     and value["commandDigest"] == action_command_digest(command), "evidence_changed")
            source = ArchiveSourceFile(**value["source"])
            _require(type(source.sha256) is str and _DIGEST.fullmatch(source.sha256))
            _require(type(value["retainedDevice"]) is int
                     and value["retainedDevice"] >= 0
                     and type(value["retainedInode"]) is int
                     and value["retainedInode"] > 0)
            _require(value["workName"] == "media" + Path(source.path).suffix.lower())
            return ArchiveStagedFiles(command.operationId, value["commandDigest"], source,
                                     str(retained / "original"),
                                     str(work / value["workName"]),
                                     value["retainedDevice"],
                                     value["retainedInode"])
        except (ValueError, TypeError, KeyError):
            raise ArchiveFileStoreError() from None
        finally:
            os.close(fd)

    def inspect_original(self, binding, *, cancelled=lambda: False):
        expected = self._op_dir(self.retained_root, binding.operationId) / "original"
        _require(str(expected) == binding.retainedPath)
        info = self._verify(
            expected, binding.source.sha256, binding.source.byteLength,
            cancelled)
        _require((info.st_dev, info.st_ino) == (
            binding.retainedDevice, binding.retainedInode),
            "artifact_changed")
        return binding.source.sha256, binding.source.byteLength

    def preview_retained_cleanup(self, binding, *, output_bytes):
        _require(type(output_bytes) is int
                 and 0 < output_bytes < binding.source.byteLength)
        with self._library_parent(binding.source.path) as (parent, name):
            installed = os.stat(name, dir_fd=parent, follow_symlinks=False)
            _require(stat.S_ISREG(installed.st_mode)
                     and installed.st_size == output_bytes,
                     "artifact_changed")
        retained = self._op_dir(
            self.retained_root, binding.operationId) / "original"
        _require(str(retained) == binding.retainedPath)
        info = os.stat(retained, follow_symlinks=False)
        _require(stat.S_ISREG(info.st_mode)
                 and info.st_size == binding.source.byteLength
                 and (info.st_dev, info.st_ino) == (
                     binding.retainedDevice, binding.retainedInode),
                 "artifact_changed")

    def install_verified(self, binding, *, output_digest, output_bytes,
                         before_replace, cancelled=lambda: False):
        """Caller first verifies codec/playback and durably saves install intent."""
        _require(type(output_digest) is str and _DIGEST.fullmatch(output_digest))
        _require(type(output_bytes) is int and 0 < output_bytes < binding.source.byteLength)
        self.inspect_original(binding, cancelled=cancelled)
        work = self._op_dir(self.work_root, binding.operationId)
        output = Path(binding.workPath)
        _require(output.parent == work and output.name == "media" + Path(binding.source.path).suffix.lower())
        self._seal_provider_output(output, output_digest, output_bytes, cancelled)
        self._verify(output, output_digest, output_bytes, cancelled)
        with self._source_fd(binding.source) as (source_fd, parent, name):
            _require(_digest_fd(source_fd, cancelled) == (binding.source.sha256, binding.source.byteLength),
                     "source_changed")
            staged_name = ".larenor-" + binding.operationId + ".install"
            # Descriptor-relative destination remains in the source directory.
            temp_fd = os.open(staged_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                              0o600, dir_fd=parent)
            try:
                input_fd = os.open(output, os.O_RDONLY | os.O_NOFOLLOW)
                try:
                    copied = hashlib.sha256()
                    length = 0
                    while True:
                        _require(not cancelled(), "cancelled")
                        chunk = os.read(input_fd, _CHUNK)
                        if not chunk:
                            break
                        copied.update(chunk)
                        length += len(chunk)
                        _require(length <= output_bytes, "artifact_changed")
                        view = memoryview(chunk)
                        while view:
                            count = os.write(temp_fd, view)
                            _require(count > 0)
                            view = view[count:]
                    _require((copied.hexdigest(), length) == (output_digest, output_bytes), "artifact_changed")
                finally:
                    os.close(input_fd)
                os.fchmod(temp_fd, stat.S_IMODE(os.fstat(source_fd).st_mode))
                os.fsync(temp_fd)
                before_replace(binding, output_digest, output_bytes)
                _require(not cancelled(), "cancelled")
                current = os.stat(name, dir_fd=parent, follow_symlinks=False)
                _require(_unchanged(current) == binding.source.identity, "source_changed")
                os.replace(staged_name, name, src_dir_fd=parent, dst_dir_fd=parent)
                os.fsync(parent)
            finally:
                os.close(temp_fd)
        return output_digest, output_bytes

    @staticmethod
    def _seal_provider_output(output, digest, length, cancelled):
        # Unmanic moves its FFmpeg output into this already private operation
        # directory with the provider's umask (commonly 0644). Seal only the
        # exact verified work file, never a library source or retained original.
        fd = os.open(output, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            before = os.fstat(fd)
            _require(stat.S_ISREG(before.st_mode)
                     and before.st_uid == os.getuid()
                     and before.st_nlink == 1
                     and not before.st_mode & 0o022, "artifact_changed")
            _require(_digest_fd(fd, cancelled) == (digest, length)
                     and _unchanged(os.fstat(fd)) == _unchanged(before)
                     and _unchanged(os.stat(output, follow_symlinks=False))
                     == _unchanged(before), "artifact_changed")
            os.fchmod(fd, 0o600)
            os.fsync(fd)
        finally:
            os.close(fd)

    def observe_retained_cleanup(self, binding, *, expected_digest,
                                 output_digest, output_bytes,
                                 cancelled=lambda: False):
        _require(expected_digest == binding.source.sha256, "evidence_changed")
        _require(type(output_digest) is str and _DIGEST.fullmatch(output_digest))
        _require(type(output_bytes) is int and 0 < output_bytes < binding.source.byteLength)
        installed = self.observe_source(binding.source.path, expected_bytes=output_bytes,
                                        cancelled=cancelled)
        _require(installed.sha256 == output_digest, "artifact_changed")
        expected = self._op_dir(
            self.retained_root, binding.operationId) / "original"
        _require(str(expected) == binding.retainedPath)
        retained = self._verify(
            expected, binding.source.sha256, binding.source.byteLength,
            cancelled)
        _require((retained.st_dev, retained.st_ino) == (
            binding.retainedDevice, binding.retainedInode),
            "artifact_changed")
        return ArchiveRetainedCleanupProof(
            operationId=binding.operationId,
            commandDigest=binding.commandDigest,
            retainedDevice=retained.st_dev,
            retainedInode=retained.st_ino,
            retainedDigest=binding.source.sha256,
            retainedBytes=binding.source.byteLength,
            outputDigest=output_digest,
            outputBytes=output_bytes,
        )

    def cleanup_retained(self, binding, proof, *, intent_recorded,
                         before_delete=None, before_unlink,
                         cancelled=lambda: False):
        _require(type(proof) is ArchiveRetainedCleanupProof
                 and proof.operationId == binding.operationId
                 and proof.commandDigest == binding.commandDigest
                 and proof.retainedDigest == binding.source.sha256
                 and proof.retainedBytes == binding.source.byteLength
                 and (proof.retainedDevice, proof.retainedInode) == (
                     binding.retainedDevice, binding.retainedInode)
                 and type(proof.retainedDevice) is int
                 and proof.retainedDevice >= 0
                 and type(proof.retainedInode) is int
                 and proof.retainedInode > 0
                 and type(intent_recorded) is bool
                 and callable(before_unlink)
                 and (intent_recorded or callable(before_delete)),
                 "evidence_changed")
        installed = self.observe_source(
            binding.source.path, expected_bytes=proof.outputBytes,
            cancelled=cancelled)
        _require(installed.sha256 == proof.outputDigest, "artifact_changed")
        parent = self._op_dir(self.retained_root, binding.operationId)
        fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            try:
                retained_fd = os.open(
                    "original", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                    dir_fd=fd)
            except FileNotFoundError:
                _require(intent_recorded, "retained_original_missing")
                return False
            try:
                before = os.fstat(retained_fd)
                _require(
                    stat.S_ISREG(before.st_mode)
                    and (before.st_dev, before.st_ino) == (
                        proof.retainedDevice, proof.retainedInode),
                    "artifact_changed")
                actual = _digest_fd(retained_fd, cancelled)
                _require(
                    _unchanged(before) == _unchanged(os.fstat(retained_fd))
                    and actual == (
                        proof.retainedDigest, proof.retainedBytes),
                    "artifact_changed")
            finally:
                os.close(retained_fd)
            if not intent_recorded:
                before_delete(proof)
                _require(not cancelled(), "cancelled")
                installed = self.observe_source(
                    binding.source.path, expected_bytes=proof.outputBytes,
                    cancelled=cancelled)
                _require(
                    installed.sha256 == proof.outputDigest,
                    "artifact_changed")
                entry = os.stat("original", dir_fd=fd, follow_symlinks=False)
                _require(
                    _unchanged(entry) == _unchanged(before),
                    "artifact_changed")
            before_unlink(proof)
            _require(not cancelled(), "cancelled")
            os.unlink("original", dir_fd=fd)
            os.fsync(fd)
            return True
        finally:
            os.close(fd)
