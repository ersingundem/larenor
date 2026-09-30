#!/usr/bin/env python3
"""Initialize or verify the one fixed host installation journal set.

Initialization is an explicit activation effect.  A durable intent permits a
crash between the three first creations; once the authenticated set receipt is
published, a missing or replaced journal is never regenerated.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
from contextlib import ExitStack
from pathlib import Path
import stat
import sys

from larenor_server.plugins.installation_runtime import load_policy
from larenor_server.plugins.managed_container import ManagedWorkerJournal
from larenor_server.plugins.resource_journal import ResourceJournal
from larenor_server.plugins.volume_create_journal import VolumeCreateJournal


POLICY = Path("/etc/larenor-server/host-workers/root/installation.json")
STATE_ROOT = Path("/var/lib/larenor-server/host-workers/installation")
EXPECTED_JOURNALS = {
    "resources": STATE_ROOT / "resources",
    "volumes": STATE_ROOT / "volumes",
    "containers": STATE_ROOT / "containers",
}
EXPECTED_DOCKER_SOCKET = Path("/var/run/docker.sock")
EXPECTED_DOCKER_UID = 0
MAX_FILE_BYTES = 16 * 1024
DOMAIN = "larenor-installation-journal-set-v1"


class JournalSetError(RuntimeError):
    def __init__(self):
        super().__init__("installation_journal_set_invalid")


def _canonical(value):
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("ascii")


def _pairs(values):
    result = {}
    for key, value in values:
        if key in result:
            raise ValueError()
        result[key] = value
    return result


def _identity(info):
    return (
        info.st_dev,
        info.st_ino,
        info.st_uid,
        info.st_gid,
        stat.S_IFMT(info.st_mode),
        stat.S_IMODE(info.st_mode),
        info.st_nlink,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


def _root_state(root):
    info = root.lstat()
    if (
        not stat.S_ISDIR(info.st_mode)
        or stat.S_ISLNK(info.st_mode)
        or info.st_uid != os.geteuid()
        or stat.S_IMODE(info.st_mode) != 0o700
    ):
        raise JournalSetError()


def _read(path):
    descriptor = -1
    try:
        descriptor = os.open(
            path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
        )
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != os.geteuid()
            or stat.S_IMODE(before.st_mode) != 0o600
            or before.st_nlink != 1
            or not 1 <= before.st_size <= MAX_FILE_BYTES
        ):
            raise JournalSetError()
        raw = bytearray()
        while len(raw) <= MAX_FILE_BYTES:
            part = os.read(descriptor, min(4096, MAX_FILE_BYTES + 1 - len(raw)))
            if not part:
                break
            raw.extend(part)
        after = os.fstat(descriptor)
        current = path.lstat()
        if (
            len(raw) != before.st_size
            or _identity(before) != _identity(after)
            or _identity(after) != _identity(current)
        ):
            raise JournalSetError()
        return bytes(raw)
    except JournalSetError:
        raise
    except Exception:
        raise JournalSetError() from None
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _decode(raw, expected):
    try:
        value = json.loads(
            raw.decode("ascii"),
            object_pairs_hook=_pairs,
            parse_float=lambda _value: (_ for _ in ()).throw(ValueError()),
            parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
        )
        if type(value) is not dict or set(value) != set(expected):
            raise ValueError()
        return value
    except Exception:
        raise JournalSetError() from None


def _intent_value():
    body = {
        "schemaVersion": 1,
        "domain": DOMAIN,
        "state": "initializing",
        "journals": {name: str(path) for name, path in EXPECTED_JOURNALS.items()},
    }
    return body | {"digest": hashlib.sha256(_canonical(body)).hexdigest()}


def _receipt_value(identities):
    body = {
        "schemaVersion": 1,
        "domain": DOMAIN,
        "state": "ready",
        "journals": dict(sorted(identities.items())),
    }
    return body | {"digest": hashlib.sha256(_canonical(body)).hexdigest()}


def _validate_envelope(value, expected_state):
    try:
        if (
            type(value.get("schemaVersion")) is not int
            or value["schemaVersion"] != 1
            or value.get("domain") != DOMAIN
            or value.get("state") != expected_state
            or type(value.get("digest")) is not str
            or len(value["digest"]) != 64
        ):
            raise ValueError()
        body = dict(value)
        digest = body.pop("digest")
        if hashlib.sha256(_canonical(body)).hexdigest() != digest:
            raise ValueError()
    except Exception:
        raise JournalSetError() from None


def _write_atomic(path, value):
    temporary = path.with_name("." + path.name + ".new")
    descriptor = -1
    try:
        if temporary.exists() or temporary.is_symlink():
            info = temporary.lstat()
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_uid != os.geteuid()
                or stat.S_IMODE(info.st_mode) != 0o600
                or info.st_nlink != 1
            ):
                raise JournalSetError()
            temporary.unlink()
        raw = _canonical(value)
        descriptor = os.open(
            temporary,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | os.O_NOFOLLOW
            | os.O_CLOEXEC,
            0o600,
        )
        if os.write(descriptor, raw) != len(raw):
            raise OSError()
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        os.replace(temporary, path)
        parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
        try:
            os.fsync(parent)
        finally:
            os.close(parent)
    except JournalSetError:
        raise
    except Exception:
        raise JournalSetError() from None
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        temporary.unlink(missing_ok=True)


def _policy():
    try:
        value = load_policy(POLICY)
        observed = {
            "resources": value.resource_journal,
            "volumes": value.volume_journal,
            "containers": value.container_journal,
        }
        if (
            observed != EXPECTED_JOURNALS
            or Path(value.endpoint.path) != EXPECTED_DOCKER_SOCKET
            or value.endpoint.owner_uid != EXPECTED_DOCKER_UID
        ):
            raise ValueError()
        return value
    except Exception:
        raise JournalSetError() from None


def _open_journals(*, initialize_missing):
    classes = {
        "resources": ResourceJournal,
        "volumes": VolumeCreateJournal,
        "containers": ManagedWorkerJournal,
    }
    resources = ExitStack()
    identities = {}
    try:
        for name in ("resources", "volumes", "containers"):
            path = EXPECTED_JOURNALS[name]
            missing = not path.exists() and not path.is_symlink()
            if missing and not initialize_missing:
                raise JournalSetError()
            journal = resources.enter_context(
                classes[name](path, initialize=missing and initialize_missing)
            )
            identities[name] = journal.identity
        return resources, identities
    except Exception:
        resources.close()
        raise JournalSetError() from None


def _receipt(path, identities):
    value = _decode(
        _read(path),
        {"schemaVersion", "domain", "state", "journals", "digest"},
    )
    _validate_envelope(value, "ready")
    if value["journals"] != dict(sorted(identities.items())):
        raise JournalSetError()


def _valid_intent(path):
    value = _decode(
        _read(path),
        {"schemaVersion", "domain", "state", "journals", "digest"},
    )
    _validate_envelope(value, "initializing")
    if value != _intent_value():
        raise JournalSetError()


def _lock(root):
    path = root / ".journal-set.lock"
    descriptor = os.open(
        path,
        os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC,
        0o600,
    )
    try:
        info = os.fstat(descriptor)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.geteuid()
            or stat.S_IMODE(info.st_mode) != 0o600
            or info.st_nlink != 1
        ):
            raise JournalSetError()
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        return descriptor
    except Exception:
        os.close(descriptor)
        raise JournalSetError() from None


def verify():
    _policy()
    _root_state(STATE_ROOT)
    descriptor = _lock(STATE_ROOT)
    resources = None
    try:
        resources, identities = _open_journals(initialize_missing=False)
        _receipt(STATE_ROOT / "journal-set.json", identities)
        return True
    finally:
        if resources is not None:
            resources.close()
        os.close(descriptor)


def initialize():
    _policy()
    _root_state(STATE_ROOT)
    descriptor = _lock(STATE_ROOT)
    resources = None
    intent = STATE_ROOT / "journal-set.intent.json"
    receipt = STATE_ROOT / "journal-set.json"
    try:
        if receipt.exists() or receipt.is_symlink():
            resources, identities = _open_journals(initialize_missing=False)
            _receipt(receipt, identities)
            if intent.exists() or intent.is_symlink():
                _valid_intent(intent)
                intent.unlink()
            return True

        existence = {
            name: path.exists() or path.is_symlink()
            for name, path in EXPECTED_JOURNALS.items()
        }
        if intent.exists() or intent.is_symlink():
            _valid_intent(intent)
            allow_missing = True
        elif any(existence.values()) and not all(existence.values()):
            raise JournalSetError()
        elif not any(existence.values()):
            _write_atomic(intent, _intent_value())
            allow_missing = True
        else:
            # Adopt a complete, strictly validated pre-package journal set.
            allow_missing = False

        resources, identities = _open_journals(initialize_missing=allow_missing)
        _write_atomic(receipt, _receipt_value(identities))
        if intent.exists() or intent.is_symlink():
            _valid_intent(intent)
            intent.unlink()
        return True
    finally:
        if resources is not None:
            resources.close()
        os.close(descriptor)


def main(argv=None):
    values = sys.argv[1:] if argv is None else list(argv)
    if values not in (["initialize"], ["verify"]):
        print("invalid_arguments", file=sys.stderr)
        return 2
    try:
        if values[0] == "initialize":
            initialize()
        else:
            verify()
        return 0
    except Exception:
        print("installation_journal_set_invalid", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
