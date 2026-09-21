"""Private provider boundary and durable HTTP runtime for legacy remotes."""

from typing import Protocol

from ..errors import ApiError, StartupError
from .http import LegacyRemoteHttpGateway
from .models import (
    RemoteAuthority,
    RemoteCatalog,
    RemoteCommandProfile,
    RemoteDeliveryReceipt,
    RemoteDevice,
    RemoteWorkerCommand,
)
from .service import LegacyRemoteManager
from .store import LegacyRemoteStore


class LegacyRemoteProvider(Protocol):
    """Trusted in-process adapter; secrets and raw IR/RF never cross this boundary."""

    def catalog(self, actor, core_id: str, home_id: str) -> RemoteCatalog: ...

    def resolve_authority(self, account_id: str) -> RemoteAuthority | None: ...

    def resolve_device(self, device_id: str) -> RemoteDevice | None: ...

    def resolve_profile(self, profile_id: str) -> RemoteCommandProfile | None: ...

    def emit(self, command: RemoteWorkerCommand) -> RemoteDeliveryReceipt: ...


def build_legacy_remote_gateway(database, settings, key, context, provider):
    if provider is None:
        return None
    required = (
        "catalog",
        "resolve_authority",
        "resolve_device",
        "resolve_profile",
        "emit",
    )
    if any(not callable(getattr(provider, name, None)) for name in required):
        raise ValueError("invalid_legacy_remote_provider")
    store = LegacyRemoteStore(database, key, context)
    store.validate_storage()
    try:
        manager = LegacyRemoteManager(
            auditKey=key,
            authorityResolver=provider.resolve_authority,
            deviceResolver=provider.resolve_device,
            profileResolver=provider.resolve_profile,
            worker=provider.emit,
            clockMs=lambda: int(settings.clock() * 1000),
            store=store,
        )
    except ApiError:
        raise StartupError("storage_initialization_failed") from None
    return LegacyRemoteHttpGateway(
        manager=manager,
        catalogResolver=lambda actor: provider.catalog(
            actor, context.coreId, context.homeId
        ),
    )
