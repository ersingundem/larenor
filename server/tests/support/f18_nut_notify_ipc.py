"""Linux peer-UID proof for the fixed NUT notification boundary."""

import hashlib
import os
from pathlib import Path
import pwd
import signal
import sys
import threading

from larenor_server.power_recovery.nut_bridge import (
    NutBridgeConfig,
    NutBridgeOutbox,
    NutBridgeRuntime,
    send_notification,
)


def _server(socket_path, state_root):
    stopped = threading.Event()
    for number in (signal.SIGINT, signal.SIGTERM):
        signal.signal(number, lambda *_args: stopped.set())
    config = NutBridgeConfig(
        "ups-fixture", 1, "t" * 32, "rackups@127.0.0.1:3493",
        "https://127.0.0.1:1", "127.0.0.1", 1,
        Path("/dev/null"), hashlib.sha256(b"").hexdigest(),
        Path("/bin/false"), hashlib.sha256(Path("/bin/false").read_bytes()).hexdigest(),
        state_root, 240, 1, 1, 1, "nut",
    )
    outbox = NutBridgeOutbox(config)
    with NutBridgeRuntime(config, outbox, notify_socket=socket_path) as runtime:
        runtime.serve(stopped)


def _client(socket_path):
    notice = send_notification(
        socket_path,
        {"UPSNAME": "rackups@127.0.0.1:3493", "NOTIFYTYPE": "ONBATT"},
    )
    if len(notice) != 32:
        raise RuntimeError("notification_not_reserved")


def main(argv):
    if len(argv) not in {3, 4} or argv[1] not in {"server", "client"}:
        return 2
    if argv[1] == "server":
        if len(argv) != 4 or os.geteuid() != 10006:
            return 2
        _server(Path(argv[2]), Path(argv[3]))
    else:
        if len(argv) != 3 or os.geteuid() != pwd.getpwnam("nut").pw_uid:
            return 2
        _client(Path(argv[2]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
