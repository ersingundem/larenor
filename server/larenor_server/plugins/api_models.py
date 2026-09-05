"""Admin API contracts for offline configuration previews, not execution."""

from typing import Annotated, Literal

from pydantic import Field, StringConstraints, field_validator

from ..admin.models import ObjectId
from ..models import StrictModel
from .models import CatalogEntry, Digest, InstallPlan, Platform


Identifier = Annotated[str, StringConstraints(pattern=r"^[a-z][a-z0-9_-]{0,39}$")]


class PluginWorkerStatus(StrictModel):
    available: Literal[False] = False
    platform: None = None
    reason: Literal["worker_not_configured"] = "worker_not_configured"


class PluginCatalogResponse(StrictModel):
    catalogDigest: Digest
    entries: list[CatalogEntry] = Field(min_length=6, max_length=6)
    worker: PluginWorkerStatus


class PluginPreviewRequest(StrictModel):
    serviceId: Identifier
    distributionId: Identifier
    manifestDigest: Digest
    platform: Platform
    settings: dict[str, str | int | None] = Field(max_length=6, repr=False)

    @field_validator("settings", mode="before")
    @classmethod
    def scalar_settings(cls, value):
        if not isinstance(value, dict) or any(
            type(key) is not str or len(key) > 40 or
            type(item) not in (str, int, type(None)) or
            isinstance(item, str) and (len(item) > 80 or any(ord(c) < 32 or ord(c) == 127 for c in item))
            for key, item in value.items()
        ):
            raise ValueError("invalid_settings")
        return value


class PluginPreview(StrictModel):
    id: ObjectId
    revision: Literal[1]
    createdAt: str
    expiresAt: str
    plan: InstallPlan


class PluginPreviewResponse(StrictModel):
    preview: PluginPreview
