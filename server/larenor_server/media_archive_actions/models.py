"""Strict public and private contracts for F30 archive actions."""

from typing import Literal

from pydantic import Field, field_validator, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel
from ..plugins.media_archive_health_models import (
    SavingComparisonBasis,
    SavingConfidence,
    SavingEvidence,
    SavingKind,
    MediaArchiveSavingsComparison,
)


CandidateId = str
Digest = str
ActionType = Literal["optimize", "cleanup"]
ActionState = Literal[
    "queued", "running", "succeeded", "failed", "cancelled",
    "needs_attention",
]
ActionPhase = Literal[
    "queued", "preparing", "executing", "verifying", "complete", "failed",
    "cancelled", "needs_attention",
]
ActionError = Literal[
    "worker_unavailable", "authority_changed", "evidence_changed",
    "effect_unknown", "verification_failed", "cancel_unknown",
]
ActionOperation = Literal[
    "stage_transcode", "cleanup_duplicate", "cleanup_retention",
    "cleanup_retained_original",
]


def _exact_version(value):
    if type(value) is not int:
        raise ValueError("invalid_schema")
    return value


def _digest(value: str) -> str:
    if (type(value) is not str or len(value) != 64
            or any(char not in "0123456789abcdef" for char in value)):
        raise ValueError("invalid_media_archive_action_digest")
    return value


class Versioned(StrictModel):
    schemaVersion: Literal[1] = 1

    _version = field_validator("schemaVersion", mode="before")(_exact_version)


class ArchiveActionAuthority(StrictModel):
    installationId: ObjectId
    installationRevision: Revision
    snapshotRevision: Revision
    sourceRevisions: dict[
        Literal["jellyfin", "sonarr", "radarr", "qbittorrent"], Revision]

    @model_validator(mode="after")
    def exact_sources(self):
        if set(self.sourceRevisions) != {
            "jellyfin", "sonarr", "radarr", "qbittorrent"
        }:
            raise ValueError("invalid_media_archive_action_authority")
        return self


class ArchiveActionPolicy(Versioned):
    revision: Revision
    sharedQuotaBytes: int = Field(
        ge=256 * 1024 * 1024, le=10 * 1024**4)
    reservedBytes: int = Field(ge=0, le=10 * 1024**4)
    availableBytes: int = Field(ge=0, le=10 * 1024**4)
    automaticCleanup: Literal[False] = False

    @model_validator(mode="after")
    def coherent(self):
        if (self.reservedBytes > self.sharedQuotaBytes
                or self.sharedQuotaBytes - self.reservedBytes
                != self.availableBytes):
            raise ValueError("invalid_media_archive_action_policy")
        return self


class ArchiveActionCandidate(StrictModel):
    candidateId: CandidateId = Field(pattern=r"^[0-9a-f]{64}$")
    kind: SavingKind
    title: str = Field(min_length=1, max_length=240)
    potentialBytes: int = Field(gt=0, le=2**63 - 1)
    confidence: SavingConfidence
    comparison: MediaArchiveSavingsComparison
    evidence: list[SavingEvidence] = Field(min_length=3, max_length=3)
    actionType: ActionType

    @model_validator(mode="after")
    def coherent(self):
        if ((self.kind == "transcode") != (self.actionType == "optimize")
                or self.comparison.estimatedSavingBytes
                != self.potentialBytes):
            raise ValueError("invalid_media_archive_action_candidate")
        return self


class ArchiveActionJob(Versioned):
    jobId: ObjectId
    revision: Revision
    kind: ActionType
    state: ActionState
    phase: ActionPhase
    cancelRequested: bool
    reservedBytes: int = Field(ge=0, le=10 * 1024**4)
    retainedOriginal: bool
    cleanupAvailable: bool
    errorCode: ActionError | None
    proofDigest: Digest | None = None
    createdAt: int = Field(ge=1, le=253402300799)
    updatedAt: int = Field(ge=1, le=253402300799)

    _proof = field_validator("proofDigest")(
        lambda value: None if value is None else _digest(value))

    @model_validator(mode="after")
    def coherent(self):
        valid_phases = {
            "queued": {"queued"},
            "running": {"preparing", "executing", "verifying"},
            "succeeded": {"complete"},
            "failed": {"failed"},
            "cancelled": {"cancelled"},
            "needs_attention": {"needs_attention"},
        }
        if (self.phase not in valid_phases[self.state]
                or self.updatedAt < self.createdAt
                or (self.errorCode is not None)
                != (self.state in {"failed", "needs_attention"})
                or (self.proofDigest is not None)
                != (self.state == "succeeded")
                or self.kind == "optimize"
                and (not self.retainedOriginal or self.reservedBytes <= 0)
                or self.kind == "cleanup"
                and (self.retainedOriginal or self.reservedBytes != 0)
                or self.cleanupAvailable
                and (self.kind != "optimize" or self.state != "succeeded"
                     or not self.retainedOriginal)
                or self.cancelRequested
                and self.state not in {
                    "running", "cancelled", "needs_attention"
                }):
            raise ValueError("invalid_media_archive_action_job")
        return self


class ArchiveActionPreview(Versioned):
    previewId: ObjectId
    revision: Revision
    candidateId: CandidateId = Field(pattern=r"^[0-9a-f]{64}$")
    operation: ActionOperation
    reservedBytes: int = Field(ge=0, le=10 * 1024**4)
    originalWillBeRetained: bool
    expiresAt: int = Field(ge=1, le=253402300799)
    confirmAvailable: Literal[True] = True

    @model_validator(mode="after")
    def coherent(self):
        optimize = self.operation == "stage_transcode"
        if (optimize != self.originalWillBeRetained
                or optimize != (self.reservedBytes > 0)):
            raise ValueError("invalid_media_archive_action_preview")
        return self


class ArchiveActionSnapshot(Versioned):
    revision: Revision
    policy: ArchiveActionPolicy
    authority: ArchiveActionAuthority
    candidates: list[ArchiveActionCandidate] = Field(max_length=768)
    jobs: list[ArchiveActionJob] = Field(max_length=64)
    generatedAt: int = Field(ge=1, le=253402300799)

    @model_validator(mode="after")
    def coherent(self):
        if (self.revision != self.policy.revision
                or len({item.candidateId for item in self.candidates})
                != len(self.candidates)
                or len({item.jobId for item in self.jobs}) != len(self.jobs)):
            raise ValueError("invalid_media_archive_action_snapshot")
        return self


class SnapshotActionRequest(Versioned):
    requestId: ObjectId
    installationId: ObjectId
    expectedInstallationRevision: Revision
    expectedSnapshotRevision: Revision


class SnapshotActionResponse(StrictModel):
    requestId: ObjectId
    snapshot: ArchiveActionSnapshot


class UpdateArchiveActionPolicyRequest(Versioned):
    requestId: ObjectId
    expectedRevision: Revision
    sharedQuotaBytes: int = Field(
        ge=256 * 1024 * 1024, le=10 * 1024**4)


class ArchiveActionPolicyResponse(StrictModel):
    requestId: ObjectId
    policy: ArchiveActionPolicy


class PreviewArchiveActionRequest(Versioned):
    requestId: ObjectId
    installationId: ObjectId
    expectedInstallationRevision: Revision
    expectedSnapshotRevision: Revision
    expectedPolicyRevision: Revision
    candidateId: CandidateId = Field(pattern=r"^[0-9a-f]{64}$")


class PreviewArchiveCleanupRequest(Versioned):
    requestId: ObjectId
    installationId: ObjectId
    expectedInstallationRevision: Revision
    expectedSnapshotRevision: Revision
    expectedPolicyRevision: Revision
    candidateId: CandidateId | None = Field(
        default=None, pattern=r"^[0-9a-f]{64}$")
    sourceJobId: ObjectId | None = None
    expectedSourceJobRevision: Revision | None = None

    @model_validator(mode="after")
    def exact_target(self):
        candidate = self.candidateId is not None
        source = self.sourceJobId is not None
        if (candidate == source or source
                != (self.expectedSourceJobRevision is not None)):
            raise ValueError("invalid_media_archive_cleanup_target")
        return self


class ArchiveActionPreviewResponse(StrictModel):
    requestId: ObjectId
    preview: ArchiveActionPreview


class ConfirmArchiveActionRequest(Versioned):
    requestId: ObjectId
    previewId: ObjectId
    expectedPreviewRevision: Revision


class ArchiveActionJobRequest(Versioned):
    requestId: ObjectId
    jobId: ObjectId
    expectedJobRevision: Revision


class ArchiveActionJobResponse(StrictModel):
    requestId: ObjectId
    job: ArchiveActionJob


class PrivateArchiveActionCommand(Versioned):
    operationId: ObjectId
    operation: ActionOperation
    authority: ArchiveActionAuthority
    candidate: ArchiveActionCandidate
    sourceJobId: ObjectId | None = None
    sourceJobRevision: Revision | None = None
    targetRefs: list[str] = Field(min_length=1, max_length=16)
    evidenceDigest: Digest
    reservedBytes: int = Field(ge=0, le=10 * 1024**4)
    retainOriginal: bool

    _proof = field_validator("evidenceDigest")(_digest)

    @field_validator("targetRefs")
    @classmethod
    def safe_refs(cls, values):
        if (len(values) != len(set(values)) or any(
                type(value) is not str or not 1 <= len(value) <= 128
                or any(ord(char) < 33 or ord(char) == 127 for char in value)
                for value in values)):
            raise ValueError("invalid_media_archive_action_targets")
        return values

    @model_validator(mode="after")
    def coherent(self):
        optimize = self.operation == "stage_transcode"
        if (optimize != self.retainOriginal
                or optimize != (self.reservedBytes > 0)
                or (self.operation == "stage_transcode"
                    and self.candidate.actionType != "optimize")
                or self.operation in {
                    "cleanup_duplicate", "cleanup_retention"
                } and self.candidate.actionType != "cleanup"
                or self.operation == "cleanup_retained_original"
                and self.candidate.actionType != "optimize"
                or (self.sourceJobId is not None)
                != (self.sourceJobRevision is not None)
                or (self.operation == "cleanup_retained_original")
                != (self.sourceJobId is not None)):
            raise ValueError("invalid_media_archive_action_command")
        return self


class ArchiveActionWorkerPreview(Versioned):
    operationId: ObjectId
    evidenceDigest: Digest
    requiredBytes: int = Field(ge=0, le=10 * 1024**4)
    originalWillBeRetained: bool
    state: Literal["ready"]

    _proof = field_validator("evidenceDigest")(_digest)


class ArchiveActionWorkerReceipt(Versioned):
    operationId: ObjectId
    evidenceDigest: Digest
    state: Literal["succeeded", "failed", "cancelled", "needs_attention"]
    errorCode: ActionError | None
    retainedOriginal: bool
    proofDigest: Digest | None = None

    _evidence = field_validator("evidenceDigest")(_digest)
    _proof = field_validator("proofDigest")(
        lambda value: None if value is None else _digest(value))

    @model_validator(mode="after")
    def coherent(self):
        if ((self.errorCode is not None)
                != (self.state in {"failed", "needs_attention"})
                or (self.proofDigest is not None)
                != (self.state == "succeeded")):
            raise ValueError("invalid_media_archive_action_receipt")
        return self
