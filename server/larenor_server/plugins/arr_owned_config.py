"""Fixed Sonarr/Radarr config.xml for fresh Larenor-owned instances.

The renderer has no filesystem or network authority.  Its exact bytes are
written only by the managed installation worker after appdata ownership has
been proved.  The services remain on Larenor's private media network and their
API keys never cross the public Client contract.
"""

from dataclasses import dataclass, field
import hmac
import re
import secrets
from typing import Literal


ArrServiceId = Literal['sonarr', 'radarr']

_API_KEY = re.compile(r'[0-9a-f]{32}\Z')
_SERVICE = {
    'sonarr': (8989, 'Larenor Sonarr'),
    'radarr': (7878, 'Larenor Radarr'),
}


class ArrOwnedConfigError(ValueError):
    """Secret-free failure for invalid renderer input."""

    def __init__(self):
        super().__init__('invalid_arr_owned_config')


@dataclass(frozen=True)
class ArrOwnedConfig:
    service_id: ArrServiceId
    relative_path: Literal['config.xml'] = 'config.xml'
    configuration: bytes = field(default=b'', repr=False)


def is_arr_api_key(value):
    """Match upstream's lower-case, hyphen-free Guid representation."""
    return type(value) is str and _API_KEY.fullmatch(value) is not None


def generate_arr_api_key():
    return secrets.token_hex(16)


def render_arr_owned_config(service_id, api_key):
    """Render only the allowlisted identity, listener and policy settings."""
    try:
        if type(service_id) is not str or service_id not in _SERVICE:
            raise ValueError()
        if not is_arr_api_key(api_key):
            raise ValueError()
        port, instance_name = _SERVICE[service_id]
        configuration = (
            '<?xml version="1.0" encoding="utf-8" standalone="yes"?>\n'
            '<Config>\n'
            '  <BindAddress>*</BindAddress>\n'
            f'  <Port>{port}</Port>\n'
            '  <EnableSsl>False</EnableSsl>\n'
            '  <LaunchBrowser>False</LaunchBrowser>\n'
            f'  <ApiKey>{api_key}</ApiKey>\n'
            '  <AuthenticationMethod>None</AuthenticationMethod>\n'
            '  <AuthenticationRequired>Enabled</AuthenticationRequired>\n'
            '  <AnalyticsEnabled>False</AnalyticsEnabled>\n'
            '  <UpdateAutomatically>False</UpdateAutomatically>\n'
            '  <LogLevel>info</LogLevel>\n'
            f'  <InstanceName>{instance_name}</InstanceName>\n'
            '</Config>\n'
        ).encode('ascii')
        return ArrOwnedConfig(
            service_id=service_id, configuration=configuration)
    except (ValueError, TypeError, AttributeError, UnicodeError):
        raise ArrOwnedConfigError() from None


def verify_arr_owned_config(configuration, service_id, *, api_key):
    """Reject every byte that is not part of the owned canonical config."""
    try:
        if (type(configuration) is not bytes
                or not 1 <= len(configuration) <= 4096):
            return False
        expected = render_arr_owned_config(service_id, api_key)
        return hmac.compare_digest(configuration, expected.configuration)
    except (ValueError, TypeError, AttributeError, UnicodeError,
            ArrOwnedConfigError):
        return False
