"""S09.1 durable installed-component authority from private journals."""

import pytest

from larenor_server.core_backups.component_installation_authority import (
    ComponentInstallationAuthorityError,
    DurableComponentInstallationAuthority,
    InstalledComponentReceipt,
    InstalledComponentVolumeReceipt,
)
from larenor_server.plugins.managed_container import (
    JournaledManagedContainerOperations,
    ManagedWorkerJournal,
)
from larenor_server.plugins.volume_create_journal import VolumeCreateJournal
from larenor_server.plugins.volume_plan import build_volume_plan
from test_managed_container_binding import Engine, build, command, source
from test_volume_journal import observe


def volume_inputs():
    catalog, stack, policy = source()
    return {
        'plan': build_volume_plan(stack, catalog, policy),
        'stack': stack,
        'catalog': catalog,
        'policy': policy,
    }


def install_container(journal):
    _builder, _stack, binding = build(container_journal_id=journal.identity)
    worker = JournaledManagedContainerOperations(journal, Engine(binding))
    worker.apply(command(binding), binding)
    worker.apply(command(binding, 'start_container', '8' * 32), binding)
    return binding


def ready_volume(journal, data, resource):
    journal.prepare(**data, resource_id=resource.resourceId)
    journal.begin_create(resource.resourceId, 1, **data)
    journal.reconcile(resource.resourceId, 2, observe, **data)


def test_snapshot_joins_exact_catalog_appdata_receipts_and_excludes_library(tmp_path):
    data = volume_inputs()
    selected = tuple(
        item for item in data['plan'].resources if item.serviceId == 'jellyfin'
    )
    with (
        ManagedWorkerJournal(tmp_path / 'containers', initialize=True) as containers,
        VolumeCreateJournal(tmp_path / 'volumes', initialize=True) as volumes,
    ):
        binding = install_container(containers)
        with volumes.locked():
            for resource in selected:
                ready_volume(volumes, data, resource)

        authority = DurableComponentInstallationAuthority(containers, volumes)
        snapshot = authority.snapshot()

        assert len(snapshot) == 1 and type(snapshot[0]) is InstalledComponentReceipt
        component = snapshot[0]
        assert component.service_id == 'jellyfin'
        assert component.installation_id == binding.name.removeprefix('larenor-')
        assert component.container_id == '5' * 64
        assert component.service_version == '10.11.11'
        assert component.config_schema_version == 1
        assert component.data_schema_version == 'upstream_managed_unverified'
        assert [item.volume_id for item in component.volumes] == [
            'jellyfin-cache', 'jellyfin-config',
        ]
        assert all(type(item) is InstalledComponentVolumeReceipt
                   and item.intent.receipt.state == 'observed_requires_bootstrap'
                   and item.intent.binding.resource.kind == 'managed_appdata'
                   for item in component.volumes)
        assert not any(item.intent.binding.resource.target == '/media'
                       for item in component.volumes)
        assert repr(component) == 'InstalledComponentReceipt(<private>)'
        assert repr(component.volumes[0]) == 'InstalledComponentVolumeReceipt(<private>)'
        assert authority.snapshot() == snapshot


@pytest.mark.parametrize('state', ['missing', 'prepared'])
def test_snapshot_rejects_incomplete_or_nonready_appdata_receipts(tmp_path, state):
    data = volume_inputs()
    appdata = tuple(item for item in data['plan'].resources
                    if item.serviceId == 'jellyfin'
                    and item.kind == 'managed_appdata')
    library = next(item for item in data['plan'].resources
                   if item.kind == 'managed_library')
    with (
        ManagedWorkerJournal(tmp_path / 'containers', initialize=True) as containers,
        VolumeCreateJournal(tmp_path / 'volumes', initialize=True) as volumes,
    ):
        install_container(containers)
        with volumes.locked():
            ready_volume(volumes, data, appdata[0])
            ready_volume(volumes, data, library)
            if state == 'prepared':
                volumes.prepare(**data, resource_id=appdata[1].resourceId)
        authority = DurableComponentInstallationAuthority(containers, volumes)
        with pytest.raises(
            ComponentInstallationAuthorityError,
            match='^installation_authority_unavailable$',
        ):
            authority.snapshot()
