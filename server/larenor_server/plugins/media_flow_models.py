"""Strict, secret-free contracts for the managed media delivery flow."""

import re
from typing import Literal

from pydantic import Field, field_validator, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel
from .media_archive_health_models import (
    ArrArchiveSnapshot,
    JellyfinArchiveSnapshot,
    QbittorrentArchiveSnapshot,
)


MediaFlowProvider = Literal[
    "seerr", "qbittorrent", "sonarr", "radarr", "jellyfin",
]
MediaFlowStageName = Literal["request", "download", "import", "playable"]
MediaFlowStageState = Literal[
    "not_started", "pending", "active", "partial", "complete", "failed",
]
MEDIA_FLOW_PROVIDER_ORDER = (
    "seerr", "qbittorrent", "sonarr", "radarr", "jellyfin",
)
_MEDIA_KEY = re.compile(
    r"(?:movie:tmdb:[1-9][0-9]{0,11}|series:tvdb:[1-9][0-9]{0,11})\Z"
)


def validate_media_key(value: str) -> str:
    if _MEDIA_KEY.fullmatch(value) is None:
        raise ValueError("invalid_media_flow_key")
    return value


class SeerrFlowRequest(StrictModel):
    mediaKey: str = Field(min_length=1, max_length=96)
    state: Literal["pending", "approved", "declined", "failed"]
    requestedSeasons: list[int] = Field(max_length=100)

    _key = field_validator("mediaKey")(validate_media_key)

    @model_validator(mode="after")
    def coherent(self):
        if (
            self.requestedSeasons != sorted(set(self.requestedSeasons))
            or any(season < 0 or season > 1000 for season in self.requestedSeasons)
            or self.mediaKey.startswith("movie:") and self.requestedSeasons
        ):
            raise ValueError("invalid_media_flow_observation")
        return self


class SeerrFlowSnapshot(StrictModel):
    serviceId: Literal["seerr"] = "seerr"
    serviceRecordId: ObjectId
    serviceRevision: Revision
    snapshotRevision: Revision
    installationId: ObjectId
    installationRevision: Revision
    state: Literal["verified", "unavailable", "unsupported"]
    observedAt: int = Field(ge=1, le=253402300799)
    requests: list[SeerrFlowRequest] = Field(max_length=4096)

    @model_validator(mode="after")
    def coherent(self):
        if (
            self.state != "verified" and self.requests
            or len({item.mediaKey for item in self.requests}) != len(self.requests)
        ):
            raise ValueError("invalid_media_flow_observation")
        return self


class MediaFlowObservation(StrictModel):
    flowRevision: Revision
    seerr: SeerrFlowSnapshot
    qbittorrent: QbittorrentArchiveSnapshot
    sonarr: ArrArchiveSnapshot
    radarr: ArrArchiveSnapshot
    jellyfin: JellyfinArchiveSnapshot

    @model_validator(mode="after")
    def exact_current_sources(self):
        sources = (
            self.seerr,
            self.qbittorrent,
            self.sonarr,
            self.radarr,
            self.jellyfin,
        )
        if (
            self.sonarr.serviceId != "sonarr"
            or self.radarr.serviceId != "radarr"
            or any(source.snapshotRevision != self.flowRevision for source in sources)
            or any(source.state != "verified" for source in sources)
        ):
            raise ValueError("invalid_media_flow_observation")
        return self


class MediaFlowSourceRevision(StrictModel):
    provider: MediaFlowProvider
    serviceRevision: Revision
    snapshotRevision: Revision
    observedAt: int = Field(ge=1, le=253402300799)


class MediaFlowAuthorityRequest(StrictModel):
    requestId: ObjectId
    mediaKey: str = Field(min_length=1, max_length=96)

    _key = field_validator("mediaKey")(validate_media_key)


class MediaFlowAuthorityResponse(StrictModel):
    requestId: ObjectId
    mediaKey: str
    flowRevision: Revision
    sources: list[MediaFlowSourceRevision] = Field(min_length=5, max_length=5)

    @model_validator(mode="after")
    def exact_sources(self):
        if (
            tuple(item.provider for item in self.sources)
            != MEDIA_FLOW_PROVIDER_ORDER
            or any(
                item.snapshotRevision != self.flowRevision
                for item in self.sources
            )
        ):
            raise ValueError("invalid_media_flow_authority")
        return self


class MediaFlowReadRequest(MediaFlowAuthorityRequest):
    expectedFlowRevision: Revision
    expectedSources: list[MediaFlowSourceRevision] = Field(
        min_length=5, max_length=5
    )

    @model_validator(mode="after")
    def exact_sources(self):
        if (
            tuple(item.provider for item in self.expectedSources)
            != MEDIA_FLOW_PROVIDER_ORDER
            or any(
                item.snapshotRevision != self.expectedFlowRevision
                for item in self.expectedSources
            )
        ):
            raise ValueError("invalid_media_flow_authority")
        return self


class MediaFlowStage(StrictModel):
    name: MediaFlowStageName
    state: MediaFlowStageState
    provider: MediaFlowProvider
    sourceRevision: Revision


class MediaSeasonCoverage(StrictModel):
    seasonNumber: int = Field(ge=0, le=1000)
    knownEpisodes: list[int] = Field(max_length=1000)
    downloadedEpisodes: list[int] = Field(max_length=1000)
    importedEpisodes: list[int] = Field(max_length=1000)
    playableEpisodes: list[int] = Field(max_length=1000)
    missingEpisodes: list[int] = Field(max_length=1000)
    requested: bool
    requestable: bool
    incomplete: bool
    missingSeason: bool
    partialImport: bool

    @model_validator(mode="after")
    def coherent(self):
        groups = (
            self.knownEpisodes,
            self.downloadedEpisodes,
            self.importedEpisodes,
            self.playableEpisodes,
            self.missingEpisodes,
        )
        if any(group != sorted(set(group)) for group in groups):
            raise ValueError("invalid_media_flow_coverage")
        known = set(self.knownEpisodes)
        expected_requestable = (
            not self.requested
            and not self.downloadedEpisodes
            and not self.importedEpisodes
            and not self.playableEpisodes
        )
        expected_missing_season = (
            (self.requested or bool(known)) and not self.playableEpisodes
        )
        expected_incomplete = (
            expected_missing_season or bool(self.missingEpisodes)
        )
        expected_partial_import = (
            bool(self.importedEpisodes)
            and bool(known - set(self.importedEpisodes))
        )
        if (
            any(episode < 1 or episode > 10000 for group in groups for episode in group)
            or not set(self.downloadedEpisodes).issubset(known)
            or not set(self.importedEpisodes).issubset(known)
            or not set(self.playableEpisodes).issubset(known)
            or set(self.missingEpisodes) != known - set(self.playableEpisodes)
            or self.requestable != expected_requestable
            or self.missingSeason != expected_missing_season
            or self.incomplete != expected_incomplete
            or self.partialImport != expected_partial_import
        ):
            raise ValueError("invalid_media_flow_coverage")
        return self


class MediaFlowStatus(StrictModel):
    mediaKey: str
    flowRevision: Revision
    state: Literal[
        "not_requested", "requested", "downloading", "importing",
        "partial", "playable", "failed",
    ]
    stages: list[MediaFlowStage] = Field(min_length=4, max_length=4)
    sources: list[MediaFlowSourceRevision] = Field(min_length=5, max_length=5)
    seasons: list[MediaSeasonCoverage] = Field(max_length=100)

    @model_validator(mode="after")
    def exact_sources_and_stages(self):
        if (
            tuple(item.provider for item in self.sources)
            != MEDIA_FLOW_PROVIDER_ORDER
            or any(
                item.snapshotRevision != self.flowRevision
                for item in self.sources
            )
            or tuple(item.name for item in self.stages)
            != ("request", "download", "import", "playable")
        ):
            raise ValueError("invalid_media_flow_status")
        return self


class MediaFlowReadResponse(StrictModel):
    requestId: ObjectId
    flow: MediaFlowStatus
