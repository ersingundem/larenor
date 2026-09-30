"""Normal Core routes consume the packaged component worker over real AF_UNIX."""

from contextlib import contextmanager
import os
from pathlib import Path
import threading
import time
import uuid

from conftest import auth, ready
from fastapi.testclient import TestClient

from larenor_server.config import Settings
from larenor_server.core_backups import component_worker as worker_client
from larenor_server.core_backups.component_worker_server import (
    ComponentSnapshotWorkerServer,
)
from larenor_server.core_backups.service import ComponentVolumeSnapshot
from larenor_server.plugins.catalog import load_catalog
from larenor_server.plugins.component_updates import installed_update_source
from larenor_server.runtime import create_configured_app


class Boundary:
    def __init__(self):
        common = {
            "serviceId": "jellyfin",
            "serviceVersion": "10.11.11",
            "configSchemaVersion": 1,
            "dataSchemaVersion": "upstream_managed_unverified",
            "captureGeneration": "1" * 32,
        }
        self.snapshots = (
            ComponentVolumeSnapshot(
                **common,
                volumeId="jellyfin-cache",
                payload=b"normal Core cache capture\n",
            ),
            ComponentVolumeSnapshot(
                **common,
                volumeId="jellyfin-config",
                payload=b"normal Core config capture\n",
            ),
        )
        catalog = load_catalog()
        entry = next(
            item for item in catalog.entries if item.manifest.serviceId == "jellyfin"
        )
        image = next(
            item for item in entry.manifest.images if item.platform == "linux/amd64"
        )
        self.source = installed_update_source(
            installation_id="2" * 32,
            service_id=entry.manifest.serviceId,
            service_version=entry.manifest.version,
            config_schema_version=entry.manifest.configSchemaVersion,
            data_schema_version=entry.manifest.dataSchemaVersion,
            platform=image.platform,
            observed_image_config_digest=image.configDigest,
            catalog_entry=entry,
            recorded_catalog_digest=catalog.digest,
        )
        self.entered = 0
        self.released = 0
        self.source_reads = 0

    @contextmanager
    def quiesce(self, deadline):
        assert time.monotonic() < deadline <= time.monotonic() + 5
        self.entered += 1
        try:
            yield self.snapshots
        finally:
            self.released += 1

    def update_sources(self, deadline):
        assert time.monotonic() < deadline <= time.monotonic() + 5
        self.source_reads += 1
        return (self.source,)


@contextmanager
def worker(boundary):
    parent = Path("/tmp").resolve() / f"larenor-component-normal-{uuid.uuid4().hex}"
    parent.mkdir(mode=0o700)
    path = parent / "worker.sock"
    server = ComponentSnapshotWorkerServer(
        path,
        boundary,
        owner_uid=os.getuid(),
        client_uid=os.getuid(),
        peer_uid=lambda _connection: os.getuid(),
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    assert server.wait_ready(2)
    try:
        yield path
    finally:
        server.close()
        thread.join(2)
        assert not thread.is_alive()
        parent.rmdir()


def test_normal_core_backup_and_update_routes_use_the_configured_worker(
    tmp_path, monkeypatch
):
    # Production runs on Linux and uses SO_PEERCRED.  macOS has no SO_PEERCRED,
    # so this route-composition test injects only the observed local test UID;
    # the hosted Linux gate exercises the kernel credential boundary.
    monkeypatch.setattr(worker_client, "_peer_uid", lambda _connection: os.getuid())
    boundary = Boundary()
    with worker(boundary) as socket_path:
        root = tmp_path.resolve()
        settings = Settings(
            root / "data",
            root / "secrets/vault.key",
            component_backup_worker_socket=socket_path,
            component_backup_worker_uid=os.getuid(),
        )
        app = create_configured_app(settings)
        with TestClient(app) as client:
            pair = ready((app, client, settings, None))
            backup = client.get("/api/v1/admin/backups/plan", headers=auth(pair))
            updates = client.get("/api/v1/admin/component-updates", headers=auth(pair))

    assert backup.status_code == 200
    assert [
        item["serviceId"] for item in backup.json()["manifest"]["components"]
    ] == ["jellyfin"]
    assert updates.status_code == 200
    assert [item["current"]["serviceId"] for item in updates.json()["installed"]] == [
        "jellyfin"
    ]
    assert boundary.entered == boundary.released == 1
    assert boundary.source_reads == 1
