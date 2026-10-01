import hashlib
import io
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import textwrap
import tempfile
import unittest
from unittest import mock

from tool import f60_sunshine_owned_host as host


ROOT = Path(__file__).resolve().parents[2]
HOST_WORKFLOW = (ROOT / ".github/workflows/f60-sunshine-owned-host.yml").read_text()
SERVER_WORKFLOW = (ROOT / ".github/workflows/server-test.yml").read_text()
_GUARD_STEP = HOST_WORKFLOW.split(
    "      - name: Require reviewed same-repository source\n", 1,
)[1].split("\n      - name:", 1)[0]
GUARD_SCRIPT = textwrap.dedent(_GUARD_STEP.split("        run: |\n", 1)[1])


class _Response(io.BytesIO):
    status = 200

    def __init__(self, body: bytes, url: str):
        super().__init__(body)
        self._url = url
        self.headers = {"Content-Length": str(len(body))}

    def geturl(self):
        return self._url

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


class _HttpsResponse:
    def __init__(self, body: bytes, *, status: int = 200):
        self.status = status
        self._body = body

    def getheader(self, name):
        return str(len(self._body)) if name.lower() == "content-length" else None

    def read(self, amount=-1):
        if amount < 0:
            return self._body
        result, self._body = self._body[:amount], self._body[amount:]
        return result


class _HttpsConnection:
    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []
        self.closed = False

    def request(self, method, path, body=None, headers=None):
        self.requests.append((method, path, body, dict(headers or {})))

    def getresponse(self):
        return self.responses.pop(0)

    def close(self):
        self.closed = True


class _Process:
    def __init__(self, pid):
        self.pid = pid
        self.returncode = None
        self.calls = []

    def poll(self):
        return self.returncode

    def terminate(self):
        self.calls.append("terminate")

    def wait(self, timeout=None):
        self.calls.append(("wait", timeout))
        self.returncode = 0
        return 0

    def kill(self):
        self.calls.append("kill")
        self.returncode = -9


class _Completed:
    def __init__(self, returncode=0, stdout="", stderr=""):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


class F60SunshineOwnedHostTest(unittest.TestCase):
    def _run_workflow_guard(self, **changes):
        reference = "refs/heads/codex/project-completion-100"
        values = {
            "CALLER_CONTRACT": "",
            "GITHUB_ENV": "",
            "GITHUB_EVENT_NAME": "workflow_dispatch",
            "GITHUB_REF": reference,
            "GITHUB_REPOSITORY": "ersingundem/larenor",
            "GITHUB_SHA": "a" * 40,
            "GITHUB_WORKFLOW_REF": (
                "ersingundem/larenor/.github/workflows/"
                f"f60-sunshine-owned-host.yml@{reference}"
            ),
            "GITHUB_WORKFLOW_SHA": "a" * 40,
            "PR_HEAD_REPOSITORY": "",
            "RUNNER_ENVIRONMENT": "github-hosted",
            "RUNNER_TEMP": "",
        }
        values.update(changes)
        with tempfile.TemporaryDirectory() as temporary:
            values["RUNNER_TEMP"] = values["RUNNER_TEMP"] or temporary
            values["GITHUB_ENV"] = values["GITHUB_ENV"] or str(
                Path(temporary) / "github-env"
            )
            return subprocess.run(
                ["/bin/bash", "-e", "-o", "pipefail", "-c", GUARD_SCRIPT],
                env=values,
                text=True,
                capture_output=True,
                check=False,
            )

    def test_registered_dispatcher_is_isolated_from_required_server_gates(self):
        self.assertIn("          - f60-host", SERVER_WORKFLOW)
        self.assertIn(
            "if: github.event_name != 'workflow_dispatch' || inputs.scope == 'all' || inputs.scope == 'f08'",
            SERVER_WORKFLOW,
        )
        self.assertIn(
            "if: github.event_name != 'workflow_dispatch' || inputs.scope == 'all' || inputs.scope == 'host'",
            SERVER_WORKFLOW,
        )
        self.assertIn(
            "if: github.event_name == 'workflow_dispatch' && inputs.scope == 'f60-host'",
            SERVER_WORKFLOW,
        )
        self.assertIn(
            "uses: ./.github/workflows/f60-sunshine-owned-host.yml",
            SERVER_WORKFLOW,
        )
        aggregate = SERVER_WORKFLOW.split("  server-test:\n", 1)[1]
        self.assertIn("inputs.scope == 'all'", aggregate)
        self.assertNotIn("f60-sunshine-owned-host", aggregate)

    def test_source_guard_accepts_exact_manual_or_registered_dispatcher(self):
        self.assertEqual(self._run_workflow_guard().returncode, 0)
        reference = "refs/heads/codex/project-completion-100"
        dispatched = self._run_workflow_guard(
            CALLER_CONTRACT="f60-owned-host-v1",
            GITHUB_WORKFLOW_REF=(
                "ersingundem/larenor/.github/workflows/"
                f"server-test.yml@{reference}"
            ),
        )
        self.assertEqual(dispatched.returncode, 0, dispatched.stderr)

    def test_source_guard_rejects_wrong_caller_contract_ref_or_revision(self):
        reference = "refs/heads/codex/project-completion-100"
        valid_dispatcher = (
            "ersingundem/larenor/.github/workflows/server-test.yml@" + reference
        )
        for changes in (
            {"CALLER_CONTRACT": "wrong", "GITHUB_WORKFLOW_REF": valid_dispatcher},
            {
                "CALLER_CONTRACT": "f60-owned-host-v1",
                "GITHUB_WORKFLOW_REF": (
                    "ersingundem/larenor/.github/workflows/other.yml@" + reference
                ),
            },
            {"GITHUB_REF": "refs/heads/unreviewed"},
            {"GITHUB_WORKFLOW_SHA": "b" * 40},
        ):
            with self.subTest(changes=changes):
                self.assertNotEqual(self._run_workflow_guard(**changes).returncode, 0)

    def test_release_identity_is_exact_official_ubuntu_2404_asset(self):
        self.assertEqual(host.SUNSHINE_TAG, "v2026.914.233613")
        self.assertEqual(
            host.SUNSHINE_ASSET,
            "sunshine_2026.914.233613-1+ubuntu24.04_amd64.deb",
        )
        self.assertEqual(
            host.SUNSHINE_SHA256,
            "c38e9c705f650f8705f61702717e99bec34044c5028fcb8f23a08fe041292c21",
        )
        self.assertTrue(host.SUNSHINE_URL.startswith("https://github.com/LizardByte/Sunshine/"))

    def test_owned_runner_rejects_non_github_wrong_os_arch_and_symlink_os_release(self):
        self.assertEqual(host.OS_RELEASE, Path("/usr/lib/os-release"))
        valid = 'ID=ubuntu\nVERSION_ID="24.04"\n'
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            release = root / "os-release"
            release.write_text(valid, encoding="utf-8")
            environment = {
                "GITHUB_ACTIONS": "true",
                "RUNNER_ENVIRONMENT": "github-hosted",
            }
            host.require_owned_runner(
                environment,
                os_release=release,
                machine="x86_64",
                platform_name="linux",
            )
            for changed in (
                {"GITHUB_ACTIONS": "false", "RUNNER_ENVIRONMENT": "github-hosted"},
                {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "self-hosted"},
            ):
                with self.assertRaises(host.HostFailure):
                    host.require_owned_runner(
                        changed,
                        os_release=release,
                        machine="x86_64",
                        platform_name="linux",
                    )
            release.write_text('ID=ubuntu\nVERSION_ID="22.04"\n', encoding="utf-8")
            with self.assertRaises(host.HostFailure):
                host.require_owned_runner(
                    environment,
                    os_release=release,
                    machine="x86_64",
                    platform_name="linux",
                )
            release.write_text(valid, encoding="utf-8")
            with self.assertRaises(host.HostFailure):
                host.require_owned_runner(
                    environment,
                    os_release=release,
                    machine="aarch64",
                    platform_name="linux",
                )
            target = root / "real-release"
            target.write_text(valid, encoding="utf-8")
            release.unlink()
            release.symlink_to(target)
            with self.assertRaises(host.HostFailure):
                host.require_owned_runner(
                    environment,
                    os_release=release,
                    machine="x86_64",
                    platform_name="linux",
                )

    def test_private_workspace_and_material_are_private_and_software_h264_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            workspace = host.PrivateWorkspace.create(parent)
            try:
                material = workspace.write_host_material(
                    username="owned-user", password="private-password"
                )
                self.assertEqual(stat.S_IMODE(workspace.root.stat().st_mode), 0o700)
                for path in (
                    material.config,
                    material.apps,
                    material.credentials,
                    material.state,
                ):
                    self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
                config = material.config.read_text(encoding="utf-8")
                self.assertIn("capture = x11\n", config)
                self.assertIn("encoder = software\n", config)
                self.assertIn("sw_preset = ultrafast\n", config)
                self.assertIn("hevc_mode = 1\n", config)
                self.assertIn("av1_mode = 1\n", config)
                self.assertIn("max_bitrate = 2000\n", config)
                self.assertIn("keyboard = disabled\n", config)
                self.assertIn("mouse = disabled\n", config)
                self.assertIn("controller = disabled\n", config)
                self.assertNotIn("private-password", config)
                apps = json.loads(material.apps.read_text(encoding="utf-8"))
                self.assertEqual(apps, {"env": {}, "apps": [{"name": "Desktop"}]})
            finally:
                workspace.close()
            self.assertFalse(workspace.root.exists())

    def test_stream_profile_enables_only_owned_keyboard_and_mouse_input(self):
        with tempfile.TemporaryDirectory() as temporary:
            workspace = host.PrivateWorkspace.create(Path(temporary))
            try:
                material = workspace.write_host_material(
                    username="owned-user",
                    password="private-password",
                    stream_profile=True,
                )
                config = material.config.read_text(encoding="utf-8")
                self.assertIn("keyboard = enabled\n", config)
                self.assertIn("mouse = enabled\n", config)
                self.assertIn("controller = disabled\n", config)
            finally:
                workspace.close()

    def test_release_download_is_bounded_redirect_allowlisted_and_digest_checked(self):
        body = b"owned release bytes"
        expected = hashlib.sha256(body).hexdigest()
        final_url = "https://release-assets.githubusercontent.com/fixture/deb"
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "sunshine.deb"
            host._download_verified(
                "https://github.com/LizardByte/Sunshine/releases/download/tag/file",
                destination,
                expected_sha256=expected,
                max_bytes=1024,
                opener=lambda *_args, **_kwargs: _Response(body, final_url),
            )
            self.assertEqual(destination.read_bytes(), body)
            self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o600)
            for bad_url in (
                "http://release-assets.githubusercontent.com/fixture/deb",
                "https://example.invalid/fixture/deb",
            ):
                with self.assertRaises(host.HostFailure):
                    host._download_verified(
                        "https://github.com/LizardByte/Sunshine/releases/download/tag/file",
                        Path(temporary) / "bad.deb",
                        expected_sha256=expected,
                        max_bytes=1024,
                        opener=lambda *_a, u=bad_url, **_k: _Response(body, u),
                    )
            with self.assertRaises(host.HostFailure):
                host._download_verified(
                    "https://github.com/LizardByte/Sunshine/releases/download/tag/file",
                    Path(temporary) / "wrong.deb",
                    expected_sha256="0" * 64,
                    max_bytes=1024,
                    opener=lambda *_args, **_kwargs: _Response(body, final_url),
                )

    def test_install_uses_only_pinned_local_deb_and_exact_dpkg_readback(self):
        body = b"package"
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(
            host, "SUNSHINE_ASSET_BYTES", len(body)
        ), mock.patch.object(
            host, "SUNSHINE_SHA256", hashlib.sha256(body).hexdigest()
        ):
            package = Path(temporary) / host.SUNSHINE_ASSET
            package.write_bytes(body)
            calls = []

            def run(argv, **kwargs):
                calls.append((argv, kwargs))
                if argv[0] == "/usr/bin/dpkg-query":
                    return _Completed(stdout=host.SUNSHINE_PACKAGE_VERSION)
                return _Completed()

            host.install_release(package, runner=run)
        self.assertEqual(
            calls[0][0],
            [
                "/usr/bin/sudo",
                "/usr/bin/apt-get",
                "install",
                "--yes",
                "--no-install-recommends",
                str(package),
            ],
        )
        self.assertEqual(
            calls[1][0],
            [
                "/usr/bin/dpkg-query",
                "--show",
                "--showformat=${Version}",
                "sunshine",
            ],
        )

    def test_pairing_and_unpair_use_exact_routes_bodies_and_strict_responses(self):
        pending_id = "a" * 32
        owned_uuid = "0f5f1830-7253-4ce8-986f-0cb2c7946044"
        connection = _HttpsConnection(
            [
                _HttpsResponse(json.dumps({"pairings": [{
                    "id": pending_id,
                    "name": "Larenor F60",
                    "address": "192.0.2.4",
                }]}).encode()),
                _HttpsResponse(b'{"status":true}'),
                _HttpsResponse(json.dumps({
                    "named_certs": [{
                        "name": "Larenor F60",
                        "uuid": owned_uuid,
                        "enabled": True,
                    }],
                    "status": True,
                }).encode()),
                _HttpsResponse(json.dumps({
                    "named_certs": [{
                        "name": "Larenor F60",
                        "uuid": owned_uuid,
                        "enabled": True,
                    }],
                    "status": True,
                }).encode()),
                _HttpsResponse(b'{"status":true}'),
                _HttpsResponse(b'{"named_certs":[],"status":true}'),
            ]
        )
        api = host.SunshineApi(
            username="private-user",
            password="private-password",
            certificate=Path("/private/cert.pem"),
            connection_factory=lambda *_args, **_kwargs: connection,
            ssl_context_factory=lambda _path: object(),
        )
        self.assertEqual(api.pending_pairing("Larenor F60"), pending_id)
        api.approve_pairing(pending_id, "1234", "Larenor F60")
        self.assertEqual(api.owned_client_uuid("Larenor F60"), owned_uuid)
        api.require_owned_client_present("Larenor F60", owned_uuid)
        api.unpair_owned(owned_uuid)
        api.require_client_absent("Larenor F60")
        requests = [(method, path, body) for method, path, body, _ in connection.requests]
        self.assertEqual(
            requests,
            [
                ("GET", "/api/pin", None),
                ("POST", "/api/pin", b'{"name":"Larenor F60","pairing_id":"' + pending_id.encode() + b'","pin":"1234"}'),
                ("GET", "/api/clients/list", None),
                ("GET", "/api/clients/list", None),
                ("POST", "/api/clients/unpair", b'{"uuid":"' + owned_uuid.encode() + b'"}'),
                ("GET", "/api/clients/list", None),
            ],
        )
        for _, _, _, headers in connection.requests:
            self.assertIn("Authorization", headers)
            self.assertNotIn("Origin", headers)
            self.assertNotIn("Referer", headers)
        self.assertNotIn("private-password", repr(api))

    def test_present_readback_requires_exact_uuid_name_and_enabled_state(self):
        owned_uuid = "0f5f1830-7253-4ce8-986f-0cb2c7946044"
        changed_uuid = "dff42a53-dfde-4031-8c3e-c11fd2229d79"
        for client in (
            {"name": "roth", "uuid": changed_uuid, "enabled": True},
            {"name": "replacement", "uuid": owned_uuid, "enabled": True},
            {"name": "roth", "uuid": owned_uuid, "enabled": False},
        ):
            with self.subTest(client=client):
                connection = _HttpsConnection([_HttpsResponse(json.dumps({
                    "named_certs": [client], "status": True,
                }).encode())])
                api = host.SunshineApi(
                    username="private-user",
                    password="private-password",
                    certificate=Path("/private/cert.pem"),
                    connection_factory=lambda *_args, **_kwargs: connection,
                    ssl_context_factory=lambda _path: object(),
                )
                with self.assertRaises(host.HostFailure):
                    api.require_owned_client_present("roth", owned_uuid)

    def test_api_rejects_duplicate_extra_malformed_and_oversized_json_without_secret(self):
        responses = (
            b'{"pairings":[],"pairings":[]}',
            b'{"pairings":[],"extra":true}',
            b'{"pairings":[{"id":"' + b"a" * 32 + b'","name":"n","address":"not-an-ip"}]}',
        )
        for body in responses:
            with self.subTest(body=body[:20]):
                connection = _HttpsConnection([_HttpsResponse(body)])
                api = host.SunshineApi(
                    username="private-user",
                    password="private-password",
                    certificate=Path("/private/cert.pem"),
                    connection_factory=lambda *_a, c=connection, **_k: c,
                    ssl_context_factory=lambda _path: object(),
                )
                with self.assertRaises(host.HostFailure) as failure:
                    api.pending_pairing("n")
                self.assertNotIn("private-password", str(failure.exception))
        connection = _HttpsConnection(
            [_HttpsResponse(b"{" + b" " * (host.MAX_API_BYTES + 1))]
        )
        api = host.SunshineApi(
            username="private-user",
            password="private-password",
            certificate=Path("/private/cert.pem"),
            connection_factory=lambda *_a, **_k: connection,
            ssl_context_factory=lambda _path: object(),
        )
        with self.assertRaises(host.HostFailure):
            api.pending_pairing("n")

    def test_malformed_mutation_input_never_reaches_transport(self):
        connection = _HttpsConnection([])
        api = host.SunshineApi(
            username="u",
            password="p",
            certificate=Path("/private/cert.pem"),
            connection_factory=lambda *_a, **_k: connection,
            ssl_context_factory=lambda _path: object(),
        )
        invalid = (
            lambda: api.approve_pairing("a" * 31, "1234", "owned"),
            lambda: api.approve_pairing("a" * 32, "12x4", "owned"),
            lambda: api.approve_pairing("a" * 32, "1234", ""),
            lambda: api.cancel_pairing("z" * 32),
            lambda: api.unpair_owned("not-a-uuid"),
        )
        for call in invalid:
            with self.assertRaises(host.HostFailure):
                call()
        self.assertEqual(connection.requests, [])

    def test_pinned_tls_context_uses_only_private_fixture_certificate(self):
        with tempfile.TemporaryDirectory() as temporary:
            certificate = Path(temporary) / "cert.pem"
            certificate.write_text(
                "-----BEGIN CERTIFICATE-----\nfixture\n-----END CERTIFICATE-----\n",
                encoding="ascii",
            )
            with mock.patch(
                "tool.f60_sunshine_owned_host.ssl.create_default_context"
            ) as create:
                context = mock.Mock()
                create.return_value = context
                self.assertIs(host.pinned_ssl_context(certificate), context)
            create.assert_called_once_with(cafile=str(certificate))
            self.assertTrue(context.check_hostname)
            self.assertEqual(context.verify_mode, host.ssl.CERT_REQUIRED)

    def test_mdns_parser_accepts_one_exact_resolved_nvstream_record_without_exposing_ip(self):
        raw = (
            "+;eth0;IPv4;Larenor-F60-Owned;_nvstream._tcp;local\n"
            "=;eth0;IPv4;Larenor-F60-Owned;_nvstream._tcp;local;host.local;192.0.2.5;47989;\n"
        )
        receipt = host.verify_mdns(raw, expected_name="Larenor-F60-Owned")
        self.assertEqual(receipt, {"service": "_nvstream._tcp", "port": 47989})
        self.assertNotIn("192.0.2.5", json.dumps(receipt))
        self.assertEqual(
            host.verify_mdns(raw + raw, expected_name="Larenor-F60-Owned"), receipt
        )
        ipv6 = (
            "=;eth0;IPv6;Larenor-F60-Owned;_nvstream._tcp;local;host.local;2001:db8::5;47989;\n"
        )
        self.assertEqual(
            host.verify_mdns(raw + ipv6, expected_name="Larenor-F60-Owned"), receipt
        )
        with self.assertRaises(host.HostFailure):
            host.verify_mdns(
                raw
                + raw.replace("host.local", "other.local").replace(
                    "192.0.2.5", "192.0.2.6"
                ),
                expected_name="Larenor-F60-Owned",
            )
        with self.assertRaises(host.HostFailure):
            host.verify_mdns(
                raw.replace("47989", "47990"),
                expected_name="Larenor-F60-Owned",
            )

    def test_mdns_parser_filters_to_default_interface_and_rejects_foreign_instance(self):
        owned = (
            "=;eth0;IPv4;runner-host;_nvstream._tcp;local;host.local;192.0.2.5;47989;\n"
        )
        loopback = owned.replace(";eth0;", ";lo;").replace(
            "192.0.2.5", "127.0.0.1"
        )
        self.assertEqual(
            host.verify_mdns(
                loopback + owned,
                expected_name="runner-host",
                expected_interface="eth0",
            ),
            {"service": "_nvstream._tcp", "port": 47989},
        )
        with self.assertRaises(host.HostFailure):
            host.verify_mdns(
                loopback,
                expected_name="runner-host",
                expected_interface="eth0",
            )
        with self.assertRaises(host.HostFailure):
            host.verify_mdns(
                owned.replace("runner-host", "foreign-host"),
                expected_name="runner-host",
                expected_interface="eth0",
            )

    def test_mdns_identity_matches_pinned_sunshine_hostname_algorithm(self):
        self.assertEqual(host._sunshine_mdns_instance_name("runner-host"), "runner-host")
        self.assertEqual(host._sunshine_mdns_instance_name("runner host"), "runner-host")
        self.assertEqual(host._sunshine_mdns_instance_name("runner.local"), "runner")
        self.assertEqual(host._sunshine_mdns_instance_name(".invalid"), "Sunshine")
        self.assertEqual(host._sunshine_mdns_instance_name("a" * 70), "a" * 63)
        with self.assertRaises(host.HostFailure):
            host._sunshine_mdns_instance_name("rünner")

    def test_mdns_observation_accepts_exact_bounded_resolution_before_avahi_timeout(self):
        raw = (
            "+;eth0;IPv4;runner-host;_nvstream._tcp;local\n"
            "=;eth0;IPv4;runner-host;_nvstream._tcp;local;host.local;192.0.2.5;47989;\n"
        )
        timed_out = subprocess.TimeoutExpired(
            ["/usr/bin/avahi-browse"], 10, output=raw.encode("utf-8")
        )
        with mock.patch.object(
            host, "_default_interface", return_value="eth0"
        ), mock.patch.object(
            host.socket, "gethostname", return_value="runner-host"
        ), mock.patch.object(
            host.subprocess, "run", side_effect=timed_out
        ) as run:
            self.assertEqual(
                host._observe_mdns(),
                {"service": "_nvstream._tcp", "port": 47989},
            )
        self.assertEqual(
            run.call_args.args[0],
            [
                "/usr/bin/avahi-browse",
                "--parsable",
                "--resolve",
                "--terminate",
                "--no-db-lookup",
                "_nvstream._tcp",
            ],
        )

    def test_mdns_timeout_without_exact_owned_resolution_fails_closed(self):
        timed_out = subprocess.TimeoutExpired(
            ["/usr/bin/avahi-browse"], 10, output=b""
        )
        with mock.patch.object(
            host, "_default_interface", return_value="eth0"
        ), mock.patch.object(
            host.socket, "gethostname", return_value="runner-host"
        ), mock.patch.object(
            host.subprocess, "run", side_effect=timed_out
        ):
            with self.assertRaisesRegex(host.HostFailure, "observation is empty"):
                host._observe_mdns()

    def test_mdns_nonzero_browser_exit_has_bounded_safe_failure(self):
        completed = _Completed(returncode=2, stdout="", stderr="private stderr")
        with mock.patch.object(
            host, "_default_interface", return_value="eth0"
        ), mock.patch.object(
            host.subprocess, "run", return_value=completed
        ):
            with self.assertRaisesRegex(host.HostFailure, "mDNS browser failed") as failure:
                host._observe_mdns()
        self.assertNotIn("private", str(failure.exception))

    def test_default_interface_is_exact_single_up_default_route(self):
        with tempfile.TemporaryDirectory() as temporary:
            route = Path(temporary) / "route"
            route.write_text(
                "Iface Destination Gateway Flags RefCnt Use Metric Mask MTU Window IRTT\n"
                "eth0 00000000 010011AC 0003 0 0 100 00000000 0 0 0\n"
                "eth0 000011AC 00000000 0001 0 0 100 00FFFFFF 0 0 0\n",
                encoding="ascii",
            )
            self.assertEqual(host._default_interface(route), "eth0")
            route.write_text(
                route.read_text(encoding="ascii")
                + "eth1 00000000 010012AC 0003 0 0 100 00000000 0 0 0\n",
                encoding="ascii",
            )
            with self.assertRaises(host.HostFailure):
                host._default_interface(route)

    def test_owned_process_cleanup_is_reverse_order_and_kills_only_exact_popen_objects(self):
        cleanup = host.OwnedProcesses()
        pulse, xvfb, sunshine = _Process(101), _Process(102), _Process(103)
        cleanup.add("pulseaudio", pulse)
        cleanup.add("xvfb", xvfb)
        cleanup.add("sunshine", sunshine)
        cleanup.close()
        for process in (sunshine, xvfb, pulse):
            self.assertEqual(process.calls, ["terminate", ("wait", host.STOP_TIMEOUT_SECONDS)])

    def test_exact_owned_sunshine_group_can_stop_without_targeting_other_children(self):
        cleanup = host.OwnedProcesses()
        pulse, sunshine = _Process(101), _Process(103)
        cleanup.add("pulseaudio", pulse)
        cleanup.add("sunshine", sunshine)
        with mock.patch.object(host.os, "getpgid", return_value=103) as getpgid, \
                mock.patch.object(host.os, "killpg") as killpg:
            cleanup.stop_sunshine()
        getpgid.assert_called_once_with(103)
        killpg.assert_called_once_with(103, signal.SIGTERM)
        self.assertEqual(sunshine.calls, [("wait", host.STOP_TIMEOUT_SECONDS)])
        self.assertEqual(pulse.calls, [])
        cleanup.close()
        self.assertEqual(pulse.calls, ["terminate", ("wait", host.STOP_TIMEOUT_SECONDS)])

        for invalid_group in (102, 104):
            cleanup = host.OwnedProcesses()
            process = _Process(103)
            cleanup.add("sunshine", process)
            with mock.patch.object(host.os, "getpgid", return_value=invalid_group), \
                    mock.patch.object(host.os, "killpg") as killpg:
                with self.assertRaises(host.HostFailure):
                    cleanup.stop_sunshine()
            killpg.assert_not_called()

    def test_spawn_plan_has_no_shell_gpu_or_secret_and_uses_private_logs(self):
        with tempfile.TemporaryDirectory() as temporary:
            workspace = host.PrivateWorkspace.create(Path(temporary))
            try:
                material = workspace.write_host_material(
                    username="u", password="private-secret-value"
                )
                plans = host.process_plans(material)
                self.assertEqual([plan.name for plan in plans], ["pulseaudio", "xvfb", "sunshine"])
                joined = json.dumps([plan.argv for plan in plans])
                self.assertNotIn("secret", joined)
                self.assertNotIn("vaapi", joined.lower())
                self.assertNotIn("nvenc", joined.lower())
                self.assertEqual(plans[1].argv[:4], ("/usr/bin/Xvfb", ":99", "-screen", "0"))
                self.assertEqual(plans[2].argv, ("/usr/bin/sunshine", str(material.config)))
                for plan in plans:
                    self.assertTrue(plan.log.is_relative_to(workspace.root))
                pulse, xvfb = host._private_runtime_probe_commands(material)
                self.assertEqual(
                    pulse[1],
                    (
                        "/usr/bin/pactl",
                        "--server",
                        "unix:" + str(material.runtime / "pulse/native"),
                        "info",
                    ),
                )
                self.assertEqual(xvfb[1], ("/usr/bin/xdpyinfo", "-display", ":99"))
            finally:
                workspace.close()

    def test_private_runtime_probe_requires_actual_success_and_live_children(self):
        processes = mock.Mock()
        results = iter([_Completed(returncode=1), _Completed(returncode=0)])
        runner = mock.Mock(side_effect=lambda *_a, **_k: next(results))
        clock = iter([0.0, 0.0, 0.1])
        host._wait_private_runtime(
            "xvfb",
            ("/usr/bin/xdpyinfo", "-display", ":99"),
            {"DISPLAY": ":99"},
            processes,
            runner=runner,
            monotonic=lambda: next(clock),
            sleeper=lambda _seconds: None,
        )
        self.assertEqual(runner.call_count, 2)
        self.assertEqual(processes.require_alive.call_count, 2)

    def test_main_refuses_local_machine_without_starting_processes(self):
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch(
            "tool.f60_sunshine_owned_host.subprocess.Popen"
        ) as popen:
            self.assertEqual(host.main([]), 2)
        popen.assert_not_called()

    def test_public_readiness_never_claims_stream_acceptance(self):
        owned = object.__new__(host.OwnedSunshineHost)
        owned.processes = mock.Mock()
        owned.tls_fingerprint = "a" * 64
        owned.mdns = {"service": "_nvstream._tcp", "port": 47989}
        receipt = owned.public_readiness()
        self.assertEqual(receipt["state"], "host_ready")
        self.assertIs(receipt["streamAccepted"], False)
        self.assertNotIn("success", receipt)


if __name__ == "__main__":
    unittest.main()
