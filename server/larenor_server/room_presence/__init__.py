"""Room-level local presence fusion contracts."""

from .fusion import PresenceAutomationHandoff, RoomPresenceFusion
from .repository import RoomPresenceRepository
from .models import (
    PresenceAuthority,
    PresenceAutomationCommand,
    PresenceDevice,
    PresenceEstimate,
    PresenceHandoffReceipt,
    PresencePolicy,
    PresenceRoom,
    PresenceSource,
    WorkerPresenceReceipt,
)

__all__ = [
    "PresenceAuthority",
    "PresenceAutomationCommand",
    "PresenceAutomationHandoff",
    "PresenceDevice",
    "PresenceEstimate",
    "PresenceHandoffReceipt",
    "PresencePolicy",
    "PresenceRoom",
    "PresenceSource",
    "RoomPresenceFusion",
    "RoomPresenceRepository",
    "WorkerPresenceReceipt",
]
