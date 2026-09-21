"""Production boundary for provider-backed camera profile readback."""

import hashlib
import hmac
from typing import Protocol

from .audit import TamperEvidentCameraAudit
from .http import CameraProfileHttpGateway
from .service import CameraProfileCoordinator, CameraProfileEngine


class CameraProfileProvider(Protocol):
    core_id: str
    home_id: str

    def authority(self, account_id: str): ...

    def policy_for(self, profile_id: str): ...

    def snapshot(self, actor): ...

    def apply(self, command): ...


def build_camera_profile_gateway(provider, *, master_key: bytes, clock):
    clock_ms = lambda: int(clock() * 1000)
    audit_key = hmac.new(
        master_key,
        b"larenor:camera-profile:v1:audit",
        hashlib.sha256,
    ).digest()
    engine = CameraProfileEngine(
        authorityResolver=provider.authority,
        policyResolver=provider.policy_for,
    )
    audit = TamperEvidentCameraAudit(
        key=audit_key,
        coreId=provider.core_id,
        homeId=provider.home_id,
    )
    coordinator = CameraProfileCoordinator(
        audit=audit,
        authorityResolver=provider.authority,
        policyResolver=provider.policy_for,
    )
    return CameraProfileHttpGateway(
        engine=engine,
        coordinator=coordinator,
        provider=provider,
        clockMs=clock_ms,
    )
