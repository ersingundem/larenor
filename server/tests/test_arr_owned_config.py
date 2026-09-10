"""Owned Sonarr/Radarr config.xml contract for fresh managed instances."""

import pytest

from larenor_server.plugins.arr_owned_config import (
    ArrOwnedConfigError,
    generate_arr_api_key,
    is_arr_api_key,
    render_arr_owned_config,
    verify_arr_owned_config,
)


API_KEY = '01234567' * 4


def test_generated_api_key_matches_upstream_guid_without_hyphens():
    values = {generate_arr_api_key() for _ in range(32)}
    assert len(values) == 32
    assert all(is_arr_api_key(value) for value in values)
    assert all(len(value) == 32 and value == value.lower() for value in values)


@pytest.mark.parametrize('service_id,port,instance_name', [
    ('sonarr', 8989, 'Larenor Sonarr'),
    ('radarr', 7878, 'Larenor Radarr'),
])
def test_renderer_emits_only_the_owned_private_service_settings(
        service_id, port, instance_name):
    result = render_arr_owned_config(service_id, API_KEY)

    assert result.service_id == service_id
    assert result.relative_path == 'config.xml'
    assert result.configuration == (
        '<?xml version="1.0" encoding="utf-8" standalone="yes"?>\n'
        '<Config>\n'
        '  <BindAddress>*</BindAddress>\n'
        f'  <Port>{port}</Port>\n'
        '  <EnableSsl>False</EnableSsl>\n'
        '  <LaunchBrowser>False</LaunchBrowser>\n'
        f'  <ApiKey>{API_KEY}</ApiKey>\n'
        '  <AuthenticationMethod>None</AuthenticationMethod>\n'
        '  <AuthenticationRequired>Enabled</AuthenticationRequired>\n'
        '  <AnalyticsEnabled>False</AnalyticsEnabled>\n'
        '  <UpdateAutomatically>False</UpdateAutomatically>\n'
        '  <LogLevel>info</LogLevel>\n'
        f'  <InstanceName>{instance_name}</InstanceName>\n'
        '</Config>\n'
    ).encode('ascii')
    assert verify_arr_owned_config(
        result.configuration, service_id, api_key=API_KEY)


def test_result_repr_does_not_expose_the_api_key_or_configuration():
    result = render_arr_owned_config('sonarr', API_KEY)
    shown = repr(result)
    assert API_KEY not in shown
    assert 'configuration' not in shown


@pytest.mark.parametrize('value', [
    '', 'short', 'g' * 32, 'A' * 32, '0' * 31, '0' * 33,
    b'0' * 32, True, None,
])
def test_api_key_contract_is_exact_and_fails_closed(value):
    assert is_arr_api_key(value) is False
    with pytest.raises(ArrOwnedConfigError, match='^invalid_arr_owned_config$'):
        render_arr_owned_config('sonarr', value)


@pytest.mark.parametrize('service_id', [
    '', 'lidarr', 'Sonarr', '../sonarr', b'sonarr', True, None,
])
def test_unknown_service_cannot_select_a_path_or_port(service_id):
    with pytest.raises(ArrOwnedConfigError, match='^invalid_arr_owned_config$'):
        render_arr_owned_config(service_id, API_KEY)


@pytest.mark.parametrize('mutation', [
    lambda raw: raw + b'<Hidden>value</Hidden>\n',
    lambda raw: raw.replace(b'<BindAddress>*', b'<BindAddress>0.0.0.0'),
    lambda raw: raw.replace(b'<Port>8989', b'<Port>7878'),
    lambda raw: raw.replace(b'<EnableSsl>False', b'<EnableSsl>True'),
    lambda raw: raw.replace(b'<AuthenticationMethod>None',
                            b'<AuthenticationMethod>Forms'),
    lambda raw: raw.replace(b'<AnalyticsEnabled>False',
                            b'<AnalyticsEnabled>True'),
    lambda raw: raw.replace(b'<UpdateAutomatically>False',
                            b'<UpdateAutomatically>True'),
    lambda raw: raw.replace(API_KEY.encode(), b'f' * 32),
])
def test_reconciliation_rejects_drift_and_unknown_settings(mutation):
    result = render_arr_owned_config('sonarr', API_KEY)
    assert not verify_arr_owned_config(
        mutation(result.configuration), 'sonarr', api_key=API_KEY)


@pytest.mark.parametrize('configuration', [
    b'', b'x' * 4097, '<Config/>', bytearray(b'<Config/>'), None, True,
    b'<!DOCTYPE Config [<!ENTITY x SYSTEM "file:///etc/passwd">]><Config>&x;</Config>',
])
def test_reconciliation_rejects_invalid_or_active_xml(configuration):
    assert verify_arr_owned_config(
        configuration, 'sonarr', api_key=API_KEY) is False


def test_service_and_api_key_are_bound_to_the_exact_bytes():
    sonarr = render_arr_owned_config('sonarr', API_KEY)
    assert not verify_arr_owned_config(
        sonarr.configuration, 'radarr', api_key=API_KEY)
    assert not verify_arr_owned_config(
        sonarr.configuration, 'sonarr', api_key='f' * 32)
