#!/usr/bin/python3
"""Fixed NUT NOTIFYCMD launcher for the durable Larenor event outbox."""

import os


PYTHON = "/opt/larenor-server-host/current/server/bin/python"
CONFIG = "/etc/larenor-server/host-workers/power-recovery/nut-bridge.json"
UPSMON = "/etc/nut/upsmon.conf"


def main():
    environment = {
        "PATH": "/usr/bin:/bin",
        "LANG": "C",
        "LC_ALL": "C",
        "UPSNAME": os.environ.get("UPSNAME", ""),
        "NOTIFYTYPE": os.environ.get("NOTIFYTYPE", ""),
    }
    os.execve(PYTHON, [
        PYTHON, "-m", "larenor_server.power_recovery.nut_bridge",
        "--config", CONFIG, "--upsmon-config", UPSMON, "notify",
    ], environment)


if __name__ == "__main__":
    main()
