"""Real bounded child failures within the synthetic helper-build composition."""
import importlib
import sys

import pytest

from test_jellyfin_storage_diagnostics import launched, protocol


@pytest.mark.parametrize('fault,code', [
    ('exit', 'fixture_command_exit_failed'),
    ('overflow', 'fixture_command_output_limit'),
    ('timeout', 'fixture_command_timeout'),
    ('spawn', 'fixture_command_spawn_failed'),
    ('read', 'fixture_command_io_failed'),
])
def test_helper_build_distinguishes_real_child_failures_without_output_or_retry(
        launched, monkeypatch, tmp_path, capsys, fault, code):
    ci, daemon, events = launched
    smoke = ci.smoke
    actual_docker, actual_spawn = daemon.docker, smoke.subprocess.Popen
    processes = []
    builds = []
    def spawn(*args, **kwargs):
        expected = smoke.subprocess.PIPE if builds else smoke.subprocess.DEVNULL
        assert kwargs['stderr'] is expected
        child = actual_spawn(*args, **kwargs)
        processes.append(child)
        return child
    monkeypatch.setattr(smoke.subprocess, 'Popen', spawn)
    def docker(args, **kwargs):
        if args[0] != 'build':
            return actual_docker(args, **kwargs)
        builds.append(args)
        assert kwargs['limit'] == 256 and kwargs['timeout'] == 600
        programs = {
            'exit': 'import sys; print("synthetic-private-stdout"); print("synthetic-private-stderr",file=sys.stderr); sys.exit(17)',
            'overflow': 'print("synthetic-private-output-"*32)',
            'timeout': 'import time; time.sleep(30)',
            'read': 'import time; print("synthetic-private-output",flush=True); time.sleep(30)',
        }
        command = ([str(tmp_path/'no-such-synthetic-program')] if fault == 'spawn'
                   else [sys.executable, '-c', programs[fault]])
        kwargs['timeout'] = 0.1 if fault == 'timeout' else 3
        with monkeypatch.context() as local:
            if fault == 'read':
                actual_read = smoke.os.read
                def failed_read(fd, *args):
                    if any(not child.stdout.closed and child.stdout.fileno() == fd for child in processes):
                        raise OSError('synthetic-private-read-error')
                    return actual_read(fd, *args)
                local.setattr(smoke.os, 'read', failed_read)
            return smoke.bounded_command(command, environment={}, **kwargs)
    monkeypatch.setattr(daemon, 'docker', docker)
    assert ci.main(['--run-ephemeral-ci']) == 1
    assert len(builds) == 1
    assert events == ['enter', 'cleanup']
    assert all(child.poll() is not None and child.stdout.closed for child in processes)
    assert all(child.stderr is None or child.stderr.closed for child in processes)
    assert sum(call[0] == 'create' and '--name=larenor-helper-base-probe' in call for call in daemon.calls) == 1
    assert sum(call == ['start','--attach','d'*64] for call in daemon.calls) == 1
    assert not any(call[0] == 'restart' or call == ['start','c'*64]
        or (call[0] == 'create' and '--name=larenor-helper-base-probe' not in call) for call in daemon.calls)
    output = capsys.readouterr()
    assert output.out == ''
    assert output.err == f'storage_characterization_failed phase=helper_build code={code}\n'


def test_exact_output_limit_and_large_discarded_stderr_preserve_success():
    smoke = importlib.import_module('tool.jellyfin_storage_smoke')
    program = 'import os; os.write(2,b"synthetic-private-stderr"*65536); os.write(1,b"x"*256)'
    output = smoke.bounded_command([sys.executable, '-c', program],
        environment={}, timeout=3, limit=256, diagnose_failure=False)
    assert output == b'x'*256


def test_timeout_after_stdout_eof_uses_same_closed_timeout_code():
    smoke = importlib.import_module('tool.jellyfin_storage_smoke')
    with pytest.raises(smoke.SmokeError, match='^fixture_command_timeout$'):
        smoke.bounded_command([sys.executable, '-c', 'import os,time; os.close(1); time.sleep(30)'],
            environment={}, timeout=0.15, limit=256, diagnose_failure=True)


@pytest.mark.parametrize('value', [1, 0, 'true', None])
def test_diagnostic_selector_is_strict_before_spawning(monkeypatch, value):
    smoke = importlib.import_module('tool.jellyfin_storage_smoke')
    monkeypatch.setattr(smoke.subprocess, 'Popen', lambda *a, **kw: pytest.fail('invalid selector spawned child'))
    with pytest.raises(smoke.SmokeError, match='^fixture_command_failed$'):
        smoke.bounded_command(['unused'], environment={}, diagnose_failure=value)


def test_complete_consumer_selects_detailed_codes_for_only_one_build(protocol, monkeypatch):
    smoke, source, daemon, images = protocol
    actual = daemon.docker
    selected = []
    def docker(args, **kwargs):
        if kwargs.get('diagnose_failure') is True:
            selected.append(args)
        return actual(args, **kwargs)
    monkeypatch.setattr(daemon, 'docker', docker)
    result = smoke.characterize(daemon, source=source, images=images, volumes=object())
    assert result['result'] == 'characterized' and result['installAvailable'] is False
    assert len(selected) == 1 and selected[0][0] == 'build'


def test_owned_daemon_forwards_opt_in_without_changing_socket_or_environment(tmp_path, monkeypatch):
    smoke = importlib.import_module('tool.jellyfin_storage_smoke')
    owner = smoke.EphemeralDaemon()
    owner.root = tmp_path
    calls = []
    monkeypatch.setattr(owner, '_socket', lambda: calls.append('socket_verified'))
    def command(args, **kwargs):
        assert calls == ['socket_verified']
        assert args == ['/usr/bin/docker', '--host=unix://'+str(tmp_path/'engine.sock'),
                        '--config='+str(tmp_path/'docker-config'), 'build']
        assert kwargs == {'environment':smoke.child_environment(tmp_path),
                          'timeout':600, 'limit':256, 'diagnose_failure':True, 'diagnose_process':False, 'diagnose_start':False}
        return b'synthetic-id'
    monkeypatch.setattr(smoke, 'bounded_command', command)
    assert owner.docker(['build'], timeout=600, limit=256, diagnose_failure=True) == b'synthetic-id'
