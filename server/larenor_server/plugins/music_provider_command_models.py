"""Public, secret-free authority contracts for provider configuration commands."""

from typing import Literal

from pydantic import Field, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel
from .music_provider_setup_models import ProviderDomain


ProviderCommand = Literal['enable', 'disable']


class CreateMusicProviderCommandPreviewRequest(StrictModel):
    requestId: ObjectId
    installationId: ObjectId
    expectedInstallationRevision: Revision
    providerSetupId: ObjectId
    expectedProviderRevision: Revision
    providerDomain: ProviderDomain
    command: ProviderCommand
    settings: dict = Field(default_factory=dict, max_length=0)

    @model_validator(mode='after')
    def no_public_settings(self):
        if self.settings:
            raise ValueError('provider_settings_are_private')
        return self


class MusicProviderCommandPreview(StrictModel):
    id: ObjectId
    revision: Literal[1]
    installationId: ObjectId
    installationRevision: Revision
    providerSetupId: ObjectId
    providerRevision: Revision
    providerDomain: ProviderDomain
    command: ProviderCommand
    settings: dict = Field(max_length=0)
    planHash: str = Field(pattern=r'^[0-9a-f]{64}$')
    effectAvailable: Literal[False]
    installAvailable: Literal[False]
    blockers: Literal[['effect_unavailable']]
    createdAt: str
    expiresAt: str


class MusicProviderCommandPreviewResponse(StrictModel):
    preview: MusicProviderCommandPreview


class ConfirmMusicProviderCommandRequest(StrictModel):
    requestId: ObjectId
    previewId: ObjectId
    expectedPreviewRevision: Literal[1]
    planHash: str = Field(pattern=r'^[0-9a-f]{64}$')


class MusicProviderCommand(StrictModel):
    id: ObjectId
    revision: Literal[1]
    requestId: ObjectId
    previewId: ObjectId
    installationId: ObjectId
    installationRevision: Revision
    providerSetupId: ObjectId
    providerRevision: Revision
    providerDomain: ProviderDomain
    command: ProviderCommand
    state: Literal['blocked']
    errorCode: Literal['effect_unavailable']
    effectAvailable: Literal[False]
    installAvailable: Literal[False]
    createdAt: str


class MusicProviderCommandResponse(StrictModel):
    command: MusicProviderCommand
