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
    assert len(source.plan.resources) == 13 and len(source.volumes.resources) == 7
    assert source.image.serviceId == 'jellyfin'
    assert source.image.image.platform == platform
    assert source.image.image.reference.endswith('@'+source.image.image.digest)
    assert {v.target for v in source.targets} == {'/config','/cache'}
    assert all(v.containerUser == '1000:1000' and v.noCopy is True for v in source.targets)
    assert len({v.name for v in source.targets}) == 2


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
    root = tmp_path/'owned'
    root.mkdir(mode=0o700)
    args = m.daemon_command(root)
    assert args[:2] == ['/usr/bin/unshare','--mount']
    assert '--pid' in args and '--fork' in args and '--kill-child=SIGKILL' in args
    assert '--host=unix://'+str(root/'engine.sock') in args
    assert '--data-root='+str(root/'data') in args
    assert '--exec-root='+str(root/'exec') in args
    assert '--config-file='+str(root/'daemon.json') in args
    assert '--bridge=none' in args and '--iptables=false' in args and '--ip-forward=false' in args
    assert not any('/var/run/' in arg or '/var/lib/docker' in arg for arg in args)


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
    daemon.process = SimpleNamespace(poll=lambda:None)
    daemon.socket_identity = (1,2)
    (tmp_path/'engine.sock').write_text('wrong object')
    with pytest.raises(m.SmokeError, match='^owned_daemon_lost$'):
        daemon.docker(['info'])


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
            'Mounts':[{'Type':'volume','Source':v.name,'Target':v.target,'ReadOnly':False,
                       'VolumeOptions':{'NoCopy':True}} for v in source.targets]},
        'Mounts':[{'Type':'volume','Name':v.name,'Driver':'local','Destination':v.target,'RW':True}
            for v in source.targets]}
    assert m.verify_container(current, source, expected) is None
    current['Mounts'].append({'Type':'volume','Name':'foreign','Destination':'/extra','RW':True})
    with pytest.raises(m.SmokeError):
        m.verify_container(current, source, expected)
    current['Mounts'].pop()
    current['HostConfig']['Mounts'][0]['VolumeOptions']['NoCopy'] = False
    with pytest.raises(m.SmokeError):
        m.verify_container(current, source, expected)
    current['HostConfig']['Mounts'][0]['VolumeOptions']['NoCopy'] = True
    current['Config']['User'] = '0:0'
    with pytest.raises(m.SmokeError):
        m.verify_container(current, source, expected)


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
        fault = None
        restarted = False
        calls = []
        seen = {}
        def docker(self, args, **kwargs):
            self.calls.append(list(args))
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
                return ('c'*64+'\n').encode()
            if args[:2] == ['container','inspect']:
                value = {'Id':'c'*64,'Image':source.image.image.configDigest,
                    'Config':dict(image_config,User='1000:1000'),
                    'HostConfig':{'NetworkMode':'none','Privileged':False,'CapDrop':['ALL'],
                        'Mounts':[{'Type':'volume','Source':v.name,'Target':v.target,
                            'VolumeOptions':{'NoCopy':True}} for v in source.targets]},
                    'Mounts':[{'Type':'volume','Name':v.name,'Driver':'local','Destination':v.target,'RW':True}
                        for v in source.targets]}
                if self.fault == 'mount':
                    value['Mounts'].append({'Type':'volume','Name':'foreign','Destination':'/extra'})
                return json.dumps(value).encode()
            assert args[0] == 'run'
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
            elif mode == 'health':
                value = {'id': ('b' if self.restarted and self.fault == 'identity' else 'a')*32,
                    'version':'10.11.11','wizardCompleted':False}
            elif mode == 'initial_data':
                value = {'database':True,'configuration':True}
            elif mode == 'app_identity':
                value = {'uid':1000,'gid':1000}
            else:
                assert mode in {'write_sentinel','verify_sentinel'}
                value = {'sentinel':'verified','uid':1000,'gid':1000}
            return json.dumps(value).encode()
    return m, source, Docker(), Images()


def test_complete_protocol_uses_two_nocopy_mounts_and_one_restart(protocol):
    m, source, docker, images = protocol
    result = m.characterize(docker, source=source, images=images, volumes=object())
    assert result['result'] == 'characterized' and result['volumeCount'] == 2
    assert result['installAvailable'] is False and result['bootstrapAccountConfigured'] is False
    assert sum(c[0]=='create' for c in docker.calls) == 1
    assert sum(c[0]=='start' for c in docker.calls) == 1
    assert sum(c[0]=='restart' for c in docker.calls) == 1
    creates = next(c for c in docker.calls if c[0]=='create')
    assert len([a for a in creates if a.startswith('--mount=')]) == 2
    assert '--network=none' in creates and '--user=1000:1000' in creates
    assert not any(a.startswith(('--publish','--privileged','--volume=')) for c in docker.calls for a in c)
    assert sum(c[-1]=='initialize_empty_root' for c in docker.calls) == 2
    assert sum(c[-1]=='verify_sentinel' for c in docker.calls) == 2


@pytest.mark.parametrize('fault', ['initialize_empty_root','start','restart','identity','mount','initial_data'])
def test_lost_or_conflicting_reply_never_repeats_a_mutation(protocol, fault):
    m, source, docker, images = protocol
    docker.fault = fault
    with pytest.raises(m.SmokeError):
        m.characterize(docker, source=source, images=images, volumes=object())
    assert sum(c[0]=='create' for c in docker.calls) <= 1
    assert sum(c[0]=='start' for c in docker.calls) <= 1
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


@pytest.mark.parametrize('failure', [None,'popen','wrong_root','body'])
def test_daemon_lifecycle_reaps_only_owned_process_and_directory(tmp_path, monkeypatch, failure):
    m = api()
    owned = tmp_path/'owned'
    outsider = tmp_path/'unrelated'
    outsider.mkdir()
    (outsider/'keep').write_text('keep')
    events = []
    def directory(**kwargs):
        owned.mkdir(mode=0o700)
        return str(owned)
    monkeypatch.setattr(m,'native_platform',lambda *a:'linux/amd64')
    monkeypatch.setattr(m.tempfile,'mkdtemp',directory)
    class Process:
        pid=12345
        code=None
        def poll(self):
            return self.code
        def wait(self,**_):
            events.append('wait')
            self.code=0
            return 0
    def spawn(args,**kwargs):
        events.append('spawn')
        assert kwargs['env']['HOME'] == str(owned)
        if failure == 'popen':
            raise OSError('synthetic-private')
        (owned/'engine.sock').touch()
        return Process()
    monkeypatch.setattr(m.subprocess,'Popen',spawn)
    monkeypatch.setattr(m.EphemeralDaemon,'_socket',lambda _: (1,2))
    def docker(self, args, **kwargs):
        return json.dumps(str(outsider if failure == 'wrong_root' else owned/'data')).encode()
    monkeypatch.setattr(m.EphemeralDaemon,'docker',docker)
    monkeypatch.setattr(m.os,'killpg',lambda pid,sig:events.append(('kill',pid,sig)))
    if failure:
        with pytest.raises((OSError, m.SmokeError)):
            with m.EphemeralDaemon():
                if failure == 'body':
                    raise m.SmokeError()
    else:
        with m.EphemeralDaemon() as daemon:
            assert daemon.root == owned
    assert not owned.exists() and (outsider/'keep').read_text() == 'keep'
    if failure != 'popen':
        assert ('kill',12345,m.signal.SIGTERM) in events
        assert ('kill',12345,m.signal.SIGKILL) in events and events[-1] == 'wait'


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


def test_exited_unshare_still_terminates_owned_group(monkeypatch):
    m = api()
    events = []
    owner = m.EphemeralDaemon()
    owner.process = SimpleNamespace(pid=12345,poll=lambda:0,wait=lambda **_:events.append('wait'))
    monkeypatch.setattr(m.os,'killpg',lambda pid,sig:events.append(('kill',pid,sig)))
    owner.__exit__()
    assert events[0][0] == 'kill' and events[0][1] == 12345
    assert events[-1] == 'wait'


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
