"""Packaged privileged component snapshot worker composition."""

import os
from pathlib import Path
import time
from contextlib import contextmanager

import pytest

from larenor_server.core_backups.component_worker_runtime import (
    ComponentWorkerRuntimeConfig,
    ComponentWorkerRuntimeError,
    build_runtime,
    main,
)
from larenor_server.core_backups.component_linux_capture_preflight import (
    LinuxBtrfsCaptureCapability,
)
from larenor_server.plugins.managed_container import ManagedWorkerJournal
from larenor_server.plugins.volume_create_journal import VolumeCreateJournal


class Backend:
    def __init__(self):
        self.recovered = False

    def create_read_only(self, source, destination, deadline):
        raise AssertionError("not dispatched during composition")

    def is_read_only(self, destination, deadline):
        return True

    def delete(self, destination, deadline):
        self.recovered = True


class CapturePreflight:
    def __init__(self):
        self.calls = []
        self.closed = False
        self.capability = LinuxBtrfsCaptureCapability(
            1, 11, 12, 13, 14, 15, 16, 17
        )

    def verify(self, deadline):
        assert time.monotonic() < deadline
        self.calls.append("verify")
        return self.capability

    def revalidate(self, capability, deadline):
        assert time.monotonic() < deadline
        return capability is self.capability

    def source_retained(self, *_args):
        return True

    @contextmanager
    def retain_source(self, *_args):
        yield

    def close(self):
        self.closed = True


def initialized_journals(tmp_path):
    containers = tmp_path / "containers"
    volumes = tmp_path / "volumes"
    with (
        ManagedWorkerJournal(containers, initialize=True),
        VolumeCreateJournal(volumes, initialize=True),
    ):
        pass
    return containers, volumes


def config(tmp_path, runtime):
    containers, volumes = initialized_journals(tmp_path)
    runtime.mkdir(mode=0o700)
    captures = tmp_path / "captures"
    captures.mkdir(mode=0o700)
    engine_socket = Path("/tmp") / f"engine-{os.getpid()}-{tmp_path.name}.sock"
    return ComponentWorkerRuntimeConfig(
        socket_path=runtime / "component.sock",
        container_journal=containers,
        volume_journal=volumes,
        engine_socket=engine_socket,
        capture_root=captures,
        capture_journal=tmp_path / "capture-journal.json",
        api_uid=os.getuid(),
        socket_gid=None,
        engine_uid=os.getuid(),
    )


@pytest.fixture
def selected_config(tmp_path):
    temporary_root = Path("/private/tmp")
    if not temporary_root.is_dir():
        temporary_root = Path("/tmp")
    runtime = temporary_root / f"larenor-worker-{os.getpid()}-{tmp_path.name}"
    selected = config(tmp_path, runtime)
    yield selected
    runtime.rmdir()


def test_runtime_composes_durable_authority_docker_adapter_and_capture(selected_config):
    selected = selected_config
    preflight = CapturePreflight()
    with build_runtime(
        selected,
        backend=Backend(),
        capture_preflight=preflight,
        require_privileged=False,
        docker_peer_uid=lambda _connection: os.getuid(),
        worker_peer_uid=lambda _connection: os.getuid(),
    ) as runtime:
        assert runtime.server.provider is runtime.provider
        assert runtime.server.client_uid == os.getuid()
        assert runtime.server.path == selected.socket_path
        assert runtime.capture_capability is preflight.capability
        assert preflight.closed is False
    assert preflight.calls == ["verify"]
    assert preflight.closed is True


def test_runtime_rejects_non_exact_capture_capability(selected_config):
    class MalformedPreflight:
        @staticmethod
        def verify(_deadline):
            return None

    with pytest.raises(
        ComponentWorkerRuntimeError, match="worker_configuration_invalid"
    ):
        with build_runtime(
            selected_config,
            backend=Backend(),
            capture_preflight=MalformedPreflight(),
            require_privileged=False,
            docker_peer_uid=lambda _connection: os.getuid(),
            worker_peer_uid=lambda _connection: os.getuid(),
        ):
            raise AssertionError("malformed capability must not compose")


@pytest.mark.parametrize(
    "damage",
    ["relative", "same_journals", "journal_inside_capture", "bool_uid"],
)
def test_runtime_configuration_is_exact_and_fail_closed(selected_config, damage):
    selected = selected_config
    values = vars(selected).copy()
    if damage == "relative":
        values["engine_socket"] = Path("engine.sock")
    elif damage == "same_journals":
        values["volume_journal"] = selected.container_journal
    elif damage == "journal_inside_capture":
        values["capture_journal"] = selected.capture_root / "journal.json"
    else:
        values["api_uid"] = True
    with pytest.raises(
        ComponentWorkerRuntimeError, match="worker_configuration_invalid"
    ):
        ComponentWorkerRuntimeConfig(**values)


def test_packaged_entrypoint_rejects_unsupported_platform_without_paths(
    capsys, monkeypatch
):
    monkeypatch.setattr(
        "larenor_server.core_backups.component_worker_runtime._platform",
        lambda: "unsupported",
    )
    assert main(["--check-platform"]) == 2
    assert capsys.readouterr().err.strip() == "worker_configuration_invalid"


def test_package_exposes_component_backup_worker_entrypoint():
    project = Path(__file__).parents[1] / "pyproject.toml"
    assert (
        "larenor-component-backup-worker = "
        '"larenor_server.core_backups.component_worker_runtime:main"'
    ) in project.read_text()
