"""Presence-informed camera recording profile contracts."""

from .audit import TamperEvidentCameraAudit
from .models import (
    CameraMode,
    CameraProfileAuthority,
    CameraProfilePolicy,
    CameraReadback,
    CameraScope,
    ManualCameraOverride,
    PresenceSignal,
    WorkerReadback,
)
from .service import CameraProfileCoordinator, CameraProfileEngine

__all__ = [
    "CameraMode",
    "CameraProfileAuthority",
    "CameraProfileCoordinator",
    "CameraProfileEngine",
    "CameraProfilePolicy",
    "CameraReadback",
    "CameraScope",
    "ManualCameraOverride",
    "PresenceSignal",
    "TamperEvidentCameraAudit",
    "WorkerReadback",
]
