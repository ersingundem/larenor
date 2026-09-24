"""Explicit offline composition for privileged managed-component restores."""

import os
import time
from contextlib import ExitStack
from dataclasses import dataclass
from pathlib import Path

from ..files import private_read
from ..plugins.docker_probe import DockerEndpoint
from ..plugins.managed_container import ManagedWorkerJournal
from ..plugins.volume_create_journal import VolumeCreateJournal
from .component_docker_adapter import UnixDockerComponentSnapshotAdapter
from .component_installation_authority import DurableComponentInstallationAuthority
from .component_linux_restore import (
    DurableComponentRestoreAuthority,
    LinuxComponentRestoreBoundary,
    LinuxDirectoryRestoreEngine,
)
from .component_restore import ComponentRestorePlanError, plan_component_restore
from .component_restore_recovery import (
    ComponentRestoreRecoveryJournal,
    DurableComponentRestoreCoordinator,
)


class ComponentRestoreRuntimeError(RuntimeError):
    """Static operator-facing failure without paths or daemon details."""

    def __init__(self):
        super().__init__("component_restore_unavailable")


def _absolute(value):
    try:
        raw = str(value)
        if (
            not isinstance(value, Path)
            or not value.is_absolute()
            or value == Path("/")
            or ".." in value.parts
            or not 1 <= len(raw.encode("utf-8", "strict")) <= 4096
            or any(ord(char) < 32 or ord(char) == 127 for char in raw)
        ):
            raise ValueError()
        return value
    except Exception:  # noqa: BLE001 - collapse private path/parser details
        raise ComponentRestoreRuntimeError() from None


@dataclass(frozen=True)
class ComponentRestoreRuntimeConfig:
    """Private operator-owned paths; no value is accepted from a backup."""

    container_journal: Path
    volume_journal: Path
    engine_socket: Path
    recovery_journal: Path
    recovery_key_file: Path
    engine_uid: int = 0

    def __post_init__(self):
        try:
            paths = tuple(
                _absolute(getattr(self, name))
                for name in (
                    "container_journal",
                    "volume_journal",
                    "engine_socket",
                    "recovery_journal",
                    "recovery_key_file",
                )
            )
            if (
                len(paths) != len(set(paths))
                or type(self.engine_uid) is not int
                or not 0 <= self.engine_uid < 2**31
            ):
                raise ValueError()
        except ComponentRestoreRuntimeError:
            raise
        except Exception:  # noqa: BLE001 - expose one static operator error
            raise ComponentRestoreRuntimeError() from None


@dataclass
class ComponentRestoreRuntime:
    """One retained authority/controller generation for one offline invocation."""

    config: ComponentRestoreRuntimeConfig
    authority: DurableComponentRestoreAuthority
    boundary: LinuxComponentRestoreBoundary
    journal: ComponentRestoreRecoveryJournal
    coordinator: DurableComponentRestoreCoordinator
    _resources: ExitStack
    _monotonic: object = time.monotonic

    def __repr__(self):
        return "ComponentRestoreRuntime(<private>)"

    def plan(self, capture):
        return plan_component_restore(capture, self.authority)

    def _selected_coordinator(self, checkpoint):
        if checkpoint is None:
            return self.coordinator
        if not callable(checkpoint):
            raise ComponentRestorePlanError()
        return DurableComponentRestoreCoordinator(
            self.journal,
            self.boundary,
            monotonic=self._monotonic,
            checkpoint=checkpoint,
        )

    def restore(self, capture, *, deadline, checkpoint=None):
        plan = self.plan(capture)
        return self._selected_coordinator(checkpoint).restore(
            capture, plan, deadline=deadline
        )

    def recover(self, capture, *, deadline, checkpoint=None):
        plan = self.plan(capture)
        return self._selected_coordinator(checkpoint).recover(plan, deadline=deadline)

    def close(self):
        self._resources.close()

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.close()


def build_component_restore_runtime(
    config,
    *,
    require_privileged=True,
    docker_peer_uid=None,
    system=None,
    monotonic=None,
    checkpoint=None,
):
    """Compose the production boundary only in an explicit privileged process."""

    if (
        type(config) is not ComponentRestoreRuntimeConfig
        or type(require_privileged) is not bool
        or require_privileged
        and os.geteuid() != 0
    ):
        raise ComponentRestoreRuntimeError()
    resources = ExitStack()
    try:
        key = private_read(config.recovery_key_file, 32)
        if len(key) != 32:
            raise ValueError()
        containers = resources.enter_context(
            ManagedWorkerJournal(config.container_journal)
        )
        volumes = resources.enter_context(VolumeCreateJournal(config.volume_journal))
        installed = DurableComponentInstallationAuthority(containers, volumes)
        authority = DurableComponentRestoreAuthority(installed)
        endpoint = DockerEndpoint(
            str(config.engine_socket), owner_uid=config.engine_uid
        )
        controller = UnixDockerComponentSnapshotAdapter(
            endpoint,
            installed,
            peer_uid=docker_peer_uid,
        )
        engine = LinuxDirectoryRestoreEngine(system=system)
        boundary = LinuxComponentRestoreBoundary(
            authority,
            controller,
            engine,
            enabled=True,
        )
        journal = ComponentRestoreRecoveryJournal(config.recovery_journal, key)
        selected_monotonic = time.monotonic if monotonic is None else monotonic
        coordinator = DurableComponentRestoreCoordinator(
            journal,
            boundary,
            monotonic=selected_monotonic,
            checkpoint=checkpoint,
        )
        return ComponentRestoreRuntime(
            config,
            authority,
            boundary,
            journal,
            coordinator,
            resources,
            selected_monotonic,
        )
    except ComponentRestoreRuntimeError:
        resources.close()
        raise
    except Exception:  # noqa: BLE001 - close all retained resources fail-closed
        resources.close()
        raise ComponentRestoreRuntimeError() from None
