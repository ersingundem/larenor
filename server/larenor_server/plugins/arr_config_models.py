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


class ArrConfigurationExecutionError(Exception):
    """Closed error crossing the Core-to-worker boundary."""

    def __init__(self, code='arr_config_resources_unavailable', *,
                 uncertain_effect=False):
        self.code = (code if code in ARR_CONFIG_EXECUTION_CODES
                     else 'arr_config_resources_unavailable')
        self.uncertain_effect = uncertain_effect is True
        super().__init__(self.code)

    def __repr__(self):
        return (f'ArrConfigurationExecutionError({self.code!r}, '
                f'uncertain_effect={self.uncertain_effect!r})')
