"""Public and encrypted-private contracts for S06.5 bootstrap intent."""

from typing import Literal

from pydantic import ConfigDict, Field, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel


class CreateMediaServiceBootstrapRequest(StrictModel):
    requestId: ObjectId
    installationId: ObjectId
    expectedInstallationRevision: Revision


class MediaServiceBootstrap(StrictModel):
    id: ObjectId
    requestId: ObjectId
    installationId: ObjectId
    serviceId: Literal['jellyfin']
    revision: Revision
    state: Literal['queued', 'running', 'credentials_configured', 'wiring_partial',
                   'succeeded', 'needs_attention', 'failed', 'cancelled']
    credentialsConfigured: bool
    wiringState: Literal['pending', 'partial', 'verified']
    errorCode: Literal[
        'bootstrap_authority_changed', 'bootstrap_resources_unavailable',
        'bootstrap_endpoint_unavailable', 'bootstrap_endpoint_changed',
        'bootstrap_startup_failed', 'bootstrap_timeout', 'bootstrap_interrupted',
        'bootstrap_worker_unavailable', 'invalid_bootstrap_result',
    ] | None
    installAvailable: Literal[False] = False
    createdAt: str
    updatedAt: str

    @model_validator(mode='after')
    def coherent(self):
        if self.state in ('queued', 'running') and (
                self.credentialsConfigured or self.wiringState != 'pending'):
            raise ValueError('invalid_media_bootstrap_state')
        if not self.credentialsConfigured and self.wiringState != 'pending':
            raise ValueError('invalid_media_bootstrap_state')
        if self.wiringState in ('partial', 'verified') and not self.credentialsConfigured:
            raise ValueError('invalid_media_bootstrap_state')
        if self.state == 'credentials_configured' and (
                not self.credentialsConfigured or self.wiringState != 'pending'):
            raise ValueError('invalid_media_bootstrap_state')
        if self.state == 'wiring_partial' and (
                not self.credentialsConfigured or self.wiringState != 'partial'):
            raise ValueError('invalid_media_bootstrap_state')
        if self.state == 'succeeded' and (
                not self.credentialsConfigured or self.wiringState != 'verified'):
            raise ValueError('invalid_media_bootstrap_state')
        if self.state != 'succeeded' and self.wiringState == 'verified':
            raise ValueError('invalid_media_bootstrap_state')
        if self.state in ('queued', 'running', 'credentials_configured',
                          'wiring_partial', 'succeeded', 'cancelled') and self.errorCode is not None:
            raise ValueError('invalid_media_bootstrap_state')
        if self.state in ('needs_attention', 'failed') and self.errorCode is None:
            raise ValueError('invalid_media_bootstrap_state')
        return self


class MediaServiceBootstrapResponse(StrictModel):
    bootstrap: MediaServiceBootstrap


class MediaServiceBootstrapsResponse(StrictModel):
    bootstraps: list[MediaServiceBootstrap] = Field(max_length=10)
    nextBefore: int | None


class PrivateMediaServiceBootstrap(StrictModel):
    model_config = ConfigDict(extra='forbid', strict=True, frozen=True)

    schemaVersion: Literal[1] = 1
    username: Literal['larenor-system'] = 'larenor-system'
    credential: str = Field(min_length=32, max_length=128, repr=False,
                            pattern=r'^[A-Za-z0-9_-]+$')
    locale: Literal['tr-TR'] = 'tr-TR'
    metadataCountryCode: Literal['TR'] = 'TR'
    preferredMetadataLanguage: Literal['tr'] = 'tr'
    remote_access: Literal[False] = False
    automatic_port_mapping: Literal[False] = False
