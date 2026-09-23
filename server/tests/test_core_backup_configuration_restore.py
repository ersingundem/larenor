"""S09.1 restore compatibility for backed-up Core worker topology."""

import pytest
from conftest import auth, ready

from larenor_server.config import Settings
from larenor_server.core_backups.restore import restore_empty
from larenor_server.errors import ApiError

PASSPHRASE = "Correct horse battery staple 2026"


@pytest.mark.parametrize(
    "worker_paths",
    [
        ("installation_worker_socket",),
        (
            "keenetic_worker_socket",
            "keenetic_worker_health",
            "keenetic_worker_key_file",
        ),
        ("plugin_worker_socket",),
        ("proxmox_power_worker_socket", "proxmox_power_worker_health"),
    ],
)
def test_restore_rejects_worker_topology_drift_before_staging(
    server, tmp_path, worker_paths
):
    app, client, _settings, clock = server
    pair = ready(server)
    response = client.post(
        "/api/v1/admin/backups/export",
        headers=auth(pair),
        json={"passphrase": PASSPHRASE},
    )
    assert response.status_code == 200
    root = (tmp_path / "restored").resolve()
    configured = {
        name: root / f"run/{name}"
        for name in worker_paths
    }
    target = Settings(
        root / "data",
        root / "secrets/vault.key",
        clock=clock,
        **configured,
    )

    with pytest.raises(ApiError) as rejected:
        restore_empty(target, response.content, PASSPHRASE)

    assert rejected.value.code == "backup_incompatible"
    assert not target.database_file.exists()
    assert not target.key_file.exists()
    assert not list(target.data_dir.glob(".restore-*"))
    assert not (target.data_dir / ".restore-state.json").exists()
    assert all(
        getattr(app.state.core.core_backups.settings, name) is None
        for name in worker_paths
    )
