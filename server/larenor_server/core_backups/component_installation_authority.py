"""Durable journal authority for the exact installed component volume set."""

from dataclasses import dataclass, field, fields
import math
from pathlib import Path
import re
import threading
import time

from ..plugins.component_updates import (
    ComponentUpdateCommand,
    ComponentUpdateError,
    installed_update_source,
    verify_installed_update_source,
    verify_update_command,
)
from ..plugins.image_resources import ImageObservation, _ImageBinding, image_binding
from ..plugins.managed_container import (
    JellyfinBindingBuilder,
    ManagedImageProof,
    ManagedInstalledContainer,
    ManagedNetworkProof,
    ManagedVolumeProof,
    ManagedWorkerJournal,
    VerifiedJellyfinResources,
)
from ..plugins.resource_models import ResourcePreparationPlan, WorkerPolicyBinding
from ..plugins.resource_plan import build_resource_plan
from ..plugins.stack_plan import MediaStackPlan, build_media_stack_plan
from ..plugins.volume_create_journal import (
    VolumeCreateIntent,
    VolumeCreateJournal,
)
from ..plugins.volume_plan import VolumeStoragePlan, build_volume_plan
from ..plugins.models import Catalog, CatalogEntry
from ..context import ContextResponse
from .component_snapshot_provider import ComponentVolumeSource


_VOLUME_ID = re.compile(r"[a-z][a-z0-9-]{0,127}\Z")


class ComponentInstallationAuthorityError(RuntimeError):
    """Static failure; journal payloads, paths and identities stay private."""

    def __init__(self):
        super().__init__("installation_authority_unavailable")


def _exact(value, kind):
    return type(value) is kind and set(vars(value)) == {
        item.name for item in fields(kind)
    }


@dataclass(frozen=True, repr=False)
class InstalledComponentVolumeReceipt:
    volume_id: str
    target: str
    intent: VolumeCreateIntent = field(repr=False)

    def __post_init__(self):
        try:
            resource = self.intent.binding.resource
            if (
                not _exact(self.intent, VolumeCreateIntent)
                or type(self.volume_id) is not str
                or _VOLUME_ID.fullmatch(self.volume_id) is None
                or type(self.target) is not str
                or self.target != resource.target
                or resource.kind != "managed_appdata"
                or self.intent.receipt.state != "observed_requires_bootstrap"
                or type(self.intent.receipt.revision) is not int
                or self.intent.receipt.revision < 3
            ):
                raise ValueError()
        except (AttributeError, TypeError, ValueError):
            raise ComponentInstallationAuthorityError() from None

    def __repr__(self):
        return "InstalledComponentVolumeReceipt(<private>)"


@dataclass(frozen=True, repr=False)
class InstalledComponentReceipt:
    service_id: str
    installation_id: str
    container_id: str
    service_version: str
    config_schema_version: int
    data_schema_version: str
    catalog_digest: str
    catalog_entry: CatalogEntry = field(repr=False)
    installed: ManagedInstalledContainer = field(repr=False)
    volumes: tuple[InstalledComponentVolumeReceipt, ...] = field(repr=False)

    def __post_init__(self):
        try:
            if (
                not _exact(self.installed, ManagedInstalledContainer)
                or self.installation_id != self.installed.installation_id
                or self.container_id != self.installed.container_id
                or type(self.service_id) is not str
                or type(self.service_version) is not str
                or type(self.config_schema_version) is not int
                or type(self.data_schema_version) is not str
                or type(self.catalog_digest) is not str
                or type(self.catalog_entry) is not CatalogEntry
                or self.catalog_entry.catalogDigest != self.catalog_digest
                or self.catalog_entry.manifest.serviceId != self.service_id
                or self.catalog_entry.manifest.version != self.service_version
                or type(self.volumes) is not tuple
                or not self.volumes
                or any(
                    not _exact(item, InstalledComponentVolumeReceipt)
                    or item.intent.binding.resource.serviceId != self.service_id
                    or item.intent.binding.resource.installationId
                    != self.installation_id
                    for item in self.volumes
                )
                or tuple(sorted(self.volumes, key=lambda item: item.volume_id))
                != self.volumes
            ):
                raise ValueError()
        except (AttributeError, TypeError, ValueError):
            raise ComponentInstallationAuthorityError() from None

    def __repr__(self):
        return "InstalledComponentReceipt(<private>)"


@dataclass(frozen=True, repr=False)
class ComponentUpdatePreparation:
    command: ComponentUpdateCommand
    current: InstalledComponentReceipt
    stack: MediaStackPlan = field(repr=False)
    catalog: Catalog = field(repr=False)
    policy: WorkerPolicyBinding = field(repr=False)
    resource_plan: ResourcePreparationPlan = field(repr=False)
    volume_plan: VolumeStoragePlan = field(repr=False)
    intents: tuple = field(repr=False)
    image: _ImageBinding = field(repr=False)

    def __repr__(self):
        return "ComponentUpdatePreparation(<private>)"


class DurableComponentInstallationAuthority:
    """Join exact terminal container and volume receipts under both locks."""

    def __init__(self, containers, volumes):
        if (
            type(containers) is not ManagedWorkerJournal
            or type(volumes) is not VolumeCreateJournal
        ):
            raise ComponentInstallationAuthorityError()
        self._containers = containers
        self._volumes = volumes
        self._mutex = threading.Lock()
        self._expected = None
        self._sources = None

    @staticmethod
    def _current_binding(installed, intents, stack, catalog, policy, service_id):
        """Re-derive the stored effect from current durable resource receipts."""
        binding = installed.binding
        by_resource = {
            intent.binding.resource.resourceId: intent for intent in intents
        }
        if len(by_resource) != len(intents):
            raise ComponentInstallationAuthorityError()

        def proof(resource_plan, volume_plan, component):
            image = next(
                item
                for item in resource_plan.resources
                if item.kind == "ensure_image" and item.serviceId == service_id
            )
            network = resource_plan.resources[-1]
            mounted = {item.name for item in binding.mounts}
            expected_volumes = tuple(
                item for item in volume_plan.resources if item.name in mounted
            )
            if len(expected_volumes) != len(mounted):
                raise ComponentInstallationAuthorityError()
            volumes = []
            for expected in expected_volumes:
                intent = by_resource.get(expected.resourceId)
                if (
                    intent is None
                    or intent.binding.resource != expected
                    or intent.binding.source
                    != (volume_plan, stack, catalog, policy)
                    or intent.receipt.state != "observed_requires_bootstrap"
                    or type(intent.receipt.revision) is not int
                    or intent.receipt.revision < 3
                ):
                    raise ComponentInstallationAuthorityError()
                volumes.append(
                    ManagedVolumeProof(
                        expected.resourceId,
                        expected.operationId,
                        intent.receipt.revision,
                        intent.binding.journal_id,
                        intent.binding.ownership_nonce,
                        expected.name,
                        expected.target,
                        True,
                    )
                )
            return VerifiedJellyfinResources(
                stack_plan_hash=resource_plan.stackPlanHash,
                resource_plan_hash=resource_plan.planHash,
                volume_plan_hash=volume_plan.planHash,
                worker_policy_digest=resource_plan.workerPolicyDigest,
                image=ManagedImageProof(
                    image.resourceId,
                    3,
                    binding.image_id,
                    binding.image_configuration,
                ),
                volumes=tuple(volumes),
                # These two identities are proof-local inputs to the pure
                # builder. The derived binding retains only the current
                # resource name and the journaled container's exact network ID.
                network=ManagedNetworkProof(
                    network.resourceId,
                    network.operationId,
                    3,
                    "0" * 32,
                    "1" * 32,
                    network.name,
                    binding.network_id,
                ),
            )

        expected = JellyfinBindingBuilder(
            catalog,
            policy,
            installed.journal_id,
            proof,
            service_id=service_id,
        )(stack)
        if expected != binding:
            raise ComponentInstallationAuthorityError()

    @staticmethod
    def _component(installed, intents):
        candidates = tuple(
            intent
            for intent in intents
            if intent.binding.resource.kind == "managed_appdata"
            and intent.binding.resource.installationId == installed.installation_id
        )
        services = {intent.binding.resource.serviceId for intent in candidates}
        if len(services) != 1:
            raise ComponentInstallationAuthorityError()
        service_id = next(iter(services))
        mounted = {item.name: item for item in installed.binding.mounts}
        receipts = []
        observed = set()
        current_source = None
        catalog = None
        entry = None
        manifest = None
        expected = None
        for intent in candidates:
            resource = intent.binding.resource
            source = intent.binding.source
            if (
                type(source) is not tuple
                or len(source) != 4
                or current_source is not None and source != current_source
                or intent.receipt.state != "observed_requires_bootstrap"
            ):
                raise ComponentInstallationAuthorityError()
            if current_source is None:
                if type(source[2]) is not Catalog:
                    raise ComponentInstallationAuthorityError()
                catalog = Catalog.model_validate_json(source[2].model_dump_json())
                entries = tuple(
                    item
                    for item in catalog.entries
                    if item.manifest.serviceId == service_id
                )
                if (
                    len(entries) != 1
                    or any(item.catalogDigest != catalog.digest for item in catalog.entries)
                    or source[0].catalogDigest != catalog.digest
                ):
                    raise ComponentInstallationAuthorityError()
                entry = entries[0]
                manifest = entry.manifest
                expected = {
                    (
                        mount.target,
                        f"{service_id}-{mount.relativePath.rsplit('/', 1)[-1]}",
                    )
                    for mount in manifest.mounts
                    if mount.kind == "managed_appdata"
                }
                if len(candidates) != len(expected):
                    raise ComponentInstallationAuthorityError()
            current_source = source
            component = next(
                (
                    item
                    for item in source[1].components
                    if item.installationId == installed.installation_id
                ),
                None,
            )
            mount = mounted.get(resource.name)
            identity = (
                resource.target,
                f"{service_id}-{resource.requestedRelativePath.rsplit('/', 1)[-1]}",
            )
            if (
                component is None
                or component.serviceId != service_id
                or component.plan.manifestDigest != entry.manifestDigest
                or expected is None
                or identity not in expected
                or mount is None
                or mount.target != resource.target
                or mount.read_only is not False
            ):
                raise ComponentInstallationAuthorityError()
            observed.add(identity)
            receipts.append(
                InstalledComponentVolumeReceipt(identity[1], resource.target, intent)
            )
        if expected is None or observed != expected:
            raise ComponentInstallationAuthorityError()
        if (
            current_source is None
            or catalog is None
            or entry is None
            or manifest is None
        ):
            raise ComponentInstallationAuthorityError()
        DurableComponentInstallationAuthority._current_binding(
            installed,
            intents,
            current_source[1],
            catalog,
            current_source[3],
            service_id,
        )
        return InstalledComponentReceipt(
            service_id,
            installed.installation_id,
            installed.container_id,
            manifest.version,
            manifest.configSchemaVersion,
            manifest.dataSchemaVersion,
            catalog.digest,
            entry,
            installed,
            tuple(sorted(receipts, key=lambda item: item.volume_id)),
        )

    def _read(self):
        with self._containers.locked(), self._volumes.locked():
            installed = self._containers.installed()
            intents = self._volumes.intents()
            result = tuple(
                sorted(
                    (
                        self._component(item, intents)
                        for item in installed
                    ),
                    key=lambda item: item.service_id,
                )
            )
            services = [item.service_id for item in result]
            containers = [item.container_id for item in result]
            names = [
                volume.intent.binding.resource.name
                for component in result
                for volume in component.volumes
            ]
            resources = [
                volume.intent.binding.resource.resourceId
                for component in result
                for volume in component.volumes
            ]
            if (
                len(services) != len(set(services))
                or len(containers) != len(set(containers))
                or len(names) != len(set(names))
                or len(resources) != len(set(resources))
            ):
                raise ComponentInstallationAuthorityError()
        return result

    def prepare_update(self, command, catalog):
        """Derive one target image proposal from the current durable install."""
        if not self._mutex.acquire(blocking=False):
            raise ComponentInstallationAuthorityError()
        try:
            command = verify_update_command(command)
            if type(catalog) is not Catalog:
                raise ComponentInstallationAuthorityError()
            catalog = Catalog.model_validate_json(catalog.model_dump_json())
            receipts = self._read()
            matches = tuple(
                item
                for item in receipts
                if item.installation_id == command.installationId
                and item.service_id == command.serviceId
            )
            if len(matches) != 1:
                raise ComponentInstallationAuthorityError()
            current = matches[0]
            source = verify_installed_update_source(
                installed_update_source(
                    installation_id=current.installation_id,
                    service_id=current.service_id,
                    service_version=current.service_version,
                    config_schema_version=current.config_schema_version,
                    data_schema_version=current.data_schema_version,
                    platform=current.installed.binding.platform,
                    observed_image_config_digest=current.installed.binding.image_id,
                    catalog_entry=current.catalog_entry,
                    recorded_catalog_digest=current.catalog_digest,
                )
            )
            if source.sourceDigest != command.sourceDigest:
                raise ComponentInstallationAuthorityError()
            with self._volumes.locked():
                intents = self._volumes.intents()
            retained_sources = tuple(
                item.intent.binding.source for item in current.volumes
            )
            if (
                not retained_sources
                or any(item != retained_sources[0] for item in retained_sources[1:])
            ):
                raise ComponentInstallationAuthorityError()
            retained = retained_sources[0]
            if (
                type(retained) is not tuple
                or len(retained) != 4
                or type(retained[1]) is not MediaStackPlan
                or type(retained[3]) is not WorkerPolicyBinding
            ):
                raise ComponentInstallationAuthorityError()
            old_stack = retained[1]
            context = ContextResponse(
                schemaVersion=1,
                coreId=old_stack.coreId,
                homeId=old_stack.homeId,
            )
            stack = build_media_stack_plan(
                catalog,
                old_stack.settings,
                old_stack.platform,
                context,
                old_stack.preparationId,
            )
            policy = WorkerPolicyBinding.model_validate_json(
                retained[3].model_dump_json()
            )
            resource_plan = build_resource_plan(stack, catalog, policy)
            volume_plan = build_volume_plan(stack, catalog, policy)
            component = next(
                item
                for item in stack.components
                if item.serviceId == command.serviceId
            )
            if (
                component.installationId != command.installationId
                or component.plan.manifestDigest != command.targetManifestDigest
            ):
                raise ComponentInstallationAuthorityError()
            mounted = {item.name for item in current.installed.binding.mounts}
            selected_intents = tuple(
                item
                for item in intents
                if item.binding.resource.name in mounted
            )
            expected_volumes = tuple(
                item for item in volume_plan.resources if item.name in mounted
            )
            if (
                len(selected_intents) != len(mounted)
                or len(expected_volumes) != len(mounted)
            ):
                raise ComponentInstallationAuthorityError()
            by_name = {
                item.binding.resource.name: item for item in selected_intents
            }
            for expected in expected_volumes:
                actual = by_name.get(expected.name)
                if actual is None:
                    raise ComponentInstallationAuthorityError()
                old = actual.binding.resource.model_dump(mode="json")
                target = expected.model_dump(mode="json")
                old.pop("childPlanHash", None)
                target.pop("childPlanHash", None)
                if (
                    old != target
                    or actual.receipt.state != "observed_requires_bootstrap"
                    or actual.receipt.revision < 3
                ):
                    raise ComponentInstallationAuthorityError()
            image_resource = next(
                item
                for item in resource_plan.resources
                if item.kind == "ensure_image"
                and item.serviceId == command.serviceId
            )
            return ComponentUpdatePreparation(
                command,
                current,
                stack,
                catalog,
                policy,
                resource_plan,
                volume_plan,
                selected_intents,
                image_binding(
                    resource_plan,
                    stack,
                    catalog,
                    policy,
                    image_resource.resourceId,
                ),
            )
        except ComponentInstallationAuthorityError:
            raise
        except Exception:
            raise ComponentInstallationAuthorityError() from None
        finally:
            self._mutex.release()

    def update_binding(self, preparation, image):
        """Build the exact target container from retained resource receipts."""
        try:
            if (
                type(preparation) is not ComponentUpdatePreparation
                or type(image) is not ImageObservation
                or image.image_id != preparation.image.config_digest
            ):
                raise ComponentInstallationAuthorityError()
            service_id = preparation.command.serviceId
            current = preparation.current
            by_name = {
                item.binding.resource.name: item
                for item in preparation.intents
            }

            def proof(resource_plan, volume_plan, component):
                if (
                    resource_plan != preparation.resource_plan
                    or volume_plan != preparation.volume_plan
                    or component.serviceId != service_id
                ):
                    raise ComponentInstallationAuthorityError()
                image_resource = next(
                    item
                    for item in resource_plan.resources
                    if item.kind == "ensure_image" and item.serviceId == service_id
                )
                expected_volumes = tuple(
                    item
                    for item in volume_plan.resources
                    if item.name in {mount.name for mount in current.installed.binding.mounts}
                )
                volume_proofs = []
                for expected in expected_volumes:
                    intent = by_name.get(expected.name)
                    if intent is None:
                        raise ComponentInstallationAuthorityError()
                    volume_proofs.append(
                        ManagedVolumeProof(
                            expected.resourceId,
                            expected.operationId,
                            intent.receipt.revision,
                            intent.binding.journal_id,
                            intent.binding.ownership_nonce,
                            expected.name,
                            expected.target,
                            True,
                        )
                    )
                network = resource_plan.resources[-1]
                return VerifiedJellyfinResources(
                    stack_plan_hash=resource_plan.stackPlanHash,
                    resource_plan_hash=resource_plan.planHash,
                    volume_plan_hash=volume_plan.planHash,
                    worker_policy_digest=resource_plan.workerPolicyDigest,
                    image=ManagedImageProof(
                        image_resource.resourceId,
                        3,
                        image.image_id,
                        image.configuration,
                    ),
                    volumes=tuple(volume_proofs),
                    network=ManagedNetworkProof(
                        network.resourceId,
                        network.operationId,
                        3,
                        "0" * 32,
                        "1" * 32,
                        network.name,
                        current.installed.binding.network_id,
                    ),
                )

            binding = JellyfinBindingBuilder(
                preparation.catalog,
                preparation.policy,
                current.installed.journal_id,
                proof,
                service_id=service_id,
            )(preparation.stack)
            if (
                binding.name != current.installed.binding.name
                or binding.network_id != current.installed.binding.network_id
                or {item.name for item in binding.mounts}
                != {item.name for item in current.installed.binding.mounts}
            ):
                raise ComponentInstallationAuthorityError()
            return binding
        except ComponentInstallationAuthorityError:
            raise
        except Exception:
            raise ComponentInstallationAuthorityError() from None

    def update_sources(self):
        """Return display-safe F15 identities only for current live receipts."""
        try:
            receipts = self._read()
            return tuple(
                installed_update_source(
                    installation_id=receipt.installation_id,
                    service_id=receipt.service_id,
                    service_version=receipt.service_version,
                    config_schema_version=receipt.config_schema_version,
                    data_schema_version=receipt.data_schema_version,
                    platform=receipt.installed.binding.platform,
                    observed_image_config_digest=receipt.installed.binding.image_id,
                    catalog_entry=receipt.catalog_entry,
                    recorded_catalog_digest=receipt.catalog_digest,
                )
                for receipt in receipts
            )
        except ComponentInstallationAuthorityError:
            raise
        except (ComponentUpdateError, KeyError, TypeError, ValueError):
            raise ComponentInstallationAuthorityError() from None

    @staticmethod
    def _source_set(sources, receipts):
        if type(sources) not in (tuple, list) or len(sources) > 128:
            raise ComponentInstallationAuthorityError()
        expected = {
            (component.service_id, volume.volume_id): (
                component.container_id,
                component.service_version,
                component.config_schema_version,
                component.data_schema_version,
                volume.intent.receipt.revision,
            )
            for component in receipts
            for volume in component.volumes
        }
        selected = []
        identities = set()
        paths = set()
        for value in sources:
            if not _exact(value, ComponentVolumeSource):
                raise ComponentInstallationAuthorityError()
            key = (value.service_id, value.volume_id)
            if (
                key not in expected
                or (
                    value.container_id,
                    value.service_version,
                    value.config_schema_version,
                    value.data_schema_version,
                    value.installation_revision,
                )
                != expected[key]
                or not isinstance(value.path, Path)
                or type(value.device) is not int
                or value.device < 0
                or type(value.inode) is not int
                or value.inode <= 0
                or key in {item[:2] for item in selected}
                or value.path in paths
                or (value.device, value.inode) in identities
            ):
                raise ComponentInstallationAuthorityError()
            selected.append((
                value.service_id,
                value.volume_id,
                value.container_id,
                value.service_version,
                value.config_schema_version,
                value.data_schema_version,
                value.installation_revision,
                value.path,
                value.device,
                value.inode,
            ))
            paths.add(value.path)
            identities.add((value.device, value.inode))
        if {item[:2] for item in selected} != set(expected):
            raise ComponentInstallationAuthorityError()
        return tuple(sorted(selected))

    def snapshot(self):
        if not self._mutex.acquire(blocking=False):
            raise ComponentInstallationAuthorityError()
        try:
            current = self._read()
            if self._expected is None:
                self._expected = current
            elif current != self._expected:
                raise ComponentInstallationAuthorityError()
            return self._expected
        except ComponentInstallationAuthorityError:
            raise
        except Exception:
            raise ComponentInstallationAuthorityError() from None
        finally:
            self._mutex.release()

    def revalidate(self, sources, deadline):
        """Return literal True only for the bound sources and current journals."""
        if (
            type(deadline) not in (int, float)
            or type(deadline) is bool
            or not math.isfinite(deadline)
            or time.monotonic() >= deadline
            or not self._mutex.acquire(blocking=False)
        ):
            return False
        try:
            if self._expected is None:
                return False
            selected = self._source_set(sources, self._expected)
            if self._sources is not None and selected != self._sources:
                return False
            if self._read() != self._expected or time.monotonic() >= deadline:
                return False
            if self._sources is None:
                self._sources = selected
            return True
        except Exception:
            return False
        finally:
            self._mutex.release()
