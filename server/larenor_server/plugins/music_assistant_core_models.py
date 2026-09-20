"""Closed public and private contracts for the managed music engine."""

import re
from typing import Literal

from pydantic import Field, field_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel


class AuthenticatedMusicAssistantReadback(StrictModel):
    token: str = Field(min_length=1, max_length=2048, repr=False)
    serverId: str = Field(min_length=1, max_length=128)
    serverVersion: str = Field(min_length=1, max_length=80)
    schemaVersion: int = Field(ge=1, le=2**31 - 1)

    @field_validator('token', 'serverId')
    @classmethod
    def safe_private_text(cls, value):
        if any(ord(char) < 32 or ord(char) == 127 for char in value):
            raise ValueError('invalid_music_assistant_readback')
        return value

    @field_validator('serverVersion')
    @classmethod
    def safe_version(cls, value):
        if re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9 ._+:/()\-]{0,79}', value) is None:
            raise ValueError('invalid_music_assistant_readback')
        return value


class MusicAssistantPeer(StrictModel):
    serviceId: ObjectId
    serviceRevision: Revision


class MusicAssistantCoreReadiness(StrictModel):
    installationId: ObjectId
    installationRevision: Revision
    revision: Revision
    state: Literal['verified', 'needs_attention']
    serverVersion: str = Field(min_length=1, max_length=80)
    schemaVersion: int = Field(ge=1, le=2**31 - 1)
    homeAssistant: MusicAssistantPeer
    jellyfin: MusicAssistantPeer
    errorCode: Literal['dependency_changed', 'installation_changed'] | None
    installAvailable: Literal[False] = False


class MusicAssistantCoreReadinessResponse(StrictModel):
    readiness: MusicAssistantCoreReadiness


class MusicAssistantKeyRotationRequest(StrictModel):
    """Private Core request. Credentials are deliberately absent."""

    requestId: ObjectId
    coreId: ObjectId
    homeId: ObjectId
    installationId: ObjectId
    expectedInstallationRevision: Revision
    expectedWorkerRevision: Revision
    providerSetupId: ObjectId
    expectedProviderRevision: Revision
    providerInstanceId: str = Field(min_length=1, max_length=128)

    @field_validator('providerInstanceId')
    @classmethod
    def safe_provider_instance(cls, value):
        if re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}', value) is None:
            raise ValueError('invalid_music_assistant_key_rotation')
        return value


class AuthenticatedMusicAssistantKeyRotationReadback(StrictModel):
    """Worker-only authenticated result; never registered in HTTP models."""

    requestId: ObjectId
    readback: AuthenticatedMusicAssistantReadback = Field(repr=False)
    previousTokenRetired: bool


class PrivateMusicAssistantKeyRotationAction(StrictModel):
    request: MusicAssistantKeyRotationRequest
    phase: Literal['preparing', 'activated']
    currentToken: str = Field(min_length=1, max_length=2048, repr=False)
    replacementToken: str | None = Field(
        default=None, min_length=1, max_length=2048, repr=False)


class MusicAssistantKeyRotationReceipt(StrictModel):
    requestId: ObjectId
    installationId: ObjectId
    installationRevision: Revision
    workerRevision: Revision
    providerSetupId: ObjectId
    providerRevision: Revision
    providerInstanceId: str = Field(min_length=1, max_length=128)
    state: Literal['retired']


class _StoredMusicAssistantKeyRotation(StrictModel):
    request: MusicAssistantKeyRotationRequest
    previous: '_StoredMusicAssistantCore' = Field(repr=False)
    replacement: AuthenticatedMusicAssistantReadback | None = Field(
        default=None, repr=False)


class _StoredMusicAssistantCore(AuthenticatedMusicAssistantReadback):
    homeAssistant: MusicAssistantPeer
    jellyfin: MusicAssistantPeer
