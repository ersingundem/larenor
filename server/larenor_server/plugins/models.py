"""Immutable, strict offline catalog and calculated-plan contracts.

These models describe requested effects, never observed host capacity or permission
to install. Only a later worker policy may resolve a storage-root identifier.
"""

import re
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, StrictBool, model_validator


Digest = Annotated[str, Field(pattern=r"^[0-9a-f]{64}$")]
ImageDigest = Annotated[str, Field(pattern=r"^sha256:[0-9a-f]{64}$")]
Platform = Literal["linux/amd64", "linux/arm64"]
ServiceId = Literal["jellyfin", "seerr", "sonarr", "radarr", "qbittorrent", "music_assistant"]
SettingName = Literal["instanceName", "dataRootId", "webPort", "torrentPort", "libraryRootId", "mediaRootId", "musicRootId"]
SettingValue = str | int | None
RootId = Annotated[str, Field(pattern=r"^[a-z][a-z0-9_-]{0,31}$")]
InstanceName = Annotated[str, Field(pattern=r"^[a-z][a-z0-9-]{0,39}$")]
Port = Annotated[int, Field(ge=1, le=65535)]
Text = Annotated[str, Field(min_length=1, max_length=240, pattern=r"^[^\x00-\x1f\x7f]+$")]
HttpsUrl = Annotated[str, Field(min_length=10, max_length=300, pattern=r"^https://[A-Za-z0-9._/-]+$")]
TargetPath = Annotated[str, Field(pattern=r"^/[a-z][a-z0-9_/]{0,79}$")]


class FrozenModel(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)


class ImagePlatform(FrozenModel):
    platform: Platform
    digest: ImageDigest
    configDigest: ImageDigest


class SecurityProfile(FrozenModel):
    user: Literal["1000:1000", "0:0"]
    privileged: StrictBool
    capDrop: tuple[Literal["ALL"], ...] = Field(min_length=1, max_length=1)
    capAdd: tuple[Literal["NET_BIND_SERVICE"], ...] = Field(max_length=1)
    noNewPrivileges: StrictBool
    init: StrictBool

    @model_validator(mode="after")
    def bounded_privileges(self):
        if self.privileged or not self.noNewPrivileges:
            raise ValueError("invalid_security_profile")
        return self


class ResourceProfile(FrozenModel):
    memoryMiB: int = Field(ge=128, le=16384)
    cpuMillis: int = Field(ge=100, le=16000)
    pidsLimit: int = Field(ge=32, le=4096)
    minimumDiskMiB: int = Field(ge=1024, le=1048576)


class Listener(FrozenModel):
    protocol: Literal["tcp", "udp"]
    port: Port
    purpose: Literal["web", "stream", "torrent", "airplay_ptp_event", "airplay_ptp_general"]


class NetworkProfile(FrozenModel):
    mode: Literal["bridge", "host"]
    listeners: tuple[Listener, ...] = Field(min_length=1, max_length=8)
    dynamicReceiverPorts: StrictBool


class PortBinding(FrozenModel):
    protocol: Literal["tcp", "udp"]
    hostIp: Literal["0.0.0.0"]
    hostPort: int = Field(ge=1024, le=65535)
    containerPort: Port


class StorageMount(FrozenModel):
    kind: Literal["managed_appdata", "approved_library"]
    rootId: RootId
    relativePath: Annotated[str, Field(pattern=r"^(?:[a-z][a-z0-9-]{0,39}/(?:config|cache|data))?$")]
    target: TargetPath
    readOnly: StrictBool

    @model_validator(mode="after")
    def storage_boundary(self):
        if self.kind == "managed_appdata" and (not self.relativePath or self.readOnly):
            raise ValueError("invalid_storage_profile")
        if self.kind == "approved_library" and self.relativePath:
            raise ValueError("invalid_storage_profile")
        return self


class TmpfsMount(FrozenModel):
    target: Literal["/tmp", "/run"]
    sizeMiB: int = Field(ge=16, le=512)
    uid: int = Field(ge=0, le=1000)
    gid: int = Field(ge=0, le=1000)
    executable: StrictBool

    @model_validator(mode="after")
    def fixed_ownership(self):
        if self.uid not in (0, 1000) or self.gid not in (0, 1000):
            raise ValueError("invalid_tmpfs_ownership")
        return self


class EnvironmentValue(FrozenModel):
    name: Literal["TZ", "PORT", "WEBUI_PORT", "TORRENTING_PORT", "LOG_LEVEL"]
    value: Annotated[str, Field(min_length=1, max_length=80, pattern=r"^[A-Za-z0-9/_-]+$")]


class HealthProfile(FrozenModel):
    profile: Literal["jellyfin_public", "seerr_public", "sonarr_public", "radarr_public", "qbittorrent_web", "music_assistant_info"]
    path: Annotated[str, Field(pattern=r"^/[A-Za-z0-9/_-]*$")]
    port: Port


def valid_setting(kind: str, value: SettingValue, minimum: int | None, maximum: int | None) -> bool:
    if kind == "port":
        return type(value) is int and minimum is not None and maximum is not None and minimum <= value <= maximum
    if kind == "optional_root_id" and value is None:
        return True
    expression = r"[a-z][a-z0-9-]{0,39}" if kind == "slug" else r"[a-z][a-z0-9_-]{0,31}"
    return type(value) is str and re.fullmatch(expression, value) is not None


class SettingSpec(FrozenModel):
    name: SettingName
    kind: Literal["slug", "root_id", "optional_root_id", "port"]
    default: SettingValue
    minimum: int | None
    maximum: int | None

    @model_validator(mode="after")
    def bounded_default(self):
        if self.kind == "port":
            if self.minimum != 1024 or self.maximum != 65535:
                raise ValueError("invalid_setting_spec")
        elif self.minimum is not None or self.maximum is not None:
            raise ValueError("invalid_setting_spec")
        if not valid_setting(self.kind, self.default, self.minimum, self.maximum):
            raise ValueError("invalid_setting_default")
        return self


class Setting(FrozenModel):
    name: SettingName
    value: SettingValue


class PluginManifest(FrozenModel):
    manifestVersion: int = Field(ge=1, le=1)
    configSchemaVersion: int = Field(ge=1, le=1)
    dataSchemaVersion: Literal["upstream_managed_unverified"]
    serviceId: ServiceId
    integrationRole: Literal["managed_service", "internal_engine"]
    distributionId: Literal["upstream", "linuxserver"]
    displayName: Text
    version: Annotated[str, Field(pattern=r"^[A-Za-z0-9._-]{1,80}$")]
    upstreamRepository: HttpsUrl
    sourceRepository: HttpsUrl
    sourceRevision: Annotated[str, Field(pattern=r"^[0-9a-f]{40}$")]
    releaseUrl: HttpsUrl
    license: Text
    licenseUrl: HttpsUrl
    distributionLicense: Text
    documentationUrls: tuple[HttpsUrl, ...] = Field(min_length=1, max_length=5)
    verifiedAt: Literal["2026-09-05"]
    repository: Annotated[str, Field(pattern=r"^ghcr\.io/[a-z0-9-]+/[a-z0-9-]+$")]
    tag: Annotated[str, Field(pattern=r"^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$")]
    indexDigest: ImageDigest
    images: tuple[ImagePlatform, ...] = Field(min_length=1, max_length=2)
    installable: StrictBool
    settings: tuple[SettingSpec, ...] = Field(min_length=2, max_length=6)
    security: SecurityProfile
    network: NetworkProfile
    mounts: tuple[StorageMount, ...] = Field(min_length=1, max_length=3)
    ports: tuple[PortBinding, ...] = Field(max_length=3)
    tmpfs: tuple[TmpfsMount, ...] = Field(max_length=2)
    environment: tuple[EnvironmentValue, ...] = Field(max_length=4)
    resources: ResourceProfile
    health: HealthProfile
    warnings: tuple[Text, ...] = Field(max_length=12)

    @model_validator(mode="after")
    def unique_and_disabled(self):
        if self.installable:
            raise ValueError("worker_unverified")
        if (self.serviceId == "music_assistant") != (self.integrationRole == "internal_engine"):
            raise ValueError("invalid_integration_role")
        for values in (tuple(i.platform for i in self.images), tuple(s.name for s in self.settings),
                       tuple(m.target for m in self.mounts), tuple(e.name for e in self.environment)):
            if len(values) != len(set(values)):
                raise ValueError("duplicate_manifest_item")
        if self.network.mode == "host" and (self.serviceId != "music_assistant" or self.ports):
            raise ValueError("invalid_network_profile")
        if self.serviceId != "music_assistant" and (self.security.capAdd or self.security.user != "1000:1000"):
            raise ValueError("invalid_security_profile")
        return self


class CatalogManifest(FrozenModel):
    schemaVersion: int = Field(ge=1, le=1)
    version: Literal["2026-09-05.1"]
    entries: tuple[PluginManifest, ...] = Field(min_length=6, max_length=6)

    @model_validator(mode="after")
    def unique_services(self):
        if len({entry.serviceId for entry in self.entries}) != 6:
            raise ValueError("duplicate_manifest_item")
        return self


class CatalogEntry(FrozenModel):
    catalogDigest: Digest
    manifestDigest: Digest
    manifest: PluginManifest


class Catalog(FrozenModel):
    digest: Digest
    entries: tuple[CatalogEntry, ...] = Field(min_length=6, max_length=6)


class SelectedImage(FrozenModel):
    repository: Annotated[str, Field(pattern=r"^ghcr\.io/[a-z0-9-]+/[a-z0-9-]+$")]
    tag: Annotated[str, Field(pattern=r"^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$")]
    platform: Platform
    digest: ImageDigest
    indexDigest: ImageDigest
    reference: Annotated[str, Field(pattern=r"^ghcr\.io/[a-z0-9-]+/[a-z0-9-]+:[A-Za-z0-9_][A-Za-z0-9._-]{0,127}@sha256:[0-9a-f]{64}$")]


class InstallPlan(FrozenModel):
    schemaVersion: int = Field(ge=1, le=1)
    serviceId: ServiceId
    integrationRole: Literal["managed_service", "internal_engine"]
    distributionId: Literal["upstream", "linuxserver"]
    instanceName: InstanceName
    catalogDigest: Digest
    manifestDigest: Digest
    planHash: Digest
    installable: StrictBool
    blockers: tuple[Literal["worker_unverified", "host_preflight_required"], ...]
    settings: tuple[Setting, ...] = Field(min_length=2, max_length=6)
    image: SelectedImage
    security: SecurityProfile
    network: NetworkProfile
    mounts: tuple[StorageMount, ...] = Field(min_length=1, max_length=3)
    ports: tuple[PortBinding, ...] = Field(max_length=3)
    tmpfs: tuple[TmpfsMount, ...] = Field(max_length=2)
    environment: tuple[EnvironmentValue, ...] = Field(max_length=4)
    resources: ResourceProfile
    health: HealthProfile
    warnings: tuple[Text, ...] = Field(max_length=12)

    @model_validator(mode="after")
    def capability_disabled(self):
        if self.installable or self.blockers != ("worker_unverified", "host_preflight_required"):
            raise ValueError("worker_unverified")
        return self
