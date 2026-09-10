"""Private qBittorrent configuration and secret-free execution outcome."""

from dataclasses import dataclass
import re
from typing import Literal

from pydantic import ConfigDict, Field

from ..models import StrictModel
from .qbittorrent_config_effect import QbittorrentConfigInstallReceipt


class PrivateQbittorrentConfiguration(StrictModel):
    model_config = ConfigDict(extra='forbid', strict=True, frozen=True)

    schemaVersion: Literal[1] = 1
    credential: str = Field(
        min_length=32, max_length=128, pattern=r'^[A-Za-z0-9_-]+$', repr=False,
    )
    apiKey: str = Field(
        min_length=32, max_length=128, pattern=r'^[A-Za-z0-9_-]+$', repr=False,
    )
    saltHex: str = Field(pattern=r'^[0-9a-f]{32}$', repr=False)

    def __repr__(self):
        return 'PrivateQbittorrentConfiguration(<private>)'


@dataclass(frozen=True)
class QbittorrentConfiguredInstallReceipt:
    configuration: QbittorrentConfigInstallReceipt
    container_id: str
    state: Literal['qbittorrent_container_started']

    def __post_init__(self):
        if (type(self.configuration) is not QbittorrentConfigInstallReceipt
                or type(self.container_id) is not str
                or re.fullmatch(r'[0-9a-f]{64}', self.container_id) is None
                or self.state != 'qbittorrent_container_started'):
            raise ValueError('invalid_qbittorrent_install_receipt')


QB_CONFIG_EXECUTION_CODES = frozenset({
    'qbittorrent_config_authority_changed',
    'qbittorrent_config_resources_unavailable',
    'qbittorrent_config_write_failed',
    'qbittorrent_config_result_invalid',
    'qbittorrent_config_timeout',
})


class QbittorrentConfigurationExecutionError(Exception):
    """Closed error crossing the Core-to-worker boundary."""

    def __init__(self, code='qbittorrent_config_resources_unavailable', *,
                 uncertain_effect=False):
        self.code = (code if code in QB_CONFIG_EXECUTION_CODES
                     else 'qbittorrent_config_resources_unavailable')
        self.uncertain_effect = uncertain_effect is True
        super().__init__(self.code)

    def __repr__(self):
        return (f'QbittorrentConfigurationExecutionError({self.code!r}, '
                f'uncertain_effect={self.uncertain_effect!r})')
