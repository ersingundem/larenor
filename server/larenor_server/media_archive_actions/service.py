"""Evidence-bound previews and durable, explicit F30 archive action jobs."""

from collections import defaultdict
import hashlib
import hmac
import json
import math
import sqlite3
import time
import uuid

from pydantic import ValidationError

from ..errors import ApiError, StartupError
from ..plugins.media_archive_core_models import MediaArchiveReadRequest
from .models import (
    ArchiveActionAuthority,
    ArchiveActionCandidate,
    ArchiveActionJob,
    ArchiveActionPolicy,
    ArchiveActionPreview,
    ArchiveActionSnapshot,
    ArchiveActionWorkerPreview,
    ArchiveActionWorkerReceipt,
    ConfirmArchiveActionRequest,
    PreviewArchiveActionRequest,
    PreviewArchiveCleanupRequest,
    PrivateArchiveActionCommand,
    SnapshotActionRequest,
    UpdateArchiveActionPolicyRequest,
)


MAX_PREVIEWS = 512
RETAINED_PREVIEWS = 384
MAX_JOBS = 256
RETAINED_JOBS = 192
PREVIEW_TTL_SECONDS = 15 * 60
DEFAULT_QUOTA_BYTES = 64 * 1024**3
WORKER_DEADLINE_SECONDS = 5
RUNNING_STALE_SECONDS = WORKER_DEADLINE_SECONDS + 2

_POLICY_FIELDS = (
    "singleton", "revision", "quota_bytes", "request_id", "request_hash",
    "created_at", "updated_at",
)
_PREVIEW_FIELDS = (
    "id", "sequence", "revision", "actor_id", "actor_revision", "family_id", "request_id",
    "request_hash", "kind", "candidate_id", "source_job_id",
    "source_job_revision",
    "policy_revision", "installation_id", "installation_revision",
    "snapshot_revision", "operation", "state", "command_json",
    "reserved_bytes", "expires_at", "created_at", "updated_at",
)
_JOB_FIELDS = (
    "id", "sequence", "revision", "actor_id", "actor_revision",
    "family_id", "request_id", "request_hash", "preview_id", "kind",
    "candidate_id", "source_job_id", "source_job_revision",
    "state", "phase", "cancel_requested", "reserved_bytes",
    "retained_original", "error_code", "proof_digest", "command_json", "created_at",
    "updated_at",
)


class MediaArchiveActionService:
    """Keeps analysis read-only until a separately confirmed durable job."""

    def __init__(self, db, auth, settings, key, context, media_archive_health):
        self.db, self.auth, self.settings = db, auth, settings
        self.context, self.media_archive_health = context, media_archive_health
        self._key = hmac.new(
            key, b"larenor-media-archive-actions-v1", hashlib.sha256
        ).digest()
        self.worker = None

    def bind_worker(self, worker):
        if (self.worker is not None or any(not callable(getattr(worker, name, None))
                                           for name in (
                                               "preview", "execute",
                                               "reconcile"))):
            raise StartupError("media_archive_action_worker_invalid")
        self.worker = worker

    @property
    def backend(self):
        """Compatibility surface used by the app lifecycle dispatcher."""
        return self.worker

    @staticmethod
    def _json(value):
        if hasattr(value, "model_dump"):
            value = value.model_dump(mode="json")
        return json.dumps(
            value, sort_keys=True, separators=(",", ":"), allow_nan=False,
            default=lambda item: item.model_dump(mode="json"),
        )

    @classmethod
    def _hash(cls, value):
        return hashlib.sha256(cls._json(value).encode("utf-8")).hexdigest()

    def _tag(self, domain, values):
        scope = [
            getattr(self.context, "coreId", None),
            getattr(self.context, "homeId", None),
            values,
        ]
        return hmac.new(
            self._key, domain.encode("ascii") + b"\0"
            + self._json(scope).encode("utf-8"), hashlib.sha256,
        ).hexdigest()

    def _row_tag(self, domain, row, fields):
        return self._tag(domain, {name: row[name] for name in fields})

    def _verified(self, domain, row, fields):
        if row is None or not hmac.compare_digest(
                row["envelope_tag"], self._row_tag(domain, row, fields)):
            raise ApiError("media_archive_action_storage_unavailable", 503)
        return row

    def _now(self):
        value = self.settings.clock()
        if (type(value) not in (int, float) or not math.isfinite(value)
                or not 1 <= value <= 253402300799):
            raise ApiError("media_archive_action_unavailable", 503)
        return int(value)

    def _admin(self, connection, actor):
        self.auth.assert_current(connection, actor)
        if actor.role != "admin" or actor.must_change_password:
            raise ApiError("forbidden", 403)
        row = connection.execute(
            "SELECT revision FROM users WHERE id=?", (actor.id,)
        ).fetchone()
        if row is None or type(row["revision"]) is not int:
            raise ApiError("forbidden", 403)
        return row["revision"]

    def _policy_row(self, connection, *, create=True):
        raw = connection.execute(
            "SELECT * FROM media_archive_action_policy WHERE singleton=1"
        ).fetchone()
        if raw is not None:
            return self._verified("policy", raw, _POLICY_FIELDS)
        if not create:
            return None
        now = self._now()
        row = {
            "singleton": 1,
            "revision": 1,
            "quota_bytes": DEFAULT_QUOTA_BYTES,
            "request_id": None,
            "request_hash": None,
            "created_at": now,
            "updated_at": now,
        }
        row["envelope_tag"] = self._row_tag("policy", row, _POLICY_FIELDS)
        connection.execute(
            "INSERT INTO media_archive_action_policy VALUES(?,?,?,?,?,?,?,?)",
            tuple(row.values()),
        )
        return row

    def _expire_previews(self, connection, now):
        rows = connection.execute(
            "SELECT * FROM media_archive_action_previews "
            "WHERE state='ready' AND expires_at<=? ORDER BY sequence LIMIT ?",
            (now, MAX_PREVIEWS + 1),
        ).fetchall()
        if len(rows) > MAX_PREVIEWS:
            raise ApiError("media_archive_action_storage_unavailable", 503)
        for raw in rows:
            row = dict(self._verified("preview", raw, _PREVIEW_FIELDS))
            row.update(
                revision=row["revision"] + 1,
                state="expired",
                updated_at=max(now, row["updated_at"]),
            )
            row["envelope_tag"] = self._row_tag(
                "preview", row, _PREVIEW_FIELDS)
            connection.execute(
                "UPDATE media_archive_action_previews SET revision=?,state=?,"
                "updated_at=?,envelope_tag=? WHERE id=?",
                (row["revision"], row["state"], row["updated_at"],
                 row["envelope_tag"], row["id"]),
            )

    def _reserved(self, connection, now):
        self._expire_previews(connection, now)
        preview = connection.execute(
            "SELECT COALESCE(SUM(reserved_bytes),0) FROM "
            "media_archive_action_previews WHERE state='ready' AND expires_at>?",
            (now,),
        ).fetchone()[0]
        jobs = connection.execute(
            "SELECT COALESCE(SUM(reserved_bytes),0) FROM "
            "media_archive_action_jobs WHERE state IN "
            "('queued','running','needs_attention')"
        ).fetchone()[0]
        if (type(preview) is not int or type(jobs) is not int
                or preview < 0 or jobs < 0
                or preview + jobs > 10 * 1024**4):
            raise ApiError("media_archive_action_storage_unavailable", 503)
        return preview + jobs

    def _public_policy(self, connection, row, now):
        reserved = self._reserved(connection, now)
        if reserved > row["quota_bytes"]:
            raise ApiError("media_archive_action_storage_unavailable", 503)
        return ArchiveActionPolicy(
            revision=row["revision"],
            sharedQuotaBytes=row["quota_bytes"],
            reservedBytes=reserved,
            availableBytes=row["quota_bytes"] - reserved,
            automaticCleanup=False,
        )

    @staticmethod
    def _authority(current):
        return ArchiveActionAuthority(
            installationId=current.installationId,
            installationRevision=current.installationRevision,
            snapshotRevision=current.snapshotRevision,
            sourceRevisions={item.serviceId: item.serviceRevision
                             for item in current.sources},
        )

    def _collect(self, actor, body):
        request = MediaArchiveReadRequest(
            requestId=body.requestId,
            installationId=body.installationId,
            expectedInstallationRevision=body.expectedInstallationRevision,
            expectedSnapshotRevision=body.expectedSnapshotRevision,
        )
        current, observation = self.media_archive_health._collect(actor, request)
        return self._authority(current), observation

    def _candidate(self, authority, *, kind, title, potential, confidence,
                   basis, observed, retained, evidence, action, refs):
        value = {
            "kind": kind,
            "title": title,
            "potentialBytes": potential,
            "confidence": confidence,
            "comparison": {
                "basis": basis,
                "observedBytes": observed,
                "estimatedRetainedBytes": retained,
                "estimatedSavingBytes": potential,
            },
            "evidence": evidence,
            "actionType": action,
        }
        candidate_id = self._hash({
            "schemaVersion": 1,
            "authority": authority,
            "candidate": value,
            "targetRefs": sorted(refs),
        })
        return ArchiveActionCandidate(candidateId=candidate_id, **value), sorted(refs)

    def _candidates(self, authority, observation):
        values = {"duplicate": [], "transcode": [], "retention": []}
        playable = [item for item in observation.jellyfin.items
                    if item.integrity == "playable" and item.sizeBytes > 0]
        used = set()

        hashes = defaultdict(list)
        for item in playable:
            if item.contentHash is not None:
                hashes[item.contentHash].append(item)
        for group in hashes.values():
            group.sort(key=lambda item: item.itemId)
            if len(group) < 2 or len({item.sizeBytes for item in group}) != 1:
                continue
            observed = sum(item.sizeBytes for item in group)
            retained = group[0].sizeBytes
            values["duplicate"].append(self._candidate(
                authority, kind="duplicate", title=group[0].title,
                potential=observed - retained, confidence="high",
                basis="keep_largest_copy", observed=observed,
                retained=retained,
                evidence=["content_hash_match", "multiple_playable_files",
                          "largest_copy_excluded"], action="cleanup",
                refs=[item.itemId for item in group],
            ))
            used.update(item.itemId for item in group)

        metadata = defaultdict(list)
        for item in playable:
            if item.contentHash is None and item.runtimeSeconds is not None:
                metadata[(item.title, item.sizeBytes,
                          item.runtimeSeconds)].append(item)
        for group in metadata.values():
            group.sort(key=lambda item: item.itemId)
            if len(group) < 2:
                continue
            observed = sum(item.sizeBytes for item in group)
            retained = group[0].sizeBytes
            values["duplicate"].append(self._candidate(
                authority, kind="duplicate", title=group[0].title,
                potential=observed - retained, confidence="medium",
                basis="keep_largest_copy", observed=observed,
                retained=retained,
                evidence=["name_size_runtime_match",
                          "multiple_playable_files",
                          "largest_copy_excluded"], action="cleanup",
                refs=[item.itemId for item in group],
            ))
            used.update(item.itemId for item in group)

        qualities = defaultdict(list)
        for item in playable:
            if (item.itemId not in used and item.runtimeSeconds is not None
                    and item.quality is not None):
                qualities[(item.mediaKey, item.runtimeSeconds)].append(item)
        for group in qualities.values():
            if len(group) < 2:
                continue
            ranked = sorted(
                group,
                key=lambda item: (
                    item.quality.width * item.quality.height,
                    item.quality.videoBitrate, item.sizeBytes, item.itemId),
            )
            best = ranked[-1]
            lower = [item for item in ranked[:-1] if (
                item.quality.width * item.quality.height,
                item.quality.videoBitrate, item.sizeBytes,
            ) < (
                best.quality.width * best.quality.height,
                best.quality.videoBitrate, best.sizeBytes,
            )]
            if not lower:
                continue
            potential = sum(item.sizeBytes for item in lower)
            observed = sum(item.sizeBytes for item in group)
            values["duplicate"].append(self._candidate(
                authority, kind="duplicate", title=best.title,
                potential=potential, confidence="medium",
                basis="keep_best_quality_copy", observed=observed,
                retained=observed - potential,
                evidence=["same_media_identity", "quality_profile_comparison",
                          "best_quality_excluded"], action="cleanup",
                refs=[best.itemId] + [item.itemId for item in lower],
            ))

        for item in playable:
            proof = item.transcode
            if proof is None:
                continue
            estimate = ((proof.sourceBitrate - proof.targetBitrate)
                        * proof.durationSeconds) // 8
            potential = min(item.sizeBytes, estimate)
            if potential <= 0:
                continue
            values["transcode"].append(self._candidate(
                authority, kind="transcode", title=item.title,
                potential=potential, confidence="medium",
                basis="bounded_transcode_estimate", observed=item.sizeBytes,
                retained=item.sizeBytes - potential,
                evidence=["source_profile_verified",
                          "target_playback_verified",
                          "bounded_size_estimate"], action="optimize",
                refs=[item.itemId, item.mediaKey],
            ))

        for item in observation.qbittorrent.items:
            if (item.state != "complete" or not item.importedConfirmed
                    or not item.retentionPolicySatisfied
                    or item.mediaKey is None or item.contentBytes <= 0):
                continue
            values["retention"].append(self._candidate(
                authority, kind="retention", title=item.title,
                potential=item.contentBytes, confidence="medium",
                basis="review_retained_copy", observed=item.contentBytes,
                retained=0,
                evidence=["download_complete", "import_verified",
                          "retention_policy_satisfied"], action="cleanup",
                refs=[item.torrentId, item.mediaKey],
            ))

        result = []
        for kind in ("duplicate", "transcode", "retention"):
            lane = values[kind]
            lane.sort(key=lambda pair: (
                pair[0].title.casefold(), pair[0].title,
                pair[0].potentialBytes, pair[0].candidateId,
            ))
            result.extend(lane[:256])
        return result

    def _command(self, authority, candidate, refs, operation, operation_id,
                 source_job_id=None, source_job_revision=None):
        reserve = (max(1, candidate.comparison.estimatedRetainedBytes)
                   if operation == "stage_transcode" else 0)
        evidence = self._hash({
            "authority": authority,
            "candidate": candidate,
            "targetRefs": refs,
            "operation": operation,
        })
        return PrivateArchiveActionCommand(
            operationId=operation_id,
            operation=operation,
            authority=authority,
            candidate=candidate,
            sourceJobId=source_job_id,
            sourceJobRevision=source_job_revision,
            targetRefs=refs,
            evidenceDigest=evidence,
            reservedBytes=reserve,
            retainOriginal=operation == "stage_transcode",
        )

    def _decode_command(self, raw):
        try:
            if type(raw) is not str or len(raw.encode("utf-8")) > 262144:
                raise ValueError()
            return PrivateArchiveActionCommand.model_validate_json(raw)
        except (ValidationError, ValueError, TypeError, AttributeError,
                RecursionError, OverflowError):
            raise ApiError("media_archive_action_storage_unavailable", 503) from None

    def _preview_row(self, raw):
        row = self._verified("preview", raw, _PREVIEW_FIELDS)
        command = self._decode_command(row["command_json"])
        if (command.operationId != row["id"]
                or command.candidate.candidateId != row["candidate_id"]
                or command.authority.installationId != row["installation_id"]
                or command.authority.installationRevision
                != row["installation_revision"]
                or command.authority.snapshotRevision != row["snapshot_revision"]
                or command.operation != row["operation"]
                or command.reservedBytes != row["reserved_bytes"]
                or command.sourceJobId != row["source_job_id"]
                or command.sourceJobRevision != row["source_job_revision"]
                or (command.operation == "stage_transcode")
                != (row["kind"] == "optimize")):
            raise ApiError("media_archive_action_storage_unavailable", 503)
        return row, command

    def _job_row(self, raw):
        row = self._verified("job", raw, _JOB_FIELDS)
        command = self._decode_command(row["command_json"])
        if (command.operationId != row["preview_id"]
                or (command.operation == "stage_transcode")
                != (row["kind"] == "optimize")
                or command.reservedBytes != row["reserved_bytes"]
                or command.candidate.candidateId != row["candidate_id"]
                or command.sourceJobId != row["source_job_id"]
                or command.sourceJobRevision != row["source_job_revision"]
                or bool(row["retained_original"])
                != (row["kind"] == "optimize")):
            raise ApiError("media_archive_action_storage_unavailable", 503)
        return row, command

    @staticmethod
    def _public_preview(row, command):
        return ArchiveActionPreview(
            previewId=row["id"], revision=row["revision"],
            candidateId=row["candidate_id"], operation=row["operation"],
            reservedBytes=row["reserved_bytes"],
            originalWillBeRetained=command.retainOriginal,
            expiresAt=row["expires_at"], confirmAvailable=True,
        )

    def _public_job(self, connection, row):
        cleanup_available = False
        if (row["kind"] == "optimize" and row["state"] == "succeeded"
                and bool(row["retained_original"])):
            cleanup_available = connection.execute(
                "SELECT NOT EXISTS(SELECT 1 FROM media_archive_action_jobs "
                "WHERE source_job_id=?) AND NOT EXISTS(SELECT 1 FROM "
                "media_archive_action_previews WHERE source_job_id=? "
                "AND state='ready' AND expires_at>?)",
                (row["id"], row["id"], self._now()),
            ).fetchone()[0] == 1
        return ArchiveActionJob(
            jobId=row["id"], revision=row["revision"], kind=row["kind"],
            state=row["state"], phase=row["phase"],
            cancelRequested=bool(row["cancel_requested"]),
            reservedBytes=row["reserved_bytes"],
            retainedOriginal=bool(row["retained_original"]),
            cleanupAvailable=cleanup_available,
            errorCode=row["error_code"], proofDigest=row["proof_digest"],
            createdAt=row["created_at"],
            updatedAt=row["updated_at"],
        )

    def _latest_jobs(self, connection, actor):
        rows = connection.execute(
            "SELECT * FROM media_archive_action_jobs "
            "WHERE actor_id=? AND family_id=? "
            "ORDER BY sequence DESC LIMIT 65",
            (actor.id, actor.family_id),
        ).fetchall()
        if len(rows) > 64:
            rows = rows[:64]
        result = []
        for raw in rows:
            row, _command = self._job_row(raw)
            result.append(self._public_job(connection, row))
        return result

    def snapshot(self, actor, body):
        if type(body) is not SnapshotActionRequest:
            raise ApiError("invalid_request")
        authority, observation = self._collect(actor, body)
        candidates = [item for item, _refs in self._candidates(
            authority, observation)]
        now = self._now()
        with self.db.transaction() as connection:
            self._admin(connection, actor)
            policy_row = self._policy_row(connection)
            policy = self._public_policy(connection, policy_row, now)
            jobs = self._latest_jobs(connection, actor)
        return {
            "requestId": body.requestId,
            "snapshot": ArchiveActionSnapshot(
                revision=policy.revision, policy=policy, authority=authority,
                candidates=candidates, jobs=jobs, generatedAt=now,
            ),
        }

    def update_policy(self, actor, body):
        if type(body) is not UpdateArchiveActionPolicyRequest:
            raise ApiError("invalid_request")
        request_hash = self._hash(body)
        now = self._now()
        with self.db.transaction() as connection:
            self._admin(connection, actor)
            raw = self._policy_row(connection)
            if raw["request_id"] == body.requestId:
                if not hmac.compare_digest(raw["request_hash"], request_hash):
                    raise ApiError("media_archive_action_request_conflict", 409)
                return {"requestId": body.requestId,
                        "policy": self._public_policy(connection, raw, now)}
            if raw["revision"] != body.expectedRevision:
                raise ApiError("media_archive_action_policy_changed", 409)
            reserved = self._reserved(connection, now)
            if body.sharedQuotaBytes < reserved:
                raise ApiError("media_archive_action_quota_exceeded", 409)
            row = dict(raw)
            row.update(
                revision=raw["revision"] + 1,
                quota_bytes=body.sharedQuotaBytes,
                request_id=body.requestId,
                request_hash=request_hash,
                updated_at=max(now, raw["updated_at"]),
            )
            row["envelope_tag"] = self._row_tag("policy", row, _POLICY_FIELDS)
            connection.execute(
                "UPDATE media_archive_action_policy SET revision=?,quota_bytes=?,"
                "request_id=?,request_hash=?,updated_at=?,envelope_tag=? "
                "WHERE singleton=1",
                (row["revision"], row["quota_bytes"], row["request_id"],
                 row["request_hash"], row["updated_at"], row["envelope_tag"]),
            )
            return {"requestId": body.requestId,
                    "policy": self._public_policy(connection, row, now)}

    def _require_worker(self):
        if self.worker is None:
            raise ApiError("media_archive_action_worker_unavailable", 503)
        return self.worker

    def _worker_gate(self, actor):
        try:
            with self.db.connection() as connection:
                connection.execute("BEGIN")
                self._admin(connection, actor)
            return True
        except ApiError:
            return False

    def _call_preview(self, actor, command):
        worker = self._require_worker()
        deadline = time.monotonic() + WORKER_DEADLINE_SECONDS
        try:
            raw = worker.preview(
                command, deadline=deadline,
                gate=lambda: self._worker_gate(actor),
            )
            receipt = ArchiveActionWorkerPreview.model_validate(
                raw.model_dump(mode="python")
                if hasattr(raw, "model_dump") else raw)
        except ApiError:
            raise
        except Exception:
            raise ApiError("media_archive_action_worker_unavailable", 503) from None
        if (time.monotonic() >= deadline
                or receipt.operationId != command.operationId
                or not hmac.compare_digest(
                    receipt.evidenceDigest, command.evidenceDigest)
                or receipt.requiredBytes != command.reservedBytes
                or receipt.originalWillBeRetained != command.retainOriginal):
            raise ApiError("media_archive_action_worker_unavailable", 503)
        return receipt

    def _prune_previews(self, connection):
        rows = connection.execute(
            "SELECT * FROM media_archive_action_previews "
            "ORDER BY sequence LIMIT ?", (MAX_PREVIEWS + 1,)
        ).fetchall()
        if len(rows) > MAX_PREVIEWS:
            raise ApiError("media_archive_action_storage_unavailable", 503)
        for row in rows:
            self._preview_row(row)
        if len(rows) < MAX_PREVIEWS:
            return
        deletable = [row["id"] for row in rows
                     if row["state"] in {"consumed", "expired"}]
        count = min(len(deletable), len(rows) - RETAINED_PREVIEWS)
        if count:
            connection.executemany(
                "DELETE FROM media_archive_action_previews WHERE id=?",
                ((value,) for value in deletable[:count]),
            )
        if len(rows) - count >= MAX_PREVIEWS:
            raise ApiError("media_archive_action_preview_limit", 429)

    def _find_candidate(self, actor, body, candidate_id, action_type):
        authority, observation = self._collect(actor, body)
        matches = [(candidate, refs) for candidate, refs
                   in self._candidates(authority, observation)
                   if candidate.candidateId == candidate_id
                   and candidate.actionType == action_type]
        if len(matches) != 1:
            raise ApiError("media_archive_action_evidence_changed", 409)
        return authority, matches[0][0], matches[0][1]

    def _existing_preview(self, connection, actor, body, request_hash, now):
        raw = connection.execute(
            "SELECT * FROM media_archive_action_previews WHERE "
            "actor_id=? AND family_id=? AND request_id=?",
            (actor.id, actor.family_id, body.requestId),
        ).fetchone()
        if raw is None:
            return None
        row, command = self._preview_row(raw)
        if not hmac.compare_digest(row["request_hash"], request_hash):
            raise ApiError("media_archive_action_request_conflict", 409)
        if row["state"] != "ready" or row["expires_at"] <= now:
            raise ApiError("media_archive_action_preview_expired", 409)
        return self._public_preview(row, command)

    def _save_preview(self, actor, body, command, kind):
        request_hash = self._hash(body)
        now = self._now()
        with self.db.transaction() as connection:
            actor_revision = self._admin(connection, actor)
            existing = self._existing_preview(
                connection, actor, body, request_hash, now)
            if existing is not None:
                return existing
            if command.sourceJobId is not None:
                used = connection.execute(
                    "SELECT 1 FROM media_archive_action_jobs "
                    "WHERE source_job_id=? LIMIT 1",
                    (command.sourceJobId,),
                ).fetchone()
                pending = connection.execute(
                    "SELECT * FROM media_archive_action_previews "
                    "WHERE source_job_id=? AND state='ready' AND expires_at>? "
                    "LIMIT 1",
                    (command.sourceJobId, now),
                ).fetchone()
                if used is not None or pending is not None:
                    if pending is not None:
                        self._preview_row(pending)
                    raise ApiError(
                        "media_archive_action_cleanup_already_confirmed", 409)
            self._prune_previews(connection)
            policy = self._policy_row(connection)
            if policy["revision"] != body.expectedPolicyRevision:
                raise ApiError("media_archive_action_policy_changed", 409)
            reserved = self._reserved(connection, now)
            if reserved + command.reservedBytes > policy["quota_bytes"]:
                raise ApiError("media_archive_action_quota_exceeded", 409)
            sequence = connection.execute(
                "SELECT COALESCE(MAX(sequence),0)+1 FROM "
                "media_archive_action_previews"
            ).fetchone()[0]
            row = {
                "id": command.operationId,
                "sequence": sequence,
                "revision": 1,
                "actor_id": actor.id,
                "actor_revision": actor_revision,
                "family_id": actor.family_id,
                "request_id": body.requestId,
                "request_hash": request_hash,
                "kind": kind,
                "candidate_id": command.candidate.candidateId,
                "source_job_id": command.sourceJobId,
                "source_job_revision": command.sourceJobRevision,
                "policy_revision": policy["revision"],
                "installation_id": command.authority.installationId,
                "installation_revision": command.authority.installationRevision,
                "snapshot_revision": command.authority.snapshotRevision,
                "operation": command.operation,
                "state": "ready",
                "command_json": command.model_dump_json(),
                "reserved_bytes": command.reservedBytes,
                "expires_at": now + PREVIEW_TTL_SECONDS,
                "created_at": now,
                "updated_at": now,
            }
            row["envelope_tag"] = self._row_tag(
                "preview", row, _PREVIEW_FIELDS)
            connection.execute(
                "INSERT INTO media_archive_action_previews VALUES"
                "(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                tuple(row.values()),
            )
            return self._public_preview(row, command)

    def preview(self, actor, body):
        if type(body) is not PreviewArchiveActionRequest:
            raise ApiError("invalid_request")
        authority, candidate, refs = self._find_candidate(
            actor, body, body.candidateId, "optimize")
        operation_id = uuid.uuid4().hex
        command = self._command(
            authority, candidate, refs, "stage_transcode", operation_id)
        self._call_preview(actor, command)
        # A late worker result never weakens the exact source authority.
        current, current_candidate, current_refs = self._find_candidate(
            actor, body, body.candidateId, "optimize")
        if (current != authority or current_candidate != candidate
                or current_refs != refs):
            raise ApiError("media_archive_action_authority_changed", 409)
        saved = self._save_preview(actor, body, command, "optimize")
        return {"requestId": body.requestId, "preview": saved}

    def _source_job_cleanup(self, connection, actor, body):
        raw = connection.execute(
            "SELECT * FROM media_archive_action_jobs WHERE id=?",
            (body.sourceJobId,),
        ).fetchone()
        if raw is None:
            raise ApiError("not_found", 404)
        row, source = self._job_row(raw)
        if (row["actor_id"] != actor.id or row["family_id"] != actor.family_id
                or row["revision"] != body.expectedSourceJobRevision
                or row["kind"] != "optimize" or row["state"] != "succeeded"
                or not row["retained_original"]):
            raise ApiError("media_archive_action_job_changed", 409)
        return row, source

    def preview_cleanup(self, actor, body):
        if type(body) is not PreviewArchiveCleanupRequest:
            raise ApiError("invalid_request")
        source_job_id = None
        source_job_revision = None
        if body.candidateId is not None:
            authority, candidate, refs = self._find_candidate(
                actor, body, body.candidateId, "cleanup")
            operation = ("cleanup_duplicate" if candidate.kind == "duplicate"
                         else "cleanup_retention")
        else:
            authority, _observation = self._collect(actor, body)
            with self.db.connection() as connection:
                connection.execute("BEGIN")
                self._admin(connection, actor)
                row, source = self._source_job_cleanup(
                    connection, actor, body)
            candidate, refs = source.candidate, source.targetRefs
            source_job_id = row["id"]
            source_job_revision = row["revision"]
            operation = "cleanup_retained_original"
        command = self._command(
            authority, candidate, refs, operation, uuid.uuid4().hex,
            source_job_id, source_job_revision)
        self._call_preview(actor, command)
        current, _observation = self._collect(actor, body)
        if current != authority:
            raise ApiError("media_archive_action_authority_changed", 409)
        saved = self._save_preview(actor, body, command, "cleanup")
        return {"requestId": body.requestId, "preview": saved}

    def _prune_jobs(self, connection):
        rows = connection.execute(
            "SELECT * FROM media_archive_action_jobs ORDER BY sequence LIMIT ?",
            (MAX_JOBS + 1,),
        ).fetchall()
        if len(rows) > MAX_JOBS:
            raise ApiError("media_archive_action_storage_unavailable", 503)
        for row in rows:
            self._job_row(row)
        if len(rows) < MAX_JOBS:
            return
        deletable = [row["id"] for row in rows if row["state"] in {
            "succeeded", "failed", "cancelled"
        }]
        count = min(len(deletable), len(rows) - RETAINED_JOBS)
        if count:
            connection.executemany(
                "DELETE FROM media_archive_action_jobs WHERE id=?",
                ((value,) for value in deletable[:count]),
            )
        if len(rows) - count >= MAX_JOBS:
            raise ApiError("media_archive_action_job_limit", 429)

    def confirm(self, actor, body):
        if type(body) is not ConfirmArchiveActionRequest:
            raise ApiError("invalid_request")
        request_hash = self._hash(body)
        now = self._now()
        with self.db.transaction() as connection:
            actor_revision = self._admin(connection, actor)
            old = connection.execute(
                "SELECT * FROM media_archive_action_jobs WHERE actor_id=? "
                "AND family_id=? AND request_id=?",
                (actor.id, actor.family_id, body.requestId),
            ).fetchone()
            if old is not None:
                row, _command = self._job_row(old)
                if not hmac.compare_digest(row["request_hash"], request_hash):
                    raise ApiError("media_archive_action_request_conflict", 409)
                return {"requestId": body.requestId,
                        "job": self._public_job(connection, row)}
            self._prune_jobs(connection)
            raw = connection.execute(
                "SELECT * FROM media_archive_action_previews WHERE id=?",
                (body.previewId,),
            ).fetchone()
            if raw is None:
                raise ApiError("not_found", 404)
            preview, command = self._preview_row(raw)
            if (preview["actor_id"] != actor.id
                    or preview["family_id"] != actor.family_id
                    or preview["actor_revision"] != actor_revision
                    or preview["revision"] != body.expectedPreviewRevision
                    or preview["state"] != "ready"
                    or preview["expires_at"] <= now):
                raise ApiError("media_archive_action_preview_expired", 409)
            if (preview["source_job_id"] is not None
                    and connection.execute(
                        "SELECT 1 FROM media_archive_action_jobs "
                        "WHERE source_job_id=? LIMIT 1",
                        (preview["source_job_id"],),
                    ).fetchone() is not None):
                raise ApiError(
                    "media_archive_action_cleanup_already_confirmed", 409)
            sequence = connection.execute(
                "SELECT COALESCE(MAX(sequence),0)+1 FROM "
                "media_archive_action_jobs"
            ).fetchone()[0]
            row = {
                "id": uuid.uuid4().hex,
                "sequence": sequence,
                "revision": 1,
                "actor_id": actor.id,
                "actor_revision": actor_revision,
                "family_id": actor.family_id,
                "request_id": body.requestId,
                "request_hash": request_hash,
                "preview_id": preview["id"],
                "kind": preview["kind"],
                "candidate_id": preview["candidate_id"],
                "source_job_id": preview["source_job_id"],
                "source_job_revision": preview["source_job_revision"],
                "state": "queued",
                "phase": "queued",
                "cancel_requested": 0,
                "reserved_bytes": preview["reserved_bytes"],
                "retained_original": int(preview["kind"] == "optimize"),
                "error_code": None,
                "proof_digest": None,
                "command_json": preview["command_json"],
                "created_at": now,
                "updated_at": now,
            }
            row["envelope_tag"] = self._row_tag("job", row, _JOB_FIELDS)
            connection.execute(
                "INSERT INTO media_archive_action_jobs VALUES"
                "(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                tuple(row.values()),
            )
            changed = dict(preview)
            changed.update(
                revision=preview["revision"] + 1,
                state="consumed", updated_at=max(now, preview["updated_at"]),
            )
            changed["envelope_tag"] = self._row_tag(
                "preview", changed, _PREVIEW_FIELDS)
            connection.execute(
                "UPDATE media_archive_action_previews SET revision=?,state=?,"
                "updated_at=?,envelope_tag=? WHERE id=?",
                (changed["revision"], changed["state"], changed["updated_at"],
                 changed["envelope_tag"], changed["id"]),
            )
            return {"requestId": body.requestId,
                    "job": self._public_job(connection, row)}

    @staticmethod
    def _find_job(connection, job_id):
        row = connection.execute(
            "SELECT * FROM media_archive_action_jobs WHERE id=?", (job_id,)
        ).fetchone()
        if row is None:
            raise ApiError("not_found", 404)
        return row

    def read_job(self, actor, body):
        with self.db.connection() as connection:
            connection.execute("BEGIN")
            self._admin(connection, actor)
            row, _command = self._job_row(self._find_job(
                connection, body.jobId))
            if (row["actor_id"] != actor.id
                    or row["family_id"] != actor.family_id):
                raise ApiError("not_found", 404)
            if row["revision"] != body.expectedJobRevision:
                raise ApiError("media_archive_action_job_changed", 409)
            return {"requestId": body.requestId,
                    "job": self._public_job(connection, row)}

    def _write_job(self, connection, row, **changes):
        changed = dict(row)
        changed.update(changes)
        changed["revision"] = row["revision"] + 1
        changed["updated_at"] = max(self._now(), row["updated_at"])
        changed["envelope_tag"] = self._row_tag("job", changed, _JOB_FIELDS)
        connection.execute(
            "UPDATE media_archive_action_jobs SET revision=?,state=?,phase=?,"
            "cancel_requested=?,error_code=?,proof_digest=?,updated_at=?,"
            "envelope_tag=? "
            "WHERE id=?",
            (changed["revision"], changed["state"], changed["phase"],
             changed["cancel_requested"], changed["error_code"],
             changed["proof_digest"], changed["updated_at"],
             changed["envelope_tag"], changed["id"]),
        )
        return changed

    def cancel(self, actor, body):
        with self.db.transaction() as connection:
            self._admin(connection, actor)
            row, _command = self._job_row(self._find_job(
                connection, body.jobId))
            if (row["actor_id"] != actor.id
                    or row["family_id"] != actor.family_id):
                raise ApiError("not_found", 404)
            if row["revision"] != body.expectedJobRevision:
                raise ApiError("media_archive_action_job_changed", 409)
            if row["state"] == "queued":
                row = self._write_job(
                    connection, row, state="cancelled", phase="cancelled",
                    cancel_requested=1, error_code=None)
            elif row["state"] == "running":
                row = self._write_job(
                    connection, row, cancel_requested=1)
            return {"requestId": body.requestId,
                    "job": self._public_job(connection, row)}

    def _dispatch_authorized(self, connection, row):
        current = connection.execute(
            "SELECT u.revision,u.role,u.disabled,u.must_change_password,"
            "f.revoked_at,f.expires_at FROM users u JOIN session_families f "
            "ON f.user_id=u.id WHERE u.id=? AND f.id=?",
            (row["actor_id"], row["family_id"]),
        ).fetchone()
        return bool(current and current["revision"] == row["actor_revision"]
                    and current["role"] == "admin" and not current["disabled"]
                    and not current["must_change_password"]
                    and current["revoked_at"] is None
                    and current["expires_at"] > self.settings.clock())

    def _cancelled(self, job_id):
        with self.db.connection() as connection:
            row = connection.execute(
                "SELECT cancel_requested FROM media_archive_action_jobs "
                "WHERE id=?", (job_id,)
            ).fetchone()
            return row is None or bool(row["cancel_requested"])

    def _worker_receipt(self, method, command, job_id):
        worker = self._require_worker()
        deadline = time.monotonic() + WORKER_DEADLINE_SECONDS
        try:
            raw = getattr(worker, method)(
                command, deadline=deadline,
                cancelled=lambda: self._cancelled(job_id),
            )
            receipt = ArchiveActionWorkerReceipt.model_validate(
                raw.model_dump(mode="python")
                if hasattr(raw, "model_dump") else raw)
        except ApiError:
            raise
        except Exception:
            return ArchiveActionWorkerReceipt(
                operationId=command.operationId,
                evidenceDigest=command.evidenceDigest,
                state="needs_attention", errorCode="effect_unknown",
                retainedOriginal=command.retainOriginal,
            )
        if (time.monotonic() >= deadline
                or receipt.operationId != command.operationId
                or not hmac.compare_digest(
                    receipt.evidenceDigest, command.evidenceDigest)
                or receipt.retainedOriginal != command.retainOriginal):
            return ArchiveActionWorkerReceipt(
                operationId=command.operationId,
                evidenceDigest=command.evidenceDigest,
                state="needs_attention", errorCode="effect_unknown",
                retainedOriginal=command.retainOriginal,
            )
        return receipt

    def dispatch_next(self):
        self._require_worker()
        with self.db.transaction() as connection:
            raw = connection.execute(
                "SELECT * FROM media_archive_action_jobs WHERE state='queued' "
                "ORDER BY sequence LIMIT 1"
            ).fetchone()
            if raw is None:
                return None
            row, command = self._job_row(raw)
            if not self._dispatch_authorized(connection, row):
                row = self._write_job(
                    connection, row, state="cancelled", phase="cancelled",
                    cancel_requested=1, error_code=None)
                return self._public_job(connection, row)
            row = self._write_job(
                connection, row, state="running", phase="preparing",
                cancel_requested=0, error_code=None)
        receipt = self._worker_receipt("execute", command, row["id"])
        phase = {
            "succeeded": "complete", "failed": "failed",
            "cancelled": "cancelled", "needs_attention": "needs_attention",
        }[receipt.state]
        with self.db.transaction() as connection:
            current, _command = self._job_row(self._find_job(
                connection, row["id"]))
            if current["state"] != "running":
                raise ApiError("media_archive_action_job_changed", 409)
            if current["cancel_requested"] and receipt.state != "cancelled":
                receipt = ArchiveActionWorkerReceipt(
                    operationId=command.operationId,
                    evidenceDigest=command.evidenceDigest,
                    state="needs_attention", errorCode="cancel_unknown",
                    retainedOriginal=command.retainOriginal,
                )
                phase = "needs_attention"
            current = self._write_job(
                connection, current, state=receipt.state, phase=phase,
                cancel_requested=int(current["cancel_requested"]),
                error_code=receipt.errorCode,
                proof_digest=receipt.proofDigest)
            return self._public_job(connection, current)

    def reconcile(self, actor, body):
        self._require_worker()
        with self.db.transaction() as connection:
            self._admin(connection, actor)
            row, command = self._job_row(self._find_job(
                connection, body.jobId))
            if (row["actor_id"] != actor.id
                    or row["family_id"] != actor.family_id):
                raise ApiError("not_found", 404)
            if (row["revision"] != body.expectedJobRevision
                    or row["state"] != "needs_attention"):
                raise ApiError("media_archive_action_job_changed", 409)
            row = self._write_job(
                connection, row, state="running", phase="verifying",
                cancel_requested=int(row["cancel_requested"]), error_code=None)
        receipt = self._worker_receipt("reconcile", command, row["id"])
        phase = {
            "succeeded": "complete", "failed": "failed",
            "cancelled": "cancelled", "needs_attention": "needs_attention",
        }[receipt.state]
        with self.db.transaction() as connection:
            current, _command = self._job_row(self._find_job(
                connection, row["id"]))
            current = self._write_job(
                connection, current, state=receipt.state, phase=phase,
                cancel_requested=(0 if receipt.state == "succeeded"
                                  else int(current["cancel_requested"])),
                error_code=receipt.errorCode,
                proof_digest=receipt.proofDigest)
            return {"requestId": body.requestId,
                    "job": self._public_job(connection, current)}

    def tick(self):
        """Recover interrupted claims, then dispatch at most one queued job."""
        stale_before = self._now() - RUNNING_STALE_SECONDS
        with self.db.transaction() as connection:
            rows = connection.execute(
                "SELECT * FROM media_archive_action_jobs WHERE state='running' "
                "AND updated_at<=? ORDER BY sequence LIMIT ?",
                (stale_before, MAX_JOBS + 1),
            ).fetchall()
            if len(rows) > MAX_JOBS:
                raise ApiError("media_archive_action_storage_unavailable", 503)
            for raw in rows:
                row, _command = self._job_row(raw)
                self._write_job(
                    connection, row, state="needs_attention",
                    phase="needs_attention",
                    cancel_requested=int(row["cancel_requested"]),
                    error_code=("cancel_unknown" if row["cancel_requested"]
                                else "effect_unknown"),
                    proof_digest=None,
                )
        if self.worker is None:
            return None
        return self.dispatch_next()

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                connection.execute("BEGIN")
                policy = self._policy_row(connection, create=False)
                if policy is not None:
                    self._public_policy(connection, policy, self._now())
                previews = connection.execute(
                    "SELECT * FROM media_archive_action_previews LIMIT ?",
                    (MAX_PREVIEWS + 1,),
                ).fetchall()
                jobs = connection.execute(
                    "SELECT * FROM media_archive_action_jobs LIMIT ?",
                    (MAX_JOBS + 1,),
                ).fetchall()
                if len(previews) > MAX_PREVIEWS or len(jobs) > MAX_JOBS:
                    raise ValueError()
                for row in previews:
                    verified, command = self._preview_row(row)
                    if verified["state"] == "ready":
                        self._public_preview(verified, command)
                for row in jobs:
                    verified, _command = self._job_row(row)
                    self._public_job(connection, verified)
        except (ApiError, ValueError, TypeError, sqlite3.Error,
                OverflowError):
            raise StartupError("media_archive_action_storage_invalid") from None
