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
        'DOCKER_API_VERSION': '1.47', 'LANG': 'C.UTF-8'}


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
        'dockerfileSha256': digest('server/Dockerfile.volume-bootstrap')}


def main(arguments=None):
    args = sys.argv[1:] if arguments is None else arguments
    if args != ['--run-ephemeral-ci']:
        print('explicit_ephemeral_ci_flag_required', file=sys.stderr)
        return 2
    try:
        # This first boundary checkpoint is fail-closed until its complete
        # characterization consumer is supplied in the next runtime RED.
        require('characterize' in globals(), 'fixture_protocol_not_implemented')
        with EphemeralDaemon() as daemon:
            result = characterize(daemon)
        print(json.dumps(result, sort_keys=True, separators=(',', ':')))
        return 0
    except SmokeError as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
