"""Linux UID boundary proof for the packaged Proxmox read-only observer."""

import os
from pathlib import Path
import signal
import sys
import threading
import time

from larenor_server.proxmox_commands.models import ProxmoxGuestDescriptor
from larenor_server.proxmox_commands.worker_ipc import (
    PackagedProxmoxObservationResult,
    ProxmoxPowerWorkerServer,
    verified_power_worker_client,
)
from larenor_server.proxmox_commands.worker_runtime import (
    WorkerHealthReceipt,
    _write_health,
)


class _ReadOnlyAdapter:
    def observe(self, command, *, deadline, cancelled):
        if time.monotonic() >= deadline or cancelled():
            raise RuntimeError()
        return PackagedProxmoxObservationResult("running", command.status_revision)

    def execute(self, command, *, deadline, cancelled):
        raise RuntimeError("mutation_forbidden")


def _server(socket_path, health_path):
    stopped = threading.Event()
    for number in (signal.SIGINT, signal.SIGTERM):
        signal.signal(number, lambda *_args: stopped.set())
    server = ProxmoxPowerWorkerServer(
        socket_path,
        _ReadOnlyAdapter(),
        allowed_uid=10001,
        socket_gid=10002,
    )
    server.start()
    info = socket_path.lstat()
    _write_health(
        health_path,
        WorkerHealthReceipt(
            1, "proxmox-power-effect", "ready", "f" * 32, os.geteuid(),
            info.st_dev, info.st_ino, time.time(),
        ),
        10002,
        api_uid=10001,
    )
    try:
        stopped.wait()
    finally:
        server.close()


def _client(socket_path, health_path):
    client = verified_power_worker_client(
        socket_path, health_path, 10005, socket_gid=10002,
    )
    if client is None:
        raise RuntimeError("verified_worker_unavailable")
    descriptor = ProxmoxGuestDescriptor(
        "a" * 32, "binding_1", 7, "service_1", 9, "qemu", "running", 11,
        "service_1", "node-a", 101, True,
    )
    result = client.observe_bounded(
        descriptor,
        lambda: None,
        user_revision=3,
        resource_revision=5,
        acl_revision=6,
        deadline_ms=2_000,
        allowed_addresses=("127.0.0.1",),
    )
    if result != PackagedProxmoxObservationResult("running", 11):
        raise RuntimeError("unexpected_observation")


def main(argv):
    if len(argv) != 4 or argv[1] not in {"server", "client"}:
        return 2
    socket_path, health_path = Path(argv[2]), Path(argv[3])
    if argv[1] == "server":
        _server(socket_path, health_path)
    else:
        _client(socket_path, health_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
