#!/usr/bin/env python3
"""Hosted Linux proof for root component worker to Core UID AF_UNIX IPC."""

from contextlib import contextmanager
from pathlib import Path
import signal
import sys
import time

from larenor_server.core_backups.component_worker import ComponentSnapshotWorkerClient
from larenor_server.core_backups.component_worker_server import (
    ComponentSnapshotWorkerServer,
)


class EmptyBoundary:
    @contextmanager
    def quiesce(self, deadline):
        assert time.monotonic() < deadline <= time.monotonic() + 5
        yield ()


def serve(path):
    worker = ComponentSnapshotWorkerServer(
        path,
        EmptyBoundary(),
        owner_uid=0,
        client_uid=10001,
        socket_gid=10002,
    )

    def stop(_number, _frame):
        worker.close()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    worker.serve_forever()
    return 0


def read(path):
    client = ComponentSnapshotWorkerClient(path, owner_uid=0)
    with client.quiesce(time.monotonic() + 2) as snapshots:
        if snapshots != ():
            return 1
    return 0


def main(argv):
    if len(argv) != 2 or argv[0] not in {"server", "client"}:
        return 2
    path = Path(argv[1])
    return serve(path) if argv[0] == "server" else read(path)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
