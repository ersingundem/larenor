"""Journal-bound Arr config effect; all Engine calls are synthetic."""

from dataclasses import replace
import inspect
import json
import threading

import pytest

from larenor_server.plugins.docker_probe import DockerEndpoint
from larenor_server.plugins.engine_stdin import EngineStdinError
from larenor_server.plugins.arr_config_binding import (
    bind_arr_owned_config,
)
from larenor_server.plugins.arr_config_effect import (
    ArrConfigEffectError,
    ArrConfigHelperResult,
    ArrConfigInstaller,
    UnixArrConfigEngine,
)
from larenor_server.services.transport import ProbeResponse
from test_arr_config_binding import API_KEY, source


HELPER = 'sha256:' + '8' * 64
CONTAINER = '7' * 64


def prepared(tmp_path):
    journal, intent = source(tmp_path, 'sonarr')
    binding = bind_arr_owned_config(
        journal, intent, api_key=API_KEY)
    return journal, intent, binding


def response(status, value=None):
    body = b'' if value is None else json.dumps(
        value, sort_keys=True, separators=(',', ':')).encode()
    return ProbeResponse(status, (), body)


class ExchangeTransport:
    def __init__(self, replies):
        self.replies = list(replies)
        self.calls = []

    def _exchange(self, method, target, body=None):
        self.calls.append((method, target, body))
        result = self.replies.pop(0)
        if isinstance(result, Exception):
            raise result
        return result


class StdinTransport:
    def __init__(self, endpoint, output=None):
        self._endpoint = endpoint
        self.output = output
        self.calls = []

    def exchange(self, container_id, input_bytes, consume, **options):
        self.calls.append((container_id, input_bytes, options))
        assert options['before_dispatch']() is True
        if isinstance(self.output, Exception):
            raise self.output
        return consume(self.output, b'')


def test_unix_engine_uses_one_fixed_rw_helper_and_private_stdin(tmp_path):
    _journal, _intent, binding = prepared(tmp_path)
    transport = ExchangeTransport([
        response(201, {'Id': CONTAINER, 'Warnings': None}),
        response(204),
        response(200, {'StatusCode': 0, 'Error': None}),
        response(204),
    ])
    endpoint = DockerEndpoint('/private/docker.sock', owner_uid=0)
    stdin = StdinTransport(endpoint, (
        b'{"schemaVersion":1,"sha256":"' +
        binding.configuration_digest.encode() +
        b'","state":"sonarr_config_installed"}\n'))
    engine = UnixArrConfigEngine(
        endpoint,
        transport_factory=lambda _: transport,
        stdin_factory=lambda _: stdin,
        name_factory=lambda: '6' * 32,
    )

    result = engine.install(
        binding, HELPER, 'linux/amd64', cancelled=threading.Event(),
        before_dispatch=lambda: True)

    assert result == ArrConfigHelperResult(
        'sonarr_config_installed', binding.configuration_digest)
    create = transport.calls[0]
    assert create[:2] == (
        'POST',
        '/containers/create?name=larenor-arr-config-' + '6' * 32
        + '&platform=linux%2Famd64',
    )
    body = json.loads(create[2])
    assert body['Image'] == HELPER and body['User'] == '1000:1000'
    assert body['Entrypoint'] == [
        '/usr/local/bin/python', '-I', '/opt/larenor/volume_bootstrap_helper.py']
    assert body['Cmd'] == ['install_sonarr_config']
    assert body['Labels']['org.larenor.service'] == 'sonarr'
    assert body['AttachStdin'] is True and body['OpenStdin'] is True
    assert body['StdinOnce'] is True and body['Tty'] is False
    assert body['NetworkDisabled'] is True
    assert body['HostConfig']['NetworkMode'] == 'none'
    assert body['HostConfig']['ReadonlyRootfs'] is True
    assert body['HostConfig']['CapDrop'] == ['ALL']
    assert body['HostConfig']['Mounts'] == [{
        'Type': 'volume', 'Source': binding.volume_name, 'Target': '/volume',
        'ReadOnly': False, 'VolumeOptions': {'NoCopy': True}}]
    assert binding.configuration not in create[2]
    assert stdin.calls[0][0:2] == (CONTAINER, binding.configuration)
    assert stdin.calls[0][2]['platform'] == 'linux/amd64'
    assert transport.calls[1][:2] == ('POST', f'/containers/{CONTAINER}/start')
    assert transport.calls[2][:2] == (
        'POST', f'/containers/{CONTAINER}/wait?condition=not-running')
    assert transport.calls[3][:2] == (
        'DELETE', f'/containers/{CONTAINER}?force=1&v=0')


def test_radarr_binding_selects_only_the_radarr_helper_command(tmp_path):
    journal, intent = source(tmp_path, 'radarr')
    binding = bind_arr_owned_config(journal, intent, api_key=API_KEY)
    transport = ExchangeTransport([
        response(201, {'Id': CONTAINER, 'Warnings': None}), response(204),
        response(200, {'StatusCode': 0, 'Error': None}), response(204),
    ])
    endpoint = DockerEndpoint('/private/docker.sock', owner_uid=0)
    stdin = StdinTransport(endpoint, (
        b'{"schemaVersion":1,"sha256":"' +
        binding.configuration_digest.encode() +
        b'","state":"radarr_config_installed"}\n'))
    engine = UnixArrConfigEngine(
        endpoint, transport_factory=lambda _: transport,
        stdin_factory=lambda _: stdin, name_factory=lambda: '6' * 32)

    result = engine.install(
        binding, HELPER, 'linux/arm64', cancelled=threading.Event(),
        before_dispatch=lambda: True)

    body = json.loads(transport.calls[0][2])
    assert body['Cmd'] == ['install_radarr_config']
    assert body['Labels']['org.larenor.service'] == 'radarr'
    assert result == ArrConfigHelperResult(
        'radarr_config_installed', binding.configuration_digest)


class InstalledEngine:
    def __init__(self, endpoint, result=None):
        self._endpoint = endpoint
        self.result = result
        self.calls = []

    def install(self, binding, helper, platform, *, cancelled, before_dispatch):
        self.calls.append((binding, helper, platform, cancelled))
        assert before_dispatch() is True
        if isinstance(self.result, Exception):
            raise self.result
        return self.result or ArrConfigHelperResult(
            'sonarr_config_installed', binding.configuration_digest)


class MutatingEngine(InstalledEngine):
    def install(self, binding, helper, platform, *, cancelled, before_dispatch):
        result = super().install(
            binding, helper, platform, cancelled=cancelled,
            before_dispatch=before_dispatch)
        object.__setattr__(binding, 'configuration_digest', '9' * 64)
        return result


def test_installer_rebinds_source_before_and_after_effect(tmp_path):
    journal, intent, binding = prepared(tmp_path)
    endpoint = DockerEndpoint('/private/docker.sock', owner_uid=0)
    engine = InstalledEngine(endpoint)
    installer = ArrConfigInstaller(
        endpoint, HELPER, 'linux/amd64', engine_factory=lambda _: engine)

    receipt = installer.install(
        binding, journal, intent, api_key=API_KEY,
        cancelled=threading.Event(), before_dispatch=lambda: True)

    assert receipt.service_id == binding.service_id == 'sonarr'
    assert receipt.resource_id == binding.resource_id
    assert receipt.operation_id == binding.operation_id
    assert receipt.journal_id == binding.journal_id
    assert receipt.revision == binding.revision
    assert receipt.volume_name == binding.volume_name
    assert receipt.configuration_digest == binding.configuration_digest
    assert receipt.state == 'sonarr_config_installed'
    assert len(engine.calls) == 1
    assert API_KEY not in repr(receipt)


def test_installer_rejects_forged_binding_before_effect(tmp_path):
    journal, intent, binding = prepared(tmp_path)
    endpoint = DockerEndpoint('/private/docker.sock', owner_uid=0)
    engine = InstalledEngine(endpoint)
    installer = ArrConfigInstaller(
        endpoint, HELPER, 'linux/amd64', engine_factory=lambda _: engine)
    forged = replace(binding, configuration_digest='9' * 64)
    with pytest.raises(
        ArrConfigEffectError,
        match='^arr_config_effect_untrusted$',
    ):
        installer.install(
            forged, journal, intent, api_key=API_KEY,
            cancelled=threading.Event(), before_dispatch=lambda: True)
    assert engine.calls == []


def test_installer_rejects_forged_service_before_effect(tmp_path):
    journal, intent, binding = prepared(tmp_path)
    endpoint = DockerEndpoint('/private/docker.sock', owner_uid=0)
    engine = InstalledEngine(endpoint)
    installer = ArrConfigInstaller(
        endpoint, HELPER, 'linux/amd64', engine_factory=lambda _: engine)
    forged = replace(binding, service_id='radarr')

    with pytest.raises(
        ArrConfigEffectError,
        match='^arr_config_effect_untrusted$',
    ):
        installer.install(
            forged, journal, intent, api_key=API_KEY,
            cancelled=threading.Event(), before_dispatch=lambda: True)

    assert engine.calls == []


def test_installer_rejects_cross_service_result_as_uncertain(tmp_path):
    journal, intent, binding = prepared(tmp_path)
    endpoint = DockerEndpoint('/private/docker.sock', owner_uid=0)
    engine = InstalledEngine(endpoint, ArrConfigHelperResult(
        'radarr_config_installed', binding.configuration_digest))
    installer = ArrConfigInstaller(
        endpoint, HELPER, 'linux/amd64', engine_factory=lambda _: engine)

    with pytest.raises(
        ArrConfigEffectError,
        match='^arr_config_effect_authority_changed$',
    ) as raised:
        installer.install(
            binding, journal, intent, api_key=API_KEY,
            cancelled=threading.Event(), before_dispatch=lambda: True)

    assert raised.value.uncertain_effect is True
    assert len(engine.calls) == 1


def test_source_change_after_effect_is_uncertain_and_secret_free(tmp_path, monkeypatch):
    from larenor_server.plugins import arr_config_effect as module
    journal, intent, binding = prepared(tmp_path)
    endpoint = DockerEndpoint('/private/docker.sock', owner_uid=0)
    engine = InstalledEngine(endpoint)
    installer = ArrConfigInstaller(
        endpoint, HELPER, 'linux/amd64', engine_factory=lambda _: engine)
    checks = iter((True, False))
    monkeypatch.setattr(
        module, 'verify_arr_config_binding',
        lambda *_args, **_kwargs: next(checks))
    with pytest.raises(
        ArrConfigEffectError,
        match='^arr_config_effect_authority_changed$',
    ) as raised:
        installer.install(
            binding, journal, intent, api_key=API_KEY,
            cancelled=threading.Event(), before_dispatch=lambda: True)
    assert raised.value.uncertain_effect is True
    assert API_KEY not in repr(raised.value)


def test_in_process_binding_mutation_after_effect_is_rejected(tmp_path):
    journal, intent, binding = prepared(tmp_path)
    endpoint = DockerEndpoint('/private/docker.sock', owner_uid=0)
    engine = MutatingEngine(endpoint)
    installer = ArrConfigInstaller(
        endpoint, HELPER, 'linux/amd64', engine_factory=lambda _: engine)

    with pytest.raises(
        ArrConfigEffectError,
        match='^arr_config_effect_authority_changed$',
    ) as raised:
        installer.install(
            binding, journal, intent, api_key=API_KEY, cancelled=threading.Event(),
            before_dispatch=lambda: True)

    assert raised.value.uncertain_effect is True
    assert binding.configuration_digest != '9' * 64


@pytest.mark.parametrize('image,platform', [
    ('latest', 'linux/amd64'), (HELPER[:-1], 'linux/amd64'),
    (HELPER, 'linux/s390x'),
])
def test_installer_configuration_is_closed(image, platform):
    with pytest.raises(ArrConfigEffectError):
        ArrConfigInstaller(
            DockerEndpoint('/private/docker.sock', owner_uid=0), image, platform)


@pytest.mark.parametrize('stage,expected,uncertain', [
    ('create', 'arr_config_effect_create_failed', False),
    ('start', 'arr_config_effect_start_failed', False),
    ('stream', 'arr_config_effect_stream_failed', True),
    ('wait', 'arr_config_effect_wait_failed', True),
    ('cleanup', 'arr_config_effect_cleanup_failed', True),
])
def test_engine_failures_are_static_and_known_containers_are_removed(
    tmp_path, stage, expected, uncertain,
):
    _journal, _intent, binding = prepared(tmp_path)
    endpoint = DockerEndpoint('/private/docker.sock', owner_uid=0)
    success_output = (
        b'{"schemaVersion":1,"sha256":"' +
        binding.configuration_digest.encode() +
        b'","state":"sonarr_config_installed"}\n')
    stdin = StdinTransport(
        endpoint,
        EngineStdinError('engine_stdin_unavailable')
        if stage == 'stream' else success_output,
    )
    replies = {
        'create': [response(500)],
        'start': [response(201, {'Id': CONTAINER, 'Warnings': None}),
                  response(500), response(204)],
        'stream': [response(201, {'Id': CONTAINER, 'Warnings': None}),
                   response(204), response(204)],
        'wait': [response(201, {'Id': CONTAINER, 'Warnings': None}),
                 response(204), response(200, {'StatusCode': 1}), response(204)],
        'cleanup': [response(201, {'Id': CONTAINER, 'Warnings': None}),
                    response(204), response(200, {'StatusCode': 0}), response(500)],
    }[stage]
    transport = ExchangeTransport(replies)
    engine = UnixArrConfigEngine(
        endpoint, transport_factory=lambda _: transport,
        stdin_factory=lambda _: stdin, name_factory=lambda: '6' * 32)
    with pytest.raises(ArrConfigEffectError, match='^' + expected + '$') as raised:
        engine.install(
            binding, HELPER, 'linux/amd64', cancelled=threading.Event(),
            before_dispatch=lambda: True)
    assert raised.value.uncertain_effect is uncertain
    if stage != 'create':
        assert transport.calls[-1][:2] == (
            'DELETE', f'/containers/{CONTAINER}?force=1&v=0')
    assert API_KEY not in repr(raised.value)


def test_helper_output_must_be_exact_and_never_enters_error(tmp_path):
    _journal, _intent, binding = prepared(tmp_path)
    endpoint = DockerEndpoint('/private/docker.sock', owner_uid=0)
    transport = ExchangeTransport([
        response(201, {'Id': CONTAINER, 'Warnings': None}), response(204),
        response(204),
    ])
    stdin = StdinTransport(endpoint, b'private helper output')
    engine = UnixArrConfigEngine(
        endpoint, transport_factory=lambda _: transport,
        stdin_factory=lambda _: stdin, name_factory=lambda: '6' * 32)
    with pytest.raises(
        ArrConfigEffectError,
        match='^arr_config_effect_result_failed$',
    ) as raised:
        engine.install(
            binding, HELPER, 'linux/amd64', cancelled=threading.Event(),
            before_dispatch=lambda: True)
    assert 'private helper output' not in repr(raised.value)
    assert raised.value.uncertain_effect is True


def test_malformed_created_identity_is_never_used_in_cleanup(tmp_path):
    _journal, _intent, binding = prepared(tmp_path)
    endpoint = DockerEndpoint('/private/docker.sock', owner_uid=0)
    transport = ExchangeTransport([
        response(201, {'Id': '../foreign', 'Warnings': None}),
    ])
    engine = UnixArrConfigEngine(
        endpoint, transport_factory=lambda _: transport,
        stdin_factory=lambda _: StdinTransport(endpoint),
        name_factory=lambda: '6' * 32)

    with pytest.raises(
        ArrConfigEffectError,
        match='^arr_config_effect_create_failed$',
    ) as raised:
        engine.install(
            binding, HELPER, 'linux/amd64', cancelled=threading.Event(),
            before_dispatch=lambda: True)

    assert raised.value.uncertain_effect is True
    assert len(transport.calls) == 1
    assert transport.calls[0][0] == 'POST'


def test_helper_cannot_report_the_other_arr_service_state(tmp_path):
    _journal, _intent, binding = prepared(tmp_path)
    endpoint = DockerEndpoint('/private/docker.sock', owner_uid=0)
    transport = ExchangeTransport([
        response(201, {'Id': CONTAINER, 'Warnings': None}), response(204),
        response(204),
    ])
    stdin = StdinTransport(endpoint, (
        b'{"schemaVersion":1,"sha256":"' +
        binding.configuration_digest.encode() +
        b'","state":"radarr_config_installed"}\n'))
    engine = UnixArrConfigEngine(
        endpoint, transport_factory=lambda _: transport,
        stdin_factory=lambda _: stdin, name_factory=lambda: '6' * 32)
    with pytest.raises(
        ArrConfigEffectError,
        match='^arr_config_effect_result_failed$',
    ) as raised:
        engine.install(
            binding, HELPER, 'linux/amd64', cancelled=threading.Event(),
            before_dispatch=lambda: True)
    assert raised.value.uncertain_effect is True


def test_stream_failure_preserves_only_closed_engine_cause(tmp_path):
    _journal, _intent, binding = prepared(tmp_path)
    endpoint = DockerEndpoint('/private/docker.sock', owner_uid=0)
    transport = ExchangeTransport([
        response(201, {'Id': CONTAINER, 'Warnings': None}), response(204),
        response(204),
    ])
    stdin = StdinTransport(
        endpoint, EngineStdinError('engine_stdin_protocol'))
    engine = UnixArrConfigEngine(
        endpoint, transport_factory=lambda _: transport,
        stdin_factory=lambda _: stdin, name_factory=lambda: '6' * 32)

    with pytest.raises(ArrConfigEffectError) as raised:
        engine.install(
            binding, HELPER, 'linux/amd64', cancelled=threading.Event(),
            before_dispatch=lambda: True)

    assert raised.value.code == 'arr_config_effect_stream_failed'
    assert raised.value.cause_code == 'engine_stdin_protocol'
    assert 'private' not in repr(raised.value)


def test_effect_api_has_no_caller_path_command_or_container_specification():
    parameters = inspect.signature(ArrConfigInstaller.install).parameters
    assert set(parameters) == {
        'self', 'binding', 'journal', 'intent', 'api_key',
        'cancelled', 'before_dispatch'}
    forbidden = {'path', 'volume', 'command', 'image', 'container', 'docker'}
    assert not forbidden & set(parameters)


def test_cancelled_install_never_reaches_engine(tmp_path):
    journal, intent, binding = prepared(tmp_path)
    endpoint = DockerEndpoint('/private/docker.sock', owner_uid=0)
    engine = InstalledEngine(endpoint)
    installer = ArrConfigInstaller(
        endpoint, HELPER, 'linux/amd64', engine_factory=lambda _: engine)
    cancelled = threading.Event()
    cancelled.set()
    with pytest.raises(
        ArrConfigEffectError,
        match='^arr_config_effect_cancelled$',
    ):
        installer.install(
            binding, journal, intent, api_key=API_KEY,
            cancelled=cancelled, before_dispatch=lambda: True)
    assert engine.calls == []
