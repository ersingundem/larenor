"""Secret-free, read-only recovery status for managed media services."""

from typing import Literal

from pydantic import Field, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel

ManagedMediaService = Literal[
    "larenor_core",
    "qbittorrent",
    "sonarr",
    "radarr",
    "jellyfin",
    "seerr",
    "music_assistant",
]


class MediaRecoveryService(StrictModel):
    serviceId: ManagedMediaService
    sourceId: ObjectId | None
    sourceKind: Literal[
        "core",
        "installation",
        "configuration",
        "bootstrap",
        "missing",
    ]
    revision: Revision | None
    resultState: Literal[
        "pending",
        "partial",
        "verified",
        "cancelled",
        "needs_attention",
        "failed",
        "missing",
    ]
    containerState: Literal["pending", "started", "unknown"]
    serviceState: Literal["unverified", "verified"]
    storedState: Literal["missing", "stored"]
    reachableState: Literal["unknown", "reachable", "unreachable"]
    verifiedState: Literal["unverified", "verified"]
    recoveryAction: Literal["wait", "configure", "review", "retry", "none"]
    automaticRetry: Literal[False] = False
    errorCode: str | None = Field(default=None, pattern=r"^[a-z][a-z0-9_]{0,127}$")
    updatedAt: str | None

    @model_validator(mode="after")
    def coherent(self):
        if self.serviceState != self.verifiedState:
            raise ValueError("invalid_media_recovery_status")
        if (self.serviceId == "larenor_core") != (self.sourceKind == "core"):
            raise ValueError("invalid_media_recovery_status")
        if self.sourceKind == "missing":
            if (
                self.sourceId is not None
                or self.revision is not None
                or self.updatedAt is not None
                or self.resultState != "missing"
                or self.storedState != "missing"
                or self.reachableState != "unknown"
                or self.verifiedState != "unverified"
                or self.containerState != "unknown"
                or self.recoveryAction != "configure"
            ):
                raise ValueError("invalid_media_recovery_status")
            return self
        if (
            self.sourceId is None
            or self.revision is None
            or self.storedState != "stored"
            or (self.sourceKind != "core" and self.updatedAt is None)
        ):
            raise ValueError("invalid_media_recovery_status")
        if self.sourceKind == "core" and (
            self.serviceId != "larenor_core"
            or self.resultState != "verified"
            or self.reachableState != "reachable"
        ):
            raise ValueError("invalid_media_recovery_status")
        if self.verifiedState == "verified" and self.reachableState != "reachable":
            raise ValueError("invalid_media_recovery_status")
        if self.serviceState == "verified" and self.containerState != "started":
            raise ValueError("invalid_media_recovery_status")
        if self.resultState == "verified" and (
            self.containerState != "started"
            or self.serviceState != "verified"
            or self.recoveryAction != "none"
            or self.errorCode is not None
        ):
            raise ValueError("invalid_media_recovery_status")
        if self.resultState == "pending" and (
            self.recoveryAction != "wait" or self.errorCode is not None
        ):
            raise ValueError("invalid_media_recovery_status")
        if self.resultState == "partial" and (
            self.recoveryAction not in {"configure", "review"}
            or self.errorCode is not None
        ):
            raise ValueError("invalid_media_recovery_status")
        if self.resultState == "cancelled" and (
            self.recoveryAction != "none" or self.errorCode is not None
        ):
            raise ValueError("invalid_media_recovery_status")
        if self.resultState == "needs_attention" and (
            self.recoveryAction != "review" or self.errorCode is None
        ):
            raise ValueError("invalid_media_recovery_status")
        if self.resultState == "failed" and (
            self.recoveryAction != "retry" or self.errorCode is None
        ):
            raise ValueError("invalid_media_recovery_status")
        return self


class MediaRecoveryStatusResponse(StrictModel):
    schemaVersion: Literal[2] = 2
    state: Literal["incomplete", "attention", "ready"]
    installAvailable: Literal[False] = False
    services: list[MediaRecoveryService] = Field(min_length=7, max_length=7)

    @model_validator(mode="after")
    def coherent(self):
        expected = (
            "attention"
            if any(
                item.resultState in {"needs_attention", "failed"}
                for item in self.services
            )
            else "ready"
            if all(item.resultState == "verified" for item in self.services)
            else "incomplete"
        )
        if self.state != expected:
            raise ValueError("invalid_media_recovery_status")
        identifiers = [item.serviceId for item in self.services]
        if len(identifiers) != len(set(identifiers)):
            raise ValueError("invalid_media_recovery_status")
        if identifiers != [
            "larenor_core",
            "qbittorrent",
            "sonarr",
            "radarr",
            "jellyfin",
            "seerr",
            "music_assistant",
        ]:
            raise ValueError("invalid_media_recovery_status")
        return self
