"""Production wiring boundary for Zigbee/Thread coordinator providers."""

import hashlib
import hmac
from pathlib import Path
from typing import Protocol

from .http import MeshCenterHttpGateway
from .service import FirmwareUpdateManager, MeshHealthService
from .store import FirmwareUpdateStore


class MeshCenterProvider(Protocol):
    """Minimal provider contract; transports remain outside the API process."""

    def snapshot(self, actor): ...

    def authority(self, account_id: str): ...

    def topology(self, home_id: str): ...

    def interference(self, home_id: str): ...

    def catalog(self, catalog_id: str): ...

    def signing_key(self, key_id: str): ...

    def install(self, command): ...


def _subkey(master_key: bytes, purpose: bytes) -> bytes:
    return hmac.new(
        master_key, b"larenor:mesh-center:v1\0" + purpose, hashlib.sha256
    ).digest()


def build_mesh_center_gateway(
    provider: MeshCenterProvider,
    *,
    master_key: bytes,
    data_dir: Path,
    clock,
) -> MeshCenterHttpGateway:
    """Bind one provider to durable, authenticated Core state."""
    clock_ms = lambda: int(clock() * 1000)
    health = MeshHealthService(
        authorityResolver=provider.authority,
        topologyResolver=provider.topology,
        interferenceResolver=provider.interference,
        clockMs=clock_ms,
    )
    updates = FirmwareUpdateManager(
        auditKey=_subkey(master_key, b"audit"),
        authorityResolver=provider.authority,
        topologyResolver=provider.topology,
        catalogResolver=provider.catalog,
        signingKeyResolver=provider.signing_key,
        worker=provider.install,
        clockMs=clock_ms,
        stateStore=FirmwareUpdateStore(
            Path(data_dir) / "mesh-firmware-updates.state",
            _subkey(master_key, b"state"),
        ),
    )
    return MeshCenterHttpGateway(
        health=health,
        updates=updates,
        snapshotResolver=provider.snapshot,
    )
