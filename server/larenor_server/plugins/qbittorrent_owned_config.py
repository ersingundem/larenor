"""Fixed qBittorrent 5.2.3 config seed for a fresh Larenor-owned instance.

The renderer has no filesystem or network authority.  A later worker step must
bind these bytes to the already verified qBittorrent appdata volume and prove
the authenticated API readback before installation can become available.
"""

from dataclasses import dataclass, field
import base64
import binascii
import hashlib
import hmac
import re

from .qbittorrent_api_key import is_qbittorrent_api_key


_CREDENTIAL = re.compile(r'[A-Za-z0-9_-]{32,128}\Z')
_ITERATIONS = 100_000
_KEY_BYTES = 64
_SALT_BYTES = 16


class QbittorrentOwnedConfigError(ValueError):
    """Closed, secret-free failure for untrusted renderer inputs."""

    def __init__(self):
        super().__init__('invalid_qbittorrent_owned_config')


@dataclass(frozen=True)
class QbittorrentOwnedConfig:
    relative_path: str
    password_hash: str = field(repr=False)
    configuration: bytes = field(repr=False)


def _valid_credential(value):
    return type(value) is str and _CREDENTIAL.fullmatch(value) is not None


def _password_hash(credential, salt):
    derived = hashlib.pbkdf2_hmac(
        'sha512', credential.encode('utf-8'), salt, _ITERATIONS,
        dklen=_KEY_BYTES)
    return (base64.b64encode(salt).decode('ascii') + ':'
            + base64.b64encode(derived).decode('ascii'))


def render_qbittorrent_owned_config(credential, *, api_key, salt, web_port=8080,
                                    torrent_port=6881):
    """Render only allowlisted identity, listener and managed-path settings."""
    try:
        if (not _valid_credential(credential) or not is_qbittorrent_api_key(api_key)
                or type(salt) is not bytes
                or len(salt) != _SALT_BYTES
                or type(web_port) is not int or not 1024 <= web_port <= 65535
                or type(torrent_port) is not int or not 1024 <= torrent_port <= 65535):
            raise ValueError()
        password_hash = _password_hash(credential, salt)
        text = (
            '[BitTorrent]\n'
            'Session\\DefaultSavePath=/data/downloads\n'
            f'Session\\Port={torrent_port}\n'
            'Session\\TempPath=/data/incomplete\n'
            'Session\\TempPathEnabled=true\n\n'
            '[Preferences]\n'
            f'WebUI\\APIKey={api_key}\n'
            'WebUI\\Address=*\n'
            'WebUI\\AuthSubnetWhitelistEnabled=false\n'
            'WebUI\\ClickjackingProtection=true\n'
            'WebUI\\CSRFProtection=true\n'
            'WebUI\\HostHeaderValidation=true\n'
            'WebUI\\LocalHostAuth=true\n'
            f'WebUI\\Password_PBKDF2="@ByteArray({password_hash})"\n'
            f'WebUI\\Port={web_port}\n'
            'WebUI\\SecureCookie=true\n'
            'WebUI\\ServerDomains=qbittorrent\n'
            'WebUI\\UseUPnP=false\n'
            'WebUI\\Username=larenor-system\n'
        ).encode('ascii')
        return QbittorrentOwnedConfig(
            relative_path='qBittorrent/qBittorrent.conf',
            password_hash=password_hash, configuration=text)
    except (ValueError, TypeError, AttributeError, UnicodeError):
        raise QbittorrentOwnedConfigError() from None


def verify_qbittorrent_password(stored, credential):
    """Verify qBittorrent's salt:key PBKDF2 form without raising on storage."""
    try:
        if (type(stored) is not str or len(stored) > 256
                or not _valid_credential(credential)):
            return False
        parts = stored.split(':')
        if len(parts) != 2:
            return False
        salt = base64.b64decode(parts[0], validate=True)
        key = base64.b64decode(parts[1], validate=True)
        if len(salt) != _SALT_BYTES or len(key) != _KEY_BYTES:
            return False
        expected = hashlib.pbkdf2_hmac(
            'sha512', credential.encode('utf-8'), salt, _ITERATIONS,
            dklen=_KEY_BYTES)
        return hmac.compare_digest(key, expected)
    except (ValueError, TypeError, binascii.Error, UnicodeError):
        return False


def verify_qbittorrent_owned_config(configuration, credential, *, api_key,
                                    web_port=8080, torrent_port=6881):
    """Re-derive a seed file from its salt and reject any configuration drift."""
    try:
        if (type(configuration) is not bytes or not 1 <= len(configuration) <= 4096
                or not _valid_credential(credential)
                or not is_qbittorrent_api_key(api_key)):
            return False
        prefix = b'WebUI\\Password_PBKDF2="@ByteArray('
        matching = tuple(line for line in configuration.splitlines()
                         if line.startswith(prefix))
        if len(matching) != 1 or not matching[0].endswith(b')"'):
            return False
        stored = matching[0][len(prefix):-2].decode('ascii')
        parts = stored.split(':')
        if len(parts) != 2:
            return False
        salt = base64.b64decode(parts[0], validate=True)
        if len(salt) != _SALT_BYTES or not verify_qbittorrent_password(stored, credential):
            return False
        expected = render_qbittorrent_owned_config(
            credential, api_key=api_key, salt=salt, web_port=web_port,
            torrent_port=torrent_port)
        return hmac.compare_digest(configuration, expected.configuration)
    except (ValueError, TypeError, binascii.Error, UnicodeError,
            QbittorrentOwnedConfigError):
        return False
