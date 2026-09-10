"""Closed qBittorrent configuration over the mutating installation socket."""

from contextlib import contextmanager
import os
from pathlib import Path
import tempfile
import time

import pytest

from larenor_server.plugins.installation_ipc import (
    InstallationWorkerClient, InstallationWorkerServer,
)
from larenor_server.plugins.qbittorrent_config_effect import (
    QbittorrentConfigEffectError, QbittorrentConfigInstallReceipt,
)
from larenor_server.plugins.qbittorrent_config_models import (
    PrivateQbittorrentConfiguration, QbittorrentConfiguredInstallReceipt,
    QbittorrentConfigurationExecutionError,
)
from test_media_host_preflight import stack


CREDENTIAL = 'c' * 48
CONTROL_ID = 'q' * 32


def private():
    return PrivateQbittorrentConfiguration(
        credential=CREDENTIAL, apiKey=CONTROL_ID, saltHex='ab' * 16,
    )


class Backend:
    def __init__(self, result=None):
        self.calls = []
        self.install_calls = []
        self.result = result or QbittorrentConfigInstallReceipt(
            '1' * 32, '2' * 32, '3' * 32, 3,
            'larenor-appdata-v1-' + '1' * 32, '4' * 64,
            'qbittorrent_config_installed',
        )

    def apply(self, *_args):
        raise AssertionError('unrelated operation')

    def reconcile(self, *_args):
        raise AssertionError('unrelated operation')

    def configure_qbittorrent(self, job, plan, credential, *, api_key, salt,
                              cancelled, deadline, gate):
        self.calls.append((job, plan, credential, api_key, salt, cancelled, deadline, gate))
        assert deadline > time.monotonic()
        assert gate() is True
        assert not cancelled.is_set()
        if isinstance(self.result, BaseException):
            raise self.result
        return self.result

    def install_configured_qbittorrent(
            self, job, plan, credential, *, api_key, salt, cancelled,
            deadline, gate):
        self.install_calls.append(job)
        configured = self.configure_qbittorrent(
            job, plan, credential, api_key=api_key, salt=salt,
            cancelled=cancelled, deadline=deadline, gate=gate)
        return QbittorrentConfiguredInstallReceipt(
            configured, '5' * 64, 'qbittorrent_container_started',
            'qbittorrent_service_verified')


@contextmanager
def running(backend=None):
    with tempfile.TemporaryDirectory(
        prefix='lqi-', dir='/private/tmp' if Path('/private/tmp').is_dir() else '/tmp',
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


def test_private_configuration_roundtrip_reaches_only_closed_worker_method():
    selected = stack()
    payload = private()
    with running() as (backend, client):
        assert client.status() == {
            'capability': 'container_execution', 'installAvailable': False,
            'services': ['jellyfin', 'qbittorrent'],
        }
        receipt = client.configure_qbittorrent(
            'a' * 32, selected, payload,
            deadline=time.monotonic() + .4, gate=lambda: True,
        )
    assert receipt == backend.result
    call = backend.calls[0]
    assert call[:5] == (
        'a' * 32, selected, CREDENTIAL, CONTROL_ID, bytes.fromhex('ab' * 16))
    assert CREDENTIAL not in repr(payload) + repr(receipt)
    assert CONTROL_ID not in repr(payload) + repr(receipt)


def test_configured_install_roundtrip_uses_one_closed_ordered_operation():
    selected = stack()
    payload = private()
    with running() as (backend, client):
        receipt = client.install_qbittorrent(
            'a' * 32, selected, payload,
            deadline=time.monotonic() + .4, gate=lambda: True)
    assert receipt == QbittorrentConfiguredInstallReceipt(
        backend.result, '5' * 64, 'qbittorrent_container_started',
        'qbittorrent_service_verified')
    assert backend.install_calls == ['a' * 32]
    assert len(backend.calls) == 1
    assert backend.calls[0][:5] == (
        'a' * 32, selected, CREDENTIAL, CONTROL_ID,
        bytes.fromhex('ab' * 16))
    assert CREDENTIAL not in repr(receipt)


@pytest.mark.parametrize('gate', [
    lambda: False,
    lambda: (_ for _ in ()).throw(RuntimeError('private-authority-detail')),
])
def test_authority_loss_prevents_private_ipc_dispatch(gate):
    payload = private()
    with running() as (backend, client):
        with pytest.raises(
            QbittorrentConfigurationExecutionError,
            match='^qbittorrent_config_authority_changed$',
        ):
            client.configure_qbittorrent(
                'a' * 32, stack(), payload,
                deadline=time.monotonic() + .4, gate=gate,
            )
    assert backend.calls == []
    assert CREDENTIAL not in repr(payload)


def test_worker_failure_preserves_static_uncertain_result_only():
    failure = QbittorrentConfigEffectError(
        'qbittorrent_config_effect_stream_failed', uncertain_effect=True,
    )
    with running(Backend(failure)) as (backend, client):
        with pytest.raises(
            QbittorrentConfigurationExecutionError,
            match='^qbittorrent_config_write_failed$',
        ) as raised:
            client.configure_qbittorrent(
                'a' * 32, stack(), private(),
                deadline=time.monotonic() + .4, gate=lambda: True,
            )
    assert raised.value.uncertain_effect
    assert len(backend.calls) == 1
    assert CREDENTIAL not in repr(raised.value)


def test_authority_loss_after_worker_effect_is_uncertain_and_secret_free():
    checks = iter((True, False))
    with running() as (backend, client):
        with pytest.raises(
            QbittorrentConfigurationExecutionError,
            match='^qbittorrent_config_authority_changed$',
        ) as raised:
            client.configure_qbittorrent(
                'a' * 32, stack(), private(),
                deadline=time.monotonic() + .4, gate=lambda: next(checks),
            )
    assert raised.value.uncertain_effect
    assert len(backend.calls) == 1
    assert CREDENTIAL not in repr(raised.value)


@pytest.mark.parametrize('change', ['job', 'plan', 'private', 'deadline', 'gate'])
def test_invalid_client_input_never_reaches_worker(change):
    values = {
        'job': 'a' * 32, 'plan': stack(), 'private': private(),
        'deadline': time.monotonic() + .4, 'gate': lambda: True,
    }
    values[change] = {
        'job': 'bad', 'plan': {}, 'private': {},
        'deadline': True, 'gate': 'gate',
    }[change]
    with running() as (backend, client):
        with pytest.raises(QbittorrentConfigurationExecutionError):
            client.configure_qbittorrent(
                values.pop('job'), values.pop('plan'), values.pop('private'),
                **values,
            )
    assert backend.calls == []


@pytest.mark.parametrize('change', [
    {'credential': 'private-secret'},
    {'apiKey': True},
    {'saltHex': 'ff'},
])
def test_unvalidated_model_copy_is_revalidated_inside_worker(change):
    payload = private().model_copy(update=change)
    with running() as (backend, client):
        with pytest.raises(QbittorrentConfigurationExecutionError):
            client.configure_qbittorrent(
                'a' * 32, stack(), payload,
                deadline=time.monotonic() + .4, gate=lambda: True,
            )
    assert backend.calls == []


def test_invalid_worker_receipt_is_rejected_without_private_output():
    backend = Backend(result={'private': CREDENTIAL})
    with running(backend) as (_backend, client):
        with pytest.raises(
            QbittorrentConfigurationExecutionError,
            match='^qbittorrent_config_result_invalid$',
        ) as raised:
            client.configure_qbittorrent(
                'a' * 32, stack(), private(),
                deadline=time.monotonic() + .4, gate=lambda: True,
            )
    assert CREDENTIAL not in repr(raised.value)


def test_configured_install_requires_verified_service_receipt():
    backend = Backend()

    def unverified(*_args, **_kwargs):
        return QbittorrentConfiguredInstallReceipt(
            backend.result, '5' * 64, 'qbittorrent_container_started')

    backend.install_configured_qbittorrent = unverified
    with running(backend) as (_backend, client):
        with pytest.raises(
            QbittorrentConfigurationExecutionError,
            match='^qbittorrent_config_result_invalid$',
        ) as raised:
            client.install_qbittorrent(
                'a' * 32, stack(), private(),
                deadline=time.monotonic() + .4, gate=lambda: True)
    assert raised.value.uncertain_effect
    assert CREDENTIAL not in repr(raised.value)
