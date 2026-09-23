"""Durable journal authority for the exact installed component volume set."""

from dataclasses import dataclass, field, fields
import math
from pathlib import Path
import re
import threading
import time

from ..plugins.catalog import load_catalog
from ..plugins.managed_container import (
    ManagedInstalledContainer,
    ManagedWorkerJournal,
)
from ..plugins.volume_create_journal import (
    VolumeCreateIntent,
    VolumeCreateJournal,
)
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
    def _catalog():
        catalog = load_catalog()
        return catalog, {
            entry.manifest.serviceId: (entry, entry.manifest)
            for entry in catalog.entries
        }

    @staticmethod
    def _component(installed, intents, catalog, entries):
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
        current = entries.get(service_id)
        if current is None:
            raise ComponentInstallationAuthorityError()
        entry, manifest = current
        expected = {
            (mount.target, f"{service_id}-{mount.relativePath.rsplit('/', 1)[-1]}")
            for mount in manifest.mounts
            if mount.kind == "managed_appdata"
        }
        if len(candidates) != len(expected):
            raise ComponentInstallationAuthorityError()
        mounted = {item.name: item for item in installed.binding.mounts}
        receipts = []
        observed = set()
        for intent in candidates:
            resource = intent.binding.resource
            source = intent.binding.source
            if (
                type(source) is not tuple
                or len(source) != 4
                or source[2] != catalog
                or source[0].catalogDigest != catalog.digest
                or intent.receipt.state != "observed_requires_bootstrap"
            ):
                raise ComponentInstallationAuthorityError()
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
        if observed != expected:
            raise ComponentInstallationAuthorityError()
        return InstalledComponentReceipt(
            service_id,
            installed.installation_id,
            installed.container_id,
            manifest.version,
            manifest.configSchemaVersion,
            manifest.dataSchemaVersion,
            installed,
            tuple(sorted(receipts, key=lambda item: item.volume_id)),
        )

    def _read(self):
        catalog, entries = self._catalog()
        with self._containers.locked(), self._volumes.locked():
            installed = self._containers.installed()
            intents = self._volumes.intents()
            result = tuple(
                sorted(
                    (
                        self._component(item, intents, catalog, entries)
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
