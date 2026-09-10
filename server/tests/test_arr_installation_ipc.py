"""Closed Sonarr/Radarr configuration over the mutating worker socket."""

from contextlib import contextmanager
import os
from pathlib import Path
import tempfile
import time

import pytest

from larenor_server.plugins.arr_config_effect import (
    ArrConfigEffectError,
    ArrConfigInstallReceipt,
)
from larenor_server.plugins.arr_config_models import (
    ArrConfigurationExecutionError,
    PrivateArrConfiguration,
)
from larenor_server.plugins.arr_config_runtime import ArrConfigRuntimeError
from larenor_server.plugins.installation_ipc import (
    InstallationWorkerClient,
    InstallationWorkerServer,
)
from test_media_host_preflight import stack


API_KEY = '01234567' * 4
QBITTORRENT_API_KEY = 'qbt_' + 'A' * 28


def private(service_id='sonarr', *, with_qbittorrent=False):
    return PrivateArrConfiguration(
        serviceId=service_id, apiKey=API_KEY,
        qbittorrentApiKey=(QBITTORRENT_API_KEY
                           if with_qbittorrent else None))


def receipt(service_id='sonarr'):
    return ArrConfigInstallReceipt(
        service_id, '1' * 32, '2' * 32, '3' * 32, 3,
        'larenor-appdata-v1-' + '1' * 32, '4' * 64,
        f'{service_id}_config_installed')


class Backend:
    def __init__(self, result=None):
        self.calls = []
        self.result = result

    def apply(self, *_args):
        raise AssertionError('unrelated operation')

    def reconcile(self, *_args):
        raise AssertionError('unrelated operation')

    def configure_arr(self, job, plan, service_id, *, api_key, cancelled,
                      deadline, gate):
        self.calls.append((
            job, plan, service_id, api_key, cancelled, deadline, gate))
        assert deadline > time.monotonic()
        assert gate() is True
        assert not cancelled.is_set()
        if isinstance(self.result, BaseException):
            raise self.result
        return receipt(service_id) if self.result is None else self.result


@contextmanager
def running(backend=None):
    with tempfile.TemporaryDirectory(
        prefix='lai-',
        dir='/private/tmp' if Path('/private/tmp').is_dir() else '/tmp',
    ) as root:
        path = Path(root) / 'worker.sock'
        selected = backend or Backend()
        server = InstallationWorkerServer(
            path, selected, allowed_uid=os.getuid(),
            peer_uid=lambda _connection: os.getuid(), timeout=.5,
        )
        server.start()
        try:
            yield selected, InstallationWorkerClient(
                path, owner_uid=os.getuid(),
                peer_uid=lambda _connection: os.getuid(), timeout=.5,
            )
        finally:
            server.close()


@pytest.mark.parametrize('service_id', ['sonarr', 'radarr'])
def test_private_configuration_roundtrip_reaches_only_arr_worker_method(
        service_id):
    selected = stack()
    payload = private(service_id)
    with running() as (backend, client):
        assert client.status() == {
            'capability': 'container_execution', 'installAvailable': False,
            'services': ['jellyfin', 'qbittorrent', 'sonarr', 'radarr'],
        }
        result = client.configure_arr(
            'a' * 32, selected, payload,
            deadline=time.monotonic() + .4, gate=lambda: True)

    assert result == receipt(service_id)
    call = backend.calls[0]
    assert call[:4] == ('a' * 32, selected, service_id, API_KEY)
    assert API_KEY not in repr(payload) + repr(result)


@pytest.mark.parametrize('gate', [
    lambda: False,
    lambda: (_ for _ in ()).throw(RuntimeError('private-authority-detail')),
])
def test_authority_loss_prevents_private_ipc_dispatch(gate):
    payload = private()
    with running() as (backend, client):
        with pytest.raises(
            ArrConfigurationExecutionError,
            match='^arr_config_authority_changed$',
        ):
            client.configure_arr(
                'a' * 32, stack(), payload,
                deadline=time.monotonic() + .4, gate=gate)

    assert backend.calls == []
    assert API_KEY not in repr(payload)


def test_worker_failure_preserves_static_uncertain_result_only():
    failure = ArrConfigEffectError(
        'arr_config_effect_stream_failed', uncertain_effect=True)
    with running(Backend(failure)) as (backend, client):
        with pytest.raises(
            ArrConfigurationExecutionError,
            match='^arr_config_write_failed$',
        ) as raised:
            client.configure_arr(
                'a' * 32, stack(), private(),
                deadline=time.monotonic() + .4, gate=lambda: True)

    assert raised.value.uncertain_effect is True
    assert len(backend.calls) == 1
    assert API_KEY not in repr(raised.value)


def test_runtime_failure_maps_to_closed_resources_error():
    failure = ArrConfigRuntimeError('arr_config_runtime_untrusted')
    with running(Backend(failure)) as (backend, client):
        with pytest.raises(
            ArrConfigurationExecutionError,
            match='^arr_config_resources_unavailable$',
        ):
            client.configure_arr(
                'a' * 32, stack(), private(),
                deadline=time.monotonic() + .4, gate=lambda: True)

    assert len(backend.calls) == 1


def test_authority_loss_after_worker_effect_is_uncertain_and_secret_free():
    checks = iter((True, False))
    with running() as (backend, client):
        with pytest.raises(
            ArrConfigurationExecutionError,
            match='^arr_config_authority_changed$',
        ) as raised:
            client.configure_arr(
                'a' * 32, stack(), private(),
                deadline=time.monotonic() + .4,
                gate=lambda: next(checks))

    assert raised.value.uncertain_effect is True
    assert len(backend.calls) == 1
    assert API_KEY not in repr(raised.value)


@pytest.mark.parametrize('change', [
    'job', 'plan', 'private', 'deadline', 'gate',
])
def test_invalid_client_input_never_reaches_worker(change):
    values = {
        'job': 'a' * 32,
        'plan': stack(),
        'private': private(),
        'deadline': time.monotonic() + .4,
        'gate': lambda: True,
    }
    values[change] = {
        'job': 'bad', 'plan': {}, 'private': {},
        'deadline': True, 'gate': 'gate',
    }[change]

    with running() as (backend, client):
        with pytest.raises(ArrConfigurationExecutionError):
            client.configure_arr(
                values.pop('job'), values.pop('plan'),
                values.pop('private'), **values)

    assert backend.calls == []


@pytest.mark.parametrize('change', [
    {'serviceId': 'jellyfin'},
    {'apiKey': True},
    {'apiKey': 'F' * 32},
])
def test_unvalidated_model_copy_is_revalidated_inside_worker(change):
    payload = private().model_copy(update=change)
    with running() as (backend, client):
        with pytest.raises(ArrConfigurationExecutionError):
            client.configure_arr(
                'a' * 32, stack(), payload,
                deadline=time.monotonic() + .4, gate=lambda: True)

    assert backend.calls == []


def test_cross_service_worker_receipt_is_rejected_as_uncertain():
    with running(Backend(receipt('radarr'))) as (backend, client):
        with pytest.raises(
            ArrConfigurationExecutionError,
            match='^arr_config_result_invalid$',
        ) as raised:
            client.configure_arr(
                'a' * 32, stack(), private('sonarr'),
                deadline=time.monotonic() + .4, gate=lambda: True)

    assert raised.value.uncertain_effect is True
    assert len(backend.calls) == 1


def test_invalid_worker_receipt_is_closed_without_private_output():
    backend = Backend(result={'private': API_KEY})
    with running(backend) as (_backend, client):
        with pytest.raises(
            ArrConfigurationExecutionError,
            match='^arr_config_result_invalid$',
        ) as raised:
            client.configure_arr(
                'a' * 32, stack(), private(),
                deadline=time.monotonic() + .4, gate=lambda: True)

    assert raised.value.uncertain_effect is True
    assert API_KEY not in repr(raised.value)


def test_private_model_and_error_never_render_api_key():
    payload = private()
    failure = ArrConfigurationExecutionError(
        'arr_config_write_failed', uncertain_effect=True,
        cause_code='arr_execution_invalid_worker_result')
    assert API_KEY not in repr(payload)
    assert API_KEY not in repr(failure)
    assert failure.cause_code == 'arr_execution_invalid_worker_result'
    assert ArrConfigurationExecutionError(
        cause_code=API_KEY).cause_code is None

@pytest.mark.parametrize('service_id', ['sonarr', 'radarr'])
def test_configured_arr_install_roundtrip_includes_verified_container(service_id):
    from larenor_server.plugins.arr_config_models import ArrConfiguredInstallReceipt
    class InstallBackend(Backend):
        def install_configured_arr(self, job, plan, selected, *, api_key,
                                   qbittorrent_api_key=None, cancelled,
                                   deadline, gate):
            self.calls.append((
                job, plan, selected, api_key, qbittorrent_api_key))
            assert gate() and not cancelled.is_set()
            return ArrConfiguredInstallReceipt(
                receipt(selected), '5' * 64,
                selected + '_container_started',
                selected + '_service_verified')
    selected=InstallBackend()
    with running(selected) as (backend,client):
        value=client.install_arr(
            'a'*32,stack(),private(service_id, with_qbittorrent=True),
            deadline=time.monotonic()+.4,gate=lambda:True)
    assert value.configuration==receipt(service_id)
    assert value.container_id=='5'*64
    assert value.state==service_id+'_container_started'
    assert value.service_state==service_id+'_service_verified'
    assert backend.calls[0][2:]==(
        service_id,API_KEY,QBITTORRENT_API_KEY)


def test_cross_service_configured_receipt_is_rejected_as_uncertain():
    from larenor_server.plugins.arr_config_models import ArrConfiguredInstallReceipt
    class Wrong(Backend):
        def install_configured_arr(self, *_args, **_kwargs):
            return ArrConfiguredInstallReceipt(
                receipt('radarr'),'5'*64,'radarr_container_started',
                'radarr_service_verified')
    with running(Wrong()) as (_backend,client):
        with pytest.raises(ArrConfigurationExecutionError,
                           match='^arr_config_result_invalid$') as raised:
            client.install_arr('a'*32,stack(),private('sonarr'),
                deadline=time.monotonic()+.4,gate=lambda:True)
    assert raised.value.uncertain_effect
