"""S09.1 managed component volume snapshot provider."""

import io
import os
import time
import zipfile
from dataclasses import replace
from pathlib import Path

import pytest

from larenor_server.core_backups.component_snapshot_provider import (
    ComponentSnapshotProviderError,
    ComponentVolumeSource,
    ManagedComponentSnapshotProvider,
    archive_component_directory,
)
from larenor_server.plugins.catalog import load_catalog


class InstalledAuthority:
    def __init__(self):
        self.available = True
        self.calls = []

    def revalidate(self, sources, deadline):
        assert time.monotonic() < deadline
        self.calls.append(sources)
        return self.available


class PauseController:
    def __init__(self, *, fail_on=None, uncertain_on=None):
        self.fail_on = fail_on
        self.uncertain_on = uncertain_on
        self.calls = []
        self.paused = set()

    def pause(self, container_id, deadline):
        assert time.monotonic() < deadline
        self.calls.append(("pause", container_id))
        if container_id == self.fail_on:
            raise RuntimeError("private controller detail")
        self.paused.add(container_id)
        if container_id == self.uncertain_on:
            raise TimeoutError("private uncertain result")
        return True

    def unpause(self, container_id, deadline):
        assert time.monotonic() < deadline
        self.calls.append(("unpause", container_id))
        self.paused.remove(container_id)
        return True


def source(service, volume, path):
    manifest = next(
        entry.manifest
        for entry in load_catalog().entries
        if entry.manifest.serviceId == service
    )
    identity = path.lstat()
    return ComponentVolumeSource(
        service_id=service,
        container_id=f"larenor-{service}",
        volume_id=f"{service}-{volume}",
        path=path,
        service_version=manifest.version,
        config_schema_version=manifest.configSchemaVersion,
        data_schema_version=manifest.dataSchemaVersion,
        installation_revision=7,
        device=identity.st_dev,
        inode=identity.st_ino,
    )


def provider(sources, controller, authority=None):
    return ManagedComponentSnapshotProvider(
        sources,
        controller,
        authority or InstalledAuthority(),
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
    authority = InstalledAuthority()
    snapshot_provider = provider(
        (
            source("jellyfin", "cache", cache),
            source("jellyfin", "config", config),
        ),
        controller,
        authority,
    )

    with snapshot_provider.quiesce(time.monotonic() + 3) as first:
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

    with snapshot_provider.quiesce(time.monotonic() + 3) as second:
        assert [item.payload for item in second] == [item.payload for item in first]
    assert len(authority.calls) == 4


def test_provider_rolls_back_partial_pause_without_reading_volumes(tmp_path):
    jellyfin_config = tmp_path / "jellyfin-config"
    jellyfin_cache = tmp_path / "jellyfin-cache"
    seerr_config = tmp_path / "seerr-config"
    for path in (jellyfin_config, jellyfin_cache, seerr_config):
        path.mkdir()
    controller = PauseController(fail_on="larenor-seerr")
    snapshot_provider = provider(
        (
            source("jellyfin", "config", jellyfin_config),
            source("jellyfin", "cache", jellyfin_cache),
            source("seerr", "config", seerr_config),
        ),
        controller,
    )

    with pytest.raises(ComponentSnapshotProviderError, match="snapshot_unavailable"):
        with snapshot_provider.quiesce(time.monotonic() + 3):
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
        provider((source("jellyfin", "config", config),), PauseController())


def test_archive_rejects_symlink_and_always_unpauses_provider(tmp_path):
    config = tmp_path / "config"
    cache = tmp_path / "cache"
    config.mkdir()
    cache.mkdir()
    (config / "escape").symlink_to(tmp_path / "outside")
    controller = PauseController()
    snapshot_provider = provider(
        (
            source("jellyfin", "config", config),
            source("jellyfin", "cache", cache),
        ),
        controller,
    )

    with pytest.raises(ComponentSnapshotProviderError, match="snapshot_unavailable"):
        with snapshot_provider.quiesce(time.monotonic() + 3):
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
    invalid = replace(source("jellyfin", "config", config), **change)
    with pytest.raises(
        ComponentSnapshotProviderError, match="invalid_snapshot_configuration"
    ):
        provider(
            (invalid, source("jellyfin", "cache", cache)),
            PauseController(),
        )


def test_uncertain_pause_is_reconciled_before_confirmed_containers(tmp_path):
    paths = {
        name: tmp_path / name
        for name in ("jellyfin-config", "jellyfin-cache", "seerr-config")
    }
    for path in paths.values():
        path.mkdir()
    controller = PauseController(uncertain_on="larenor-seerr")
    snapshot_provider = provider(
        (
            source("jellyfin", "config", paths["jellyfin-config"]),
            source("jellyfin", "cache", paths["jellyfin-cache"]),
            source("seerr", "config", paths["seerr-config"]),
        ),
        controller,
    )

    with pytest.raises(ComponentSnapshotProviderError, match="snapshot_unavailable"):
        with snapshot_provider.quiesce(time.monotonic() + 3):
            raise AssertionError("must_not_yield")

    assert controller.paused == set()
    assert controller.calls[-2:] == [
        ("unpause", "larenor-seerr"),
        ("unpause", "larenor-jellyfin"),
    ]


def test_path_replacement_is_rejected_before_pause(tmp_path):
    config = tmp_path / "config"
    cache = tmp_path / "cache"
    config.mkdir()
    cache.mkdir()
    controller = PauseController()
    snapshot_provider = provider(
        (
            source("jellyfin", "config", config),
            source("jellyfin", "cache", cache),
        ),
        controller,
    )
    config.rename(tmp_path / "old-config")
    config.mkdir()

    with pytest.raises(ComponentSnapshotProviderError, match="snapshot_unavailable"):
        with snapshot_provider.quiesce(time.monotonic() + 3):
            raise AssertionError("must_not_yield")

    assert controller.calls == []


def test_installed_authority_loss_blocks_before_pause(tmp_path):
    config = tmp_path / "config"
    cache = tmp_path / "cache"
    config.mkdir()
    cache.mkdir()
    authority = InstalledAuthority()
    authority.available = False
    controller = PauseController()
    snapshot_provider = provider(
        (
            source("jellyfin", "config", config),
            source("jellyfin", "cache", cache),
        ),
        controller,
        authority,
    )

    with pytest.raises(ComponentSnapshotProviderError, match="snapshot_unavailable"):
        with snapshot_provider.quiesce(time.monotonic() + 3):
            raise AssertionError("must_not_yield")
    assert controller.calls == []


def test_provider_rejects_shared_container_across_services(tmp_path):
    jellyfin_config = tmp_path / "jellyfin-config"
    jellyfin_cache = tmp_path / "jellyfin-cache"
    seerr_config = tmp_path / "seerr-config"
    for path in (jellyfin_config, jellyfin_cache, seerr_config):
        path.mkdir()
    seerr = replace(
        source("seerr", "config", seerr_config),
        container_id="larenor-jellyfin",
    )
    with pytest.raises(
        ComponentSnapshotProviderError, match="invalid_snapshot_configuration"
    ):
        provider(
            (
                source("jellyfin", "config", jellyfin_config),
                source("jellyfin", "cache", jellyfin_cache),
                seerr,
            ),
            PauseController(),
        )
