"""Offline contract for native managed qBittorrent acceptance."""

import copy
import importlib
import json
from types import SimpleNamespace

import pytest


def api():
    return importlib.import_module('tool.qbittorrent_managed_ci')


def receipt(module):
    source = module.fixture_source('linux/amd64')
    hashes = module.smoke.source_hashes()
    helper = module.smoke.helper_attestation(
        'sha256:' + 'f' * 64,
        {'Id': 'sha256:' + 'f' * 64, 'Os': 'linux', 'Architecture': 'amd64',
         'Config': {'Labels': module.smoke.source_labels('a' * 40, hashes)}},
        'linux/amd64', 'a' * 40,
    )
    return {
        'schemaVersion': 1,
        'result': 'qbittorrent_characterized',
        'platform': 'linux/amd64',
        'sourceCommit': 'a' * 40,
        'catalogDigest': source.catalog.digest,
        'qbittorrentManifestDigest': source.image.image.digest,
        'qbittorrentConfigDigest': source.image.image.configDigest,
        'helper': helper,
        'imageState': 'ready',
        'networkState': 'ready',
        'volumeStates': ['observed_requires_bootstrap'] * 2,
        'volumeCount': 2,
        'containerMode': 'journaled_managed_v2',
        'containerJournalVersion': 2,
        'configurationState': 'qbittorrent_config_installed',
        'containerState': 'qbittorrent_container_started',
        'serviceState': 'qbittorrent_service_verified',
        'categoryCount': 2,
        'categoriesPersistent': True,
        'apiKeyVerified': True,
        'restartCount': 1,
        'installAvailable': False,
    }


def test_receipt_requires_exact_service_and_restart_evidence():
    module = api()
    value = receipt(module)
    assert module.validate_receipt(value, 'a' * 40, 'linux/amd64') is None
    for field in (
        'configurationState', 'containerState', 'serviceState',
        'categoryCount', 'categoriesPersistent', 'apiKeyVerified',
        'restartCount',
    ):
        damaged = copy.deepcopy(value)
        damaged.pop(field)
        with pytest.raises(module.QbittorrentManagedCIError):
            module.validate_receipt(damaged, 'a' * 40, 'linux/amd64')
    serialized = json.dumps(value)
    assert '"apiKey":' not in serialized and '"credential":' not in serialized


def test_launch_accepts_only_exact_main_or_same_repository_pr_merge():
    module = api()
    base = {
        'CI': 'true', 'GITHUB_ACTIONS': 'true',
        'RUNNER_ENVIRONMENT': 'github-hosted', 'RUNNER_ARCH': 'X64',
        'GITHUB_REPOSITORY': 'ersingundem/larenor',
        'GITHUB_WORKFLOW_SHA': 'a' * 40, 'GITHUB_SHA': 'a' * 40,
        'EXPECTED_PLATFORM': 'linux/amd64',
    }
    manual = {**base, 'GITHUB_EVENT_NAME': 'workflow_dispatch',
              'GITHUB_REF': 'refs/heads/main', 'GITHUB_BASE_REF': '',
              'PR_HEAD_REPOSITORY': ''}
    pull = {**base, 'GITHUB_EVENT_NAME': 'pull_request',
            'GITHUB_REF': 'refs/pull/40/merge', 'GITHUB_BASE_REF': 'main',
            'PR_HEAD_REPOSITORY': 'ersingundem/larenor'}
    assert module.validate_launch(manual, 'Linux', 'x86_64', 0) == 'linux/amd64'
    assert module.validate_launch(pull, 'Linux', 'x86_64', 0) == 'linux/amd64'
    for damaged in (
        {**pull, 'PR_HEAD_REPOSITORY': 'fork/larenor'},
        {**pull, 'GITHUB_REF': 'refs/heads/feature'},
        {**pull, 'GITHUB_BASE_REF': 'release'},
        {**pull, 'GITHUB_WORKFLOW_SHA': 'b' * 40},
    ):
        with pytest.raises(module.QbittorrentManagedCIError):
            module.validate_launch(damaged, 'Linux', 'x86_64', 0)


def test_run_is_opt_in_and_publishes_only_after_owned_cleanup(monkeypatch, capsys):
    module = api()
    value, events = receipt(module), []
    monkeypatch.setenv('GITHUB_SHA', 'a' * 40)
    monkeypatch.setattr(module, 'validate_launch', lambda *args: 'linux/amd64')
    monkeypatch.setattr(module.smoke, 'capture_source',
                        lambda commit: events.append(('capture', commit)) or ('a' * 40, {}))
    monkeypatch.setattr(module.smoke, 'check_source',
                        lambda binding: events.append(('recheck', binding[0])))

    class Owned:
        def __enter__(self):
            events.append('enter')
            return self
        def __exit__(self, *_):
            assert capsys.readouterr().out == ''
            events.append('cleanup')
        def emergency_cleanup(self):
            events.append('emergency')

    monkeypatch.setattr(module.smoke, 'EphemeralDaemon', Owned)
    monkeypatch.setattr(
        module, 'characterize',
        lambda _owner, **kwargs: events.append(('native', kwargs['checkout_binding'][0])) or value)
    assert module.main(['--run-ephemeral-ci']) == 0
    assert events == [('capture', 'a' * 40), 'enter', ('native', 'a' * 40),
                      'cleanup', ('recheck', 'a' * 40)]
    assert json.loads(capsys.readouterr().out) == value


def test_characterize_projects_only_closed_native_evidence(monkeypatch):
    module = api()
    expected = receipt(module)
    source = module.fixture_source('linux/amd64')
    binding = ('a' * 40, module.smoke.source_hashes())
    events = []
    daemon = SimpleNamespace(platform='linux/amd64')
    monkeypatch.setattr(module, 'fixture_source', lambda _platform: source)
    monkeypatch.setattr(
        module.smoke, 'check_source',
        lambda value: events.append(('source', value[0])))
    monkeypatch.setattr(
        module, '_prepare_resources',
        lambda _daemon, _source: (events.append('resources') or
                                  ('endpoint', expected['volumeStates'])))
    monkeypatch.setattr(
        module, '_build_helper',
        lambda _daemon, _binding: (events.append('helper') or
                                   ('sha256:' + 'f' * 64,
                                    expected['helper'])))
    monkeypatch.setattr(
        module, '_prepare_volumes',
        lambda _daemon, _source, _helper: events.append('volumes'))
    result = SimpleNamespace(
        configuration=SimpleNamespace(
            state='qbittorrent_config_installed'),
        state='qbittorrent_container_started',
        service_state='qbittorrent_service_verified')
    monkeypatch.setattr(
        module, '_install_and_restart',
        lambda *_args: events.append('runtime') or result)
    assert module.characterize(
        daemon, checkout_binding=binding) == expected
    assert events == [
        ('source', 'a' * 40), 'resources', 'helper', 'volumes',
        'runtime', ('source', 'a' * 40)]
    serialized = json.dumps(expected)
    assert '"apiKey":' not in serialized and '"credential":' not in serialized


def test_runtime_backend_supplies_both_config_runtimes(monkeypatch):
    module = api()
    from larenor_server.plugins import arr_config_runtime
    from larenor_server.plugins import installation_runtime
    from larenor_server.plugins import qbittorrent_config_runtime

    calls = []

    def config(kind):
        def build(*arguments):
            value = (kind, arguments)
            calls.append(value)
            return value
        return build

    def backend(*arguments):
        calls.append(('backend', arguments))
        return arguments

    monkeypatch.setattr(
        qbittorrent_config_runtime, 'QbittorrentConfigRuntime',
        config('qbittorrent'))
    monkeypatch.setattr(arr_config_runtime, 'ArrConfigRuntime', config('arr'))
    monkeypatch.setattr(installation_runtime, '_RuntimeBackend', backend)
    values = tuple(object() for _ in range(8))

    result = module._runtime_backend(*values)

    common = values[2:]
    assert calls == [
        ('qbittorrent', common),
        ('arr', common),
        ('backend', (values[0], values[1], calls[0], calls[1])),
    ]
    assert result == calls[2][1]


def test_receipt_verification_never_starts_daemon(tmp_path, monkeypatch, capsys):
    module = api()
    path = tmp_path / 'receipt.json'
    path.write_text(json.dumps(receipt(module)))
    monkeypatch.setenv('GITHUB_SHA', 'a' * 40)
    monkeypatch.setenv('EXPECTED_PLATFORM', 'linux/amd64')
    monkeypatch.setattr(module.smoke, 'verify_checkout', lambda _commit: None)
    monkeypatch.setattr(module.smoke, 'EphemeralDaemon',
                        lambda: pytest.fail('verification started daemon'))
    assert module.main(['--verify-receipt', str(path)]) == 0
    assert capsys.readouterr().out == 'qbittorrent_characterization_receipt_verified\n'


@pytest.mark.parametrize('arguments', [[], ['--run'], ['--socket', '/var/run/docker.sock']])
def test_cli_has_no_generic_or_external_socket_mode(arguments, monkeypatch, capsys):
    module = api()
    monkeypatch.setattr(module, 'run', lambda: pytest.fail('invalid CLI ran fixture'))
    assert module.main(arguments) == 1
    assert capsys.readouterr().out == ''


def test_static_diagnostic_phase_hides_the_original_exception():
    module = api()
    with pytest.raises(module.QbittorrentManagedCIError) as failure:
        with module.diagnostic_phase('runtime_install'):
            raise RuntimeError('private engine detail')
    assert failure.value.args == ('qbittorrent_runtime_install_failed',)
    assert failure.value.__cause__ is None
    with pytest.raises(module.QbittorrentManagedCIError) as requirement:
        with module.diagnostic_phase('resource_verify'):
            module.require(False)
    assert requirement.value.args == ('qbittorrent_resource_verify_failed',)
    with pytest.raises(module.QbittorrentManagedCIError):
        with module.diagnostic_phase('not_allowed'):
            pass


def test_diagnostic_phase_preserves_only_allowlisted_production_code():
    module = api()
    from larenor_server.plugins.qbittorrent_config_effect import (
        QbittorrentConfigEffectError,
    )

    with pytest.raises(module.QbittorrentManagedCIError) as known:
        with module.diagnostic_phase('runtime_install'):
            raise QbittorrentConfigEffectError(
                'qbittorrent_config_effect_wait_failed')
    assert known.value.args == ('qbittorrent_config_effect_wait_failed',)

    class UntrustedFailure(Exception):
        code = 'qbittorrent_config_effect_wait_failed'

    with pytest.raises(module.QbittorrentManagedCIError) as unknown:
        with module.diagnostic_phase('runtime_install'):
            raise UntrustedFailure('private detail')
    assert unknown.value.args == ('qbittorrent_runtime_install_failed',)


def test_diagnostic_phase_prefers_closed_engine_cause():
    module = api()
    from larenor_server.plugins.qbittorrent_config_effect import (
        QbittorrentConfigEffectError,
    )

    with pytest.raises(module.QbittorrentManagedCIError) as failure:
        with module.diagnostic_phase('runtime_install'):
            raise QbittorrentConfigEffectError(
                'qbittorrent_config_effect_stream_failed',
                uncertain_effect=True, cause_code='engine_stdin_protocol')
    assert failure.value.args == ('engine_stdin_protocol',)


def test_diagnostic_phase_preserves_closed_readback_cause():
    module = api()
    from larenor_server.plugins.qbittorrent_config_models import (
        QbittorrentConfigurationExecutionError,
    )

    with pytest.raises(module.QbittorrentManagedCIError) as failure:
        with module.diagnostic_phase('runtime_install'):
            raise QbittorrentConfigurationExecutionError(
                'qbittorrent_service_verification_failed',
                uncertain_effect=True,
                cause_code='qbittorrent_readback_protocol')
    assert failure.value.args == ('qbittorrent_readback_protocol',)


def test_main_prints_only_allowlisted_native_diagnostic(monkeypatch, capsys):
    module = api()
    monkeypatch.setattr(
        module, 'run',
        lambda: (_ for _ in ()).throw(
            module.QbittorrentManagedCIError(
                'qbittorrent_container_restart_failed')))
    assert module.main(['--run-ephemeral-ci']) == 1
    captured = capsys.readouterr()
    assert captured.out == ''
    assert captured.err == 'qbittorrent_container_restart_failed\n'
