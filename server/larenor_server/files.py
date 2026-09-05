"""Private local files. Existing permissions/keys are never silently replaced."""

import os
from pathlib import Path
import stat

from .errors import StartupError


def checked_path(path: Path) -> Path:
    if not path.is_absolute() or ".." in path.parts or path == Path("/"):
        raise StartupError("invalid_storage_path")
    if any(parent.is_symlink() for parent in (path, *path.parents)):
        raise StartupError("symlink_storage_path")
    return path


def private_directory(path: Path) -> None:
    checked_path(path)
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = path.stat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid()
            or stat.S_IMODE(info.st_mode) != 0o700):
        raise StartupError("storage_directory_not_private")
    for parent in path.parents:
        ancestor = parent.stat()
        sticky_root = ancestor.st_uid == 0 and ancestor.st_mode & stat.S_ISVTX
        if (ancestor.st_uid not in (0, os.geteuid()) or
                (ancestor.st_mode & 0o022 and not sticky_root)):
            raise StartupError("storage_parent_not_trusted")


def private_read(path: Path, maximum: int) -> bytes:
    checked_path(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
            raise StartupError("storage_file_not_private")
        value = stream.read(maximum + 1)
        if len(value) > maximum:
            raise StartupError("invalid_storage_file")
        return value


def sync_directory(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def private_create(path: Path, value: bytes) -> None:
    checked_path(path)
    private_directory(path.parent)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(value)
        stream.flush()
        os.fsync(stream.fileno())
    sync_directory(path.parent)
