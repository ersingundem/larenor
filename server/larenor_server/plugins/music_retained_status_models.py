"""Secret-free retained Music Assistant inventory contract."""

from typing import Literal

from pydantic import Field, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel


class RetainedServiceRevision(StrictModel):
    serviceId: ObjectId
    serviceRevision: Revision


class RetainedBootstrapReceipt(StrictModel):
    revision: Revision
    state: Literal['ready', 'failed']
    serverVersion: str = Field(min_length=1, max_length=80)
    schemaVersion: int = Field(ge=1, le=2**31 - 1)
    homeAssistant: RetainedServiceRevision
    jellyfin: RetainedServiceRevision


class RetainedProviderSetup(StrictModel):
    id: ObjectId
    providerDomain: Literal['spotify', 'apple_music', 'ytmusic']
    revision: Revision
    state: Literal[
        'queued', 'action_required', 'ready', 'cancelled', 'needs_attention']
    updatedAt: str


class RetainedMusicInstallation(StrictModel):
    installationId: ObjectId
    installationRevision: Revision
    installationState: Literal[
        'queued', 'running', 'container_started', 'needs_attention',
        'failed', 'cancelled']
    state: Literal['partial', 'failed', 'ready']
    errorCode: Literal[
        'installation_pending', 'installation_failed', 'bootstrap_unknown',
        'installation_changed', 'dependency_changed', 'provider_not_ready',
        'provider_failed'] | None
    bootstrapReceipt: RetainedBootstrapReceipt | None
    providers: list[RetainedProviderSetup] = Field(max_length=256)

    @model_validator(mode='after')
    def coherent(self):
        if ((self.bootstrapReceipt is None)
                != (self.errorCode in {
                    'installation_pending', 'installation_failed',
                    'bootstrap_unknown'})):
            raise ValueError('invalid_music_retained_status')
        if self.state == 'ready' and (
                self.errorCode is not None or self.bootstrapReceipt is None
                or self.bootstrapReceipt.state != 'ready'
                or not any(item.state == 'ready' for item in self.providers)):
            raise ValueError('invalid_music_retained_status')
        if self.state == 'failed' and self.errorCode is None:
            raise ValueError('invalid_music_retained_status')
        if self.state == 'partial' and self.errorCode not in {
                'installation_pending', 'bootstrap_unknown',
                'provider_not_ready'}:
            raise ValueError('invalid_music_retained_status')
        return self


class MusicRetainedStatusResponse(StrictModel):
    schemaVersion: Literal[1] = 1
    state: Literal['unknown', 'partial', 'failed', 'ready']
    installAvailable: Literal[False] = False
    installations: list[RetainedMusicInstallation] = Field(max_length=64)

    @model_validator(mode='after')
    def coherent(self):
        expected = (
            'unknown' if not self.installations
            else 'failed' if any(item.state == 'failed'
                                 for item in self.installations)
            else 'ready' if all(item.state == 'ready'
                                for item in self.installations)
            else 'partial')
        if self.state != expected:
            raise ValueError('invalid_music_retained_status')
        if len({item.installationId for item in self.installations}) != len(
                self.installations):
            raise ValueError('invalid_music_retained_status')
        return self
