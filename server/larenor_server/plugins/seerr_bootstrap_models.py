"""Private Seerr bootstrap input bound to one verified Jellyfin receipt."""

from typing import Literal

from pydantic import ConfigDict, Field, model_validator

from ..admin.models import ObjectId, Revision
from .models import Digest
from ..models import StrictModel


class PrivateSeerrArrBinding(StrictModel):
    model_config = ConfigDict(extra="forbid", strict=True, frozen=True)

    serviceId: Literal["radarr", "sonarr"]
    configurationId: ObjectId
    configurationRevision: Revision
    resourceRevision: Revision
    serviceRevision: Revision
    configurationDigest: Digest
    hostname: str = Field(pattern=r"^larenor-[0-9a-f]{32}$")
    apiKey: str = Field(
        min_length=32, max_length=32, pattern=r"^[0-9a-f]{32}$", repr=False
    )
    rootPath: str = Field(pattern=r"^/media/(movies|tv)$")
    profileId: int = Field(ge=1, le=2**31 - 1)
    profileName: str = Field(min_length=1, max_length=128)

    def __repr__(self):
        return f"PrivateSeerrArrBinding(serviceId={self.serviceId!r}, <private>)"


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
    arrBindings: tuple[PrivateSeerrArrBinding, ...] = Field(
        default=(), min_length=0, max_length=2
    )

    @model_validator(mode="after")
    def coherent(self):
        if self.arrBindings and tuple(item.serviceId for item in self.arrBindings) != (
            "radarr",
            "sonarr",
        ):
            raise ValueError("invalid_seerr_arr_bindings")
        expected = {"radarr": ("/media/movies", 4), "sonarr": ("/media/tv", 5)}
        if any(
            (item.rootPath, item.profileId) != expected[item.serviceId]
            or item.profileName != "HD-1080p"
            for item in self.arrBindings
        ):
            raise ValueError("invalid_seerr_arr_bindings")
        return self
