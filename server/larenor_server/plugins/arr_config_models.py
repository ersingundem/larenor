"""Private Arr configuration and secret-free worker execution outcome."""

from typing import Literal

from pydantic import ConfigDict, Field

from ..models import StrictModel


class PrivateArrConfiguration(StrictModel):
    model_config = ConfigDict(extra='forbid', strict=True, frozen=True)

    schemaVersion: Literal[1] = 1
    serviceId: Literal['sonarr', 'radarr']
    apiKey: str = Field(
        min_length=32, max_length=32, pattern=r'^[0-9a-f]{32}$', repr=False,
    )

    def __repr__(self):
        return 'PrivateArrConfiguration(<private>)'


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
