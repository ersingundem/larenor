"""Offline contract tests for the manual Larenor Server package.

Uses a fake Docker daemon and a loopback-only HTTP fixture. No live server,
provider account, container lifecycle, VM or hardware is touched.
"""

import contextlib
from email.message import Message
import http.server
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import tempfile
import threading
import unittest
import urllib.error
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "deploy/larenor-server"
SPEC = importlib.util.spec_from_file_location("larenor_deployment", PACKAGE / "manage.py")
deployment = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(deployment)


class FakeDocker:
    def __init__(self, directory, running=True):
        self.calls = []
        self.state = {
            "id": "a" * 64, "name": "/larenor-server", "running": running,
            "paused": False, "restarting": False, "oom": False, "exitCode": 0,
            "image": deployment.IMAGE, "user": "0:0", "network": "host",
            "privileged": False, "caps": ["NET_BIND_SERVICE"], "capDrop": ["ALL"],
            "security": ["no-new-privileges:true"], "devices": [],
            "logs": {"Type": "json-file", "Config": {"max-size": "10m", "max-file": "3"}},
            "mounts": [{"Type": "bind", "Source": str(directory),
                        "Destination": "/data", "RW": True}],
        }
        self.fail_stop = False
        self.fail_start = False
        self.forced_stop = False

    def __call__(self, args, timeout=15):
        self.calls.append(args)
        if args[0] == "inspect":
            return json.dumps(self.state)
        if args[0] == "stop":
            self.state["running"] = False
            if self.fail_stop:
                raise deployment.DeploymentError("docker_timeout")
            self.state["exitCode"] = 137 if self.forced_stop else 0
        elif args[0] == "start":
            if self.fail_start:
                raise deployment.DeploymentError("docker_command_failed")
            self.state["running"] = True
        else:
            raise AssertionError("Unexpected Docker command")
        return ""

    @property
    def mutations(self):
        return [command for command in self.calls if command[0] != "inspect"]


class MemoryResponse:
    def __init__(self, body, content_type="application/json", status=200):
        self.body = io.BytesIO(body)
        self.status = status
        self.headers = Message()
        self.headers["Content-Type"] = content_type

    def read1(self, limit):
        return self.body.read(limit)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.body.close()


class FakeOpener:
    def __init__(self, response=None, error=None):
        self.response, self.error, self.calls = response, error, []

    def open(self, request, timeout):
        self.calls.append((request, timeout))
        if self.error:
            raise self.error
        return self.response


class DeploymentConfigTest(unittest.TestCase):
    def test_shared_compose_is_pinned_private_and_has_supported_casaos_metadata(self):
        config = json.loads((PACKAGE / "compose.yaml").read_text())
        self.assertEqual(config["name"], "larenor-server")
        self.assertEqual(list(config["services"]), ["larenor-server"])
        service = config["services"]["larenor-server"]
        self.assertEqual(service["image"], deployment.IMAGE)
        self.assertRegex(service["image"], r":2\.10\.2@sha256:[a-f0-9]{64}$")
        self.assertEqual(service["container_name"], "larenor-server")
        self.assertEqual(service["network_mode"], "host")
        self.assertEqual(service["user"], "0:0")
        self.assertEqual(service["cap_drop"], ["ALL"])
        self.assertEqual(service["cap_add"], ["NET_BIND_SERVICE"])
        self.assertEqual(service["security_opt"], ["no-new-privileges:true"])
        self.assertEqual(service["logging"], {
            "driver": "json-file", "options": {"max-size": "10m", "max-file": "3"}})
        self.assertEqual(service["restart"], "unless-stopped")
        self.assertEqual(service["environment"], {"LOG_LEVEL": "warning"})
        for forbidden in ("ports", "privileged", "devices", "env_file", "pid"):
            self.assertNotIn(forbidden, service)
        self.assertEqual(service["volumes"], [{"type": "bind", "source": str(deployment.DATA),
                                             "target": "/data", "bind": {"create_host_path": False}}])
        metadata = config["x-casaos"]
        # Fields verified against CasaOS-AppManagement's ComposeAppStoreInfo schema.
        for key in ("author", "category", "description", "developer", "icon", "screenshot_link",
                    "tagline", "thumbnail", "title", "tips", "index", "port_map"):
            self.assertIn(key, metadata)
        self.assertEqual(metadata["main"], "larenor-server")
        self.assertEqual(metadata["title"]["tr_tr"], "Larenor Server")
        self.assertEqual(metadata["title"]["en_us"], "Larenor Server")
        self.assertEqual(metadata["port_map"], "8095")
        self.assertIn("Music Assistant", metadata["developer"])
        self.assertEqual(metadata["architectures"], ["amd64", "arm64"])

    def test_optional_library_is_read_only_and_never_created_by_docker(self):
        volume = json.loads((PACKAGE / "local-music.compose.yaml").read_text())["services"][
            "larenor-server"]["volumes"][0]
        self.assertTrue(volume["read_only"])
        self.assertEqual(volume["target"], "/media")
        self.assertFalse(volume["bind"]["create_host_path"])
        self.assertNotIn(".sock", volume["source"])

    def test_default_backup_is_a_plan_even_without_docker_or_directories(self):
        docker = FakeDocker("/missing")
        self.assertEqual(deployment.backup(runner=docker), {
            "status": "backup_plan_only", "mutations": False})
        self.assertEqual(docker.calls, [])

    def test_default_cli_only_runs_preflight(self):
        with patch.object(deployment, "preflight", return_value={"system": "unsupported"}) as check:
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(deployment.main([]), 1)
            check.assert_called_once_with(deployment.DATA)

    def test_subprocess_errors_and_bodies_are_never_printed(self):
        with patch.object(deployment.subprocess, "run") as run:
            run.return_value.returncode = 1
            run.return_value.stdout = "private-token"
            run.return_value.stderr = "provider-secret"
            with self.assertRaisesRegex(deployment.DeploymentError, "^docker_command_failed$"):
                deployment.run_docker(["inspect"])
            self.assertTrue(run.call_args.kwargs["capture_output"])
            self.assertNotIn("shell", run.call_args.kwargs)


class ProbeTest(unittest.TestCase):
    INFO = {"server_id": "private-instance-id", "server_version": "2.10.2", "schema_version": 28,
            "internal_url": "http://private-host", "unexpected_secret": "never-print"}

    def test_actual_http_request_does_not_follow_redirect_or_send_credentials(self):
        seen = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                seen.append((self.path, dict(self.headers)))
                self.send_response(302)
                self.send_header("Location", "/private-target")
                self.end_headers()

            def log_message(self, *_):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            with patch.dict(os.environ, {"http_proxy": "http://invalid-proxy:1"}):
                result = deployment.probe(f"http://127.0.0.1:{server.server_port}")
            self.assertEqual(result, {"status": "redirect_rejected"})
            self.assertEqual([path for path, _ in seen], ["/info"])
            headers = {key.lower(): value for key, value in seen[0][1].items()}
            self.assertNotIn("authorization", headers)
            self.assertNotIn("cookie", headers)
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=2)

    def test_success_is_only_validated_public_server_info_not_login_or_playback(self):
        opener = FakeOpener(MemoryResponse(json.dumps(self.INFO).encode()))
        result = deployment.probe("http://server:8095/", opener)
        self.assertEqual(result, {"status": "server_reachable", "version_matches_pin": True,
                                  "authentication_verified": False, "playback_verified": False})
        self.assertEqual(opener.calls[0][0].full_url, "http://server:8095/info")
        self.assertEqual(opener.calls[0][1], 5)
        self.assertNotIn("private", json.dumps(result))

    def test_unexpected_installed_version_is_visible_without_claiming_pinned_version(self):
        info = dict(self.INFO, server_version="2.10.1")
        result = deployment.probe("https://server", FakeOpener(MemoryResponse(json.dumps(info).encode())))
        self.assertFalse(result["version_matches_pin"])

    def test_authentication_permission_http_and_timeout_are_distinct(self):
        for code, expected in ((401, "authentication_required"), (403, "permission_denied"),
                               (307, "redirect_rejected"), (500, "server_error"), (404, "http_error")):
            with self.subTest(code=code):
                error = urllib.error.HTTPError("https://secret-host", code, "private reason", {}, io.BytesIO(b"private body"))
                self.assertEqual(deployment.probe("http://host", FakeOpener(error=error)), {"status": expected})
        for error, expected in ((TimeoutError("secret"), "timeout"),
                                (urllib.error.URLError(TimeoutError()), "timeout"),
                                (urllib.error.URLError("private URL"), "network_error")):
            self.assertEqual(deployment.probe("http://host", FakeOpener(error=error)), {"status": expected})

    def test_invalid_credential_or_endpoint_urls_issue_no_request(self):
        for url in ("https://user:password@host", "http://host?token=private", "https://host/#private",
                    "http://host/api", "file:///secret", "http://host:0", "http://host:70000",
                    "http://host\\@other", "http://host\n", "https://%40host", "/relative"):
            with self.subTest(url=url):
                opener = FakeOpener()
                with self.assertRaisesRegex(deployment.DeploymentError, "^invalid_url$"):
                    deployment.probe(url, opener)
                self.assertEqual(opener.calls, [])

    def test_malformed_html_oversized_or_wrong_schema_cannot_look_healthy(self):
        for body, content_type, expected in (
            (b"<html>login</html>", "text/html", "invalid_response"),
            (b"not JSON", "application/json", "invalid_response"),
            (b"{}", "application/json", "invalid_response"),
            (b"x" * (deployment.MAX_RESPONSE + 1), "application/json", "response_too_large"),
            (json.dumps(dict(self.INFO, schema_version=True)).encode(), "application/json", "invalid_response"),
        ):
            with self.subTest(expected=expected):
                self.assertEqual(deployment.probe("http://host", FakeOpener(MemoryResponse(body, content_type))),
                                 {"status": expected})

    def test_response_deadline_prevents_indefinite_small_chunk_stream(self):
        with patch.object(deployment.time, "monotonic", side_effect=[0, 0, 6]):
            result = deployment.probe("http://host", FakeOpener(MemoryResponse(b"x" * 9000)))
        self.assertEqual(result, {"status": "timeout"})


class RuntimeAndBackupTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.data = self.root / "data"
        self.destination = self.root / "backups"
        for directory in (self.data, self.destination):
            directory.mkdir(mode=0o700)
        (self.data / "auth.db").write_bytes(b"private credential fixture")
        self.docker = FakeDocker(self.data)

    def tearDown(self):
        self.temporary.cleanup()

    def backup(self, **kwargs):
        return deployment.backup(self.data, self.destination, execute=True, runner=self.docker, **kwargs)

    def test_runtime_review_rejects_importer_dropped_security_or_wrong_mounts(self):
        changes = {
            "network": "bridge", "image": "ghcr.io/music-assistant/server:latest", "user": "",
            "privileged": True, "caps": ["SYS_ADMIN"], "capDrop": [],
            "security": ["apparmor=unconfined"], "devices": [{"PathOnHost": "/dev/snd"}],
            "logs": {"Type": "json-file", "Config": {}},
            "mounts": [{"Type": "bind", "Source": str(self.data), "Destination": "/data", "RW": False}],
        }
        for key, value in changes.items():
            with self.subTest(key=key):
                docker = FakeDocker(self.data)
                docker.state[key] = value
                with self.assertRaises(deployment.DeploymentError):
                    deployment.inspect_runtime(self.data, docker)
                self.assertEqual(docker.mutations, [])

    def test_airplay_ptp_requires_exactly_bind_service_capability(self):
        for caps in ([], None, ["SYS_ADMIN"], ["NET_BIND_SERVICE", "NET_ADMIN"]):
            with self.subTest(caps=caps):
                self.docker.state["caps"] = caps
                with self.assertRaisesRegex(deployment.DeploymentError, "runtime_policy_mismatch"):
                    deployment.inspect_runtime(self.data, self.docker)
        self.docker.state["caps"] = ["CAP_NET_BIND_SERVICE"]
        deployment.inspect_runtime(self.data, self.docker)
        self.assertEqual(self.docker.mutations, [])

    def test_malformed_runtime_packet_fails_before_any_container_mutation(self):
        for changes in ({"caps": [1]}, {"capDrop": "ALL"}, {"running": 1},
                        {"mounts": {}}, {"image": None}, {"id": "../../../other"}):
            with self.subTest(changes=changes):
                docker = FakeDocker(self.data)
                docker.state.update(changes)
                with self.assertRaisesRegex(deployment.DeploymentError, "runtime_identity_or_mount_invalid"):
                    deployment.inspect_runtime(self.data, docker)
                self.assertEqual(docker.mutations, [])

    def test_required_runtime_field_cannot_be_silently_defaulted(self):
        del self.docker.state["caps"]
        with self.assertRaisesRegex(deployment.DeploymentError, "runtime_identity_or_mount_invalid"):
            deployment.inspect_runtime(self.data, self.docker)

    def test_backup_stop_archive_then_restart_same_container_and_keep_archive_private(self):
        result = self.backup()
        self.assertEqual(result["status"], "backup_complete")
        self.assertTrue(result["service_restarted"])
        self.assertEqual(self.docker.mutations, [["stop", "--time", "60", "a" * 64], ["start", "a" * 64]])
        archive_path = self.destination / result["archive"]
        self.assertEqual(stat.S_IMODE(archive_path.stat().st_mode), 0o600)
        with deployment.tarfile.open(archive_path) as archive:
            self.assertEqual(archive.getnames(), ["larenor-server-backup.json", "data", "data/auth.db"])
            self.assertEqual(archive.extractfile("data/auth.db").read(), b"private credential fixture")
            self.assertEqual(json.load(archive.extractfile("larenor-server-backup.json"))["image"], deployment.IMAGE)
        self.assertTrue(self.docker.state["running"])
        self.assertFalse(list(self.destination.glob("*.partial")))

    def test_archive_failure_still_restarts_original_service_without_success_or_partial_archive(self):
        def fail(directory, stream):
            self.assertFalse(self.docker.state["running"])
            stream.write(b"partial credential backup")
            raise OSError("fixture disk full")

        with self.assertRaises(OSError):
            self.backup(archiver=fail)
        self.assertTrue(self.docker.state["running"])
        self.assertEqual(self.docker.mutations[-1], ["start", "a" * 64])
        self.assertFalse(list(self.destination.glob("*.tar.gz*")))

    def test_timeout_after_stop_attempt_still_attempts_recovery(self):
        self.docker.fail_stop = True
        with self.assertRaisesRegex(deployment.DeploymentError, "docker_timeout"):
            self.backup()
        self.assertTrue(self.docker.state["running"])
        self.assertEqual(self.docker.mutations[-1][0], "start")

    def test_forced_or_unclean_stop_is_not_claimed_as_consistent_backup(self):
        self.docker.forced_stop = True
        with self.assertRaisesRegex(deployment.DeploymentError, "unclean_stop"):
            self.backup()
        self.assertTrue(self.docker.state["running"])
        self.assertFalse(list(self.destination.glob("*.tar.gz")))

    def test_existing_stopped_service_is_not_started(self):
        self.docker.state["running"] = False
        result = self.backup()
        self.assertFalse(result["service_restarted"])
        self.assertEqual(self.docker.mutations, [])

    def test_restart_failure_retains_completed_private_backup_and_does_not_report_success(self):
        self.docker.fail_start = True
        with self.assertRaisesRegex(deployment.DeploymentError, "restart_failed_check_private_backups"):
            self.backup()
        files = list(self.destination.glob("*.tar.gz"))
        self.assertEqual(len(files), 1)
        self.assertEqual(stat.S_IMODE(files[0].stat().st_mode), 0o600)

    def test_replaced_container_is_never_started_using_an_old_name_or_old_id(self):
        def replacement(directory, stream):
            self.docker.state["id"] = "b" * 64
            stream.write(b"partial")

        with self.assertRaisesRegex(deployment.DeploymentError, "container_changed_restart_manually"):
            self.backup(archiver=replacement)
        self.assertEqual([command for command in self.docker.mutations if command[0] == "start"], [])

    def test_private_path_or_symlink_failure_has_zero_container_mutations(self):
        for mode in (0o755, 0o770, 0o707):
            with self.subTest(mode=mode):
                self.destination.chmod(mode)
                with self.assertRaisesRegex(deployment.DeploymentError, "directory_not_private"):
                    self.backup()
                self.assertEqual(self.docker.calls, [])
        self.destination.chmod(0o700)
        link = self.root / "linked"
        link.symlink_to(self.data, target_is_directory=True)
        with self.assertRaisesRegex(deployment.DeploymentError, "symlink_directory"):
            deployment.backup(link, self.destination, execute=True, runner=self.docker)
        self.assertEqual(self.docker.calls, [])

    def test_backup_may_not_contain_itself(self):
        child = self.data / "backups"
        child.mkdir(mode=0o700)
        with self.assertRaisesRegex(deployment.DeploymentError, "backup_directories_overlap"):
            deployment.backup(self.data, child, execute=True, runner=self.docker)
        self.assertEqual(self.docker.calls, [])

    def test_unexpected_symlink_member_fails_instead_of_backing_up_external_secret(self):
        external = self.root / "outside-secret"
        external.write_text("never archive")
        (self.data / "link").symlink_to(external)
        with self.assertRaisesRegex(deployment.DeploymentError, "backup_non_regular_member"):
            self.backup()
        self.assertTrue(self.docker.state["running"])
        self.assertFalse(list(self.destination.glob("*.tar.gz")))

    def test_existing_archive_is_never_overwritten(self):
        with patch.object(deployment.uuid, "uuid4") as identifier:
            identifier.return_value.hex = "a" * 32
            # Pin the timestamp as well, without depending on wall-clock speed.
            with patch.object(deployment.datetime, "datetime") as clock:
                clock.now.return_value.strftime.return_value = "20260905T120000Z"
                first = self.backup()
                before = (self.destination / first["archive"]).read_bytes()
                with self.assertRaises(FileExistsError):
                    self.backup()
                self.assertEqual((self.destination / first["archive"]).read_bytes(), before)
                self.assertTrue(self.docker.state["running"])

    def test_another_backup_holding_the_lock_prevents_any_docker_call(self):
        lock = self.destination / ".backup.lock"
        with lock.open("w") as stream:
            deployment.fcntl.flock(stream, deployment.fcntl.LOCK_EX | deployment.fcntl.LOCK_NB)
            with self.assertRaisesRegex(deployment.DeploymentError, "backup_already_running"):
                self.backup()
        self.assertEqual(self.docker.calls, [])

    def test_cleanup_failure_cannot_skip_service_restart(self):
        original = Path.unlink

        def unlink(path, *args, **kwargs):
            if str(path).endswith(".partial"):
                raise PermissionError("fixture cleanup failure")
            return original(path, *args, **kwargs)

        with patch.object(Path, "unlink", new=unlink):
            with self.assertRaisesRegex(deployment.DeploymentError, "backup_cleanup_failed"):
                self.backup()
        self.assertTrue(self.docker.state["running"])
        self.assertEqual(self.docker.mutations[-1], ["start", "a" * 64])

    def test_archive_and_destination_directory_are_fsynced_before_success(self):
        synced = []

        def sync(fd):
            synced.append(stat.S_ISDIR(os.fstat(fd).st_mode))

        with patch.object(deployment.os, "fsync", side_effect=sync):
            self.backup()
        self.assertEqual(synced, [False, True])

    def test_failed_directory_fsync_still_restarts_service_and_reports_failure(self):
        def fail_directory(fd):
            if stat.S_ISDIR(os.fstat(fd).st_mode):
                raise OSError("fixture filesystem fsync failure")

        with patch.object(deployment.os, "fsync", side_effect=fail_directory):
            with self.assertRaises(OSError):
                self.backup()
        self.assertTrue(self.docker.state["running"])

    def test_container_still_running_after_stop_never_archives_live_database(self):
        runner = self.docker

        def ignored_stop(args, timeout=15):
            result = runner(args, timeout)
            if args[0] == "stop":
                runner.state["running"] = True
            return result

        with self.assertRaisesRegex(deployment.DeploymentError, "not_stopped"):
            deployment.backup(self.data, self.destination, execute=True, runner=ignored_stop)
        self.assertFalse(list(self.destination.glob("*.tar.gz")))

    def test_world_writable_parent_cannot_replace_private_backup_directory(self):
        parent = self.root / "unsafe"
        parent.mkdir(mode=0o700)
        destination = parent / "backups"
        destination.mkdir(mode=0o700)
        parent.chmod(0o777)
        with self.assertRaisesRegex(deployment.DeploymentError, "directory_parent_not_trusted"):
            deployment.backup(self.data, destination, execute=True, runner=self.docker)
        self.assertEqual(self.docker.calls, [])

    def test_cli_archive_exception_does_not_expose_data_path_or_credentials(self):
        output = io.StringIO()
        with patch.object(deployment.platform, "system", return_value="Linux"), \
                patch.object(deployment.os, "geteuid", return_value=0), \
                patch.object(deployment, "backup", side_effect=OSError("private-token /private-data-path")), \
                contextlib.redirect_stdout(output):
            self.assertEqual(deployment.main(["backup", "--execute"]), 1)
        self.assertEqual(json.loads(output.getvalue()), {"status": "operation_failed"})


if __name__ == "__main__":
    unittest.main()
