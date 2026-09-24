"""Packaged privileged worker for isolated component backup snapshots."""

import argparse
from contextlib import ExitStack, contextmanager
from dataclasses import dataclass
import os
from pathlib import Path
import platform
import re
import signal
import sys
import time

from ..plugins.docker_probe import DockerEndpoint
from ..plugins.managed_container import ManagedWorkerJournal
from ..plugins.volume_create_journal import VolumeCreateJournal
from .component_docker_adapter import UnixDockerComponentSnapshotAdapter
from .component_installation_authority import (
    DurableComponentInstallationAuthority,
)
from .component_isolated_capture import (
    BtrfsReadOnlySnapshotBackend,
    LinuxCowCaptureEngine,
)
from .component_linux_capture_preflight import (
    LinuxBtrfsCaptureCapability,
    LinuxBtrfsCapturePreflight,
)
from .component_worker_server import ComponentSnapshotWorkerServer


class ComponentWorkerRuntimeError(RuntimeError):
    """Static packaged-worker failure without host paths or journal details."""

    def __init__(self, code="worker_configuration_invalid"):
        self.code = (
            code
            if code in {"worker_configuration_invalid", "worker_unavailable"}
            else "worker_unavailable"
        )
        super().__init__(self.code)


def _absolute(value):
    if not isinstance(value, Path):
        raise ComponentWorkerRuntimeError()
    raw = str(value)
    if (
        not value.is_absolute()
        or ".." in value.parts
        or value == Path("/")
        or len(raw.encode("utf-8", "strict")) > 4096
        or any(ord(char) < 32 or ord(char) == 127 for char in raw)
    ):
        raise ComponentWorkerRuntimeError()
    return value


@dataclass(frozen=True)
class ComponentWorkerRuntimeConfig:
    socket_path: Path
    container_journal: Path
    volume_journal: Path
    engine_socket: Path
    capture_root: Path
    capture_journal: Path
    api_uid: int
    socket_gid: int | None
    engine_uid: int = 0

    def __post_init__(self):
        try:
            paths = tuple(
                _absolute(getattr(self, name))
                for name in (
                    "socket_path",
                    "container_journal",
                    "volume_journal",
                    "engine_socket",
                    "capture_root",
                    "capture_journal",
                )
            )
            if (
                len(paths) != len(set(paths))
                or self.capture_journal.is_relative_to(self.capture_root)
                or self.capture_root.is_relative_to(self.capture_journal)
                or any(
                    type(value) is not int or not 0 <= value < 2**31
                    for value in (self.api_uid, self.engine_uid)
                )
                or self.socket_gid is not None
                and (
                    type(self.socket_gid) is not int or not 0 <= self.socket_gid < 2**31
                )
            ):
                raise ValueError()
        except Exception:
            raise ComponentWorkerRuntimeError() from None


class PackagedComponentSnapshotBoundary:
    """Build one exact Docker/provider generation for each worker request."""

    def __init__(self, endpoint, authority, capture, *, peer_uid=None):
        self._endpoint = endpoint
        self._authority = authority
        self._capture = capture
        self._peer_uid = peer_uid

    @contextmanager
    def quiesce(self, deadline):
        try:
            adapter = UnixDockerComponentSnapshotAdapter(
                self._endpoint,
                self._authority,
                peer_uid=self._peer_uid,
                capture_engine=self._capture,
            )
            provider = adapter.provider(deadline)
            with provider.quiesce(deadline) as snapshots:
                yield snapshots
        except BaseException as error:
            if isinstance(error, (KeyboardInterrupt, SystemExit)):
                raise
            raise ComponentWorkerRuntimeError("worker_unavailable") from None


@dataclass
class ComponentWorkerRuntime:
    server: ComponentSnapshotWorkerServer
    provider: PackagedComponentSnapshotBoundary
    capture: LinuxCowCaptureEngine
    capture_capability: LinuxBtrfsCaptureCapability | None
    _resources: ExitStack

    def close(self):
        try:
            self.server.close()
        finally:
            self._resources.close()

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.close()


def build_runtime(
    config,
    *,
    backend=None,
    capture_preflight=None,
    require_privileged=True,
    docker_peer_uid=None,
    worker_peer_uid=None,
):
    """Compose journals, Docker authority, COW engine and private IPC server."""
    if type(config) is not ComponentWorkerRuntimeConfig:
        raise ComponentWorkerRuntimeError()
    if require_privileged is not True and require_privileged is not False:
        raise ComponentWorkerRuntimeError()
    if require_privileged and os.geteuid() != 0:
        raise ComponentWorkerRuntimeError()
    if capture_preflight is not None and not callable(
        getattr(capture_preflight, "verify", None)
    ):
        raise ComponentWorkerRuntimeError()
    resources = ExitStack()
    try:
        preflight = capture_preflight
        if preflight is None and require_privileged:
            preflight = LinuxBtrfsCapturePreflight(config.capture_root)
        capability = None
        if preflight is not None:
            capability = preflight.verify(time.monotonic() + 5)
            if type(capability) is not LinuxBtrfsCaptureCapability:
                raise ComponentWorkerRuntimeError()
            close_preflight = getattr(preflight, "close", None)
            if callable(close_preflight):
                resources.callback(close_preflight)
        containers = resources.enter_context(
            ManagedWorkerJournal(config.container_journal)
        )
        volumes = resources.enter_context(VolumeCreateJournal(config.volume_journal))
        authority = DurableComponentInstallationAuthority(containers, volumes)
        capture = LinuxCowCaptureEngine(
            config.capture_root,
            config.capture_journal,
            backend=backend,
            capability_preflight=preflight,
            capture_capability=capability,
        )
        capture.recover(time.monotonic() + 5)
        endpoint = DockerEndpoint(
            str(config.engine_socket), owner_uid=config.engine_uid
        )
        provider = PackagedComponentSnapshotBoundary(
            endpoint,
            authority,
            capture,
            peer_uid=docker_peer_uid,
        )
        server = ComponentSnapshotWorkerServer(
            config.socket_path,
            provider,
            owner_uid=os.geteuid(),
            client_uid=config.api_uid,
            socket_gid=config.socket_gid,
            peer_uid=worker_peer_uid,
        )
        return ComponentWorkerRuntime(
            server, provider, capture, capability, resources
        )
    except Exception:
        resources.close()
        raise ComponentWorkerRuntimeError() from None


def _platform():
    if not sys.platform.startswith("linux"):
        return "unsupported"
    machine = platform.machine().lower()
    if machine in {"x86_64", "amd64"}:
        return "linux/amd64"
    if machine in {"aarch64", "arm64"}:
        return "linux/arm64"
    return "unsupported"


def _uid(value):
    if type(value) is not str or re.fullmatch(r"[0-9]{1,10}", value) is None:
        raise argparse.ArgumentTypeError("invalid")
    result = int(value)
    if result >= 2**31:
        raise argparse.ArgumentTypeError("invalid")
    return result


class _Parser(argparse.ArgumentParser):
    def error(self, _message):
        raise ComponentWorkerRuntimeError()


def _configuration(args):
    required = (
        args.socket,
        args.container_journal,
        args.volume_journal,
        args.engine_socket,
        args.capture_root,
        args.capture_journal,
        args.api_uid,
    )
    if any(value is None for value in required):
        raise ComponentWorkerRuntimeError()
    return ComponentWorkerRuntimeConfig(
        socket_path=args.socket,
        container_journal=args.container_journal,
        volume_journal=args.volume_journal,
        engine_socket=args.engine_socket,
        capture_root=args.capture_root,
        capture_journal=args.capture_journal,
        api_uid=args.api_uid,
        socket_gid=args.socket_gid,
        engine_uid=args.engine_uid,
    )


def main(argv=None):
    parser = _Parser(prog="larenor-component-backup-worker", description=__doc__)
    parser.add_argument("--socket", type=Path)
    parser.add_argument("--container-journal", type=Path)
    parser.add_argument("--volume-journal", type=Path)
    parser.add_argument("--engine-socket", type=Path)
    parser.add_argument("--capture-root", type=Path)
    parser.add_argument("--capture-journal", type=Path)
    parser.add_argument("--api-uid", type=_uid)
    parser.add_argument("--socket-gid", type=_uid)
    parser.add_argument("--engine-uid", type=_uid, default=0)
    parser.add_argument("--btrfs", type=Path, default=Path("/usr/bin/btrfs"))
    parser.add_argument("--check-platform", action="store_true")
    parser.add_argument("--check-config", action="store_true")
    try:
        args = parser.parse_args(argv)
        if _platform() not in {"linux/amd64", "linux/arm64"}:
            raise ComponentWorkerRuntimeError()
        if args.check_platform:
            return 0
        config = _configuration(args)
        backend = BtrfsReadOnlySnapshotBackend(args.btrfs)
        runtime = build_runtime(config, backend=backend)
        if args.check_config:
            runtime.close()
            return 0
    except Exception:
        print("worker_configuration_invalid", file=sys.stderr)
        return 2

    previous = {}

    def stop(_number, _frame):
        runtime.server.close()

    result = 0
    try:
        for number in (signal.SIGINT, signal.SIGTERM):
            previous[number] = signal.getsignal(number)
            signal.signal(number, stop)
        runtime.server.serve_forever()
    except Exception:
        result = 1
    finally:
        runtime.close()
        for number, handler in previous.items():
            try:
                signal.signal(number, handler)
            except Exception:
                result = 1
    if result:
        print("worker_unavailable", file=sys.stderr)
    return result


if __name__ == "__main__":
    raise SystemExit(main())
