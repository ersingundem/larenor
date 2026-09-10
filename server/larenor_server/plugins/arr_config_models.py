"""Private Arr configuration and secret-free worker execution outcome."""

from dataclasses import dataclass
import re
from typing import Literal

from pydantic import ConfigDict, Field

from ..models import StrictModel
from .arr_config_effect import ArrConfigInstallReceipt


class PrivateArrConfiguration(StrictModel):
    model_config = ConfigDict(extra='forbid', strict=True, frozen=True)

    schemaVersion: Literal[1] = 1
    serviceId: Literal['sonarr', 'radarr']
    apiKey: str = Field(
        min_length=32, max_length=32, pattern=r'^[0-9a-f]{32}$', repr=False,
    )

    def __repr__(self):
        return 'PrivateArrConfiguration(<private>)'


@dataclass(frozen=True)
class ArrConfiguredInstallReceipt:
    configuration: ArrConfigInstallReceipt
    container_id: str
    state: Literal['sonarr_container_started', 'radarr_container_started']
    service_state: Literal['sonarr_service_verified', 'radarr_service_verified']

    def __post_init__(self):
        service = getattr(self.configuration, 'service_id', None)
        if (type(self.configuration) is not ArrConfigInstallReceipt
                or service not in {'sonarr', 'radarr'}
                or type(self.container_id) is not str
                or re.fullmatch(r'[0-9a-f]{64}', self.container_id) is None
                or self.state != service + '_container_started'
                or self.service_state != service + '_service_verified'):
            raise ValueError('invalid_arr_install_receipt')


ARR_CONFIG_EXECUTION_CODES = frozenset({
    'arr_config_authority_changed',
    'arr_config_resources_unavailable',
    'arr_config_write_failed',
    'arr_config_result_invalid',
    'arr_config_timeout',
})
ARR_CONFIG_CAUSE_CODES = frozenset({
    'arr_configure_stage_failed',
    'arr_execution_stage_failed',
    'arr_bootstrap_stage_failed',
    'arr_receipt_stage_failed',
    'arr_execution_authority_changed',
    'arr_execution_cancelled',
    'arr_execution_worker_unavailable',
    'arr_execution_invalid_worker_result',
    'arr_execution_resource_conflict',
    'arr_execution_container_not_running',
    'arr_execution_dispatch_expired',
    'invalid_arr_authenticated_readback',
    'arr_authentication_failed',
    'arr_readback_protocol',
    'arr_readback_mismatch',
    'arr_authenticated_readback_unavailable',
    'arr_authenticated_readback_timeout',
    'arr_bootstrap_resources_unavailable',
    'arr_bootstrap_authority_changed',
    'arr_bootstrap_endpoint_unavailable',
    'arr_bootstrap_endpoint_changed',
    'arr_bootstrap_readback_failed',
    'arr_bootstrap_timeout',
    'arr_bootstrap_before_connect_failed',
    'arr_bootstrap_after_connect_failed',
    'arr_bootstrap_after_readback_failed',
})


class ArrConfigurationExecutionError(Exception):
    """Closed error crossing the Core-to-worker boundary."""

    def __init__(self, code='arr_config_resources_unavailable', *,
                 uncertain_effect=False, cause_code=None):
        self.code = (code if code in ARR_CONFIG_EXECUTION_CODES
                     else 'arr_config_resources_unavailable')
        self.uncertain_effect = uncertain_effect is True
        self.cause_code = (
            cause_code if cause_code in ARR_CONFIG_CAUSE_CODES else None)
        super().__init__(self.code)

    def __repr__(self):
        return (f'ArrConfigurationExecutionError({self.code!r}, '
                f'uncertain_effect={self.uncertain_effect!r}, '
                f'cause_code={self.cause_code!r})')
