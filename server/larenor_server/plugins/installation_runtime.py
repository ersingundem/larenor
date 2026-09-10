"""Internal Linux entry point for the bounded Larenor installation worker.

The API process receives only this worker's Unix socket.  Docker access,
resource journals, the managed-container journal and the exact bootstrap helper
remain private to this process.  The policy is operator-owned and has no
environment-variable or Client override for Docker operations.
"""

import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import signal
import stat
import sys
import threading

from ..errors import StartupError
from ..files import checked_path, private_read
from .catalog import load_catalog
from .docker_probe import DockerEndpoint
from .host_preflight import _host_platform
from .installation_execution import JellyfinWorkerBackend
from .installation_ipc import InstallationWorkerServer
from .installation_supervisor import RetainedDaemonPeerVerifier, SupervisedInstallationBackend
from .jellyfin_bootstrap_executor import JellyfinBootstrapExecutor
from .jellyfin_startup import JellyfinStartupConfigurator
from .jellyfin_authenticated_readback import JellyfinAuthenticatedReadback
from .jellyfin_managed_libraries import JellyfinManagedLibraries
from .qbittorrent_config_runtime import QbittorrentConfigRuntime
from .managed_container import (
    JellyfinBindingBuilder,
    JellyfinEngineReaders,
    JellyfinResourceProofBroker,
    JournaledManagedContainerOperations,
    ManagedWorkerJournal,
)
from .resource_journal import ResourceJournal
from .resource_models import WorkerPolicyBinding
from .volume_bootstrap import VolumeBootstrapVerifier
from .volume_create_journal import VolumeCreateJournal
from .worker import UnixDockerEngine, _safe_path


MAX_POLICY_BYTES = 32768
_IMAGE_ID = re.compile(r'sha256:[0-9a-f]{64}\Z')


class _ConfigurationError(ValueError):
    pass


class _ParserExit(Exception):
    def __init__(self, status):
        self.status = status


class _Parser(argparse.ArgumentParser):
    def error(self, _message):
        raise _ConfigurationError()

    def exit(self, status=0, message=None):
        raise _ParserExit(status)


def _uid(value):
    if not re.fullmatch(r'[0-9]{1,10}', value) or int(value) > 2**31 - 1:
        raise _ConfigurationError()
    return int(value)


def _pairs(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise _ConfigurationError()
        value[key] = item
    return value


def _reject_number(_value):
    raise _ConfigurationError()


def _private_path(value):
    if type(value) is not str:
        raise _ConfigurationError()
    result = Path(value)
    if (not result.is_absolute() or '..' in result.parts or len(value.encode('utf-8')) > 4096
            or any(ord(char) < 32 or ord(char) == 127 for char in value)):
        raise _ConfigurationError()
    checked_path(result)
    return result


@dataclass(frozen=True, repr=False)
class InstallationRuntimePolicy:
    platform: str
    endpoint: DockerEndpoint
    worker_policy: WorkerPolicyBinding
    helper_image_id: str
    resource_journal: Path
    volume_journal: Path
    container_journal: Path

    def __repr__(self):
        return 'InstallationRuntimePolicy(<private>)'


def load_policy(path):
    """Validate the private policy without opening a journal or Docker socket."""
    invalid = False
    result = None
    try:
        source = checked_path(Path(path))
        _safe_path(source, uid=os.geteuid(), kind=stat.S_ISREG, private=True)
        raw = private_read(source, MAX_POLICY_BYTES)
        value = json.loads(
            raw.decode('utf-8'),
            object_pairs_hook=_pairs,
            parse_float=_reject_number,
            parse_constant=_reject_number,
        )
        if (type(value) is not dict
                or set(value) != {'version', 'platform', 'docker', 'workerPolicy',
                                  'bootstrap', 'journals'}
                or type(value['version']) is not int or value['version'] != 1
                or value['platform'] not in {'linux/amd64', 'linux/arm64'}):
            raise _ConfigurationError()
        docker = value['docker']
        if type(docker) is not dict or set(docker) != {
                'socketPath', 'ownerUid', 'daemonExecutable'}:
            raise _ConfigurationError()
        endpoint = DockerEndpoint(
            path=docker['socketPath'],
            owner_uid=docker['ownerUid'],
            daemon_executable=docker['daemonExecutable'],
        )
        worker_policy = WorkerPolicyBinding.model_validate(value['workerPolicy'])
        bootstrap = value['bootstrap']
        if (type(bootstrap) is not dict or set(bootstrap) != {'imageId'}
                or type(bootstrap['imageId']) is not str
                or _IMAGE_ID.fullmatch(bootstrap['imageId']) is None):
            raise _ConfigurationError()
        journals = value['journals']
        if type(journals) is not dict or set(journals) != {
                'resources', 'volumes', 'containers'}:
            raise _ConfigurationError()
        paths = tuple(_private_path(journals[name]) for name in (
            'resources', 'volumes', 'containers'))
        if (len(set(paths)) != 3
                or any(left in right.parents or right in left.parents
                       for index, left in enumerate(paths)
                       for right in paths[index + 1:])):
            raise _ConfigurationError()
        result = InstallationRuntimePolicy(
            value['platform'], endpoint, worker_policy, bootstrap['imageId'], *paths,
        )
    except Exception:
        invalid = True
    if invalid or type(result) is not InstallationRuntimePolicy:
        raise _ConfigurationError()
    return result


class _RuntimeBindingBuilder:
    """Recreate a plan-bound proof broker for every IPC worker request."""

    def __init__(self, policy, catalog, resources, volumes, container, readers):
        self._policy = policy
        self._catalog = catalog
        self._resource_journal = resources
        self._volume_journal = volumes
        self._container_journal = container
        self._readers = readers
        self._endpoint = readers._endpoint

    def __call__(self, stack):
        broker = JellyfinResourceProofBroker(
            stack,
            self._catalog,
            self._policy,
            self._resource_journal,
            self._volume_journal,
            self._readers,
            engine_identity=self._endpoint,
        )
        return JellyfinBindingBuilder(
            self._catalog,
            self._policy,
            self._container_journal.identity,
            broker,
        )(stack)


class _InstallationRuntime:
    def __init__(self, backend, resources, volumes, containers):
        self.backend = backend
        self._journals = (containers, volumes, resources)
        self.closed = False

    def close(self):
        if self.closed:
            return
        self.closed = True
        failed = False
        for journal in self._journals:
            try:
                journal.close()
            except Exception:
                failed = True
        if failed:
            raise RuntimeError('worker_unavailable')


class _RuntimeBackend:
    """One journal/binding authority for installation and private bootstrap."""

    def __init__(self, operations, binding_builder, qbittorrent_config):
        self.operations = operations
        self.binding_builder = binding_builder
        self.qbittorrent_config = qbittorrent_config
        self.installation = JellyfinWorkerBackend(operations, binding_builder)
        self.bootstrap_executor = JellyfinBootstrapExecutor(
            operations, binding_builder, JellyfinStartupConfigurator(),
            JellyfinAuthenticatedReadback(), JellyfinManagedLibraries())

    def apply(self, step, plan):
        return self.installation.apply(step, plan)

    def reconcile(self, step, plan):
        return self.installation.reconcile(step, plan)

    def bootstrap(self, job, plan, private, *, deadline, gate):
        return self.bootstrap_executor.execute(
            job, plan, private, deadline=deadline, gate=gate)

    def configure_qbittorrent(self, job, stack, credential, *, api_key, salt,
                              cancelled, deadline, gate):
        if type(job) is not str or re.fullmatch(r'[0-9a-f]{32}', job) is None:
            raise ValueError('invalid_worker_result')
        return self.qbittorrent_config.install(
            stack, credential, api_key=api_key, salt=salt,
            cancelled=cancelled, before_dispatch=gate,
        )


def _build_runtime(policy, *, peer_uid=None):
    journals = []
    try:
        resources = ResourceJournal(policy.resource_journal)
        journals.append(resources)
        volumes = VolumeCreateJournal(policy.volume_journal)
        journals.append(volumes)
        containers = ManagedWorkerJournal(policy.container_journal)
        journals.append(containers)
        bootstrap = VolumeBootstrapVerifier(
            policy.endpoint,
            policy.helper_image_id,
            policy.platform,
            peer_uid=peer_uid,
        )
        readers = JellyfinEngineReaders(policy.endpoint, bootstrap, peer_uid=peer_uid)
        catalog = load_catalog()
        builder = _RuntimeBindingBuilder(
            policy.worker_policy,
            catalog,
            resources,
            volumes,
            containers,
            readers,
        )
        engine = UnixDockerEngine(
            policy.endpoint.path,
            socket_uid=policy.endpoint.owner_uid,
            peer_uid=peer_uid,
        )
        operations = JournaledManagedContainerOperations(containers, engine)
        qbittorrent_config = QbittorrentConfigRuntime(
            policy.endpoint, volumes, catalog, policy.worker_policy,
            policy.helper_image_id, policy.platform, peer_uid=peer_uid,
        )
        return _InstallationRuntime(
            _RuntimeBackend(operations, builder, qbittorrent_config),
            resources,
            volumes,
            containers,
        )
    except Exception:
        for journal in reversed(journals):
            try:
                journal.close()
            except Exception:
                pass
        raise _ConfigurationError() from None


def _serve(args, policy):
    stopped = threading.Event()
    previous = {}
    built = None
    worker = None
    failed = False

    def stop(_number, _frame):
        stopped.set()

    try:
        for number in (signal.SIGINT, signal.SIGTERM):
            previous[number] = signal.getsignal(number)
            signal.signal(number, stop)
        peer_verifier = RetainedDaemonPeerVerifier(policy.endpoint)
        built = _build_runtime(policy, peer_uid=peer_verifier)
        worker = InstallationWorkerServer(
            args.socket,
            SupervisedInstallationBackend(
                policy.endpoint, built.backend, platform=policy.platform,
                peer_verifier=peer_verifier,
            ),
            allowed_uid=args.api_uid,
            socket_gid=args.socket_gid,
        )
        worker.start()
        stopped.wait()
    except Exception:
        failed = True
    finally:
        if worker is not None:
            try:
                worker.close()
            except Exception:
                failed = True
        if built is not None:
            try:
                built.close()
            except Exception:
                failed = True
        for number, handler in previous.items():
            try:
                signal.signal(number, handler)
            except Exception:
                failed = True
    return 1 if failed else 0


def main(argv=None) -> int:
    parser = _Parser(prog='larenor-installation-worker', description=__doc__)
    parser.add_argument('--policy', required=True, type=Path)
    parser.add_argument('--socket', required=True, type=Path)
    parser.add_argument('--api-uid', required=True, type=_uid)
    parser.add_argument('--socket-gid', type=_uid)
    parser.add_argument(
        '--check-config',
        action='store_true',
        help='Validate private policy only; never open journals, Docker or a socket',
    )
    try:
        args = parser.parse_args(argv)
        checked_path(args.policy)
        checked_path(args.socket)
        if (os.getuid() != os.geteuid()
                or args.api_uid != os.getuid() and args.socket_gid is None):
            raise _ConfigurationError()
    except _ParserExit as result:
        return result.status
    except (ValueError, StartupError, OSError):
        print('invalid_arguments', file=sys.stderr)
        return 2
    try:
        policy = load_policy(args.policy)
        if _host_platform() != policy.platform:
            raise _ConfigurationError()
    except Exception:
        print('worker_configuration_invalid', file=sys.stderr)
        return 1
    socket_path = args.socket.absolute()
    journal_paths = (
        policy.resource_journal, policy.volume_journal, policy.container_journal,
    )
    if (socket_path == Path(policy.endpoint.path)
            or any(socket_path == path or path in socket_path.parents
                   for path in journal_paths)):
        print('invalid_arguments', file=sys.stderr)
        return 2
    if args.check_config:
        return 0
    status = _serve(args, policy)
    if status:
        print('worker_unavailable', file=sys.stderr)
    return status


if __name__ == '__main__':
    raise SystemExit(main())
