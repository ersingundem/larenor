"""Bounded, revision-bound floor plan storage and projection."""

from .schema import migrate_floor_plan
from .service import (
    Anchor,
    EntitySnapshot,
    Floor,
    FloorPlanAuthority,
    FloorPlanLayout,
    FloorPlanService,
    Point,
    Room,
    VectorShape,
)

__all__ = [
    "Anchor",
    "EntitySnapshot",
    "Floor",
    "FloorPlanAuthority",
    "FloorPlanLayout",
    "FloorPlanService",
    "Point",
    "Room",
    "VectorShape",
    "migrate_floor_plan",
]
