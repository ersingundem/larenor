"""Durable v3 recovery journal for cross-resource component restores."""

import fcntl
import hashlib
import hmac
import json
import math
import os
from pathlib import Path
import re
import secrets
import stat
import time

from ..files import (
    checked_path,
    private_create,
    private_directory,
    private_read,
    sync_directory,
)
from .component_restore import (
    ComponentRestoreBatchReceipt,
    ComponentRestoreBoundary,
    ComponentRestoreCoordinator,
    ComponentRestorePlan,
    ComponentRestorePlanError,
    ComponentRestoreRollbackReceipt,
    ComponentRestoreStageReceipt,
    _exact,
    _plan_matches_capture,
)


_IDENTITY = re.compile(r"[0-9a-f]{32}\Z")
_DIGEST = re.compile(r"[0-9a-f]{64}\Z")
_PHASES = {
    "acquiring",
    "acquired",
    "quiesced",
    "rollback_snapshots",
    "staging",
    "pre_commit",
    "committed",
    "rolled_back",
    "released",
}
_MAX_JOURNAL_BYTES = 256 * 1024


def _canonical(value):
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
    ).encode("ascii")


def _pairs(values):
    result = {}
    for key, value in values:
        if type(key) is not str or key in result:
            raise ValueError()
        result[key] = value
    return result


def _plan_payload(plan):
    if not _exact(plan, ComponentRestorePlan):
        raise ComponentRestorePlanError()
    plan.__post_init__()
    return {
        "snapshotId": plan.snapshot_id,
        "totalByteLength": plan.total_byte_length,
        "targets": [
            {
                "serviceId": target.service_id,
                "installationId": target.installation_id,
                "serviceVersion": target.service_version,
                "configSchemaVersion": target.config_schema_version,
                "dataSchemaVersion": target.data_schema_version,
                "installationRevision": target.installation_revision,
                "volumes": [
                    {
                        "resourceId": volume.resource_id,
                        "volumeId": volume.volume_id,
                        "bindingId": volume.binding_id,
                        "bindingRevision": volume.binding_revision,
                        "byteLength": volume.byte_length,
                        "sha256": volume.sha256,
                    }
                    for volume in target.volumes
                ],
            }
            for target in plan.targets
        ],
    }


def _plan_digest(plan):
    return hashlib.sha256(_canonical(_plan_payload(plan))).hexdigest()


def _rollback_payload(value):
    return {
        "resourceId": value.resource_id,
        "bindingId": value.binding_id,
        "bindingRevision": value.binding_revision,
        "receiptId": value.receipt_id,
        "byteLength": value.byte_length,
        "sha256": value.sha256,
    }


def _stage_payload(value):
    return {
        "resourceId": value.resource_id,
        "bindingId": value.binding_id,
        "bindingRevision": value.binding_revision,
        "rollbackReceiptId": value.rollback_receipt_id,
        "stageId": value.stage_id,
        "byteLength": value.byte_length,
        "sha256": value.sha256,
    }


def _rollback(value):
    if type(value) is not dict or set(value) != {
        "resourceId",
        "bindingId",
        "bindingRevision",
        "receiptId",
        "byteLength",
        "sha256",
    }:
        raise ComponentRestorePlanError()
    return ComponentRestoreRollbackReceipt(
        resource_id=value["resourceId"],
        binding_id=value["bindingId"],
        binding_revision=value["bindingRevision"],
        receipt_id=value["receiptId"],
        byte_length=value["byteLength"],
        sha256=value["sha256"],
    )


def _stage(value):
    if type(value) is not dict or set(value) != {
        "resourceId",
        "bindingId",
        "bindingRevision",
        "rollbackReceiptId",
        "stageId",
        "byteLength",
        "sha256",
    }:
        raise ComponentRestorePlanError()
    return ComponentRestoreStageReceipt(
        resource_id=value["resourceId"],
        binding_id=value["bindingId"],
        binding_revision=value["bindingRevision"],
        rollback_receipt_id=value["rollbackReceiptId"],
        stage_id=value["stageId"],
        byte_length=value["byteLength"],
        sha256=value["sha256"],
    )


class ComponentRestoreRecoveryJournal:
    """One authenticated, atomically replaced private recovery record."""

    def __init__(self, path, authentication_key):
        try:
            if (
                not isinstance(path, Path)
                or not path.is_absolute()
                or type(authentication_key) is not bytes
                or len(authentication_key) != 32
            ):
                raise ValueError()
            self.path = checked_path(path)
            self._key = authentication_key
        except Exception:
            raise ComponentRestorePlanError() from None

    def __repr__(self):
        return "ComponentRestoreRecoveryJournal(<private>)"

    def exists(self):
        return os.path.lexists(self.path)

    def acquire_lock(self):
        descriptor = -1
        try:
            private_directory(self.path.parent)
            lock_path = self.path.with_name(f".{self.path.name}.lock")
            try:
                private_create(lock_path, b"")
            except FileExistsError:
                pass
            descriptor = os.open(
                lock_path,
                os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
            )
            info = os.fstat(descriptor)
            current = os.stat(lock_path, follow_symlinks=False)
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_uid != os.geteuid()
                or stat.S_IMODE(info.st_mode) != 0o600
                or info.st_nlink != 1
                or (info.st_dev, info.st_ino)
                != (current.st_dev, current.st_ino)
            ):
                raise ValueError()
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return descriptor
        except Exception:
            if descriptor >= 0:
                os.close(descriptor)
            raise ComponentRestorePlanError() from None

    @staticmethod
    def release_lock(descriptor):
        try:
            if type(descriptor) is not int or descriptor < 0:
                raise ValueError()
            os.close(descriptor)
        except Exception:
            raise ComponentRestorePlanError() from None

    def _authenticate(self, body):
        return hmac.new(self._key, _canonical(body), hashlib.sha256).hexdigest()

    @staticmethod
    def _validate(body):
        if type(body) is not dict or set(body) != {
            "version",
            "operationId",
            "snapshotId",
            "planSha256",
            "phase",
            "rollbacks",
            "stages",
        }:
            raise ComponentRestorePlanError()
        if (
            type(body["version"]) is not int
            or body["version"] != 3
            or type(body["operationId"]) is not str
            or _IDENTITY.fullmatch(body["operationId"]) is None
            or type(body["snapshotId"]) is not str
            or _IDENTITY.fullmatch(body["snapshotId"]) is None
            or type(body["planSha256"]) is not str
            or _DIGEST.fullmatch(body["planSha256"]) is None
            or body["phase"] not in _PHASES
            or type(body["rollbacks"]) is not list
            or type(body["stages"]) is not list
            or len(body["rollbacks"]) > 384
            or len(body["stages"]) > 384
        ):
            raise ComponentRestorePlanError()
        rollbacks = tuple(_rollback(item) for item in body["rollbacks"])
        stages = tuple(_stage(item) for item in body["stages"])
        rollback_resources = tuple(item.resource_id for item in rollbacks)
        stage_resources = tuple(item.resource_id for item in stages)
        phase = body["phase"]
        if (
            rollback_resources != tuple(sorted(set(rollback_resources)))
            or stage_resources != tuple(sorted(set(stage_resources)))
            or len({item.receipt_id for item in rollbacks}) != len(rollbacks)
            or len({item.stage_id for item in stages}) != len(stages)
            or any(
                stage.resource_id != rollback.resource_id
                or stage.binding_id != rollback.binding_id
                or stage.binding_revision != rollback.binding_revision
                or stage.rollback_receipt_id != rollback.receipt_id
                for stage, rollback in zip(stages, rollbacks, strict=False)
            )
            or phase in {"acquiring", "acquired", "quiesced"}
            and (rollbacks or stages)
            or phase == "rollback_snapshots"
            and (not rollbacks or stages)
            or phase == "staging"
            and (not rollbacks or not stages or len(stages) > len(rollbacks))
            or phase in {"pre_commit", "committed"}
            and (not rollbacks or len(rollbacks) != len(stages))
            or phase in {"rolled_back", "released"}
            and len(stages) > len(rollbacks)
        ):
            raise ComponentRestorePlanError()
        return rollbacks, stages

    def write(self, body):
        try:
            self._validate(body)
            value = {**body, "authentication": self._authenticate(body)}
            encoded = _canonical(value)
            if len(encoded) > _MAX_JOURNAL_BYTES:
                raise ValueError()
            checked_path(self.path)
            private_directory(self.path.parent)
            temporary = self.path.with_name(
                f".{self.path.name}.{secrets.token_hex(16)}.tmp"
            )
            try:
                private_create(temporary, encoded)
                os.replace(temporary, self.path)
                sync_directory(self.path.parent)
            finally:
                if temporary.exists():
                    temporary.unlink()
                    sync_directory(self.path.parent)
        except Exception:
            raise ComponentRestorePlanError() from None

    def read(self):
        try:
            raw = private_read(self.path, _MAX_JOURNAL_BYTES)
            value = json.loads(
                raw,
                object_pairs_hook=_pairs,
                parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
            )
            if (
                type(value) is not dict
                or set(value)
                != {
                    "version",
                    "operationId",
                    "snapshotId",
                    "planSha256",
                    "phase",
                    "rollbacks",
                    "stages",
                    "authentication",
                }
                or type(value["authentication"]) is not str
            ):
                raise ValueError()
            authentication = value.pop("authentication")
            if (
                raw != _canonical({**value, "authentication": authentication})
                or not secrets.compare_digest(
                    authentication, self._authenticate(value)
                )
            ):
                raise ValueError()
            self._validate(value)
            return value
        except Exception:
            raise ComponentRestorePlanError() from None

    def clear(self):
        try:
            if not self.exists():
                return
            checked_path(self.path)
            self.path.unlink()
            sync_directory(self.path.parent)
        except Exception:
            raise ComponentRestorePlanError() from None


class DurableComponentRestoreCoordinator:
    """Journal every phase and reconcile any incomplete batch on restart."""

    def __init__(
        self,
        journal,
        boundary=None,
        *,
        monotonic=time.monotonic,
        checkpoint=None,
    ):
        if (
            type(journal) is not ComponentRestoreRecoveryJournal
            or not callable(monotonic)
            or checkpoint is not None
            and not callable(checkpoint)
        ):
            raise ComponentRestorePlanError()
        self._journal = journal
        self._boundary = boundary or ComponentRestoreBoundary()
        self._monotonic = monotonic
        self._checkpoint = checkpoint or (lambda _state: None)

    def _active(self, deadline):
        if (
            type(deadline) not in (int, float)
            or type(deadline) is bool
            or not math.isfinite(deadline)
            or self._monotonic() >= deadline
        ):
            raise ComponentRestorePlanError()

    def _state(self, plan, operation_id, phase, rollbacks=(), stages=()):
        return {
            "version": 3,
            "operationId": operation_id,
            "snapshotId": plan.snapshot_id,
            "planSha256": _plan_digest(plan),
            "phase": phase,
            "rollbacks": [_rollback_payload(item) for item in rollbacks],
            "stages": [_stage_payload(item) for item in stages],
        }

    def _persist(self, state):
        self._journal.write(state)
        self._checkpoint(state)
        return state

    @staticmethod
    def _session(session):
        required = {
            "quiesce",
            "capture_rollback",
            "stage",
            "revalidate",
            "commit",
            "rollback",
            "release",
        }
        if any(not callable(getattr(session, name, None)) for name in required):
            raise ComponentRestorePlanError()
        return session

    def _cleanup(self, session, plan, operation_id, rollbacks, stages):
        try:
            if session.rollback(tuple(rollbacks), tuple(stages)) is not True:
                return
            state = self._state(
                plan, operation_id, "rolled_back", rollbacks, stages
            )
            self._journal.write(state)
            if session.release() is not True:
                return
            self._journal.write(
                self._state(plan, operation_id, "released", rollbacks, stages)
            )
            self._journal.clear()
        except Exception:
            return

    def restore(self, capture, plan, *, deadline):
        descriptor = self._journal.acquire_lock()
        try:
            return self._restore_locked(capture, plan, deadline=deadline)
        finally:
            self._journal.release_lock(descriptor)

    def _restore_locked(self, capture, plan, *, deadline):
        session = None
        rollbacks = []
        stages = []
        operation_id = secrets.token_hex(16)
        release_attempted = False
        try:
            volumes = _plan_matches_capture(capture, plan)
            self._active(deadline)
            if self._journal.exists():
                raise ComponentRestorePlanError()
            self._persist(self._state(plan, operation_id, "acquiring"))
            acquire = getattr(self._boundary, "acquire_durable", None)
            if not callable(acquire):
                raise ComponentRestorePlanError()
            session = self._session(acquire(plan, operation_id, deadline))
            self._active(deadline)
            self._persist(self._state(plan, operation_id, "acquired"))
            if session.quiesce(plan.targets, deadline) is not True:
                raise ComponentRestorePlanError()
            self._active(deadline)
            self._persist(self._state(plan, operation_id, "quiesced"))

            for volume in volumes:
                receipt = session.capture_rollback(volume, deadline)
                if not ComponentRestoreCoordinator._rollback_matches(
                    receipt, volume
                ):
                    raise ComponentRestorePlanError()
                rollbacks.append(receipt)
                self._active(deadline)
                self._persist(
                    self._state(
                        plan,
                        operation_id,
                        "rollback_snapshots",
                        rollbacks,
                    )
                )
            if len({item.receipt_id for item in rollbacks}) != len(rollbacks):
                raise ComponentRestorePlanError()

            for volume, rollback in zip(volumes, rollbacks, strict=True):
                payload = capture.payloads[volume.resource_id]
                receipt = session.stage(volume, payload, rollback, deadline)
                if not ComponentRestoreCoordinator._stage_matches(
                    receipt, volume, rollback, payload
                ):
                    raise ComponentRestorePlanError()
                stages.append(receipt)
                self._active(deadline)
                self._persist(
                    self._state(
                        plan, operation_id, "staging", rollbacks, stages
                    )
                )
            if len({item.stage_id for item in stages}) != len(stages):
                raise ComponentRestorePlanError()
            if session.revalidate(plan, deadline) is not True:
                raise ComponentRestorePlanError()
            self._active(deadline)
            self._persist(
                self._state(plan, operation_id, "pre_commit", rollbacks, stages)
            )
            if session.commit(tuple(stages), tuple(rollbacks), deadline) is not True:
                raise ComponentRestorePlanError()
            self._persist(
                self._state(plan, operation_id, "committed", rollbacks, stages)
            )
            release_attempted = True
            if session.release() is not True:
                raise ComponentRestorePlanError()
            self._persist(
                self._state(plan, operation_id, "released", rollbacks, stages)
            )
            self._journal.clear()
            return ComponentRestoreBatchReceipt(
                snapshot_id=plan.snapshot_id,
                rollbacks=tuple(rollbacks),
                stages=tuple(stages),
            )
        except Exception:
            if session is not None:
                if not release_attempted:
                    self._cleanup(
                        session, plan, operation_id, rollbacks, stages
                    )
            elif self._journal.exists():
                self._journal.clear()
            raise ComponentRestorePlanError() from None

    @staticmethod
    def _receipts_for_plan(state, plan):
        rollbacks, stages = ComponentRestoreRecoveryJournal._validate(state)
        volumes = tuple(
            volume for target in plan.targets for volume in target.volumes
        )
        expected = tuple(item.resource_id for item in volumes)
        rollback_ids = tuple(item.resource_id for item in rollbacks)
        stage_ids = tuple(item.resource_id for item in stages)
        if (
            rollback_ids != expected[: len(rollback_ids)]
            or stage_ids != expected[: len(stage_ids)]
            or any(
                not ComponentRestoreCoordinator._rollback_matches(receipt, volume)
                for receipt, volume in zip(rollbacks, volumes, strict=False)
            )
            or any(
                receipt.resource_id != volume.resource_id
                or receipt.binding_id != volume.binding_id
                or receipt.binding_revision != volume.binding_revision
                or receipt.rollback_receipt_id != rollbacks[index].receipt_id
                or receipt.byte_length != volume.byte_length
                or not secrets.compare_digest(receipt.sha256, volume.sha256)
                for index, (receipt, volume) in enumerate(
                    zip(stages, volumes, strict=False)
                )
            )
            or state["phase"] in {"staging", "pre_commit", "committed"}
            and len(rollbacks) != len(volumes)
            or state["phase"]
            in {"pre_commit", "committed"}
            and len(stages) != len(volumes)
        ):
            raise ComponentRestorePlanError()
        return rollbacks, stages

    def recover(self, plan, *, deadline):
        descriptor = self._journal.acquire_lock()
        try:
            return self._recover_locked(plan, deadline=deadline)
        finally:
            self._journal.release_lock(descriptor)

    def _recover_locked(self, plan, *, deadline):
        if not self._journal.exists():
            return False
        try:
            self._active(deadline)
            state = self._journal.read()
            if (
                not _exact(plan, ComponentRestorePlan)
                or state["snapshotId"] != plan.snapshot_id
                or not secrets.compare_digest(
                    state["planSha256"], _plan_digest(plan)
                )
            ):
                raise ComponentRestorePlanError()
            rollbacks, stages = self._receipts_for_plan(state, plan)
            if state["phase"] == "released":
                self._journal.clear()
                return True
            recover = getattr(self._boundary, "recover_durable", None)
            if not callable(recover):
                raise ComponentRestorePlanError()
            session = self._session(
                recover(plan, state["operationId"], deadline)
            )
            self._active(deadline)
            if state["phase"] != "rolled_back":
                if session.revalidate(plan, deadline) is not True:
                    raise ComponentRestorePlanError()
                self._active(deadline)
                if session.rollback(rollbacks, stages) is not True:
                    raise ComponentRestorePlanError()
                state = self._state(
                    plan,
                    state["operationId"],
                    "rolled_back",
                    rollbacks,
                    stages,
                )
                self._persist(state)
            if session.release() is not True:
                raise ComponentRestorePlanError()
            self._persist(
                self._state(
                    plan,
                    state["operationId"],
                    "released",
                    rollbacks,
                    stages,
                )
            )
            self._journal.clear()
            return True
        except ComponentRestorePlanError:
            raise
        except Exception:
            raise ComponentRestorePlanError() from None
