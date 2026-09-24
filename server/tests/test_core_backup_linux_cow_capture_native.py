"""Root-only acceptance for the packaged Linux btrfs capture primitive."""

import os
from pathlib import Path
import subprocess
import sys
import time

import pytest

from larenor_server.core_backups.component_isolated_capture import (
    BtrfsReadOnlySnapshotBackend,
    LinuxCowCaptureEngine,
)
from larenor_server.core_backups.component_linux_capture_preflight import (
    CAP_SYS_ADMIN,
    LinuxBtrfsCapturePreflight,
    LinuxCaptureSystem,
)
from larenor_server.core_backups.component_snapshot_provider import (
    ComponentVolumeSource,
)
from larenor_server.plugins.managed_container import ManagedWorkerJournal
from larenor_server.plugins.volume_create_journal import VolumeCreateJournal

pytestmark = pytest.mark.skipif(
    "LARENOR_NATIVE_CAPTURE_ROOT" not in os.environ,
    reason="requires the owned native btrfs workflow fixture",
)


def _run(*arguments):
    subprocess.run(arguments, check=True, stdin=subprocess.DEVNULL)


class _InterruptAfterSnapshot:
    def __init__(self, backend):
        self.backend = backend

    def create_read_only(
        self, source_descriptor, generation_descriptor, capture_id, deadline
    ):
        self.backend.create_read_only(
            source_descriptor, generation_descriptor, capture_id, deadline
        )
        raise KeyboardInterrupt()

    def is_read_only(self, generation_descriptor, capture_id, deadline):
        return self.backend.is_read_only(generation_descriptor, capture_id, deadline)

    def delete(self, generation_descriptor, capture_id, deadline):
        return self.backend.delete(generation_descriptor, capture_id, deadline)


def _source(root):
    source = root / "live"
    _run("/usr/bin/btrfs", "subvolume", "create", str(source))
    (source / "state.txt").write_text("durable component state\n")
    info = source.stat()
    return ComponentVolumeSource(
        "jellyfin",
        "a" * 64,
        "jellyfin-config",
        source,
        "10.11.11",
        1,
        "upstream_managed_unverified",
        7,
        info.st_dev,
        info.st_ino,
    )


def _recover_with_packaged_worker(root, captures, journal):
    runtime = root / "runtime"
    runtime.mkdir(mode=0o700)
    containers = root / "containers.sqlite3"
    volumes = root / "volumes.sqlite3"
    with (
        ManagedWorkerJournal(containers, initialize=True),
        VolumeCreateJournal(volumes, initialize=True),
    ):
        pass
    executable = Path(sys.executable).with_name("larenor-component-backup-worker")
    assert executable.is_file()
    _run(
        str(executable),
        "--socket",
        str(runtime / "component.sock"),
        "--container-journal",
        str(containers),
        "--volume-journal",
        str(volumes),
        "--engine-socket",
        str(runtime / "engine.sock"),
        "--capture-root",
        str(captures),
        "--capture-journal",
        str(journal),
        "--api-uid",
        "0",
        "--engine-uid",
        "0",
        "--btrfs",
        "/usr/bin/btrfs",
        "--check-config",
    )


def test_real_btrfs_capture_is_read_only_and_restart_releases_intent():
    root = Path(os.environ["LARENOR_NATIVE_CAPTURE_ROOT"])
    assert os.geteuid() == 0
    source = _source(root)
    captures = root / "captures"
    captures.mkdir(mode=0o700)
    system = LinuxCaptureSystem()
    deadline = time.monotonic() + 10
    assert system.platform_name() == "linux"
    assert system.effective_uid() == 0
    assert system.effective_capabilities(deadline) & (1 << CAP_SYS_ADMIN)
    assert system.effective_uid_map(deadline) == (0, 0, 4294967295)
    namespace = system.user_namespace_identity(deadline)
    assert len(namespace) == 2 and namespace[1] > 0
    descriptor = system.open_directory(captures)
    try:
        observation = system.observe_mount(descriptor, deadline)
        assert observation.mount.filesystem == "btrfs"
        assert not observation.read_only
        assert not observation.idmapped
    finally:
        system.close(descriptor)
    preflight = LinuxBtrfsCapturePreflight(captures)
    capability = preflight.verify(time.monotonic() + 10)
    assert preflight.revalidate(capability, time.monotonic() + 10)
    journal = root / "capture-journal.json"
    backend = BtrfsReadOnlySnapshotBackend()
    identifiers = iter(("1" * 32, "2" * 32)).__next__
    engine = LinuxCowCaptureEngine(
        captures,
        journal,
        backend=backend,
        id_factory=identifiers,
        capability_preflight=preflight,
        capture_capability=capability,
    )

    leases = engine.capture((source,), time.monotonic() + 10)
    assert {item.capture_generation for item in leases} == {"1" * 32}
    generation_descriptor = os.open(
        captures / ("1" * 32),
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
    )
    try:
        assert backend.is_read_only(
            generation_descriptor, "2" * 32, time.monotonic() + 10
        )
    finally:
        os.close(generation_descriptor)
    descriptor = os.open("state.txt", os.O_RDONLY, dir_fd=leases[0].descriptor)
    try:
        assert os.read(descriptor, 128) == b"durable component state\n"
    finally:
        os.close(descriptor)
    assert engine.release(leases, time.monotonic() + 10)

    # Simulate publication interrupted after complete generation capture but
    # before its release acknowledgement reaches the privileged engine.
    unpublished = LinuxCowCaptureEngine(
        captures,
        journal,
        backend=backend,
        id_factory=iter(("3" * 32, "4" * 32)).__next__,
        capability_preflight=preflight,
        capture_capability=capability,
    ).capture((source,), time.monotonic() + 10)
    assert {item.capture_generation for item in unpublished} == {"3" * 32}
    for item in unpublished:
        os.close(item.descriptor)
    assert journal.is_file()
    recovery = LinuxCowCaptureEngine(
        captures,
        journal,
        backend=backend,
        capability_preflight=preflight,
        capture_capability=capability,
    )
    assert recovery.recover(time.monotonic() + 10)
    assert not journal.exists()
    assert list(captures.iterdir()) == []

    interrupted = LinuxCowCaptureEngine(
        captures,
        journal,
        backend=_InterruptAfterSnapshot(backend),
        id_factory=iter(("5" * 32, "6" * 32)).__next__,
        capability_preflight=preflight,
        capture_capability=capability,
    )
    try:
        interrupted.capture((source,), time.monotonic() + 10)
    except KeyboardInterrupt:
        pass
    else:
        raise AssertionError("native capture interruption was not exercised")
    assert journal.is_file()
    preflight.close()
    _recover_with_packaged_worker(root, captures, journal)
    assert not journal.exists()
    assert list(captures.iterdir()) == []
