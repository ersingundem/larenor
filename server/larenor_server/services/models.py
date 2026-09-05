import ipaddress
import re
from typing import Annotated, Literal
from urllib.parse import quote, unquote, urlsplit, urlunsplit

from pydantic import Field, StringConstraints, field_validator, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel


ServiceKind = Literal["home_assistant", "jellyfin", "seerr", "sonarr", "radarr", "lidarr", "readarr",
                      "bazarr", "prowlarr", "qbittorrent", "music_assistant", "proxmox", "keenetic",
                      "frigate", "immich", "adguard", "esphome"]
CredentialKey = Literal["token", "apiKey", "username", "password", "userId"]
CredentialValue = Annotated[str, StringConstraints(min_length=1, max_length=2048)]
Credentials = dict[CredentialKey, CredentialValue]
VerificationState = Literal["never", "reachable", "authenticated", "unavailable", "unauthorized", "unsupported"]


def safe_text(value: str) -> str:
    if any(ord(char) < 32 or ord(char) == 127 or 0xD800 <= ord(char) <= 0xDFFF for char in value):
        raise ValueError("Invalid text")
    return value


def canonical_base_url(value: str) -> str:
    safe_text(value)
    if len(value) > 2048 or any(char.isspace() for char in value) or any(char in value for char in "\\?#"):
        raise ValueError("Invalid endpoint")
    try:
        parsed = urlsplit(value)
        if (parsed.scheme not in ("http", "https") or not parsed.hostname or
                parsed.username is not None or parsed.password is not None):
            raise ValueError()
        host = parsed.hostname.rstrip(".")
        if "%" in host:
            raise ValueError()
        try:
            address = ipaddress.ip_address(host)
            host = f"[{address.compressed}]" if address.version == 6 else address.compressed
        except ValueError:
            host = host.encode("idna").decode("ascii").lower()
            if len(host) > 253 or any(not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label)
                                      for label in host.split(".")):
                raise ValueError()
        port = parsed.port
        if port is not None and not 1 <= port <= 65535:
            raise ValueError()
        authority = host + (f":{port}" if port is not None and port != (443 if parsed.scheme == "https" else 80) else "")
        if re.search(r"%(?![0-9a-fA-F]{2})", parsed.path):
            raise ValueError()
        path = unquote(parsed.path, errors="strict")
        safe_text(path)
        if (any(char in path for char in "\\%?#") or any(char.isspace() for char in path) or
                any(part in (".", "..") for part in path.split("/")) or
                re.search(r"%2f", parsed.path, re.IGNORECASE)):
            raise ValueError()
        path = quote(path.rstrip("/"), safe="/!$&'()*+,-.:;=@_~")
        result = urlunsplit((parsed.scheme, authority, path, "", ""))
        if len(result) > 2048:
            raise ValueError()
        return result
    except (ValueError, UnicodeError):
        raise ValueError("Invalid endpoint") from None


def validate_credentials(value: Credentials) -> Credentials:
    for item in value.values():
        safe_text(item)
    if sum(len(item.encode("utf-8")) for item in value.values()) > 4096:
        raise ValueError("Credentials too large")
    return value


class ConnectionFields(StrictModel):
    name: str = Field(min_length=1, max_length=80)
    baseUrl: str = Field(min_length=1, max_length=2048)

    @field_validator("name")
    @classmethod
    def valid_name(cls, value):
        value = safe_text(value).strip()
        if not value:
            raise ValueError("Invalid name")
        return value

    _base_url = field_validator("baseUrl")(canonical_base_url)


class CreateServiceRequest(ConnectionFields):
    kind: ServiceKind
    credentials: Credentials = Field(repr=False, json_schema_extra={"writeOnly": True})

    _credentials = field_validator("credentials")(validate_credentials)


class UpdateServiceRequest(ConnectionFields):
    expectedRevision: Revision
    credentials: Credentials | None = Field(default=None, repr=False, json_schema_extra={"writeOnly": True})

    @field_validator("credentials")
    @classmethod
    def valid_credentials(cls, value):
        if value is None:
            raise ValueError("Null credentials are invalid")
        return validate_credentials(value)


class ServiceVerification(StrictModel):
    state: VerificationState
    checkedAt: str | None
    version: str | None = Field(max_length=80)

    @model_validator(mode="after")
    def valid_result(self):
        if self.state == "never" and (self.checkedAt is not None or self.version is not None):
            raise ValueError("Invalid verification")
        if self.state != "never" and self.checkedAt is None:
            raise ValueError("Invalid verification")
        if self.version is not None:
            safe_text(self.version)
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9 ._+:/()\-]{0,79}", self.version):
                raise ValueError("Invalid version")
        return self


class StoredService(CreateServiceRequest):
    verification: ServiceVerification


class PublicService(ConnectionFields):
    id: ObjectId
    kind: ServiceKind
    revision: int = Field(ge=1, le=2**63 - 1)
    credentialKeys: list[CredentialKey] = Field(max_length=5)
    verification: ServiceVerification


class ServiceResponse(StrictModel):
    service: PublicService


class ServicesResponse(StrictModel):
    services: list[PublicService] = Field(max_length=128)
