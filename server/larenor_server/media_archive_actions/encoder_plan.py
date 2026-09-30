"""Publish a signed encoder plan only for protected, confirmed staged media."""

import hmac
import os
from pathlib import Path
import time

from .encoder_plugin import (
    ArchiveEncoderError, _canonical, _identity, _key, _owned, _plan, _signature,
)
from .file_store import ArchiveStagedFiles
from .journal import action_command_digest
from .models import PrivateArchiveActionCommand


class SignedArchiveTranscodePlanWriter:
    def __init__(self, work_root, key, *, clock=None):
        self.root = _owned(Path(work_root), directory=True, private=True)
        _key(key)
        self.key, self.clock = key, clock or time.time

    def __repr__(self):
        return "SignedArchiveTranscodePlanWriter(<private>)"

    def __call__(self, command, staged, *, deadline):
        try:
            if (type(command) is not PrivateArchiveActionCommand
                    or type(staged) is not ArchiveStagedFiles
                    or command.operation != "stage_transcode"
                    or command.operationId != staged.operationId
                    or not hmac.compare_digest(action_command_digest(command), staged.commandDigest)
                    or staged.source.byteLength != command.target.sourceSizeBytes
                    or time.monotonic() >= deadline):
                raise ValueError()
            path = _owned(Path(staged.workPath), private=True)
            if (path.parent.parent != self.root or path.parent.name != command.operationId
                    or path.stat().st_size != staged.source.byteLength):
                raise ValueError()
            now = int(self.clock())
            plan = {
                "schemaVersion": 1, "operationId": command.operationId,
                "commandDigest": staged.commandDigest, "workPath": str(path),
                "workIdentity": _identity(path.stat()), "inputDigest": staged.source.sha256,
                "inputBytes": staged.source.byteLength, "targetCodec": command.target.targetCodec,
                "targetBitrate": command.target.targetBitrate, "createdAt": now,
                "expiresAt": now + 6 * 60 * 60,
            }
            manifest = path.parent / "transcode-plan.json"
            if os.path.lexists(manifest):
                previous = _plan(path, self.root, self.key, now=now)
                if any(previous[field] != plan[field] for field in plan if field not in {"createdAt", "expiresAt"}):
                    raise ValueError()
                return
            descriptor = os.open(manifest, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(_canonical({"plan": plan, "signature": _signature(self.key, plan)}))
                stream.flush()
                os.fsync(stream.fileno())
            descriptor = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            _plan(path, self.root, self.key, now=now)
            if time.monotonic() >= deadline:
                raise ValueError()
        except Exception:
            raise ArchiveEncoderError() from None
