"""S09.2 Linux restore authority and descriptor-bound publication."""

import importlib
import importlib.util

import pytest

from larenor_server.core_backups.component_restore import (
    ComponentRestorePlanError,
    plan_component_restore,
)
from test_core_backup_component_docker_adapter import installed_authority
from test_core_backup_component_restore import capture


def api():
    name = "larenor_server.core_backups.component_linux_restore"
    assert importlib.util.find_spec(name) is not None, (
        "Linux component restore adapter is absent"
    )
    return importlib.import_module(name)


def test_durable_receipts_map_to_secret_free_exact_restore_authority(server, tmp_path):
    with installed_authority(tmp_path) as (authority, receipt, _binding, _volumes):
        restore_authority = api().DurableComponentRestoreAuthority(authority)
        targets = restore_authority.snapshot()
        plan = plan_component_restore(capture(server), restore_authority)

    assert len(targets) == 1
    target = targets[0]
    assert target.service_id == receipt.service_id
    assert target.installation_id == receipt.installation_id
    assert target.installation_revision > 0
    assert tuple(item.volume_id for item in target.volumes) == tuple(
        item.volume_id for item in receipt.volumes
    )
    assert all(len(item.binding_id) == 64 for item in target.volumes)
    assert tuple(item.binding_revision for item in target.volumes) == tuple(
        item.intent.receipt.revision for item in receipt.volumes
    )
    assert plan.targets[0].installation_revision == target.installation_revision
    assert repr(target) == "ComponentRestoreAuthorityTarget(<private>)"


def test_authority_rejects_receipt_drift_without_publishing_foreign_target(
    server, tmp_path
):
    with installed_authority(tmp_path) as (authority, _receipt, _binding, volumes):
        restore_authority = api().DurableComponentRestoreAuthority(authority)
        opened = capture(server)
        restore_authority.snapshot()
        volumes._db.execute(
            "UPDATE resources SET revision=revision+1 WHERE resource_id="
            "(SELECT resource_id FROM resources ORDER BY resource_id LIMIT 1)"
        )

        with pytest.raises(
            ComponentRestorePlanError,
            match="^component_restore_unavailable$",
        ):
            plan_component_restore(opened, restore_authority)
