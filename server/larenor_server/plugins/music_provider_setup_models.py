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
    state: Literal['queued', 'action_required', 'ready', 'cancelled', 'needs_attention']
    nextAction: Literal['awaiting_core_discovery', 'continue_in_larenor', 'retry', 'none']
    interaction: Literal['open_external', 'submit_form'] | None
    fields: list[ProviderSetupEntry] = Field(max_length=16)
    providerInstanceId: str | None = Field(default=None, max_length=128)
    installAvailable: Literal[False] = False
    createdAt: str
    updatedAt: str


class MusicProviderSetupResponse(StrictModel):
    setup: MusicProviderSetup


class SubmitMusicProviderSetupRequest(StrictModel):
    expectedRevision: Revision
    stepId: str = Field(min_length=1, max_length=80)
    values: dict[str, str | bool] = Field(max_length=16, repr=False)


class ContinueMusicProviderSetupRequest(StrictModel):
    expectedRevision: Revision


class PrivateMusicProviderSetupAction(StrictModel):
    setupId: ObjectId
    providerDomain: ProviderDomain
    command: Literal['start', 'submit', 'resume', 'abort']
    flowId: str | None = Field(default=None, min_length=1, max_length=128, repr=False)
    stepId: str | None = Field(default=None, min_length=1, max_length=80)
    values: dict[str, str | bool] = Field(default_factory=dict, max_length=16, repr=False)
    token: str = Field(min_length=1, max_length=2048, repr=False)

    @model_validator(mode='after')
    def coherent_action(self):
        if self.command == 'start':
            valid = self.flowId is None and self.stepId is None and not self.values
        elif self.command == 'submit':
            valid = self.flowId is not None and self.stepId is not None
        else:
            valid = self.flowId is not None and self.stepId is None and not self.values
        if not valid:
            raise ValueError('invalid_provider_setup_action')
        return self


class ProviderSetupWorkerResult(StrictModel):
    state: Literal['action_required', 'ready', 'cancelled']
    providerDomain: ProviderDomain
    discovery: ProviderSetupDiscovery | None = None
    providerInstanceId: str | None = Field(default=None, min_length=1, max_length=128)

    @field_validator('providerInstanceId')
    @classmethod
    def safe_instance_id(cls, value):
        if (value is not None
                and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}',
                                 value) is None):
            raise ValueError('invalid_provider_setup_worker_result')
        return value

    @model_validator(mode='after')
    def coherent_result(self):
        if ((self.state == 'action_required') != (self.discovery is not None)
                or (self.state == 'ready') != (self.providerInstanceId is not None)
                or self.state == 'cancelled'
                and (self.discovery is not None or self.providerInstanceId is not None)):
            raise ValueError('invalid_provider_setup_worker_result')
        if self.discovery is not None and self.discovery.providerDomain != self.providerDomain:
            raise ValueError('invalid_provider_setup_worker_result')
        return self


class _StoredMusicProviderSetup(StrictModel):
    request: CreateMusicProviderSetupRequest
    discovery: ProviderSetupDiscovery | None = None
    status: Literal['queued', 'action_required', 'ready', 'cancelled', 'needs_attention'] = 'queued'
    providerInstanceId: str | None = Field(default=None, max_length=128)
    pendingCommand: Literal['submit', 'resume', 'abort'] | None = None
    pendingStepId: str | None = Field(default=None, max_length=80)
    pendingValues: dict[str, str | bool] = Field(default_factory=dict, max_length=16, repr=False)
