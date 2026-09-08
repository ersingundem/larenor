"""Classify bounded private build stderr, never export its contents."""
import sys

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
