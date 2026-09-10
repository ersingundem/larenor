"""Owned qBittorrent 5.2.3 identity and path configuration contract."""

import base64
import hashlib

import pytest

from larenor_server.plugins.qbittorrent_owned_config import (
    QbittorrentOwnedConfigError,
    render_qbittorrent_owned_config,
    verify_qbittorrent_owned_config,
    verify_qbittorrent_password,
)


PRIVATE_PASSWORD = 'p' * 40
PRIVATE_BEARER = 'qbt_' + 'k' * 28
SALT = bytes(range(16))


def test_renderer_matches_upstream_pbkdf2_and_fixed_managed_paths():
    result = render_qbittorrent_owned_config(
        PRIVATE_PASSWORD, api_key=PRIVATE_BEARER, salt=SALT, web_port=8080,
        torrent_port=6881)

    derived = hashlib.pbkdf2_hmac(
        'sha512', PRIVATE_PASSWORD.encode('utf-8'), SALT, 100_000, dklen=64)
    encoded = base64.b64encode(SALT).decode() + ':' + base64.b64encode(derived).decode()
    assert result.relative_path == 'qBittorrent/qBittorrent.conf'
    assert result.password_hash == encoded
    assert result.configuration == (
        '[BitTorrent]\n'
        'Session\\DefaultSavePath=/data/downloads\n'
        'Session\\Port=6881\n'
        'Session\\TempPath=/data/incomplete\n'
        'Session\\TempPathEnabled=true\n\n'
        '[Preferences]\n'
        f'WebUI\\APIKey={PRIVATE_BEARER}\n'
        'WebUI\\Address=*\n'
        'WebUI\\AuthSubnetWhitelistEnabled=false\n'
        'WebUI\\ClickjackingProtection=true\n'
        'WebUI\\CSRFProtection=true\n'
        'WebUI\\HostHeaderValidation=true\n'
        'WebUI\\LocalHostAuth=true\n'
        f'WebUI\\Password_PBKDF2="@ByteArray({encoded})"\n'
        'WebUI\\Port=8080\n'
        'WebUI\\SecureCookie=true\n'
        'WebUI\\ServerDomains=qbittorrent\n'
        'WebUI\\UseUPnP=false\n'
        'WebUI\\Username=larenor-system\n'
    ).encode('ascii')
    assert verify_qbittorrent_password(result.password_hash, PRIVATE_PASSWORD)
    assert not verify_qbittorrent_password(result.password_hash, PRIVATE_PASSWORD + 'x')


def test_config_result_never_reveals_the_credential_or_hash_in_repr():
    result = render_qbittorrent_owned_config(
        PRIVATE_PASSWORD, api_key=PRIVATE_BEARER, salt=SALT)
    shown = repr(result)
    assert PRIVATE_PASSWORD not in shown
    assert result.password_hash not in shown
    assert PRIVATE_BEARER not in shown
    assert 'configuration' not in shown


@pytest.mark.parametrize('credential', [
    '', 'short', 'contains space ' + 'x' * 32, 'contains:colon' + 'x' * 32,
    'x' * 129, b'x' * 40, True,
])
def test_renderer_rejects_untrusted_credentials_without_echoing_them(credential):
    with pytest.raises(QbittorrentOwnedConfigError) as caught:
        render_qbittorrent_owned_config(credential, api_key=PRIVATE_BEARER, salt=SALT)
    assert str(caught.value) == 'invalid_qbittorrent_owned_config'
    assert repr(credential) not in str(caught.value)


@pytest.mark.parametrize('field,value', [
    ('salt', b'x' * 15), ('salt', bytearray(b'x' * 16)), ('web_port', True),
    ('web_port', 1023), ('web_port', 65536), ('torrent_port', '6881'),
    ('torrent_port', 0),
])
def test_renderer_rejects_invalid_crypto_and_port_inputs(field, value):
    values = {'api_key': PRIVATE_BEARER, 'salt': SALT, 'web_port': 8080,
              'torrent_port': 6881}
    values[field] = value
    with pytest.raises(QbittorrentOwnedConfigError,
                       match='^invalid_qbittorrent_owned_config$'):
        render_qbittorrent_owned_config(PRIVATE_PASSWORD, **values)


@pytest.mark.parametrize('stored', [
    '', 'not-base64:not-base64', 'AAAA', ':', 'A' * 4096, None, True,
])
def test_password_verifier_fails_closed_for_malformed_storage(stored):
    assert verify_qbittorrent_password(stored, PRIVATE_PASSWORD) is False


def test_fixed_salt_makes_reconciliation_deterministic_and_new_salt_rotates_hash():
    first = render_qbittorrent_owned_config(PRIVATE_PASSWORD, api_key=PRIVATE_BEARER, salt=SALT)
    repeated = render_qbittorrent_owned_config(PRIVATE_PASSWORD, api_key=PRIVATE_BEARER, salt=SALT)
    rotated = render_qbittorrent_owned_config(
        PRIVATE_PASSWORD, api_key=PRIVATE_BEARER, salt=b'z' * 16)
    assert first == repeated
    assert first.password_hash != rotated.password_hash
    assert first.configuration != rotated.configuration


def test_exact_config_can_be_reconciled_from_its_embedded_salt():
    result = render_qbittorrent_owned_config(
        PRIVATE_PASSWORD, api_key=PRIVATE_BEARER, salt=SALT, web_port=9090,
        torrent_port=6991)
    assert verify_qbittorrent_owned_config(
        result.configuration, PRIVATE_PASSWORD, api_key=PRIVATE_BEARER, web_port=9090,
        torrent_port=6991)
    assert not verify_qbittorrent_owned_config(
        result.configuration, PRIVATE_PASSWORD + 'x', api_key=PRIVATE_BEARER,
        web_port=9090, torrent_port=6991)
    assert not verify_qbittorrent_owned_config(
        result.configuration, PRIVATE_PASSWORD, api_key=PRIVATE_BEARER, web_port=9091,
        torrent_port=6991)
    wrong_bearer = PRIVATE_BEARER[:-1] + 'x'
    assert not verify_qbittorrent_owned_config(
        result.configuration, PRIVATE_PASSWORD, api_key=wrong_bearer,
        web_port=9090, torrent_port=6991)


@pytest.mark.parametrize('mutation', [
    lambda raw: raw + b'Hidden\\Option=true\n',
    lambda raw: raw.replace(b'/data/downloads', b'/private/downloads'),
    lambda raw: raw.replace(b'CSRFProtection=true', b'CSRFProtection=false'),
    lambda raw: raw.replace(b'UseUPnP=false', b'UseUPnP=true'),
    lambda raw: raw.replace(b'Username=larenor-system', b'Username=admin'),
    lambda raw: raw.replace(b'@ByteArray(', b'@ByteArray(AA'),
])
def test_reconciliation_rejects_drift_and_unknown_settings(mutation):
    result = render_qbittorrent_owned_config(
        PRIVATE_PASSWORD, api_key=PRIVATE_BEARER, salt=SALT)
    assert not verify_qbittorrent_owned_config(
        mutation(result.configuration), PRIVATE_PASSWORD, api_key=PRIVATE_BEARER)


@pytest.mark.parametrize('value', [b'', b'x' * 4097, 'not-bytes', bytearray(b'x'), None])
def test_reconciliation_fails_closed_for_invalid_file_shape(value):
    assert verify_qbittorrent_owned_config(
        value, PRIVATE_PASSWORD, api_key=PRIVATE_BEARER) is False


@pytest.mark.parametrize('api_key', [
    '', 'short', 'contains:colon' + 'x' * 32, 'x' * 32,
    'qbt_' + 'x' * 27, 'qbt_' + 'x' * 29, b'x' * 32, True,
])
def test_api_key_is_required_and_strict(api_key):
    with pytest.raises(QbittorrentOwnedConfigError,
                       match='^invalid_qbittorrent_owned_config$'):
        render_qbittorrent_owned_config(
            PRIVATE_PASSWORD, api_key=api_key, salt=SALT)
