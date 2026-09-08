"""Real child failure causes at the attached-base-start boundary, no Docker."""
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
def test_attached_start_distinguishes_child_failures_without_replay_or_disclosure(
        launched, monkeypatch, tmp_path, capsys, fault, code):
    ci, daemon, cleanup = launched
    smoke = ci.smoke
    original_docker, original_spawn = daemon.docker, smoke.subprocess.Popen
    children, starts = [], []
    def spawn(*args, **kwargs):
        child = original_spawn(*args, **kwargs)
        children.append(child)
        return child
    monkeypatch.setattr(smoke.subprocess, 'Popen', spawn)
    def docker(args, **kwargs):
        if args != ['start','--attach','d'*64]:
            return original_docker(args, **kwargs)
        starts.append(list(args))
        assert kwargs['timeout'] == 20 and kwargs['limit'] == 128
        programs = {
            'exit': 'import sys; print("synthetic-private-stdout"); print("synthetic-private-stderr",file=sys.stderr); sys.exit(17)',
            'overflow': 'print("synthetic-private-output-"*32)',
            'timeout': 'import time; time.sleep(30)',
            'read': 'import time; print("synthetic-private-read",flush=True); time.sleep(30)',
        }
        command = ([str(tmp_path/'no-such-synthetic-program')] if fault == 'spawn'
                   else [sys.executable,'-c',programs[fault]])
        kwargs['timeout'] = 0.1 if fault == 'timeout' else 3
        with monkeypatch.context() as local:
            if fault == 'read':
                original_read = smoke.os.read
                def failed_read(fd, *args):
                    if any(not child.stdout.closed and child.stdout.fileno() == fd for child in children):
                        raise OSError('synthetic-private-read-error')
                    return original_read(fd, *args)
                local.setattr(smoke.os, 'read', failed_read)
            return smoke.bounded_command(command, environment={}, **kwargs)
    monkeypatch.setattr(daemon, 'docker', docker)
    assert ci.main(['--run-ephemeral-ci']) == 1
    assert len(starts) == 1 and cleanup == ['enter','cleanup']
    assert sum(call[0] == 'create' for call in daemon.calls) == 1
    assert not any(call[0] in {'build','start','restart'} for call in daemon.calls)
    assert all(child.poll() is not None and child.stdout.closed for child in children)
    assert all(child.stderr is None or child.stderr.closed for child in children)
    output = capsys.readouterr()
    assert output.out == ''
    assert output.err == f'storage_characterization_failed phase=helper_base_start code={code}\n'
