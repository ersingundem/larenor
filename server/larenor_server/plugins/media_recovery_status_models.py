"""Secret-free, read-only recovery status for managed media services."""

from typing import Literal

from pydantic import Field, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel


ManagedMediaService = Literal[
    "qbittorrent", "sonarr", "radarr", "jellyfin", "seerr",
    "music_assistant",
]


class MediaRecoveryService(StrictModel):
    serviceId: ManagedMediaService
    sourceId: ObjectId
    sourceKind: Literal["installation", "configuration", "bootstrap"]
    revision: Revision
    resultState: Literal[
        "pending", "partial", "verified", "cancelled", "needs_attention",
        "failed",
    ]
    containerState: Literal["pending", "started", "unknown"]
    serviceState: Literal["unverified", "verified"]
    recoveryAction: Literal["wait", "configure", "review", "retry", "none"]
    automaticRetry: Literal[False] = False
    errorCode: str | None = Field(
        default=None, pattern=r"^[a-z][a-z0-9_]{0,127}$")
    updatedAt: str

    @model_validator(mode="after")
    def coherent(self):
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
    schemaVersion: Literal[1] = 1
    state: Literal["unknown", "incomplete", "attention", "ready"]
    installAvailable: Literal[False] = False
    services: list[MediaRecoveryService] = Field(max_length=6)

    @model_validator(mode="after")
    def coherent(self):
        expected = (
            "unknown" if not self.services
            else "attention" if any(
                item.resultState in {"needs_attention", "failed"}
                for item in self.services
            )
            else "ready" if len(self.services) == 6 and all(
                item.resultState == "verified" for item in self.services)
            else "incomplete"
        )
        if self.state != expected:
            raise ValueError("invalid_media_recovery_status")
        identifiers = [item.serviceId for item in self.services]
        if len(identifiers) != len(set(identifiers)):
            raise ValueError("invalid_media_recovery_status")
        return self
