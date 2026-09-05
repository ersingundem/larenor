from typing import Annotated, Literal

from pydantic import Field, StringConstraints, field_validator, model_validator

from ..models import StrictModel, Username


ObjectId = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{32}$")]
Revision = Annotated[int, Field(ge=1, le=2**63 - 2)]
Role = Literal["admin", "member"]
TemporaryPassword = Annotated[str, StringConstraints(min_length=12, max_length=128)]


def validate_password(value: str) -> str:
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise ValueError("Invalid password")
    return value


class CreateUserRequest(StrictModel):
    username: Username
    role: Role
    initialPassword: TemporaryPassword = Field(repr=False, json_schema_extra={"writeOnly": True})

    _safe_password = field_validator("initialPassword")(validate_password)


class UpdateUserRequest(StrictModel):
    expectedRevision: Revision
    role: Role | None = None
    disabled: bool | None = None

    @model_validator(mode="after")
    def changes(self):
        if self.role is None and self.disabled is None:
            raise ValueError("A change is required")
        if ("role" in self.model_fields_set and self.role is None or
                "disabled" in self.model_fields_set and self.disabled is None):
            raise ValueError("Null changes are invalid")
        return self


class ResetPasswordRequest(StrictModel):
    expectedRevision: Revision
    temporaryPassword: TemporaryPassword = Field(repr=False, json_schema_extra={"writeOnly": True})

    _safe_password = field_validator("temporaryPassword")(validate_password)


class AdminUser(StrictModel):
    id: ObjectId
    username: str
    role: Role
    disabled: bool
    mustChangePassword: bool
    revision: Annotated[int, Field(ge=1, le=2**63 - 1)]
    createdAt: str


class AdminUserResponse(StrictModel):
    user: AdminUser


class UsersResponse(StrictModel):
    users: list[AdminUser] = Field(max_length=256)


class AdminSession(StrictModel):
    id: ObjectId
    userId: ObjectId
    deviceName: str = Field(max_length=100)
    createdAt: str
    expiresAt: str
    revokedAt: str | None
    status: Literal["active", "revoked", "expired"]


class SessionsResponse(StrictModel):
    sessions: list[AdminSession] = Field(max_length=100)
    nextCursor: str | None


class AuditEvent(StrictModel):
    id: str
    event: Literal["admin.user.created", "admin.user.updated", "admin.user.password_reset", "admin.session.revoked"]
    action: Literal["create", "update", "reset_password", "revoke"]
    object: Literal["user", "session"]
    status: Literal["success", "denied"]
    timestamp: str
    actorId: ObjectId
    targetId: ObjectId | None


class AuditResponse(StrictModel):
    events: list[AuditEvent] = Field(max_length=100)
    nextCursor: str | None
