"""Private attached-base diagnostics with real children, never real Docker."""
import importlib
import sys

import pytest
from test_jellyfin_storage_diagnostics import launched, protocol


@pytest.mark.parametrize('message,code', [
    (b'failed to create shim task: OCI runtime create failed: synthetic-private', 'helper_base_runtime_failed'),
    (b'exec /usr/local/bin/python: exec format error', 'helper_base_exec_failed'),
    (b'operation not permitted: synthetic-private-path', 'helper_base_permission_failed'),
    (b'write synthetic-private-path: no space left on device', 'helper_base_storage_failed'),
    (b'Cannot connect to the Docker daemon at unix:///synthetic/private.sock. Is the docker daemon running?', 'helper_base_daemon_unavailable'),
    (b'Error response from daemon: No such container: synthetic-private-id', 'helper_base_container_missing'),
    (b'OCI runtime create failed: synthetic-path: permission denied', 'helper_base_permission_failed'),
    (b'permission denied; no space left on device: synthetic-private', 'helper_base_error_ambiguous'),
    (b'Error waiting for container: synthetic-private-failure', 'helper_base_wait_failed'),
    (b'private-token /private/path https://private.invalid '+b'x'*65536, 'fixture_command_stderr_limit'),
], ids=['runtime','exec','permission','storage','daemon','missing','runtime-permission','ambiguous','wait','stderr-overflow'])
def test_base_start_complete_failure_has_only_closed_private_signature(
        launched, monkeypatch, capsys, message, code):
    ci,daemon,events=launched
    original,spawn=daemon.docker,ci.smoke.subprocess.Popen
    starts,children=[],[]
    def track(*args,**kwargs):
        child=spawn(*args,**kwargs);children.append(child);return child
    monkeypatch.setattr(ci.smoke.subprocess,'Popen',track)
    def docker(args,**kwargs):
        if args != ['start','--attach','d'*64]:
            return original(args,**kwargs)
        starts.append(list(args))
        assert kwargs['timeout']==20 and kwargs['limit']==128
        kwargs['timeout']=3
        program='import os,sys;os.write(2,'+repr(message)+');os.write(1,b"private-stdout");sys.exit(1)'
        return ci.smoke.bounded_command([sys.executable,'-c',program],environment={},**kwargs)
    monkeypatch.setattr(daemon,'docker',docker)
    assert ci.main(['--run-ephemeral-ci'])==1
    assert starts==[['start','--attach','d'*64]] and events==['enter','cleanup']
    assert not any(call[0] in {'build','restart'} for call in daemon.calls)
    assert len(children)==1 and children[0].poll() is not None
    assert children[0].stdout.closed and (children[0].stderr is None or children[0].stderr.closed)
    output=capsys.readouterr()
    assert output.out==''
    assert output.err==f'storage_characterization_failed phase=helper_base_start code={code}\n'
