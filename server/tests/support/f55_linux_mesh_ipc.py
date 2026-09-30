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
    operation, raw_path, *arguments = sys.argv[1:]
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
    if operation == "core":
        if len(arguments) != 2:
            raise RuntimeError("invalid_arguments")
        from fastapi.testclient import TestClient

        from larenor_server.config import Settings
        from larenor_server.runtime import create_configured_app

        settings = Settings(
            Path(arguments[0]),
            Path(arguments[1]),
            clock=lambda: 2_000,
            login_ip_limit=100,
            login_account_limit=100,
            login_global_limit=100,
            mesh_center_worker_socket=path,
            mesh_center_worker_uid=10004,
            mesh_center_worker_socket_gid=10002,
        )
        app = create_configured_app(settings)
        with TestClient(app) as client:
            password = settings.effective_bootstrap_file.read_text().split(
                "password: ", 1
            )[1].strip()
            signed_in = client.post(
                "/api/v1/auth/login",
                json={
                    "username": "admin",
                    "password": password,
                    "deviceName": "Hosted Linux Core",
                },
            )
            if signed_in.status_code != 200:
                raise RuntimeError("core_login_failed")
            changed = client.post(
                "/api/v1/auth/password",
                headers={
                    "Authorization": "Bearer "
                    + signed_in.json()["accessToken"]
                },
                json={
                    "currentPassword": password,
                    "newPassword": "Synthetic hosted Linux password 2026",
                },
            )
            if changed.status_code != 200:
                raise RuntimeError("core_password_change_failed")
            context = app.state.core.context
            response = client.get(
                f"/api/v1/admin/mesh-center/{context.coreId}/{context.homeId}",
                headers={
                    "Authorization": "Bearer " + changed.json()["accessToken"]
                },
            )
            if (
                response.status_code != 200
                or response.json()["snapshot"]["topology"]["devices"] != []
            ):
                raise RuntimeError("core_mesh_observation_failed")
        return 0
    raise RuntimeError("invalid_operation")


if __name__ == "__main__":
    raise SystemExit(main())
