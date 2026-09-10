from dataclasses import dataclass
from typing import Annotated

from pydantic import BaseModel, ConfigDict, Field


Revision = Annotated[int, Field(ge=1, le=2**63 - 1)]


class TransferRequest(BaseModel):
    """One explicit, non-resumable download request."""

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)
    expectedUserRevision: Revision
    expectedRevision: Revision
    expectedAclRevision: Revision
    expectedServiceRevision: Revision
    deadlineMs: Annotated[int, Field(ge=1, le=15_000)] = 5_000


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
