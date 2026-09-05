from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, field_validator


class StrictModel(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")


Username = Annotated[str, StringConstraints(min_length=1, max_length=64, pattern=r"^[A-Za-z0-9_.-]+$")]
Password = Annotated[str, StringConstraints(min_length=1, max_length=128)]
RefreshToken = Annotated[str, StringConstraints(pattern=r"^[A-Za-z0-9_-]{64}$")]


class LoginRequest(StrictModel):
    username: Username
    password: Password
    deviceName: Annotated[str, StringConstraints(min_length=1, max_length=100)]

    @field_validator("deviceName")
    @classmethod
    def safe_device(cls, value: str) -> str:
        if any(ord(char) < 32 or ord(char) == 127 for char in value):
            raise ValueError("Invalid device name")
        return value


class RefreshRequest(StrictModel):
    refreshToken: RefreshToken


class LogoutRequest(StrictModel):
    refreshToken: RefreshToken | None = None


class PasswordRequest(StrictModel):
    currentPassword: Password
    newPassword: Annotated[str, StringConstraints(min_length=12, max_length=128)]

    @field_validator("newPassword")
    @classmethod
    def safe_password(cls, value: str) -> str:
        if any(ord(char) < 32 or ord(char) == 127 for char in value):
            raise ValueError("Invalid password")
        return value


class VaultRequest(StrictModel):
    expectedRevision: Annotated[int, Field(ge=0, le=2**63 - 2)]
    document: dict


class HealthResponse(StrictModel):
    service: Literal["larenor-server"]
    apiVersion: Literal[1]


class PublicUser(StrictModel):
    id: str
    username: str
    role: Literal["admin", "member"]
    mustChangePassword: bool


class UserResponse(StrictModel):
    user: PublicUser


class SessionPair(StrictModel):
    accessToken: str
    refreshToken: str
    expiresIn: Annotated[int, Field(ge=1)]
    user: PublicUser


class VaultResponse(StrictModel):
    revision: Annotated[int, Field(ge=0)]
    document: dict | None


class ErrorDetail(StrictModel):
    code: str
    message: str


class ErrorResponse(StrictModel):
    error: ErrorDetail
