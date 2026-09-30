#!/usr/bin/env python3
"""Hosted-Linux proof for distinct mesh-worker and Core peer identities."""

import os
from pathlib import Path
import sys

from larenor_server.mesh_center.worker_ipc import (
    Zigbee2MqttWorkerClient,
    Zigbee2MqttWorkerServer,
)
from larenor_server.mesh_center.zigbee2mqtt_provider import Zigbee2MqttObservation


class _Observer:
    def observe(self, *, timeout):
        return Zigbee2MqttObservation(
            revision=19,
            capturedAtMs=2_000_000,
            bridgeState=b'{"state":"online"}',
            bridgeInfo=b'{"coordinator":{},"network":{}}',
            devices=b"[]",
            deviceStates={},
            availability={},
        )


def main():
    operation, raw_path = sys.argv[1:]
    path = Path(raw_path)
    if operation == "server":
        Zigbee2MqttWorkerServer(
            path,
            _Observer(),
            owner_uid=os.geteuid(),
            peer_uid=10001,
            socket_gid=10002,
        ).serve_forever()
        return 0
    if operation == "client":
        result = Zigbee2MqttWorkerClient(
            path,
            owner_uid=10004,
            peer_uid=10004,
            socket_gid=10002,
        ).observe(timeout=2)
        if result.revision != 19:
            raise RuntimeError("unexpected_observation")
        return 0
    raise RuntimeError("invalid_operation")


if __name__ == "__main__":
    raise SystemExit(main())
