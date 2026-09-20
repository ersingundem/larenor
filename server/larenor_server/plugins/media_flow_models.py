"""Strict, secret-free contracts for the managed media delivery flow."""

import posixpath
import re
import unicodedata
from pathlib import PurePosixPath
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
_ITEM_KEY = re.compile(
    r"(?:movie:tmdb:[1-9][0-9]{0,11}|episode:tvdb:[1-9][0-9]{0,11}:"
    r"[0-9]{1,4}:[0-9]{1,5})\Z"
)
_TORRENT_ID = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")


def validate_media_key(value: str) -> str:
    if _MEDIA_KEY.fullmatch(value) is None:
        raise ValueError("invalid_media_flow_key")
    return value


def _canonical_absolute_path(value: str) -> str:
    if (
        not value.startswith("/")
        or value.startswith("//")
        or value != posixpath.normpath(value)
        or any(unicodedata.category(character)[0] == "C" for character in value)
    ):
        raise ValueError("invalid_media_flow_path")
    return value


class MediaFlowPathEvidence(StrictModel):
    """Private, lexical bind-mount identity; never returned by the API."""

    provider: Literal["qbittorrent", "sonarr", "radarr", "jellyfin"]
    containerRoot: str = Field(min_length=1, max_length=1024)
    containerPath: str = Field(min_length=2, max_length=1024)
    hostRoot: str = Field(min_length=1, max_length=1024)
    device: int = Field(ge=1, le=2**63 - 1)
    inode: int = Field(ge=1, le=2**63 - 1)

    _root = field_validator("containerRoot", "containerPath", "hostRoot")(
        _canonical_absolute_path
    )

    @model_validator(mode="after")
    def contained(self):
        try:
            relative = PurePosixPath(self.containerPath).relative_to(
                PurePosixPath(self.containerRoot)
            )
        except ValueError:
            raise ValueError("invalid_media_flow_path") from None
        if not relative.parts:
            raise ValueError("invalid_media_flow_path")
        return self

    def resolved_host_path(self) -> str:
        relative = PurePosixPath(self.containerPath).relative_to(
            PurePosixPath(self.containerRoot)
        )
        return str(PurePosixPath(self.hostRoot).joinpath(relative))


class MediaFlowFileEvidence(StrictModel):
    mediaKey: str = Field(min_length=1, max_length=96)
    torrentId: str = Field(min_length=40, max_length=64)
    importReceiptId: ObjectId
    playbackItemId: ObjectId
    paths: list[MediaFlowPathEvidence] = Field(min_length=3, max_length=3)

    @field_validator("mediaKey")
    @classmethod
    def item_key(cls, value):
        if _ITEM_KEY.fullmatch(value) is None:
            raise ValueError("invalid_media_flow_delivery")
        return value

    @field_validator("torrentId")
    @classmethod
    def torrent_id(cls, value):
        if _TORRENT_ID.fullmatch(value) is None:
            raise ValueError("invalid_media_flow_delivery")
        return value

    @model_validator(mode="after")
    def exact_hardlink_chain(self):
        arr = "radarr" if self.mediaKey.startswith("movie:") else "sonarr"
        if tuple(item.provider for item in self.paths) != (
            "qbittorrent", arr, "jellyfin"
        ):
            raise ValueError("invalid_media_flow_delivery")
        identities = {(item.device, item.inode) for item in self.paths}
        resolved = [item.resolved_host_path() for item in self.paths]
        if (
            len(identities) != 1
            or resolved[0] == resolved[1]
            or resolved[1] != resolved[2]
        ):
            raise ValueError("invalid_media_flow_delivery")
        return self


class MediaFlowDeliveryEvidence(StrictModel):
    """One idempotent request lineage with private file continuity proof."""

    mediaKey: str = Field(min_length=1, max_length=96)
    operationId: ObjectId
    requestReceiptId: ObjectId
    retryAttempt: int = Field(ge=1, le=32)
    effectState: Literal["verified", "uncertain"]
    files: list[MediaFlowFileEvidence] = Field(max_length=4096)

    _key = field_validator("mediaKey")(validate_media_key)

    @model_validator(mode="after")
    def one_effect_per_item(self):
        media_keys = [item.mediaKey for item in self.files]
        torrent_ids = [item.torrentId for item in self.files]
        import_ids = [item.importReceiptId for item in self.files]
        playback_ids = [item.playbackItemId for item in self.files]
        if any(len(set(values)) != len(values) for values in (
            media_keys, torrent_ids, import_ids, playback_ids
        )):
            raise ValueError("invalid_media_flow_delivery")
        if self.mediaKey.startswith("movie:"):
            valid_keys = all(key == self.mediaKey for key in media_keys)
        else:
            show = self.mediaKey.rsplit(":", 1)[1]
            valid_keys = all(
                key.startswith(f"episode:tvdb:{show}:") for key in media_keys
            )
        if not valid_keys:
            raise ValueError("invalid_media_flow_delivery")
        return self


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
    delivery: MediaFlowDeliveryEvidence | None = None
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
        delivery = self.delivery
        if delivery is not None:
            request = [
                item for item in self.seerr.requests
                if item.mediaKey == delivery.mediaKey
            ]
            arr = self.radarr if delivery.mediaKey.startswith("movie:") else self.sonarr
            matched_keys = set()
            for proof in delivery.files:
                qbit = [
                    item for item in self.qbittorrent.items
                    if item.mediaKey == proof.mediaKey
                ]
                imported = [
                    item for item in arr.items if item.mediaKey == proof.mediaKey
                ]
                playable = [
                    item for item in self.jellyfin.items
                    if item.mediaKey == proof.mediaKey
                ]
                if (
                    len(qbit) != 1
                    or qbit[0].torrentId != proof.torrentId
                    or not qbit[0].importedConfirmed
                    or qbit[0].state not in {"complete", "seeding"}
                    or len(imported) != 1
                    or imported[0].state != "available"
                    or len(playable) != 1
                    or playable[0].itemId != proof.playbackItemId
                    or playable[0].integrity != "playable"
                ):
                    raise ValueError("invalid_media_flow_observation")
                matched_keys.add(proof.mediaKey)
            qbit_keys = {
                item.mediaKey for item in self.qbittorrent.items
                if item.mediaKey is not None
                and item.importedConfirmed
                and item.state in {"complete", "seeding"}
            }
            arr_keys = {item.mediaKey for item in arr.items if item.state == "available"}
            jellyfin_keys = {
                item.mediaKey for item in self.jellyfin.items
                if item.integrity == "playable"
            }
            if delivery.mediaKey.startswith("movie:"):
                relevant = {delivery.mediaKey}
            else:
                show = delivery.mediaKey.rsplit(":", 1)[1]
                relevant = {
                    key for key in qbit_keys | arr_keys | jellyfin_keys
                    if key.startswith(f"episode:tvdb:{show}:")
                }
            expected = qbit_keys & arr_keys & jellyfin_keys & relevant
            if len(request) != 1 or matched_keys != expected:
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


class MediaFlowDeliveryStatus(StrictModel):
    state: Literal["hardlink_verified"] = "hardlink_verified"
    retryAttempt: int = Field(ge=1, le=32)
    fileCount: int = Field(ge=1, le=4096)


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
    delivery: MediaFlowDeliveryStatus | None = None

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
