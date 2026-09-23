"""Linux read-only/COW component capture engine contract."""

import json
import os
import shutil
import time
from dataclasses import replace

import pytest

from larenor_server.core_backups.component_isolated_capture import (
    IsolatedComponentCaptureError,
    LinuxCowCaptureEngine,
)
from larenor_server.core_backups.component_snapshot_provider import (
    ComponentVolumeSource,
)


class FakeCowBackend:
    def __init__(self, *, interrupt_after=None, delete_failure=False):
        self.interrupt_after = interrupt_after
        self.delete_failure = delete_failure
        self.created = []
        self.deleted = []
        self.read_only = set()

    def create_read_only(self, source, destination, deadline):
        assert time.monotonic() < deadline
        shutil.copytree(source, destination)
        self.created.append((source, destination))
        self.read_only.add(destination)
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


def engine(tmp_path, backend):
    root = tmp_path / "captures"
    root.mkdir(mode=0o700)
    return LinuxCowCaptureEngine(
        root,
        tmp_path / "capture-journal.json",
        backend=backend,
        id_factory=iter(("1" * 32, "2" * 32, "3" * 32)).__next__,
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
    restarted = LinuxCowCaptureEngine(
        tmp_path / "captures", journal, backend=backend
    )
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
    damaged = (replace(values[0], snapshot_inode=values[0].snapshot_inode + 1), *values[1:])
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

