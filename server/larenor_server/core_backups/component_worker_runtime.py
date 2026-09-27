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
from ..plugins.catalog import load_catalog
from ..plugins.component_updates import (
    ComponentUpdateCommand,
    ComponentUpdateEffectResult,
    release_identity,
    verify_installed_update_source,
    verify_update_command,
)
from ..plugins.image_resources import ImagePullLimits, ImageResourceError, UnixImageEngine
from ..plugins.managed_container import ManagedWorkerJournal, managed_container_matches
from ..plugins.worker import DockerWorkerError, UnixDockerEngine
from ..plugins.volume_create_journal import VolumeCreateJournal
from .component_docker_adapter import UnixDockerComponentSnapshotAdapter
from .component_installation_authority import (
    ComponentInstallationAuthorityError,
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
from .component_update_effects import ComponentUpdateEffectJournal


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

    def __init__(self, endpoint, authority, capture, effects, *, peer_uid=None):
        if type(effects) is not ComponentUpdateEffectJournal:
            raise ComponentWorkerRuntimeError()
        self._endpoint = endpoint
        self._authority = authority
        self._capture = capture
        self._effects = effects
        self._peer_uid = peer_uid

    def update_sources(self, deadline):
        try:
            if (
                type(deadline) not in (int, float)
                or type(deadline) is bool
                or not time.monotonic() < deadline <= time.monotonic() + 5
            ):
                raise ValueError()
            return self._authority.update_sources()
        except BaseException as error:
            if isinstance(error, (KeyboardInterrupt, SystemExit)):
                raise
            raise ComponentWorkerRuntimeError("worker_unavailable") from None

    def validate_update(self, command, deadline):
        """Revalidate an exact confirmation against live receipts and pins."""
        try:
            now = time.monotonic()
            if (
                type(deadline) not in (int, float)
                or type(deadline) is bool
                or not now < deadline <= now + 5
                or type(command) is not ComponentUpdateCommand
            ):
                raise ValueError()
            command = verify_update_command(
                ComponentUpdateCommand.model_validate_json(command.model_dump_json())
            )
            wall_ms = int(time.time() * 1000)
            if not command.issuedAtMs <= wall_ms < command.expiresAtMs:
                raise ValueError()
            sources = tuple(
                verify_installed_update_source(item)
                for item in self._authority.update_sources()
            )
            matches = tuple(
                item
                for item in sources
                if item.installationId == command.installationId
                and item.current.serviceId == command.serviceId
            )
            if (
                len(matches) != 1
                or matches[0].sourceDigest != command.sourceDigest
                or matches[0].current.build.manifestDigest
                == command.targetManifestDigest
            ):
                raise ValueError()
            targets = tuple(
                entry
                for entry in load_catalog().entries
                if entry.manifest.serviceId == command.serviceId
                and entry.manifestDigest == command.targetManifestDigest
            )
            if len(targets) != 1:
                raise ValueError()
            target, _permissions, _schema = release_identity(
                targets[0], matches[0].current.platform
            )
            if target.build.manifestDigest != command.targetManifestDigest:
                raise ValueError()
            return command
        except BaseException as error:
            if isinstance(error, (KeyboardInterrupt, SystemExit)):
                raise
            raise ComponentWorkerRuntimeError("worker_unavailable") from None

    @staticmethod
    def _effect_result(command, state, code):
        return ComponentUpdateEffectResult(
            schemaVersion=1,
            updateId=command.updateId,
            installationId=command.installationId,
            serviceId=command.serviceId,
            commandDigest=command.commandDigest,
            sourceDigest=command.sourceDigest,
            targetManifestDigest=command.targetManifestDigest,
            state=state,
            code=code,
        )

    def _rollback_update(self, engine, preparation, record):
        """Best-effort exact rollback; uncertainty remains operator-visible."""
        try:
            if record.new_container_id is not None:
                new = engine.inspect_container(record.new_container_id)
                if new is not None:
                    state = new.get("State")
                    if type(state) is not dict:
                        raise DockerWorkerError()
                    if state.get("Running") is True:
                        engine.stop_container(record.new_container_id)
                    engine.remove_container(record.new_container_id)
            old = engine.inspect_container(record.old_container_id)
            if old is None or type(old.get("State")) is not dict:
                raise DockerWorkerError()
            canonical = preparation.current.installed.binding.name
            if old.get("Name") == "/larenor-retired-" + preparation.command.updateId:
                engine.restore_managed_container(record.old_container_id, canonical)
                old = engine.inspect_container(record.old_container_id)
            if old is None or old.get("Name") != "/" + canonical:
                raise DockerWorkerError()
            if old["State"].get("Running") is not True:
                engine.start_container(record.old_container_id)
                old = engine.inspect_container(record.old_container_id)
            if (
                not managed_container_matches(old, preparation.current.installed.binding)
                or old["State"].get("Running") is not True
            ):
                raise DockerWorkerError()
            with self._effects.locked():
                return self._effects.transition(
                    record.command.updateId,
                    "mutating",
                    "rolled_back",
                    new_container_id=record.new_container_id,
                )
        except BaseException as error:
            if isinstance(error, (KeyboardInterrupt, SystemExit)):
                raise
            try:
                with self._effects.locked():
                    current = self._effects.get(record.command.updateId)
                    if current is not None and current.state == "mutating":
                        self._effects.transition(
                            record.command.updateId,
                            "mutating",
                            "needs_attention",
                            new_container_id=current.new_container_id,
                        )
            except Exception:
                pass
            return None

    def execute_update(self, command, deadline):
        """Pull, replace and rollback one exact confirmed managed component."""
        try:
            now = time.monotonic()
            if (
                type(deadline) not in (int, float)
                or type(deadline) is bool
                or not now < deadline <= now + 300
            ):
                raise ValueError()
            command = verify_update_command(command)
            with self._effects.locked():
                existing = self._effects.get(command.updateId)
                if existing is not None:
                    if existing.command != command:
                        raise ValueError()
                    if existing.state == "mutating":
                        existing = self._effects.transition(
                            command.updateId,
                            "mutating",
                            "needs_attention",
                            new_container_id=existing.new_container_id,
                        )
            if existing is not None:
                if existing.state == "committed":
                    try:
                        self._authority.accept_committed_update(command)
                    except ComponentInstallationAuthorityError:
                        return self._effect_result(
                            command,
                            "needs_attention",
                            "container_state_unknown",
                        )
                    return self._effect_result(
                        command, "succeeded", "component_updated"
                    )
                if existing.state == "rolled_back":
                    return self._effect_result(
                        command, "failed", "component_update_failed"
                    )
                if existing.state == "needs_attention":
                    return self._effect_result(
                        command,
                        "needs_attention",
                        "worker_response_unknown",
                    )
            command = self.validate_update(command, min(deadline, now + 5))
            if command.rollbackSnapshotRequired:
                return self._effect_result(command, "failed", "rollback_unavailable")
            preparation = self._authority.prepare_update(command, load_catalog())
            remaining = deadline - time.monotonic()
            image_engine = UnixImageEngine(
                self._endpoint,
                limits=ImagePullLimits(
                    total_seconds=max(0.1, min(300, remaining)),
                    idle_seconds=max(0.1, min(30, remaining)),
                ),
                peer_uid=self._peer_uid,
            )
            image = image_engine.inspect(preparation.image)
            if image is None:
                image_engine.pull(preparation.image)
                image = image_engine.inspect(preparation.image)
            if image is None:
                return self._effect_result(command, "failed", "image_unavailable")
            binding = self._authority.update_binding(preparation, image)
            command = self.validate_update(
                command, min(deadline, time.monotonic() + 5)
            )
            source = (
                preparation.stack.model_dump(mode="json"),
                preparation.catalog.model_dump(mode="json"),
                preparation.policy.model_dump(mode="json"),
            )
            with self._effects.locked():
                record = self._effects.prepare(
                    command,
                    preparation.current.container_id,
                    binding,
                    source,
                )
                if record.state == "committed":
                    return self._effect_result(
                        command, "succeeded", "component_updated"
                    )
                if record.state == "rolled_back":
                    return self._effect_result(
                        command, "failed", "component_update_failed"
                    )
                if record.state != "prepared":
                    if record.state == "mutating":
                        self._effects.transition(
                            command.updateId,
                            "mutating",
                            "needs_attention",
                            new_container_id=record.new_container_id,
                        )
                    return self._effect_result(
                        command, "needs_attention", "worker_response_unknown"
                    )
                record = self._effects.transition(
                    command.updateId, "prepared", "mutating"
                )
            engine = UnixDockerEngine(
                self._endpoint.path,
                timeout=min(30, max(0.1, deadline - time.monotonic())),
                socket_uid=self._endpoint.owner_uid,
                peer_uid=self._peer_uid,
            )
            try:
                old = engine.inspect_container(record.old_container_id)
                if (
                    not managed_container_matches(
                        old, preparation.current.installed.binding
                    )
                    or old["State"].get("Running") is not True
                ):
                    raise DockerWorkerError()
                engine.stop_container(record.old_container_id)
                engine.rename_managed_container(
                    record.old_container_id,
                    "larenor-retired-" + command.updateId,
                )
                new_container_id = engine.create_managed_container(binding)
                with self._effects.locked():
                    record = self._effects.transition(
                        command.updateId,
                        "mutating",
                        "mutating",
                        new_container_id=new_container_id,
                    )
                engine.start_container(new_container_id)
                observed = engine.inspect_container(new_container_id)
                if (
                    not managed_container_matches(observed, binding)
                    or observed["State"].get("Running") is not True
                ):
                    raise DockerWorkerError()
                with self._effects.locked():
                    self._effects.transition(
                        command.updateId,
                        "mutating",
                        "committed",
                        new_container_id=new_container_id,
                    )
                try:
                    self._authority.accept_committed_update(command)
                except ComponentInstallationAuthorityError:
                    return self._effect_result(
                        command, "needs_attention", "container_state_unknown"
                    )
                return self._effect_result(command, "succeeded", "component_updated")
            except BaseException as error:
                if isinstance(error, (KeyboardInterrupt, SystemExit)):
                    raise
                rolled_back = self._rollback_update(engine, preparation, record)
                return self._effect_result(
                    command,
                    "failed" if rolled_back is not None else "needs_attention",
                    (
                        "component_update_failed"
                        if rolled_back is not None
                        else "rollback_required"
                    ),
                )
        except ImageResourceError:
            return self._effect_result(command, "failed", "image_unavailable")
        except ComponentInstallationAuthorityError:
            return self._effect_result(
                command, "needs_attention", "container_state_unknown"
            )
        except BaseException as error:
            if isinstance(error, (KeyboardInterrupt, SystemExit)):
                raise
            try:
                command = verify_update_command(command)
                return self._effect_result(
                    command, "needs_attention", "container_state_unknown"
                )
            except Exception:
                raise ComponentWorkerRuntimeError("worker_unavailable") from None

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
        effects = resources.enter_context(
            ComponentUpdateEffectJournal(config.container_journal)
        )
        volumes = resources.enter_context(VolumeCreateJournal(config.volume_journal))
        authority = DurableComponentInstallationAuthority(
            containers, volumes, effects
        )
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
            effects,
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
