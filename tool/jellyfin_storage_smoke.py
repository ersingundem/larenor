#!/usr/bin/env python3
"""Opt-in native CI characterization; never connects to an existing daemon.

The only CLI action creates its own mount/PID namespace, daemon, data root,
socket and empty Docker client configuration. No supplied socket/platform or
DOCKER_HOST fallback exists. CI environment checks are an accidental-use guard,
not a production authority issuer. This is not wired to Server API/runtime.
"""
from contextlib import contextmanager
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
from types import MappingProxyType
import uuid


REPOSITORY = Path(__file__).resolve().parents[1]
_HASH = re.compile(r'sha256:[0-9a-f]{64}\Z')
_COMMIT = re.compile(r'[0-9a-f]{40}\Z')
_CODES = {'storage_characterization_failed','native_ephemeral_ci_required','fixture_command_failed',
    'owned_daemon_lost','owned_daemon_unavailable','owned_cleanup_failed','fixture_image_unresolved',
    'fixture_volume_unresolved','fixture_protocol_failed','jellyfin_startup_timeout',
    'unexpected_image_volume','unexpected_initial_write_access','restart_identity_changed','fixture_source_changed'}
_DIAGNOSTIC_CODES = _CODES | {'invalid_image_preparation', 'invalid_image_binding',
    'fixture_command_exit_failed', 'fixture_command_output_limit', 'fixture_command_timeout',
    'fixture_command_spawn_failed', 'fixture_command_io_failed',
    'image_cancelled', 'image_pull_not_authorized', 'image_observation_unavailable',
    'invalid_image_limits', 'image_protocol', 'image_stream_limit', 'image_pull_failed',
    'image_engine_unavailable', 'image_timeout', 'image_unverified', 'image_api_unsupported',
    'invalid_volume_preparation', 'invalid_volume_binding', 'invalid_volume_effect_limits',
    'volume_create_not_authorized', 'volume_protocol', 'volume_response_limit',
    'volume_engine_unavailable', 'volume_timeout', 'volume_cancelled', 'volume_api_unsupported',
    'journal_unavailable', 'unsafe_worker_path', 'worker_busy', 'invalid_binding',
    'storage_characterization_evidence_invalid'}
_PHASES = {'launcher', 'launch_validation', 'source_capture', 'daemon_start', 'daemon_cleanup',
    'characterization', 'image_prepare', 'volume_prepare', 'image_inspect', 'helper_stage',
    'helper_build', 'helper_inspect', 'helper_seed', 'initial_permissions', 'bootstrap_check',
    'bootstrap_initialize', 'initialized_permissions', 'sentinel_write', 'container_create',
    'container_inspect', 'container_start', 'initial_health', 'initial_identity', 'initial_data',
    'container_restart', 'restart_health', 'restart_identity', 'root_verify', 'sentinel_verify',
    'restart_data', 'source_recheck', 'receipt_validate', 'receipt_verify'}
_SOURCE_FILES = ('tool/volume_bootstrap_helper.py','tool/jellyfin_storage_probe.py',
    'tool/jellyfin_storage_smoke.py','server/Dockerfile.volume-bootstrap',
    'server/Dockerfile.volume-bootstrap.dockerignore', 'LICENSE', 'NOTICE')
_BUILD_FILES = ('tool/volume_bootstrap_helper.py', 'tool/jellyfin_storage_probe.py',
    'server/Dockerfile.volume-bootstrap', 'LICENSE', 'NOTICE')


class SmokeError(Exception):
    def __init__(self, code='storage_characterization_failed', *, phase=None):
        self.phase = _closed(phase, _PHASES, 'launcher')
        super().__init__(_closed(code, _DIAGNOSTIC_CODES, 'storage_characterization_failed'))


def _closed(value, allowed, fallback):
    return value if type(value) is str and len(value) <= 64 and value in allowed else fallback


def _error_code(error):
    # Read only BaseException's stored arguments, never __str__/repr or a custom
    # property. Arbitrary diagnostics, paths, output and credentials stay private.
    args = BaseException.args.__get__(error)
    return _closed(args[0] if len(args) == 1 else None,
                   _DIAGNOSTIC_CODES, 'storage_characterization_failed')


@contextmanager
def diagnostic_phase(name):
    """Preserve the innermost failing boundary; cleanup success cannot replace it."""
    selected = _closed(name, _PHASES, 'launcher')
    try:
        yield
    except Exception as error:
        if type(error) is SmokeError:
            selected = _closed(error.phase, _PHASES, selected)
            # An unannotated SmokeError belongs to this boundary.
            if selected == 'launcher':
                selected = _closed(name, _PHASES, 'launcher')
        raise SmokeError(_error_code(error), phase=selected) from None


def failure_diagnostic(error):
    phase = _closed(error.phase, _PHASES, 'launcher') if type(error) is SmokeError else 'launcher'
    return 'storage_characterization_failed phase='+phase+' code='+_error_code(error)


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


def _signal_group(process, sig):
    try:
        os.killpg(process.pid, sig)
    except ProcessLookupError:
        pass


def bounded_command(arguments, *, environment, timeout=60, limit=65536, diagnose_failure=False):
    """No shell/input/ambient secrets; cap bytes and kill/reap the owned child."""
    require(type(diagnose_failure) is bool, 'fixture_command_failed')
    def check(value, code):
        require(value, code if diagnose_failure else 'fixture_command_failed')
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
                check(remaining > 0 and selector.select(remaining), 'fixture_command_timeout')
                chunk = os.read(process.stdout.fileno(), limit - len(result) + 1)
                if not chunk:
                    break
                result.extend(chunk)
                check(len(result) <= limit, 'fixture_command_output_limit')
        remaining = deadline - time.monotonic()
        check(remaining > 0, 'fixture_command_timeout')
        check(process.wait(timeout=remaining) == 0, 'fixture_command_exit_failed')
        return bytes(result)
    except subprocess.TimeoutExpired:
        raise SmokeError('fixture_command_timeout' if diagnose_failure else 'fixture_command_failed') from None
    except OSError:
        code = 'fixture_command_spawn_failed' if process is None else 'fixture_command_io_failed'
        raise SmokeError(code if diagnose_failure else 'fixture_command_failed') from None
    finally:
        if process is not None:
            try:
                # An exited parent can leave descendants holding its pipe open.
                # The group remains ours even when Popen.poll() has reaped it.
                _signal_group(process, signal.SIGKILL)
                process.wait(timeout=5)
            finally:
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

    def docker(self, args, *, timeout=60, limit=65536, diagnose_failure=False):
        self._socket()
        return bounded_command(['/usr/bin/docker', '--host=unix://'+str(self.root/'engine.sock'),
            '--config='+str(self.root/'docker-config'), *args], environment=child_environment(self.root),
            timeout=timeout, limit=limit, diagnose_failure=diagnose_failure)

    @diagnostic_phase('daemon_start')
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

    @diagnostic_phase('daemon_cleanup')
    def __exit__(self, *_):
        if self.process is not None:
            _signal_group(self.process, signal.SIGTERM)
            try:
                self.process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                pass
            finally:
                _signal_group(self.process, signal.SIGKILL)
                self.process.wait(timeout=5)
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
    with diagnostic_phase('image_prepare'):
        with ResourceJournal(image_dir, initialize=not image_dir.exists()) as journal:
            result = JournaledImageOperations(journal, images).apply(source.plan, source.stack,
                source.catalog, source.policy, source.image.resourceId, authorize_pull=lambda:True)
            require(result.state == 'ready', 'fixture_image_unresolved')
    states = []
    with diagnostic_phase('volume_prepare'):
        with VolumeCreateJournal(volume_dir, initialize=not volume_dir.exists()) as journal:
            for target in source.targets:
                receipt = JournaledVolumeCreates(journal, volumes).apply(source.volumes, source.stack,
                    source.catalog, source.policy, target.resourceId, authorize_create=lambda:True)
                require(receipt.state == 'observed_requires_bootstrap', 'fixture_volume_unresolved')
                states.append(receipt.state)
    return {'imageState': result.state, 'volumeStates': states}


def _source_bytes(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
        with os.fdopen(fd, 'rb') as source:
            require(stat.S_ISREG(os.fstat(source.fileno()).st_mode), 'fixture_source_changed')
            raw = source.read(1048577)
        require(len(raw) <= 1048576, 'fixture_source_changed')
        return raw
    except OSError:
        raise SmokeError('fixture_source_changed') from None


def source_hashes():
    return {name: hashlib.sha256(_source_bytes(REPOSITORY/name)).hexdigest()
            for name in _SOURCE_FILES}


def capture_source(commit):
    verify_checkout(commit)
    binding = commit, MappingProxyType(source_hashes())
    check_source(binding)
    return binding


def check_source(binding):
    commit, expected = binding
    verify_checkout(commit)
    require(source_hashes() == expected, 'fixture_source_changed')


def check_staged(context, binding):
    expected = binding[1]
    require({str(p.relative_to(context)) for p in context.rglob('*') if not p.is_dir()}
            == set(_BUILD_FILES), 'fixture_source_changed')
    for name in _BUILD_FILES:
        require(hashlib.sha256(_source_bytes(context/name)).hexdigest() == expected[name],
                'fixture_source_changed')


def stage_context(root, binding):
    """Legacy Docker reads only this new allowlisted context, never the checkout.

    Rechecks detect observed checkout/stage drift, not a malicious local writer
    changing and restoring bytes between checks. No user paths are accepted.
    """
    check_source(binding)
    context = root/'helper-context'
    context.mkdir(mode=0o700)
    for name in _BUILD_FILES:
        raw = _source_bytes(REPOSITORY/name)
        require(hashlib.sha256(raw).hexdigest() == binding[1][name], 'fixture_source_changed')
        target = context/name
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with target.open('xb') as output:
            output.write(raw)
    check_source(binding)
    check_staged(context, binding)
    return context


def source_labels(commit, hashes):
    return {'org.opencontainers.image.revision': commit,
        'org.larenor.fixture.source-bundle': hashlib.sha256(
            json.dumps(hashes, sort_keys=True, separators=(',', ':')).encode()).hexdigest()}


def verify_checkout(commit):
    require(type(commit) is str and _COMMIT.fullmatch(commit), 'fixture_source_changed')
    git = ['/usr/bin/git','-c','safe.directory='+str(REPOSITORY),'-C',str(REPOSITORY)]
    env = {'PATH':'/usr/bin:/bin','LANG':'C.UTF-8'}
    head = bounded_command(git+['rev-parse','HEAD'], environment=env, limit=64).decode().strip()
    require(head == commit, 'fixture_source_changed')
    bounded_command(git+['ls-files','--error-unmatch','--',*_SOURCE_FILES],environment=env,limit=4096)
    bounded_command(git+['diff','--exit-code','HEAD','--',*_SOURCE_FILES],environment=env,limit=256)


def helper_attestation(image_id, inspected, selected_platform, commit, *, expected_hashes=None):
    require(type(image_id) is str and _HASH.fullmatch(image_id) and _COMMIT.fullmatch(commit))
    require(inspected.get('Id') == image_id and inspected.get('Os') == 'linux'
            and inspected.get('Architecture') == selected_platform.split('/')[1])
    hashes = source_hashes() if expected_hashes is None else dict(expected_hashes)
    labels = inspected.get('Config',{}).get('Labels') or {}
    require(all(labels.get(key) == value for key,value in source_labels(commit,hashes).items()),
            'fixture_source_changed')
    return {'configDigest': image_id, 'platform': selected_platform, 'sourceCommit': commit,
        'publishedManifestDigest': None,
        'helperSourceSha256': hashes['tool/volume_bootstrap_helper.py'],
        'probeSourceSha256': hashes['tool/jellyfin_storage_probe.py'],
        'dockerfileSha256': hashes['server/Dockerfile.volume-bootstrap'], 'sourceHashes':hashes}


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
        '--user='+('0:0' if bootstrap and mode != 'verify_root' else '1000:1000')]
    if mode == 'app_identity':
        require(re.fullmatch(r'container:[0-9a-f]{64}', network) is not None)
        args.append('--pid='+network)
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


@diagnostic_phase('characterization')
def characterize(daemon, *, source=None, images=None, volumes=None, checkout_binding=None):
    """The real consumer: two volumes, bootstrap, NoCopy/start/restart or fail.

    Optional objects are private offline-test seams, not CLI/runtime inputs.
    A new context never replays another daemon's state; cleanup is whole owned
    namespace shutdown, never Docker prune or removal of externally named data.
    """
    from larenor_server.plugins.docker_probe import DockerEndpoint
    from larenor_server.plugins.image_resources import UnixImageEngine, image_binding
    from larenor_server.plugins.volume_effects import UnixVolumeCreator
    checkout_binding = capture_source(os.environ['GITHUB_SHA']) if checkout_binding is None else checkout_binding
    check_source(checkout_binding)
    source = fixture_source(daemon.platform) if source is None else source
    endpoint = DockerEndpoint(str(daemon.root/'engine.sock'), owner_uid=0)
    images = UnixImageEngine(endpoint) if images is None else images
    volumes = UnixVolumeCreator(endpoint) if volumes is None else volumes
    receipt = prepare_storage(daemon.root, source, images, volumes)
    with diagnostic_phase('image_inspect'):
        binding = image_binding(source.plan, source.stack, source.catalog, source.policy, source.image.resourceId)
        observed = images.inspect(binding)
        require(observed is not None and observed.image_id == binding.config_digest)
        image_config = _decoded(observed.configuration)
        require(type(image_config) is dict and set(image_config.get('Volumes') or {}) <= {'/config','/cache'},
                'unexpected_image_volume')
    iid_file = daemon.root/'helper.iid'
    with diagnostic_phase('helper_stage'):
        context = stage_context(daemon.root, checkout_binding)
    commit, hashes = checkout_binding
    labels = source_labels(commit, dict(hashes))
    with diagnostic_phase('helper_build'):
        daemon.docker(['build','--pull','--quiet','--network=none',
            *['--label='+key+'='+value for key,value in labels.items()], '--file',
            str(context/'server/Dockerfile.volume-bootstrap'),'--iidfile',str(iid_file),str(context)],
            timeout=600, limit=256, diagnose_failure=True)
    with diagnostic_phase('helper_inspect'):
        check_source(checkout_binding)
        check_staged(context, checkout_binding)
        helper_id = iid_file.read_text().strip()
        require(_HASH.fullmatch(helper_id) is not None)
        inspected = _decoded(daemon.docker(['image','inspect','--format','{{json .}}',helper_id], limit=65536))
        attestation = helper_attestation(helper_id, inspected, daemon.platform, commit, expected_hashes=hashes)
    with diagnostic_phase('helper_seed'):
        require(_helper(daemon, helper_id, 'image_seed') == {'imageSeed':True})
    for target in source.targets:
        # A real negative oracle, not an invented RED: if it is writable already,
        # this candidate's rootful/empty ownership assumption must be reviewed.
        with diagnostic_phase('initial_permissions'):
            require(_helper(daemon, helper_id, 'writable', target=target)
                == {'writable':False,'uid':1000,'gid':1000}, 'unexpected_initial_write_access')
        with diagnostic_phase('bootstrap_check'):
            require(_helper(daemon, helper_id, 'check', target=target, bootstrap=True)
                == {'schemaVersion':1,'state':'empty_uninitialized'})
        with diagnostic_phase('bootstrap_initialize'):
            require(_helper(daemon, helper_id, 'initialize_empty_root', target=target, bootstrap=True)
                == {'schemaVersion':1,'state':'empty_initialized'})
        with diagnostic_phase('initialized_permissions'):
            require(_helper(daemon, helper_id, 'writable', target=target)
                == {'writable':True,'uid':1000,'gid':1000})
        with diagnostic_phase('sentinel_write'):
            require(_helper(daemon, helper_id, 'write_sentinel', target=target)
                == {'sentinel':'verified','uid':1000,'gid':1000})
    name = 'larenor-jellyfin-'+source.stack.preparationId
    args = ['create','--name='+name,'--network=none','--read-only','--cap-drop=ALL',
        '--security-opt=no-new-privileges','--user=1000:1000','--memory=4g','--cpus=2',
        '--pids-limit=512','--restart=no','--tmpfs=/tmp:rw,nosuid,nodev,size=67108864','--env=TZ=UTC']
    args += ['--mount=type=volume,src='+v.name+',dst='+v.target+',volume-nocopy' for v in source.targets]
    with diagnostic_phase('container_create'):
        container_id = daemon.docker(args+[binding.reference], limit=128).decode().strip()
        require(re.fullmatch(r'[0-9a-f]{64}', container_id) is not None)
    @diagnostic_phase('container_inspect')
    def inspect():
        value = _decoded(daemon.docker(['container','inspect','--format','{{json .}}',container_id], limit=262144))
        require(value.get('Id') == container_id)
        verify_container(value, source, image_config)
    inspect()
    with diagnostic_phase('container_start'):
        daemon.docker(['start',container_id], limit=128)
    with diagnostic_phase('initial_health'):
        first = _health(daemon, helper_id, container_id)
    with diagnostic_phase('initial_identity'):
        require(_helper(daemon, helper_id, 'app_identity', network='container:'+container_id)
                == {'uid':1000,'gid':1000})
    config_target = next(v for v in source.targets if v.target == '/config')
    with diagnostic_phase('initial_data'):
        require(_helper(daemon, helper_id, 'initial_data', target=config_target)
                == {'database':True,'configuration':True})
    with diagnostic_phase('container_restart'):
        daemon.docker(['restart','--time=10',container_id], timeout=30, limit=128)
    with diagnostic_phase('restart_health'):
        second = _health(daemon, helper_id, container_id)
        require(second == first, 'restart_identity_changed')
    with diagnostic_phase('restart_identity'):
        require(_helper(daemon, helper_id, 'app_identity', network='container:'+container_id)
                == {'uid':1000,'gid':1000})
    inspect()
    for target in source.targets:
        with diagnostic_phase('root_verify'):
            require(_helper(daemon, helper_id, 'verify_root', target=target, bootstrap=True)
                    == {'schemaVersion':1,'state':'root_verified'})
        with diagnostic_phase('sentinel_verify'):
            require(_helper(daemon, helper_id, 'verify_sentinel', target=target)
                    == {'sentinel':'verified','uid':1000,'gid':1000})
    with diagnostic_phase('restart_data'):
        require(_helper(daemon, helper_id, 'initial_data', target=config_target)
                == {'database':True,'configuration':True})
    with diagnostic_phase('source_recheck'):
        check_source(checkout_binding)
        check_staged(context, checkout_binding)
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
        checkout_binding = capture_source(os.environ.get('GITHUB_SHA',''))
        with EphemeralDaemon() as daemon:
            result = characterize(daemon, checkout_binding=checkout_binding)
        print(json.dumps(result, sort_keys=True, separators=(',', ':')))
        return 0
    except SmokeError as error:
        print(str(error), file=sys.stderr)
        return 1
    except Exception:
        print('storage_characterization_failed', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
