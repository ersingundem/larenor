"""Private runtime binds Arr config to the current volume journal."""

import inspect
import threading

import pytest

from larenor_server.plugins.arr_config_effect import (
    ArrConfigEffectError,
    ArrConfigInstallReceipt,
)
from larenor_server.plugins.arr_config_runtime import (
    ArrConfigRuntime,
    ArrConfigRuntimeError,
)
from larenor_server.plugins.docker_probe import DockerEndpoint
from test_arr_config_binding import API_KEY, source


HELPER = 'sha256:' + '8' * 64


class Installer:
    def __init__(self, endpoint, result=None):
        self._endpoint = endpoint
        self.result = result
        self.calls = []

    def install(self, binding, journal, intent, *, api_key, cancelled,
                before_dispatch):
        self.calls.append((
            binding, journal, intent, api_key, cancelled, before_dispatch))
        assert before_dispatch() is True
        if isinstance(self.result, BaseException):
            raise self.result
        return self.result or ArrConfigInstallReceipt(
            binding.service_id, binding.resource_id, binding.operation_id,
            binding.journal_id, binding.revision, binding.volume_name,
            binding.configuration_digest,
            f'{binding.service_id}_config_installed')


def runtime(tmp_path, service_id='sonarr', *, result=None):
    journal, intent = source(tmp_path, service_id)
    _plan, stack, catalog, policy = intent.binding.source
    endpoint = DockerEndpoint('/private/docker.sock', owner_uid=0)
    installer = Installer(endpoint, result)
    selected = ArrConfigRuntime(
        endpoint, journal, catalog, policy, HELPER, 'linux/amd64',
        installer_factory=lambda _: installer,
    )
    return selected, installer, journal, stack, intent


@pytest.mark.parametrize('service_id', ['sonarr', 'radarr'])
def test_runtime_rebinds_exact_current_arr_volume_and_private_config(
        tmp_path, service_id):
    selected, installer, journal, stack, expected = runtime(
        tmp_path, service_id)
    cancelled = threading.Event()

    result = selected.install(
        stack, service_id, api_key=API_KEY, cancelled=cancelled,
        before_dispatch=lambda: True)

    assert result.service_id == service_id
    assert result.state == f'{service_id}_config_installed'
    assert len(installer.calls) == 1
    binding, actual_journal, intent, api_key, event, _gate = installer.calls[0]
    assert actual_journal is journal and intent == expected
    assert binding.service_id == service_id
    assert binding.resource_id == expected.binding.resource_id
    assert binding.volume_name == expected.binding.resource.name
    assert api_key == API_KEY and event is cancelled
    assert API_KEY not in repr(selected)
    assert API_KEY not in repr(result)


def test_runtime_rejects_stale_volume_before_effect(tmp_path):
    selected, installer, journal, stack, intent = runtime(tmp_path)
    with journal.locked():
        journal._db.execute(
            'UPDATE resources SET revision=? WHERE resource_id=?',
            (intent.receipt.revision + 1, intent.receipt.resource_id),
        )

    with pytest.raises(
        ArrConfigRuntimeError,
        match='^arr_config_runtime_untrusted$',
    ):
        selected.install(
            stack, 'sonarr', api_key=API_KEY,
            cancelled=threading.Event(), before_dispatch=lambda: True)

    assert installer.calls == []


@pytest.mark.parametrize('change', [
    {'service_id': ''},
    {'service_id': 'jellyfin'},
    {'service_id': True},
    {'api_key': ''},
    {'api_key': 'F' * 32},
    {'cancelled': object()},
    {'before_dispatch': None},
])
def test_runtime_input_contract_is_closed_before_journal_or_effect(
        tmp_path, change):
    selected, installer, _journal, stack, _intent = runtime(tmp_path)
    values = dict(
        stack=stack, service_id='sonarr', api_key=API_KEY,
        cancelled=threading.Event(), before_dispatch=lambda: True)

    with pytest.raises(ArrConfigRuntimeError):
        selected.install(**(values | change))

    assert installer.calls == []


def test_runtime_api_has_no_path_volume_command_or_docker_override():
    parameters = inspect.signature(ArrConfigRuntime.install).parameters
    assert set(parameters) == {
        'self', 'stack', 'service_id', 'api_key', 'cancelled',
        'before_dispatch',
    }
    forbidden = {'path', 'volume', 'command', 'docker', 'image', 'endpoint'}
    assert not forbidden & set(parameters)


@pytest.mark.parametrize('helper,platform', [
    ('latest', 'linux/amd64'),
    (HELPER[:-1], 'linux/amd64'),
    (HELPER, 'linux/s390x'),
])
def test_runtime_configuration_rejects_unpinned_image_or_platform(
        tmp_path, helper, platform):
    journal, intent = source(tmp_path, 'sonarr')
    _plan, _stack, catalog, policy = intent.binding.source
    endpoint = DockerEndpoint('/private/docker.sock', owner_uid=0)
    called = []

    with pytest.raises(
        ArrConfigRuntimeError,
        match='^arr_config_runtime_configuration_invalid$',
    ):
        ArrConfigRuntime(
            endpoint, journal, catalog, policy, helper, platform,
            installer_factory=lambda _: called.append(True),
        )

    assert called == []


def test_unknown_installer_error_is_static_uncertain_and_secret_free(tmp_path):
    selected, _installer, _journal, stack, _intent = runtime(
        tmp_path, result=RuntimeError('private-effect-detail'))

    with pytest.raises(
        ArrConfigRuntimeError,
        match='^arr_config_runtime_effect_failed$',
    ) as raised:
        selected.install(
            stack, 'sonarr', api_key=API_KEY,
            cancelled=threading.Event(), before_dispatch=lambda: True)

    assert raised.value.uncertain_effect is True
    assert 'private-effect-detail' not in repr(raised.value)
    assert API_KEY not in repr(raised.value)


def test_closed_effect_error_remains_closed(tmp_path):
    selected, _installer, _journal, stack, _intent = runtime(
        tmp_path, result=ArrConfigEffectError(
            'arr_config_effect_stream_failed', uncertain_effect=True))

    with pytest.raises(
        ArrConfigEffectError,
        match='^arr_config_effect_stream_failed$',
    ) as raised:
        selected.install(
            stack, 'sonarr', api_key=API_KEY,
            cancelled=threading.Event(), before_dispatch=lambda: True)

    assert raised.value.uncertain_effect is True


def test_cross_service_result_is_uncertain(tmp_path):
    foreign = ArrConfigInstallReceipt(
        'radarr', '9' * 32, '8' * 32, '7' * 32, 3,
        'larenor-appdata-v1-' + '9' * 32, '6' * 64,
        'radarr_config_installed')
    selected, installer, _journal, stack, _intent = runtime(
        tmp_path, result=foreign)

    with pytest.raises(
        ArrConfigRuntimeError,
        match='^arr_config_runtime_result_invalid$',
    ) as raised:
        selected.install(
            stack, 'sonarr', api_key=API_KEY,
            cancelled=threading.Event(), before_dispatch=lambda: True)

    assert raised.value.uncertain_effect is True
    assert len(installer.calls) == 1
