"""Linux read-only/COW component capture engine contract."""

import json
import fcntl
import os
import shutil
import subprocess
import time
from contextlib import contextmanager
from dataclasses import replace
from pathlib import Path

import pytest

from larenor_server.core_backups.component_isolated_capture import (
    BtrfsReadOnlySnapshotBackend,
    IsolatedComponentCaptureError,
    LinuxCowCaptureEngine,
)
from larenor_server.core_backups.component_linux_capture_preflight import (
    LinuxBtrfsCaptureCapability,
)
from larenor_server.core_backups.component_snapshot_provider import (
    ComponentVolumeSource,
)


class FakeCowBackend:
    def __init__(
        self,
        *,
        interrupt_after=None,
        delete_failure=False,
        replace_source=False,
        after_create=None,
    ):
        self.interrupt_after = interrupt_after
        self.delete_failure = delete_failure
        self.created = []
        self.deleted = []
        self.read_only = set()
        self.replace_source = replace_source
        self.after_create = after_create

    def create_read_only(self, source, destination, deadline):
        assert time.monotonic() < deadline
        shutil.copytree(source, destination)
        self.created.append((source, destination))
        self.read_only.add(destination)
        if self.after_create is not None:
            self.after_create()
        if self.replace_source:
            retired = source.with_name(source.name + "-retired")
            source.rename(retired)
            source.mkdir()
        if self.interrupt_after == len(self.created):
            raise KeyboardInterrupt()

    def is_read_only(self, destination, deadline):
        assert time.monotonic() < deadline
        return destination in self.read_only

    def delete(self, destination, deadline):
        assert time.monotonic() < deadline
        if self.delete_failure:
            raise OSError("private backend detail")
        shutil.rmtree(destination)
        self.read_only.discard(destination)
        self.deleted.append(destination)


def sources(tmp_path):
    result = []
    for index, volume_id in enumerate(("jellyfin-cache", "jellyfin-config"), 1):
        root = tmp_path / "live" / volume_id
        root.mkdir(parents=True)
        (root / "state.txt").write_text(volume_id)
        info = root.stat()
        result.append(
            ComponentVolumeSource(
                "jellyfin",
                "a" * 64,
                volume_id,
                root,
                "10.11.11",
                1,
                "upstream_managed_unverified",
                index + 2,
                info.st_dev,
                info.st_ino,
            )
        )
    return tuple(result)


class CapturePreflight:
    def __init__(self):
        self.retained = True
        self.sources_retained = True
        self.calls = []
        self.held_sources = 0
        self.capability_calls = 0
        self.fail_on_capability_call = None

    def revalidate(self, capability, deadline):
        assert time.monotonic() < deadline
        self.capability_calls += 1
        self.calls.append(("capability", capability))
        return self.retained and (
            self.fail_on_capability_call is None
            or self.capability_calls < self.fail_on_capability_call
        )

    def source_retained(self, path, device, inode, capability, deadline):
        assert time.monotonic() < deadline
        self.calls.append(("source", path, device, inode, capability))
        return self.retained and self.sources_retained

    @contextmanager
    def retain_source(self, path, device, inode, capability, deadline):
        assert self.source_retained(path, device, inode, capability, deadline)
        self.held_sources += 1
        try:
            yield
        finally:
            self.held_sources -= 1


def engine(tmp_path, backend, *, preflight=None, identifiers=None):
    root = tmp_path / "captures"
    root.mkdir(mode=0o700)
    capability = (
        None
        if preflight is None
        else LinuxBtrfsCaptureCapability(1, 11, 12, 13, 14, 15, 16, 17)
    )
    return LinuxCowCaptureEngine(
        root,
        tmp_path / "capture-journal.json",
        backend=backend,
        id_factory=iter(
            identifiers or ("1" * 32, "2" * 32, "3" * 32)
        ).__next__,
        capability_preflight=preflight,
        capture_capability=capability,
    )


def test_engine_returns_one_read_only_generation_and_releases_durably(tmp_path):
    backend = FakeCowBackend()
    capture = engine(tmp_path, backend)
    values = capture.capture(sources(tmp_path), time.monotonic() + 2)

    assert {item.capture_generation for item in values} == {"1" * 32}
    assert [item.capture_id for item in values] == ["2" * 32, "3" * 32]
    assert all(item.writer_container_ids == ("a" * 64,) for item in values)
    assert capture.revalidate(values, time.monotonic() + 2) is True
    assert (tmp_path / "capture-journal.json").is_file()

    assert capture.release(values, time.monotonic() + 2) is True
    assert not (tmp_path / "capture-journal.json").exists()
    assert list((tmp_path / "captures").iterdir()) == []
    for value in values:
        with pytest.raises(OSError):
            os.fstat(value.descriptor)


def test_capability_is_retained_and_release_is_exactly_once(tmp_path):
    preflight = CapturePreflight()
    backend = FakeCowBackend()
    capture = engine(tmp_path, backend, preflight=preflight)

    values = capture.capture(sources(tmp_path), time.monotonic() + 2)
    assert all(
        fcntl.fcntl(item.descriptor, fcntl.F_GETFL) & os.O_ACCMODE
        == os.O_RDONLY
        for item in values
    )
    assert all(
        fcntl.fcntl(item.descriptor, fcntl.F_GETFD) & fcntl.FD_CLOEXEC
        for item in values
    )
    assert capture.revalidate(values, time.monotonic() + 2) is True
    assert capture.release(values, time.monotonic() + 2) is True
    assert capture.release(values, time.monotonic() + 2) is False
    assert len(backend.deleted) == 2
    assert {call[0] for call in preflight.calls} == {"capability", "source"}


def test_engine_requires_exact_preflight_and_capability_pair(tmp_path):
    root = tmp_path / "captures"
    root.mkdir(mode=0o700)
    capability = LinuxBtrfsCaptureCapability(1, 11, 12, 13, 14, 15, 16, 17)
    with pytest.raises(IsolatedComponentCaptureError):
        LinuxCowCaptureEngine(
            root,
            tmp_path / "journal.json",
            backend=FakeCowBackend(),
            capture_capability=capability,
        )


def test_source_mount_drift_rolls_back_partial_capture(tmp_path):
    preflight = CapturePreflight()
    backend = FakeCowBackend(
        after_create=lambda: setattr(preflight, "sources_retained", False)
    )
    capture = engine(tmp_path, backend, preflight=preflight)

    with pytest.raises(IsolatedComponentCaptureError):
        capture.capture(sources(tmp_path), time.monotonic() + 2)

    assert len(backend.created) == 1
    assert len(backend.deleted) == 1
    assert not (tmp_path / "capture-journal.json").exists()
    assert list((tmp_path / "captures").iterdir()) == []


def test_source_descriptor_lease_spans_snapshot_mutation(tmp_path):
    preflight = CapturePreflight()

    def assert_source_held():
        assert preflight.held_sources == 1

    backend = FakeCowBackend(after_create=assert_source_held)
    capture = engine(tmp_path, backend, preflight=preflight)

    values = capture.capture(sources(tmp_path), time.monotonic() + 2)
    assert preflight.held_sources == 0
    assert capture.release(values, time.monotonic() + 2)


def test_capability_drift_retains_journal_until_safe_restart_cleanup(tmp_path):
    preflight = CapturePreflight()
    backend = FakeCowBackend()
    capture = engine(tmp_path, backend, preflight=preflight)
    values = capture.capture(sources(tmp_path), time.monotonic() + 2)

    preflight.retained = False
    assert capture.revalidate(values, time.monotonic() + 2) is False
    assert capture.release(values, time.monotonic() + 2) is False
    assert backend.deleted == []
    assert (tmp_path / "capture-journal.json").is_file()
    for item in values:
        with pytest.raises(OSError):
            os.fstat(item.descriptor)

    preflight.retained = True
    restarted = LinuxCowCaptureEngine(
        tmp_path / "captures",
        tmp_path / "capture-journal.json",
        backend=backend,
        capability_preflight=preflight,
        capture_capability=LinuxBtrfsCaptureCapability(
            1, 11, 12, 13, 14, 15, 16, 17
        ),
    )
    assert restarted.recover(time.monotonic() + 2) is True
    assert restarted.recover(time.monotonic() + 2) is True
    assert len(backend.deleted) == 2


def test_capability_is_rechecked_before_generation_mutation(tmp_path):
    preflight = CapturePreflight()
    preflight.fail_on_capability_call = 4
    backend = FakeCowBackend()
    capture = engine(tmp_path, backend, preflight=preflight)

    with pytest.raises(IsolatedComponentCaptureError):
        capture.capture(sources(tmp_path), time.monotonic() + 2)

    assert backend.created == []
    assert (tmp_path / "capture-journal.json").is_file()
    assert list((tmp_path / "captures").iterdir()) == []
    preflight.fail_on_capability_call = None
    assert capture.recover(time.monotonic() + 2)
    assert not (tmp_path / "capture-journal.json").exists()


@pytest.mark.parametrize(
    "identifiers",
    [
        ("1" * 32, "1" * 32, "3" * 32),
        ("1" * 31, "2" * 32, "3" * 32),
    ],
)
def test_generation_and_capture_ids_are_exact_and_unique(tmp_path, identifiers):
    backend = FakeCowBackend()
    capture = engine(tmp_path, backend, identifiers=identifiers)

    with pytest.raises(IsolatedComponentCaptureError):
        capture.capture(sources(tmp_path), time.monotonic() + 2)

    assert backend.created == []
    assert not (tmp_path / "capture-journal.json").exists()


def test_restart_recovers_every_intended_snapshot_after_interruption(tmp_path):
    backend = FakeCowBackend(interrupt_after=1)
    capture = engine(tmp_path, backend)
    with pytest.raises(KeyboardInterrupt):
        capture.capture(sources(tmp_path), time.monotonic() + 2)

    journal = tmp_path / "capture-journal.json"
    value = json.loads(journal.read_text())
    assert value["state"] == "capturing"
    assert len(value["volumes"]) == 2
    assert len(list((tmp_path / "captures" / ("1" * 32)).iterdir())) == 1

    backend.interrupt_after = None
    restarted = LinuxCowCaptureEngine(tmp_path / "captures", journal, backend=backend)
    assert restarted.recover(time.monotonic() + 2) is True
    assert not journal.exists()
    assert list((tmp_path / "captures").iterdir()) == []


def test_failed_release_retains_journal_for_restart_cleanup(tmp_path):
    backend = FakeCowBackend()
    capture = engine(tmp_path, backend)
    values = capture.capture(sources(tmp_path), time.monotonic() + 2)
    backend.delete_failure = True

    assert capture.release(values, time.monotonic() + 2) is False
    assert (tmp_path / "capture-journal.json").is_file()
    backend.delete_failure = False
    assert LinuxCowCaptureEngine(
        tmp_path / "captures",
        tmp_path / "capture-journal.json",
        backend=backend,
    ).recover(time.monotonic() + 2)
    assert list((tmp_path / "captures").iterdir()) == []


def test_revalidate_rejects_writable_or_identity_drift(tmp_path):
    backend = FakeCowBackend()
    capture = engine(tmp_path, backend)
    values = capture.capture(sources(tmp_path), time.monotonic() + 2)
    destination = backend.created[0][1]
    backend.read_only.remove(destination)
    assert capture.revalidate(values, time.monotonic() + 2) is False
    backend.read_only.add(destination)
    damaged = (
        replace(values[0], snapshot_inode=values[0].snapshot_inode + 1),
        *values[1:],
    )
    assert capture.revalidate(damaged, time.monotonic() + 2) is False
    assert capture.release(values, time.monotonic() + 2)


def test_malformed_restart_journal_fails_closed_without_deleting(tmp_path):
    root = tmp_path / "captures"
    root.mkdir(mode=0o700)
    owned = root / ("1" * 32)
    owned.mkdir()
    journal = tmp_path / "capture-journal.json"
    journal.write_text('{"schemaVersion":1,"volumes":[{"directory":"../foreign"}]}')
    os.chmod(journal, 0o600)

    with pytest.raises(IsolatedComponentCaptureError):
        LinuxCowCaptureEngine(root, journal, backend=FakeCowBackend()).recover(
            time.monotonic() + 2
        )
    assert owned.is_dir()


def test_capture_rejects_source_identity_drift_and_retains_no_payload(tmp_path):
    backend = FakeCowBackend(replace_source=True)
    capture = engine(tmp_path, backend)

    with pytest.raises(IsolatedComponentCaptureError):
        capture.capture(sources(tmp_path), time.monotonic() + 2)

    assert not (tmp_path / "capture-journal.json").exists()
    assert list((tmp_path / "captures").iterdir()) == []


def test_capture_rejects_unjournaled_capture_root_entry(tmp_path):
    backend = FakeCowBackend()
    capture = engine(tmp_path, backend)
    (tmp_path / "captures" / "foreign").mkdir()

    with pytest.raises(IsolatedComponentCaptureError):
        capture.capture(sources(tmp_path), time.monotonic() + 2)

    assert backend.created == []
    assert (tmp_path / "captures" / "foreign").is_dir()


def test_btrfs_backend_uses_only_fixed_read_only_operations():
    calls = []

    def run(arguments, **options):
        calls.append((arguments, options))
        output = b"ro=true\n" if arguments[1:4] == ["property", "get", "-ts"] else b""
        return subprocess.CompletedProcess(arguments, 0, output)

    backend = BtrfsReadOnlySnapshotBackend(Path("/usr/bin/env"), runner=run)
    deadline = time.monotonic() + 2
    backend.create_read_only(Path("/source"), Path("/capture"), deadline)
    backend.delete(Path("/capture"), deadline)

    assert [call[0][1:] for call in calls] == [
        ["subvolume", "snapshot", "-r", "/source", "/capture"],
        ["property", "get", "-ts", "/capture", "ro"],
        ["subvolume", "delete", "/capture"],
    ]
    assert all(call[1]["stdin"] is subprocess.DEVNULL for call in calls)
    assert all(call[1]["stderr"] is subprocess.DEVNULL for call in calls)
    assert all("shell" not in call[1] for call in calls)


def test_btrfs_runner_failure_is_static_and_source_free():
    def fail(_arguments, **_options):
        raise RuntimeError("private-host-path")

    backend = BtrfsReadOnlySnapshotBackend(Path("/usr/bin/env"), runner=fail)
    with pytest.raises(
        IsolatedComponentCaptureError, match="^isolated_capture_unavailable$"
    ) as caught:
        backend.create_read_only(
            Path("/private/source"),
            Path("/private/destination"),
            time.monotonic() + 2,
        )
    assert "private" not in repr(caught.value)
