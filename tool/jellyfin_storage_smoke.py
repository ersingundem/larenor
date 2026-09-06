#!/usr/bin/env python3
"""Opt-in native CI characterization; never connects to an existing daemon.

The only CLI action creates its own mount/PID namespace, daemon, data root,
socket and empty Docker client configuration. No supplied socket/platform or
DOCKER_HOST fallback exists. CI environment checks are an accidental-use guard,
not a production authority issuer. This is not wired to Server API/runtime.
"""
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid


REPOSITORY = Path(__file__).resolve().parents[1]
_HASH = re.compile(r'sha256:[0-9a-f]{64}\Z')
_COMMIT = re.compile(r'[0-9a-f]{40}\Z')


class SmokeError(Exception):
    def __init__(self, code='storage_characterization_failed'):
        super().__init__(code)


def require(value, code='storage_characterization_failed'):
    if not value:
        raise SmokeError(code)


def native_platform(environment, system, machine, uid):
    selected = {'x86_64': ('X64', 'linux/amd64'), 'aarch64': ('ARM64', 'linux/arm64')}.get(machine)
    require(system == 'Linux' and type(uid) is int and uid == 0 and selected is not None
        and environment.get('CI') == 'true' and environment.get('GITHUB_ACTIONS') == 'true'
        and environment.get('RUNNER_ENVIRONMENT') == 'github-hosted'
        and environment.get('RUNNER_ARCH') == selected[0]
        and _COMMIT.fullmatch(environment.get('GITHUB_SHA', '')) is not None,
        'native_ephemeral_ci_required')
    return selected[1]


def child_environment(root):
    return {'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
        'HOME': str(root), 'DOCKER_CONFIG': str(root/'docker-config'),
        'DOCKER_API_VERSION': '1.47', 'DOCKER_BUILDKIT': '0', 'LANG': 'C.UTF-8'}


def bounded_command(arguments, *, environment, timeout=60, limit=65536):
    """No shell/input/ambient secrets; cap bytes and kill/reap the owned child."""
    process = None
    deadline = time.monotonic() + timeout
    try:
        process = subprocess.Popen(arguments, env=environment, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0, start_new_session=True)
        result = bytearray()
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while True:
                remaining = deadline - time.monotonic()
                require(remaining > 0 and selector.select(remaining), 'fixture_command_failed')
                chunk = os.read(process.stdout.fileno(), limit - len(result) + 1)
                if not chunk:
                    break
                result.extend(chunk)
                require(len(result) <= limit, 'fixture_command_failed')
        remaining = deadline - time.monotonic()
        require(remaining > 0 and process.wait(timeout=remaining) == 0, 'fixture_command_failed')
        return bytes(result)
    except (OSError, subprocess.TimeoutExpired):
        raise SmokeError('fixture_command_failed') from None
    finally:
        if process is not None:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            process.stdout.close()


def daemon_command(root):
    return ['/usr/bin/unshare', '--mount', '--propagation=private', '--pid', '--fork',
        '--kill-child=SIGKILL', '--mount-proc', '/usr/bin/dockerd',
        '--host=unix://'+str(root/'engine.sock'), '--data-root='+str(root/'data'),
        '--exec-root='+str(root/'exec'), '--pidfile='+str(root/'daemon.pid'),
        '--config-file='+str(root/'daemon.json'), '--bridge=none', '--iptables=false',
        '--ip6tables=false', '--ip-forward=false', '--ip-masq=false',
        '--userland-proxy=false', '--storage-driver=vfs', '--group=root']


class EphemeralDaemon:
    """Own only resources created in this context; cleanup cannot select a host."""
    def __init__(self):
        self.root = self.process = self.socket_identity = self.root_identity = None

    def _socket(self):
        try:
            require(self.process is not None and self.process.poll() is None, 'owned_daemon_lost')
            value = (self.root/'engine.sock').lstat()
            require(stat.S_ISSOCK(value.st_mode) and value.st_uid == 0
                    and not value.st_mode & 0o002, 'owned_daemon_lost')
            identity = value.st_dev, value.st_ino
            require(self.socket_identity is None or self.socket_identity == identity, 'owned_daemon_lost')
            return identity
        except OSError:
            raise SmokeError('owned_daemon_lost') from None

    def docker(self, args, *, timeout=60, limit=65536):
        self._socket()
        return bounded_command(['/usr/bin/docker', '--host=unix://'+str(self.root/'engine.sock'),
            '--config='+str(self.root/'docker-config'), *args], environment=child_environment(self.root),
            timeout=timeout, limit=limit)

    def __enter__(self):
        self.platform = native_platform(os.environ, platform.system(), platform.machine(), os.geteuid())
        self.root = Path(tempfile.mkdtemp(prefix='larenor-jellyfin-', dir='/tmp'))
        info = self.root.lstat()
        self.root_identity = info.st_dev, info.st_ino
        try:
            (self.root/'docker-config').mkdir(mode=0o700)
            (self.root/'daemon.json').write_text('{}')
            (self.root/'daemon.json').chmod(0o600)
            self.process = subprocess.Popen(daemon_command(self.root), env=child_environment(self.root),
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                start_new_session=True)
            deadline = time.monotonic() + 40
            while not (self.root/'engine.sock').exists():
                require(self.process.poll() is None and time.monotonic() < deadline, 'owned_daemon_unavailable')
                time.sleep(0.1)
            self.socket_identity = self._socket()
            actual = json.loads(self.docker(['info', '--format', '{{json .DockerRootDir}}']))
            require(actual == str(self.root/'data'), 'owned_daemon_lost')
            return self
        except BaseException:
            self.__exit__(*sys.exc_info())
            raise

    def __exit__(self, *_):
        if self.process is not None:
            if self.process.poll() is None:
                os.killpg(self.process.pid, signal.SIGTERM)
                try:
                    self.process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    os.killpg(self.process.pid, signal.SIGKILL)
                    self.process.wait(timeout=15)
            else:
                self.process.wait()
            self.process = None
        if self.root is not None:
            value = self.root.lstat()
            require(stat.S_ISDIR(value.st_mode) and (value.st_dev, value.st_ino) == self.root_identity,
                    'owned_cleanup_failed')
            shutil.rmtree(self.root)
            self.root = None


@dataclass(frozen=True, repr=False)
class FixtureSource:
    catalog: object
    stack: object
    policy: object
    plan: object
    volumes: object
    image: object
    targets: tuple


def fixture_source(selected_platform):
    from larenor_server.context import ContextResponse
    from larenor_server.plugins.catalog import load_catalog
    from larenor_server.plugins.resource_models import WorkerPolicyBinding
    from larenor_server.plugins.resource_plan import build_resource_plan
    from larenor_server.plugins.stack_plan import build_media_stack_plan
    from larenor_server.plugins.volume_plan import build_volume_plan
    catalog = load_catalog()
    context = ContextResponse(schemaVersion=1, coreId=uuid.uuid4().hex, homeId=uuid.uuid4().hex)
    stack = build_media_stack_plan(catalog, {}, selected_platform, context, uuid.uuid4().hex)
    # Identifies this fixture protocol; deliberately not an operator policy/grant.
    policy = WorkerPolicyBinding(schemaVersion=1, workerPolicyVersion=1,
        workerPolicyDigest=hashlib.sha256(b'larenor-owned-ci-storage-fixture-v1').hexdigest())
    plan, volumes = build_resource_plan(stack, catalog, policy), build_volume_plan(stack, catalog, policy)
    image = next(r for r in plan.resources if r.kind == 'ensure_image' and r.serviceId == 'jellyfin')
    targets = tuple(r for r in volumes.resources if r.serviceId == 'jellyfin')
    require(len(targets) == 2 and {v.target for v in targets} == {'/config','/cache'})
    return FixtureSource(catalog, stack, policy, plan, volumes, image, targets)


def prepare_storage(root, source, images, volumes):
    from larenor_server.plugins.image_preparation import JournaledImageOperations
    from larenor_server.plugins.resource_journal import ResourceJournal
    from larenor_server.plugins.volume_create_journal import VolumeCreateJournal
    from larenor_server.plugins.volume_preparation import JournaledVolumeCreates
    image_dir, volume_dir = root/'image-journal', root/'volume-journal'
    with ResourceJournal(image_dir, initialize=not image_dir.exists()) as journal:
        result = JournaledImageOperations(journal, images).apply(source.plan, source.stack,
            source.catalog, source.policy, source.image.resourceId, authorize_pull=lambda:True)
        require(result.state == 'ready', 'fixture_image_unresolved')
    states = []
    with VolumeCreateJournal(volume_dir, initialize=not volume_dir.exists()) as journal:
        for target in source.targets:
            receipt = JournaledVolumeCreates(journal, volumes).apply(source.volumes, source.stack,
                source.catalog, source.policy, target.resourceId, authorize_create=lambda:True)
            require(receipt.state == 'observed_requires_bootstrap', 'fixture_volume_unresolved')
            states.append(receipt.state)
    return {'imageState': result.state, 'volumeStates': states}


def helper_attestation(image_id, inspected, selected_platform, commit):
    require(type(image_id) is str and _HASH.fullmatch(image_id) and _COMMIT.fullmatch(commit))
    require(inspected.get('Id') == image_id and inspected.get('Os') == 'linux'
            and inspected.get('Architecture') == selected_platform.split('/')[1])
    def digest(name):
        return hashlib.sha256((REPOSITORY/name).read_bytes()).hexdigest()
    return {'configDigest': image_id, 'platform': selected_platform, 'sourceCommit': commit,
        'publishedManifestDigest': None,
        'helperSourceSha256': digest('tool/volume_bootstrap_helper.py'),
        'probeSourceSha256': digest('tool/jellyfin_storage_probe.py'),
        'dockerfileSha256': digest('server/Dockerfile.volume-bootstrap')}


def verify_container(value, source, image_config):
    require(type(value) is dict and value.get('Image') == source.image.image.configDigest)
    config, host = value.get('Config',{}), value.get('HostConfig',{})
    require(config.get('User') == '1000:1000' and host.get('NetworkMode') == 'none'
        and not host.get('PortBindings') and host.get('Privileged') is False
        and host.get('CapDrop') == ['ALL'])
    for key in ('Entrypoint','Cmd','Volumes'):
        require(config.get(key) == image_config.get(key))
    mounts, requested = value.get('Mounts'), host.get('Mounts')
    require(type(mounts) is list and len(mounts) == 2 and type(requested) is list and len(requested) == 2)
    for target in source.targets:
        actual = [m for m in mounts if m.get('Destination') == target.target]
        desired = [m for m in requested if m.get('Target') == target.target]
        require(len(actual) == len(desired) == 1)
        require(actual[0].get('Type') == 'volume' and actual[0].get('Name') == target.name
            and actual[0].get('Driver') == 'local' and actual[0].get('RW') is True)
        require(desired[0].get('Type') == 'volume' and desired[0].get('Source') == target.name
            and desired[0].get('ReadOnly',False) is False
            and desired[0].get('VolumeOptions',{}).get('NoCopy') is True)
    require(not host.get('Binds') and not host.get('VolumesFrom'))


def _decoded(raw):
    try:
        return json.loads(raw)
    except (ValueError, TypeError):
        raise SmokeError('fixture_protocol_failed') from None


def _helper(daemon, image_id, mode, *, target=None, bootstrap=False, network='none'):
    args = ['run','--rm','--network='+network,'--read-only','--cap-drop=ALL',
        '--security-opt=no-new-privileges','--pids-limit=32','--memory=64m',
        '--user='+('0:0' if bootstrap else '1000:1000')]
    if bootstrap:
        if mode == 'initialize_empty_root':
            args.append('--cap-add=CHOWN')
    else:
        args += ['--entrypoint=/usr/local/bin/python']
    if target is not None:
        args += ['--mount=type=volume,src='+target.name+',dst=/volume,volume-nocopy']
    args += [image_id]
    if not bootstrap:
        args += ['-I','/opt/larenor/jellyfin_storage_probe.py']
    args += [mode]
    return _decoded(daemon.docker(args, timeout=20, limit=4096))


def _health(daemon, helper_id, container_id):
    deadline = time.monotonic()+180
    while time.monotonic() < deadline:
        try:
            value = _helper(daemon, helper_id, 'health', network='container:'+container_id)
            require(type(value) is dict and value.get('version') == '10.11.11'
                and value.get('wizardCompleted') is False
                and re.fullmatch(r'[0-9a-f]{32}', value.get('id','')))
            return value
        except SmokeError:
            time.sleep(1)
    raise SmokeError('jellyfin_startup_timeout')


def characterize(daemon, *, source=None, images=None, volumes=None):
    """The real consumer: two volumes, bootstrap, NoCopy/start/restart or fail.

    Optional objects are private offline-test seams, not CLI/runtime inputs.
    A new context never replays another daemon's state; cleanup is whole owned
    namespace shutdown, never Docker prune or removal of externally named data.
    """
    from larenor_server.plugins.docker_probe import DockerEndpoint
    from larenor_server.plugins.image_resources import UnixImageEngine, image_binding
    from larenor_server.plugins.volume_effects import UnixVolumeCreator
    source = fixture_source(daemon.platform) if source is None else source
    endpoint = DockerEndpoint(str(daemon.root/'engine.sock'), owner_uid=0)
    images = UnixImageEngine(endpoint) if images is None else images
    volumes = UnixVolumeCreator(endpoint) if volumes is None else volumes
    receipt = prepare_storage(daemon.root, source, images, volumes)
    binding = image_binding(source.plan, source.stack, source.catalog, source.policy, source.image.resourceId)
    observed = images.inspect(binding)
    require(observed is not None and observed.image_id == binding.config_digest)
    image_config = _decoded(observed.configuration)
    require(type(image_config) is dict and set(image_config.get('Volumes') or {}) <= {'/config','/cache'},
            'unexpected_image_volume')
    iid_file = daemon.root/'helper.iid'
    daemon.docker(['build','--pull','--quiet','--network=none','--file',
        str(REPOSITORY/'server/Dockerfile.volume-bootstrap'),'--iidfile',str(iid_file),str(REPOSITORY)],
        timeout=600, limit=256)
    helper_id = iid_file.read_text().strip()
    require(_HASH.fullmatch(helper_id) is not None)
    inspected = _decoded(daemon.docker(['image','inspect','--format','{{json .}}',helper_id], limit=65536))
    attestation = helper_attestation(helper_id, inspected, daemon.platform, os.environ['GITHUB_SHA'])
    require(_helper(daemon, helper_id, 'image_seed') == {'imageSeed':True})
    for target in source.targets:
        # A real negative oracle, not an invented RED: if it is writable already,
        # this candidate's rootful/empty ownership assumption must be reviewed.
        require(_helper(daemon, helper_id, 'writable', target=target)
            == {'writable':False,'uid':1000,'gid':1000}, 'unexpected_initial_write_access')
        require(_helper(daemon, helper_id, 'check', target=target, bootstrap=True)
            == {'schemaVersion':1,'state':'empty_uninitialized'})
        require(_helper(daemon, helper_id, 'initialize_empty_root', target=target, bootstrap=True)
            == {'schemaVersion':1,'state':'empty_initialized'})
        require(_helper(daemon, helper_id, 'writable', target=target)
            == {'writable':True,'uid':1000,'gid':1000})
        require(_helper(daemon, helper_id, 'write_sentinel', target=target)
            == {'sentinel':'verified','uid':1000,'gid':1000})
    name = 'larenor-jellyfin-'+source.stack.preparationId
    args = ['create','--name='+name,'--network=none','--read-only','--cap-drop=ALL',
        '--security-opt=no-new-privileges','--user=1000:1000','--memory=4g','--cpus=2',
        '--pids-limit=512','--restart=no','--tmpfs=/tmp:rw,nosuid,nodev,size=67108864','--env=TZ=UTC']
    args += ['--mount=type=volume,src='+v.name+',dst='+v.target+',volume-nocopy' for v in source.targets]
    container_id = daemon.docker(args+[binding.reference], limit=128).decode().strip()
    require(re.fullmatch(r'[0-9a-f]{64}', container_id) is not None)
    def inspect():
        value = _decoded(daemon.docker(['container','inspect','--format','{{json .}}',container_id], limit=262144))
        require(value.get('Id') == container_id)
        verify_container(value, source, image_config)
    inspect()
    daemon.docker(['start',container_id], limit=128)
    first = _health(daemon, helper_id, container_id)
    config_target = next(v for v in source.targets if v.target == '/config')
    require(_helper(daemon, helper_id, 'initial_data', target=config_target)
            == {'database':True,'configuration':True})
    daemon.docker(['restart','--time=10',container_id], timeout=30, limit=128)
    second = _health(daemon, helper_id, container_id)
    require(second == first, 'restart_identity_changed')
    inspect()
    for target in source.targets:
        require(_helper(daemon, helper_id, 'verify_root', target=target, bootstrap=True)
                == {'schemaVersion':1,'state':'root_verified'})
        require(_helper(daemon, helper_id, 'verify_sentinel', target=target)
                == {'sentinel':'verified','uid':1000,'gid':1000})
    require(_helper(daemon, helper_id, 'initial_data', target=config_target)
            == {'database':True,'configuration':True})
    return {'schemaVersion':1,'result':'characterized','platform':daemon.platform,
        'catalogDigest':source.catalog.digest,'jellyfinManifestDigest':source.image.image.digest,
        'jellyfinConfigDigest':binding.config_digest,'helper':attestation,
        'volumeCount':2,'restartCount':1,'serverId':first['id'],
        'bootstrapAccountConfigured':False,'installAvailable':False, **receipt}


def main(arguments=None):
    args = sys.argv[1:] if arguments is None else arguments
    if args != ['--run-ephemeral-ci']:
        print('explicit_ephemeral_ci_flag_required', file=sys.stderr)
        return 2
    try:
        with EphemeralDaemon() as daemon:
            result = characterize(daemon)
        print(json.dumps(result, sort_keys=True, separators=(',', ':')))
        return 0
    except SmokeError as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
