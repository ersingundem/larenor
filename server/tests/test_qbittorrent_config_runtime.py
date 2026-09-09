"""Private runtime binds qBittorrent config to the current volume journal."""

import inspect
import threading

import pytest

from larenor_server.plugins.docker_probe import DockerEndpoint
from larenor_server.plugins.qbittorrent_config_effect import (
    QbittorrentConfigInstallReceipt,
)
from larenor_server.plugins.qbittorrent_config_runtime import (
    QbittorrentConfigRuntime,
    QbittorrentConfigRuntimeError,
)
from test_qbittorrent_config_binding import (
    PRIVATE_BEARER,
    PRIVATE_PASSWORD,
    SALT,
    source,
)


HELPER = 'sha256:' + '8' * 64


class Installer:
    def __init__(self, endpoint, result=None):
        self._endpoint = endpoint
        self.result = result
        self.calls = []

    def install(self, binding, journal, intent, credential, *, api_key,
                cancelled, before_dispatch):
        self.calls.append((binding, journal, intent, credential, api_key,
                           cancelled, before_dispatch))
        assert before_dispatch() is True
        if isinstance(self.result, BaseException):
            raise self.result
        return self.result or QbittorrentConfigInstallReceipt(
            binding.resource_id, binding.operation_id, binding.journal_id,
            binding.revision, binding.volume_name,
            binding.configuration_digest, 'qbittorrent_config_installed')


def runtime(tmp_path, *, result=None):
    journal, intent = source(tmp_path)
    _plan, stack, catalog, policy = intent.binding.source
    endpoint = DockerEndpoint('/private/docker.sock', owner_uid=0)
    installer = Installer(endpoint, result)
    selected = QbittorrentConfigRuntime(
        endpoint, journal, catalog, policy, HELPER, 'linux/amd64',
        installer_factory=lambda _: installer,
    )
    return selected, installer, journal, stack, intent


def test_runtime_rebinds_exact_current_qbittorrent_volume_and_private_config(tmp_path):
    selected, installer, journal, stack, expected = runtime(tmp_path)
    cancelled = threading.Event()

    result = selected.install(
        stack, PRIVATE_PASSWORD, api_key=PRIVATE_BEARER, salt=SALT,
        cancelled=cancelled, before_dispatch=lambda: True,
    )

    assert result.state == 'qbittorrent_config_installed'
    assert len(installer.calls) == 1
    binding, actual_journal, intent, credential, api_key, event, _gate = \
        installer.calls[0]
    assert actual_journal is journal and intent == expected
    assert binding.resource_id == expected.binding.resource_id
    assert binding.volume_name == expected.binding.resource.name
    assert credential == PRIVATE_PASSWORD and api_key == PRIVATE_BEARER
    assert event is cancelled
    assert PRIVATE_PASSWORD not in repr(selected)
    assert PRIVATE_BEARER not in repr(selected)


def test_runtime_rejects_stale_or_missing_volume_before_effect(tmp_path):
    selected, installer, journal, stack, intent = runtime(tmp_path)
    with journal.locked():
        journal._db.execute(
            'UPDATE resources SET revision=? WHERE resource_id=?',
            (intent.receipt.revision + 1, intent.receipt.resource_id),
        )
    with pytest.raises(
        QbittorrentConfigRuntimeError,
        match='^qbittorrent_config_runtime_untrusted$',
    ):
        selected.install(
            stack, PRIVATE_PASSWORD, api_key=PRIVATE_BEARER, salt=SALT,
            cancelled=threading.Event(), before_dispatch=lambda: True,
        )
    assert installer.calls == []


@pytest.mark.parametrize('change', [
    {'credential': ''}, {'api_key': ''}, {'salt': b'x' * 15},
    {'cancelled': object()}, {'before_dispatch': None},
])
def test_runtime_input_contract_is_closed_before_journal_or_effect(tmp_path, change):
    selected, installer, _journal, stack, _intent = runtime(tmp_path)
    values = dict(
        stack=stack, credential=PRIVATE_PASSWORD, api_key=PRIVATE_BEARER,
        salt=SALT, cancelled=threading.Event(), before_dispatch=lambda: True,
    )
    with pytest.raises(QbittorrentConfigRuntimeError):
        selected.install(**(values | change))
    assert installer.calls == []


def test_runtime_api_has_no_path_volume_command_or_docker_override():
    parameters = inspect.signature(QbittorrentConfigRuntime.install).parameters
    assert set(parameters) == {
        'self', 'stack', 'credential', 'api_key', 'salt', 'cancelled',
        'before_dispatch',
    }
    assert not {'path', 'volume', 'command', 'docker', 'image', 'endpoint'} & set(parameters)


@pytest.mark.parametrize('helper,platform', [
    ('latest', 'linux/amd64'),
    (HELPER[:-1], 'linux/amd64'),
    (HELPER, 'linux/s390x'),
])
def test_runtime_configuration_rejects_unpinned_image_or_platform(
        tmp_path, helper, platform):
    journal, intent = source(tmp_path)
    _plan, _stack, catalog, policy = intent.binding.source
    endpoint = DockerEndpoint('/private/docker.sock', owner_uid=0)
    called = []
    with pytest.raises(
        QbittorrentConfigRuntimeError,
        match='^qbittorrent_config_runtime_configuration_invalid$',
    ):
        QbittorrentConfigRuntime(
            endpoint, journal, catalog, policy, helper, platform,
            installer_factory=lambda _: called.append(True),
        )
    assert called == []


def test_unknown_installer_error_is_static_uncertain_and_secret_free(tmp_path):
    selected, _installer, _journal, stack, _intent = runtime(
        tmp_path, result=RuntimeError('private-effect-detail'))
    with pytest.raises(
        QbittorrentConfigRuntimeError,
        match='^qbittorrent_config_runtime_effect_failed$',
    ) as raised:
        selected.install(
            stack, PRIVATE_PASSWORD, api_key=PRIVATE_BEARER, salt=SALT,
            cancelled=threading.Event(), before_dispatch=lambda: True,
        )
    assert raised.value.uncertain_effect is True
    assert 'private-effect-detail' not in repr(raised.value)
    assert PRIVATE_PASSWORD not in repr(raised.value)
    assert PRIVATE_BEARER not in repr(raised.value)
