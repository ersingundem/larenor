"""S09.1 managed component-volume backup contract."""

import copy
from contextlib import contextmanager
from dataclasses import replace

import pytest
from conftest import auth, ready

from larenor_server.core_backups.restore import _validate_capture
from larenor_server.core_backups.service import (
    ComponentVolumeSnapshot,
    CoreBackupContract,
)
from larenor_server.errors import ApiError

PASSPHRASE = "Correct horse battery staple 2026"
CAPTURE_GENERATION = "1" * 32


class ComponentBoundary:
    def __init__(self, snapshots):
        self.snapshots = snapshots
        self.deadlines = []
        self.active = False
        self.released = False

    @contextmanager
    def quiesce(self, deadline):
        self.deadlines.append(deadline)
        self.active = True
        try:
            yield self.snapshots
        finally:
            self.active = False
            self.released = True


def _snapshots():
    common = {
        "serviceId": "jellyfin",
        "serviceVersion": "10.11.11",
        "configSchemaVersion": 1,
        "dataSchemaVersion": "upstream_managed_unverified",
        "captureGeneration": CAPTURE_GENERATION,
    }
    return (
        ComponentVolumeSnapshot(
            **common,
            volumeId="jellyfin-cache",
            payload=b"synthetic jellyfin cache snapshot\n",
        ),
        ComponentVolumeSnapshot(
            **common,
            volumeId="jellyfin-config",
            payload=b"synthetic jellyfin config snapshot\n",
        ),
    )


def _install_boundary(server, monkeypatch, *, monotonic=lambda: 100.0):
    app, _client, settings, _clock = server
    boundary = ComponentBoundary(_snapshots())
    contract = CoreBackupContract(
        app.state.core.db,
        app.state.core.auth,
        settings,
        component_boundary=boundary,
        monotonic=monotonic,
    )
    original = contract._capture_family_board

    def capture_family_board_while_quiesced():
        assert boundary.active
        return original()

    monkeypatch.setattr(
        contract,
        "_capture_family_board",
        capture_family_board_while_quiesced,
    )
    app.state.core.core_backups = contract
    return boundary


def test_component_volumes_share_the_bounded_cut_and_stay_encrypted(
    server, monkeypatch
):
    app, client, _settings, _clock = server
    pair = ready(server)
    boundary = _install_boundary(server, monkeypatch)

    response = client.post(
        "/api/v1/admin/backups/export",
        headers=auth(pair),
        json={"passphrase": PASSPHRASE},
    )

    assert response.status_code == 200
    assert boundary.deadlines == [105.0]
    assert boundary.released and not boundary.active
    for snapshot in _snapshots():
        assert snapshot.payload not in response.content

    opened = app.state.core.core_backups.open_bundle(response.content, PASSPHRASE)
    assert opened.manifest.snapshotId == CAPTURE_GENERATION
    assert opened.manifest.consistencyBoundary.model_dump() == {
        "mode": "core_write_lock_and_component_quiescence",
        "maxDurationSeconds": 5,
    }
    assert [item.model_dump() for item in opened.manifest.components] == [
        {
            "serviceId": "jellyfin",
            "serviceVersion": "10.11.11",
            "configSchemaVersion": 1,
            "dataSchemaVersion": "upstream_managed_unverified",
            "volumeResourceIds": [
                "component-jellyfin-cache",
                "component-jellyfin-config",
            ],
        }
    ]
    assert opened.payloads["component-jellyfin-cache"] == _snapshots()[0].payload
    assert opened.payloads["component-jellyfin-config"] == _snapshots()[1].payload


def test_mixed_component_capture_generations_fail_before_publication(server):
    app, client, settings, _clock = server
    pair = ready(server)
    first, second = _snapshots()
    boundary = ComponentBoundary((first, replace(second, captureGeneration="2" * 32)))
    app.state.core.core_backups = CoreBackupContract(
        app.state.core.db,
        app.state.core.auth,
        settings,
        component_boundary=boundary,
    )

    response = client.post(
        "/api/v1/admin/backups/export",
        headers=auth(pair),
        json={"passphrase": PASSPHRASE},
    )

    assert response.status_code == 503
    assert response.json()["error"]["code"] == "server_unavailable"
    assert boundary.released


def test_component_version_schema_and_volume_compatibility_fail_closed(
    server, monkeypatch
):
    _app, client, _settings, _clock = server
    pair = ready(server)
    _install_boundary(server, monkeypatch)
    manifest = client.get(
        "/api/v1/admin/backups/plan", headers=auth(pair)
    ).json()["manifest"]

    accepted = client.post(
        "/api/v1/admin/backups/restore/validate",
        headers=auth(pair),
        json={"manifest": manifest},
    )
    assert accepted.json() == {"compatible": True, "reasons": []}

    cases = []
    changed = copy.deepcopy(manifest)
    changed["components"][0]["serviceVersion"] = "10.11.10"
    cases.append((changed, "component_version_mismatch"))
    changed = copy.deepcopy(manifest)
    changed["components"][0]["configSchemaVersion"] = 2
    cases.append((changed, "component_schema_mismatch"))
    changed = copy.deepcopy(manifest)
    changed["components"][0]["volumeResourceIds"][0] = "component-jellyfin-state"
    resource = next(
        item
        for item in changed["resources"]
        if item["id"] == "component-jellyfin-cache"
    )
    resource["id"] = "component-jellyfin-state"
    changed["components"][0]["volumeResourceIds"].sort()
    cases.append((changed, "component_volume_mismatch"))

    for changed, reason in cases:
        response = client.post(
            "/api/v1/admin/backups/restore/validate",
            headers=auth(pair),
            json={"manifest": changed},
        )
        assert response.status_code == 200
        assert response.json() == {"compatible": False, "reasons": [reason]}


def test_component_quiescence_deadline_releases_and_returns_no_manifest(
    server, monkeypatch
):
    _app, client, _settings, _clock = server
    pair = ready(server)
    times = iter((100.0, 105.001))
    boundary = _install_boundary(server, monkeypatch, monotonic=lambda: next(times))

    response = client.get("/api/v1/admin/backups/plan", headers=auth(pair))

    assert response.status_code == 200
    assert response.json() == {
        "status": "blocked",
        "blockers": ["component_quiescence_timeout"],
        "manifest": None,
    }
    assert boundary.released and not boundary.active


def test_partial_component_volume_set_fails_closed(server):
    app, client, settings, _clock = server
    pair = ready(server)
    boundary = ComponentBoundary(_snapshots()[:1])
    app.state.core.core_backups = CoreBackupContract(
        app.state.core.db,
        app.state.core.auth,
        settings,
        component_boundary=boundary,
    )

    response = client.get("/api/v1/admin/backups/plan", headers=auth(pair))

    assert response.status_code == 503
    assert response.json()["error"]["code"] == "server_unavailable"
    assert boundary.released


def test_component_payload_restore_is_rejected_before_publication(server, monkeypatch):
    app, _client, settings, _clock = server
    pair = ready(server)
    _install_boundary(server, monkeypatch)
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    capture = app.state.core.core_backups.capture(actor)

    with pytest.raises(ApiError, match="backup_incompatible"):
        _validate_capture(capture, settings)
