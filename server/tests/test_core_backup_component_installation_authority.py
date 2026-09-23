"""S09.1 durable installed-component authority from private journals."""

from dataclasses import replace
import json
import time

import pytest

import larenor_server.core_backups.component_installation_authority as authority_module
from larenor_server.core_backups.component_installation_authority import (
    ComponentInstallationAuthorityError,
    DurableComponentInstallationAuthority,
    InstalledComponentReceipt,
    InstalledComponentVolumeReceipt,
)
from larenor_server.core_backups.component_snapshot_provider import ComponentVolumeSource
from larenor_server.plugins.managed_container import (
    JournaledManagedContainerOperations,
    ManagedWorkerJournal,
)
from larenor_server.plugins.worker import WorkerStep
from larenor_server.plugins.volume_create_journal import VolumeCreateJournal
from larenor_server.plugins.volume_plan import build_volume_plan
from test_managed_container_binding import (
    Engine, build, build_qbittorrent, command, source,
)
from test_volume_journal import observe


def volume_inputs():
    catalog, stack, policy = source()
    return {
        'plan': build_volume_plan(stack, catalog, policy),
        'stack': stack,
        'catalog': catalog,
        'policy': policy,
    }


def install_container(journal, binding=None):
    if binding is None:
        _builder, _stack, binding = build(container_journal_id=journal.identity)
    worker = JournaledManagedContainerOperations(journal, Engine(binding))
    worker.apply(command(binding), binding)
    worker.apply(command(binding, 'start_container', '8' * 32), binding)
    return binding


def drifted_binding(journal, damage):
    _builder, _stack, binding = build(container_journal_id=journal.identity)
    specification = json.loads(binding.specification)
    if damage in {'plan', 'catalog', 'manifest'}:
        specification['Labels']['org.larenor.' + damage] = '9' * 64
    elif damage == 'image':
        binding = replace(binding, image_id='sha256:' + '9' * 64)
        specification['Image'] = specification['Image'].rsplit('@', 1)[0] + (
            '@sha256:' + '9' * 64
        )
    elif damage == 'config':
        specification['HostConfig']['Memory'] += 1048576
    else:
        raise AssertionError('unknown damage')
    return replace(
        binding,
        specification=json.dumps(
            specification,
            sort_keys=True,
            separators=(',', ':'),
        ).encode(),
    )


def ready_volume(journal, data, resource):
    journal.prepare(**data, resource_id=resource.resourceId)
    journal.begin_create(resource.resourceId, 1, **data)
    journal.reconcile(resource.resourceId, 2, observe, **data)


def snapshot_sources(snapshot, root):
    root.mkdir()
    result = []
    for component in snapshot:
        for volume in component.volumes:
            path = root / volume.volume_id
            path.mkdir()
            identity = path.lstat()
            result.append(ComponentVolumeSource(
                service_id=component.service_id,
                container_id=component.container_id,
                volume_id=volume.volume_id,
                path=path,
                service_version=component.service_version,
                config_schema_version=component.config_schema_version,
                data_schema_version=component.data_schema_version,
                installation_revision=volume.intent.receipt.revision,
                device=identity.st_dev,
                inode=identity.st_ino,
            ))
    return tuple(result)


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


def test_revalidate_requires_the_exact_bound_source_set_and_current_journals(
        tmp_path, monkeypatch):
    data = volume_inputs()
    selected = tuple(item for item in data['plan'].resources
                     if item.serviceId == 'jellyfin')
    with (
        ManagedWorkerJournal(tmp_path / 'containers', initialize=True) as containers,
        VolumeCreateJournal(tmp_path / 'volumes', initialize=True) as volumes,
    ):
        install_container(containers)
        with volumes.locked():
            for resource in selected:
                ready_volume(volumes, data, resource)
        authority = DurableComponentInstallationAuthority(containers, volumes)
        sources = snapshot_sources(authority.snapshot(), tmp_path / 'payloads')
        deadline = time.monotonic() + 2
        assert authority.revalidate(sources, deadline) is True
        assert authority.revalidate(sources, deadline) is True

        malformed = (
            replace(sources[0], installation_revision=4),
            *sources[1:],
        )
        assert authority.revalidate(malformed, deadline) is False
        assert authority.revalidate((sources[0], sources[0]), deadline) is False
        assert authority.revalidate(sources[:1], deadline) is False
        shared_identity = (
            sources[0],
            replace(
                sources[1], path=sources[0].path,
                device=sources[0].device, inode=sources[0].inode,
            ),
        )
        assert authority.revalidate(shared_identity, deadline) is False
        assert authority.revalidate(sources, time.monotonic() - 1) is False

        monkeypatch.setattr(authority_module, 'load_catalog',
                            lambda: (_ for _ in ()).throw(RuntimeError('private drift')))
        assert authority.revalidate(sources, deadline) is False
        monkeypatch.undo()

        volumes._db.execute(
            'UPDATE resources SET revision=revision+1 WHERE resource_id='
            '(SELECT resource_id FROM resources ORDER BY resource_id LIMIT 1)'
        )
        assert authority.revalidate(sources, deadline) is False


def test_snapshot_rejects_two_installed_services_sharing_one_container_identity(
        tmp_path):
    data = volume_inputs()
    selected = tuple(item for item in data['plan'].resources
                     if item.serviceId in {'jellyfin', 'qbittorrent'})
    with (
        ManagedWorkerJournal(tmp_path / 'containers', initialize=True) as containers,
        VolumeCreateJournal(tmp_path / 'volumes', initialize=True) as volumes,
    ):
        install_container(containers)
        _builder, _stack, binding = build_qbittorrent(containers.identity)
        worker = JournaledManagedContainerOperations(containers, Engine(binding))
        worker.apply(WorkerStep(
            '9' * 32, binding.name.removeprefix('larenor-'),
            'create_container', 'a' * 32, time.time() + 30,
        ), binding)
        worker.apply(WorkerStep(
            '9' * 32, binding.name.removeprefix('larenor-'),
            'start_container', 'b' * 32, time.time() + 30,
        ), binding)
        with volumes.locked():
            for resource in selected:
                ready_volume(volumes, data, resource)
        authority = DurableComponentInstallationAuthority(containers, volumes)
        with pytest.raises(
            ComponentInstallationAuthorityError,
            match='^installation_authority_unavailable$',
        ):
            authority.snapshot()


@pytest.mark.parametrize(
    'damage',
    ['plan', 'catalog', 'manifest', 'image', 'config'],
)
def test_snapshot_rejects_stale_or_foreign_installed_binding_against_current_receipts(
        tmp_path, damage):
    data = volume_inputs()
    selected = tuple(
        item for item in data['plan'].resources if item.serviceId == 'jellyfin'
    )
    with (
        ManagedWorkerJournal(tmp_path / 'containers', initialize=True) as containers,
        VolumeCreateJournal(tmp_path / 'volumes', initialize=True) as volumes,
    ):
        install_container(containers, drifted_binding(containers, damage))
        with volumes.locked():
            for resource in selected:
                ready_volume(volumes, data, resource)

        with pytest.raises(
            ComponentInstallationAuthorityError,
            match='^installation_authority_unavailable$',
        ):
            DurableComponentInstallationAuthority(containers, volumes).snapshot()
