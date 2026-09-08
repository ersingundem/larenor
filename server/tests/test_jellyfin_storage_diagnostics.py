"""Offline failure receipts execute the real fixture flow with owned fakes."""
import importlib

import pytest

from test_jellyfin_storage_smoke import protocol


@pytest.fixture
def launched(protocol, monkeypatch):
    smoke, source, daemon, images = protocol
    ci = importlib.import_module('tool.jellyfin_storage_ci')
    events = []
    actual = smoke.characterize
    monkeypatch.setattr(ci, 'validate_launch', lambda *args: 'linux/amd64')
    class Owned:
        process = None
        def __enter__(self):
            events.append('enter')
            return daemon
        def __exit__(self, *_):
            events.append('cleanup')
    monkeypatch.setattr(smoke, 'EphemeralDaemon', Owned)
    monkeypatch.setattr(smoke, 'characterize', lambda owner, **kwargs:
        actual(owner, source=source, images=images, volumes=object(), **kwargs))
    return ci, daemon, events


@pytest.mark.parametrize('fault,phase,code', [
    ('initialize_empty_root', 'bootstrap_initialize', 'fixture_command_failed'),
    ('start', 'container_start', 'fixture_command_failed'),
    ('restart', 'container_restart', 'fixture_command_failed'),
    ('identity', 'restart_health', 'restart_identity_changed'),
    ('mount', 'container_inspect', 'storage_characterization_failed'),
    ('initial_data', 'initial_data', 'fixture_command_failed'),
])
def test_actual_failure_phase_survives_cleanup_without_success_or_replay(launched, capsys, fault, phase, code):
    ci, daemon, events = launched
    daemon.fault = fault
    assert ci.main(['--run-ephemeral-ci']) == 1
    assert events == ['enter', 'cleanup']
    output = capsys.readouterr()
    assert output.out == ''
    assert output.err == f'storage_characterization_failed phase={phase} code={code}\n'
    assert sum(call[0] == 'create' for call in daemon.calls) <= 1
    assert sum(call[0] == 'restart' for call in daemon.calls) <= 1


def test_build_exception_text_never_escapes_but_its_stage_does(launched, monkeypatch, capsys):
    ci, daemon, events = launched
    actual = daemon.docker
    def docker(args, **kwargs):
        if args[0] == 'build':
            raise OSError('synthetic-secret /private/fixture/path DOCKER_HOST=private')
        return actual(args, **kwargs)
    monkeypatch.setattr(daemon, 'docker', docker)
    assert ci.main(['--run-ephemeral-ci']) == 1
    output = capsys.readouterr()
    assert output.out == ''
    assert output.err == ('storage_characterization_failed '
        'phase=helper_build code=storage_characterization_failed\n')
    assert events[-1] == 'cleanup'


def test_source_failure_is_distinct_and_does_not_start_daemon(launched, monkeypatch, capsys):
    ci, _, events = launched
    def reject(_):
        raise ci.smoke.SmokeError('fixture_source_changed')
    monkeypatch.setattr(ci.smoke, 'capture_source', reject)
    assert ci.main(['--run-ephemeral-ci']) == 1
    assert events == []
    assert capsys.readouterr().err == ('storage_characterization_failed '
        'phase=source_capture code=fixture_source_changed\n')
