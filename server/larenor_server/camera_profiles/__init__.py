"""Presence-informed camera recording profile contracts."""

from .audit import TamperEvidentCameraAudit
from .models import (
    CameraMode,
    CameraProfileAuthority,
    CameraPrivacyBoundary,
    CameraProfilePolicy,
    CameraProviderSupport,
    CameraReadback,
    CameraScope,
    ManualCameraOverride,
    PresenceSignal,
    WorkerReadback,
)
from .http import CameraProfileHttpGateway
from .service import CameraProfileCoordinator, CameraProfileEngine

__all__ = [
    "CameraMode",
    "CameraProfileAuthority",
    "CameraProfileCoordinator",
    "CameraProfileEngine",
    "CameraPrivacyBoundary",
    "CameraProfileHttpGateway",
    "CameraProfilePolicy",
    "CameraProviderSupport",
    "CameraReadback",
    "CameraScope",
    "ManualCameraOverride",
    "PresenceSignal",
    "TamperEvidentCameraAudit",
    "WorkerReadback",
]
