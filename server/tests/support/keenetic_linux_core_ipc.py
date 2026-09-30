"""Read-only normal-Core startup proof against the dedicated host identity."""

from pathlib import Path
import sys

from installed_core_tcp import InstalledCoreTcp
from larenor_server.config import Settings
from larenor_server.keenetic_commands.core_worker import HealthGatedKeeneticWorkerEffect
from larenor_server.runtime import create_configured_app


def main():
    socket_path, health_path, key_path, data_path, vault_path = map(Path, sys.argv[1:])
    settings = Settings(
        data_path,
        vault_path,
        keenetic_worker_socket=socket_path,
        keenetic_worker_health=health_path,
        keenetic_worker_key_file=key_path,
        keenetic_worker_uid=10008,
        keenetic_worker_socket_gid=10002,
    )
    app = create_configured_app(settings)
    with InstalledCoreTcp(app):
        effect = app.state.core.keenetic_commands._effect
        assert isinstance(effect, HealthGatedKeeneticWorkerEffect)
        # Only socket/receipt/kernel-peer readiness; no router request or effect.
        effect._live()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
