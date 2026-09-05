"""Typed public documentation for the existing release protocol."""

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


class ReleaseManifest(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    schemaVersion: Literal[1]
    applicationId: Literal["com.ersingundem.larenor"]
    versionCode: int = Field(ge=1, le=2147483647)
    versionName: str = Field(min_length=1, max_length=80)
    certificateSha256: str = Field(pattern=r"^[a-fA-F0-9]{64}$")
    apkSha256: str = Field(pattern=r"^[a-fA-F0-9]{64}$")
    sizeBytes: int = Field(ge=1, le=512 * 1024 * 1024)
    minSdk: Literal[26]
    commit: str = Field(pattern=r"^[a-fA-F0-9]{40}$")
    downloadPath: str = Field(pattern=r"^/api/v1/client/releases/[1-9][0-9]{0,9}/apk$")
    publishedAt: str = Field(max_length=64, description="ISO 8601 timestamp with explicit timezone")
    releaseNotes: str = Field(max_length=12000)


class PendingRelease(BaseModel):
    state: Literal["awaitingUpload", "uploaded"]
    uploadId: str
    versionCode: int
    expiresAt: float = Field(description="Unix timestamp in seconds")


class PublishedRelease(BaseModel):
    state: Literal["published"]
    release: ReleaseManifest


class UploadedRelease(BaseModel):
    state: Literal["uploaded"]
    uploadId: str
    versionCode: int
