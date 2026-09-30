"""Strict public and private contracts for F30 archive actions."""

from typing import Annotated, Literal

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
OriginalState = Literal[
    "not_applicable", "pending", "retained", "not_retained", "removed",
    "unknown",
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
    schemaVersion: Literal[2] = 2
    jobId: ObjectId
    revision: Revision
    kind: ActionType
    state: ActionState
    phase: ActionPhase
    cancelRequested: bool
    reservedBytes: int = Field(ge=0, le=10 * 1024**4)
    originalState: OriginalState
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
                and (self.originalState == "not_applicable"
                     or self.reservedBytes <= 0)
                or self.kind == "cleanup"
                and (self.originalState != "not_applicable"
                     or self.reservedBytes != 0)
                or self.cleanupAvailable
                and (self.kind != "optimize" or self.state != "succeeded"
                     or self.originalState != "retained")
                or self.state in {"queued", "running"}
                and self.kind == "optimize"
                and self.originalState != "pending"
                or self.state == "succeeded" and self.kind == "optimize"
                and self.originalState not in {"retained", "removed"}
                or self.state in {"failed", "cancelled"}
                and self.kind == "optimize"
                and self.originalState not in {"not_retained", "retained"}
                or self.state == "needs_attention" and self.kind == "optimize"
                and self.originalState not in {"pending", "retained", "unknown"}
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


class TranscodeActionTarget(StrictModel):
    targetType: Literal["transcode"] = "transcode"
    sourceItemId: ObjectId
    mediaKey: str = Field(min_length=1, max_length=96)


class DuplicateActionTarget(StrictModel):
    targetType: Literal["duplicate"] = "duplicate"
    keepItemId: ObjectId
    deleteItemIds: list[ObjectId] = Field(min_length=1, max_length=15)

    @model_validator(mode="after")
    def exact_roles(self):
        if (self.keepItemId in self.deleteItemIds
                or len(set(self.deleteItemIds)) != len(self.deleteItemIds)):
            raise ValueError("invalid_media_archive_action_targets")
        return self


class RetentionActionTarget(StrictModel):
    targetType: Literal["retention"] = "retention"
    torrentId: str = Field(pattern=r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
    importedMediaKey: str = Field(min_length=1, max_length=96)


class RetainedOriginalActionTarget(StrictModel):
    targetType: Literal["retained_original"] = "retained_original"
    sourceOperationId: ObjectId


class LegacyUnresolvedActionTarget(StrictModel):
    """Readable marker for v1 rows whose sorted refs lost target roles."""

    targetType: Literal["legacy_unresolved"] = "legacy_unresolved"
    targetRefs: list[str] = Field(min_length=1, max_length=16)

    @field_validator("targetRefs")
    @classmethod
    def bounded_refs(cls, value):
        if (len(set(value)) != len(value)
                or any(type(item) is not str or not 1 <= len(item) <= 128
                       or any(ord(char) < 33 or ord(char) == 127
                              for char in item)
                       for item in value)):
            raise ValueError("invalid_media_archive_action_targets")
        return value


ArchiveActionTarget = Annotated[
    TranscodeActionTarget | DuplicateActionTarget | RetentionActionTarget
    | RetainedOriginalActionTarget | LegacyUnresolvedActionTarget,
    Field(discriminator="targetType"),
]


class ArchiveActionJobResponse(StrictModel):
    requestId: ObjectId
    job: ArchiveActionJob


class PrivateArchiveActionCommand(Versioned):
    schemaVersion: Literal[2] = 2
    operationId: ObjectId
    operation: ActionOperation
    authority: ArchiveActionAuthority
    candidate: ArchiveActionCandidate
    sourceJobId: ObjectId | None = None
    sourceJobRevision: Revision | None = None
    target: ArchiveActionTarget
    evidenceDigest: Digest
    reservedBytes: int = Field(ge=0, le=10 * 1024**4)
    retainOriginal: bool

    _proof = field_validator("evidenceDigest")(_digest)

    @model_validator(mode="after")
    def coherent(self):
        optimize = self.operation == "stage_transcode"
        legacy = self.target.targetType == "legacy_unresolved"
        if (optimize != self.retainOriginal
                or optimize != (self.reservedBytes > 0)
                or (self.operation == "stage_transcode"
                    and self.candidate.actionType != "optimize")
                or self.operation in {
                    "cleanup_duplicate", "cleanup_retention"
                } and self.candidate.actionType != "cleanup"
                or self.operation == "cleanup_retained_original"
                and self.candidate.actionType != "optimize"
                or not legacy and (self.operation == "stage_transcode")
                != (self.target.targetType == "transcode")
                or not legacy and (self.operation == "cleanup_duplicate")
                != (self.target.targetType == "duplicate")
                or not legacy and (self.operation == "cleanup_retention")
                != (self.target.targetType == "retention")
                or not legacy and (self.operation == "cleanup_retained_original")
                != (self.target.targetType == "retained_original")
                or (self.sourceJobId is not None)
                != (self.sourceJobRevision is not None)
                or (self.operation == "cleanup_retained_original")
                != (self.sourceJobId is not None)):
            raise ValueError("invalid_media_archive_action_command")
        return self


class ArchiveActionWorkerPreview(Versioned):
    schemaVersion: Literal[2] = 2
    operationId: ObjectId
    evidenceDigest: Digest
    requiredBytes: int = Field(ge=0, le=10 * 1024**4)
    originalWillBeRetained: bool
    state: Literal["ready"]

    _proof = field_validator("evidenceDigest")(_digest)


class ArchiveActionWorkerReceipt(Versioned):
    schemaVersion: Literal[2] = 2
    operationId: ObjectId
    evidenceDigest: Digest
    state: Literal[
        "running", "succeeded", "failed", "cancelled", "needs_attention",
    ]
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
                != (self.state == "succeeded")
                or self.state == "running" and self.retainedOriginal):
            raise ValueError("invalid_media_archive_action_receipt")
        return self
