"""Authenticated adapter for mesh health and explicit firmware updates."""

from ..errors import ApiError
from .models import (
    MeshCenterSnapshot,
    MeshConfirmRequest,
    MeshPreviewRequest,
)


class MeshCenterHttpGateway:
    def __init__(self, *, health, updates, snapshotResolver):
        self._health = health
        self._updates = updates
        self._resolve_snapshot = snapshotResolver

    def _snapshot(self, actor, core_id, home_id):
        try:
            raw = self._resolve_snapshot(actor)
            authority, topology, interference, catalog = raw
            health = self._health.observe(authority, topology, interference)
            catalog = self._updates.validate_catalog(catalog)
            snapshot = MeshCenterSnapshot(
                schemaVersion=1,
                authority=authority,
                topology=topology,
                interference=interference,
                catalog=catalog,
                health=health,
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
