from typing import Annotated, Literal
from urllib.parse import urlsplit

from pydantic import Field, StringConstraints, field_validator, model_validator

from ..models import StrictModel


Secret = Annotated[str, StringConstraints(min_length=32, max_length=512)]
TargetId = Annotated[
    str, StringConstraints(pattern=r"^[a-z][a-z0-9-]{2,63}$")
]


def _https_endpoint(value: str) -> str:
    try:
        parsed = urlsplit(value)
        if (
            parsed.scheme != "https"
            or not parsed.hostname
            or parsed.username is not None
            or parsed.password is not None
            or parsed.query
            or parsed.fragment
            or parsed.path not in ("", "/")
            or parsed.port is not None and not 1 <= parsed.port <= 65535
            or len(value) > 2048
        ):
            raise ValueError("invalid_target_endpoint")
    except (TypeError, ValueError):
        raise ValueError("invalid_target_endpoint") from None
    return value[:-1] if value.endswith("/") else value


class ConfigureImmutableTargetRequest(StrictModel):
    contractVersion: Literal[1]
    expectedRevision: Annotated[int, Field(ge=0, le=2**63 - 2)]
    endpoint: Annotated[str, StringConstraints(min_length=9, max_length=2048)]
    targetId: TargetId
    retentionDays: Annotated[int, Field(ge=7, le=3650)]
    quotaBytes: Annotated[int, Field(ge=64 * 1024 * 1024, le=10 * 1024**4)]
    writeToken: Secret
    recoveryToken: Secret
    backupPassphrase: Annotated[
        str, StringConstraints(min_length=16, max_length=128)
    ]

    @field_validator("endpoint")
    @classmethod
    def endpoint_is_https_origin(cls, value: str) -> str:
        return _https_endpoint(value)

    @model_validator(mode="after")
    def separates_authorities(self):
        if self.writeToken == self.recoveryToken:
            raise ValueError("target_authority_not_separated")
        return self


class ImmutableTarget(StrictModel):
    contractVersion: Literal[1]
    revision: Annotated[int, Field(ge=1, le=2**63 - 1)]
    kind: Literal["rest_append_only_v1"]
    endpoint: str
    targetId: TargetId
    retentionDays: Annotated[int, Field(ge=7, le=3650)]
    quotaBytes: Annotated[int, Field(ge=64 * 1024 * 1024, le=10 * 1024**4)]
    writerScope: Literal["append_only"]
    recoveryScope: Literal["read_and_retain"]
    configuredAt: Annotated[int, Field(ge=0, le=253402300799)]


class ImmutableTargetResponse(StrictModel):
    target: ImmutableTarget | None

