"""Public and encrypted-private contracts for S06.5 bootstrap intent."""

from typing import Literal

from pydantic import ConfigDict, Field, field_validator, model_validator

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
        'bootstrap_startup_failed', 'bootstrap_readback_failed',
        'bootstrap_timeout', 'bootstrap_interrupted',
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


class PrivateMediaLibrary(StrictModel):
    model_config = ConfigDict(extra='forbid', strict=True, frozen=True)

    name: str = Field(min_length=1, max_length=128)
    collectionType: str | None = Field(
        default=None, pattern=r'^[a-z][a-z0-9_-]{0,31}$')
    itemId: str = Field(pattern=r'^[0-9a-f]{32}$')
    locations: tuple[str, ...] = Field(max_length=16, repr=False)

    @field_validator('name')
    @classmethod
    def safe_name(cls, value):
        if value != value.strip() or any(ord(char) < 32 or ord(char) == 127 for char in value):
            raise ValueError('invalid_private_media_library')
        return value

    @field_validator('locations')
    @classmethod
    def managed_locations(cls, value):
        for path in value:
            if (type(path) is not str or not 7 <= len(path) <= 1024
                    or not path.startswith('/media/') or path.endswith('/')
                    or '//' in path or any(part in {'', '.', '..'} for part in path.split('/')[2:])
                    or any(ord(char) < 32 or ord(char) > 126 for char in path)):
                raise ValueError('invalid_private_media_library')
        return value


class PrivateJellyfinReadback(StrictModel):
    model_config = ConfigDict(extra='forbid', strict=True, frozen=True)

    apiKey: str = Field(min_length=32, max_length=128, repr=False,
                        pattern=r'^[A-Za-z0-9_-]+$')
    serverId: str = Field(pattern=r'^[0-9a-f]{32}$')
    serverName: str = Field(min_length=1, max_length=128)
    version: str = Field(
        pattern=r'^[0-9]{1,4}(?:\.[0-9]{1,4}){2,3}(?:[-+][0-9A-Za-z.-]{1,64})?$')
    libraries: tuple[PrivateMediaLibrary, ...] = Field(max_length=256, repr=False)

    @field_validator('serverName')
    @classmethod
    def safe_server_name(cls, value):
        if value != value.strip() or any(ord(char) < 32 or ord(char) == 127 for char in value):
            raise ValueError('invalid_private_jellyfin_readback')
        return value


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
    readback: PrivateJellyfinReadback | None = Field(default=None, repr=False)
