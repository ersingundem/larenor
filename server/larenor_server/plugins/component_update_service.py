"""Authenticated Core projection for verified component update reviews."""

import time

from ..context import ContextResponse
from ..errors import ApiError
from .catalog import load_catalog
from .component_updates import (
    ComponentUpdateInventory,
    ComponentUpdatePolicy,
    ConfirmComponentUpdateRequest,
    build_update_review,
    verify_installed_update_source,
)


class ComponentUpdateService:
    """Join private worker receipts with the packaged target catalog."""

    def __init__(self, boundary, context, preferences, confirmations, jobs):
        if type(context) is not ContextResponse:
            raise ValueError("invalid_component_update_configuration")
        self._boundary = boundary
        self._context = context
        self._preferences = preferences
        self._confirmations = confirmations
        self._jobs = jobs

    def inventory(self, actor):
        try:
            reader = getattr(self._boundary, "update_sources", None)
            if not callable(reader):
                raise ApiError("component_update_worker_unavailable", 503)
            sources = tuple(
                verify_installed_update_source(item)
                for item in reader(time.monotonic() + 5)
            )
            if tuple(
                sorted(
                    sources,
                    key=lambda item: (item.current.serviceId, item.installationId),
                )
            ) != sources:
                raise ValueError("unordered_sources")
            catalog = load_catalog()
            entries = {
                item.manifest.serviceId: item for item in catalog.entries
            }
            preferences = self._preferences.list(
                actor,
                (source.current.serviceId for source in sources),
            )
            reviews = []
            execution_available = callable(
                getattr(self._boundary, "execute_update", None)
            )
            for source, preference in zip(sources, preferences, strict=True):
                entry = entries.get(source.current.serviceId)
                if entry is None:
                    raise ValueError("missing_target")
                policy = ComponentUpdatePolicy(
                    schemaVersion=1,
                    serviceId=source.current.serviceId,
                    currentManifestDigest=source.current.build.manifestDigest,
                    allowedTargetManifestDigests=(entry.manifestDigest,),
                    allowedTargetVersions=(entry.manifest.version,),
                    allowedPermissionAdditions=(),
                    requireUpstreamSignature=preference.requireUpstreamSignature,
                    releasePreference=preference.mode,
                )
                reviews.append(
                    build_update_review(
                        context=self._context,
                        installation_id=source.installationId,
                        current=source.current,
                        current_permissions=source.permissions,
                        current_schema=source.componentSchema,
                        target_entry=entry,
                        target_platform=source.current.platform,
                        policy=policy,
                        execution_available=execution_available,
                    )
                )
            return ComponentUpdateInventory(
                schemaVersion=1,
                coreId=self._context.coreId,
                homeId=self._context.homeId,
                installed=sources,
                reviews=tuple(reviews),
                preferences=preferences,
            )
        except ApiError:
            raise
        except Exception:
            raise ApiError("component_update_unavailable", 503) from None

    def put_preference(self, actor, service_id, body):
        return self._preferences.put(actor, service_id, body)

    def confirm(self, actor, installation_id, value):
        body = ConfirmComponentUpdateRequest.model_validate(value)
        inventory = self.inventory(actor)
        matches = tuple(
            (source, review, preference)
            for source, review, preference in zip(
                inventory.installed,
                inventory.reviews,
                inventory.preferences,
                strict=True,
            )
            if source.installationId == installation_id
        )
        if len(matches) != 1:
            raise ApiError("not_found", 404)
        command = self._confirmations.confirm(actor, *matches[0], body)
        try:
            validate = getattr(self._boundary, "validate_update", None)
            if not callable(validate):
                raise ValueError("component_update_worker_unavailable")
            if validate(command, time.monotonic() + 5) != command:
                raise ValueError("component_update_worker_mismatch")
        except BaseException as error:
            if isinstance(error, (KeyboardInterrupt, SystemExit)):
                raise
            self._confirmations.discard_unvalidated(command)
            raise ApiError("component_update_worker_unavailable", 503) from None
        try:
            self._jobs.enqueue(actor, command)
        except BaseException:
            self._confirmations.discard_unvalidated(command)
            raise
        return command

    def get_job(self, actor, update_id):
        return self._jobs.get(actor, update_id)

    def cancel_job(self, actor, update_id, body):
        return self._jobs.cancel(actor, update_id, body)
