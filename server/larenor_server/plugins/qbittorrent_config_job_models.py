"""Public and encrypted-private contracts for qBittorrent config jobs."""

from typing import Literal

from pydantic import Field, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel
from .media_installation_models import (
    CancelMediaInstallationRequest, CreateMediaInstallationRequest,
)
from .models import Digest
from .qbittorrent_config_models import PrivateQbittorrentConfiguration
from .stack_plan import MediaStackPlan


CreateQbittorrentConfigurationRequest = CreateMediaInstallationRequest
CancelQbittorrentConfigurationRequest = CancelMediaInstallationRequest


class PrivateQbittorrentReceipt(StrictModel):
    resourceId: ObjectId
    operationId: ObjectId
    journalId: ObjectId
    revision: Revision
    volumeName: str = Field(pattern=r'^larenor-appdata-v1-[0-9a-f]{32}$')
    configurationDigest: Digest
    state: Literal[
        'qbittorrent_config_installed',
        'qbittorrent_config_already_installed',
    ]
    # These fields were added after configuration-only jobs had already been
    # persisted.  Keeping them nullable lets Core read those encrypted receipts
    # without claiming that their container was started.
    containerId: Digest | None = None
    containerState: Literal['qbittorrent_container_started'] | None = None
    serviceState: Literal['qbittorrent_service_verified'] | None = None

    @model_validator(mode='after')
    def coherent(self):
        if self.volumeName != 'larenor-appdata-v1-' + self.resourceId:
            raise ValueError('invalid_qbittorrent_configuration_receipt')
        if (self.containerId is None) != (self.containerState is None):
            raise ValueError('invalid_qbittorrent_configuration_receipt')
        if self.serviceState is not None and self.containerState is None:
            raise ValueError('invalid_qbittorrent_configuration_receipt')
        return self


class QbittorrentConfiguration(StrictModel):
    id: ObjectId
    requestId: ObjectId
    preparationId: ObjectId
    inspectionId: ObjectId
    serviceId: Literal['qbittorrent']
    revision: Revision
    state: Literal[
        'queued', 'running', 'succeeded', 'needs_attention', 'failed',
        'cancelled',
    ]
    phase: Literal['queued', 'configuring', 'complete']
    cancelRequested: bool
    configured: bool
    configurationState: Literal[
        'qbittorrent_config_installed',
        'qbittorrent_config_already_installed',
    ] | None
    containerState: Literal['container_started'] | None
    serviceState: Literal['verified'] | None
    errorCode: Literal[
        'qbittorrent_config_authority_changed',
        'qbittorrent_config_context_changed',
        'qbittorrent_config_preparation_changed',
        'qbittorrent_config_inspection_changed',
        'qbittorrent_config_catalog_changed',
        'qbittorrent_config_resources_unavailable',
        'qbittorrent_config_write_failed',
        'qbittorrent_config_result_invalid',
        'qbittorrent_config_timeout',
        'qbittorrent_config_interrupted',
        'qbittorrent_config_cancellation_uncertain',
        'qbittorrent_config_worker_unavailable',
        'qbittorrent_service_unavailable',
        'qbittorrent_service_changed',
        'qbittorrent_service_verification_failed',
    ] | None
    installAvailable: Literal[False] = False
    createdAt: str
    updatedAt: str

    @model_validator(mode='after')
    def coherent(self):
        if self.state == 'queued' and (
                self.phase != 'queued' or self.revision != 1
                or self.cancelRequested):
            raise ValueError('invalid_qbittorrent_configuration_state')
        if self.state == 'running' and (
                self.phase != 'configuring' or self.revision < 2):
            raise ValueError('invalid_qbittorrent_configuration_state')
        if self.state not in {'queued', 'running'} and (
                self.phase != 'complete' or self.revision < 2):
            raise ValueError('invalid_qbittorrent_configuration_state')
        if self.state == 'succeeded':
            if (not self.configured or self.configurationState is None
                    or self.errorCode is not None or self.cancelRequested):
                raise ValueError('invalid_qbittorrent_configuration_state')
        if self.serviceState is not None and self.containerState is None:
            raise ValueError('invalid_qbittorrent_configuration_state')
        if self.state != 'succeeded' and (
                self.configured or self.configurationState is not None
                or self.containerState is not None or self.serviceState is not None):
            raise ValueError('invalid_qbittorrent_configuration_state')
        if self.state in {'queued', 'running', 'cancelled'} and self.errorCode is not None:
            raise ValueError('invalid_qbittorrent_configuration_state')
        if self.state in {'failed', 'needs_attention'} and self.errorCode is None:
            raise ValueError('invalid_qbittorrent_configuration_state')
        if self.state == 'cancelled' and not self.cancelRequested:
            raise ValueError('invalid_qbittorrent_configuration_state')
        if self.cancelRequested and self.state not in {'running', 'cancelled', 'needs_attention'}:
            raise ValueError('invalid_qbittorrent_configuration_state')
        return self


class QbittorrentConfigurationResponse(StrictModel):
    configuration: QbittorrentConfiguration


class QbittorrentConfigurationsResponse(StrictModel):
    configurations: list[QbittorrentConfiguration] = Field(max_length=10)
    nextBefore: int | None


class QbittorrentConfigurationCapabilities(StrictModel):
    executionConfigured: bool
    installAvailable: Literal[False] = False
    serviceId: Literal['qbittorrent'] = 'qbittorrent'


class QbittorrentConfigurationPayload(StrictModel):
    request: CreateQbittorrentConfigurationRequest
    plan: MediaStackPlan
    private: PrivateQbittorrentConfiguration
    receipt: PrivateQbittorrentReceipt | None = None
