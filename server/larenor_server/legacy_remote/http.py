"""Authenticated route adapter for the bounded legacy-remote manager."""

from ..errors import ApiError
from .models import RemoteCatalog, RemoteConfirmRequest, RemotePreviewRequest


class LegacyRemoteHttpGateway:
    def __init__(self, *, manager, catalogResolver):
        self._manager = manager
        self._resolve_catalog = catalogResolver

    def _catalog(self, actor, core_id, home_id):
        try:
            catalog = RemoteCatalog.model_validate(self._resolve_catalog(actor))
        except ApiError:
            raise
        except Exception:
            raise ApiError("remote_provider_unavailable", 503) from None
        authority = catalog.authority
        if (authority.coreId, authority.homeId) != (core_id, home_id):
            raise ApiError("not_found", 404)
        if (
            authority.accountId != actor.id
            or authority.sessionFamilyId != actor.family_id
            or not authority.active
            or not authority.canControlLegacyRemote
        ):
            raise ApiError("forbidden", 403)
        self._manager.authorize(authority)
        return catalog

    def catalog(self, actor, core_id, home_id):
        return self._catalog(actor, core_id, home_id)

    def preview(self, actor, core_id, home_id, raw):
        body = RemotePreviewRequest.model_validate(raw)
        catalog = self._catalog(actor, core_id, home_id)
        if body.authority != catalog.authority:
            raise ApiError("revision_conflict", 409)
        item = next(
            (value for value in catalog.items if value.device.deviceId == body.deviceId),
            None,
        )
        if item is None:
            raise ApiError("not_found", 404)
        device, profile = item.device, item.profile
        definition = next(
            (value for value in profile.commands if value.bindingId == body.bindingId),
            None,
        )
        if (
            definition is None
            or definition.key != body.commandKey
            or (
                device.revision,
                device.providerId,
                device.providerRevision,
                device.bridgeId,
                device.bridgeRevision,
                profile.profileId,
                profile.revision,
                profile.codeSetId,
                profile.codeSetRevision,
            )
            != (
                body.expectedDeviceRevision,
                body.providerId,
                body.expectedProviderRevision,
                body.bridgeId,
                body.expectedBridgeRevision,
                body.profileId,
                body.expectedProfileRevision,
                body.codeSetId,
                body.expectedCodeSetRevision,
            )
        ):
            raise ApiError("revision_conflict", 409)
        return self._manager.preview(
            body.authority,
            device,
            profile,
            commandKey=body.commandKey,
            repeats=body.repeats,
            holdMs=body.holdMs,
            requestId=body.requestId,
        )

    def confirm(self, actor, core_id, home_id, request_id, raw):
        body = RemoteConfirmRequest.model_validate(raw)
        catalog = self._catalog(actor, core_id, home_id)
        if (
            body.authority != catalog.authority
            or body.preview.requestId != request_id
        ):
            raise ApiError("revision_conflict", 409)
        return self._manager.confirm(
            body.authority, body.preview, body.confirmationToken
        )

    def result(self, actor, core_id, home_id, request_id):
        catalog = self._catalog(actor, core_id, home_id)
        return self._manager.result(catalog.authority, request_id)
