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


def test_actual_daemon_start_failure_cleans_its_directory(launched, monkeypatch, tmp_path, capsys):
    ci, _, _ = launched
    # Recover the real class from a fresh module load without constructing Docker.
    import importlib.util
    spec = importlib.util.spec_from_file_location('diagnostic_owned', ci.smoke.__file__)
    module = importlib.util.module_from_spec(spec)
    import sys
    monkeypatch.setitem(sys.modules, spec.name, module)
    spec.loader.exec_module(module)
    owned = tmp_path/'owned'
    monkeypatch.setattr(module, 'native_platform', lambda *args: 'linux/amd64')
    def directory(**kwargs):
        owned.mkdir(mode=0o700)
        return str(owned)
    def spawn(*args, **kwargs):
        raise OSError('synthetic private daemon launch text')
    monkeypatch.setattr(module.tempfile, 'mkdtemp', directory)
    monkeypatch.setattr(module.subprocess, 'Popen', spawn)
    with pytest.raises(module.SmokeError) as caught:
        module.EphemeralDaemon().__enter__()
    assert not owned.exists()
    assert module.failure_diagnostic(caught.value) == ('storage_characterization_failed '
        'phase=daemon_start code=storage_characterization_failed')
    assert capsys.readouterr().out == ''


def test_actual_cleanup_failure_has_priority_and_cannot_publish_success(monkeypatch, tmp_path, capsys):
    ci = importlib.import_module('tool.jellyfin_storage_ci')
    monkeypatch.setenv('GITHUB_SHA', 'a'*40)
    monkeypatch.setattr(ci, 'validate_launch', lambda *args: 'linux/amd64')
    monkeypatch.setattr(ci.smoke, 'capture_source', lambda _: ('a'*40, {}))
    def enter(owner):
        owner.root = tmp_path/'owned'
        owner.root.mkdir(mode=0o700)
        info = owner.root.lstat()
        owner.root_identity = info.st_dev, info.st_ino
        return owner
    monkeypatch.setattr(ci.smoke.EphemeralDaemon, '__enter__', enter)
    def cleanup(_):
        raise OSError('synthetic-private-cleanup-path')
    monkeypatch.setattr(ci.smoke.shutil, 'rmtree', cleanup)
    monkeypatch.setattr(ci.smoke, 'characterize', lambda *args, **kwargs: {'result':'characterized'})
    monkeypatch.setattr(ci, 'validate_receipt', lambda *args: pytest.fail('cleanup failure verified receipt'))
    assert ci.main(['--run-ephemeral-ci']) == 1
    output = capsys.readouterr()
    assert output.out == ''
    assert output.err == ('storage_characterization_failed '
        'phase=daemon_cleanup code=storage_characterization_failed\n')


@pytest.mark.parametrize('payload', ['synthetic-secret /private/path', 'x'*10000, ['secret'], None])
def test_exception_payload_and_mutated_phase_cannot_escape(launched, monkeypatch, capsys, payload):
    ci, _, _ = launched
    error = ci.smoke.SmokeError()
    error.args = (payload,)
    error.phase = payload
    def failed():
        raise error
    monkeypatch.setattr(ci, 'run', failed)
    assert ci.main(['--run-ephemeral-ci']) == 1
    output = capsys.readouterr()
    assert output.out == ''
    assert output.err == ('storage_characterization_failed '
        'phase=launcher code=storage_characterization_failed\n')


def test_exception_str_and_args_override_are_never_evaluated(launched, monkeypatch, capsys):
    ci, _, _ = launched
    class PrivateError(Exception):
        def __str__(self):
            pytest.fail('formatted raw exception')
        @property
        def args(self):
            pytest.fail('read custom exception property')
    def failed():
        raise PrivateError('synthetic-secret')
    monkeypatch.setattr(ci, 'run', failed)
    assert ci.main(['--run-ephemeral-ci']) == 1
    assert capsys.readouterr().err == ('storage_characterization_failed '
        'phase=launcher code=storage_characterization_failed\n')


@pytest.mark.parametrize('kind,phase,code', [
    ('image', 'image_prepare', 'image_observation_unavailable'),
    ('volume', 'volume_prepare', 'fixture_volume_unresolved'),
])
def test_actual_journal_composition_retains_only_closed_failure_code(tmp_path, monkeypatch, kind, phase, code):
    smoke = importlib.import_module('tool.jellyfin_storage_smoke')
    from larenor_server.plugins.image_resources import ImageObservation, ImageResourceError
    from larenor_server.plugins.volume_effects import VolumeEffectError
    source = smoke.fixture_source('linux/amd64')
    class Images:
        def pull(self, *args, **kwargs):
            pytest.fail('failed inspection must not pull')
        def inspect(self, binding, **kwargs):
            if kind == 'image':
                raise ImageResourceError('image_engine_unavailable')
            return ImageObservation(binding.config_digest, b'{}')
    class Volumes:
        def create(self, *args, **kwargs):
            pytest.fail('failed probe must not create')
        def probe(self, *args, **kwargs):
            raise VolumeEffectError('volume_timeout')
    with pytest.raises(smoke.SmokeError) as caught:
        smoke.prepare_storage(tmp_path, source, Images(), Volumes())
    assert smoke.failure_diagnostic(caught.value) == f'storage_characterization_failed phase={phase} code={code}'
