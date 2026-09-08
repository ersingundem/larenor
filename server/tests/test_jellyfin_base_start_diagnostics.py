"""Real child failure causes at the attached-base-start boundary, no Docker."""
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
def test_attached_start_distinguishes_child_failures_without_replay_or_disclosure(
        launched, monkeypatch, tmp_path, capsys, fault, code):
    ci, daemon, cleanup = launched
    smoke = ci.smoke
    original_docker, original_spawn = daemon.docker, smoke.subprocess.Popen
    children, starts = [], []
    def spawn(*args, **kwargs):
        assert kwargs['stderr'] is smoke.subprocess.PIPE
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


@pytest.mark.parametrize('value', [1, 0, 'true', None])
def test_process_diagnostic_selector_is_strict_before_any_spawn(monkeypatch, value):
    smoke = importlib.import_module('tool.jellyfin_storage_smoke')
    monkeypatch.setattr(smoke.subprocess, 'Popen', lambda *a, **kw: pytest.fail('invalid flag spawned'))
    with pytest.raises(smoke.SmokeError, match='^fixture_command_failed$'):
        smoke.bounded_command(['unused'], environment={}, diagnose_process=value)


@pytest.mark.parametrize('count', [128,129])
def test_process_diagnostics_preserve_exact_stdout_bound_and_discard_large_stderr(count, monkeypatch):
    smoke = importlib.import_module('tool.jellyfin_storage_smoke')
    original = smoke.subprocess.Popen
    children = []
    def spawn(*args, **kwargs):
        assert kwargs['stderr'] is smoke.subprocess.DEVNULL
        child = original(*args, **kwargs)
        children.append(child)
        return child
    monkeypatch.setattr(smoke.subprocess, 'Popen', spawn)
    program = ('import os; os.write(2,b"OCI runtime create failed: synthetic-private"*65536); '
               f'os.write(1,b"x"*{count})')
    def invoke():
        return smoke.bounded_command([sys.executable,'-c',program], environment={},
            diagnose_process=True, timeout=3, limit=128)
    if count == 128:
        assert invoke() == b'x'*128
    else:
        with pytest.raises(smoke.SmokeError, match='^fixture_command_output_limit$'):
            invoke()
    assert len(children) == 1 and children[0].poll() is not None
    assert children[0].stdout.closed and children[0].stderr is None


def test_nonzero_process_diagnostics_never_invoke_build_error_classifier(monkeypatch, capsys):
    smoke = importlib.import_module('tool.jellyfin_storage_smoke')
    monkeypatch.setattr(smoke, '_build_error', lambda _: pytest.fail('process-only entered stderr classifier'))
    with pytest.raises(smoke.SmokeError, match='^fixture_command_exit_failed$'):
        smoke.bounded_command([sys.executable,'-c',
            'import os,sys;os.write(2,b"OCI runtime create failed: synthetic-private");sys.exit(17)'],
            environment={}, timeout=3, limit=128, diagnose_process=True)
    assert capsys.readouterr() == ('','')


def test_process_timeout_after_stdout_eof_is_still_bounded(monkeypatch):
    smoke = importlib.import_module('tool.jellyfin_storage_smoke')
    original = smoke.subprocess.Popen
    children = []
    def spawn(*args, **kwargs):
        child = original(*args, **kwargs)
        children.append(child)
        return child
    monkeypatch.setattr(smoke.subprocess, 'Popen', spawn)
    with pytest.raises(smoke.SmokeError, match='^fixture_command_timeout$'):
        smoke.bounded_command([sys.executable,'-c','import os,time;os.close(1);time.sleep(30)'],
            environment={}, timeout=0.15, limit=128, diagnose_process=True)
    assert len(children) == 1 and children[0].poll() is not None
    assert children[0].stdout.closed and children[0].stderr is None


def test_current_consumer_opts_only_attached_base_start_into_process_codes(protocol, monkeypatch):
    smoke, source, daemon, images = protocol
    original = daemon.docker
    process_calls, build_calls = [], []
    def docker(args, **kwargs):
        if kwargs.get('diagnose_process') is True:
            process_calls.append(list(args))
            assert kwargs.get('diagnose_failure',False) is False
            assert kwargs.get('diagnose_start') is True
            assert kwargs['timeout'] == 20 and kwargs['limit'] == 128
        if kwargs.get('diagnose_failure') is True:
            build_calls.append(list(args))
            assert kwargs.get('diagnose_process',False) is False
        return original(args, **kwargs)
    monkeypatch.setattr(daemon,'docker',docker)
    result = smoke.characterize(daemon, source=source, images=images, volumes=object())
    assert result['result'] == 'characterized' and result['installAvailable'] is False
    assert process_calls == [['start','--attach','d'*64]]
    assert len(build_calls) == 1 and build_calls[0][0] == 'build'


def test_owned_socket_environment_and_process_option_are_forwarded_exactly(tmp_path, monkeypatch):
    smoke = importlib.import_module('tool.jellyfin_storage_smoke')
    owner = smoke.EphemeralDaemon()
    owner.root = tmp_path
    events = []
    monkeypatch.setattr(owner,'_socket',lambda:events.append('owned-socket'))
    def command(args, **kwargs):
        assert events == ['owned-socket']
        assert args == ['/usr/bin/docker','--host=unix://'+str(tmp_path/'engine.sock'),
            '--config='+str(tmp_path/'docker-config'),'start','--attach','d'*64]
        assert kwargs == {'environment':smoke.child_environment(tmp_path),
            'timeout':20,'limit':128,'diagnose_failure':False,'diagnose_process':True,'diagnose_start':False}
        return b'larenor-helper-base-ok-v1\n'
    monkeypatch.setattr(smoke,'bounded_command',command)
    assert owner.docker(['start','--attach','d'*64], timeout=20, limit=128, diagnose_process=True) == b'larenor-helper-base-ok-v1\n'
