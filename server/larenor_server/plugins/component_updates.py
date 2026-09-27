"""Pure, fail-closed review contracts for packaged component updates.

The packaged catalog is the trust root for release identity.  An upstream
signature is represented independently because a digest pin is not a
signature, and a signature is not proof that a release is correct.  This
module performs no network, Docker, database or filesystem effects.
"""

from __future__ import annotations

import hashlib
import json
import re
import secrets
from typing import Annotated, Literal

from pydantic import Field, StrictBool, model_validator

from ..context import ContextResponse, Identity
from .catalog import CatalogError, _trusted_entry
from .models import (
    CatalogEntry,
    Digest,
    FrozenModel,
    ImageDigest,
    Platform,
    ServiceId,
)


_INSTALLATION_ID = re.compile(r"[0-9a-f]{32}\Z")
_MAX_WIRE_BYTES = 131072
PermissionKey = Annotated[
    str,
    Field(
        min_length=3,
        max_length=320,
        pattern=r"^[a-z][a-z0-9_]*(?::[A-Za-z0-9._/:@=-]+)+$",
    ),
]
ReleasePreferenceMode = Literal["stable_only", "manual_review", "disabled"]


class ComponentUpdateError(ValueError):
    """A stable public failure that never reflects caller-controlled values."""


class UpstreamSignatureEvidence(FrozenModel):
    status: Literal["verified", "unavailable"]
    kind: Literal["sigstore_bundle", "upstream_unavailable"]
    issuer: Annotated[str, Field(min_length=1, max_length=300)] | None
    subject: Annotated[str, Field(min_length=1, max_length=300)] | None
    bundleDigest: Digest | None

    @model_validator(mode="after")
    def coherent_signature(self):
        if self.status == "verified":
            if (
                self.kind != "sigstore_bundle"
                or self.issuer is None
                or self.subject is None
                or self.bundleDigest is None
            ):
                raise ValueError("invalid_signature_evidence")
        elif (
            self.kind != "upstream_unavailable"
            or self.issuer is not None
            or self.subject is not None
            or self.bundleDigest is not None
        ):
            raise ValueError("invalid_signature_evidence")
        return self


class ComponentBuildEvidence(FrozenModel):
    kind: Literal["packaged_catalog_pin"]
    catalogDigest: Digest
    manifestDigest: Digest
    sourceRevision: Annotated[str, Field(pattern=r"^[0-9a-f]{40}$")]
    imageDigest: ImageDigest
    imageConfigDigest: ImageDigest


class ComponentReleaseIdentity(FrozenModel):
    schemaVersion: Literal[1]
    serviceId: ServiceId
    integrationRole: Literal["managed_service", "internal_engine"]
    distributionId: Literal["upstream", "linuxserver"]
    version: Annotated[str, Field(pattern=r"^[A-Za-z0-9._-]{1,80}$")]
    publisher: Annotated[str, Field(min_length=1, max_length=240)]
    upstreamRepository: Annotated[
        str, Field(pattern=r"^https://[A-Za-z0-9._/-]+$")
    ]
    sourceRepository: Annotated[
        str, Field(pattern=r"^https://[A-Za-z0-9._/-]+$")
    ]
    releaseUrl: Annotated[str, Field(pattern=r"^https://[A-Za-z0-9._/-]+$")]
    repository: Annotated[
        str, Field(pattern=r"^ghcr\.io/[a-z0-9-]+/[a-z0-9-]+$")
    ]
    platform: Platform
    signature: UpstreamSignatureEvidence
    build: ComponentBuildEvidence


class ComponentPermissionSet(FrozenModel):
    claims: tuple[PermissionKey, ...] = Field(max_length=64)

    @model_validator(mode="after")
    def sorted_unique_claims(self):
        if tuple(sorted(set(self.claims))) != self.claims:
            raise ValueError("invalid_permission_set")
        return self


class ComponentPermissionChanges(FrozenModel):
    added: tuple[PermissionKey, ...] = Field(max_length=64)
    removed: tuple[PermissionKey, ...] = Field(max_length=64)
    retained: tuple[PermissionKey, ...] = Field(max_length=64)

    @model_validator(mode="after")
    def disjoint_sorted_changes(self):
        groups = (self.added, self.removed, self.retained)
        if any(tuple(sorted(set(group))) != group for group in groups):
            raise ValueError("invalid_permission_changes")
        if any(set(groups[left]) & set(groups[right]) for left, right in ((0, 1), (0, 2), (1, 2))):
            raise ValueError("invalid_permission_changes")
        return self


class ComponentSchemaIdentity(FrozenModel):
    configSchemaVersion: Annotated[int, Field(ge=1, le=2**31 - 1)]
    dataSchemaVersion: Annotated[
        str, Field(min_length=1, max_length=80, pattern=r"^[A-Za-z0-9._-]+$")
    ]


class InstalledComponentUpdateSource(FrozenModel):
    schemaVersion: Literal[1]
    installationId: Identity
    sourceDigest: Digest
    current: ComponentReleaseIdentity
    permissions: ComponentPermissionSet
    componentSchema: ComponentSchemaIdentity


class ComponentMigrationPlan(FrozenModel):
    current: ComponentSchemaIdentity
    target: ComponentSchemaIdentity
    migrationRequired: StrictBool
    rollbackSnapshotRequired: StrictBool
    state: Literal["not_required", "snapshot_required"]

    @model_validator(mode="after")
    def coherent_migration(self):
        changed = self.current != self.target
        if self.migrationRequired is not changed:
            raise ValueError("invalid_migration_plan")
        expected = "snapshot_required" if changed else "not_required"
        if self.state != expected or self.rollbackSnapshotRequired is not changed:
            raise ValueError("invalid_migration_plan")
        return self


class ComponentUpdatePolicy(FrozenModel):
    schemaVersion: Literal[1]
    serviceId: ServiceId
    currentManifestDigest: Digest
    allowedTargetManifestDigests: tuple[Digest, ...] = Field(min_length=1, max_length=8)
    allowedTargetVersions: tuple[
        Annotated[str, Field(pattern=r"^[A-Za-z0-9._-]{1,80}$")], ...
    ] = Field(min_length=1, max_length=8)
    allowedPermissionAdditions: tuple[PermissionKey, ...] = Field(max_length=64)
    requireUpstreamSignature: StrictBool
    releasePreference: ReleasePreferenceMode

    @model_validator(mode="after")
    def sorted_unique_policy(self):
        groups = (
            self.allowedTargetManifestDigests,
            self.allowedTargetVersions,
            self.allowedPermissionAdditions,
        )
        if any(tuple(sorted(set(group))) != group for group in groups):
            raise ValueError("invalid_update_policy")
        return self


class ComponentReleasePreference(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    serviceId: ServiceId
    revision: Annotated[int, Field(ge=0, le=2**63 - 1)]
    mode: ReleasePreferenceMode
    requireUpstreamSignature: StrictBool


class PutComponentReleasePreference(FrozenModel):
    schemaVersion: Literal[1]
    expectedRevision: Annotated[int, Field(ge=0, le=2**63 - 2)]
    mode: ReleasePreferenceMode
    requireUpstreamSignature: StrictBool


class ConfirmComponentUpdateRequest(FrozenModel):
    schemaVersion: Literal[1]
    expectedSourceDigest: Digest
    expectedReviewDigest: Digest
    expectedPreferenceRevision: Annotated[int, Field(ge=0, le=2**63 - 1)]
    approvePermissionAdditions: StrictBool
    approveManualReview: StrictBool
    approveRollbackSnapshot: StrictBool


UpdateBlocker = Literal[
    "same_release",
    "origin_changed",
    "current_release_untrusted",
    "target_release_not_allowed",
    "target_version_not_allowed",
    "upstream_signature_required",
    "permission_addition_not_allowed",
    "migration_snapshot_required",
    "manual_approval_required",
    "updates_disabled",
    "execution_worker_unavailable",
]


class ComponentUpdateReview(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    installationId: Identity
    reviewDigest: Digest
    current: ComponentReleaseIdentity
    target: ComponentReleaseIdentity
    permissions: ComponentPermissionChanges
    migration: ComponentMigrationPlan
    blockers: tuple[UpdateBlocker, ...] = Field(min_length=1, max_length=10)
    approvalRequired: StrictBool
    applyAvailable: Literal[False]

    @model_validator(mode="after")
    def coherent_review(self):
        if tuple(sorted(set(self.blockers))) != self.blockers:
            raise ValueError("invalid_update_review")
        if self.permissions.added and not self.approvalRequired:
            raise ValueError("invalid_update_review")
        if "execution_worker_unavailable" not in self.blockers:
            raise ValueError("invalid_update_review")
        return self


class ComponentUpdateCommand(FrozenModel):
    schemaVersion: Literal[1]
    updateId: Identity
    coreId: Identity
    homeId: Identity
    installationId: Identity
    serviceId: ServiceId
    sourceDigest: Digest
    reviewDigest: Digest
    preferenceRevision: Annotated[int, Field(ge=0, le=2**63 - 1)]
    targetManifestDigest: Digest
    rollbackSnapshotRequired: StrictBool
    issuedAtMs: Annotated[int, Field(ge=0, le=2**63 - 1)]
    expiresAtMs: Annotated[int, Field(ge=1, le=2**63 - 1)]
    commandDigest: Digest
    state: Literal["confirmed"]

    @model_validator(mode="after")
    def bounded_confirmation(self):
        if (
            self.expiresAtMs <= self.issuedAtMs
            or self.expiresAtMs - self.issuedAtMs > 5 * 60 * 1000
        ):
            raise ValueError("invalid_component_update_command")
        return self


ComponentUpdateJobState = Literal[
    "queued",
    "validating",
    "ready",
    "running",
    "succeeded",
    "failed",
    "cancelled",
    "needs_attention",
]


class CancelComponentUpdateJobRequest(FrozenModel):
    schemaVersion: Literal[1]
    expectedRevision: Annotated[int, Field(ge=1, le=2**63 - 2)]


class ComponentUpdateJob(FrozenModel):
    schemaVersion: Literal[1]
    updateId: Identity
    installationId: Identity
    serviceId: ServiceId
    revision: Annotated[int, Field(ge=1, le=2**63 - 1)]
    state: ComponentUpdateJobState
    cancelRequested: StrictBool
    errorCode: Annotated[
        str, Field(pattern=r"^[a-z][a-z0-9_]{2,63}$")
    ] | None
    sourceDigest: Digest
    reviewDigest: Digest
    targetManifestDigest: Digest
    commandDigest: Digest
    createdAtMs: Annotated[int, Field(ge=0, le=2**63 - 1)]
    updatedAtMs: Annotated[int, Field(ge=0, le=2**63 - 1)]

    @model_validator(mode="after")
    def coherent_job(self):
        terminal = self.state in {"succeeded", "failed", "cancelled"}
        if (
            self.updatedAtMs < self.createdAtMs
            or self.cancelRequested and self.state == "succeeded"
            or self.errorCode is not None
            and self.state not in {"failed", "needs_attention"}
            or self.state == "failed" and self.errorCode is None
            or terminal and self.state == "cancelled" and not self.cancelRequested
        ):
            raise ValueError("invalid_component_update_job")
        return self


class ComponentUpdateEffectResult(FrozenModel):
    schemaVersion: Literal[1]
    updateId: Identity
    installationId: Identity
    serviceId: ServiceId
    commandDigest: Digest
    sourceDigest: Digest
    targetManifestDigest: Digest
    state: Literal["succeeded", "failed", "needs_attention", "cancelled"]
    code: Annotated[str, Field(pattern=r"^[a-z][a-z0-9_]{2,63}$")]

    @model_validator(mode="after")
    def coherent_effect_result(self):
        allowed = {
            "succeeded": {"component_updated"},
            "failed": {
                "worker_unavailable",
                "image_unavailable",
                "rollback_unavailable",
            },
            "needs_attention": {
                "worker_response_unknown",
                "container_state_unknown",
                "rollback_required",
            },
            "cancelled": {"cancelled"},
        }
        if self.code not in allowed[self.state]:
            raise ValueError("invalid_component_update_effect_result")
        return self


class ComponentUpdateInventory(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    installed: tuple[InstalledComponentUpdateSource, ...] = Field(max_length=6)
    reviews: tuple[ComponentUpdateReview, ...] = Field(max_length=6)
    preferences: tuple[ComponentReleasePreference, ...] = Field(max_length=6)

    @model_validator(mode="after")
    def coherent_inventory(self):
        installed_ids = tuple(item.installationId for item in self.installed)
        review_ids = tuple(item.installationId for item in self.reviews)
        preference_services = tuple(item.serviceId for item in self.preferences)
        if (
            tuple(
                sorted(
                    self.installed,
                    key=lambda item: (item.current.serviceId, item.installationId),
                )
            )
            != self.installed
            or tuple(
                sorted(
                    self.reviews,
                    key=lambda item: (item.current.serviceId, item.installationId),
                )
            )
            != self.reviews
            or installed_ids != review_ids
            or preference_services
            != tuple(item.current.serviceId for item in self.installed)
            or any(
                item.coreId != self.coreId or item.homeId != self.homeId
                for item in self.reviews
            )
            or any(
                item.coreId != self.coreId or item.homeId != self.homeId
                for item in self.preferences
            )
        ):
            raise ValueError("invalid_update_inventory")
        return self


def _canonical(value: object) -> bytes:
    raw = json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8")
    if len(raw) > _MAX_WIRE_BYTES:
        raise ValueError("component_update_size")
    return raw


def _validated(value, kind):
    if type(value) is not kind:
        raise ValueError("component_update_type")
    return kind.model_validate_json(_canonical(value.model_dump(mode="json")))


def _publisher(repository: str) -> str:
    # ghcr.io/<publisher>/<package>; the normalized package publisher is shown
    # independently from upstream/source URLs so origin changes are visible.
    return repository.split("/", 2)[1]


def _permissions(manifest) -> ComponentPermissionSet:
    claims = {
        f"security:user={manifest.security.user}",
        f"security:privileged={str(manifest.security.privileged).lower()}",
        f"security:no_new_privileges={str(manifest.security.noNewPrivileges).lower()}",
        f"security:init={str(manifest.security.init).lower()}",
        f"network:mode={manifest.network.mode}",
    }
    claims.update(f"capability:drop={value}" for value in manifest.security.capDrop)
    claims.update(f"capability:add={value}" for value in manifest.security.capAdd)
    claims.update(
        f"listener:{value.protocol}/{value.port}={value.purpose}"
        for value in manifest.network.listeners
    )
    claims.update(
        "mount:"
        + value.target
        + "="
        + value.kind
        + "/"
        + ("read_only" if value.readOnly else "read_write")
        for value in manifest.mounts
    )
    claims.update(
        f"port:{value.protocol}/{value.hostPort}={value.containerPort}"
        for value in manifest.ports
    )
    claims.update(f"tmpfs:{value.target}={value.sizeMiB}" for value in manifest.tmpfs)
    claims.update(f"environment:name={value.name}" for value in manifest.environment)
    return ComponentPermissionSet(claims=tuple(sorted(claims)))


def release_identity(entry: CatalogEntry, platform: str) -> tuple[ComponentReleaseIdentity, ComponentPermissionSet, ComponentSchemaIdentity]:
    """Return a display-safe identity only for the exact packaged catalog pin."""
    try:
        manifest = _trusted_entry(entry)
        selected = next(
            item for item in manifest.images if item.platform == platform
        )
        signature = UpstreamSignatureEvidence(
            status="unavailable",
            kind="upstream_unavailable",
            issuer=None,
            subject=None,
            bundleDigest=None,
        )
        identity = ComponentReleaseIdentity(
            schemaVersion=1,
            serviceId=manifest.serviceId,
            integrationRole=manifest.integrationRole,
            distributionId=manifest.distributionId,
            version=manifest.version,
            publisher=_publisher(manifest.repository),
            upstreamRepository=manifest.upstreamRepository,
            sourceRepository=manifest.sourceRepository,
            releaseUrl=manifest.releaseUrl,
            repository=manifest.repository,
            platform=selected.platform,
            signature=signature,
            build=ComponentBuildEvidence(
                kind="packaged_catalog_pin",
                catalogDigest=entry.catalogDigest,
                manifestDigest=entry.manifestDigest,
                sourceRevision=manifest.sourceRevision,
                imageDigest=selected.digest,
                imageConfigDigest=selected.configDigest,
            ),
        )
        schema = ComponentSchemaIdentity(
            configSchemaVersion=manifest.configSchemaVersion,
            dataSchemaVersion=manifest.dataSchemaVersion,
        )
        return identity, _permissions(manifest), schema
    except (CatalogError, ValueError, TypeError, AttributeError, StopIteration):
        raise ComponentUpdateError("component_release_untrusted") from None


def recorded_release_identity(
    entry: CatalogEntry,
    catalog_digest: str,
    platform: str,
) -> tuple[
    ComponentReleaseIdentity,
    ComponentPermissionSet,
    ComponentSchemaIdentity,
]:
    """Rebuild an installed identity from its journal-bound catalog entry.

    Target releases must pass :func:`release_identity` and therefore the current
    package pins.  An installed release is instead bound to the exact catalog
    snapshot retained by the private installation journal.  Revalidate every
    field and both recorded digests here so a later package catalog cannot
    silently rewrite the identity of the running container.
    """
    try:
        if type(entry) is not CatalogEntry or type(catalog_digest) is not str:
            raise ValueError("recorded_release_type")
        validated = CatalogEntry.model_validate_json(
            _canonical(entry.model_dump(mode="json"))
        )
        manifest = validated.manifest
        manifest_digest = hashlib.sha256(
            _canonical(manifest.model_dump(mode="json"))
        ).hexdigest()
        if (
            validated.catalogDigest != catalog_digest
            or validated.manifestDigest != manifest_digest
        ):
            raise ValueError("recorded_release_digest")
        selected = next(
            item for item in manifest.images if item.platform == platform
        )
        identity = ComponentReleaseIdentity(
            schemaVersion=1,
            serviceId=manifest.serviceId,
            integrationRole=manifest.integrationRole,
            distributionId=manifest.distributionId,
            version=manifest.version,
            publisher=_publisher(manifest.repository),
            upstreamRepository=manifest.upstreamRepository,
            sourceRepository=manifest.sourceRepository,
            releaseUrl=manifest.releaseUrl,
            repository=manifest.repository,
            platform=selected.platform,
            signature=UpstreamSignatureEvidence(
                status="unavailable",
                kind="upstream_unavailable",
                issuer=None,
                subject=None,
                bundleDigest=None,
            ),
            build=ComponentBuildEvidence(
                kind="packaged_catalog_pin",
                catalogDigest=validated.catalogDigest,
                manifestDigest=validated.manifestDigest,
                sourceRevision=manifest.sourceRevision,
                imageDigest=selected.digest,
                imageConfigDigest=selected.configDigest,
            ),
        )
        schema = ComponentSchemaIdentity(
            configSchemaVersion=manifest.configSchemaVersion,
            dataSchemaVersion=manifest.dataSchemaVersion,
        )
        return identity, _permissions(manifest), schema
    except (ValueError, TypeError, AttributeError, StopIteration, RecursionError):
        raise ComponentUpdateError("component_release_untrusted") from None


def installed_update_source(
    *,
    installation_id: str,
    service_id: str,
    service_version: str,
    config_schema_version: int,
    data_schema_version: str,
    platform: str,
    observed_image_config_digest: str,
    catalog_entry: CatalogEntry,
    recorded_catalog_digest: str,
) -> InstalledComponentUpdateSource:
    """Bind one revalidated installation receipt to its packaged release.

    The caller must already have re-derived the live managed-container binding.
    This function additionally requires its observed image configuration digest
    to equal the packaged release and rejects stale version/schema metadata.
    """
    try:
        if (
            type(installation_id) is not str
            or not _INSTALLATION_ID.fullmatch(installation_id)
            or type(service_id) is not str
            or type(service_version) is not str
            or type(config_schema_version) is not int
            or type(data_schema_version) is not str
            or type(platform) is not str
            or type(observed_image_config_digest) is not str
        ):
            raise ValueError("installed_source_type")
        identity, permissions, component_schema = recorded_release_identity(
            catalog_entry,
            recorded_catalog_digest,
            platform,
        )
        if (
            identity.serviceId != service_id
            or identity.version != service_version
            or component_schema.configSchemaVersion != config_schema_version
            or component_schema.dataSchemaVersion != data_schema_version
            or identity.build.imageConfigDigest != observed_image_config_digest
        ):
            raise ValueError("installed_source_mismatch")
        base = dict(
            schemaVersion=1,
            installationId=installation_id,
            sourceDigest="0" * 64,
            current=identity,
            permissions=permissions,
            componentSchema=component_schema,
        )
        provisional = InstalledComponentUpdateSource(**base)
        payload = provisional.model_dump(mode="json")
        payload["sourceDigest"] = None
        source_digest = hashlib.sha256(_canonical(payload)).hexdigest()
        return InstalledComponentUpdateSource(
            **(base | {"sourceDigest": source_digest})
        )
    except ComponentUpdateError:
        raise
    except (ValueError, TypeError, AttributeError, RecursionError):
        raise ComponentUpdateError("installed_component_untrusted") from None


def verify_installed_update_source(
    value: InstalledComponentUpdateSource,
) -> InstalledComponentUpdateSource:
    """Recompute the source digest after strict wire round-trip validation."""
    try:
        validated = _validated(value, InstalledComponentUpdateSource)
        payload = validated.model_dump(mode="json")
        payload["sourceDigest"] = None
        expected = hashlib.sha256(_canonical(payload)).hexdigest()
        if not secrets.compare_digest(validated.sourceDigest, expected):
            raise ValueError("source_digest")
        return validated
    except (ValueError, TypeError, AttributeError, RecursionError):
        raise ComponentUpdateError("installed_component_untrusted") from None


def build_update_command(
    *,
    context: ContextResponse,
    update_id: str,
    issued_at_ms: int,
    source: InstalledComponentUpdateSource,
    review: ComponentUpdateReview,
    preference: ComponentReleasePreference,
    request: ConfirmComponentUpdateRequest,
) -> ComponentUpdateCommand:
    """Bind one explicit admin confirmation to one exact verified review."""
    try:
        context = _validated(context, ContextResponse)
        source = verify_installed_update_source(source)
        review = _validated(review, ComponentUpdateReview)
        preference = _validated(preference, ComponentReleasePreference)
        request = _validated(request, ConfirmComponentUpdateRequest)
        if (
            type(update_id) is not str
            or not _INSTALLATION_ID.fullmatch(update_id)
            or type(issued_at_ms) is not int
            or type(issued_at_ms) is bool
            or not 0 <= issued_at_ms <= 2**63 - 1 - 5 * 60 * 1000
        ):
            raise ValueError("component_update_command_identity")
        if (
            source.installationId != review.installationId
            or source.current != review.current
            or source.current.serviceId != preference.serviceId
            or context.coreId != review.coreId
            or context.homeId != review.homeId
            or context.coreId != preference.coreId
            or context.homeId != preference.homeId
            or request.expectedSourceDigest != source.sourceDigest
            or request.expectedReviewDigest != review.reviewDigest
            or request.expectedPreferenceRevision != preference.revision
        ):
            raise ValueError("component_update_command_stale")
        permitted = {
            "execution_worker_unavailable",
            "migration_snapshot_required",
            "manual_approval_required",
        }
        if not set(review.blockers).issubset(permitted):
            raise ValueError("component_update_command_blocked")
        if (
            review.permissions.added
            and not request.approvePermissionAdditions
            or "manual_approval_required" in review.blockers
            and not request.approveManualReview
            or review.migration.rollbackSnapshotRequired
            and not request.approveRollbackSnapshot
            or preference.mode == "disabled"
            or review.current.build.manifestDigest
            == review.target.build.manifestDigest
        ):
            raise ValueError("component_update_command_approval")
        base = dict(
            schemaVersion=1,
            updateId=update_id,
            coreId=context.coreId,
            homeId=context.homeId,
            installationId=source.installationId,
            serviceId=source.current.serviceId,
            sourceDigest=source.sourceDigest,
            reviewDigest=review.reviewDigest,
            preferenceRevision=preference.revision,
            targetManifestDigest=review.target.build.manifestDigest,
            rollbackSnapshotRequired=review.migration.rollbackSnapshotRequired,
            issuedAtMs=issued_at_ms,
            expiresAtMs=issued_at_ms + 5 * 60 * 1000,
            commandDigest="0" * 64,
            state="confirmed",
        )
        provisional = ComponentUpdateCommand(**base)
        payload = provisional.model_dump(mode="json")
        payload["commandDigest"] = None
        digest = hashlib.sha256(_canonical(payload)).hexdigest()
        return ComponentUpdateCommand(**(base | {"commandDigest": digest}))
    except ComponentUpdateError:
        raise
    except (ValueError, TypeError, AttributeError, RecursionError):
        raise ComponentUpdateError("component_update_confirmation_invalid") from None


def verify_update_command(value: ComponentUpdateCommand) -> ComponentUpdateCommand:
    """Strictly revalidate a command and its digest at every process boundary."""
    try:
        validated = _validated(value, ComponentUpdateCommand)
        payload = validated.model_dump(mode="json")
        payload["commandDigest"] = None
        expected = hashlib.sha256(_canonical(payload)).hexdigest()
        if not secrets.compare_digest(validated.commandDigest, expected):
            raise ValueError("component_update_command_digest")
        return validated
    except (ValueError, TypeError, AttributeError, RecursionError):
        raise ComponentUpdateError("component_update_confirmation_invalid") from None


def build_update_review(
    *,
    context: ContextResponse,
    installation_id: str,
    current: ComponentReleaseIdentity,
    current_permissions: ComponentPermissionSet,
    current_schema: ComponentSchemaIdentity,
    target_entry: CatalogEntry,
    target_platform: str,
    policy: ComponentUpdatePolicy,
) -> ComponentUpdateReview:
    """Compare a durable current identity with one packaged target release.

    The result remains non-executable.  A later effect worker must capture and
    bind a rollback snapshot, revalidate the exact review digest and only then
    expose a separate confirmation operation.
    """
    try:
        context = _validated(context, ContextResponse)
        current = _validated(current, ComponentReleaseIdentity)
        current_permissions = _validated(current_permissions, ComponentPermissionSet)
        current_schema = _validated(current_schema, ComponentSchemaIdentity)
        policy = _validated(policy, ComponentUpdatePolicy)
        if type(installation_id) is not str or not _INSTALLATION_ID.fullmatch(installation_id):
            raise ValueError("installation_identity")
        target, target_permissions, target_schema = release_identity(
            target_entry, target_platform
        )

        added = tuple(sorted(set(target_permissions.claims) - set(current_permissions.claims)))
        removed = tuple(sorted(set(current_permissions.claims) - set(target_permissions.claims)))
        retained = tuple(sorted(set(current_permissions.claims) & set(target_permissions.claims)))
        permissions = ComponentPermissionChanges(
            added=added,
            removed=removed,
            retained=retained,
        )
        migration = ComponentMigrationPlan(
            current=current_schema,
            target=target_schema,
            migrationRequired=current_schema != target_schema,
            rollbackSnapshotRequired=current_schema != target_schema,
            state="snapshot_required" if current_schema != target_schema else "not_required",
        )

        blockers: set[UpdateBlocker] = {"execution_worker_unavailable"}
        if current.build.manifestDigest == target.build.manifestDigest:
            blockers.add("same_release")
        if (
            current.serviceId != target.serviceId
            or current.integrationRole != target.integrationRole
            or current.distributionId != target.distributionId
            or current.publisher != target.publisher
            or current.upstreamRepository != target.upstreamRepository
            or current.sourceRepository != target.sourceRepository
            or current.repository != target.repository
            or current.platform != target.platform
        ):
            blockers.add("origin_changed")
        if (
            policy.serviceId != current.serviceId
            or policy.currentManifestDigest != current.build.manifestDigest
        ):
            blockers.add("current_release_untrusted")
        if target.build.manifestDigest not in policy.allowedTargetManifestDigests:
            blockers.add("target_release_not_allowed")
        if target.version not in policy.allowedTargetVersions:
            blockers.add("target_version_not_allowed")
        if policy.requireUpstreamSignature and target.signature.status != "verified":
            blockers.add("upstream_signature_required")
        if not set(added).issubset(policy.allowedPermissionAdditions):
            blockers.add("permission_addition_not_allowed")
        if migration.rollbackSnapshotRequired:
            blockers.add("migration_snapshot_required")
        manual_approval = (
            policy.releasePreference == "manual_review"
            and current.build.manifestDigest != target.build.manifestDigest
        )
        if manual_approval:
            blockers.add("manual_approval_required")
        if policy.releasePreference == "disabled":
            blockers.add("updates_disabled")

        base = dict(
            schemaVersion=1,
            coreId=context.coreId,
            homeId=context.homeId,
            installationId=installation_id,
            reviewDigest="0" * 64,
            current=current,
            target=target,
            permissions=permissions,
            migration=migration,
            blockers=tuple(sorted(blockers)),
            approvalRequired=bool(added) or manual_approval,
            applyAvailable=False,
        )
        provisional = ComponentUpdateReview(**base)
        payload = provisional.model_dump(mode="json")
        payload["reviewDigest"] = None
        digest = hashlib.sha256(_canonical(payload)).hexdigest()
        return ComponentUpdateReview(**(base | {"reviewDigest": digest}))
    except ComponentUpdateError:
        raise
    except (ValueError, TypeError, AttributeError, RecursionError):
        raise ComponentUpdateError("component_update_review_invalid") from None
