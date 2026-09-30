"""Authenticated adapter for mesh health and explicit firmware updates."""

from ..errors import ApiError
from .models import (
    CoordinatorBackupStatus,
    MeshCenterSnapshot,
    MeshConfirmRequest,
    MeshPreviewRequest,
)
from .managed_ota import (
    ManagedOtaCheckRequest,
    ManagedOtaConfirmRequest,
    ManagedOtaPreviewRequest,
)


class MeshCenterHttpGateway:
    def __init__(self, *, health, updates, snapshotResolver, managedOta=None):
        self._health = health
        self._updates = updates
        self._resolve_snapshot = snapshotResolver
        self._managed_ota = managedOta

    def _managed(self):
        if self._managed_ota is None:
            raise ApiError("firmware_update_unsupported", 409)
        return self._managed_ota

    def _snapshot(self, actor, core_id, home_id):
        try:
            raw = self._resolve_snapshot(actor)
            if not isinstance(raw, (tuple, list)) or len(raw) not in (4, 5):
                raise ValueError("invalid_mesh_snapshot")
            authority, topology, interference, catalog = raw[:4]
            backup = (
                None
                if len(raw) == 4 or raw[4] is None
                else CoordinatorBackupStatus.model_validate(raw[4])
            )
            health = self._health.observe(authority, topology, interference)
            catalog = self._updates.validate_catalog(catalog)
            snapshot = MeshCenterSnapshot(
                schemaVersion=1,
                authority=authority,
                topology=topology,
                interference=interference,
                catalog=catalog,
                health=health,
                coordinatorBackup=backup,
            )
        except ApiError:
            raise
        except Exception:
            raise ApiError("mesh_provider_unavailable", 503) from None
        authority = snapshot.authority
        if (authority.coreId, authority.homeId) != (core_id, home_id):
            raise ApiError("not_found", 404)
        if (
            authority.accountId != actor.id
            or authority.sessionFamilyId != actor.family_id
            or not authority.active
            or not authority.canObserveMesh
        ):
            raise ApiError("forbidden", 403)
        return snapshot

    def snapshot(self, actor, core_id, home_id):
        return self._snapshot(actor, core_id, home_id)

    def preview(self, actor, core_id, home_id, raw):
        body = MeshPreviewRequest.model_validate(raw)
        snapshot = self._snapshot(actor, core_id, home_id)
        if (
            body.authority != snapshot.authority
            or body.topology != snapshot.topology
            or body.catalog != snapshot.catalog
        ):
            raise ApiError("revision_conflict", 409)
        return self._updates.preview(
            body.authority,
            body.topology,
            body.catalog,
            deviceId=body.deviceId,
            firmwareId=body.firmwareId,
            requestId=body.requestId,
        )

    def confirm(self, actor, core_id, home_id, request_id, raw):
        body = MeshConfirmRequest.model_validate(raw)
        snapshot = self._snapshot(actor, core_id, home_id)
        if body.authority != snapshot.authority or body.preview.requestId != request_id:
            raise ApiError("revision_conflict", 409)
        return self._updates.confirm(
            body.authority, body.preview, body.confirmationToken
        )

    def result(self, actor, core_id, home_id, request_id):
        snapshot = self._snapshot(actor, core_id, home_id)
        return self._updates.result(snapshot.authority, request_id)

    def managed_ota_check(self, actor, core_id, home_id, raw):
        body = ManagedOtaCheckRequest.model_validate(raw)
        snapshot = self._snapshot(actor, core_id, home_id)
        if body.authority != snapshot.authority or body.topology != snapshot.topology:
            raise ApiError("revision_conflict", 409)
        return self._managed().check(
            body.authority, body.topology, body.deviceId
        )

    def managed_ota_preview(self, actor, core_id, home_id, raw):
        body = ManagedOtaPreviewRequest.model_validate(raw)
        snapshot = self._snapshot(actor, core_id, home_id)
        if body.authority != snapshot.authority or body.topology != snapshot.topology:
            raise ApiError("revision_conflict", 409)
        return self._managed().preview(
            body.authority, body.topology, body.offer, body.requestId
        )

    def managed_ota_confirm(self, actor, core_id, home_id, request_id, raw):
        body = ManagedOtaConfirmRequest.model_validate(raw)
        snapshot = self._snapshot(actor, core_id, home_id)
        if body.authority != snapshot.authority or body.preview.requestId != request_id:
            raise ApiError("revision_conflict", 409)
        return self._managed().confirm(
            body.authority, body.preview, body.confirmationToken
        )

    def managed_ota_result(self, actor, core_id, home_id, request_id):
        snapshot = self._snapshot(actor, core_id, home_id)
        return self._managed().result(snapshot.authority, request_id)
