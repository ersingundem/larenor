"""Offline contract for the separate journaled managed-container acceptance."""

import copy
import importlib
import json
from pathlib import Path

import pytest


def api():
    return importlib.import_module('tool.jellyfin_managed_ci')


def receipt(module):
    source = module.smoke.fixture_source('linux/amd64')
    hashes = module.smoke.source_hashes()
    helper = module.smoke.helper_attestation(
        'sha256:' + 'f' * 64,
        {'Id': 'sha256:' + 'f' * 64, 'Os': 'linux', 'Architecture': 'amd64',
         'Config': {'Labels': module.smoke.source_labels('a' * 40, hashes)}},
        'linux/amd64', 'a' * 40,
    )
    return {
        'schemaVersion': 1, 'result': 'characterized', 'platform': 'linux/amd64',
        'catalogDigest': source.catalog.digest,
        'jellyfinManifestDigest': source.image.image.digest,
        'jellyfinConfigDigest': source.image.image.configDigest,
        'helper': helper, 'volumeCount': 2, 'restartCount': 1,
        'serverId': 'b' * 32, 'containerMode': 'journaled_managed_v2',
        'containerJournalVersion': 2, 'bootstrapAccountConfigured': False,
        'installAvailable': False, 'imageState': 'ready',
        'volumeStates': ['observed_requires_bootstrap'] * 2,
    }


def test_managed_receipt_requires_exact_v2_execution_evidence():
    module = api()
    value = receipt(module)
    assert module.validate_receipt(value, 'a' * 40, 'linux/amd64') is None
    for field in ('containerMode', 'containerJournalVersion'):
        damaged = copy.deepcopy(value)
        damaged.pop(field)
        with pytest.raises(module.ManagedCIError):
            module.validate_receipt(damaged, 'a' * 40, 'linux/amd64')


def test_managed_run_uses_opt_in_mode_and_publishes_after_cleanup(monkeypatch, capsys):
    module = api()
    value, events = receipt(module), []
    monkeypatch.setenv('GITHUB_SHA', 'a' * 40)
    monkeypatch.setattr(module, 'validate_launch', lambda *args: 'linux/amd64')
    monkeypatch.setattr(module.smoke, 'capture_source',
                        lambda commit: events.append(('capture', commit)) or ('a' * 40, {}))
    monkeypatch.setattr(module.smoke, 'check_source',
                        lambda binding: events.append(('recheck', binding[0])))

    class Owned:
        process = None
        def __enter__(self):
            events.append('enter')
            return self
        def __exit__(self, *_):
            assert capsys.readouterr().out == ''
            events.append('cleanup')
        def emergency_cleanup(self):
            events.append('emergency')

    monkeypatch.setattr(module.smoke, 'EphemeralDaemon', Owned)
    def characterize(_owner, **kwargs):
        assert kwargs['managed'] is True
        events.append('managed')
        return value
    monkeypatch.setattr(module.smoke, 'characterize', characterize)

    assert module.main(['--run-ephemeral-ci']) == 0
    assert events == [('capture', 'a' * 40), 'enter', 'managed', 'cleanup',
                      ('recheck', 'a' * 40)]
    assert json.loads(capsys.readouterr().out) == value


def test_managed_receipt_verification_never_starts_a_daemon(tmp_path, monkeypatch, capsys):
    module = api()
    path = tmp_path / 'receipt.json'
    path.write_text(json.dumps(receipt(module)))
    monkeypatch.setenv('GITHUB_SHA', 'a' * 40)
    monkeypatch.setenv('EXPECTED_PLATFORM', 'linux/amd64')
    monkeypatch.setattr(module.smoke, 'verify_checkout', lambda _commit: None)
    monkeypatch.setattr(module.smoke, 'EphemeralDaemon',
                        lambda: pytest.fail('receipt verification started a daemon'))
    assert module.main(['--verify-receipt', str(path)]) == 0
    assert capsys.readouterr().out == 'managed_characterization_receipt_verified\n'


@pytest.mark.parametrize('arguments', [[], ['--run'], ['--socket', '/var/run/docker.sock']])
def test_managed_ci_has_no_generic_or_external_socket_cli(arguments, monkeypatch, capsys):
    module = api()
    monkeypatch.setattr(module, 'run', lambda: pytest.fail('invalid CLI started fixture'))
    assert module.main(arguments) == 1
    assert capsys.readouterr().out == ''
