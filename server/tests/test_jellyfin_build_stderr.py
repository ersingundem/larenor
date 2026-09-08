"""Classify bounded private build stderr, never export its contents."""
import importlib
import os
import signal
import subprocess
import sys
import time

import pytest

from test_jellyfin_storage_diagnostics import launched, protocol


@pytest.mark.parametrize('message,code', [
    (b'Error response from daemon: manifest unknown: private-registry/path', 'helper_build_manifest_missing'),
    (b'no matching manifest for linux/private in the manifest list entries', 'helper_build_platform_missing'),
    (b'toomanyrequests: private-account limit reached', 'helper_build_registry_limit'),
    (b'pull access denied for private-registry/path', 'helper_build_registry_auth'),
    (b'failed to create shim task: OCI runtime create failed: private-path', 'helper_build_runtime_failed'),
    (b'COPY failed: stat private-file: no such file or directory', 'helper_build_context_failed'),
    (b'x509: certificate signed by unknown authority: private-host', 'helper_build_tls_failed'),
    (b'lookup private-host: no such host', 'helper_build_dns_failed'),
    (b'write private-path: no space left on device', 'helper_build_storage_failed'),
    (b'The command private-command returned a non-zero code: 7', 'helper_build_step_failed'),
])
def test_real_build_exit_reports_only_closed_stderr_category(launched, monkeypatch, capsys, message, code):
    ci, daemon, events = launched
    original = daemon.docker
    builds = []
    def docker(args, **kwargs):
        if args[0] != 'build':
            return original(args, **kwargs)
        builds.append(args)
        program = 'import os,sys; os.write(2,'+repr(message)+'); sys.exit(1)'
        return ci.smoke.bounded_command([sys.executable, '-c', program], environment={}, **kwargs)
    monkeypatch.setattr(daemon, 'docker', docker)
    assert ci.main(['--run-ephemeral-ci']) == 1
    assert len(builds) == 1 and events == ['enter', 'cleanup']
    output = capsys.readouterr()
    assert output.out == ''
    assert output.err == f'storage_characterization_failed phase=helper_build code={code}\n'


def test_build_stderr_overflow_fails_closed_without_waiting_for_child(monkeypatch, capsys):
    import importlib
    smoke = importlib.import_module('tool.jellyfin_storage_smoke')
    child = None
    original = smoke.subprocess.Popen
    def spawn(*args, **kwargs):
        nonlocal child
        child = original(*args, **kwargs)
        return child
    monkeypatch.setattr(smoke.subprocess, 'Popen', spawn)
    with pytest.raises(smoke.SmokeError, match='^fixture_command_stderr_limit$'):
        smoke.bounded_command([sys.executable, '-c',
            'import os,time; os.write(2,b"private"*20000); time.sleep(30)'],
            environment={}, timeout=3, limit=256, diagnose_failure=True)
    assert child.poll() is not None and child.stdout.closed and child.stderr.closed
    assert capsys.readouterr().out == ''


def test_quiet_build_progress_can_precede_final_runtime_error(launched, monkeypatch, capsys):
    ci, daemon, events = launched
    original = daemon.docker
    def docker(args, **kwargs):
        if args[0] != 'build':
            return original(args, **kwargs)
        program = ('import os,sys; os.write(2,'+repr(b'synthetic-progress\n')+'*1800); '
                   'os.write(2,b"Error: OCI runtime create failed: synthetic-private-path"); sys.exit(1)')
        return ci.smoke.bounded_command([sys.executable, '-c', program], environment={}, **kwargs)
    monkeypatch.setattr(daemon, 'docker', docker)
    assert ci.main(['--run-ephemeral-ci']) == 1
    assert events == ['enter', 'cleanup']
    output = capsys.readouterr()
    assert output.out == ''
    assert output.err == ('storage_characterization_failed phase=helper_build '
                          'code=helper_build_runtime_failed\n')


@pytest.mark.parametrize('stderr,exit_code,expected', [
    (b'WARNING: The legacy builder is deprecated. private failure', 1, 'fixture_command_exit_failed'),
    (b'manifest unknown followed by x509: private details', 1, 'helper_build_error_ambiguous'),
    (b'\xff\xfeprivate-unrecognized-message', 1, 'fixture_command_exit_failed'),
    (b'Error response from daemon: manifest unknown private-path', 0, None),
    (b'x509: truncated private detail'+b'x'*65536, 1, 'fixture_command_stderr_limit'),
])
def test_only_nonzero_complete_bounded_diagnostics_are_classified(stderr, exit_code, expected, capsys):
    smoke = importlib.import_module('tool.jellyfin_storage_smoke')
    command = [sys.executable, '-c',
        'import os,sys; os.write(2,'+repr(stderr)+'); os.write(1,b"ok"); sys.exit('+str(exit_code)+')']
    if expected is None:
        assert smoke.bounded_command(command, environment={}, timeout=3, limit=256, diagnose_failure=True) == b'ok'
    else:
        with pytest.raises(smoke.SmokeError, match='^'+expected+'$'):
            smoke.bounded_command(command, environment={}, timeout=3, limit=256, diagnose_failure=True)
    output = capsys.readouterr()
    assert output.out == output.err == ''


def test_both_pipes_drain_at_exact_limits_and_close_on_success(monkeypatch):
    smoke = importlib.import_module('tool.jellyfin_storage_smoke')
    original = smoke.subprocess.Popen
    children = []
    def spawn(*args, **kwargs):
        child = original(*args, **kwargs)
        children.append(child)
        return child
    monkeypatch.setattr(smoke.subprocess, 'Popen', spawn)
    command = [sys.executable, '-c', 'import os,threading; '
        't=threading.Thread(target=lambda:os.write(2,b"p"*65536));t.start();os.write(1,b"x"*256);t.join()']
    assert smoke.bounded_command(command, environment={}, timeout=3, limit=256, diagnose_failure=True) == b'x'*256
    assert len(children) == 1 and children[0].returncode == 0
    assert children[0].stdout.closed and children[0].stderr.closed


def test_split_signature_is_joined_privately_before_classification():
    smoke = importlib.import_module('tool.jellyfin_storage_smoke')
    command = [sys.executable, '-c', 'import os,time,sys; os.write(2,b"OCI runtime ");'
        'time.sleep(0.02);os.write(2,b"create failed: private");sys.exit(1)']
    with pytest.raises(smoke.SmokeError, match='^helper_build_runtime_failed$'):
        smoke.bounded_command(command, environment={}, timeout=3, limit=256, diagnose_failure=True)


def test_stderr_inherited_by_descendant_cannot_bypass_deadline_or_group_cleanup(tmp_path):
    smoke = importlib.import_module('tool.jellyfin_storage_smoke')
    pidfile = tmp_path/'synthetic-child.pid'
    program = ('import subprocess,sys,pathlib; child=subprocess.Popen([sys.executable,"-c",'
        '"import time; time.sleep(30)"],stdout=subprocess.DEVNULL); '
        'pathlib.Path('+repr(str(pidfile))+').write_text(str(child.pid))')
    child = None
    try:
        with pytest.raises(smoke.SmokeError, match='^fixture_command_timeout$'):
            smoke.bounded_command([sys.executable, '-c', program],
                environment={}, timeout=0.25, limit=256, diagnose_failure=True)
        child = int(pidfile.read_text())
        deadline = time.monotonic()+1
        while time.monotonic() < deadline:
            state = subprocess.run(['/bin/ps', '-o', 'stat=', '-p', str(child)], capture_output=True, timeout=2)
            if state.returncode != 0 or state.stdout.strip().startswith(b'Z'):
                break
            time.sleep(0.02)
        else:
            pytest.fail('descendant retaining stderr survived owned group cleanup')
    finally:
        if child is None and pidfile.exists():
            child = int(pidfile.read_text())
        if child is not None:
            try:
                os.kill(child, signal.SIGKILL)
            except ProcessLookupError:
                pass
