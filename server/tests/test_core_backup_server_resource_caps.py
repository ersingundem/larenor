"""Server restore preflight caps every typed backup resource."""

import copy

import pytest
from conftest import auth, ready
from larenor_server.core_backups import service as backup_service


def _manifest(server):
    _app, client, _settings, _clock = server
    pair = ready(server)
    response = client.get("/api/v1/admin/backups/plan", headers=auth(pair))
    assert response.status_code == 200
    return client, pair, response.json()["manifest"]


def _validate(client, pair, manifest):
    return client.post(
        "/api/v1/admin/backups/restore/validate",
        headers=auth(pair),
        json={"manifest": manifest},
    )


def _resource(manifest, identifier):
    return next(item for item in manifest["resources"] if item["id"] == identifier)


def _add_component(manifest, index, byte_length):
    service_id = f"synthetic{index}"
    resource_id = f"component-{service_id}-data"
    manifest["components"].append(
        {
            "serviceId": service_id,
            "serviceVersion": "1.0.0",
            "configSchemaVersion": 1,
            "dataSchemaVersion": "1",
            "volumeResourceIds": [resource_id],
        }
    )
    manifest["resources"].append(
        {
            "id": resource_id,
            "kind": "componentData",
            "version": "component-v1",
            "byteLength": byte_length,
            "sha256": f"{index:064x}",
        }
    )


@pytest.mark.parametrize(
    ("identifier", "maximum"),
    [
        ("core-database", backup_service.MAX_DATABASE_BYTES),
        ("family-board", backup_service.MAX_FAMILY_BOARD_BYTES),
    ],
)
def test_restore_preflight_caps_core_database_and_family_board(
    server, identifier, maximum
):
    client, pair, manifest = _manifest(server)
    _resource(manifest, identifier)["byteLength"] = maximum

    exact = _validate(client, pair, manifest)

    assert exact.status_code == 200
    assert exact.json() == {"compatible": True, "reasons": []}

    _resource(manifest, identifier)["byteLength"] = maximum + 1
    overflow = _validate(client, pair, manifest)

    assert overflow.status_code == 400
    assert overflow.json()["error"]["code"] == "invalid_request"


def test_restore_preflight_caps_each_component_volume(server):
    client, pair, manifest = _manifest(server)
    _add_component(manifest, 1, backup_service.MAX_COMPONENT_VOLUME_BYTES)

    exact = _validate(client, pair, manifest)

    assert exact.status_code == 200
    assert exact.json() == {
        "compatible": False,
        "reasons": ["component_version_mismatch"],
    }

    _resource(manifest, "component-synthetic1-data")["byteLength"] += 1
    overflow = _validate(client, pair, manifest)

    assert overflow.status_code == 400
    assert overflow.json()["error"]["code"] == "invalid_request"


def test_restore_preflight_caps_aggregate_component_volumes(server):
    client, pair, manifest = _manifest(server)
    for index in range(4):
        _add_component(manifest, index, backup_service.MAX_COMPONENT_VOLUME_BYTES)

    exact = _validate(client, pair, manifest)

    assert exact.status_code == 200
    assert exact.json() == {
        "compatible": False,
        "reasons": ["component_version_mismatch"],
    }

    overflow = copy.deepcopy(manifest)
    _add_component(overflow, 4, 1)
    rejected = _validate(client, pair, overflow)

    assert rejected.status_code == 400
    assert rejected.json()["error"]["code"] == "invalid_request"
