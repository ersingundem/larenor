"""Authority-bound leases for isolated read-only component captures.

The native capture engine owns the atomic filesystem operation.  This module
accepts only an exact, separately rooted, read-only descriptor set bound to the
durable installation source tuple and keeps that lease alive through the
consumer boundary.
"""

import fcntl
import json
import math
import os
from pathlib import Path
import re
import secrets
import stat
import subprocess
import time
from contextlib import contextmanager
from dataclasses import dataclass, fields

from .component_snapshot_provider import ComponentVolumeSource
from .component_linux_capture_preflight import LinuxBtrfsCaptureCapability
from ..files import checked_path, private_directory, private_read, sync_directory

_CAPTURE_ID = re.compile(r"[a-z0-9][a-z0-9_.-]{0,127}\Z")
_CAPTURE_GENERATION = re.compile(r"[0-9a-f]{32}\Z")
_HEX_ID = re.compile(r"[0-9a-f]{32}\Z")
_MAX_JOURNAL_BYTES = 64 * 1024


class IsolatedComponentCaptureError(RuntimeError):
    """Static capture failure without host paths or backend diagnostics."""

    def __init__(self):
        super().__init__("isolated_capture_unavailable")


class BtrfsReadOnlySnapshotBackend:
    """Fixed-operation btrfs adapter; never accepts Client commands."""

    def __init__(self, executable=Path("/usr/bin/btrfs"), *, runner=None):
        try:
            executable = checked_path(Path(executable))
            info = executable.lstat()
            selected_runner = subprocess.run if runner is None else runner
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_uid != 0
                or stat.S_IMODE(info.st_mode) & 0o022
                or not os.access(executable, os.X_OK)
                or not callable(selected_runner)
            ):
                raise ValueError()
        except Exception:
            raise IsolatedComponentCaptureError() from None
        self._executable = executable
        self._runner = selected_runner

    @staticmethod
    def _timeout(deadline):
        _remaining(deadline)
        return max(0.001, deadline - time.monotonic())

    @staticmethod
    def _directory_descriptor(descriptor):
        try:
            if type(descriptor) is not int or descriptor < 0:
                raise ValueError()
            info = os.fstat(descriptor)
            if not stat.S_ISDIR(info.st_mode):
                raise ValueError()
            return descriptor
        except Exception:
            raise IsolatedComponentCaptureError() from None

    @staticmethod
    def _capture_id(capture_id):
        if type(capture_id) is not str or _HEX_ID.fullmatch(capture_id) is None:
            raise IsolatedComponentCaptureError()
        return capture_id

    def _run(self, arguments, deadline, *, output=False, pass_fds=()):
        try:
            if (
                type(pass_fds) is not tuple
                or any(type(item) is not int or item < 0 for item in pass_fds)
                or len(set(pass_fds)) != len(pass_fds)
            ):
                raise ValueError()
            result = self._runner(
                [str(self._executable), *arguments],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE if output else subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=self._timeout(deadline),
                check=False,
                pass_fds=pass_fds,
            )
            if result.returncode != 0:
                raise ValueError()
            return result.stdout if output else b""
        except Exception:
            raise IsolatedComponentCaptureError() from None

    def create_read_only(
        self, source_descriptor, generation_descriptor, capture_id, deadline
    ):
        source_descriptor = self._directory_descriptor(source_descriptor)
        generation_descriptor = self._directory_descriptor(generation_descriptor)
        capture_id = self._capture_id(capture_id)
        source = f"/proc/self/fd/{source_descriptor}"
        destination = f"/proc/self/fd/{generation_descriptor}/{capture_id}"
        self._run(
            ["subvolume", "snapshot", "-r", str(source), str(destination)],
            deadline,
            pass_fds=(source_descriptor, generation_descriptor),
        )
        if not self.is_read_only(generation_descriptor, capture_id, deadline):
            raise IsolatedComponentCaptureError()

    def is_read_only(self, generation_descriptor, capture_id, deadline):
        generation_descriptor = self._directory_descriptor(generation_descriptor)
        capture_id = self._capture_id(capture_id)
        destination = f"/proc/self/fd/{generation_descriptor}/{capture_id}"
        value = self._run(
            ["property", "get", "-ts", str(destination), "ro"],
            deadline,
            output=True,
            pass_fds=(generation_descriptor,),
        )
        return value == b"ro=true\n"

    def delete(self, generation_descriptor, capture_id, deadline):
        generation_descriptor = self._directory_descriptor(generation_descriptor)
        capture_id = self._capture_id(capture_id)
        destination = f"/proc/self/fd/{generation_descriptor}/{capture_id}"
        self._run(
            ["subvolume", "delete", str(destination)],
            deadline,
            pass_fds=(generation_descriptor,),
        )


@dataclass(frozen=True, repr=False)
class IsolatedComponentVolume:
    service_id: str
    container_id: str
    volume_id: str
    service_version: str
    config_schema_version: int
    data_schema_version: str
    installation_revision: int
    source_device: int
    source_inode: int
    snapshot_device: int
    snapshot_inode: int
    descriptor: int
    writer_container_ids: tuple[str, ...]
    capture_version: int
    capture_generation: str
    capture_id: str

    def __repr__(self):
        return "IsolatedComponentVolume(<private>)"


def _exact(value, cls):
    return type(value) is cls and set(vars(value)) == {
        item.name for item in fields(cls)
    }


def _remaining(deadline):
    if (
        type(deadline) not in (int, float)
        or type(deadline) is bool
        or not math.isfinite(deadline)
        or deadline - time.monotonic() <= 0
    ):
        raise IsolatedComponentCaptureError()


def _canonical(value):
    try:
        return json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=True,
            allow_nan=False,
        ).encode("ascii")
    except (TypeError, ValueError, UnicodeError):
        raise IsolatedComponentCaptureError() from None


class LinuxCowCaptureEngine:
    """Own one crash-recoverable generation of read-only COW snapshots."""

    def __init__(
        self,
        capture_root,
        journal_path,
        *,
        backend=None,
        id_factory=None,
        capability_preflight=None,
        capture_capability=None,
    ):
        try:
            self.capture_root = checked_path(Path(capture_root))
            self.journal_path = checked_path(Path(journal_path))
            if (
                self.journal_path == self.capture_root
                or self.journal_path.is_relative_to(self.capture_root)
            ):
                raise ValueError()
            private_directory(self.capture_root)
            private_directory(self.journal_path.parent)
            selected = backend or BtrfsReadOnlySnapshotBackend()
            if any(
                not callable(getattr(selected, name, None))
                for name in ("create_read_only", "is_read_only", "delete")
            ):
                raise ValueError()
            if id_factory is not None and not callable(id_factory):
                raise ValueError()
            if (capability_preflight is None) != (capture_capability is None):
                raise ValueError()
            if capability_preflight is not None and (
                type(capture_capability) is not LinuxBtrfsCaptureCapability
                or not callable(getattr(capability_preflight, "revalidate", None))
                or not callable(getattr(capability_preflight, "source_retained", None))
                or not callable(getattr(capability_preflight, "retain_source", None))
                or not callable(getattr(capability_preflight, "retain_capture", None))
            ):
                raise ValueError()
        except Exception:
            raise IsolatedComponentCaptureError() from None
        self._backend = selected
        self._id_factory = id_factory or (lambda: secrets.token_hex(16))
        self._capability_preflight = capability_preflight
        self._capture_capability = capture_capability
        self._active_sources = None

    def _capability_retained(self, deadline):
        if self._capability_preflight is None:
            return True
        try:
            return (
                self._capability_preflight.revalidate(
                    self._capture_capability, deadline
                )
                is True
            )
        except Exception:
            return False

    def _source_retained(self, source, deadline):
        if self._capability_preflight is None:
            return True
        try:
            return (
                self._capability_preflight.source_retained(
                    source.path,
                    source.device,
                    source.inode,
                    self._capture_capability,
                    deadline,
                )
                is True
            )
        except Exception:
            return False

    def _require_capability(self, deadline):
        if not self._capability_retained(deadline):
            raise IsolatedComponentCaptureError()

    @contextmanager
    def _held_source(self, source, deadline):
        descriptor = -1
        try:
            if self._capability_preflight is not None:
                with self._capability_preflight.retain_source(
                    source.path,
                    source.device,
                    source.inode,
                    self._capture_capability,
                    deadline,
                ) as descriptor:
                    if type(descriptor) is not int or descriptor < 0:
                        raise IsolatedComponentCaptureError()
                    yield descriptor
                return
            before = source.path.lstat()
            descriptor = os.open(
                source.path,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
            )
            current = os.fstat(descriptor)
            after = source.path.lstat()
            expected = (source.device, source.inode)
            if (
                not stat.S_ISDIR(current.st_mode)
                or (before.st_dev, before.st_ino) != expected
                or (current.st_dev, current.st_ino) != expected
                or (after.st_dev, after.st_ino) != expected
            ):
                raise IsolatedComponentCaptureError()
            yield descriptor
            current = os.fstat(descriptor)
            after = source.path.lstat()
            if (current.st_dev, current.st_ino) != expected or (
                after.st_dev,
                after.st_ino,
            ) != expected:
                raise IsolatedComponentCaptureError()
        except (KeyboardInterrupt, SystemExit):
            raise
        except Exception:
            raise IsolatedComponentCaptureError() from None
        finally:
            if self._capability_preflight is None and descriptor >= 0:
                try:
                    os.close(descriptor)
                except OSError:
                    pass

    @contextmanager
    def _held_capture(self, deadline, *, exit_failure=None):
        descriptor = -1
        yielded = False
        body_failed = False
        try:
            if exit_failure is not None and not callable(exit_failure):
                raise IsolatedComponentCaptureError()
            if self._capability_preflight is not None:
                with self._capability_preflight.retain_capture(
                    self._capture_capability, deadline
                ) as descriptor:
                    if type(descriptor) is not int or descriptor < 0:
                        raise IsolatedComponentCaptureError()
                    yielded = True
                    try:
                        yield descriptor
                    except BaseException:
                        body_failed = True
                        raise
                return
            before = self.capture_root.lstat()
            descriptor = os.open(
                self.capture_root,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
            )
            current = os.fstat(descriptor)
            after = self.capture_root.lstat()
            if (
                not stat.S_ISDIR(current.st_mode)
                or (before.st_dev, before.st_ino) != (current.st_dev, current.st_ino)
                or (after.st_dev, after.st_ino) != (current.st_dev, current.st_ino)
            ):
                raise IsolatedComponentCaptureError()
            yielded = True
            try:
                yield descriptor
            except BaseException:
                body_failed = True
                raise
            current = os.fstat(descriptor)
            after = self.capture_root.lstat()
            if (after.st_dev, after.st_ino) != (current.st_dev, current.st_ino):
                raise IsolatedComponentCaptureError()
        except (KeyboardInterrupt, SystemExit):
            raise
        except Exception:
            if yielded and not body_failed and exit_failure is not None:
                try:
                    exit_failure()
                except Exception:
                    pass
            raise IsolatedComponentCaptureError() from None
        finally:
            if self._capability_preflight is None and descriptor >= 0:
                try:
                    os.close(descriptor)
                except OSError:
                    pass

    def _id(self):
        try:
            value = self._id_factory()
        except Exception:
            raise IsolatedComponentCaptureError() from None
        if type(value) is not str or _HEX_ID.fullmatch(value) is None:
            raise IsolatedComponentCaptureError()
        return value

    @staticmethod
    def _journal_value(raw):
        try:
            value = json.loads(
                raw,
                object_pairs_hook=lambda pairs: _pairs(pairs),
                parse_float=lambda _value: (_ for _ in ()).throw(ValueError()),
                parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
            )
            if (
                type(value) is not dict
                or set(value)
                != {"schemaVersion", "captureGeneration", "state", "volumes"}
                or value["schemaVersion"] != 1
                or value["state"] != "capturing"
                or type(value["captureGeneration"]) is not str
                or _HEX_ID.fullmatch(value["captureGeneration"]) is None
                or type(value["volumes"]) is not list
                or not 1 <= len(value["volumes"]) <= 128
            ):
                raise ValueError()
            seen = set()
            for item in value["volumes"]:
                if (
                    type(item) is not dict
                    or set(item) != {"serviceId", "volumeId", "captureId", "directory"}
                    or type(item["serviceId"]) is not str
                    or type(item["volumeId"]) is not str
                    or not _CAPTURE_ID.fullmatch(item["serviceId"])
                    or not _CAPTURE_ID.fullmatch(item["volumeId"])
                    or type(item["captureId"]) is not str
                    or _HEX_ID.fullmatch(item["captureId"]) is None
                    or item["directory"] != item["captureId"]
                    or item["captureId"] in seen
                ):
                    raise ValueError()
                seen.add(item["captureId"])
            if _canonical(value) != raw:
                raise ValueError()
            return value
        except Exception:
            raise IsolatedComponentCaptureError() from None

    def _read_journal(self):
        try:
            return self._journal_value(
                private_read(self.journal_path, _MAX_JOURNAL_BYTES)
            )
        except FileNotFoundError:
            return None
        except IsolatedComponentCaptureError:
            raise
        except Exception:
            raise IsolatedComponentCaptureError() from None

    def _write_journal(self, value):
        raw = _canonical(value)
        if not 1 <= len(raw) <= _MAX_JOURNAL_BYTES:
            raise IsolatedComponentCaptureError()
        temporary = self.journal_path.parent / (
            "." + self.journal_path.name + "." + secrets.token_hex(16)
        )
        descriptor = None
        try:
            if self.journal_path.exists() or self.journal_path.is_symlink():
                raise IsolatedComponentCaptureError()
            descriptor = os.open(
                temporary,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o600,
            )
            offset = 0
            while offset < len(raw):
                count = os.write(descriptor, raw[offset:])
                if count <= 0:
                    raise OSError()
                offset += count
            os.fsync(descriptor)
            os.close(descriptor)
            descriptor = None
            os.replace(temporary, self.journal_path)
            sync_directory(self.journal_path.parent)
        except IsolatedComponentCaptureError:
            raise
        except Exception:
            raise IsolatedComponentCaptureError() from None
        finally:
            if descriptor is not None:
                try:
                    os.close(descriptor)
                except OSError:
                    pass
            try:
                if temporary.exists() or temporary.is_symlink():
                    temporary.unlink()
            except OSError:
                pass

    def _remove_journal(self):
        try:
            self.journal_path.unlink()
            sync_directory(self.journal_path.parent)
        except Exception:
            raise IsolatedComponentCaptureError() from None

    def _root_children(self, root_descriptor, deadline):
        children = []
        try:
            with os.scandir(root_descriptor) as entries:
                for entry in entries:
                    _remaining(deadline)
                    if type(entry.name) is not str:
                        raise IsolatedComponentCaptureError()
                    children.append(entry.name)
                    if len(children) > 1:
                        raise IsolatedComponentCaptureError()
        except IsolatedComponentCaptureError:
            raise
        except (OSError, TypeError, UnicodeError, ValueError):
            raise IsolatedComponentCaptureError() from None
        return tuple(children)

    @staticmethod
    def _open_generation(root_descriptor, generation_id):
        if type(generation_id) is not str or _HEX_ID.fullmatch(generation_id) is None:
            raise IsolatedComponentCaptureError()
        try:
            return os.open(
                generation_id,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=root_descriptor,
            )
        except Exception:
            raise IsolatedComponentCaptureError() from None

    def _cleanup_with_root(self, journal, deadline, root_descriptor):
        generation_id = journal["captureGeneration"]
        generation_descriptor = -1
        try:
            self._require_capability(deadline)
            try:
                generation_descriptor = self._open_generation(
                    root_descriptor, generation_id
                )
            except IsolatedComponentCaptureError:
                try:
                    os.stat(
                        generation_id,
                        dir_fd=root_descriptor,
                        follow_symlinks=False,
                    )
                except FileNotFoundError:
                    generation_descriptor = -1
                else:
                    raise
            if generation_descriptor >= 0:
                for item in reversed(journal["volumes"]):
                    _remaining(deadline)
                    self._require_capability(deadline)
                    try:
                        info = os.stat(
                            item["directory"],
                            dir_fd=generation_descriptor,
                            follow_symlinks=False,
                        )
                    except FileNotFoundError:
                        continue
                    if not stat.S_ISDIR(info.st_mode):
                        raise IsolatedComponentCaptureError()
                    self._backend.delete(
                        generation_descriptor, item["directory"], deadline
                    )
                    self._require_capability(deadline)
                os.close(generation_descriptor)
                generation_descriptor = -1
                self._require_capability(deadline)
                info = os.stat(
                    generation_id,
                    dir_fd=root_descriptor,
                    follow_symlinks=False,
                )
                if not stat.S_ISDIR(info.st_mode):
                    raise IsolatedComponentCaptureError()
                os.rmdir(generation_id, dir_fd=root_descriptor)
                os.fsync(root_descriptor)
            self._require_capability(deadline)
            self._remove_journal()
            return True
        except IsolatedComponentCaptureError:
            raise
        except Exception:
            raise IsolatedComponentCaptureError() from None
        finally:
            if generation_descriptor >= 0:
                try:
                    os.close(generation_descriptor)
                except OSError:
                    pass

    def _cleanup(self, journal, deadline):
        with self._held_capture(deadline) as root_descriptor:
            return self._cleanup_with_root(journal, deadline, root_descriptor)

    def recover(self, deadline):
        _remaining(deadline)
        self._require_capability(deadline)
        journal = self._read_journal()
        with self._held_capture(deadline) as root_descriptor:
            children = self._root_children(root_descriptor, deadline)
            if journal is None:
                if children:
                    raise IsolatedComponentCaptureError()
                return True
            if any(item != journal["captureGeneration"] for item in children):
                raise IsolatedComponentCaptureError()
            result = self._cleanup_with_root(journal, deadline, root_descriptor)
        if result:
            self._active_sources = None
        return result

    @staticmethod
    def _sources(sources):
        if type(sources) not in (tuple, list) or not 1 <= len(sources) <= 128:
            raise IsolatedComponentCaptureError()
        result = tuple(
            sorted(sources, key=lambda item: (item.service_id, item.volume_id))
        )
        keys = set()
        for source in result:
            try:
                info = source.path.lstat()
                key = (source.service_id, source.volume_id)
                if (
                    not _exact(source, ComponentVolumeSource)
                    or key in keys
                    or not stat.S_ISDIR(info.st_mode)
                    or (info.st_dev, info.st_ino) != (source.device, source.inode)
                ):
                    raise ValueError()
                keys.add(key)
            except Exception:
                raise IsolatedComponentCaptureError() from None
        return result

    def capture(self, sources, deadline):
        _remaining(deadline)
        self._require_capability(deadline)
        descriptors = []

        def abandon_unpublished_capture():
            self._active_sources = None
            while descriptors:
                descriptor = descriptors.pop()
                try:
                    os.close(descriptor)
                except OSError:
                    pass

        with self._held_capture(
            deadline, exit_failure=abandon_unpublished_capture
        ) as root_descriptor:
            if self._read_journal() is not None or self._root_children(
                root_descriptor, deadline
            ):
                raise IsolatedComponentCaptureError()
            selected = self._sources(sources)
            if self._active_sources is not None or any(
                not self._source_retained(source, deadline) for source in selected
            ):
                raise IsolatedComponentCaptureError()
            generation_id = self._id()
            identifiers = [self._id() for _ in selected]
            if len(set((generation_id, *identifiers))) != len(identifiers) + 1:
                raise IsolatedComponentCaptureError()
            journal = {
                "schemaVersion": 1,
                "captureGeneration": generation_id,
                "state": "capturing",
                "volumes": [
                    {
                        "serviceId": source.service_id,
                        "volumeId": source.volume_id,
                        "captureId": capture_id,
                        "directory": capture_id,
                    }
                    for source, capture_id in zip(selected, identifiers, strict=True)
                ],
            }
            self._require_capability(deadline)
            self._write_journal(journal)
            self._require_capability(deadline)
            captured = []
            generation_descriptor = -1
            try:
                self._require_capability(deadline)
                os.mkdir(generation_id, 0o700, dir_fd=root_descriptor)
                os.fsync(root_descriptor)
                generation_descriptor = self._open_generation(
                    root_descriptor, generation_id
                )
                self._require_capability(deadline)
                for source, capture_id in zip(selected, identifiers, strict=True):
                    _remaining(deadline)
                    self._require_capability(deadline)
                    if not self._source_retained(source, deadline):
                        raise IsolatedComponentCaptureError()
                    with self._held_source(source, deadline) as source_descriptor:
                        self._require_capability(deadline)
                        self._backend.create_read_only(
                            source_descriptor,
                            generation_descriptor,
                            capture_id,
                            deadline,
                        )
                        self._require_capability(deadline)
                    self._require_capability(deadline)
                    if not self._source_retained(source, deadline):
                        raise IsolatedComponentCaptureError()
                    if (
                        self._backend.is_read_only(
                            generation_descriptor, capture_id, deadline
                        )
                        is not True
                    ):
                        raise IsolatedComponentCaptureError()
                    descriptor = os.open(
                        capture_id,
                        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                        dir_fd=generation_descriptor,
                    )
                    descriptors.append(descriptor)
                    info = os.fstat(descriptor)
                    captured.append(
                        IsolatedComponentVolume(
                            source.service_id,
                            source.container_id,
                            source.volume_id,
                            source.service_version,
                            source.config_schema_version,
                            source.data_schema_version,
                            source.installation_revision,
                            source.device,
                            source.inode,
                            info.st_dev,
                            info.st_ino,
                            descriptor,
                            (source.container_id,),
                            1,
                            generation_id,
                            capture_id,
                        )
                    )
                values = tuple(captured)
                self._active_sources = selected
                if not self.revalidate(values, deadline):
                    raise IsolatedComponentCaptureError()
                return values
            except (KeyboardInterrupt, SystemExit):
                self._active_sources = None
                for descriptor in descriptors:
                    try:
                        os.close(descriptor)
                    except OSError:
                        pass
                raise
            except Exception:
                self._active_sources = None
                for descriptor in descriptors:
                    try:
                        os.close(descriptor)
                    except OSError:
                        pass
                if generation_descriptor >= 0:
                    try:
                        os.close(generation_descriptor)
                    except OSError:
                        pass
                    generation_descriptor = -1
                try:
                    self._cleanup_with_root(journal, deadline, root_descriptor)
                except Exception:
                    pass
                raise IsolatedComponentCaptureError() from None
            finally:
                if generation_descriptor >= 0:
                    try:
                        os.close(generation_descriptor)
                    except OSError:
                        pass

    def _matches_journal(self, capture, journal):
        if type(capture) not in (tuple, list) or not capture:
            return False
        expected = {
            (item["serviceId"], item["volumeId"], item["captureId"])
            for item in journal["volumes"]
        }
        return (
            len(capture) == len(expected)
            and all(_exact(item, IsolatedComponentVolume) for item in capture)
            and {(item.service_id, item.volume_id, item.capture_id) for item in capture}
            == expected
            and {item.capture_generation for item in capture}
            == {journal["captureGeneration"]}
        )

    def revalidate(self, capture, deadline):
        generation_descriptor = -1
        try:
            _remaining(deadline)
            self._require_capability(deadline)
            if self._capability_preflight is not None:
                if self._active_sources is None or any(
                    not self._source_retained(source, deadline)
                    for source in self._active_sources
                ):
                    return False
            journal = self._read_journal()
            if journal is None or not self._matches_journal(capture, journal):
                return False
            with self._held_capture(deadline) as root_descriptor:
                generation_descriptor = self._open_generation(
                    root_descriptor, journal["captureGeneration"]
                )
                for item in capture:
                    self._require_capability(deadline)
                    info = os.fstat(item.descriptor)
                    observed = os.stat(
                        item.capture_id,
                        dir_fd=generation_descriptor,
                        follow_symlinks=False,
                    )
                    if (
                        not stat.S_ISDIR(info.st_mode)
                        or (info.st_dev, info.st_ino)
                        != (item.snapshot_device, item.snapshot_inode)
                        or (observed.st_dev, observed.st_ino)
                        != (item.snapshot_device, item.snapshot_inode)
                        or self._backend.is_read_only(
                            generation_descriptor,
                            item.capture_id,
                            deadline,
                        )
                        is not True
                    ):
                        return False
            return True
        except Exception:
            return False
        finally:
            if generation_descriptor >= 0:
                try:
                    os.close(generation_descriptor)
                except OSError:
                    pass

    def release(self, capture, deadline):
        journal = None
        try:
            _remaining(deadline)
            journal = self._read_journal()
            if journal is None or not self._matches_journal(capture, journal):
                raise IsolatedComponentCaptureError()
        except Exception:
            journal = None
        finally:
            if type(capture) in (tuple, list):
                for item in capture:
                    descriptor = getattr(item, "descriptor", -1)
                    if type(descriptor) is int and descriptor >= 0:
                        try:
                            os.close(descriptor)
                        except OSError:
                            pass
        if journal is None:
            return False
        try:
            result = self._cleanup(journal, deadline)
            if result:
                self._active_sources = None
            return result
        except Exception:
            return False


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if type(key) is not str or key in result:
            raise ValueError()
        result[key] = value
    return result


class AuthorityBoundIsolatedCapture:
    """Validate and own one native read-only/COW capture lease."""

    def __init__(self, engine):
        if any(
            not hasattr(engine, name) or not callable(getattr(engine, name))
            for name in ("capture", "revalidate", "release")
        ):
            raise IsolatedComponentCaptureError()
        self._engine = engine

    @staticmethod
    def _validate(sources, capture):
        if (
            type(sources) not in (tuple, list)
            or type(capture) not in (tuple, list)
            or not sources
            or len(sources) != len(capture)
            or len(sources) > 128
        ):
            raise IsolatedComponentCaptureError()
        expected = {}
        for source in sources:
            if not _exact(source, ComponentVolumeSource):
                raise IsolatedComponentCaptureError()
            key = (source.service_id, source.volume_id)
            if key in expected:
                raise IsolatedComponentCaptureError()
            expected[key] = source

        selected = []
        capture_ids = set()
        capture_generations = set()
        snapshot_identities = set()
        descriptors = set()
        for value in capture:
            if not _exact(value, IsolatedComponentVolume):
                raise IsolatedComponentCaptureError()
            source = expected.get((value.service_id, value.volume_id))
            try:
                info = os.fstat(value.descriptor)
                flags = fcntl.fcntl(value.descriptor, fcntl.F_GETFL)
                fd_flags = fcntl.fcntl(value.descriptor, fcntl.F_GETFD)
            except (OSError, TypeError, ValueError):
                raise IsolatedComponentCaptureError() from None
            if (
                source is None
                or (
                    value.container_id,
                    value.service_version,
                    value.config_schema_version,
                    value.data_schema_version,
                    value.installation_revision,
                    value.source_device,
                    value.source_inode,
                )
                != (
                    source.container_id,
                    source.service_version,
                    source.config_schema_version,
                    source.data_schema_version,
                    source.installation_revision,
                    source.device,
                    source.inode,
                )
                or type(value.descriptor) is not int
                or value.descriptor < 0
                or not stat.S_ISDIR(info.st_mode)
                or (info.st_dev, info.st_ino)
                != (value.snapshot_device, value.snapshot_inode)
                or (value.snapshot_device, value.snapshot_inode)
                == (value.source_device, value.source_inode)
                or flags & os.O_ACCMODE != os.O_RDONLY
                or not fd_flags & fcntl.FD_CLOEXEC
                or value.writer_container_ids != (value.container_id,)
                or type(value.capture_version) is not int
                or value.capture_version != 1
                or type(value.capture_generation) is not str
                or _CAPTURE_GENERATION.fullmatch(value.capture_generation) is None
                or type(value.capture_id) is not str
                or _CAPTURE_ID.fullmatch(value.capture_id) is None
                or value.capture_id in capture_ids
                or (value.snapshot_device, value.snapshot_inode) in snapshot_identities
                or value.descriptor in descriptors
            ):
                raise IsolatedComponentCaptureError()
            capture_ids.add(value.capture_id)
            capture_generations.add(value.capture_generation)
            snapshot_identities.add((value.snapshot_device, value.snapshot_inode))
            descriptors.add(value.descriptor)
            selected.append(value)
        if (
            set(expected) != {(item.service_id, item.volume_id) for item in selected}
            or len(capture_generations) != 1
        ):
            raise IsolatedComponentCaptureError()
        return tuple(
            sorted(selected, key=lambda item: (item.service_id, item.volume_id))
        )

    @contextmanager
    def acquire(self, sources, deadline):
        _remaining(deadline)
        capture = None
        active_error = False
        try:
            try:
                ordered = tuple(
                    sorted(sources, key=lambda item: (item.service_id, item.volume_id))
                )
                capture = self._engine.capture(ordered, deadline)
                selected = self._validate(ordered, capture)
                _remaining(deadline)
                if self._engine.revalidate(selected, deadline) is not True:
                    raise IsolatedComponentCaptureError()
            except IsolatedComponentCaptureError:
                raise
            except Exception:
                raise IsolatedComponentCaptureError() from None
            yield selected
            _remaining(deadline)
            try:
                if self._engine.revalidate(selected, deadline) is not True:
                    raise IsolatedComponentCaptureError()
            except IsolatedComponentCaptureError:
                raise
            except Exception:
                raise IsolatedComponentCaptureError() from None
        except BaseException:
            active_error = True
            raise
        finally:
            release_failed = False
            if capture is not None:
                try:
                    release_deadline = time.monotonic() + 2
                    if self._engine.release(capture, release_deadline) is not True:
                        release_failed = True
                except Exception:
                    release_failed = True
            if release_failed and not active_error:
                raise IsolatedComponentCaptureError()
