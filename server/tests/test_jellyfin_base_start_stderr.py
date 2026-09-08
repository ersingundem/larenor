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


def command(smoke, program, **kwargs):
    return smoke.bounded_command([sys.executable,'-c',program],environment={},
        timeout=kwargs.pop('timeout',3),limit=128,diagnose_start=True,**kwargs)


@pytest.mark.parametrize('message,expected',[
    (b'', 'fixture_command_exit_failed'),
    (b'\xff\xfeunrecognized private path/url/token', 'fixture_command_exit_failed'),
    (b'Error response from daemon: synthetic-unrecognized', 'fixture_command_exit_failed'),
    (b'no such file or directory: synthetic-mount-source', 'fixture_command_exit_failed'),
    (b'failed to create task for container: synthetic', 'helper_base_runtime_failed'),
    (b'OCI runtime create failed: executable file not found in $PATH: synthetic', 'helper_base_exec_failed'),
    (b'runc create failed: read-only file system: synthetic', 'helper_base_storage_failed'),
    (b'error during connect: synthetic', 'helper_base_daemon_unavailable'),
],ids=['empty','unknown-bytes','generic-daemon','bare-enoent','runtime-wrapper','runtime-exec','runtime-storage','connect'])
def test_unknown_or_wrapped_stderr_is_only_a_closed_signature(message,expected,capsys):
    smoke=importlib.import_module('tool.jellyfin_storage_smoke')
    with pytest.raises(smoke.SmokeError,match='^'+expected+'$'):
        command(smoke,'import os,sys;os.write(2,'+repr(message)+');sys.exit(17)')
    assert capsys.readouterr()==('','')


@pytest.mark.parametrize('stdout_count,stderr_count,expected',[
    (128,65536,None),(129,65536,'fixture_command_output_limit'),(128,65537,'fixture_command_stderr_limit'),
],ids=['exact-both','stdout-plus-one','stderr-plus-one'])
def test_exact_concurrent_pipe_bounds_and_success_never_classifies(
        stdout_count,stderr_count,expected,monkeypatch,capsys):
    smoke=importlib.import_module('tool.jellyfin_storage_smoke')
    original=smoke.subprocess.Popen;children=[]
    def spawn(*args,**kwargs):
        assert kwargs['stderr'] is smoke.subprocess.PIPE
        child=original(*args,**kwargs);children.append(child);return child
    monkeypatch.setattr(smoke.subprocess,'Popen',spawn)
    monkeypatch.setattr(smoke,'_start_error',lambda _:pytest.fail('classified success or incomplete output'))
    program=('import os,threading; t=threading.Thread(target=lambda:os.write(2,b"permission denied"+'
        f'b"x"*{stderr_count-17}));t.start();os.write(1,b"x"*{stdout_count});t.join()')
    if expected:
        with pytest.raises(smoke.SmokeError,match='^'+expected+'$'):
            command(smoke,program)
    else: assert command(smoke,program)==b'x'*128
    assert len(children)==1 and children[0].poll() is not None
    assert children[0].stdout.closed and children[0].stderr.closed
    assert capsys.readouterr()==('','')


def test_split_signature_and_bounded_leading_diagnostics_are_private():
    smoke=importlib.import_module('tool.jellyfin_storage_smoke')
    program=('import os,time,sys;os.write(2,b"private-leading\\n"*1800);'
        'os.write(2,b"OCI runtime create failed: permission ");time.sleep(0.02);'
        'os.write(2,b"denied: private-token /private/path");sys.exit(1)')
    with pytest.raises(smoke.SmokeError,match='^helper_base_permission_failed$'):
        command(smoke,program)


@pytest.mark.parametrize('flag',[None,0,1,'true'])
def test_start_selector_is_literal_before_any_spawn(flag,monkeypatch):
    smoke=importlib.import_module('tool.jellyfin_storage_smoke')
    monkeypatch.setattr(smoke.subprocess,'Popen',lambda *a,**kw:pytest.fail('invalid flag spawned'))
    with pytest.raises(smoke.SmokeError,match='^fixture_command_failed$'):
        smoke.bounded_command(['unused'],environment={},diagnose_start=flag)


def test_start_and_build_selectors_cannot_be_mixed(monkeypatch):
    smoke=importlib.import_module('tool.jellyfin_storage_smoke')
    monkeypatch.setattr(smoke.subprocess,'Popen',lambda *a,**kw:pytest.fail('mixed classifiers spawned'))
    with pytest.raises(smoke.SmokeError,match='^fixture_command_failed$'):
        command(smoke,'unused',diagnose_failure=True)


def test_stderr_read_failure_is_closed_and_child_is_reaped(monkeypatch,capsys):
    smoke=importlib.import_module('tool.jellyfin_storage_smoke')
    original_spawn,original_read=smoke.subprocess.Popen,smoke.os.read
    children=[]
    def spawn(*a,**kw):
        child=original_spawn(*a,**kw);children.append(child);return child
    def read(fd,*args):
        if any(not p.stderr.closed and p.stderr.fileno()==fd for p in children):
            raise OSError('private stderr/path/token')
        return original_read(fd,*args)
    monkeypatch.setattr(smoke.subprocess,'Popen',spawn);monkeypatch.setattr(smoke.os,'read',read)
    with pytest.raises(smoke.SmokeError,match='^fixture_command_io_failed$'):
        command(smoke,'import os,time;os.write(2,b"private");time.sleep(30)')
    assert len(children)==1 and children[0].poll() is not None
    assert children[0].stdout.closed and children[0].stderr.closed
    assert capsys.readouterr()==('','')


def test_closed_pipes_do_not_reset_original_deadline(monkeypatch):
    smoke=importlib.import_module('tool.jellyfin_storage_smoke')
    original=smoke.subprocess.Popen;children=[]
    def spawn(*args,**kwargs):
        child=original(*args,**kwargs);children.append(child);return child
    monkeypatch.setattr(smoke.subprocess,'Popen',spawn)
    with pytest.raises(smoke.SmokeError,match='^fixture_command_timeout$'):
        command(smoke,'import os,time;os.close(1);os.close(2);time.sleep(30)',timeout=0.15)
    assert len(children)==1 and children[0].poll() is not None
    assert children[0].stdout.closed and children[0].stderr.closed


def test_current_consumer_alone_opts_into_start_stderr_and_preserves_receipt(protocol,monkeypatch):
    smoke,source,daemon,images=protocol;original=daemon.docker;selected=[]
    def docker(args,**kwargs):
        if kwargs.get('diagnose_start') is True:
            selected.append(list(args))
            assert kwargs['timeout']==20 and kwargs['limit']==128
            assert kwargs.get('diagnose_failure',False) is False
        return original(args,**kwargs)
    monkeypatch.setattr(daemon,'docker',docker)
    result=smoke.characterize(daemon,source=source,images=images,volumes=object())
    assert selected==[['start','--attach','d'*64]]
    assert result['result']=='characterized' and result['installAvailable'] is False


def test_start_forwarding_keeps_owned_socket_empty_config_and_environment(tmp_path,monkeypatch):
    smoke=importlib.import_module('tool.jellyfin_storage_smoke')
    daemon=smoke.EphemeralDaemon();daemon.root=tmp_path;events=[]
    monkeypatch.setattr(daemon,'_socket',lambda:events.append('owned-socket'))
    def bounded(args,**kwargs):
        assert events==['owned-socket']
        assert args==['/usr/bin/docker','--host=unix://'+str(tmp_path/'engine.sock'),
            '--config='+str(tmp_path/'docker-config'),'start','--attach','d'*64]
        assert kwargs=={'environment':smoke.child_environment(tmp_path),'timeout':20,'limit':128,
            'diagnose_process':True,'diagnose_start':True,'diagnose_failure':False}
        return b'larenor-helper-base-ok-v1\n'
    monkeypatch.setattr(smoke,'bounded_command',bounded)
    assert daemon.docker(['start','--attach','d'*64],timeout=20,limit=128,
        diagnose_process=True,diagnose_start=True)==b'larenor-helper-base-ok-v1\n'


def test_descendant_holding_only_stderr_is_killed_after_total_deadline(tmp_path):
    import os
    import signal
    import subprocess
    import time
    smoke=importlib.import_module('tool.jellyfin_storage_smoke')
    pidfile=tmp_path/'owned-child.pid'
    program=('import subprocess,sys,pathlib;child=subprocess.Popen([sys.executable,"-c",'
        '"import time;time.sleep(30)"],stdout=subprocess.DEVNULL);'
        'pathlib.Path('+repr(str(pidfile))+').write_text(str(child.pid))')
    child=None
    try:
        with pytest.raises(smoke.SmokeError,match='^fixture_command_timeout$'):
            command(smoke,program,timeout=0.5)
        child=int(pidfile.read_text())
        deadline=time.monotonic()+2
        while time.monotonic()<deadline:
            result=subprocess.run(['/bin/ps','-o','stat=','-p',str(child)],capture_output=True,timeout=2)
            if result.returncode!=0 or result.stdout.strip().startswith(b'Z'): break
            time.sleep(0.02)
        else: pytest.fail('owned stderr descendant survived group cleanup')
    finally:
        if child is None and pidfile.exists(): child=int(pidfile.read_text())
        if child is not None:
            try: os.kill(child,signal.SIGKILL)
            except ProcessLookupError: pass
