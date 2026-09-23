import pytest
from larenor_server.core_backups.models import (
    BACKUP_ACTIVE_BLOCKER_ORDER,
    BackupPlanResponse,
)
from larenor_server.core_backups.service import _ACTIVE
from pydantic import ValidationError


def test_backup_plan_order_is_bound_to_the_capture_service():
    assert tuple(item[2] for item in _ACTIVE) == BACKUP_ACTIVE_BLOCKER_ORDER


@pytest.mark.parametrize(
    "blockers",
    [
        ["active_plugin_job", "active_plugin_job"],
        ["active_plugin_job", "active_bounded_transfer"],
        ["active_bounded_transfer", "component_quiescence_timeout"],
        ["component_quiescence_timeout", "component_quiescence_unavailable"],
    ],
)
def test_backup_plan_rejects_noncanonical_blocker_sets(blockers):
    with pytest.raises(ValidationError):
        BackupPlanResponse(status="blocked", blockers=blockers, manifest=None)


@pytest.mark.parametrize(
    "blockers",
    [
        ["active_bounded_transfer", "active_plugin_job"],
        ["active_plugin_job", "active_media_installation"],
        ["component_quiescence_timeout"],
        ["component_quiescence_unavailable"],
    ],
)
def test_backup_plan_accepts_canonical_service_outputs(blockers):
    plan = BackupPlanResponse(status="blocked", blockers=blockers, manifest=None)

    assert plan.blockers == blockers
