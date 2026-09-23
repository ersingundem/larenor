"""S09.1 managed component volume snapshot provider."""

import io
import os
import time
import zipfile
from pathlib import Path

import pytest

from larenor_server.core_backups.component_snapshot_provider import (
    ComponentSnapshotProviderError,
    ComponentVolumeSource,
    ManagedComponentSnapshotProvider,
    archive_component_directory,
)


class PauseController:
    def __init__(self, *, fail_on=None):
        self.fail_on = fail_on
        self.calls = []
        self.paused = set()

    def pause(self, container_id, deadline):
        assert time.monotonic() < deadline
        self.calls.append(("pause", container_id))
        if container_id == self.fail_on:
            raise RuntimeError("private controller detail")
        self.paused.add(container_id)
        return True

    def unpause(self, container_id, deadline):
        assert time.monotonic() < deadline
        self.calls.append(("unpause", container_id))
        self.paused.remove(container_id)
        return True


def source(service, volume, path):
    return ComponentVolumeSource(
        service_id=service,
        container_id=f"larenor-{service}",
        volume_id=f"{service}-{volume}",
        path=path,
    )


def test_provider_pauses_once_and_returns_deterministic_catalog_snapshots(tmp_path):
    config = tmp_path / "config"
    cache = tmp_path / "cache"
    config.mkdir()
    cache.mkdir()
    (config / "system.xml").write_text("<server />\n")
    (config / "nested").mkdir()
    (config / "nested" / "library.db").write_bytes(b"sqlite\x00payload")
    (cache / "empty").mkdir()
    controller = PauseController()
    provider = ManagedComponentSnapshotProvider(
        (
            source("jellyfin", "cache", cache),
            source("jellyfin", "config", config),
        ),
        controller,
    )

    with provider.quiesce(time.monotonic() + 3) as first:
        assert controller.paused == {"larenor-jellyfin"}
        assert [item.volumeId for item in first] == [
            "jellyfin-cache",
            "jellyfin-config",
        ]
        assert all(item.serviceVersion == "10.11.11" for item in first)
        config_payload = next(
            item.payload for item in first if item.volumeId == "jellyfin-config"
        )
        with zipfile.ZipFile(io.BytesIO(config_payload)) as archive:
            assert archive.namelist() == [
                "nested/",
                "nested/library.db",
                "system.xml",
            ]
            assert archive.read("nested/library.db") == b"sqlite\x00payload"
    assert controller.calls == [
        ("pause", "larenor-jellyfin"),
        ("unpause", "larenor-jellyfin"),
    ]

    with provider.quiesce(time.monotonic() + 3) as second:
        assert [item.payload for item in second] == [item.payload for item in first]


def test_provider_rolls_back_partial_pause_without_reading_volumes(tmp_path):
    jellyfin_config = tmp_path / "jellyfin-config"
    jellyfin_cache = tmp_path / "jellyfin-cache"
    seerr_config = tmp_path / "seerr-config"
    for path in (jellyfin_config, jellyfin_cache, seerr_config):
        path.mkdir()
    controller = PauseController(fail_on="larenor-seerr")
    provider = ManagedComponentSnapshotProvider(
        (
            source("jellyfin", "config", jellyfin_config),
            source("jellyfin", "cache", jellyfin_cache),
            source("seerr", "config", seerr_config),
        ),
        controller,
    )

    with pytest.raises(ComponentSnapshotProviderError, match="snapshot_unavailable"):
        with provider.quiesce(time.monotonic() + 3):
            raise AssertionError("must_not_yield")

    assert controller.paused == set()
    assert controller.calls == [
        ("pause", "larenor-jellyfin"),
        ("pause", "larenor-seerr"),
        ("unpause", "larenor-jellyfin"),
    ]


def test_provider_rejects_incomplete_catalog_volume_set(tmp_path):
    config = tmp_path / "config"
    config.mkdir()
    with pytest.raises(
        ComponentSnapshotProviderError, match="invalid_snapshot_configuration"
    ):
        ManagedComponentSnapshotProvider(
            (source("jellyfin", "config", config),), PauseController()
        )


def test_archive_rejects_symlink_and_always_unpauses_provider(tmp_path):
    config = tmp_path / "config"
    cache = tmp_path / "cache"
    config.mkdir()
    cache.mkdir()
    (config / "escape").symlink_to(tmp_path / "outside")
    controller = PauseController()
    provider = ManagedComponentSnapshotProvider(
        (
            source("jellyfin", "config", config),
            source("jellyfin", "cache", cache),
        ),
        controller,
    )

    with pytest.raises(ComponentSnapshotProviderError, match="snapshot_unavailable"):
        with provider.quiesce(time.monotonic() + 3):
            raise AssertionError("must_not_yield")

    assert controller.paused == set()
    assert controller.calls[-1] == ("unpause", "larenor-jellyfin")


def test_archive_is_bounded_and_rejects_expired_deadline(tmp_path):
    root = tmp_path / "root"
    root.mkdir()
    (root / "large.bin").write_bytes(b"x" * 65)
    descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        with pytest.raises(ComponentSnapshotProviderError, match="snapshot_too_large"):
            archive_component_directory(
                descriptor, time.monotonic() + 1, max_bytes=64
            )
        with pytest.raises(ComponentSnapshotProviderError, match="snapshot_unavailable"):
            archive_component_directory(descriptor, time.monotonic() - 1)
    finally:
        os.close(descriptor)


@pytest.mark.parametrize(
    "change",
    [
        {"service_id": "unknown"},
        {"container_id": "UPPER CASE"},
        {"volume_id": "jellyfin-state"},
        {"path": Path("relative")},
    ],
)
def test_provider_rejects_untrusted_source_fields(tmp_path, change):
    config = tmp_path / "config"
    cache = tmp_path / "cache"
    config.mkdir()
    cache.mkdir()
    values = {
        "service_id": "jellyfin",
        "container_id": "larenor-jellyfin",
        "volume_id": "jellyfin-config",
        "path": config,
    }
    values.update(change)
    invalid = ComponentVolumeSource(**values)
    with pytest.raises(
        ComponentSnapshotProviderError, match="invalid_snapshot_configuration"
    ):
        ManagedComponentSnapshotProvider(
            (invalid, source("jellyfin", "cache", cache)), PauseController()
        )
