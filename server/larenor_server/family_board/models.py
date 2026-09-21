from typing import Annotated, Literal

from pydantic import Field, TypeAdapter, field_validator, model_validator

from ..home_resources.models import FrozenModel, Identity


BoardRevision = Annotated[int, Field(ge=0, le=2**63 - 1)]
PositiveRevision = Annotated[int, Field(ge=1, le=2**63 - 1)]
Coordinate = Annotated[float, Field(ge=-100000, le=100000, allow_inf_nan=False)]


class BoardAuthority(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    homeRevision: PositiveRevision
    boardId: Identity
    accountId: Identity
    accountRevision: PositiveRevision
    memberRevision: PositiveRevision
    sessionFamilyId: Identity
    role: Literal["admin", "member"]
    canRead: bool
    canWrite: bool
    active: bool

    @model_validator(mode="after")
    def closed_permissions(self):
        if self.canWrite and not self.canRead:
            raise ValueError("write_requires_read")
        return self


class BoardPoint(FrozenModel):
    x: Coordinate
    y: Coordinate


class BoardCard(FrozenModel):
    schemaVersion: Literal[1]
    id: Identity
    kind: Literal["card"]
    text: str = Field(min_length=1, max_length=2000)
    x: Coordinate
    y: Coordinate
    color: Literal["yellow", "blue", "green", "pink", "gray"]

    @field_validator("text")
    @classmethod
    def safe_text(cls, value):
        if any(ord(char) == 0 or 0xD800 <= ord(char) <= 0xDFFF for char in value):
            raise ValueError("invalid_text")
        if not value.strip():
            raise ValueError("invalid_text")
        return value


class BoardStroke(FrozenModel):
    schemaVersion: Literal[1]
    id: Identity
    kind: Literal["stroke"]
    color: Literal["black", "blue", "green", "red", "white"]
    width: float = Field(gt=0, le=64, allow_inf_nan=False)
    points: list[BoardPoint] = Field(min_length=2, max_length=256)


BoardElement = Annotated[BoardCard | BoardStroke, Field(discriminator="kind")]
BOARD_ELEMENT_ADAPTER = TypeAdapter(BoardElement)


class BoardCommand(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    expectedBoardRevision: BoardRevision
    action: Literal["append", "update", "delete"]
    element: BoardElement | None = None
    elementId: Identity | None = None

    @model_validator(mode="after")
    def action_shape(self):
        if self.action in {"append", "update"}:
            if self.element is None or self.elementId is not None:
                raise ValueError("invalid_action_shape")
        elif self.element is not None or self.elementId is None:
            raise ValueError("invalid_action_shape")
        return self


class BoardReceipt(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    boardId: Identity
    boardRevision: PositiveRevision
    auditSequence: PositiveRevision
    action: Literal["append", "update", "delete"]
    elementId: Identity


class BoardAuditEvent(FrozenModel):
    schemaVersion: Literal[1]
    sequence: PositiveRevision
    action: Literal["append", "update", "delete"]
    actorId: Identity
    elementId: Identity
    boardRevision: PositiveRevision
    createdAt: float = Field(ge=0, allow_inf_nan=False)
    previousHash: str = Field(min_length=64, max_length=64, pattern=r"^[0-9a-f]{64}$")
    eventHash: str = Field(min_length=64, max_length=64, pattern=r"^[0-9a-f]{64}$")


class BoardSnapshot(FrozenModel):
    schemaVersion: Literal[1]
    authority: BoardAuthority
    boardRevision: BoardRevision
    auditHead: str = Field(min_length=64, max_length=64, pattern=r"^[0-9a-f]{64}$")
    elements: list[BoardElement] = Field(max_length=512)


class PublicBoardSnapshot(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    homeRevision: PositiveRevision
    boardId: Identity
    memberRevision: PositiveRevision
    boardRevision: BoardRevision
    auditHead: str = Field(min_length=64, max_length=64, pattern=r"^[0-9a-f]{64}$")
    elements: list[BoardElement] = Field(max_length=512)


class BoardDelta(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    boardId: Identity
    boardRevision: BoardRevision
    afterSequence: int = Field(ge=0, le=2**63 - 1)
    nextAfter: int = Field(ge=0, le=2**63 - 1)
    auditHead: str = Field(min_length=64, max_length=64, pattern=r"^[0-9a-f]{64}$")
    events: list[BoardAuditEvent] = Field(max_length=100)


class StoredReceipt(FrozenModel):
    digest: str = Field(min_length=64, max_length=64, pattern=r"^[0-9a-f]{64}$")
    receipt: BoardReceipt


class StoredBoard(FrozenModel):
    elements: list[BoardElement] = Field(max_length=512)
    receipts: dict[
        Annotated[str, Field(min_length=98, max_length=98, pattern=r"^[0-9a-f]{32}:[0-9a-f]{32}:[0-9a-f]{32}$")],
        StoredReceipt,
    ] = Field(max_length=1024)
