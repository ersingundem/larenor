"""F56 bounded legacy smart-remote Core foundation."""

from .http import LegacyRemoteHttpGateway
from .ha_provider import (
    HomeAssistantLegacyRemoteProvider,
    HomeAssistantRemoteCommand,
    HomeAssistantRemoteSourceRequest,
)
from .models import (
    RemoteAuthority,
    RemoteCatalog,
    RemoteCatalogItem,
    RemoteCodeBinding,
    RemoteCommandDefinition,
    RemoteCommandPreview,
    RemoteCommandProfile,
    RemoteCommandResult,
    RemoteConfirmRequest,
    RemoteDeliveryReceipt,
    RemoteDevice,
    RemoteLearningReceipt,
    RemoteLearningRequest,
    RemoteLearningResult,
    RemoteLearningWorkerCommand,
    RemotePreviewRequest,
    RemoteWorkerCommand,
)
from .runtime import LegacyRemoteProvider, build_legacy_remote_gateway
from .service import LegacyRemoteManager, RemoteAuditEntry
from .store import LegacyRemoteStore

__all__ = [
    "LegacyRemoteHttpGateway",
    "HomeAssistantLegacyRemoteProvider",
    "HomeAssistantRemoteCommand",
    "HomeAssistantRemoteSourceRequest",
    "LegacyRemoteManager",
    "LegacyRemoteProvider",
    "LegacyRemoteStore",
    "RemoteAuditEntry",
    "RemoteAuthority",
    "RemoteCatalog",
    "RemoteCatalogItem",
    "RemoteCodeBinding",
    "RemoteCommandDefinition",
    "RemoteCommandPreview",
    "RemoteCommandProfile",
    "RemoteCommandResult",
    "RemoteConfirmRequest",
    "RemoteDeliveryReceipt",
    "RemoteDevice",
    "RemoteLearningReceipt",
    "RemoteLearningRequest",
    "RemoteLearningResult",
    "RemoteLearningWorkerCommand",
    "RemotePreviewRequest",
    "RemoteWorkerCommand",
    "build_legacy_remote_gateway",
]
