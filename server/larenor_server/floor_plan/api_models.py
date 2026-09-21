from typing import Annotated, Literal

from pydantic import Field, field_validator

from ..home_resources.models import FrozenModel, Identity, Revision
from .service import Anchor, Floor, FloorPlanLayout, Point, Room, VectorShape

LayoutRevision = Annotated[int, Field(ge=0, le=2**63 - 1)]
LayoutId = Annotated[str, Field(min_length=1, max_length=128, pattern=r"^[A-Za-z0-9_.:-]+$")]
SafeLabel = Annotated[str, Field(min_length=1, max_length=80)]
Coordinate = Annotated[float, Field(ge=0, le=1)]


class PointModel(FrozenModel):
    x: Coordinate
    y: Coordinate


class FloorModel(FrozenModel):
    floorId: LayoutId
    label: SafeLabel
    order: int = Field(ge=0, le=7)

    @field_validator("label")
    @classmethod
    def safe_label(cls, value: str) -> str:
        if any(ord(character) < 32 for character in value):
            raise ValueError("invalid_label")
        return value


class RoomModel(FrozenModel):
    roomId: LayoutId
    floorId: LayoutId
    label: SafeLabel
    polygon: list[PointModel] = Field(min_length=3, max_length=64)

    _safe_label = field_validator("label")(FloorModel.safe_label.__func__)


class AnchorModel(FrozenModel):
    anchorId: LayoutId
    roomId: LayoutId
    targetKind: Literal["entity", "resource"]
    targetId: LayoutId
    targetRevision: Revision
    x: Coordinate
    y: Coordinate
    rotation: float = Field(ge=-360, le=360)


class VectorModel(FrozenModel):
    shapeId: LayoutId
    floorId: LayoutId
    kind: LayoutId
    points: list[PointModel] = Field(min_length=2, max_length=128)


class LayoutModel(FrozenModel):
    floors: list[FloorModel] = Field(min_length=1, max_length=8)
    rooms: list[RoomModel] = Field(min_length=1, max_length=128)
    anchors: list[AnchorModel] = Field(max_length=512)
    vectors: list[VectorModel] = Field(max_length=512)

    def to_domain(self) -> FloorPlanLayout:
        return FloorPlanLayout(
            floors=tuple(Floor(item.floorId, item.label, item.order) for item in self.floors),
            rooms=tuple(
                Room(
                    item.roomId,
                    item.floorId,
                    item.label,
                    tuple(Point(point.x, point.y) for point in item.polygon),
                )
                for item in self.rooms
            ),
            anchors=tuple(
                Anchor(
                    item.anchorId,
                    item.roomId,
                    item.targetKind,
                    item.targetId,
                    item.targetRevision,
                    item.x,
                    item.y,
                    item.rotation,
                )
                for item in self.anchors
            ),
            vectors=tuple(
                VectorShape(
                    item.shapeId,
                    item.floorId,
                    item.kind,
                    tuple(Point(point.x, point.y) for point in item.points),
                )
                for item in self.vectors
            ),
        )

    @classmethod
    def from_domain(cls, layout: FloorPlanLayout):
        return cls(
            floors=[
                FloorModel(floorId=item.floor_id, label=item.label, order=item.order)
                for item in layout.floors
            ],
            rooms=[
                RoomModel(
                    roomId=item.room_id,
                    floorId=item.floor_id,
                    label=item.label,
                    polygon=[PointModel(x=point.x, y=point.y) for point in item.polygon],
                )
                for item in layout.rooms
            ],
            anchors=[
                AnchorModel(
                    anchorId=item.anchor_id,
                    roomId=item.room_id,
                    targetKind=item.target_kind,
                    targetId=item.target_id,
                    targetRevision=item.target_revision,
                    x=item.x,
                    y=item.y,
                    rotation=item.rotation,
                )
                for item in layout.anchors
            ],
            vectors=[
                VectorModel(
                    shapeId=item.shape_id,
                    floorId=item.floor_id,
                    kind=item.kind,
                    points=[PointModel(x=point.x, y=point.y) for point in item.points],
                )
                for item in layout.vectors
            ],
        )


class ReplaceLayoutRequest(FrozenModel):
    requestId: Identity
    expectedLayoutRevision: LayoutRevision
    layout: LayoutModel

    def to_domain(self) -> FloorPlanLayout:
        return self.layout.to_domain()


class ReceiptModel(FrozenModel):
    requestId: Identity
    revision: Revision
    status: Literal["saved"]


class ReceiptResponse(FrozenModel):
    receipt: ReceiptModel


class LayoutResponse(FrozenModel):
    layoutRevision: Revision
    layout: LayoutModel


class ExportResponse(FrozenModel):
    formatVersion: Literal[1]
    homeId: Identity
    layoutRevision: Revision
    entityRegistryRevision: Revision
    resourceRevision: Revision
    layout: LayoutModel


class HistoryEntry(FrozenModel):
    auditId: Identity
    action: Literal["layout_replaced"]
    actorId: Identity
    layoutRevision: Revision
    occurredAt: float


class HistoryResponse(FrozenModel):
    entries: list[HistoryEntry] = Field(max_length=1024)
