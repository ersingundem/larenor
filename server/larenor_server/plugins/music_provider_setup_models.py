"""Strict public and private contracts for Music Assistant provider setup flows."""

import re
from typing import Literal
from urllib.parse import urlsplit

from pydantic import Field, field_validator, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel


ProviderDomain = Literal['spotify', 'apple_music', 'ytmusic']


class CreateMusicProviderSetupRequest(StrictModel):
    requestId: ObjectId
    installationId: ObjectId
    expectedInstallationRevision: Revision
    providerDomain: ProviderDomain


class ProviderSetupEntry(StrictModel):
    key: str = Field(min_length=1, max_length=80)
    type: Literal['string', 'secure_string', 'boolean']
    required: bool

    @field_validator('key')
    @classmethod
    def safe_key(cls, value):
        if re.fullmatch(r'[a-z][a-z0-9_]{0,79}', value) is None:
            raise ValueError('invalid_provider_setup_entry')
        return value


class ProviderSetupDiscovery(StrictModel):
    providerDomain: ProviderDomain
    flowId: str = Field(min_length=1, max_length=128, repr=False)
    stepId: str = Field(min_length=1, max_length=80)
    kind: Literal['external', 'form']
    externalUrl: str | None = Field(default=None, max_length=4096, repr=False)
    expiresAt: int = Field(ge=1, le=253402300799)
    entries: list[ProviderSetupEntry] = Field(max_length=16)

    @field_validator('flowId', 'stepId')
    @classmethod
    def safe_id(cls, value):
        if re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}', value) is None:
            raise ValueError('invalid_provider_setup_discovery')
        return value

    @model_validator(mode='after')
    def coherent(self):
        if self.kind == 'external':
            if self.externalUrl is None or self.entries:
                raise ValueError('invalid_provider_setup_discovery')
            parsed = urlsplit(self.externalUrl)
            if (parsed.scheme != 'https' or not parsed.hostname
                    or parsed.username is not None or parsed.password is not None
                    or parsed.fragment):
                raise ValueError('invalid_provider_setup_discovery')
        elif self.externalUrl is not None or not self.entries:
            raise ValueError('invalid_provider_setup_discovery')
        if len({entry.key for entry in self.entries}) != len(self.entries):
            raise ValueError('invalid_provider_setup_discovery')
        return self


class MusicProviderCapability(StrictModel):
    providerDomain: ProviderDomain
    name: Literal['Spotify', 'Apple Music', 'YouTube Music']
    stage: Literal['stable', 'beta']
    multiInstance: Literal[True] = True
    interaction: Literal[
        'oauth_and_playback_approval',
        'musickit_or_secure_manual_token',
        'secure_cookie_and_po_token_service',
    ]


class MusicProviderSetupCapabilities(StrictModel):
    installAvailable: Literal[False] = False
    setupEngine: Literal['music_assistant_setup_flow'] = 'music_assistant_setup_flow'
    providers: list[MusicProviderCapability] = Field(min_length=3, max_length=3)


class MusicProviderSetup(StrictModel):
    id: ObjectId
    requestId: ObjectId
    installationId: ObjectId
    installationRevision: Revision
    providerDomain: ProviderDomain
    revision: Revision
    state: Literal['queued', 'action_required']
    nextAction: Literal['awaiting_core_discovery', 'continue_in_larenor']
    interaction: Literal['open_external', 'submit_form'] | None
    fields: list[ProviderSetupEntry] = Field(max_length=16)
    installAvailable: Literal[False] = False
    createdAt: str
    updatedAt: str


class MusicProviderSetupResponse(StrictModel):
    setup: MusicProviderSetup


class _StoredMusicProviderSetup(StrictModel):
    request: CreateMusicProviderSetupRequest
    discovery: ProviderSetupDiscovery | None = None
