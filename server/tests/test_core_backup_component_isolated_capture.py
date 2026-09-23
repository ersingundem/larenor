"""S09.1 authority-bound isolated component capture contract."""

import fcntl
import io
import os
import time
import zipfile
from dataclasses import replace

import pytest

from larenor_server.core_backups.component_isolated_capture import (
    AuthorityBoundIsolatedCapture,
    IsolatedComponentVolume,
    IsolatedComponentCaptureError,
)
from larenor_server.core_backups.component_snapshot_provider import (
    ManagedComponentSnapshotProvider,
)
from larenor_server.core_backups.component_docker_adapter import (
    UnixDockerComponentSnapshotAdapter,
)
from test_core_backup_component_docker_adapter import (
    effect_operations,
    effect_reply,
    installed_authority,
    make_roots,
    operation_reply,
    running_inspect,
)
from test_core_backup_component_snapshot_provider import (
    InstalledAuthority,
    PauseController,
    source,
)
from test_volume_effects import engine_server


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
                    "capture-set-1",
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
        "mixed_generation",
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
        elif damage == "mixed_generation":
            first = replace(first, capture_generation="capture-set-2")
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


def test_managed_provider_archives_only_isolated_descriptors(tmp_path):
    sources, engine = setup(tmp_path)
    for item in sources:
        (item.path / "state.txt").write_text("live-writer-data")
    controller = PauseController()
    provider = ManagedComponentSnapshotProvider(
        sources,
        controller,
        InstalledAuthority(),
        isolated_capture=AuthorityBoundIsolatedCapture(engine),
    )

    with provider.quiesce(time.monotonic() + 3) as snapshots:
        assert controller.paused == {"larenor-jellyfin"}
        assert [call[0] for call in engine.calls][-1] == "release"
        payloads = {
            item.volumeId: zipfile.ZipFile(io.BytesIO(item.payload)).read("state.txt")
            for item in snapshots
        }
        assert payloads == {
            "jellyfin-cache": b"cache-stable",
            "jellyfin-config": b"config-stable",
        }

    assert controller.paused == set()
    assert [call[0] for call in engine.calls] == [
        "capture",
        "revalidate",
        "revalidate",
        "release",
    ]


def test_managed_provider_releases_capture_and_container_on_authority_drift(tmp_path):
    sources, engine = setup(tmp_path)

    class DriftingAuthority(InstalledAuthority):
        def revalidate(self, sources, deadline):
            result = super().revalidate(sources, deadline)
            return result and len(self.calls) < 2

    controller = PauseController()
    provider = ManagedComponentSnapshotProvider(
        sources,
        controller,
        DriftingAuthority(),
        isolated_capture=AuthorityBoundIsolatedCapture(engine),
    )

    with pytest.raises(Exception, match="snapshot_unavailable"):
        with provider.quiesce(time.monotonic() + 3):
            raise AssertionError("must_not_yield")

    assert controller.paused == set()
    assert [call[0] for call in engine.calls].count("release") == 1


def test_docker_adapter_builds_real_isolated_provider_and_owns_effects(tmp_path):
    journal = tmp_path / "journal"
    journal.mkdir(mode=0o700)
    with installed_authority(journal) as (
        authority,
        receipt,
        binding,
        _volumes,
    ):
        live_roots = make_roots(tmp_path / "live", binding)
        isolated_roots = {}
        for volume in receipt.volumes:
            path = tmp_path / "isolated" / volume.volume_id
            path.mkdir(parents=True)
            (path / "state.txt").write_text(f"stable-{volume.volume_id}")
            isolated_roots[volume.volume_id] = path
        engine = CaptureEngine(isolated_roots)
        state = {"paused": False}
        container = running_inspect(binding, live_roots)
        reply = effect_reply(container, receipt.volumes, state)
        with engine_server(reply) as (endpoint, calls):
            adapter = UnixDockerComponentSnapshotAdapter(
                endpoint,
                authority,
                peer_uid=lambda _: endpoint.owner_uid,
                capture_engine=engine,
            )
            provider = adapter.provider(time.monotonic() + 5)
            with provider.quiesce(time.monotonic() + 8) as snapshots:
                assert state["paused"] is True
                assert all(
                    zipfile.ZipFile(io.BytesIO(item.payload)).read("state.txt")
                    == f"stable-{item.volumeId}".encode()
                    for item in snapshots
                )
            assert state["paused"] is False

        assert len(effect_operations(calls)) == 2
        assert [call[0] for call in engine.calls].count("release") == 1


def test_docker_adapter_refuses_provider_without_isolated_engine(tmp_path):
    journal = tmp_path / "journal"
    journal.mkdir(mode=0o700)
    with installed_authority(journal) as (
        authority,
        receipt,
        binding,
        _volumes,
    ):
        live_roots = make_roots(tmp_path / "live", binding)
        container = running_inspect(binding, live_roots)
        with engine_server(operation_reply(container, receipt.volumes)) as (
            endpoint,
            _calls,
        ):
            adapter = UnixDockerComponentSnapshotAdapter(
                endpoint, authority, peer_uid=lambda _: endpoint.owner_uid
            )
            with pytest.raises(Exception, match="component_engine_unavailable"):
                adapter.provider(time.monotonic() + 3)
