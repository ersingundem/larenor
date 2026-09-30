"""Standalone Unmanic encoder for individually authorized archive work files.

Packaged as plugin.py using only the standard library. A library scan cannot
authorize a job: only a signed, bounded plan created after confirmation can.
"""

import hashlib
import hmac
import json
import os
from pathlib import Path
import stat
import time


class ArchiveEncoderError(RuntimeError):
    def __init__(self, code="archive_encoder_unavailable"):
        self.code = code if code in {"archive_encoder_unavailable", "archive_encoder_config_invalid",
            "archive_encoder_plan_invalid", "archive_encoder_input_invalid", "archive_encoder_output_invalid"} else "archive_encoder_unavailable"
        super().__init__(self.code)


def _check(value):
    if not value:
        raise ArchiveEncoderError()


def _canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def _unique(pairs):
    value = {}
    for key, item in pairs:
        _check(key not in value)
        value[key] = item
    return value


def _absolute(value):
    _check(type(value) is str and 1 <= len(value) <= 4096
           and all(ord(char) >= 32 and ord(char) != 127 for char in value))
    path = Path(value)
    _check(path.is_absolute() and ".." not in path.parts
           and str(path) == value and path != Path("/"))
    return path


def _owned(path, *, directory=False, private=False, missing=False):
    path = _absolute(str(path))
    for parent in reversed((path, *path.parents)):
        # Unmanic creates its per-task cache directory only after the runner
        # returns its argv. Validate every existing ancestor without creating
        # that directory here; the caller already bound the path to cacheRoot.
        if missing and not os.path.lexists(parent):
            continue
        info = parent.lstat()
        _check(not stat.S_ISLNK(info.st_mode) and info.st_uid in {0, os.geteuid()}
               and (not info.st_mode & 0o022
                    or info.st_uid == 0 and info.st_mode & stat.S_ISVTX))
        if parent != path:
            _check(stat.S_ISDIR(info.st_mode))
        else:
            _check(stat.S_ISDIR(info.st_mode) if directory else
                   stat.S_ISREG(info.st_mode) and info.st_nlink == 1)
            if private:
                _check(info.st_uid == os.geteuid()
                       and stat.S_IMODE(info.st_mode) == (0o700 if directory else 0o600))
    return path


def _file(path, maximum):
    path = _owned(path, private=True)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        _check(info.st_uid == os.geteuid() and stat.S_IMODE(info.st_mode) == 0o600
               and stat.S_ISREG(info.st_mode) and info.st_nlink == 1)
        value = stream.read(maximum + 1)
    _check(len(value) <= maximum)
    return value


def _identity(info):
    return [info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns]


def _key(key):
    _check(type(key) is bytes and len(key) == 32)
    return hmac.new(key, b"larenor-archive-encoder-plan-v1", hashlib.sha256).digest()


def _signature(key, plan):
    return hmac.new(_key(key), _canonical(plan), hashlib.sha256).hexdigest()


def _digest(value, length):
    _check(type(value) is str and len(value) == length
           and all(char in "0123456789abcdef" for char in value))


def _plan(path, work_root, key, *, now=None):
    path = _owned(path, private=True)
    relative = path.relative_to(work_root)
    _check(len(relative.parts) == 2)
    operation = relative.parts[0]
    _digest(operation, 32)
    _check(path.name.startswith("media.") and path.suffix.lower() in {".mkv", ".mp4", ".mov", ".avi", ".webm", ".m4v", ".ts"})
    envelope = json.loads(_file(path.parent / "transcode-plan.json", 8192), object_pairs_hook=_unique)
    _check(type(envelope) is dict and set(envelope) == {"plan", "signature"})
    plan = envelope["plan"]
    _check(type(plan) is dict and set(plan) == {
        "schemaVersion", "operationId", "commandDigest", "workPath", "workIdentity",
        "inputDigest", "inputBytes", "targetCodec", "targetBitrate", "createdAt", "expiresAt"})
    _digest(envelope["signature"], 64)
    _check(hmac.compare_digest(envelope["signature"], _signature(key, plan)))
    _digest(plan["commandDigest"], 64)
    _digest(plan["inputDigest"], 64)
    instant = time.time() if now is None else now
    _check(type(plan["schemaVersion"]) is int and plan["schemaVersion"] == 1
           and plan["operationId"] == operation and plan["workPath"] == str(path)
           and type(plan["inputBytes"]) is int and 0 < plan["inputBytes"] <= 10 * 1024**4
           and type(plan["targetBitrate"]) is int and 0 < plan["targetBitrate"] <= 1_000_000_000
           and plan["targetCodec"] in {"hevc", "av1"}
           and type(plan["createdAt"]) is int and type(plan["expiresAt"]) is int
           and 1 <= plan["createdAt"] <= instant < plan["expiresAt"] <= 253402300799
           and plan["expiresAt"] - plan["createdAt"] <= 6 * 60 * 60
           and type(plan["workIdentity"]) is list and len(plan["workIdentity"]) == 5
           and all(type(value) is int and value >= 0 for value in plan["workIdentity"])
           and _identity(path.stat()) == plan["workIdentity"]
           and path.stat().st_size == plan["inputBytes"])
    return plan


def _configured():
    path = os.environ.get("LARENOR_UNMANIC_ENCODER_CONFIG", "/config/larenor/archive-encoder.json")
    value = json.loads(_file(path, 4096), object_pairs_hook=_unique)
    _check(type(value) is dict and set(value) == {"schemaVersion", "workRoot", "cacheRoot", "keyFile", "ffmpeg"}
           and type(value["schemaVersion"]) is int and value["schemaVersion"] == 1)
    work = _owned(_absolute(value["workRoot"]), directory=True, private=True)
    cache = _owned(_absolute(value["cacheRoot"]), directory=True, private=True)
    _check(work != cache and work not in cache.parents and cache not in work.parents)
    # The private administrator config pins an explicit executable; resolve
    # package-manager symlinks as the Core verifier does, without PATH lookup.
    binary = _absolute(value["ffmpeg"]).resolve(strict=True)
    info = binary.stat()
    _check(stat.S_ISREG(info.st_mode) and info.st_uid in {0, os.geteuid()}
           and not info.st_mode & 0o022 and os.access(binary, os.X_OK))
    key = _file(value["keyFile"], 32)
    _key(key)
    return work, cache, key, str(binary)


def on_library_management_file_test(data):
    """An unsigned file never enters the encoder's pending queue."""
    try:
        _check(type(data) is dict)
        work, _cache, key, _binary = _configured()
        _plan(_absolute(data.get("path")), work, key)
        data["add_file_to_pending_tasks"] = True
    except Exception:
        data["add_file_to_pending_tasks"] = False
        if type(data.get("issues")) is list:
            data["issues"].append("archive_encoder_unavailable")
    return data


def on_worker_process(data):
    """Emit an argv, never a shell command, after validating the copied input."""
    try:
        return _worker(data)
    except ArchiveEncoderError:
        raise
    except Exception:
        raise ArchiveEncoderError() from None


def _worker(data):
    # A failed authorization must fail the task rather than allow an empty
    # worker flow to move an unmodified copy as an apparently successful job.
    _check(type(data) is dict)
    try:
        work, cache, key, binary = _configured()
    except Exception:
        raise ArchiveEncoderError('archive_encoder_config_invalid') from None
    try:
        plan = _plan(_absolute(data.get("original_file_path")), work, key)
    except Exception:
        raise ArchiveEncoderError('archive_encoder_plan_invalid') from None
    try:
        source = _owned(_absolute(data.get("file_in")))
    except Exception:
        raise ArchiveEncoderError('archive_encoder_input_invalid') from None
    try:
        destination = _absolute(data.get("file_out"))
        _check(cache in destination.parents)
        destination = _owned(destination, missing=True)
    except Exception:
        raise ArchiveEncoderError('archive_encoder_output_invalid') from None
    _check((source == Path(plan["workPath"]) or cache in source.parents)
           and cache in destination.parents and source != destination
           and destination.suffix.lower() == Path(plan["workPath"]).suffix.lower())
    descriptor = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as stream:
        before = os.fstat(stream.fileno())
        _check(stat.S_ISREG(before.st_mode) and before.st_nlink == 1
               and before.st_size == plan["inputBytes"])
        digest = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
        _check(_identity(before) == _identity(os.fstat(stream.fileno()))
               and _identity(before) == _identity(source.stat())
               and hmac.compare_digest(digest.hexdigest(), plan["inputDigest"]))
    codec = "libx265" if plan["targetCodec"] == "hevc" else "libsvtav1"
    command = [binary, "-v", "error", "-nostdin", "-n", "-i", str(source),
               "-map", "0", "-c", "copy", "-c:v", codec,
               "-b:v", str(plan["targetBitrate"]), "-threads", "2"]
    if codec == "libx265":
        command.extend(["-x265-params", "pools=1:frame-threads=1:log-level=error"])
    else:
        command.extend(["-svtav1-params", "lp=2"])
    command.append(str(destination))
    data["exec_command"] = command
    data["command_progress_parser"] = None
    data["repeat"] = False
    return data
