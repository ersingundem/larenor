"""Public and encrypted-private contracts for Arr config jobs."""

from typing import Literal

from pydantic import Field, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel
from .media_installation_models import (
    CancelMediaInstallationRequest, CreateMediaInstallationRequest,
)
from .models import Digest
from .arr_config_models import PrivateArrConfiguration
from .stack_plan import MediaStackPlan


class CreateArrConfigurationRequest(CreateMediaInstallationRequest):
    serviceId: Literal['sonarr', 'radarr']
CancelArrConfigurationRequest = CancelMediaInstallationRequest


class PrivateArrReceipt(StrictModel):
    serviceId: Literal['sonarr', 'radarr']
    resourceId: ObjectId
    operationId: ObjectId
    journalId: ObjectId
    revision: Revision
    volumeName: str = Field(pattern=r'^larenor-appdata-v1-[0-9a-f]{32}$')
    configurationDigest: Digest
    state: Literal[
        'sonarr_config_installed', 'sonarr_config_already_installed',
        'radarr_config_installed', 'radarr_config_already_installed',
    ]
    containerId: str = Field(pattern=r'^[0-9a-f]{64}$')
    containerState: Literal['sonarr_container_started', 'radarr_container_started']
    serviceState: Literal['sonarr_service_verified', 'radarr_service_verified']

    @model_validator(mode='after')
    def coherent(self):
        if self.volumeName != 'larenor-appdata-v1-' + self.resourceId:
            raise ValueError('invalid_arr_configuration_receipt')
        if not self.state.startswith(self.serviceId + '_config_'):
            raise ValueError('invalid_arr_configuration_receipt')
        if (self.containerState != self.serviceId + '_container_started'
                or self.serviceState != self.serviceId + '_service_verified'):
            raise ValueError('invalid_arr_configuration_receipt')
        return self


class ArrConfiguration(StrictModel):
    id: ObjectId
    requestId: ObjectId
    preparationId: ObjectId
    inspectionId: ObjectId
    serviceId: Literal['sonarr', 'radarr']
    revision: Revision
    state: Literal[
        'queued', 'running', 'succeeded', 'needs_attention', 'failed',
        'cancelled',
    ]
    phase: Literal['queued', 'configuring', 'complete']
    cancelRequested: bool
    configured: bool
    configurationState: Literal[
        'sonarr_config_installed', 'sonarr_config_already_installed',
        'radarr_config_installed', 'radarr_config_already_installed',
    ] | None
    containerState: Literal['container_started'] | None
    serviceState: Literal['verified'] | None
    errorCode: Literal[
        'arr_config_authority_changed',
        'arr_config_context_changed',
        'arr_config_preparation_changed',
        'arr_config_inspection_changed',
        'arr_config_catalog_changed',
        'arr_config_resources_unavailable',
        'arr_config_write_failed',
        'arr_config_result_invalid',
        'arr_config_timeout',
        'arr_config_interrupted',
        'arr_config_cancellation_uncertain',
        'arr_config_worker_unavailable',
    ] | None
    installAvailable: Literal[False] = False
    createdAt: str
    updatedAt: str

    @model_validator(mode='after')
    def coherent(self):
        if self.state == 'queued' and (
                self.phase != 'queued' or self.revision != 1
                or self.cancelRequested):
            raise ValueError('invalid_arr_configuration_state')
        if self.state == 'running' and (
                self.phase != 'configuring' or self.revision < 2):
            raise ValueError('invalid_arr_configuration_state')
        if self.state not in {'queued', 'running'} and (
                self.phase != 'complete' or self.revision < 2):
            raise ValueError('invalid_arr_configuration_state')
        if self.state == 'succeeded':
            if (not self.configured or self.configurationState is None
                    or self.errorCode is not None or self.cancelRequested):
                raise ValueError('invalid_arr_configuration_state')
        elif self.configured or self.configurationState is not None:
            raise ValueError('invalid_arr_configuration_state')
        if self.state == 'succeeded':
            if self.containerState != 'container_started' or self.serviceState != 'verified':
                raise ValueError('invalid_arr_configuration_state')
        elif self.containerState is not None or self.serviceState is not None:
            raise ValueError('invalid_arr_configuration_state')
        if self.state in {'queued', 'running', 'cancelled'} and self.errorCode is not None:
            raise ValueError('invalid_arr_configuration_state')
        if self.state in {'failed', 'needs_attention'} and self.errorCode is None:
            raise ValueError('invalid_arr_configuration_state')
        if self.state == 'cancelled' and not self.cancelRequested:
            raise ValueError('invalid_arr_configuration_state')
        if self.cancelRequested and self.state not in {'running', 'cancelled', 'needs_attention'}:
            raise ValueError('invalid_arr_configuration_state')
        return self


class ArrConfigurationResponse(StrictModel):
    configuration: ArrConfiguration


class ArrConfigurationsResponse(StrictModel):
    configurations: list[ArrConfiguration] = Field(max_length=10)
    nextBefore: int | None


class ArrConfigurationCapabilities(StrictModel):
    executionConfigured: bool
    installAvailable: Literal[False] = False
    serviceIds: tuple[Literal['sonarr'], Literal['radarr']] = ('sonarr', 'radarr')


class ArrConfigurationPayload(StrictModel):
    request: CreateArrConfigurationRequest
    plan: MediaStackPlan
    private: PrivateArrConfiguration
    receipt: PrivateArrReceipt | None = None
