"""S09.1 authority-bound isolated component capture contract."""

import fcntl
import os
import time
from dataclasses import replace

import pytest

from larenor_server.core_backups.component_isolated_capture import (
    AuthorityBoundIsolatedCapture,
    IsolatedComponentVolume,
    IsolatedComponentCaptureError,
)
from test_core_backup_component_snapshot_provider import source


class CaptureEngine:
    def __init__(self, roots):
        self.roots = roots
        self.calls = []
        self.available = True
        self.release_ok = True

    def capture(self, sources, deadline):
        self.calls.append(("capture", tuple(item.volume_id for item in sources)))
        values = []
        for item in sources:
            descriptor = os.open(
                self.roots[item.volume_id],
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
            )
            info = os.fstat(descriptor)
            values.append(
                IsolatedComponentVolume(
                    item.service_id,
                    item.container_id,
                    item.volume_id,
                    item.service_version,
                    item.config_schema_version,
                    item.data_schema_version,
                    item.installation_revision,
                    item.device,
                    item.inode,
                    info.st_dev,
                    info.st_ino,
                    descriptor,
                    (item.container_id,),
                    1,
                    f"capture-{item.volume_id}",
                )
            )
        return tuple(values)

    def revalidate(self, capture, deadline):
        self.calls.append(("revalidate", tuple(item.capture_id for item in capture)))
        return self.available

    def release(self, capture, deadline):
        self.calls.append(("release", tuple(item.capture_id for item in capture)))
        for item in capture:
            try:
                os.close(item.descriptor)
            except OSError:
                pass
        return self.release_ok


def setup(tmp_path):
    source_roots = {}
    capture_roots = {}
    sources = []
    for name in ("config", "cache"):
        original = tmp_path / "source" / name
        captured = tmp_path / "capture" / name
        original.mkdir(parents=True)
        captured.mkdir(parents=True)
        (captured / "state.txt").write_text(f"{name}-stable")
        source_roots[name] = original
        capture_roots[f"jellyfin-{name}"] = captured
        sources.append(source("jellyfin", name, original))
    engine = CaptureEngine(capture_roots)
    return tuple(sources), engine


def test_capture_owns_exact_read_only_descriptor_set_and_releases_once(tmp_path):
    sources, engine = setup(tmp_path)
    provider = AuthorityBoundIsolatedCapture(engine)

    with provider.acquire(sources, time.monotonic() + 2) as captured:
        assert [item.volume_id for item in captured] == [
            "jellyfin-cache",
            "jellyfin-config",
        ]
        assert all(os.fstat(item.descriptor).st_ino > 0 for item in captured)
        assert all(
            fcntl.fcntl(item.descriptor, fcntl.F_GETFL) & os.O_ACCMODE
            == os.O_RDONLY
            for item in captured
        )
        assert all(item.writer_container_ids == ("larenor-jellyfin",) for item in captured)

    assert [call[0] for call in engine.calls] == [
        "capture",
        "revalidate",
        "revalidate",
        "release",
    ]
    for item in captured:
        with pytest.raises(OSError):
            os.fstat(item.descriptor)


def test_capture_failure_or_consumer_interruption_still_releases(tmp_path):
    sources, engine = setup(tmp_path)
    provider = AuthorityBoundIsolatedCapture(engine)

    with pytest.raises(RuntimeError, match="consumer stopped"):
        with provider.acquire(sources, time.monotonic() + 2):
            raise RuntimeError("consumer stopped")
    assert [call[0] for call in engine.calls].count("release") == 1

    sources, engine = setup(tmp_path / "second")
    engine.available = False
    with pytest.raises(IsolatedComponentCaptureError, match="isolated_capture_unavailable"):
        with AuthorityBoundIsolatedCapture(engine).acquire(
            sources, time.monotonic() + 2
        ):
            raise AssertionError("must_not_yield")
    assert [call[0] for call in engine.calls].count("release") == 1


@pytest.mark.parametrize(
    "damage",
    [
        "shared_writer",
        "source_inode",
        "source_revision",
        "schema",
        "version",
        "capture_identity",
        "descriptor_mode",
    ],
)
def test_capture_rejects_drift_and_malformed_leases_without_yield(tmp_path, damage):
    sources, engine = setup(tmp_path)
    ordinary = engine.capture

    def damaged(selected, deadline):
        values = list(ordinary(selected, deadline))
        first = values[0]
        if damage == "shared_writer":
            first = replace(first, writer_container_ids=(first.container_id, "foreign"))
        elif damage == "source_inode":
            first = replace(first, source_inode=first.source_inode + 1)
        elif damage == "source_revision":
            first = replace(first, installation_revision=first.installation_revision + 1)
        elif damage == "schema":
            first = replace(first, data_schema_version="foreign")
        elif damage == "version":
            first = replace(first, service_version="0.0.0")
        elif damage == "capture_identity":
            first = replace(
                first,
                snapshot_device=first.source_device,
                snapshot_inode=first.source_inode,
            )
        elif damage == "descriptor_mode":
            os.close(first.descriptor)
            invalid = engine.roots[first.volume_id] / "writable"
            invalid.write_text("not a directory")
            descriptor = os.open(invalid, os.O_RDWR)
            first = replace(first, descriptor=descriptor)
        values[0] = first
        return tuple(values)

    engine.capture = damaged
    with pytest.raises(IsolatedComponentCaptureError, match="isolated_capture_unavailable"):
        with AuthorityBoundIsolatedCapture(engine).acquire(
            sources, time.monotonic() + 2
        ):
            raise AssertionError("must_not_yield")
    assert [call[0] for call in engine.calls].count("release") == 1


def test_capture_rejects_expired_or_malformed_deadline_without_dispatch(tmp_path):
    sources, engine = setup(tmp_path)
    provider = AuthorityBoundIsolatedCapture(engine)
    for deadline in (None, True, float("nan"), time.monotonic() - 1):
        with pytest.raises(IsolatedComponentCaptureError):
            with provider.acquire(sources, deadline):
                raise AssertionError("must_not_yield")
    assert engine.calls == []
