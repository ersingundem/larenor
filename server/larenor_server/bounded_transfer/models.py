from dataclasses import dataclass
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

from ..home_resources.models import ResourceRef


Revision = Annotated[int, Field(ge=1, le=2**63 - 1)]
Identity = Annotated[str, Field(pattern=r"^[0-9a-f]{32}$")]
Digest = Annotated[str, Field(pattern=r"^[0-9a-f]{64}$")]


class TransferRequest(BaseModel):
    """One explicit download request, optionally resuming an interrupted one."""

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)
    requestId: Identity
    expectedUserRevision: Revision
    expectedRevision: Revision
    expectedAclRevision: Revision
    expectedServiceRevision: Revision
    deadlineMs: Annotated[int, Field(ge=1, le=15_000)] = 5_000
    resumeRequestId: Identity | None = None
    resumeOffset: Annotated[int, Field(ge=0, le=256 * 1024)] = 0

    @model_validator(mode="after")
    def coherent_resume(self):
        if ((self.resumeRequestId is None) != (self.resumeOffset == 0)
                or self.resumeRequestId == self.requestId):
            raise ValueError("invalid_transfer_resume")
        return self


class TransferReceipt(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)
    requestId: Identity
    traceId: Identity
    state: Literal["accepted", "completed", "interrupted"]
    contentLength: Annotated[int, Field(ge=0, le=256 * 1024)]
    sha256: Annotated[str, Field(pattern=r"^[0-9a-f]{64}$")]
    contentType: Annotated[str, Field(min_length=1, max_length=128)]
    serviceRevision: Revision
    createdAt: float
    updatedAt: float


class TransferReceiptResponse(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)
    receipt: TransferReceipt


class TransferHistoryResponse(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)
    receipts: list[TransferReceipt] = Field(max_length=50)


class TransferEvent(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)
    sequence: Annotated[int, Field(ge=1, le=2048)]
    kind: Literal["baseline", "accepted", "result"]
    actorId: Identity
    receipt: TransferReceipt


class TransferEventHistoryResponse(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)
    schemaVersion: Literal[1] = 1
    ref: ResourceRef
    chainId: Identity
    headSequence: Annotated[int, Field(ge=0, le=2048)]
    cursorCheckpoint: Digest
    pageCheckpoint: Digest
    headCheckpoint: Digest
    events: list[TransferEvent] = Field(max_length=50)
    nextAfter: Annotated[int, Field(ge=1, le=2048)] | None
    verified: Literal[True] = True


class ProductBlobDescriptor(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)
    resourceId: Identity
    serviceRevision: Revision
    contentLength: Annotated[int, Field(ge=1, le=256 * 1024)]
    sha256: Annotated[str, Field(pattern=r"^[0-9a-f]{64}$")]
    contentType: Annotated[str, Field(min_length=1, max_length=128)]
    createdAt: float
    updatedAt: float


class ProductBlobUpload(ProductBlobDescriptor):
    requestId: Identity


class ProductBlobResponse(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)
    blob: ProductBlobDescriptor


class ProductBlobUploadResponse(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)
    blob: ProductBlobUpload


@dataclass(frozen=True)
class BlobDescriptor:
    """A blob exposed by trusted packaged code, never by a request path or URL."""

    resource_id: str
    service_revision: int
    content_type: str
    content: bytes


@dataclass(frozen=True)
class TransferLimits:
    max_blob_bytes: int = 256 * 1024
    actor_bytes_per_window: int = 1024 * 1024
    quota_window_seconds: int = 60
    chunk_bytes: int = 16 * 1024
    max_chunks: int = 64
    max_active_streams: int = 8
    max_active_per_actor: int = 1

    def __post_init__(self):
        values = (
            self.max_blob_bytes, self.actor_bytes_per_window, self.quota_window_seconds,
            self.chunk_bytes, self.max_chunks, self.max_active_streams,
            self.max_active_per_actor,
        )
        if any(type(value) is not int or value < 1 for value in values):
            raise ValueError("invalid_transfer_limits")
        if self.max_active_per_actor > self.max_active_streams:
            raise ValueError("invalid_transfer_limits")
