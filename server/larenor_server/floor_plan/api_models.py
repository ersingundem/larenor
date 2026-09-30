from typing import Annotated, Literal

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, Identity, Revision
from ..home_assistant.models import CommandReceipt
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


class EditorReplaceRequest(ReplaceLayoutRequest):
    expectedEntityRegistryRevision: Revision
    expectedResourceRevision: Revision
    expectedGrantRevision: Revision


class EditorRoomModel(FrozenModel):
    roomId: Identity
    label: SafeLabel
    revision: Revision

    _safe_label = field_validator("label")(FloorModel.safe_label.__func__)


class EditorTargetModel(FrozenModel):
    targetKind: Literal["entity", "resource"]
    targetId: LayoutId
    targetRevision: Revision
    label: SafeLabel

    _safe_label = field_validator("label")(FloorModel.safe_label.__func__)


class EditorResponse(FrozenModel):
    schemaVersion: Literal[1]
    layoutRevision: LayoutRevision
    entityRegistryRevision: Revision
    resourceRevision: Revision
    grantRevision: Revision
    layout: LayoutModel | None
    rooms: list[EditorRoomModel] = Field(max_length=512)
    targets: list[EditorTargetModel] = Field(max_length=768)


class ReceiptModel(FrozenModel):
    requestId: Identity
    revision: Revision
    status: Literal["saved"]


class ReceiptResponse(FrozenModel):
    receipt: ReceiptModel


class ActionCapabilityModel(FrozenModel):
    kind: Literal["none", "home_assistant.switch"]
    actions: list[Literal["turn_on", "turn_off"]] = Field(max_length=2)
    resourceId: Identity | None = None
    resourceRevision: Revision | None = None
    aclRevision: Revision | None = None
    bindingId: Identity | None = None
    bindingRevision: Revision | None = None
    serviceRevision: Revision | None = None

    @model_validator(mode="after")
    def closed_capability(self):
        exact = (
            self.resourceId,
            self.resourceRevision,
            self.aclRevision,
            self.bindingId,
            self.bindingRevision,
            self.serviceRevision,
        )
        if self.kind == "none":
            if self.actions or any(item is not None for item in exact):
                raise ValueError("invalid_capability")
        elif set(self.actions) != {"turn_on", "turn_off"} or any(
            item is None for item in exact
        ):
            raise ValueError("invalid_capability")
        return self


class AnchorProjectionModel(FrozenModel):
    anchorId: LayoutId
    targetKind: Literal["entity", "resource"]
    targetId: LayoutId
    targetRevision: Revision
    state: str = Field(min_length=1, max_length=255)
    status: Literal["live", "stale", "unavailable"]
    capability: ActionCapabilityModel

    @field_validator("state")
    @classmethod
    def safe_state(cls, value: str) -> str:
        if any(ord(character) < 32 or ord(character) == 127 for character in value):
            raise ValueError("invalid_state")
        return value


class LayoutResponse(FrozenModel):
    schemaVersion: Literal[1]
    layoutRevision: Revision
    entityRegistryRevision: Revision
    resourceRevision: Revision
    grantRevision: Revision
    layout: LayoutModel
    projections: list[AnchorProjectionModel] = Field(max_length=512)
    projectionLimit: int = Field(ge=1, le=512)
    projectionTruncated: bool


class ActionRequest(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    anchorId: LayoutId
    action: Literal["turn_on", "turn_off"]
    expectedLayoutRevision: Revision
    expectedEntityRegistryRevision: Revision
    expectedResourceRegistryRevision: Revision
    expectedGrantRevision: Revision
    expectedTargetRevision: Revision
    expectedResourceId: Identity
    expectedResourceRevision: Revision
    expectedAclRevision: Revision
    expectedBindingId: Identity
    expectedBindingRevision: Revision
    expectedServiceRevision: Revision


class ActionReceiptModel(FrozenModel):
    schemaVersion: Literal[1]
    anchorId: LayoutId
    layoutRevision: Revision
    entityRegistryRevision: Revision
    resourceRevision: Revision
    grantRevision: Revision
    command: CommandReceipt


class ActionResponse(FrozenModel):
    receipt: ActionReceiptModel


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
