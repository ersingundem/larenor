import json

import pytest
from pydantic import ValidationError

from larenor_server.media_archive_actions.models import (
    ArchiveActionAuthority,
    ArchiveActionCandidate,
    ArchiveActionJob,
    ArchiveActionWorkerReceipt,
    PrivateArchiveActionCommand,
)
from larenor_server.media_archive_actions.worker_ipc import (
    MediaArchiveActionWorkerError,
    PROTOCOL_VERSION,
    SCHEMA_VERSION,
    _typed_command,
)
from larenor_server.media_archive_actions.service import (
    MediaArchiveActionService,
    _JOB_FIELDS,
)
from larenor_server.errors import ApiError
import larenor_server.media_archive_actions.service as action_service_module


OID = "1" * 32
DIGEST = "a" * 64


def _authority():
    return ArchiveActionAuthority(
        installationId="2" * 32,
        installationRevision=4,
        snapshotRevision=9,
        sourceRevisions={
            "jellyfin": 3,
            "sonarr": 5,
            "radarr": 6,
            "qbittorrent": 7,
        },
    )


def _candidate(action="optimize"):
    return ArchiveActionCandidate(
        candidateId="b" * 64,
        kind="transcode" if action == "optimize" else "duplicate",
        title="Archive item",
        potentialBytes=1024,
        confidence="medium",
        comparison={
            "basis": ("bounded_transcode_estimate" if action == "optimize"
                      else "keep_largest_copy"),
            "observedBytes": 4096,
            "estimatedRetainedBytes": 3072,
            "estimatedSavingBytes": 1024,
        },
        evidence=(
            ["source_profile_verified", "target_playback_verified",
             "bounded_size_estimate"]
            if action == "optimize"
            else ["content_hash_match", "multiple_playable_files",
                  "largest_copy_excluded"]
        ),
        actionType=action,
    )


def test_transcode_target_preserves_item_and_media_roles():
    command = PrivateArchiveActionCommand(
        operationId=OID,
        operation="stage_transcode",
        authority=_authority(),
        candidate=_candidate(),
        target={
            "targetType": "transcode",
            "sourceItemId": "3" * 32,
            "mediaKey": "movie:tmdb:42",
        },
        evidenceDigest=DIGEST,
        reservedBytes=3072,
        retainOriginal=True,
    )

    assert command.target.targetType == "transcode"
    assert command.target.sourceItemId == "3" * 32
    assert command.target.mediaKey == "movie:tmdb:42"
    assert "targetRefs" not in command.model_dump(mode="json")


def test_duplicate_target_rejects_keep_item_in_delete_set():
    with pytest.raises(ValidationError):
        PrivateArchiveActionCommand(
            operationId=OID,
            operation="cleanup_duplicate",
            authority=_authority(),
            candidate=_candidate("cleanup"),
            target={
                "targetType": "duplicate",
                "keepItemId": "4" * 32,
                "deleteItemIds": ["4" * 32],
            },
            evidenceDigest=DIGEST,
            reservedBytes=0,
            retainOriginal=False,
        )


def test_operation_rejects_target_from_another_effect_domain():
    with pytest.raises(ValidationError):
        PrivateArchiveActionCommand(
            operationId=OID,
            operation="stage_transcode",
            authority=_authority(),
            candidate=_candidate(),
            target={
                "targetType": "retention",
                "torrentId": "5" * 40,
                "importedMediaKey": "movie:tmdb:42",
            },
            evidenceDigest=DIGEST,
            reservedBytes=3072,
            retainOriginal=True,
        )


def test_running_receipt_cannot_claim_original_is_already_retained():
    receipt = ArchiveActionWorkerReceipt(
        operationId=OID,
        evidenceDigest=DIGEST,
        state="running",
        errorCode=None,
        retainedOriginal=False,
    )
    assert receipt.state == "running"
    with pytest.raises(ValidationError):
        ArchiveActionWorkerReceipt(
            operationId=OID,
            evidenceDigest=DIGEST,
            state="running",
            errorCode=None,
            retainedOriginal=True,
        )


def test_public_job_distinguishes_pending_retained_and_unknown_originals():
    common = dict(
        jobId=OID,
        revision=1,
        kind="optimize",
        cancelRequested=False,
        reservedBytes=3072,
        cleanupAvailable=False,
        proofDigest=None,
        createdAt=1,
        updatedAt=1,
    )
    pending = ArchiveActionJob(
        **common, state="queued", phase="queued", originalState="pending",
        errorCode=None,
    )
    unknown = ArchiveActionJob(
        **common, state="needs_attention", phase="needs_attention",
        originalState="unknown", errorCode="effect_unknown",
    )
    assert pending.originalState == "pending"
    assert unknown.originalState == "unknown"

    removed = ArchiveActionJob(
        **{**common, "proofDigest": "c" * 64},
        state="succeeded",
        phase="complete",
        originalState="removed",
        errorCode=None,
    )
    assert removed.originalState == "removed"


def test_worker_protocol_revision_rejects_legacy_untyped_commands():
    assert (PROTOCOL_VERSION, SCHEMA_VERSION) == (2, 2)


def _transcode_command(operation_id=OID):
    return PrivateArchiveActionCommand(
        operationId=operation_id,
        operation="stage_transcode",
        authority=_authority(),
        candidate=_candidate(),
        target={
            "targetType": "transcode",
            "sourceItemId": "3" * 32,
            "mediaKey": "movie:tmdb:42",
        },
        evidenceDigest=DIGEST,
        reservedBytes=3072,
        retainOriginal=True,
    )


def test_v1_sorted_refs_remain_readable_but_are_quarantined():
    service = object.__new__(MediaArchiveActionService)
    value = _transcode_command().model_dump(mode="json")
    value["schemaVersion"] = 1
    value["targetRefs"] = sorted([
        value["target"]["sourceItemId"], value["target"]["mediaKey"],
    ])
    del value["target"]

    command = service._decode_command(json.dumps(value))

    assert command.target.targetType == "legacy_unresolved"
    receipt = service._worker_receipt("execute", command, OID)
    assert (receipt.state, receipt.errorCode) == (
        "needs_attention", "evidence_changed")
    with pytest.raises(MediaArchiveActionWorkerError) as rejected:
        _typed_command(command)
    assert rejected.value.code == "evidence_changed"


def test_retained_cleanup_targets_source_operation_not_database_job():
    source = _transcode_command(operation_id="6" * 32)
    target = MediaArchiveActionService._retained_original_target(source)

    assert target == {
        "targetType": "retained_original",
        "sourceOperationId": "6" * 32,
    }
    cleanup = PrivateArchiveActionCommand(
        operationId="7" * 32,
        operation="cleanup_retained_original",
        authority=_authority(),
        candidate=_candidate(),
        sourceJobId="8" * 32,
        sourceJobRevision=3,
        target=target,
        evidenceDigest=DIGEST,
        reservedBytes=0,
        retainOriginal=False,
    )
    assert cleanup.target.sourceOperationId != cleanup.sourceJobId


@pytest.mark.parametrize(
    ("state", "original"),
    [("failed", "unknown"), ("cancelled", "pending")],
)
def test_terminal_public_job_rejects_uncertain_original_state(state, original):
    with pytest.raises(ValidationError):
        ArchiveActionJob(
            jobId=OID,
            revision=1,
            kind="optimize",
            state=state,
            phase=state,
            cancelRequested=state == "cancelled",
            reservedBytes=3072,
            originalState=original,
            cleanupAvailable=False,
            errorCode="effect_unknown" if state == "failed" else None,
            proofDigest=None,
            createdAt=1,
            updatedAt=1,
        )


def _insert_job(service, command, *, job_id, sequence, state, phase,
                source_job_id=None, retained_original=0, updated_at=None):
    now = int(service.settings.clock())
    row = {
        "id": job_id,
        "sequence": sequence,
        "revision": 1,
        "actor_id": "9" * 32,
        "actor_revision": 1,
        "family_id": "a" * 32,
        "request_id": f"{sequence:032x}",
        "request_hash": f"{sequence:064x}",
        "preview_id": command.operationId,
        "kind": ("optimize" if command.operation == "stage_transcode"
                 else "cleanup"),
        "candidate_id": command.candidate.candidateId,
        "source_job_id": source_job_id,
        "source_job_revision": command.sourceJobRevision,
        "state": state,
        "phase": phase,
        "cancel_requested": 0,
        "reserved_bytes": command.reservedBytes,
        "retained_original": retained_original,
        "error_code": None,
        "proof_digest": ("d" * 64 if state == "succeeded" else None),
        "command_json": command.model_dump_json(),
        "created_at": now - 100,
        "updated_at": now if updated_at is None else updated_at,
    }
    row["envelope_tag"] = service._row_tag("job", row, _JOB_FIELDS)
    with service.db.transaction() as connection:
        connection.execute(
            "INSERT INTO media_archive_action_jobs VALUES"
            "(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            tuple(row.values()),
        )
    return row


class _RunningThenSucceededWorker:
    def __init__(self):
        self.calls = []

    def preview(self, *_args, **_kwargs):
        raise AssertionError("preview is not expected")

    def execute(self, *_args, **_kwargs):
        raise AssertionError("execute is not expected")

    def reconcile(self, command, **_kwargs):
        self.calls.append(command.operationId)
        state = "running" if len(self.calls) == 1 else "succeeded"
        return {
            "schemaVersion": 2,
            "operationId": command.operationId,
            "evidenceDigest": command.evidenceDigest,
            "state": state,
            "errorCode": None,
            "retainedOriginal": state == "succeeded",
            "proofDigest": "e" * 64 if state == "succeeded" else None,
        }


def test_tick_polls_running_job_until_terminal_before_dispatch(server):
    service = server[0].state.core.media_archive_actions
    worker = _RunningThenSucceededWorker()
    service.bind_worker(worker)
    command = _transcode_command(operation_id="b" * 32)
    _insert_job(
        service, command, job_id="c" * 32, sequence=1,
        state="running", phase="executing",
    )

    first = service.tick()
    assert (first.state, first.phase) == ("running", "executing")
    second = service.tick()
    assert second is None

    with service.db.connection() as connection:
        row, _ = service._job_row(connection.execute(
            "SELECT * FROM media_archive_action_jobs WHERE id=?",
            ("c" * 32,),
        ).fetchone())
    assert (row["state"], row["phase"], row["retained_original"]) == (
        "succeeded", "complete", 1)
    assert worker.calls == ["b" * 32, "b" * 32]


def test_prune_never_deletes_source_referenced_by_active_cleanup(
        server, monkeypatch):
    service = server[0].state.core.media_archive_actions
    source = _transcode_command(operation_id="d" * 32)
    source_row = _insert_job(
        service, source, job_id="e" * 32, sequence=1,
        state="succeeded", phase="complete", retained_original=0,
    )
    cleanup = PrivateArchiveActionCommand(
        operationId="f" * 32,
        operation="cleanup_retained_original",
        authority=_authority(),
        candidate=_candidate(),
        sourceJobId=source_row["id"],
        sourceJobRevision=source_row["revision"],
        target=MediaArchiveActionService._retained_original_target(source),
        evidenceDigest=DIGEST,
        reservedBytes=0,
        retainOriginal=False,
    )
    _insert_job(
        service, cleanup, job_id="0" * 32, sequence=2,
        state="queued", phase="queued", source_job_id=source_row["id"],
    )
    monkeypatch.setattr(action_service_module, "MAX_JOBS", 2)
    monkeypatch.setattr(action_service_module, "RETAINED_JOBS", 1)

    with service.db.transaction() as connection:
        with pytest.raises(ApiError) as full:
            service._prune_jobs(connection)
    assert (full.value.code, full.value.status) == (
        "media_archive_action_job_limit", 429)
    with service.db.connection() as connection:
        assert connection.execute(
            "SELECT COUNT(*) FROM media_archive_action_jobs"
        ).fetchone()[0] == 2
