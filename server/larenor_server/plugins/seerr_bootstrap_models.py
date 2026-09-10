"""Private Seerr bootstrap input bound to one verified Jellyfin receipt."""

from typing import Literal

from pydantic import ConfigDict, Field

from ..admin.models import ObjectId, Revision
from ..models import StrictModel


class PrivateSeerrBootstrap(StrictModel):
    model_config = ConfigDict(extra="forbid", strict=True, frozen=True)

    schemaVersion: Literal[1] = 1
    username: Literal["larenor-system"] = "larenor-system"
    credential: str = Field(
        min_length=32,
        max_length=128,
        repr=False,
        pattern=r"^[A-Za-z0-9_-]+$",
    )
    sourceBootstrapId: ObjectId
    sourceBootstrapRevision: Revision
