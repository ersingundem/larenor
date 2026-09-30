"""Actual Android delivery scheduler/renderer against an owned normal TLS Core.

Only CA trust and the device Keystore key are replaced in the JVM test. The
Core, HTTPS wire, strict transport, AES-GCM store, WorkManager schedule and
Android renderer are production code. Physical Keystore/OEM behavior remains
manual.
"""

import contextlib
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid
import xml.etree.ElementTree as ET

import uvicorn

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conftest import ready, server as core_fixture
from test_cli import _tls_pair


@contextlib.contextmanager
def normal_tls_core(app, cert, key):
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
    server = uvicorn.Server(uvicorn.Config(
        app, host="127.0.0.1", port=port, access_log=False, log_config=None,
        ssl_certfile=str(cert), ssl_keyfile=str(key), timeout_keep_alive=1,
        timeout_graceful_shutdown=3,
    ))
    thread = threading.Thread(target=server.run, kwargs={"sockets": [listener]}, daemon=True)
    thread.start()
    deadline = time.monotonic() + 15
    try:
        while not server.started:
            if not thread.is_alive() or time.monotonic() > deadline:
                raise RuntimeError("normal_tls_core_start_failed")
            time.sleep(0.02)
        yield f"https://127.0.0.1:{port}"
    finally:
        server.should_exit = True
        thread.join(10)
        listener.close()
        if thread.is_alive():
            raise RuntimeError("normal_tls_core_stop_failed")


def request(base, path, context, *, body=None, token=None, expected=200):
    data = None if body is None else json.dumps(body).encode()
    headers = {"Accept": "application/json"}
    if data is not None:
        headers["Content-Type"] = "application/json"
    if token is not None:
        headers["Authorization"] = "Bearer " + token
    try:
        with urllib.request.urlopen(urllib.request.Request(
            base + path, data=data, headers=headers,
            method="GET" if data is None else "POST",
        ), context=context, timeout=5) as response:
            if response.status != expected:
                raise RuntimeError("normal_tls_request_status_invalid")
            return json.load(response)
    except urllib.error.HTTPError:
        raise RuntimeError("normal_tls_request_failed") from None


def main():
    repo = Path(__file__).resolve().parents[3]
    with tempfile.TemporaryDirectory(prefix="larenor-f54-native-") as temporary:
        root = Path(temporary)
        cert, key = _tls_pair(root)
        fixture = core_fixture.__wrapped__(root)
        app, client, settings, clock = next(fixture)
        try:
            clock.now = time.time()
            actor = ready((app, client, settings, clock))
            with normal_tls_core(app, cert, key) as base:
                context = ssl.create_default_context(cafile=str(cert))
                assert request(base, "/api/v1/health", context)["apiVersion"] == 1
                scope = app.state.core.context
                path = f"/api/v1/local-notifications/{scope.coreId}/{scope.homeId}"
                subscription = request(base, path + "/subscriptions", context,
                    body={"schemaVersion": 1, "registrationId": uuid.uuid4().hex,
                          "permission": "granted", "expiresAt": clock() + 3600},
                    token=actor["accessToken"], expected=201)["subscription"]
                credential = secrets.token_urlsafe(32)
                fingerprint = hashlib.sha256(base64.urlsafe_b64decode(credential + "=")).hexdigest()
                lease = request(base, path + f"/subscriptions/{subscription['ref']['id']}/delivery-leases", context,
                    body={"schemaVersion": 1, "leaseId": uuid.uuid4().hex, "credential": credential,
                          "credentialFingerprint": fingerprint, "expectedSubscriptionRevision": subscription["revision"],
                          "expiresAt": clock() + 1800}, token=actor["accessToken"], expected=201)["lease"]
                event = request(base, path + "/events", context,
                    body={"schemaVersion": 1, "recipientUserId": actor["user"]["id"],
                          "idempotencyKey": "f54-native-service-" + uuid.uuid4().hex,
                          "category": "security", "sensitivity": "private",
                          "title": "Synthetic private title", "body": "Synthetic private body", "target": "/today"},
                    token=actor["accessToken"], expected=201)["notification"]
                config = {
                    "caFile": str(cert), "baseUrl": base, "coreId": scope.coreId, "homeId": scope.homeId,
                    "bindingId": hashlib.sha256(b"owned-normal-core-service").hexdigest(),
                    "subscriptionId": subscription["ref"]["id"], "subscriptionRevision": subscription["revision"],
                    "leaseId": lease["ref"]["id"], "leaseRevision": lease["revision"],
                    "credential": credential, "credentialFingerprint": fingerprint,
                    "expiresAt": lease["expiresAt"], "eventSequence": event["sequence"],
                    "accessToken": actor["accessToken"],
                    "revokeUrl": base + path + f"/delivery-leases/{lease['ref']['id']}?expectedRevision={lease['revision']}",
                }
                config_file = root / "native-fixture.json"
                config_file.write_text(json.dumps(config))
                config_file.chmod(0o600)
                environment = os.environ.copy()
                environment["LARENOR_F54_NATIVE_FIXTURE"] = str(config_file)
                result = subprocess.run([
                    "./gradlew", "--no-daemon", ":app:cleanTestDebugUnitTest", ":app:testDebugUnitTest",
                    "--tests", "com.ersingundem.larenor.notifications.LocalNotificationNormalCoreWorkerTest",
                ], cwd=repo / "android", env=environment, check=False)
                if result.returncode != 0:
                    raise RuntimeError("normal_core_native_service_gate_failed")
                reports = list((repo / "build/app/test-results/testDebugUnitTest").glob(
                    "TEST-*LocalNotificationNormalCoreWorkerTest.xml"))
                if len(reports) != 1:
                    raise RuntimeError("normal_core_native_report_missing")
                report = ET.parse(reports[0]).getroot()
                if any(report.get(key) != "0" for key in ("errors", "failures", "skipped")) or report.get("tests") != "1":
                    raise RuntimeError("normal_core_native_gate_not_executed")
                print("Normal HTTPS Core → actual WorkManager delivery: 1 passed; restart/revoke and sealed state verified.")
        finally:
            fixture.close()


if __name__ == "__main__":
    main()
