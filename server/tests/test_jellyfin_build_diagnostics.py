"""Real bounded child failures within the synthetic helper-build composition."""
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
        assert kwargs['stderr'] is smoke.subprocess.DEVNULL
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
    assert not any(call[0] in {'create', 'start', 'restart'} for call in daemon.calls)
    output = capsys.readouterr()
    assert output.out == ''
    assert output.err == f'storage_characterization_failed phase=helper_build code={code}\n'
