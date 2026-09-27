"""Durable volume rollback leases for schema-changing component updates."""

from dataclasses import fields
import hashlib
import math
import re
import time

from .component_linux_restore import LinuxDirectoryRestoreEngine
from .component_restore import ComponentRestoreVolumeTarget
from .component_snapshot_provider import ComponentVolumeSource
from .component_update_rollback_models import (
    ComponentUpdateRollbackError,
    ComponentUpdateRollbackReceipt,
)


_HEX_ID = re.compile(r"[0-9a-f]{32}\Z")
_SERVICE_ID = re.compile(r"[a-z][a-z0-9_]{0,31}\Z")
_VOLUME_ID = re.compile(r"[a-z][a-z0-9-]{0,31}\Z")


def _exact(value, kind):
    return type(value) is kind and set(vars(value)) == {
        item.name for item in fields(kind)
    }


def _active(deadline):
    if (
        type(deadline) not in (int, float)
        or type(deadline) is bool
        or not math.isfinite(deadline)
        or time.monotonic() >= deadline
    ):
        raise ComponentUpdateRollbackError()


class ComponentUpdateRollbackLease:
    def __init__(self, engine, leases, receipts):
        self._engine = engine
        self._leases = leases
        self.receipts = receipts
        self._closed = False

    def restore(self, deadline):
        if self._closed:
            raise ComponentUpdateRollbackError()
        try:
            for lease in self._leases:
                self._engine.restore_rollback(lease, deadline)
            return True
        except Exception:
            raise ComponentUpdateRollbackError() from None

    def discard(self, deadline):
        if self._closed:
            raise ComponentUpdateRollbackError()
        try:
            for lease in self._leases:
                self._engine.discard_rollback(lease, deadline)
            self.close()
            return True
        except Exception:
            raise ComponentUpdateRollbackError() from None

    def close(self):
        if not self._closed:
            self._engine.close(self._leases)
            self._closed = True


class ComponentUpdateRollbackStore:
    """Create and reopen exact update-owned rollback archives."""

    def __init__(self, engine=None):
        try:
            self._engine = engine or LinuxDirectoryRestoreEngine()
            if type(self._engine) is not LinuxDirectoryRestoreEngine:
                raise ValueError()
        except Exception:
            raise ComponentUpdateRollbackError() from None

    @staticmethod
    def _sources(update_id, sources, receipts=None):
        if (
            type(update_id) is not str
            or _HEX_ID.fullmatch(update_id) is None
            or type(sources) not in (tuple, list)
            or not 1 <= len(sources) <= 3
            or any(type(item) is not ComponentVolumeSource for item in sources)
        ):
            raise ComponentUpdateRollbackError()
        selected = tuple(sorted(sources, key=lambda item: item.volume_id))
        if (
            len({item.volume_id for item in selected}) != len(selected)
            or len({item.service_id for item in selected}) != 1
            or any(
                _SERVICE_ID.fullmatch(item.service_id) is None
                or _VOLUME_ID.fullmatch(item.volume_id) is None
                for item in selected
            )
        ):
            raise ComponentUpdateRollbackError()
        by_volume = {}
        if receipts is not None:
            if (
                type(receipts) not in (tuple, list)
                or len(receipts) != len(selected)
                or any(
                    not _exact(item, ComponentUpdateRollbackReceipt)
                    for item in receipts
                )
            ):
                raise ComponentUpdateRollbackError()
            by_volume = {item.volume_id: item for item in receipts}
            if len(by_volume) != len(receipts):
                raise ComponentUpdateRollbackError()
        pairs = []
        for source in selected:
            receipt = by_volume.get(source.volume_id)
            binding_id = hashlib.sha256(
                (
                    "larenor-component-update-rollback-v1\0"
                    + update_id
                    + "\0"
                    + source.service_id
                    + "\0"
                    + source.volume_id
                    + "\0"
                    + str(source.installation_revision)
                ).encode("ascii")
            ).hexdigest()
            pairs.append(
                (
                    source,
                    ComponentRestoreVolumeTarget(
                        resource_id="component-" + source.volume_id,
                        volume_id=source.volume_id,
                        binding_id=binding_id,
                        binding_revision=source.installation_revision,
                        byte_length=1 if receipt is None else receipt.byte_length,
                        sha256="0" * 64 if receipt is None else receipt.sha256,
                    ),
                )
            )
        return tuple(pairs)

    def prepare(self, update_id, sources, deadline):
        _active(deadline)
        leases = ()
        captured = []
        try:
            pairs = self._sources(update_id, sources)
            leases = self._engine.acquire(
                pairs, update_id, deadline, namespace="update"
            )
            for lease in leases:
                byte_length, sha256 = self._engine.capture_rollback(lease, deadline)
                captured.append(
                    ComponentUpdateRollbackReceipt(
                        volume_id=lease.source.volume_id,
                        byte_length=byte_length,
                        sha256=sha256,
                    )
                )
            return ComponentUpdateRollbackLease(
                self._engine, leases, tuple(captured)
            )
        except Exception:
            for lease in leases:
                try:
                    if lease.rollback is not None:
                        self._engine.discard_rollback(lease, deadline)
                except Exception:
                    pass
            self._engine.close(leases)
            raise ComponentUpdateRollbackError() from None

    def recover(self, update_id, sources, receipts, deadline):
        _active(deadline)
        leases = ()
        try:
            pairs = self._sources(update_id, sources, receipts)
            ordered = tuple(pair[1] for pair in pairs)
            leases = self._engine.acquire(
                pairs, update_id, deadline, namespace="update"
            )
            recovered = []
            for lease, target in zip(leases, ordered, strict=True):
                rollback = (target.byte_length, target.sha256)
                self._engine.adopt_rollback(lease, rollback, deadline)
                recovered.append(
                    ComponentUpdateRollbackReceipt(
                        lease.source.volume_id, *rollback
                    )
                )
            return ComponentUpdateRollbackLease(
                self._engine, leases, tuple(recovered)
            )
        except Exception:
            self._engine.close(leases)
            raise ComponentUpdateRollbackError() from None
