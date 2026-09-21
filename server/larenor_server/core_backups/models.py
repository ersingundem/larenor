from typing import Annotated, Literal

from pydantic import Field, StringConstraints, field_validator, model_validator

from ..models import StrictModel

Digest = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")]
SnapshotId = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{32}$")]
SafeVersion = Annotated[
    str, StringConstraints(min_length=1, max_length=64, pattern=r"^[A-Za-z0-9_.+-]+$")
]
ResourceId = Annotated[str, StringConstraints(pattern=r"^[a-z][a-z0-9-]{0,39}$")]
Reason = Literal[
    "unsupported_contract_version",
    "database_schema_mismatch",
    "core_version_mismatch",
    "component_schema_mismatch",
]
Blocker = Literal[
    "active_bounded_transfer",
    "active_plugin_job",
    "active_media_inspection",
    "active_media_installation",
    "active_media_bootstrap",
    "active_qbittorrent_configuration",
    "active_arr_configuration",
    "active_seerr_bootstrap",
    "active_music_assistant_bootstrap",
    "active_keenetic_command",
    "active_tablet_command",
]


class BackupResource(StrictModel):
    id: ResourceId
    kind: Literal["database", "vaultKey", "configuration", "componentData"]
    version: SafeVersion
    byteLength: Annotated[int, Field(ge=1, le=512 * 1024 * 1024)]
    sha256: Digest


class BackupManifest(StrictModel):
    contractVersion: Annotated[int, Field(ge=1, le=2**31 - 1)]
    snapshotId: SnapshotId
    createdAt: Annotated[int, Field(ge=0, le=2**63 - 1)]
    coreVersion: SafeVersion
    databaseSchemaVersion: Annotated[int, Field(ge=1, le=2**31 - 1)]
    componentSchemaVersions: dict[str, int] = Field(max_length=128)
    resources: list[BackupResource] = Field(min_length=4, max_length=4)

    @field_validator("componentSchemaVersions", mode="before")
    @classmethod
    def component_versions(cls, value):
        if not isinstance(value, dict) or any(
            type(key) is not str
            or not key
            or len(key) > 64
            or not key.replace("_", "a").isalnum()
            or type(version) is not int
            or not 1 <= version <= 2**31 - 1
            for key, version in value.items()
        ):
            raise ValueError("invalid_component_versions")
        return value

    @model_validator(mode="after")
    def exact_resource_set(self):
        expected = {
            "component-index": "componentData",
            "core-configuration": "configuration",
            "core-database": "database",
            "vault-key": "vaultKey",
        }
        found = {resource.id: resource.kind for resource in self.resources}
        if found != expected or len(found) != len(self.resources):
            raise ValueError("invalid_backup_resources")
        versions = {resource.id: resource.version for resource in self.resources}
        if versions != {
            "component-index": "1",
            "core-configuration": "1",
            "core-database": str(self.databaseSchemaVersion),
            "vault-key": "aes256-v1",
        }:
            raise ValueError("invalid_backup_resource_versions")
        return self


class BackupPlanResponse(StrictModel):
    status: Literal["ready", "blocked"]
    blockers: list[Blocker] = Field(max_length=11)
    manifest: BackupManifest | None

    @model_validator(mode="after")
    def coherent_state(self):
        if (self.status == "ready") != (
            not self.blockers and self.manifest is not None
        ):
            raise ValueError("invalid_backup_plan")
        if self.status == "blocked" and (
            not self.blockers or self.manifest is not None
        ):
            raise ValueError("invalid_backup_plan")
        return self


class RestoreValidationRequest(StrictModel):
    manifest: BackupManifest


class RestoreValidationResponse(StrictModel):
    compatible: bool
    reasons: list[Reason] = Field(max_length=4)

    @model_validator(mode="after")
    def coherent_result(self):
        if self.compatible == bool(self.reasons):
            raise ValueError("invalid_restore_validation")
        return self
