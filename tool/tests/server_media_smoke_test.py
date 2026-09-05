"""Offline tests of the actual container smoke protocol; no Docker or network."""

import copy
import io
import json
from pathlib import Path
import subprocess
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
from urllib.error import HTTPError

from tool.server_media_smoke import _NoRedirect, verify_media_preparation


ROOT = Path(__file__).resolve().parents[2]
FIXTURE = json.loads((ROOT / "contracts/media-preparations.v1.json").read_text())


class Response(io.BytesIO):
    def __init__(self, payload, status=200):
        super().__init__(json.dumps(payload).encode())
        self.status = status


class Protocol:
    def __init__(self):
        self.record = copy.deepcopy(FIXTURE["prepared"])
        self.calls = []
        self.commands = []
        self.restarts = 0
        self.bootstrap = "synthetic-bootstrap-private"
        self.token = "synthetic-access-private"
        self.password = None
        self.created = False
        self.fault = None

    def healthy(self):
        return f"http://127.0.0.1:{41001 + self.restarts}/api/v1"

    def run(self, command, **kwargs):
        self.commands.append((command, kwargs))
        if command[:2] == ["docker", "exec"]:
            assert kwargs["stdout"] == subprocess.PIPE
            assert kwargs["stderr"] == subprocess.DEVNULL
            return SimpleNamespace(returncode=0, stdout=f"username: admin\npassword: {self.bootstrap}\n".encode())
        assert command == ["docker", "restart", "--time", "10", "larenor-smoke-amd64"]
        assert self.created
        self.restarts += 1
        return SimpleNamespace(returncode=0)

    def open(self, request, timeout):
        self.calls.append(request)
        assert request.full_url.startswith(self.healthy() + "/")
        assert timeout <= 10
        path = request.full_url.split("/api/v1", 1)[1]
        body = json.loads(request.data) if request.data else None
        if self.fault:
            response = self.fault(path, body)
            if response is not None:
                return response
        if path == "/auth/login":
            assert body["username"] == "admin" and body["password"] == self.bootstrap
            return Response({"accessToken": self.token, "user": {"role": "admin", "mustChangePassword": True}})
        assert request.get_header("Authorization") == "Bearer " + self.token
        if path == "/auth/password":
            assert body["currentPassword"] == self.bootstrap
            assert body["newPassword"] != self.bootstrap
            self.password = body["newPassword"]
            return Response({"accessToken": self.token, "user": {"role": "admin", "mustChangePassword": False}})
        if path == "/context":
            return Response(FIXTURE["context"])
        if path == "/admin/plugins/catalog":
            return Response(FIXTURE["catalog"])
        if path == "/admin/plugins/jobs/capabilities":
            return Response({"preflightConfigured": False, "installAvailable": False})
        if path == "/admin/plugins/jobs":
            return Response({"jobs": [], "nextBefore": None})
        if path == "/admin/media/inspections/capabilities":
            return Response({"inspectionConfigured": False, "installAvailable": False})
        if path == "/admin/media/inspections":
            assert request.method == "GET"
            return Response({"inspections": [], "nextBefore": None})
        if path == "/admin/media/preparations":
            if request.method == "POST":
                assert body["context"] == FIXTURE["context"]
                assert body["catalogDigest"] == FIXTURE["catalog"]["catalogDigest"]
                assert body["settings"] == FIXTURE["createRequest"]["settings"]
                self.record["requestId"] = body["requestId"]
                self.created = True
                return Response({"preparation": self.record}, 201)
            return Response({"preparations": [self.record], "nextBefore": None})
        if path == "/admin/media/preparations/" + self.record["id"]:
            return Response({"preparation": self.record})
        if path == "/admin/media/preparations/" + self.record["id"] + "/cancel":
            assert self.restarts == 1
            assert body == {"expectedRevision": 1}
            self.record.update(state="cancelled", revision=2)
            return Response({"preparation": self.record})
        raise AssertionError("Unexpected smoke endpoint")


class MediaSmokeProtocolTest(unittest.TestCase):
    def exercise(self, protocol):
        with patch("tool.server_media_smoke.subprocess.run", protocol.run), \
             patch("tool.server_media_smoke.build_opener", return_value=SimpleNamespace(open=protocol.open)):
            verify_media_preparation("larenor-smoke-amd64", protocol.healthy, "linux/amd64")

    def test_create_restart_exact_history_cancel_without_executing_jobs(self):
        protocol = Protocol()
        with patch("sys.stdout", new_callable=io.StringIO) as output:
            self.exercise(protocol)
        self.assertEqual(protocol.restarts, 1)
        self.assertEqual(protocol.record["state"], "cancelled")
        writes = [r for r in protocol.calls if r.method == "POST"]
        self.assertEqual(len(writes), 4)
        self.assertTrue(all(not any(p in r.full_url for p in ("/install", "/previews", "/check")) for r in writes))
        self.assertFalse(any(r.method != "GET" and "/jobs" in r.full_url for r in protocol.calls))
        rendered = repr(protocol.commands) + output.getvalue()
        for secret in (protocol.bootstrap, protocol.token, protocol.password):
            self.assertNotIn(secret, rendered)
        self.assertEqual(output.getvalue(), "")

    def test_aggregate_inspection_routes_are_checked_before_and_after_restart(self):
        protocol = Protocol()
        self.exercise(protocol)
        for suffix in ("/admin/media/inspections", "/admin/media/inspections/capabilities"):
            calls = [r for r in protocol.calls if r.full_url.endswith(suffix)]
            self.assertEqual(len(calls), 2)
            self.assertTrue(all(r.method == "GET" for r in calls))

    def test_unconfigured_image_cannot_claim_aggregate_inspections_or_persisted_jobs(self):
        for suffix, payload in (
            ("/admin/media/inspections/capabilities", {"inspectionConfigured": True, "installAvailable": False}),
            ("/admin/media/inspections/capabilities", {"inspectionConfigured": False, "installAvailable": True}),
            ("/admin/media/inspections", {"inspections": [{"state": "succeeded"}], "nextBefore": None}),
        ):
            with self.subTest(suffix=suffix, payload=payload):
                protocol = Protocol()
                protocol.fault = lambda path, body: Response(payload) if path == suffix else None
                with self.assertRaises(RuntimeError):
                    self.exercise(protocol)

    def test_restart_must_recover_identical_record_and_context(self):
        for fault in ("missing", "plan", "context", "revision", "cancel"):
            with self.subTest(fault=fault):
                protocol = Protocol()
                def changed(path, body):
                    if not protocol.restarts:
                        return None
                    if fault == "context" and path == "/context":
                        return Response({**FIXTURE["context"], "homeId": "f" * 32})
                    if path == "/admin/media/preparations":
                        record = copy.deepcopy(protocol.record)
                        if fault == "missing":
                            return Response({"preparations": [], "nextBefore": None})
                        if fault == "plan":
                            record["plan"]["planHash"] = "f" * 64
                        if fault == "revision":
                            record["revision"] = 2
                        return Response({"preparations": [record], "nextBefore": None})
                    if fault == "cancel" and path.endswith("/cancel"):
                        return Response({"preparation": protocol.record})
                    return None
                protocol.fault = changed
                with self.assertRaisesRegex(RuntimeError, "^Media preparation smoke failed$"):
                    self.exercise(protocol)

    def test_install_or_worker_execution_capability_cannot_pass(self):
        for key in ("preflightConfigured", "installAvailable"):
            protocol = Protocol()
            protocol.fault = lambda path, body: Response({"preflightConfigured": key == "preflightConfigured", "installAvailable": key == "installAvailable"}) if path.endswith("/capabilities") else None
            with self.assertRaises(RuntimeError):
                self.exercise(protocol)
            self.assertFalse(protocol.created)

    def test_http_failure_is_static_and_never_retries_a_write(self):
        protocol = Protocol()
        def failed(path, body):
            if path == "/admin/media/preparations" and body:
                raise HTTPError("http://127.0.0.1/private", 500, "synthetic-secret", {}, io.BytesIO(b"synthetic-secret"))
        protocol.fault = failed
        with self.assertRaisesRegex(RuntimeError, "^Media preparation smoke failed$") as caught:
            self.exercise(protocol)
        self.assertNotIn("synthetic-secret", str(caught.exception))
        self.assertEqual(sum(r.method == "POST" and r.full_url.endswith("/preparations") for r in protocol.calls), 1)

    def test_non_loopback_health_result_rejects_before_secret_read(self):
        protocol = Protocol()
        protocol.healthy = lambda: "https://example.invalid/api/v1"
        with self.assertRaises(RuntimeError):
            self.exercise(protocol)
        self.assertFalse(protocol.commands)
        self.assertFalse(protocol.calls)

    def test_bad_or_oversized_bootstrap_never_reaches_http_or_diagnostics(self):
        for raw, returncode in ((b"synthetic-private", 0), (b"x" * 2049, 0),
                                (b"synthetic-private", 1)):
            with self.subTest(returncode=returncode, length=len(raw)):
                protocol = Protocol()
                protocol.run = Mock(return_value=SimpleNamespace(stdout=raw, returncode=returncode))
                with self.assertRaisesRegex(RuntimeError, "^Media preparation smoke failed$"):
                    self.exercise(protocol)
                self.assertFalse(protocol.calls)

    def test_oversized_or_wrong_status_response_blocks_before_creation(self):
        for oversized in (False, True):
            with self.subTest(oversized=oversized):
                protocol = Protocol()
                protocol.fault = lambda path, body: Response(
                    "x" * 1048576 if oversized else {}, 200 if oversized else 201)
                with self.assertRaises(RuntimeError):
                    self.exercise(protocol)
                self.assertFalse(protocol.created)

    def test_non_smoke_container_and_platform_mismatch_are_rejected(self):
        runner = Mock()
        with patch("tool.server_media_smoke.subprocess.run", runner):
            for name, platform in (("production", "linux/amd64"),
                                   ("larenor-smoke-amd64", "linux/arm64")):
                with self.assertRaises(RuntimeError):
                    verify_media_preparation(name, lambda: "http://127.0.0.1:41001/api/v1", platform)
        self.assertFalse(runner.called)

    def test_authenticated_http_disables_redirects_and_environment_proxies(self):
        protocol = Protocol()
        with patch("tool.server_media_smoke.subprocess.run", protocol.run), \
             patch("tool.server_media_smoke.build_opener", return_value=SimpleNamespace(open=protocol.open)) as opener:
            verify_media_preparation("larenor-smoke-amd64", protocol.healthy, "linux/amd64")
        proxy, redirect = opener.call_args.args
        self.assertEqual(proxy.proxies, {})
        self.assertIsInstance(redirect, _NoRedirect)
        self.assertIsNone(redirect.redirect_request(None, None, 307, None, {}, "https://example.invalid"))


if __name__ == "__main__":
    unittest.main()
