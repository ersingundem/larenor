from typing import Literal

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, HomeScope, Identity, Revision


IdempotencyKey = str
Sensitivity = Literal["public", "private"]
Permission = Literal["granted", "denied"]


def _safe_text(value: str) -> str:
    if any(ord(char) < 32 or ord(char) == 127 or 0xD800 <= ord(char) <= 0xDFFF for char in value):
        raise ValueError("invalid_text")
    value = value.strip()
    if not value:
        raise ValueError("invalid_text")
    return value


class RegisterSubscription(FrozenModel):
    schemaVersion: Literal[1]
    registrationId: Identity
    permission: Permission
    expiresAt: float

    @field_validator("schemaVersion", mode="before")
    @classmethod
    def integer_version(cls, value):
        if type(value) is not int:
            raise ValueError("invalid_schema")
        return value


class UpdateSubscription(FrozenModel):
    schemaVersion: Literal[1]
    expectedRevision: Revision
    permission: Permission
    expiresAt: float

    _version = field_validator("schemaVersion", mode="before")(RegisterSubscription.integer_version.__func__)


class SubscriptionRef(HomeScope):
    kind: Literal["local_notification_subscription"]
    id: Identity


class Subscription(FrozenModel):
    schemaVersion: Literal[1]
    ref: SubscriptionRef
    revision: Revision
    permission: Permission
    state: Literal["active", "revoked", "expired"]
    expiresAt: float


class SubscriptionResponse(FrozenModel):
    subscription: Subscription


class CreateNotification(FrozenModel):
    schemaVersion: Literal[1]
    recipientUserId: Identity
    idempotencyKey: str = Field(min_length=16, max_length=128, pattern=r"^[A-Za-z0-9._:-]+$")
    category: str = Field(min_length=1, max_length=64)
    sensitivity: Sensitivity
    title: str = Field(min_length=1, max_length=120)
    body: str = Field(min_length=1, max_length=1024)
    target: str = Field(min_length=1, max_length=256)

    _version = field_validator("schemaVersion", mode="before")(RegisterSubscription.integer_version.__func__)
    _category = field_validator("category")(_safe_text)
    _title = field_validator("title")(_safe_text)
    _body = field_validator("body")(_safe_text)

    @field_validator("target")
    @classmethod
    def safe_target(cls, value):
        value = _safe_text(value)
        if not value.startswith("/") or value.startswith("//") or "?" in value or "#" in value or "\\" in value:
            raise ValueError("invalid_target")
        segments = value.split("/")[1:]
        if any(not segment or segment in {".", ".."} for segment in segments):
            raise ValueError("invalid_target")
        return value


class PublicProjection(FrozenModel):
    title: str
    body: str
    target: str | None
    redacted: bool


class Notification(FrozenModel):
    schemaVersion: Literal[1]
    id: Identity
    sequence: int = Field(ge=1, le=2**63 - 1)
    category: str
    sensitivity: Sensitivity
    title: str
    body: str
    target: str
    createdAt: float
    deliveryState: Literal["available", "delivered"]
    readState: Literal["unread", "read"]
    acknowledged: bool
    publicProjection: PublicProjection


class NotificationResponse(FrozenModel):
    notification: Notification


class NotificationPage(FrozenModel):
    schemaVersion: Literal[1]
    scope: HomeScope
    subscriptionRevision: Revision
    events: list[Notification] = Field(max_length=100)
    nextAfter: int | None


class AcknowledgeNotifications(FrozenModel):
    schemaVersion: Literal[1]
    expectedSubscriptionRevision: Revision
    sequences: list[int] = Field(min_length=1, max_length=100)

    _version = field_validator("schemaVersion", mode="before")(RegisterSubscription.integer_version.__func__)

    @model_validator(mode="after")
    def ordered_unique_sequences(self):
        if any(type(value) is not int or not 1 <= value <= 2**63 - 1 for value in self.sequences):
            raise ValueError("invalid_sequence")
        if self.sequences != sorted(set(self.sequences)):
            raise ValueError("invalid_sequence")
        return self


class AcknowledgementResponse(FrozenModel):
    schemaVersion: Literal[1]
    subscriptionRevision: Revision
    acknowledgedThrough: int
