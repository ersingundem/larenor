"""Closed public and encrypted persistence contracts for Core remote profiles."""
import ipaddress
import re
from typing import Annotated, Literal

from pydantic import Field, SerializerFunctionWrapHandler, field_validator, model_serializer, model_validator

from ..home_resources.models import FrozenModel, HomeScope, Identity, Revision

Protocol = Literal['ssh', 'rdp', 'vnc']
CollectionRevision = Annotated[int, Field(ge=0, le=2**63 - 1)]


def _safe_text(value: str, *, empty: bool = False) -> str:
    if (not empty and not value) or value != value.strip() or any(
            ord(char) < 32 or ord(char) == 127 or 0xD800 <= ord(char) <= 0xDFFF or
            0x202A <= ord(char) <= 0x202E or 0x2066 <= ord(char) <= 0x2069
            for char in value):
        raise ValueError('invalid_text')
    return value


def _normalized_host(value: str) -> str:
    _safe_text(value)
    if re.search(r'[\s/@\\?#%\[\]]', value):
        raise ValueError('invalid_host')
    try:
        address = ipaddress.ip_address(value)
        normalized = address.compressed.lower()
        if normalized != value.lower():
            raise ValueError('invalid_host')
        return normalized
    except ValueError as error:
        if ':' in value or re.fullmatch(r'[0-9.]+', value):
            raise ValueError('invalid_host') from error
    host = value.removesuffix('.')
    label = re.compile(r'^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$')
    if not host or not all(label.fullmatch(part) for part in host.split('.')):
        raise ValueError('invalid_host')
    return host.lower()


class RdpGatewayProfile(FrozenModel):
    host: str = Field(min_length=1, max_length=253)
    port: int = Field(ge=1, le=65535)
    username: str = Field(min_length=1, max_length=128)
    domain: str = Field(default='', max_length=128)
    certificateFingerprint: str = Field(
        min_length=50, max_length=50,
        pattern=r'^SHA256:[A-Za-z0-9+/]{43}$',
    )

    @field_validator('host')
    @classmethod
    def normalized_host(cls, value):
        return _normalized_host(value)

    @field_validator('username')
    @classmethod
    def safe_username(cls, value):
        return _safe_text(value)

    @field_validator('domain')
    @classmethod
    def safe_domain(cls, value):
        return _safe_text(value, empty=True)


class RdpProfileSecurity(FrozenModel):
    domain: str = Field(default='', max_length=128)
    certificateFingerprint: str = Field(
        min_length=50, max_length=50,
        pattern=r'^SHA256:[A-Za-z0-9+/]{43}$',
    )
    gateway: RdpGatewayProfile | None

    @field_validator('domain')
    @classmethod
    def safe_domain(cls, value):
        return _safe_text(value, empty=True)


class PersonalProfileRef(HomeScope):
    kind: Literal['coreRemoteProfile']
    id: Identity
    accountId: Identity


class PersonalProfileAuthority(HomeScope):
    accountId: Identity
    sessionFamilyId: Identity
    accountRevision: Revision
    collectionRevision: CollectionRevision


class PersonalProfileFields(FrozenModel):
    label: str = Field(min_length=1, max_length=80)
    protocol: Protocol
    host: str = Field(min_length=1, max_length=253)
    port: int = Field(ge=1, le=65535)
    username: str = Field(default='', max_length=128)
    rdp: RdpProfileSecurity | None = None

    @field_validator('label')
    @classmethod
    def safe_label(cls, value):
        return _safe_text(value)

    @field_validator('username')
    @classmethod
    def safe_username(cls, value):
        return _safe_text(value, empty=True)

    @field_validator('host')
    @classmethod
    def normalized_host(cls, value):
        return _normalized_host(value)

    @model_validator(mode='after')
    def rdp_security_is_protocol_scoped(self):
        if self.protocol != 'rdp' and self.rdp is not None:
            raise ValueError('rdp_security_protocol_mismatch')
        return self


class CreatePersonalProfileRequest(PersonalProfileFields):
    requestId: Identity
    expectedAccountRevision: Revision
    expectedCollectionRevision: CollectionRevision


class UpdatePersonalProfileRequest(PersonalProfileFields):
    requestId: Identity
    expectedAccountRevision: Revision
    expectedRevision: Revision
    expectedCollectionRevision: CollectionRevision


class StoredPersonalProfile(PersonalProfileFields):
    """Encrypted payload only; credentials and session authority are absent."""


class PersonalProfile(PersonalProfileFields):
    ref: PersonalProfileRef
    revision: Revision

    @model_serializer(mode='wrap')
    def public_projection(self, handler: SerializerFunctionWrapHandler) -> dict[str, object]:
        public = handler(self)
        if self.rdp is None:
            # Older shipped clients decode exactly seven public profile keys.
            # Keep nested gateway:null when an RDP security record does exist.
            public.pop('rdp', None)
        return public


class PersonalProfileResponse(FrozenModel):
    authority: PersonalProfileAuthority
    profile: PersonalProfile


class PersonalProfilesResponse(FrozenModel):
    authority: PersonalProfileAuthority
    profiles: list[PersonalProfile] = Field(max_length=32)


class PersonalProfileDeletion(FrozenModel):
    ref: PersonalProfileRef
    deletedRevision: Revision


class PersonalProfileDeletionResponse(FrozenModel):
    authority: PersonalProfileAuthority
    deletion: PersonalProfileDeletion
