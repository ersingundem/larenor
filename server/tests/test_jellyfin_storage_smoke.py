"""Offline fixture boundary tests; never instantiate a real daemon."""
import importlib
import importlib.util
import copy
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import shutil
import subprocess
import time
from types import SimpleNamespace

import pytest

# The Server CI runs from server/; load only this checkout's offline tool code.
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))


def api():
    name = 'tool.jellyfin_storage_smoke'
    assert importlib.util.find_spec(name) is not None, 'owned-daemon storage fixture is absent'
    return importlib.import_module(name)


@pytest.mark.parametrize('env,system,machine,uid', [
    ({}, 'Linux', 'x86_64', 0),
    ({'CI': 'true'}, 'Linux', 'x86_64', 0),
    ({'CI': 'true', 'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'self-hosted', 'RUNNER_ARCH': 'X64', 'GITHUB_SHA': 'a'*40}, 'Linux', 'x86_64', 0),
    ({'CI': 'true', 'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'github-hosted', 'RUNNER_ARCH': 'X64', 'GITHUB_SHA': 'a'*40}, 'Darwin', 'arm64', 0),
    ({'CI': 'true', 'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'github-hosted', 'RUNNER_ARCH': 'X64', 'GITHUB_SHA': 'a'*40}, 'Linux', 'aarch64', 0),
    ({'CI': 'true', 'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'github-hosted', 'RUNNER_ARCH': 'X64', 'GITHUB_SHA': 'a'*40}, 'Linux', 'x86_64', 1000),
])
def test_native_ci_guard_before_process_or_files(env, system, machine, uid, monkeypatch):
    m = api()
    monkeypatch.setattr(m.tempfile, 'mkdtemp', lambda **_: pytest.fail('guard created directory'))
    monkeypatch.setattr(m.subprocess, 'Popen', lambda *a, **k: pytest.fail('guard created process'))
    with pytest.raises(m.SmokeError, match='^native_ephemeral_ci_required$'):
        m.native_platform(env, system, machine, uid)


@pytest.mark.parametrize('machine,arch,expected', [('x86_64','X64','linux/amd64'), ('aarch64','ARM64','linux/arm64')])
def test_native_architecture_is_not_qemu_or_caller_selected(machine, arch, expected):
    m = api()
    env = {'CI':'true','GITHUB_ACTIONS':'true','RUNNER_ENVIRONMENT':'github-hosted',
           'RUNNER_ARCH':arch,'GITHUB_SHA':'a'*40}
    assert m.native_platform(env, 'Linux', machine, 0) == expected


@pytest.mark.parametrize('args', [[], ['--socket', '/var/run/docker.sock'], ['--run-ephemeral-ci', '--platform', 'linux/arm64']])
def test_cli_has_no_external_socket_or_platform_input(args, monkeypatch, capsys):
    m = api()
    monkeypatch.setattr(m, 'EphemeralDaemon', lambda: pytest.fail('invalid CLI starts daemon'))
    assert m.main(args) == 2
    assert capsys.readouterr().err == 'explicit_ephemeral_ci_flag_required\n'


@pytest.mark.parametrize('platform', ['linux/amd64','linux/arm64'])
def test_source_uses_real_pinned_plans_and_exact_jellyfin_resources(platform):
    m = api()
    source = m.fixture_source(platform)
    assert source.stack.installAvailable is False and source.volumes.installAvailable is False
    assert len(source.plan.resources) == 13 and len(source.volumes.resources) == 8
    assert source.image.serviceId == 'jellyfin'
    assert source.image.image.platform == platform
    assert source.image.image.reference.endswith('@'+source.image.image.digest)
    assert {v.target for v in source.targets} == {'/config','/cache'}
    assert all(v.containerUser == '1000:1000' and v.noCopy is True for v in source.targets)
    assert len({v.name for v in source.targets}) == 2
    assert {v.target for v in source.managed_targets} == {'/config','/cache','/media'}
    media = next(v for v in source.managed_targets if v.target == '/media')
    assert media.kind == 'managed_library' and media.readOnly is True


def test_preparation_consumes_actual_sqlite_image_volume_journals(tmp_path):
    m = api()
    from larenor_server.plugins.image_resources import ImageObservation
    from larenor_server.plugins.volume_effects import VolumeAbsent, VolumeCreateAcknowledgement, _inputs
    from larenor_server.plugins.volume_resources import VolumeObservation
    from larenor_server.plugins.resource_journal import _digest
    source = m.fixture_source('linux/amd64')
    events = []
    class Images:
        present = False
        def inspect(self, binding, *, cancelled=None):
            events.append('image_get')
            return ImageObservation(binding.config_digest, b'{}') if self.present else None
        def pull(self, binding, *, cancelled=None):
            events.append('image_pull')
            self.present = True
    class Volumes:
        present = set()
        def probe(self, intent, *, cancelled=None):
            rid = intent.binding.resource_id
            events.append(('volume_get', rid, intent.receipt.state))
            digest = _digest(_inputs(intent)[1])
            return (VolumeObservation(rid, intent.binding.resource.name, source.volumes.planHash, digest)
                if rid in self.present else VolumeAbsent(rid, digest))
        def create(self, intent, *, cancelled=None, before_dispatch=None):
            assert before_dispatch() is True
            events.append(('volume_post', intent.binding.resource_id, intent.receipt.state))
            self.present.add(intent.binding.resource_id)
            return VolumeCreateAcknowledgement(intent.binding.resource_id, _digest(_inputs(intent)[1]))
    images, volumes = Images(), Volumes()
    result = m.prepare_storage(tmp_path, source, images, volumes)
    assert result['imageState'] == 'ready'
    assert result['volumeStates'] == ['observed_requires_bootstrap']*2
    assert events[:4] == ['image_get','image_pull','image_get', ('volume_get',source.targets[0].resourceId,'mutating')]
    assert len([e for e in events if isinstance(e,tuple) and e[0]=='volume_post']) == 2
    before = list(events)
    assert m.prepare_storage(tmp_path, source, images, volumes) == result
    assert events == before, 'terminal receipts must not cause fresh CREATE/PULL'


def test_bounded_process_never_inherits_docker_or_proxy_configuration(monkeypatch, tmp_path):
    m = api()
    monkeypatch.setenv('DOCKER_HOST','unix:///var/run/docker.sock')
    monkeypatch.setenv('HTTP_PROXY','http://synthetic-private')
    output = m.bounded_command([sys.executable,'-c','import os,json; print(json.dumps(dict(os.environ)))'],
        environment=m.child_environment(tmp_path), timeout=3, limit=16384)
    env = json.loads(output)
    assert 'DOCKER_HOST' not in env and 'HTTP_PROXY' not in env
    assert env['DOCKER_CONFIG'] == str(tmp_path/'docker-config')


@pytest.mark.parametrize('program,limit,timeout', [
    ('import sys;sys.stdout.write("x"*10000)',32,3),
    ('import time;time.sleep(30)',32,0.05),
    ('import sys;print("synthetic-private");sys.exit(1)',128,3),
])
def test_command_limit_timeout_and_error_are_static_and_reaped(program, limit, timeout):
    m = api()
    with pytest.raises(m.SmokeError, match='^fixture_command_failed$'):
        m.bounded_command([sys.executable,'-c',program], environment={}, limit=limit, timeout=timeout)


def test_owned_daemon_command_disables_default_bridge_and_external_config(tmp_path):
    m = api()
    root = tmp_path/'larenor-jellyfin-testnonce'
    root.mkdir(mode=0o700)
    args = m.daemon_command(root)
    unit = 'larenor-jellyfin-testnonce.service'
    cgroup = '/system.slice/'+unit
    assert args[:4] == ['/usr/bin/systemd-run','--quiet','--no-ask-password','--collect']
    assert '--unit='+unit in args and '--property=Type=exec' in args
    assert '--property=Delegate=yes' in args and '--property=DelegateSubgroup=daemon' in args
    assert '--property=KillMode=control-group' in args and '--property=SendSIGKILL=yes' in args
    assert '--property=RuntimeMaxSec=1200s' in args and '--property=TimeoutStopSec=15s' in args
    assert '/usr/bin/env' in args and '-i' in args
    unshare = args.index('/usr/bin/unshare')
    assert args[unshare:unshare+3] == ['/usr/bin/unshare','--mount','--propagation=private']
    assert not any(arg in args for arg in ('--pid','--fork','--kill-child=SIGKILL','--mount-proc'))
    assert '--exec-opt=native.cgroupdriver=cgroupfs' in args
    assert '--cgroup-parent='+cgroup+'/containers' in args
    assert '--host=unix://'+str(root/'engine.sock') in args
    assert '--data-root='+str(root/'data') in args
    assert '--exec-root='+str(root/'exec') in args
    assert '--config-file='+str(root/'daemon.json') in args
    assert '--bridge=none' in args and '--iptables=false' in args and '--ip-forward=false' in args
    assert not any('/var/run/' in arg or '/var/lib/docker' in arg for arg in args)


def test_owned_daemon_unit_rejects_non_fixture_or_ambiguous_names(tmp_path):
    m = api()
    assert m.daemon_unit(tmp_path/'larenor-jellyfin-a1b2c3') == 'larenor-jellyfin-a1b2c3.service'
    assert m.daemon_unit(tmp_path/'larenor-jellyfin-a1_b2-c3') == 'larenor-jellyfin-a1_b2-c3.service'
    for name in ('owned','larenor-jellyfin-a/b','larenor-jellyfin-a.service','larenor-jellyfin-A'):
        with pytest.raises(m.SmokeError, match='^owned_daemon_scope_invalid$'):
            m.daemon_unit(tmp_path/name)


def _unit_state(m, root, **changes):
    values = {'Id':m.daemon_unit(root),'LoadState':'loaded','ActiveState':'active',
        'SubState':'running','Transient':'yes','InvocationID':'a'*32,
        'ControlGroup':'/system.slice/'+m.daemon_unit(root),'MainPID':'12345',
        'KillMode':'control-group','Delegate':'yes','DelegateSubgroup':'daemon'}
    values.update(changes)
    return b''.join(key.encode()+b'='+values[key].encode()+b'\n' for key in m._UNIT_PROPERTIES)


def test_owned_unit_state_requires_exact_transient_cgroup_identity(tmp_path):
    m = api()
    root = tmp_path/'larenor-jellyfin-testnonce'
    values = m._unit_properties(_unit_state(m,root),root)
    assert values['InvocationID'] == 'a'*32 and values['MainPID'] == '12345'


@pytest.mark.parametrize('changes', [
    {'Id':'foreign.service'}, {'LoadState':'not-found'}, {'ActiveState':'inactive'},
    {'SubState':'exited'}, {'Transient':'no'}, {'InvocationID':'not-an-id'},
    {'ControlGroup':'/system.slice/foreign.service'}, {'MainPID':'0'},
    {'KillMode':'process'}, {'Delegate':'no'}, {'DelegateSubgroup':'containers'},
])
def test_owned_unit_state_rejects_changed_or_weakened_properties(tmp_path, changes):
    m = api()
    root = tmp_path/'larenor-jellyfin-testnonce'
    with pytest.raises(m.SmokeError, match='^owned_daemon_lost$'):
        m._unit_properties(_unit_state(m,root,**changes),root)


def test_owned_unit_state_rejects_duplicate_or_extra_properties(tmp_path):
    m = api()
    root = tmp_path/'larenor-jellyfin-testnonce'
    valid = _unit_state(m,root)
    for raw in (valid+b'Id='+m.daemon_unit(root).encode()+b'\n', valid+b'Unknown=value\n',
                b'Id=\xff\n'):
        with pytest.raises(m.SmokeError, match='^owned_daemon_lost$'):
            m._unit_properties(raw,root)


@pytest.mark.parametrize('initial,accepted', [(b'populated 1\nfrozen 0\n',True),
                                               (b'populated 0\nfrozen 0\n',False)])
def test_unit_capture_pins_live_cgroup_control_files_before_ownership(monkeypatch, tmp_path,
                                                                     initial, accepted):
    m = api()
    root = tmp_path/'larenor-jellyfin-testnonce'
    owner = m.EphemeralDaemon()
    owner.root = root
    owner._unit_output = lambda *properties:_unit_state(m,root)
    monkeypatch.setattr(m,'_bounded_file',lambda path:
        b'0::/system.slice/larenor-jellyfin-testnonce.service/daemon\n')
    opened = iter((99,100,101,102))
    monkeypatch.setattr(m.os,'open',lambda *args,**kwargs:next(opened))
    monkeypatch.setattr(m.os,'fstat',lambda fd:SimpleNamespace(st_mode=stat.S_IFDIR,
        st_dev=7,st_ino=11))
    monkeypatch.setattr(m.os,'pread',lambda fd,size,offset:initial)
    closed = []
    monkeypatch.setattr(m.os,'close',closed.append)
    if accepted:
        owner._capture_unit()
        assert owner.cgroup_fd == 99 and owner.cgroup_kill_fd == 100
        assert owner.cgroup_events_fd == 101 and owner.cgroup_live_observed is True
        assert closed == [102]
    else:
        with pytest.raises(m.SmokeError, match='^owned_daemon_lost$'):
            owner._capture_unit()
        assert closed == [101,100,99]
        assert owner.cgroup_fd is None and owner.unit_identity is None


def test_unit_replacement_during_capture_closes_every_temporary_fd_without_kill(monkeypatch,
                                                                                tmp_path):
    m = api()
    root = tmp_path/'larenor-jellyfin-testnonce'
    owner = m.EphemeralDaemon()
    owner.root = root
    states = iter((_unit_state(m,root), _unit_state(m,root,InvocationID='b'*32)))
    owner._unit_output = lambda *properties:next(states)
    monkeypatch.setattr(m,'_bounded_file',lambda path:
        b'0::/system.slice/larenor-jellyfin-testnonce.service/daemon\n')
    opened = iter((99,100,101))
    monkeypatch.setattr(m.os,'open',lambda *args,**kwargs:next(opened))
    monkeypatch.setattr(m.os,'fstat',lambda fd:SimpleNamespace(st_mode=stat.S_IFDIR,
        st_dev=7,st_ino=11))
    monkeypatch.setattr(m.os,'pread',lambda fd,size,offset:b'populated 1\nfrozen 0\n')
    closed = []
    monkeypatch.setattr(m.os,'close',closed.append)
    monkeypatch.setattr(m.os,'write',lambda *args:pytest.fail('foreign cgroup was killed'))
    with pytest.raises(m.SmokeError, match='^owned_daemon_lost$'):
        owner._capture_unit()
    assert closed == [101,100,99]
    assert owner.cgroup_fd is None and owner.cgroup_kill_fd is None


@pytest.mark.parametrize('raw,expected', [
    (b'populated 1\nfrozen 0\n', True),
    (b'frozen 0\npopulated 0\n', False),
])
def test_cgroup_events_requires_one_bounded_populated_field(raw, expected):
    m = api()
    assert m._cgroup_populated(raw) is expected


@pytest.mark.parametrize('raw', [b'', b'populated 2\n', b'populated\n',
    b'populated 0\npopulated 1\n', b'populated 0\nbad\n', b'x '*4097])
def test_cgroup_events_rejects_missing_duplicate_malformed_or_oversize_state(raw):
    m = api()
    with pytest.raises(m.SmokeError, match='^owned_cleanup_failed$'):
        m._cgroup_populated(raw)


def test_authenticated_removed_cgroup_is_empty_only_after_owned_termination(monkeypatch):
    import errno
    m = api()
    owner = m.EphemeralDaemon()
    owner.cgroup_events_fd = 101
    owner.cgroup_live_observed = True
    monkeypatch.setattr(m.os,'pread',lambda *args:(_ for _ in ()).throw(OSError(errno.ENODEV,'retired')))
    assert owner._wait_cgroup_empty(retirement_allowed=True) is None
    with pytest.raises(m.SmokeError, match='^owned_cleanup_failed$'):
        owner._wait_cgroup_empty(retirement_allowed=False)


@pytest.mark.parametrize('error', [2,5,9,13])
def test_cgroup_event_io_errors_are_never_empty(monkeypatch, error):
    m = api()
    owner = m.EphemeralDaemon()
    owner.cgroup_events_fd = 101
    owner.cgroup_live_observed = True
    monkeypatch.setattr(m.os,'pread',lambda *args:(_ for _ in ()).throw(OSError(error,'private')))
    with pytest.raises(m.SmokeError, match='^owned_cleanup_failed$'):
        owner._wait_cgroup_empty(retirement_allowed=True)


def test_helper_attestation_uses_actual_build_id_not_a_fabricated_manifest(tmp_path):
    m = api()
    inspected = {'Id':'sha256:'+'f'*64,'Os':'linux','Architecture':'amd64', 'RepoDigests':[]}
    inspected['Config'] = {'Labels':m.source_labels('a'*40,m.source_hashes())}
    value = m.helper_attestation('sha256:'+'f'*64, inspected, 'linux/amd64', 'a'*40)
    assert value['configDigest'] == inspected['Id'] and value['publishedManifestDigest'] is None
    assert value['sourceCommit'] == 'a'*40 and len(value['helperSourceSha256']) == 64
    with pytest.raises(m.SmokeError):
        m.helper_attestation('sha256:'+'e'*64, inspected, 'linux/amd64', 'a'*40)


def test_replaced_socket_fails_before_any_cli_dispatch(tmp_path):
    m = api()
    daemon = m.EphemeralDaemon()
    daemon.root = tmp_path
    daemon.unit_identity = ('a'*32,'/system.slice/larenor-jellyfin-test.service','12345')
    daemon._check_unit = lambda: None
    daemon.socket_identity = (1,2)
    (tmp_path/'engine.sock').write_text('wrong object')
    with pytest.raises(m.SmokeError, match='^owned_daemon_lost$'):
        daemon.docker(['info'])


@pytest.mark.parametrize('state', [
    b'0::/system.slice/larenor-jellyfin-test.service/containers/docker/abc\n',
    b'0::/system.slice/larenor-jellyfin-test.service/containers/abc\n',
])
def test_running_container_pid_must_be_inside_owned_container_cgroup(monkeypatch, state):
    m = api()
    daemon = m.EphemeralDaemon()
    daemon.container_cgroup_parent = '/system.slice/larenor-jellyfin-test.service/containers'
    monkeypatch.setattr(m, '_bounded_file', lambda path: state)
    assert daemon.verify_container_cgroup(4242) is None


def test_managed_container_limits_are_read_from_its_owned_cgroup(monkeypatch, tmp_path):
    m = api()
    daemon = m.EphemeralDaemon()
    monkeypatch.setattr(daemon, '_container_cgroup_path', lambda pid: tmp_path)
    (tmp_path/'memory.max').write_bytes(b'4294967296\n')
    (tmp_path/'cpu.max').write_bytes(b'200000 100000\n')
    (tmp_path/'pids.max').write_bytes(b'512\n')
    assert daemon.verify_container_resources(4242, 4294967296, 2000000000, 512) is None


@pytest.mark.parametrize('name,value', [
    ('memory.max', b'max\n'), ('memory.max', b'4294967295\n'),
    ('cpu.max', b'max 100000\n'), ('cpu.max', b'199999 100000\n'),
    ('pids.max', b'max\n'), ('pids.max', b'511\n'),
])
def test_managed_container_rejects_missing_or_weakened_cgroup_limits(
        monkeypatch, tmp_path, name, value):
    m = api()
    daemon = m.EphemeralDaemon()
    monkeypatch.setattr(daemon, '_container_cgroup_path', lambda pid: tmp_path)
    values = {'memory.max': b'4294967296\n', 'cpu.max': b'200000 100000\n',
              'pids.max': b'512\n'}
    values[name] = value
    for filename, contents in values.items():
        (tmp_path/filename).write_bytes(contents)
    with pytest.raises(m.SmokeError, match='^managed_resource_limits_unverified$'):
        daemon.verify_container_resources(4242, 4294967296, 2000000000, 512)


@pytest.mark.parametrize('pid,state', [(0,b'0::/x\n'), (4242,b'0::/system.slice/foreign.service\n'),
    (4242,b'0::/system.slice/larenor-jellyfin-test.service/containers2/abc\n')])
def test_running_container_pid_rejects_invalid_or_escaped_cgroup(monkeypatch, pid, state):
    m = api()
    daemon = m.EphemeralDaemon()
    daemon.container_cgroup_parent = '/system.slice/larenor-jellyfin-test.service/containers'
    monkeypatch.setattr(m, '_bounded_file', lambda path: state)
    with pytest.raises(m.SmokeError, match='^owned_daemon_lost$'):
        daemon.verify_container_cgroup(pid)


def test_docker_mutations_require_one_exact_owned_cgroup_parent(monkeypatch, tmp_path):
    m = api()
    daemon = m.EphemeralDaemon()
    daemon.root = tmp_path
    daemon.container_cgroup_parent = '/system.slice/larenor-jellyfin-test.service/containers'
    daemon._socket = lambda: None
    calls = []
    monkeypatch.setattr(m, 'bounded_command', lambda args, **kwargs:calls.append(args) or b'')
    exact = '--cgroup-parent='+daemon.container_cgroup_parent
    daemon.docker(['create',exact,'image'])
    assert len(calls) == 1
    for args in (['create','image'], ['run',exact,exact,'image'],
                 ['run','--cgroup-parent=/system.slice/foreign.service','image']):
        with pytest.raises(m.SmokeError, match='^owned_daemon_scope_invalid$'):
            daemon.docker(args)
    assert len(calls) == 1


def test_full_characterization_consumer_exists():
    m = api()
    assert callable(getattr(m, 'characterize', None)), 'storage flow consumer is absent'


def test_container_inspection_rejects_anonymous_copyup_or_wrong_user():
    m = api()
    source = m.fixture_source('linux/amd64')
    expected = {'Entrypoint':['/jellyfin/jellyfin'], 'Cmd':None, 'Volumes':{'/config':{},'/cache':{}}}
    current = {'Id':'c'*64,'Image':source.image.image.configDigest,
        'Config':dict(expected, User='1000:1000'),
        'HostConfig':{'NetworkMode':'none','PortBindings':{},'Privileged':False,'CapDrop':['ALL'],
            'CgroupParent':'/system.slice/test.service/containers',
            'Mounts':[{'Type':'volume','Source':v.name,'Target':v.target,'ReadOnly':False,
                       'VolumeOptions':{'NoCopy':True}} for v in source.targets]},
        'Mounts':[{'Type':'volume','Name':v.name,'Driver':'local','Destination':v.target,'RW':True}
            for v in source.targets]}
    assert m.verify_container(current, source, expected,
        '/system.slice/test.service/containers') is None
    current['Mounts'].append({'Type':'volume','Name':'foreign','Destination':'/extra','RW':True})
    with pytest.raises(m.SmokeError):
        m.verify_container(current, source, expected, '/system.slice/test.service/containers')
    current['Mounts'].pop()
    current['HostConfig']['Mounts'][0]['VolumeOptions']['NoCopy'] = False
    with pytest.raises(m.SmokeError):
        m.verify_container(current, source, expected, '/system.slice/test.service/containers')
    current['HostConfig']['Mounts'][0]['VolumeOptions']['NoCopy'] = True
    current['Config']['User'] = '0:0'
    with pytest.raises(m.SmokeError):
        m.verify_container(current, source, expected, '/system.slice/test.service/containers')
    current['Config']['User'] = '1000:1000'
    current['HostConfig']['CgroupParent'] = '/system.slice/foreign.service'
    with pytest.raises(m.SmokeError):
        m.verify_container(current, source, expected, '/system.slice/test.service/containers')


@pytest.fixture
def protocol(tmp_path, monkeypatch, request):
    m = api()
    tmp_path = Path(tempfile.mkdtemp(prefix='jf-protocol-', dir='/private/tmp' if Path('/private/tmp').exists() else '/tmp'))
    request.addfinalizer(lambda:shutil.rmtree(tmp_path))
    from larenor_server.plugins.image_resources import ImageObservation
    source = m.fixture_source('linux/amd64')
    image_config = {'Entrypoint':['/jellyfin/jellyfin'],'Cmd':None,
                    'Volumes':{'/config':{},'/cache':{}}}
    monkeypatch.setenv('GITHUB_SHA','a'*40)
    monkeypatch.setattr(m, 'verify_checkout', lambda commit: None)
    monkeypatch.setattr(m, 'prepare_storage', lambda *a: {
        'imageState':'ready','volumeStates':['observed_requires_bootstrap']*2})
    class Images:
        def inspect(self, binding):
            return ImageObservation(binding.config_digest, json.dumps(image_config).encode())
    class Docker:
        root = tmp_path
        platform = 'linux/amd64'
        container_cgroup_parent = '/system.slice/larenor-jellyfin-test.service/containers'
        fault = None
        restarted = False
        base_started = False
        app_started = False
        verified_pids = []
        calls = []
        seen = {}
        def docker(self, args, **kwargs):
            self.calls.append(list(args))
            reference = next(line.split()[1] for line in
                (m.REPOSITORY/'server/Dockerfile.volume-bootstrap').read_text().splitlines()
                if line.startswith('FROM '))
            if args[0] == 'pull':
                assert args == ['pull','--quiet','--platform='+self.platform,reference]
                return b'docker.io/library/python:canonical-pull-output\n'
            if args[:2] == ['image','inspect'] and args[-1] == reference:
                return json.dumps({'Id':'sha256:'+'e'*64,'Os':'linux',
                    'Architecture':self.platform.split('/')[1],
                    'RepoDigests':['python@'+reference.split('@')[1]],'Config':{'Volumes':None}}).encode()
            if args[0] == 'create' and '--name=larenor-helper-base-probe' in args:
                assert '--pull=never' in args and '--network=none' in args
                assert '--cgroup-parent='+self.container_cgroup_parent in args
                assert not any(a.startswith(('--mount','--volume','--publish')) for a in args)
                return ('d'*64+'\n').encode()
            if args == ['start','--attach','d'*64]:
                self.base_started = True
                return b'larenor-helper-base-ok-v1\n'
            if args[:2] == ['container','inspect'] and args[-1] == 'd'*64:
                return json.dumps({'Id':'d'*64,'Image':'sha256:'+'e'*64,
                    'Config':{'User':'0:0','Entrypoint':['/usr/local/bin/python'],
                        'Cmd':['-I','-c','print("larenor-helper-base-ok-v1")']},
                    'HostConfig':{'NetworkMode':'none','ReadonlyRootfs':True,'Privileged':False,
                        'CapDrop':['ALL'],'CapAdd':None,'Binds':None,'Mounts':None,'VolumesFrom':None,
                        'CgroupParent':self.container_cgroup_parent},
                    'Mounts':[], 'State':{'Status':'exited' if self.base_started else 'created',
                        'Running':False,'Paused':False,'Dead':False,'OOMKilled':False,'ExitCode':0}}).encode()
            if args[0] == 'build':
                (tmp_path/'helper.iid').write_text('sha256:'+'f'*64)
                return b''
            if args[:2] == ['image','inspect']:
                return json.dumps({'Id':'sha256:'+'f'*64,'Os':'linux','Architecture':'amd64',
                    'RepoDigests':[],'Config':{'Labels':m.source_labels('a'*40,m.source_hashes())}}).encode()
            if args[0] == 'create':
                return ('c'*64+'\n').encode()
            if args[0] in {'start','restart'}:
                if args[0] == self.fault:
                    raise m.SmokeError('fixture_command_failed')
                self.restarted |= args[0] == 'restart'
                self.app_started = True
                return ('c'*64+'\n').encode()
            if args[:2] == ['container','inspect']:
                value = {'Id':'c'*64,'Image':source.image.image.configDigest,
                    'Config':dict(image_config,User='1000:1000'),
                    'HostConfig':{'NetworkMode':'none','Privileged':False,'CapDrop':['ALL'],
                        'CgroupParent':self.container_cgroup_parent,
                        'Mounts':[{'Type':'volume','Source':v.name,'Target':v.target,
                            'VolumeOptions':{'NoCopy':True}} for v in source.targets]},
                    'Mounts':[{'Type':'volume','Name':v.name,'Driver':'local','Destination':v.target,'RW':True}
                        for v in source.targets],
                    'State':{'Pid':4242 if self.app_started else 0}}
                if self.fault == 'mount':
                    value['Mounts'].append({'Type':'volume','Name':'foreign','Destination':'/extra'})
                return json.dumps(value).encode()
            assert args[0] == 'run'
            assert '--cgroup-parent='+self.container_cgroup_parent in args
            mode = args[-1]
            if mode == self.fault:
                raise m.SmokeError('fixture_command_failed')
            if mode == 'image_seed':
                value = {'imageSeed':True}
            elif mode == 'writable':
                mount = next(a for a in args if a.startswith('--mount='))
                n = self.seen.get(mount,0)
                self.seen[mount] = n+1
                value = {'writable':n>0,'uid':1000,'gid':1000}
            elif mode in {'check','initialize_empty_root','verify_root'}:
                value = {'schemaVersion':1,'state':{'check':'empty_uninitialized',
                    'initialize_empty_root':'empty_initialized','verify_root':'root_verified'}[mode]}
            elif mode == 'prepare_media_directories':
                value = {'schemaVersion':1,'state':'media_directories_prepared'}
            elif mode == 'health':
                value = {'id': ('b' if self.restarted and self.fault == 'identity' else 'a')*32,
                    'version':'10.11.11',
                    'wizardCompleted':getattr(self, 'managed_configured', False)}
            elif mode == 'initial_data':
                value = {'database':True,'configuration':True}
            elif mode == 'app_identity':
                value = {'uid':1000,'gid':1000}
            else:
                assert mode in {'write_sentinel','verify_sentinel'}
                value = {'sentinel':'verified','uid':1000,'gid':1000}
            return json.dumps(value).encode()
        def verify_container_cgroup(self, pid):
            assert pid == 4242
            self.verified_pids.append(pid)
        def verify_container_resources(self, pid, memory, nano_cpus, pids_limit):
            assert (pid, memory, nano_cpus, pids_limit) == (
                4242, 4 * 1024 * 1024 * 1024, 2_000_000_000, 512)
            self.verified_pids.append(pid)
    return m, source, Docker(), Images()


def test_complete_protocol_uses_two_nocopy_mounts_and_one_restart(protocol):
    m, source, docker, images = protocol
    result = m.characterize(docker, source=source, images=images, volumes=object())
    assert result['result'] == 'characterized' and result['volumeCount'] == 2
    assert result['installAvailable'] is False and result['bootstrapAccountConfigured'] is False
    assert sum(c[0]=='create' and '--name=larenor-helper-base-probe' in c for c in docker.calls) == 1
    assert sum(c == ['start','--attach','d'*64] for c in docker.calls) == 1
    assert sum(c[0]=='create' and '--name=larenor-helper-base-probe' not in c for c in docker.calls) == 1
    assert sum(c == ['start','c'*64] for c in docker.calls) == 1
    assert sum(c[0]=='restart' for c in docker.calls) == 1
    creates = next(c for c in docker.calls if c[0]=='create' and '--name=larenor-helper-base-probe' not in c)
    assert len([a for a in creates if a.startswith('--mount=')]) == 2
    assert '--network=none' in creates and '--user=1000:1000' in creates
    assert '--cgroup-parent='+docker.container_cgroup_parent in creates
    assert not any(a.startswith(('--publish','--privileged','--volume=')) for c in docker.calls for a in c)
    assert sum(c[-1]=='initialize_empty_root' for c in docker.calls) == 2
    assert sum(c[-1]=='verify_sentinel' for c in docker.calls) == 2
    assert docker.verified_pids == [4242,4242]


def test_managed_characterization_routes_through_resources_and_v2_worker(
        protocol, monkeypatch):
    m, source, docker, images = protocol
    from tool import media_resource_smoke
    from larenor_server.plugins import managed_container
    events = []

    monkeypatch.setattr(media_resource_smoke, 'characterize_resources',
        lambda root, actual_source, actual_images, network_reader, network_creator:
            events.append(('resources', root, actual_source, actual_images,
                           type(network_reader).__name__, type(network_creator).__name__)))

    class ManagedEngine:
        def inspect_container(self, identity):
            events.append(('inspect', identity))
            return {'Id': identity, 'State': {'Pid': 4242, 'Running': True}}

    class Marker:
        @staticmethod
        def payload():
            return {'specification': {'HostConfig': {
                'Memory': 4 * 1024 * 1024 * 1024,
                'NanoCpus': 2_000_000_000,
                'PidsLimit': 512,
            }}}
    marker = Marker()
    monkeypatch.setattr(m, '_managed_create_and_start',
        lambda owner, actual_source, endpoint, helper_id:
            (events.append(('managed', owner, actual_source, endpoint.path, helper_id)),
             setattr(owner, 'managed_configured', True),
             ('c' * 64, marker, ManagedEngine(), {
                 'apiKeyVerified': True, 'libraryCount': 2, 'sessionClosed': True,
             }))[-1])
    monkeypatch.setattr(managed_container, 'managed_container_matches',
                        lambda value, binding: binding is marker)

    result = m.characterize(
        docker, source=source, images=images, volumes=object(), managed=True,
    )

    assert result['containerMode'] == 'journaled_managed_v2'
    assert result['containerJournalVersion'] == 2
    assert result['bootstrapAccountConfigured'] is True
    assert result['apiKeyVerified'] is True
    assert result['libraryCount'] == 2
    assert result['sessionClosed'] is True
    assert [event[0] for event in events[:4]] == [
        'resources', 'managed', 'inspect', 'inspect',
    ]
    app_creates = [call for call in docker.calls
                   if call[0] == 'create' and '--name=larenor-helper-base-probe' not in call]
    assert app_creates == []
    assert ['start', 'c' * 64] not in docker.calls
    assert docker.verified_pids == [4242, 4242]


@pytest.mark.parametrize('boundary,expected', [
    ('before_connect', 'bootstrap_endpoint_changed_before_connect'),
    ('after_connect', 'bootstrap_endpoint_changed_after_connect'),
    ('after_startup', 'bootstrap_endpoint_changed_after_startup'),
    ('after_readback_connect', 'bootstrap_endpoint_changed_after_readback_connect'),
    ('after_readback', 'bootstrap_endpoint_changed_after_readback'),
])
def test_native_bootstrap_endpoint_failure_keeps_only_closed_boundary(boundary, expected):
    m = api()
    from larenor_server.plugins.jellyfin_bootstrap_executor import (
        JellyfinBootstrapExecutionError,
    )
    error = JellyfinBootstrapExecutionError(
        'bootstrap_endpoint_changed', boundary=boundary,
    )
    assert m._managed_bootstrap_error(error) == expected


@pytest.mark.parametrize('completed,expected', [
    ((), 'bootstrap_startup_observe_failed'),
    (('observed_unconfigured',), 'bootstrap_startup_configuration_failed'),
    (('observed_unconfigured', 'configuration_updated'),
     'bootstrap_startup_user_failed'),
    (('observed_unconfigured', 'configuration_updated', 'user_updated'),
     'bootstrap_startup_remote_access_failed'),
    (('observed_unconfigured', 'configuration_updated', 'user_updated',
      'remote_access_updated'), 'bootstrap_startup_complete_failed'),
])
def test_native_bootstrap_startup_failure_keeps_only_closed_step(completed, expected):
    m = api()
    from larenor_server.plugins.jellyfin_bootstrap_executor import (
        JellyfinBootstrapExecutionError,
    )
    error = JellyfinBootstrapExecutionError(
        'bootstrap_startup_failed', completed_steps=completed,
        uncertain_effect=bool(completed),
    )
    assert m._managed_bootstrap_error(error) == expected


@pytest.mark.parametrize('steps,expected', [
    ((), 'bootstrap_readback_authentication_failed'),
    (('authenticated',), 'bootstrap_readback_keys_failed'),
    (('authenticated', 'keys_observed'), 'bootstrap_readback_key_create_failed'),
    (('authenticated', 'keys_observed', 'key_created'),
     'bootstrap_readback_key_reread_failed'),
    (('authenticated', 'keys_observed', 'key_verified'),
     'bootstrap_readback_system_failed'),
    (('authenticated', 'keys_observed', 'key_verified', 'system_verified'),
     'bootstrap_readback_libraries_failed'),
    (('authenticated', 'keys_observed', 'key_verified', 'system_verified',
      'libraries_verified'), 'bootstrap_readback_logout_failed'),
])
def test_native_bootstrap_readback_failure_keeps_only_closed_step(steps, expected):
    m = api()
    from larenor_server.plugins.jellyfin_bootstrap_executor import (
        JellyfinBootstrapExecutionError,
    )
    error = JellyfinBootstrapExecutionError(
        'bootstrap_readback_failed', readback_steps=steps,
        cause_code='jellyfin_authenticated_readback_protocol',
        uncertain_effect=bool(steps),
    )
    assert m._managed_bootstrap_error(error) == expected


@pytest.mark.parametrize('steps,cause,expected', [
    ((), 'jellyfin_library_protocol', 'bootstrap_wiring_observe_failed'),
    (('observed',), 'jellyfin_library_conflict', 'bootstrap_wiring_conflict'),
    (('observed',), 'jellyfin_library_protocol', 'bootstrap_wiring_create_failed'),
    (('observed', 'movies_created'), 'jellyfin_library_protocol',
     'bootstrap_wiring_shows_failed'),
    (('observed', 'shows_created'), 'jellyfin_library_protocol',
     'bootstrap_wiring_verify_failed'),
    (('observed', 'movies_created', 'shows_created'),
     'jellyfin_library_protocol', 'bootstrap_wiring_verify_failed'),
])
def test_native_library_failure_keeps_only_closed_step(steps, cause, expected):
    m = api()
    from larenor_server.plugins.jellyfin_bootstrap_executor import (
        JellyfinBootstrapExecutionError,
    )
    error = JellyfinBootstrapExecutionError(
        'bootstrap_wiring_failed', library_steps=steps, cause_code=cause,
        uncertain_effect=bool(steps),
    )
    assert m._managed_bootstrap_error(error) == expected


@pytest.mark.parametrize('status,message,expected', [
    (400, 'invalid mount config for type "volume"', 'managed_create_mount_rejected'),
    (400, 'network larenor-control-private not found', 'managed_create_network_rejected'),
    (400, 'invalid cgroup parent', 'managed_create_cgroup_rejected'),
    (400, 'invalid security option', 'managed_create_security_rejected'),
    (404, 'No such image: private', 'managed_create_image_rejected'),
    (400, 'minimum memory limit allowed is 6MB', 'managed_create_resource_rejected'),
    (500, 'private absolute path and token', 'managed_create_engine_rejected'),
])
def test_managed_create_response_is_reduced_to_closed_category(
        status, message, expected):
    m = api()
    body = json.dumps({'message': message}).encode()
    assert m._managed_create_rejection(status, body) == expected
    assert message not in m._managed_create_rejection(status, body)


@pytest.mark.parametrize('body', [
    b'', b'not-json', b'{"message":1}', b'{"message":"x","extra":"private"}',
    json.dumps({'message': 'x' * 4097}).encode(),
])
def test_malformed_managed_create_response_stays_closed(body):
    m = api()
    assert m._managed_create_rejection(400, body) == 'managed_create_engine_rejected'


@pytest.mark.parametrize('body,expected', [
    (json.dumps({'Id': 'a' * 64, 'Warnings': []}).encode(), None),
    (b'not-json', 'managed_create_response_invalid'),
    (json.dumps({'Id': 'short', 'Warnings': []}).encode(),
     'managed_create_identity_invalid'),
    (json.dumps({'Id': 'a' * 64, 'Warnings': ['private']}).encode(),
     'managed_create_warning_unclassified'),
    (json.dumps({'Id': 'a' * 64, 'Warnings': [
        "requested image's platform does not match detected host platform",
    ]}).encode(), 'managed_create_platform_warning'),
    (json.dumps({'Id': 'a' * 64, 'Warnings': [
        'IPv4 forwarding is disabled. Networking will not work.',
    ]}).encode(), 'managed_create_network_warning'),
    (json.dumps({'Id': 'a' * 64, 'Warnings': [
        'Your kernel does not support swap limit capabilities',
    ]}).encode(), 'managed_create_swap_warning'),
    (json.dumps({'Id': 'a' * 64, 'Warnings': [
        'Your kernel does not support memory limit capabilities',
    ]}).encode(), 'managed_create_memory_warning'),
    (json.dumps({'Id': 'a' * 64, 'Warnings': [
        'CPU cgroup limit is unavailable',
    ]}).encode(), 'managed_create_cpu_warning'),
    (json.dumps({'Id': 'a' * 64, 'Warnings': [
        'Pids limit is unavailable',
    ]}).encode(), 'managed_create_pids_warning'),
    (json.dumps({'Id': 'a' * 64, 'Warnings': None, 'extra': 'allowed'}).encode(), None),
])
def test_managed_create_success_shape_is_classified_without_content(body, expected):
    m = api()
    assert m._managed_create_success_diagnostic(body) == expected


def test_managed_engine_exposes_only_closed_create_diagnostic(monkeypatch):
    m = api()
    from larenor_server.plugins.docker_probe import DockerEndpoint
    from larenor_server.plugins.worker import UnixDockerEngine
    response = SimpleNamespace(
        status=400,
        body=json.dumps({'message': 'network /private/token not found'}).encode(),
    )
    monkeypatch.setattr(
        UnixDockerEngine,
        '_exchange',
        lambda _self, _method, _target, _body=None: response,
    )
    engine = m._managed_engine(DockerEndpoint('/tmp/larenor-engine.sock', owner_uid=0))
    assert engine._exchange('POST', '/containers/create?name=private', b'{}') is response
    assert engine.managed_create_diagnostic == 'managed_create_network_rejected'
    assert '/private/token' not in engine.managed_create_diagnostic


def test_managed_engine_preserves_transport_error_and_records_closed_diagnostic(
        monkeypatch):
    m = api()
    from larenor_server.plugins.docker_probe import DockerEndpoint
    from larenor_server.plugins.worker import DockerWorkerError, UnixDockerEngine
    error = DockerWorkerError('engine_unavailable')

    def fail(*_args, **_kwargs):
        raise error

    monkeypatch.setattr(UnixDockerEngine, '_exchange', fail)
    engine = m._managed_engine(DockerEndpoint('/tmp/larenor-engine.sock', owner_uid=0))
    with pytest.raises(DockerWorkerError) as caught:
        engine._exchange('POST', '/containers/create?name=private', b'{}')
    assert caught.value is error
    assert engine.managed_create_diagnostic == 'managed_create_transport_failed'


@pytest.mark.parametrize('field,actual,expected', [
    ('MemorySwap', 0, 'managed_inspect_memory_swap_mismatch'),
    ('Memory', 1, 'managed_inspect_memory_mismatch'),
    ('NanoCpus', 1, 'managed_inspect_cpu_mismatch'),
    ('PidsLimit', 1, 'managed_inspect_pids_mismatch'),
])
def test_managed_inspect_resource_drift_is_reduced_to_closed_category(
        field, actual, expected):
    m = api()
    host = {'MemorySwap': -1, 'Memory': 4294967296,
            'NanoCpus': 2000000000, 'PidsLimit': 512}
    class Binding:
        @staticmethod
        def payload():
            return {'specification': {'HostConfig': dict(host)}}
    observed = {'HostConfig': {**host, field: actual}}
    assert m._managed_inspect_diagnostic(observed, Binding()) == expected


@pytest.mark.parametrize('field,actual,expected', [
    ('SecurityOpt', ['no-new-privileges'], 'managed_inspect_security_mismatch'),
    ('Tmpfs', {}, 'managed_inspect_tmpfs_targets_mismatch'),
    ('Mounts', [{'Type': 'bind'}], 'managed_inspect_requested_mount_mismatch'),
    ('NetworkMode', 'none', 'managed_inspect_network_mode_mismatch'),
    ('Init', False, 'managed_inspect_init_mismatch'),
])
def test_managed_inspect_nonresource_host_drift_has_closed_category(
        field, actual, expected):
    m = api()
    host = {'MemorySwap': -1, 'Memory': 4294967296,
            'NanoCpus': 2000000000, 'PidsLimit': 512,
            'SecurityOpt': ['no-new-privileges:true'],
            'Tmpfs': {'/tmp': 'private'}, 'Mounts': [{'Type': 'volume'}],
            'NetworkMode': 'larenor-control-'+'a'*32, 'Init': True,
            'RestartPolicy': {'Name': 'no'}}
    class Binding:
        @staticmethod
        def payload():
            return {'specification': {'HostConfig': dict(host)}}
    observed_host = {**host, 'RestartPolicy': {'Name': 'no', 'MaximumRetryCount': 0},
                     field: actual}
    observed = {'Id': 'b'*64, 'HostConfig': observed_host}
    assert m._managed_inspect_diagnostic(observed, Binding()) == expected


@pytest.mark.parametrize('actual,expected', [
    (None, 'managed_inspect_tmpfs_empty_normalized'),
    ({}, 'managed_inspect_tmpfs_targets_mismatch'),
    ({'/tmp': 'nodev,rw,nosuid,size=64m'}, 'managed_inspect_tmpfs_order_mismatch'),
    ({'/tmp': 'rw,nosuid,nodev,size=67108864'}, 'managed_inspect_tmpfs_size_normalized'),
    ({'/tmp': 'rw,nosuid,size=64m'}, 'managed_inspect_tmpfs_option_missing'),
    ({'/tmp': 'rw,nosuid,nodev,size=64m,private'}, 'managed_inspect_tmpfs_option_extra'),
])
def test_tmpfs_diagnostic_never_exposes_raw_option_values(actual, expected):
    m = api()
    desired = {} if actual is None else {'/tmp': 'rw,nosuid,nodev,size=64m'}
    assert m._tmpfs_diagnostic(actual, desired) == expected


def test_empty_tmpfs_normalization_does_not_hide_later_host_drift():
    m = api()
    expected = {'MemorySwap': -1, 'Memory': 4294967296,
                'NanoCpus': 2000000000, 'PidsLimit': 512,
                'Tmpfs': {}, 'SecurityOpt': ['no-new-privileges:true']}
    class Binding:
        @staticmethod
        def payload():
            return {'specification': {'HostConfig': expected}}
    observed = {'HostConfig': {**expected, 'Tmpfs': None,
                               'SecurityOpt': ['no-new-privileges']}}
    assert m._managed_inspect_diagnostic(
        observed, Binding()) == 'managed_inspect_security_mismatch'


def test_empty_tmpfs_normalization_is_not_itself_a_managed_mismatch():
    m = api()
    expected = {'MemorySwap': -1, 'Memory': 4294967296,
                'NanoCpus': 2000000000, 'PidsLimit': 512, 'Tmpfs': {}}
    class Binding:
        @staticmethod
        def payload():
            return {'specification': {'HostConfig': expected}}
    assert m._managed_inspect_diagnostic(
        {'HostConfig': {**expected, 'Tmpfs': None}}, Binding()
    ) == 'managed_inspect_identity_mismatch'


def test_moved_host_mounts_do_not_hide_later_managed_mismatch():
    m = api()
    expected = {'MemorySwap': -1, 'Memory': 4294967296,
                'NanoCpus': 2000000000, 'PidsLimit': 512,
                'Tmpfs': {}, 'Mounts': [{'Type': 'volume'}], 'Init': True}
    class Binding:
        @staticmethod
        def payload():
            return {'specification': {'HostConfig': expected}}
    observed = {'HostConfig': {**expected, 'Tmpfs': None, 'Mounts': None,
                               'Init': False}}
    assert m._managed_inspect_diagnostic(
        observed, Binding()) == 'managed_inspect_init_mismatch'


@pytest.mark.parametrize('networks,expected', [
    (None, 'managed_inspect_networks_missing'),
    ({'foreign': {'NetworkID': 'b'*64}}, 'managed_inspect_network_key_mismatch'),
    ({'larenor-control-'+'a'*32: {'NetworkID': ''}},
     'managed_inspect_network_id_missing'),
    ({'larenor-control-'+'a'*32: {'NetworkID': 'c'*64}},
     'managed_inspect_network_id_mismatch'),
])
def test_network_diagnostic_reports_only_closed_structure_category(networks, expected):
    m = api()
    assert m._network_diagnostic(
        networks, 'larenor-control-'+'a'*32, 'b'*64) == expected


@pytest.mark.parametrize('worker_code,expected', [
    ('invalid_binding', 'managed_create_binding_rejected'),
    ('engine_protocol', 'managed_create_protocol_failed'),
    ('engine_peer_rejected', 'managed_create_endpoint_rejected'),
    ('unsafe_worker_path', 'managed_create_endpoint_rejected'),
    ('engine_conflict', 'managed_create_resource_conflict'),
])
def test_managed_engine_records_pre_http_worker_rejection(
        worker_code, expected, monkeypatch):
    m = api()
    from larenor_server.plugins.docker_probe import DockerEndpoint
    from larenor_server.plugins.worker import DockerWorkerError, UnixDockerEngine
    error = DockerWorkerError(worker_code)

    def fail(*_args, **_kwargs):
        raise error

    monkeypatch.setattr(UnixDockerEngine, 'create_managed_container', fail)
    engine = m._managed_engine(DockerEndpoint('/tmp/larenor-engine.sock', owner_uid=0))
    with pytest.raises(DockerWorkerError) as caught:
        engine.create_managed_container(object())
    assert caught.value is error
    assert engine.managed_create_diagnostic == expected


@pytest.mark.parametrize('state,code,diagnostic,expected', [
    ('prepared', 'accepted', None, 'managed_create_preflight_failed'),
    ('uncertain', 'engine_operation_uncertain', None, 'managed_create_uncertain'),
    ('needs_attention', 'resource_conflict', None, 'managed_create_resource_conflict'),
    ('needs_attention', 'dispatch_expired', None, 'managed_create_expired'),
    ('uncertain', 'engine_operation_uncertain', 'managed_create_network_rejected',
     'managed_create_network_rejected'),
    ('private', 'private', None, 'managed_create_receipt_invalid'),
])
def test_failed_managed_create_receipt_has_only_closed_diagnostic(
        state, code, diagnostic, expected):
    m = api()
    receipt = SimpleNamespace(state=state, code=code, container_id='private')
    assert m._managed_create_receipt_failure(receipt, diagnostic) == expected


@pytest.mark.parametrize('container_id,expected', [
    ('a' * 64, True),
    ('sha256:' + 'a' * 64, False),
    ('a' * 63, False),
    ('A' * 64, False),
    (None, False),
])
def test_managed_create_receipt_uses_docker_container_id_shape(container_id, expected):
    m = api()
    receipt = SimpleNamespace(
        state='succeeded', code='container_created', container_id=container_id,
    )
    assert m._managed_create_succeeded(receipt) is expected


@pytest.mark.parametrize('fault', ['initialize_empty_root','start','restart','identity','mount','initial_data'])
def test_lost_or_conflicting_reply_never_repeats_a_mutation(protocol, fault):
    m, source, docker, images = protocol
    docker.fault = fault
    with pytest.raises(m.SmokeError):
        m.characterize(docker, source=source, images=images, volumes=object())
    assert sum(c[0]=='create' and '--name=larenor-helper-base-probe' in c for c in docker.calls) == 1
    assert sum(c == ['start','--attach','d'*64] for c in docker.calls) == 1
    assert sum(c[0]=='create' and '--name=larenor-helper-base-probe' not in c for c in docker.calls) <= 1
    assert sum(c == ['start','c'*64] for c in docker.calls) <= 1
    assert sum(c[0]=='restart' for c in docker.calls) <= 1
    assert not any(c[0] in {'rm','volume','system'} for c in docker.calls)


def test_application_uid_is_observed_not_only_requested_in_config(protocol):
    m, source, docker, images = protocol
    m.characterize(docker, source=source, images=images, volumes=object())
    calls = [c for c in docker.calls if c[-1]=='app_identity']
    assert len(calls) == 2
    assert all('--pid=container:'+'c'*64 in c for c in calls)


def test_unexpected_library_exception_is_not_printed_by_cli(monkeypatch, capsys):
    m = api()
    monkeypatch.setattr(m,'verify_checkout',lambda _:None)
    class Owned:
        def __enter__(self):
            return self
        def __exit__(self,*_):
            self.closed=True
    owner = Owned()
    monkeypatch.setattr(m,'EphemeralDaemon',lambda:owner)
    monkeypatch.setattr(m,'characterize',lambda _, **kw: (_ for _ in ()).throw(RuntimeError('synthetic-private')))
    assert m.main(['--run-ephemeral-ci']) == 1
    assert owner.closed
    assert capsys.readouterr().err == 'storage_characterization_failed\n'


def test_build_attestation_rejects_wrong_embedded_source_label():
    m = api()
    value = {'Id':'sha256:'+'f'*64,'Os':'linux','Architecture':'amd64',
        'Config':{'Labels':{'org.opencontainers.image.revision':'b'*40}}}
    with pytest.raises(m.SmokeError):
        m.helper_attestation(value['Id'],value,'linux/amd64','a'*40)


def test_cli_verifies_checkout_before_starting_daemon(monkeypatch, capsys):
    m = api()
    calls = []
    monkeypatch.setenv('GITHUB_SHA','a'*40)
    monkeypatch.setattr(m,'verify_checkout',lambda commit:calls.append(('source',commit)),raising=False)
    class Owned:
        def __enter__(self):
            calls.append('enter')
            return self
        def __exit__(self,*_):
            calls.append('exit')
    monkeypatch.setattr(m,'EphemeralDaemon',Owned)
    monkeypatch.setattr(m,'characterize',lambda _, **kw: {'result':'characterized'})
    assert m.main(['--run-ephemeral-ci']) == 0
    assert calls == [('source','a'*40),('source','a'*40),'enter','exit']


@pytest.mark.parametrize('failure', [None,'spawn_failure','launch_uncertain','wrong_root','body'])
def test_daemon_lifecycle_reaps_only_owned_process_and_directory(tmp_path, monkeypatch, failure):
    m = api()
    owned = tmp_path/'larenor-jellyfin-testnonce'
    outsider = tmp_path/'unrelated'
    outsider.mkdir()
    (outsider/'keep').write_text('keep')
    events = []
    def directory(**kwargs):
        owned.mkdir(mode=0o700)
        return str(owned)
    monkeypatch.setattr(m,'native_platform',lambda *a:'linux/amd64')
    monkeypatch.setattr(m.tempfile,'mkdtemp',directory)
    def command(args, **kwargs):
        if args[0] == '/usr/bin/systemd-run':
            events.append('launch')
            assert kwargs['environment']['HOME'] == str(owned)
            if failure == 'spawn_failure':
                raise m.SmokeError('fixture_command_spawn_failed')
            if failure == 'launch_uncertain':
                raise m.SmokeError('fixture_command_exit_failed')
            (owned/'engine.sock').touch()
            return b''
        raise AssertionError(args)
    monkeypatch.setattr(m,'bounded_command',command)
    def capture(self):
        events.append('capture')
        self.unit_identity = ('a'*32,'/system.slice/'+m.daemon_unit(owned),'12345')
        self.cgroup_fd, self.cgroup_identity = 99, (1,2)
        self.cgroup_kill_fd, self.cgroup_events_fd = 100, 101
        self.cgroup_live_observed = True
    monkeypatch.setattr(m.EphemeralDaemon,'_capture_unit',capture)
    monkeypatch.setattr(m.EphemeralDaemon,'_check_unit',lambda _:events.append('check'))
    def kill(self):
        events.append('cgroup.kill')
        self.emergency_requested = self.emergency_applied = True
    monkeypatch.setattr(m.EphemeralDaemon,'emergency_cleanup',kill)
    monkeypatch.setattr(m.EphemeralDaemon,'_wait_cgroup_empty',
        lambda _,**kwargs:events.append(('empty',kwargs['retirement_allowed'])))
    monkeypatch.setattr(m.os,'close',lambda fd:events.append(('close',fd)))
    def socket(self):
        return (1,2)
    monkeypatch.setattr(m.EphemeralDaemon,'_socket',socket)
    def docker(self, args, **kwargs):
        return json.dumps(str(outsider if failure == 'wrong_root' else owned/'data')).encode()
    monkeypatch.setattr(m.EphemeralDaemon,'docker',docker)
    if failure:
        with pytest.raises((OSError, m.SmokeError)):
            with m.EphemeralDaemon():
                if failure == 'body':
                    raise m.SmokeError()
    else:
        with m.EphemeralDaemon() as daemon:
            assert daemon.root == owned
    assert owned.exists() is (failure == 'launch_uncertain')
    assert (outsider/'keep').read_text() == 'keep'
    if failure not in {'spawn_failure','launch_uncertain'}:
        assert events.index('cgroup.kill') < events.index(('empty',True))
        assert [('close',101),('close',100),('close',99)] == [e for e in events if
            isinstance(e,tuple) and e[0] == 'close' and e[1] in {99,100,101}]
    assert not any(isinstance(e,tuple) and e[0] == 'stop' for e in events)


def test_exited_parent_with_inherited_stdout_cannot_leave_a_live_child(tmp_path):
    m = api()
    pidfile = tmp_path/'child.pid'
    script = ('import subprocess,sys,pathlib; '
        'p=subprocess.Popen([sys.executable,"-c","import time; time.sleep(30)"]); '
        f'pathlib.Path({str(pidfile)!r}).write_text(str(p.pid))')
    child = None
    try:
        with pytest.raises(m.SmokeError, match='fixture_command_failed'):
            m.bounded_command([sys.executable,'-c',script],environment={},timeout=0.25,limit=128)
        child = int(pidfile.read_text())
        deadline = time.monotonic()+1
        alive = True
        while time.monotonic() < deadline:
            result = subprocess.run(['/bin/ps','-o','stat=','-p',str(child)],capture_output=True,timeout=2)
            alive = result.returncode == 0 and not result.stdout.strip().startswith(b'Z')
            if not alive:
                break
            time.sleep(0.02)
        assert not alive, 'parent exit must not skip termination of its owned process group'
    finally:
        if child is None and pidfile.exists():
            child = int(pidfile.read_text())
        if child is not None:
            try:
                os.kill(child,m.signal.SIGKILL)
            except ProcessLookupError:
                pass


def test_emergency_cleanup_targets_only_the_captured_cgroup_fd(monkeypatch):
    m = api()
    events = []
    owner = m.EphemeralDaemon()
    owner.cgroup_fd, owner.cgroup_kill_fd = 99, 100
    monkeypatch.setattr(m.os,'write',lambda fd,value:events.append(('write',fd,value)) or len(value))
    owner.emergency_cleanup()
    owner.emergency_cleanup()
    assert events == [('write',100,b'1')]


def test_captured_cleanup_uses_only_pinned_cgroup_and_never_stops_name(tmp_path, monkeypatch):
    m = api()
    owned = tmp_path/'larenor-jellyfin-testnonce'
    owned.mkdir()
    owner = m.EphemeralDaemon()
    owner.root, owner.root_identity = owned, (owned.stat().st_dev, owned.stat().st_ino)
    owner.unit_attempted = True
    owner.unit_identity = ('a'*32,'/system.slice/'+m.daemon_unit(owned),'12345')
    owner.cgroup_fd, owner.cgroup_identity = 99, (1,2)
    owner.cgroup_kill_fd, owner.cgroup_events_fd = 100, 101
    events = []
    monkeypatch.setattr(owner,'_check_unit',lambda:(_ for _ in ()).throw(m.SmokeError('owned_daemon_lost')))
    def kill():
        owner.emergency_requested = owner.emergency_applied = True
        events.append('cgroup.kill')
    monkeypatch.setattr(owner,'emergency_cleanup',kill)
    monkeypatch.setattr(owner,'_wait_cgroup_empty',lambda **kwargs:events.append('empty'))
    monkeypatch.setattr(m,'bounded_command',lambda *a,**k:events.append('systemctl stop'))
    monkeypatch.setattr(m.os,'close',lambda fd:events.append(('close',fd)))
    owner.__exit__()
    assert [event for event in events if not (isinstance(event,tuple)
        and event[0] == 'close' and event[1] not in {99,100,101})] == [
        'cgroup.kill','empty',('close',101),('close',100),('close',99)]
    assert not owned.exists()


def test_uncertain_pre_capture_launch_is_not_adopted_or_stopped_by_name(tmp_path, monkeypatch):
    m = api()
    owned = tmp_path/'larenor-jellyfin-testnonce'
    owned.mkdir()
    owner = m.EphemeralDaemon()
    owner.root, owner.root_identity = owned, (owned.stat().st_dev, owned.stat().st_ino)
    owner.unit_attempted = True
    owner.emergency_cleanup()
    events = []
    monkeypatch.setattr(m,'bounded_command',lambda *a,**k:events.append('systemctl stop'))
    with pytest.raises(m.SmokeError, match='^owned_cleanup_failed$'):
        owner.__exit__()
    assert events == [] and owned.exists()


@pytest.fixture
def copied_checkout(protocol, monkeypatch):
    m, source, docker, images = protocol
    checkout = docker.root/'checkout'
    checkout.mkdir()
    names = (*m._SOURCE_FILES, 'LICENSE', 'NOTICE')
    for name in names:
        target = checkout/name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((m.REPOSITORY/name).read_bytes())
    (checkout/'.git').mkdir()
    (checkout/'.git'/'synthetic-private').write_text('not build input')
    (checkout/'unrelated-artifact').write_text('not build input')
    monkeypatch.setattr(m, 'REPOSITORY', checkout)
    # Git cleanliness is characterized independently below; Docker stays fake.
    monkeypatch.setattr(m, 'verify_checkout', lambda commit: None)
    return protocol


def test_build_uses_only_explicit_staged_files_not_repository_context(copied_checkout):
    m, source, docker, images = copied_checkout
    original = docker.docker
    def dispatch(args, **kwargs):
        if args[0] == 'build':
            context = Path(args[-1])
            assert context != m.REPOSITORY, 'legacy build must never receive the checkout'
            assert context.is_relative_to(docker.root)
            expected = {'tool/volume_bootstrap_helper.py', 'tool/jellyfin_storage_probe.py',
                        'server/Dockerfile.volume-bootstrap', 'LICENSE', 'NOTICE'}
            assert {str(p.relative_to(context)) for p in context.rglob('*') if p.is_file()} == expected
            assert Path(args[args.index('--file')+1]) == context/'server/Dockerfile.volume-bootstrap'
            assert all((context/name).read_bytes() == (m.REPOSITORY/name).read_bytes() for name in expected)
        return original(args, **kwargs)
    docker.docker = dispatch
    result = m.characterize(docker, source=source, images=images, volumes=object())
    assert result['result'] == 'characterized'


@pytest.mark.parametrize('changed', ['tool/volume_bootstrap_helper.py', 'LICENSE'])
def test_preparation_cannot_rebase_build_to_changed_source(copied_checkout, monkeypatch, changed):
    m, source, docker, images = copied_checkout
    prepare = m.prepare_storage
    def change_after_preparation(*args):
        result = prepare(*args)
        with (m.REPOSITORY/changed).open('ab') as output:
            output.write(b'\nchanged after initial source binding\n')
        return result
    monkeypatch.setattr(m, 'prepare_storage', change_after_preparation)
    with pytest.raises(m.SmokeError, match='^fixture_source_changed$'):
        m.characterize(docker, source=source, images=images, volumes=object())
    assert not docker.calls, 'source drift must fail before helper build'


def test_checkout_verification_includes_license_used_by_helper(tmp_path, monkeypatch):
    m = api()
    checkout = tmp_path/'committed'
    checkout.mkdir()
    for name in {*m._SOURCE_FILES, 'LICENSE', 'NOTICE'}:
        target = checkout/name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text('synthetic committed source\n')
    def git(*args):
        return subprocess.run(['/usr/bin/git', '-C', str(checkout), *args], check=True,
                              capture_output=True, timeout=5).stdout.decode().strip()
    git('init', '-q')
    git('add', '.')
    git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture')
    commit = git('rev-parse', 'HEAD')
    monkeypatch.setattr(m, 'REPOSITORY', checkout)
    m.verify_checkout(commit)
    (checkout/'LICENSE').write_text('changed licensing bytes\n')
    with pytest.raises(m.SmokeError):
        m.verify_checkout(commit)


@pytest.mark.parametrize('where', ['checkout', 'staged', 'extra_staged', 'late_checkout'])
def test_build_or_final_drift_cannot_publish_attestation(copied_checkout, where):
    m, source, docker, images = copied_checkout
    original = docker.docker
    def dispatch(args, **kwargs):
        result = original(args, **kwargs)
        if args[0] == 'build' and where != 'late_checkout':
            context = Path(args[-1])
            target = (m.REPOSITORY/'NOTICE' if where == 'checkout' else
                      context/'LICENSE' if where == 'staged' else context/'unexpected-file')
            target.write_text('changed after staging\n')
        if args[-1] == 'verify_sentinel' and where == 'late_checkout':
            (m.REPOSITORY/'NOTICE').write_text('changed during final oracle\n')
        return result
    docker.docker = dispatch
    with pytest.raises(m.SmokeError, match='^fixture_source_changed$'):
        m.characterize(docker, source=source, images=images, volumes=object())
    if where != 'late_checkout':
        assert [call[0] for call in docker.calls] == ['pull','image','create','container','start','container','build']
        assert '--name=larenor-helper-base-probe' in docker.calls[2]
        assert docker.calls[4] == ['start','--attach','d'*64]


def test_cli_binding_is_captured_before_daemon_start(copied_checkout, monkeypatch, capsys):
    m, source, docker, images = copied_checkout
    events = []
    class Owned:
        def __enter__(self):
            (m.REPOSITORY/'tool/volume_bootstrap_helper.py').write_text('changed during daemon startup\n')
            events.append('enter')
            return docker
        def __exit__(self, *_):
            events.append('exit')
    consumer = m.characterize
    monkeypatch.setattr(m, 'EphemeralDaemon', Owned)
    monkeypatch.setattr(m, 'characterize', lambda owner, **kwargs:
        consumer(owner, source=source, images=images, volumes=object(), **kwargs))
    assert m.main(['--run-ephemeral-ci']) == 1
    assert docker.calls == [] and events == ['enter', 'exit']
    captured = capsys.readouterr()
    assert captured.out == '' and captured.err == 'fixture_source_changed\n'


def test_copy_detects_source_drift_and_never_reuses_existing_stage(copied_checkout, monkeypatch):
    m, _, docker, _ = copied_checkout
    binding = m.capture_source('a'*40)
    with pytest.raises(TypeError):
        binding[1]['LICENSE'] = '0'*64
    read = m._source_bytes
    calls = 0
    def change_after_read(path):
        nonlocal calls
        raw = read(path)
        if path == m.REPOSITORY/'LICENSE':
            calls += 1
            if calls == 2:
                path.write_text('changed during staged copy\n')
        return raw
    monkeypatch.setattr(m, '_source_bytes', change_after_read)
    with pytest.raises(m.SmokeError, match='^fixture_source_changed$'):
        m.stage_context(docker.root, binding)
    assert not docker.calls
    monkeypatch.setattr(m, '_source_bytes', read)
    fresh = m.capture_source('a'*40)
    with pytest.raises(FileExistsError):
        m.stage_context(docker.root, fresh)


@pytest.mark.parametrize('kind', ['oversize', 'symlink', 'directory', 'absent'])
def test_staged_inputs_reject_nonregular_or_unbounded_bytes(tmp_path, kind):
    m = api()
    path = tmp_path/'source'
    if kind == 'oversize':
        path.write_bytes(b'x'*1048577)
    elif kind == 'symlink':
        target = tmp_path/'other'
        target.write_text('synthetic')
        path.symlink_to(target)
    elif kind == 'directory':
        path.mkdir()
    with pytest.raises(m.SmokeError, match='^fixture_source_changed$'):
        m._source_bytes(path)
