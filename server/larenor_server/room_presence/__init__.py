"""Room-level local presence fusion contracts."""

from .fusion import PresenceAutomationHandoff, RoomPresenceFusion
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
    "WorkerPresenceReceipt",
]
