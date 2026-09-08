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
# Quiet legacy build can emit buffered progress followed by its final error.
# Keep the complete diagnostic input bounded; never export or persist it.
_BUILD_STDERR_LIMIT = 65536
_BUILD_ERROR_PATTERNS = {
    'helper_build_manifest_missing': (b'manifest unknown',),
    'helper_build_platform_missing': (b'no matching manifest for ', b'no match for platform in manifest'),
    'helper_build_registry_limit': (b'toomanyrequests:', b'429 too many requests'),
    'helper_build_registry_auth': (b'pull access denied', b'unauthorized: authentication required'),
    'helper_build_runtime_failed': (b'failed to create shim task', b'oci runtime create failed', b'runc create failed'),
    'helper_build_context_failed': (b'copy failed:', b'failed to read dockerfile'),
    'helper_build_tls_failed': (b'x509:', b'tls handshake timeout'),
    'helper_build_dns_failed': (b'no such host', b'temporary failure in name resolution'),
    'helper_build_storage_failed': (b'no space left on device', b'read-only file system'),
    'helper_build_step_failed': (b'returned a non-zero code:',),
}
# start --attach also performs inspect/attach/wait/stream operations. These
# private signatures do not prove which of those operations or host paths failed.
_START_STDERR_LIMIT = 65536
_START_ERROR_PATTERNS = {
    'helper_base_exec_failed': (b'exec format error', b'executable file not found'),
    'helper_base_permission_failed': (b'permission denied', b'operation not permitted'),
    'helper_base_storage_failed': (b'no space left on device', b'read-only file system'),
    'helper_base_daemon_unavailable': (b'cannot connect to the docker daemon', b'error during connect:'),
    'helper_base_container_missing': (b'no such container:',),
    'helper_base_wait_failed': (b'error waiting for container:',),
}
_START_RUNTIME_PATTERNS = (b'failed to create shim task', b'oci runtime create failed',
    b'runc create failed', b'failed to create task for container')
_STATE_ERROR_PATTERNS = {
    'helper_base_isolation_failed': (b'cgroup', b'apparmor', b'seccomp', b'selinux',
        b'namespace', b'rootfs', b'failed to mount', b'mount callback'),
    'helper_base_host_resource_failed': (b'resource temporarily unavailable',
        b'cannot allocate memory', b'too many open files'),
    'helper_base_path_failed': (b'no such file or directory', b'not a directory'),
    'helper_base_identity_failed': (b'no matching entries in passwd file',
        b'unable to find user', b'unable to find group'),
    'helper_base_configuration_failed': (b'invalid argument', b'invalid configuration'),
}
_PATH_LOCATION_PATTERNS = {
    'helper_base_image_path_failed': (b'/usr/local/bin/python', b'/opt/larenor/'),
    'helper_base_proc_path_failed': (b'/proc/',),
    'helper_base_sys_path_failed': (b'/sys/',),
    'helper_base_runtime_path_failed': (b'/run/',),
    'helper_base_engine_path_failed': (b'/tmp/larenor-jellyfin-', b'/var/lib/docker/'),
    'helper_base_host_path_failed': (b'/etc/resolv.conf', b'/etc/hostname', b'/etc/hosts'),
}
_DIAGNOSTIC_CODES = _CODES | set(_BUILD_ERROR_PATTERNS) | set(_START_ERROR_PATTERNS) | {
    'helper_base_runtime_failed', 'helper_base_error_ambiguous',
    'helper_base_state_error_ambiguous', *_STATE_ERROR_PATTERNS,
    'helper_base_path_location_ambiguous', *_PATH_LOCATION_PATTERNS,
    'helper_base_process_oom', 'helper_base_process_nonzero', 'helper_base_process_running',
    'helper_base_process_dead', 'helper_base_process_exited_zero',
    'helper_base_process_not_started', 'helper_base_process_not_started_nonzero',
    'helper_base_state_read_failed', 'helper_base_state_invalid',
    'helper_base_state_unclassified', 'helper_base_state_error_unclassified',
    'helper_base_state_status_unclassified',
    'helper_base_state_known_status_unclassified',
    'fixture_command_stderr_limit', 'helper_build_error_ambiguous',
    'invalid_image_preparation', 'invalid_image_binding',
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
    'helper_base_binding', 'helper_base_pull', 'helper_base_inspect', 'helper_base_create',
    'helper_base_created', 'helper_base_start', 'helper_base_result',
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


def _build_error(stderr):
    """Diagnostic signature only, never authority or raw Docker output."""
    folded = stderr.lower()
    matched = {code for code, patterns in _BUILD_ERROR_PATTERNS.items()
               if any(pattern in folded for pattern in patterns)}
    if len(matched) == 1:
        return matched.pop()
    return 'helper_build_error_ambiguous' if matched else 'fixture_command_exit_failed'


def _start_error(stderr):
    """Only complete nonzero stderr; a wrapper is fallback, not another cause."""
    folded = stderr.lower()
    matched = {code for code, patterns in _START_ERROR_PATTERNS.items()
               if any(pattern in folded for pattern in patterns)}
    if len(matched) == 1:
        return matched.pop()
    if matched:
        return 'helper_base_error_ambiguous'
    if any(pattern in folded for pattern in _START_RUNTIME_PATTERNS):
        return 'helper_base_runtime_failed'
    return 'fixture_command_exit_failed'


def _state_error(error):
    """Reduce a private Engine state error to a fixed non-secret family."""
    classified = _start_error(error)
    if classified != 'fixture_command_exit_failed':
        return classified
    folded = error.lower()
    matched = {code for code, patterns in _STATE_ERROR_PATTERNS.items()
               if any(pattern in folded for pattern in patterns)}
    if len(matched) == 1:
        classified = matched.pop()
        if classified == 'helper_base_path_failed':
            locations = {code for code, patterns in _PATH_LOCATION_PATTERNS.items()
                         if any(pattern in folded for pattern in patterns)}
            if len(locations) == 1:
                return locations.pop()
            if locations:
                return 'helper_base_path_location_ambiguous'
        return classified
    return 'helper_base_state_error_ambiguous' if matched else classified


def _diagnose_base_start_state(daemon, container_id, original):
    """Privately reduce one owned post-failure state read to a closed code."""
    if type(original) is not SmokeError:
        raise TypeError('exact SmokeError required')
    fallback = _error_code(original)
    def unreadable(code):
        return code if fallback == 'fixture_command_exit_failed' else fallback
    try:
        raw = daemon.docker(
            ['container','inspect','--format','{{json .State}}',container_id],
            timeout=10, limit=65536)
    except Exception:
        return unreadable('helper_base_state_read_failed')
    try:
        state = json.loads(raw)
        if type(state) is not dict:
            return unreadable('helper_base_state_invalid')
        status, exit_code, error = state.get('Status'), state.get('ExitCode'), state.get('Error')
        if (type(status) is not str or type(exit_code) is not int or type(exit_code) is bool
                or type(error) is not str
                or any(type(state.get(key)) is not bool
                    for key in ('Running','Paused','Restarting','Dead','OOMKilled'))):
            return unreadable('helper_base_state_invalid')
        error_bytes = error.encode('utf-8')
        if len(error_bytes) > 65536:
            return unreadable('helper_base_state_invalid')
    except (ValueError, TypeError, RecursionError, UnicodeError):
        return unreadable('helper_base_state_invalid')
    if error:
        classified = _state_error(error_bytes)
        if classified != 'fixture_command_exit_failed':
            return classified
    if state['OOMKilled']:
        return 'helper_base_process_oom'
    if state['Dead']:
        return 'helper_base_process_dead'
    if state['Running'] or state['Paused'] or state['Restarting'] or status == 'running':
        return 'helper_base_process_running'
    if status == 'exited' and exit_code != 0:
        return 'helper_base_process_nonzero'
    if not error and status == 'exited' and exit_code == 0:
        return 'helper_base_process_exited_zero'
    if not error and status == 'created' and exit_code == 0:
        return 'helper_base_process_not_started'
    if error:
        return unreadable('helper_base_state_error_unclassified')
    if status == 'created' and exit_code != 0:
        return 'helper_base_process_not_started_nonzero'
    if status not in {'created','restarting','running','removing','paused','exited','dead'}:
        return unreadable('helper_base_state_status_unclassified')
    return unreadable('helper_base_state_known_status_unclassified')


def bounded_command(arguments, *, environment, timeout=60, limit=65536,
                    diagnose_failure=False, diagnose_process=False, diagnose_start=False):
    """Separate process-only, private build and private attached-start diagnostics."""
    require(type(diagnose_failure) is bool and type(diagnose_process) is bool
        and type(diagnose_start) is bool and not (diagnose_failure and diagnose_start), 'fixture_command_failed')
    private_stderr = diagnose_failure or diagnose_start
    detailed_codes = private_stderr or diagnose_process
    def check(value, code):
        require(value, code if detailed_codes else 'fixture_command_failed')
    process = None
    stderr = bytearray()
    deadline = time.monotonic() + timeout
    try:
        process = subprocess.Popen(arguments, env=environment, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE if private_stderr else subprocess.DEVNULL,
            bufsize=0, start_new_session=True)
        result = bytearray()
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ, 'stdout')
            if private_stderr:
                selector.register(process.stderr, selectors.EVENT_READ, 'stderr')
            while selector.get_map():
                remaining = deadline - time.monotonic()
                check(remaining > 0, 'fixture_command_timeout')
                ready = selector.select(remaining)
                check(ready, 'fixture_command_timeout')
                for key, _ in ready:
                    buffer, bound, code = ((result, limit, 'fixture_command_output_limit')
                        if key.data == 'stdout' else (stderr, _START_STDERR_LIMIT if diagnose_start else _BUILD_STDERR_LIMIT,
                              'fixture_command_stderr_limit'))
                    chunk = os.read(key.fd, bound - len(buffer) + 1)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    buffer.extend(chunk)
                    check(len(buffer) <= bound, code)
        remaining = deadline - time.monotonic()
        check(remaining > 0, 'fixture_command_timeout')
        if process.wait(timeout=remaining) != 0:
            check(False, _start_error(stderr) if diagnose_start else
                  _build_error(stderr) if diagnose_failure else 'fixture_command_exit_failed')
        return bytes(result)
    except subprocess.TimeoutExpired:
        raise SmokeError('fixture_command_timeout' if detailed_codes else 'fixture_command_failed') from None
    except OSError:
        code = 'fixture_command_spawn_failed' if process is None else 'fixture_command_io_failed'
        raise SmokeError(code if detailed_codes else 'fixture_command_failed') from None
    finally:
        stderr.clear()
        if process is not None:
            try:
                # An exited parent can leave descendants holding its pipe open.
                # The group remains ours even when Popen.poll() has reaped it.
                _signal_group(process, signal.SIGKILL)
                process.wait(timeout=5)
            finally:
                process.stdout.close()
                if process.stderr is not None:
                    process.stderr.close()


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

    def docker(self, args, *, timeout=60, limit=65536, diagnose_failure=False, diagnose_process=False,
               diagnose_start=False):
        self._socket()
        return bounded_command(['/usr/bin/docker', '--host=unix://'+str(self.root/'engine.sock'),
            '--config='+str(self.root/'docker-config'), *args], environment=child_environment(self.root),
            timeout=timeout, limit=limit, diagnose_failure=diagnose_failure,
            diagnose_process=diagnose_process, diagnose_start=diagnose_start)

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



def _base_container(value, image_id, container_id, *, finished):
    require(type(value) is dict and value.get('Id') == container_id
        and value.get('Image') == image_id, 'fixture_protocol_failed')
    config, host, state = value.get('Config'), value.get('HostConfig'), value.get('State')
    require(all(type(v) is dict for v in (config, host, state)), 'fixture_protocol_failed')
    require(config.get('User') == '0:0'
        and config.get('Entrypoint') == ['/usr/local/bin/python']
        and config.get('Cmd') == ['-I','-c','print("larenor-helper-base-ok-v1")']
        and not config.get('Volumes') and value.get('Mounts') == []
        and host.get('NetworkMode') == 'none' and host.get('ReadonlyRootfs') is True
        and host.get('Privileged') is False and host.get('CapDrop') == ['ALL']
        and not any(host.get(k) for k in ('CapAdd','Binds','Mounts','VolumesFrom','PortBindings')),
        'fixture_protocol_failed')
    require(state.get('Status') == ('exited' if finished else 'created')
        and all(state.get(k) is False for k in ('Running','Paused','Dead','OOMKilled'))
        and type(state.get('ExitCode')) is int and state['ExitCode'] == 0,
        'fixture_protocol_failed')


def _helper_base(daemon, context, binding):
    """Isolate a minimal native process from legacy build; never a bootstrap grant.

    One probe belongs to the fresh daemon and is removed by its whole-namespace
    cleanup. A failed/uncertain create or start is never retried or adopted.
    """
    with diagnostic_phase('helper_base_binding'):
        check_source(binding)
        check_staged(context, binding)
        lines = _source_bytes(context/'server/Dockerfile.volume-bootstrap').decode('ascii').splitlines()
        bases = [line for line in lines if re.match(r'\s*FROM\s', line, re.IGNORECASE)]
        require(len(bases) == 1, 'fixture_source_changed')
        match = re.fullmatch(r'FROM (python:[0-9]+\.[0-9]+\.[0-9]+-slim-bookworm@sha256:[0-9a-f]{64})', bases[0])
        require(match is not None, 'fixture_source_changed')
        reference = match.group(1)
    with diagnostic_phase('helper_base_pull'):
        daemon.docker(['pull','--quiet','--platform='+daemon.platform,reference], timeout=180, limit=4096)
    with diagnostic_phase('helper_base_inspect'):
        value = _decoded(daemon.docker(['image','inspect','--format','{{json .}}',reference], limit=65536))
        require(type(value) is dict and type(value.get('Id')) is str
            and _HASH.fullmatch(value['Id']) and value.get('Os') == 'linux'
            and value.get('Architecture') == daemon.platform.split('/')[1], 'fixture_protocol_failed')
        config, digests = value.get('Config'), value.get('RepoDigests')
        require(type(config) is dict and not config.get('Volumes')
            and type(digests) is list and any(type(d) is str and d.endswith('@'+reference.split('@')[1])
                for d in digests), 'fixture_protocol_failed')
        image_id = value['Id']
    with diagnostic_phase('helper_base_create'):
        raw = daemon.docker(['create','--name=larenor-helper-base-probe','--pull=never','--network=none',
            '--read-only','--cap-drop=ALL','--security-opt=no-new-privileges','--user=0:0',
            '--pids-limit=32','--memory=64m','--restart=no','--entrypoint=/usr/local/bin/python',
            image_id,'-I','-c','print("larenor-helper-base-ok-v1")'], limit=128)
        container_id = raw.decode('ascii').strip()
        require(re.fullmatch(r'[0-9a-f]{64}', container_id), 'fixture_protocol_failed')
    def inspect(finished):
        value = _decoded(daemon.docker(['container','inspect','--format','{{json .}}',container_id], limit=65536))
        _base_container(value, image_id, container_id, finished=finished)
    with diagnostic_phase('helper_base_created'):
        inspect(False)
    with diagnostic_phase('helper_base_start'):
        try:
            result = daemon.docker(['start','--attach',container_id], timeout=20, limit=128,
                diagnose_process=True, diagnose_start=True)
        except SmokeError as error:
            raise SmokeError(_diagnose_base_start_state(daemon, container_id, error)) from None
        require(result == b'larenor-helper-base-ok-v1\n', 'fixture_protocol_failed')
    with diagnostic_phase('helper_base_result'):
        inspect(True)
        check_source(binding)
        check_staged(context, binding)

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
    _helper_base(daemon, context, checkout_binding)
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
