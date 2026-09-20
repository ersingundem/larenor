import ipaddress
from typing import Literal
from urllib.parse import urlsplit

from pydantic import Field, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel
from ..services.models import canonical_base_url


_LAN = tuple(ipaddress.ip_network(n) for n in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', 'fc00::/7'))


def address_network(value):
    ip = ipaddress.ip_address(value)
    if str(ip) != value or '%' in value or getattr(ip, 'ipv4_mapped', None):
        raise ValueError('invalid_address')
    # Never grant local Core, link-local/cloud metadata, transition or special ranges.
    if (ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_unspecified
            or ip.is_reserved or value == 'fd00:ec2::254'
            or ip.version == 6 and (ip in ipaddress.ip_network('2002::/16') or
                                   ip in ipaddress.ip_network('2001::/32'))):
        raise ValueError('invalid_address')
    if any(ip.version == n.version and ip in n for n in _LAN):
        return 'lan'
    if not ip.is_global:
        raise ValueError('invalid_address')
    return 'public'


class Address(StrictModel):
    address: str = Field(min_length=1, max_length=45)
    network: Literal['public', 'lan']

    @model_validator(mode='after')
    def valid(self):
        if address_network(self.address) != self.network:
            raise ValueError('invalid_address_class')
        return self


class Grant(StrictModel):
    scheme: Literal['http', 'https']
    host: str = Field(min_length=1, max_length=253)
    port: int = Field(ge=1, le=65535)
    addresses: list[Address] = Field(min_length=1, max_length=8)

    @model_validator(mode='after')
    def valid(self):
        authority = '[' + self.host + ']' if ':' in self.host else self.host
        parsed = urlsplit(canonical_base_url(f'{self.scheme}://{authority}:{self.port}'))
        if parsed.hostname != self.host or parsed.path or len({a.address for a in self.addresses}) != len(self.addresses):
            raise ValueError('invalid_destination')
        try:
            ipaddress.ip_address(self.host)
        except ValueError:
            pass
        else:
            if {a.address for a in self.addresses} != {self.host}:
                raise ValueError('invalid_literal_pin')
        return self


class Policy(StrictModel):
    component: Literal[
        'home_assistant_probe',
        'proxmox_command_worker',
        'keenetic_command_worker',
    ] = 'home_assistant_probe'
    serviceId: ObjectId
    serviceRevision: Revision
    revision: int = Field(ge=0, le=2**63-1)
    grants: list[Grant] = Field(max_length=1)


class Update(StrictModel):
    expectedRevision: int = Field(ge=0, le=2**63-2)
    expectedServiceRevision: Revision
    grants: list[Grant] = Field(max_length=1)


class Event(StrictModel):
    actorId: ObjectId
    serviceId: ObjectId
    serviceRevision: Revision | None
    correlationId: ObjectId
    policyRevision: int = Field(ge=0, le=2**63-1)
    source: Literal['core_api', 'unknown'] = 'core_api'
    reason: Literal[
        'policy_replaced',
        'grant_missing',
        'dispatch_authorized',
        'probe_completed',
        'probe_unconfirmed',
        'unknown',
    ]
    command: Literal['replace_egress_policy', 'verify_service', 'unknown']
    result: Literal[
        'accepted', 'denied', 'authorized', 'verified', 'unconfirmed', 'unknown'
    ]
    timestamp: float = Field(allow_inf_nan=False)

    @model_validator(mode='after')
    def closed_attribution(self):
        expected = {
            'policy_replaced': ('replace_egress_policy', 'accepted'),
            'grant_missing': ('verify_service', 'denied'),
            'dispatch_authorized': ('verify_service', 'authorized'),
            'probe_completed': ('verify_service', 'verified'),
            'probe_unconfirmed': ('verify_service', 'unconfirmed'),
        }
        if self.source == 'unknown':
            if (
                self.reason != 'unknown'
                or self.command != 'unknown'
                or self.result != 'unknown'
                or self.serviceRevision is not None
            ):
                raise ValueError('invalid_attribution')
        elif (
            self.reason not in expected
            or (self.command, self.result) != expected[self.reason]
            or self.serviceRevision is None
        ):
            raise ValueError('invalid_attribution')
        return self


class LegacyEvent(StrictModel):
    actorId: ObjectId
    serviceId: ObjectId
    correlationId: ObjectId
    policyRevision: int = Field(ge=0, le=2**63-1)
    source: Literal['core_api'] = 'core_api'
    reason: Literal[
        'policy_replaced',
        'grant_missing',
        'dispatch_authorized',
        'probe_completed',
        'probe_unconfirmed',
    ]
    timestamp: float = Field(allow_inf_nan=False)


class State(StrictModel):
    schemaVersion: Literal[2] = 2
    coreId: ObjectId
    homeId: ObjectId
    policies: list[Policy] = Field(max_length=128)
    events: list[Event] = Field(max_length=256)

    @model_validator(mode='after')
    def unique(self):
        if len({p.serviceId for p in self.policies}) != len(self.policies):
            raise ValueError('invalid_policies')
        return self


class LegacyState(StrictModel):
    schemaVersion: Literal[1] = 1
    coreId: ObjectId
    homeId: ObjectId
    policies: list[Policy] = Field(max_length=128)
    events: list[LegacyEvent] = Field(max_length=256)

    @model_validator(mode='after')
    def unique(self):
        if len({p.serviceId for p in self.policies}) != len(self.policies):
            raise ValueError('invalid_policies')
        return self


class Response(StrictModel):
    schemaVersion: Literal[2] = 2
    policy: Policy
    audit: list[Event] = Field(max_length=20)


class ServiceRef(StrictModel):
    id: ObjectId
    revision: Revision


class HistoryResponse(StrictModel):
    schemaVersion: Literal[1] = 1
    service: ServiceRef
    entries: list[Event] = Field(max_length=20)
    verified: Literal[True] = True
