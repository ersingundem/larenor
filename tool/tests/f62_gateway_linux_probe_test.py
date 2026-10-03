from __future__ import annotations

import importlib.util
import hashlib
import json
from pathlib import Path
import stat
import struct
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

TOOL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOL))
spec = importlib.util.spec_from_file_location(
    "probe", TOOL / "f62_gateway_linux_probe.py"
)
assert spec and spec.loader
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class GatewayLinuxProbeTest(unittest.TestCase):
    def _link_source(self, root: Path, relative: str) -> tuple[Path, dict]:
        source = root / "source"
        path = source / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(f"line {value}" for value in range(1, 81)) + "\n")
        for directory in (source, *path.parents):
            if directory == root.parent:
                break
            directory.chmod(0o700)
            if directory == root:
                break
        path.chmod(0o600)
        return source, probe._build_archive_source_index(source)

    def test_target_negotiation_accepts_fragmented_nla_before_tls(self):
        connection = Mock()
        reply = bytes.fromhex("030000130ed000000000000200080002000000")
        connection.recv.side_effect = [bytes([value]) for value in reply]
        probe.owned.negotiate_target_nla(connection)
        connection.sendall.assert_called_once_with(
            bytes.fromhex("030000130ee000000000000100080003000000")
        )

    def test_target_negotiation_rejects_tls_fallback_and_truncated_packets(self):
        for reply in (
            bytes.fromhex("030000130ed000000000000200080001000000"),
            bytes.fromhex("030000130ed000000000000300080005000000"),
            b"\x03\x00\x00\x13\x0e",
        ):
            with self.subTest(reply=reply.hex()):
                connection = Mock()
                connection.recv.side_effect = [bytes([value]) for value in reply] + [
                    b""
                ]
                with self.assertRaises(probe.owned.FixtureError):
                    probe.owned.negotiate_target_nla(connection)

    def test_public_reviewed_source_is_copied_privately_without_allowing_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.write_bytes(b"reviewed")
            source.chmod(0o644)
            private = probe._private_source_copy(
                source, root / "copy", probe.owned.sha256(source)
            )
            self.assertEqual(private.read_bytes(), b"reviewed")
            self.assertEqual(stat.S_IMODE(private.stat().st_mode), 0o600)
            with self.assertRaises(probe.ProbeError):
                probe._private_source_copy(source, root / "drift", "0" * 64)
            self.assertFalse((root / "drift").exists())

    def test_build_configuration_disables_xinput_without_dynamic_touch_channel(self):
        arguments = probe._cmake_arguments(Path("/owned/source"), Path("/owned/build"))
        self.assertIn("-DWITH_X11=ON", arguments)
        self.assertIn("-DWITH_XI=OFF", arguments)
        self.assertIn("-DCHANNEL_DRDYNVC=OFF", arguments)
        self.assertIn("-DCHANNEL_RDPDR=ON", arguments)
        self.assertIn("-DCHANNEL_RDPDR_CLIENT=ON", arguments)
        self.assertIn("-DCHANNEL_RDPDR_SERVER=ON", arguments)
        self.assertFalse(any(value.startswith("-DCHANNEL_RDPEI") for value in arguments))

    def test_linker_diagnostic_binds_shadow_target_hash_and_owned_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, index = self._link_source(
                root, "server/shadow/shadow_owned_rdpdr.c"
            )
            unit = source / "server/shadow/shadow_owned_rdpdr.c"
            symbol = b"rdpdr_server_context_new"
            raw = (
                b"FAILED: server/shadow/cli/freerdp-shadow-cli\n"
                + str(unit).encode("ascii")
                + b":42: undefined reference to `"
                + symbol
                + b"'\n"
            )
            diagnostic = probe._linker_diagnostic(
                raw, source=source, source_index=index
            )
            self.assertEqual(diagnostic[0:2], ("shadowCli", 1))
            self.assertEqual(
                diagnostic[2],
                [{
                    "symbolSha256": hashlib.sha256(symbol).hexdigest(),
                    "symbolClass": "ownedRdpdrApi",
                }],
            )
            self.assertEqual(diagnostic[3], "ownedRdpdr")
            self.assertEqual(diagnostic[4], 42)
            self.assertEqual(diagnostic[5], index[diagnostic[6]][0])

    def test_linker_diagnostic_classifies_reviewed_x11_and_crypto_hashes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, index = self._link_source(root, "client/X11/xf_client.c")
            raw = b"FAILED: client/X11/xfreerdp\n" + b"\n".join(
                b"undefined reference to `" + symbol + b"'"
                for symbol in (
                    b"XOpenDisplay", b"SSL_new", b"unknown_external",
                    b"XCloseDisplay", b"XCreateWindow",
                )
            ) + b"\n"
            diagnostic = probe._linker_diagnostic(
                raw, source=source, source_index=index
            )
            self.assertEqual(diagnostic[0], "xFreeRdp")
            self.assertEqual(diagnostic[1], 5)
            self.assertEqual(len(diagnostic[2]), 4)
            self.assertEqual(
                [item["symbolClass"] for item in diagnostic[2]],
                ["x11External", "cryptoExternal", "other", "x11External"],
            )
            self.assertEqual(diagnostic[3:], (None, None, None, None))

    def test_linker_diagnostic_accepts_real_gnu_ld_archive_and_object_prefixes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, index = self._link_source(root, "client/X11/xf_client.c")
            cases = (
                (
                    b"/usr/bin/ld: ../libfreerdp-server3.a("
                    b"shadow_owned_rdpdr.c.o):(.text+0x1a): "
                    b"undefined reference to `rdpdr_server_context_free'",
                    "ownedRdpdrApi",
                ),
                (
                    b"CMakeFiles/xfreerdp.dir/xf_client.c.o: "
                    b"undefined reference to `XOpenDisplay'",
                    "x11External",
                ),
            )
            for record, expected_class in cases:
                with self.subTest(record=record):
                    diagnostic = probe._linker_diagnostic(
                        b"FAILED: client/X11/xfreerdp\n" + record + b"\n",
                        source=source,
                        source_index=index,
                    )
                    self.assertEqual(diagnostic[0:2], ("xFreeRdp", 1))
                    self.assertEqual(
                        diagnostic[2][0]["symbolClass"], expected_class
                    )
                    self.assertEqual(diagnostic[3:], (None, None, None, None))

    def test_gnu_ld_source_section_keeps_exact_indexed_origin(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, index = self._link_source(
                root, "server/shadow/shadow_owned_rdpdr.c"
            )
            unit = source / "server/shadow/shadow_owned_rdpdr.c"
            raw = (
                b"FAILED: server/shadow/cli/freerdp-shadow-cli\n/usr/bin/ld: "
                + str(unit).encode("ascii")
                + b":31:(.text+0x2f): undefined reference to "
                b"`rdpdr_server_context_new'\n"
            )
            diagnostic = probe._linker_diagnostic(
                raw, source=source, source_index=index
            )
            self.assertEqual(diagnostic[3], "ownedRdpdr")
            self.assertEqual(diagnostic[4], 31)
            self.assertEqual(diagnostic[5], index[diagnostic[6]][0])

    def test_same_failed_line_requires_every_output_to_be_reviewed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, index = self._link_source(root, "client/X11/xf_client.c")
            record = b"undefined reference to `XOpenDisplay'\n"
            multiple = probe._linker_diagnostic(
                b"FAILED: server/shadow/cli/freerdp-shadow-cli "
                b"client/X11/xfreerdp\n" + record,
                source=source,
                source_index=index,
            )
            self.assertEqual(multiple[0], "multiple")
            unknown = probe._linker_diagnostic(
                b"FAILED: client/X11/xfreerdp unreviewed/link-output\n" + record,
                source=source,
                source_index=index,
            )
            self.assertEqual(
                unknown, ("unknown", None, [], None, None, None, None)
            )

    def test_linker_diagnostic_reports_multiple_targets_without_raw_identifiers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, index = self._link_source(root, "client/X11/xf_client.c")
            raw = (
                b"FAILED: server/shadow/cli/freerdp-shadow-cli\n"
                b"FAILED: client/X11/xfreerdp\n"
                b"undefined reference to `XMapWindow'\n"
            )
            diagnostic = probe._linker_diagnostic(
                raw, source=source, source_index=index
            )
            self.assertEqual(diagnostic[0], "multiple")
            encoded = json.dumps(diagnostic)
            self.assertNotIn("XMapWindow", encoded)
            self.assertNotIn(str(source), encoded)

    def test_malformed_truncated_or_unreviewed_target_stays_unknown(self):
        samples = (
            b"FAILED: client/X11/xfreerdp\nundefined reference to `unterminated\n",
            b"FAILED: unknown/target\nundefined reference to `SSL_new'\n",
            b"FAILED:\nundefined reference to `SSL_new'\n",
            b"FAILED: client/X11/xfreerdp\n"
            b"unit.o:(.text+0xZZ): undefined reference to `SSL_new'\n",
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, index = self._link_source(root, "client/X11/xf_client.c")
            for raw in samples:
                with self.subTest(raw=raw):
                    self.assertEqual(
                        probe._linker_diagnostic(
                            raw, source=source, source_index=index
                        ),
                        ("unknown", None, [], None, None, None, None),
                    )

    def test_link_origin_is_withheld_after_source_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, index = self._link_source(root, "client/X11/xf_client.c")
            unit = source / "client/X11/xf_client.c"
            unit.write_text(unit.read_text() + "drift\n")
            raw = (
                b"FAILED: client/X11/xfreerdp\n"
                + str(unit).encode("ascii")
                + b":12: undefined reference to `XOpenDisplay'\n"
            )
            diagnostic = probe._linker_diagnostic(
                raw, source=source, source_index=index
            )
            self.assertEqual(diagnostic[0:2], ("xFreeRdp", 1))
            self.assertEqual(diagnostic[3:], (None, None, None, None))

    def test_linker_build_writes_closed_private_nonaccepting_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            root.chmod(0o700)
            source, index = self._link_source(
                root, "server/shadow/shadow_owned_rdpdr.c"
            )
            unit = source / "server/shadow/shadow_owned_rdpdr.c"
            symbol = b"rdpdr_server_context_free"
            raw = (
                b"FAILED: server/shadow/cli/freerdp-shadow-cli\n"
                + str(unit).encode("ascii")
                + b":17: undefined reference to `"
                + symbol
                + b"'\n"
            )

            def fake_run(_argv, **kwargs):
                kwargs["stdout"].write(raw)
                kwargs["stdout"].flush()
                return SimpleNamespace(returncode=1)

            receipt = root / "failure.json"
            with (
                patch.object(probe.subprocess, "run", side_effect=fake_run),
                patch.object(probe, "source_revision", return_value="1" * 40),
                self.assertRaisesRegex(probe.ProbeError, "freerdpBuildFailed"),
            ):
                probe._run_build(
                    ["/usr/bin/false"], cwd=root, log=root / "build.log",
                    timeout=10, phase="compile", failure_receipt=receipt,
                    compiler_source=source, compiler_index=index,
                )
            value = json.loads(receipt.read_text())
            self.assertEqual(set(value), probe.BUILD_FAILURE_RECEIPT_KEYS)
            self.assertEqual(value["schemaVersion"], 4)
            self.assertEqual(value["failureCode"], "linkerError")
            self.assertEqual(value["compilerErrorClass"], "linkUndefined")
            self.assertEqual(value["linkTarget"], "shadowCli")
            self.assertEqual(value["linkUndefinedCount"], 1)
            self.assertEqual(value["linkUndefined"][0]["symbolClass"], "ownedRdpdrApi")
            self.assertFalse(value["featureAccepted"])
            self.assertEqual(stat.S_IMODE(receipt.stat().st_mode), 0o600)
            encoded = receipt.read_text()
            self.assertNotIn(symbol.decode("ascii"), encoded)
            self.assertNotIn(str(source), encoded)

    def test_unknown_linker_shape_preserves_primary_failure_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            root.chmod(0o700)
            source, index = self._link_source(root, "client/X11/xf_client.c")
            raw = (
                b"FAILED: client/X11/xfreerdp\n"
                b"undefined reference to `truncated\n"
            )

            def fake_run(_argv, **kwargs):
                kwargs["stdout"].write(raw)
                kwargs["stdout"].flush()
                return SimpleNamespace(returncode=1)

            receipt = root / "failure.json"
            with (
                patch.object(probe.subprocess, "run", side_effect=fake_run),
                patch.object(probe, "source_revision", return_value="2" * 40),
                self.assertRaises(probe.ProbeError),
            ):
                probe._run_build(
                    ["/usr/bin/false"], cwd=root, log=root / "build.log",
                    timeout=10, phase="compile", failure_receipt=receipt,
                    compiler_source=source, compiler_index=index,
                )
            value = json.loads(receipt.read_text())
            self.assertEqual(value["failureCode"], "linkerError")
            self.assertEqual(value["linkTarget"], "unknown")
            self.assertIsNone(value["linkUndefinedCount"])
            self.assertEqual(value["linkUndefined"], [])
            self.assertFalse(value["featureAccepted"])

    def test_source_binding_uses_v2_mirror_patch(self):
        patch = TOOL / "patches/f62-owned-shadow-rdpdr.patch"
        manifest = TOOL / "manifests/f62-owned-shadow-rdpdr-source.json"
        self.assertEqual(probe.owned.sha256(patch), probe.TARGET_PATCH_SHA256)
        self.assertEqual(probe.owned.sha256(manifest), probe.TARGET_MANIFEST_SHA256)
        value = json.loads(manifest.read_text())
        self.assertEqual(value["patchSha256"], probe.TARGET_PATCH_SHA256)
        text = patch.read_text()
        self.assertIn(r'"\\ToRemote\\upload-%.16s.bin"', text)
        self.assertIn(r'"\\FromRemote\\outbound-%.16s.bin"', text)
        self.assertNotIn(r'"\\upload-%.16s.bin"', text)
        self.assertNotIn(r'"\\outbound-%.16s.bin"', text)

    def test_payload_and_private_mirror_contract(self):
        nonce = "a" * 64
        self.assertEqual(len((probe.UPLOAD_PREFIX + nonce).encode("ascii")), 91)
        self.assertEqual(len((probe.OUTBOUND_PREFIX + nonce).encode("ascii")), 93)
        source = (TOOL / "f62_gateway_linux_probe.py").read_text()
        for exact in (
            'to_remote = mirror / "ToRemote"',
            'from_remote = mirror / "FromRemote"',
            "upload_path = to_remote / upload_name",
            "watcher = CloseWriteWatcher(from_remote, outbound_name)",
            "outbound_path = from_remote / outbound_name",
        ):
            self.assertIn(exact, source)

    def test_client_secrets_are_only_written_to_an_inherited_argument_fd(self):
        source = (TOOL / "f62_gateway_linux_probe.py").read_text()
        self.assertIn('f"/args-from:fd:{read_fd}"', source)
        self.assertIn("pass_fds=(read_fd,)", source)
        self.assertIn('f"/p:{target_password}"', source)
        self.assertIn("p:{gateway_password}", source)
        popen = source[
            source.index("self.proc = subprocess.Popen(") : source.index(
                "self.pid = self.proc.pid"
            )
        ]
        self.assertNotIn("arguments", popen)
        self.assertNotIn("password", popen.lower())
        client_args = source[
            source.index("client_args = [") : source.index(
                "client_env =", source.index("client_args = [")
            )
        ]
        self.assertNotIn('"xfreerdp",', client_args)
        self.assertIn("usage-method:direct,type:http,no-websockets", client_args)
        self.assertNotIn("/cert:ignore", source)
        self.assertIn('return "sha256:" + value', source)

    def test_effect_precedes_client_close_and_publication_follows_cleanup(self):
        source = (TOOL / "f62_gateway_linux_probe.py").read_text()
        body = source[
            source.index("def run_probe(") : source.index("\ndef self_test()")
        ]
        self.assertLess(
            body.index("watcher.wait("), body.index("client.stop_after_effect()")
        )
        self.assertLess(
            body.index("client.stop_after_effect()"),
            body.index("_validate_target_witness"),
        )
        self.assertLess(
            body.index("finally:"), body.index("_write_cleanup_receipt(out, public)")
        )
        self.assertIn('owned._journal_process(state, "client", client, journal)', body)
        self.assertIn('owned._journal_process(state, "xvfb", xvfb, journal)', body)

    def test_public_receipt_is_closed_and_explicitly_non_accepting(self):
        values = {
            "runnerSourceRevision": "1" * 40,
            "schemaVersion": 1,
            "scope": "ownedLinuxRdGatewayRdpdrProbe",
            "sourceRevision": probe.FREERDP_REVISION,
            "sourceArchiveSha256": probe.FREERDP_ARCHIVE_SHA256,
            "targetPatchSha256": probe.TARGET_PATCH_SHA256,
            "sourceManifestSha256": probe.TARGET_MANIFEST_SHA256,
            "rdpgwRevision": probe.owned.REVISION,
            "rdpgwArchiveSha256": probe.owned.ARCHIVE_SHA,
            "shadowBinarySha256": "1" * 64,
            "xfreerdpBinarySha256": "2" * 64,
            "gatewayBinarySha256": "3" * 64,
            "authBinarySha256": "4" * 64,
            "gatewayAuthObserved": True,
            "gatewayPinMatched": True,
            "targetPinMatched": True,
            "configuredTargetExact": True,
            "directTargetBlocked": True,
            "targetConnectedThroughGateway": True,
            "rdpdrUploadMatched": True,
            "rdpdrDownloadMatched": True,
            "targetCleanClose": True,
            "singleAuthenticatedSession": True,
            "cleanupComplete": True,
            "androidProductExercised": False,
            "runtimeAccepted": False,
            "featureAccepted": False,
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            root.chmod(0o700)
            out = root / "receipt.json"
            probe._write_cleanup_receipt(out, values)
            self.assertEqual(json.loads(out.read_text()), values)
            self.assertEqual(stat.S_IMODE(out.stat().st_mode), 0o600)
            self.assertFalse(
                set(values)
                & {"nonce", "gatewayPassword", "targetPassword", "targetHost", "mirror"}
            )
            rejected = dict(values)
            rejected["runtimeAccepted"] = True
            with self.assertRaises(probe.ProbeError):
                probe._write_cleanup_receipt(root / "bad.json", rejected)

    def test_synthetic_target_binary_requires_both_mirror_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "shadow"
            raw = bytearray(64)
            raw[:6] = b"\x7fELF\x02\x01"
            struct.pack_into("<HH", raw, 16, 3, 62)
            raw.extend(b"\0".join(probe.target_package.REQUIRED_BINARY_MARKERS))
            binary.write_bytes(raw)
            binary.chmod(0o700)
            probe.target_package.verify_elf(binary)
            binary.write_bytes(
                raw.replace(b"\\\\FromRemote\\\\outbound-", b"wrong-path-marker_______")
            )
            binary.chmod(0o700)
            with self.assertRaises(probe.target_package.PackageError):
                probe.target_package.verify_elf(binary)

    def test_cleanup_fallback_is_idempotent_by_exact_owned_identity(self):
        source = (TOOL / "f62_rdpgw_owned_fixture.py").read_text()
        body = source[
            source.index("def cleanup_state(") : source.index("\ndef cleanup_command")
        ]
        self.assertIn('current != process["start"]', body)
        self.assertIn('"/usr/sbin/iptables", "-C"', body)
        self.assertIn('["/usr/sbin/ip", "link", "show", "dev"', body)
        self.assertIn('["/usr/sbin/ip", "netns", "list"]', body)
        self.assertIn(
            'process["kind"] not in ("xvfb", "target", "auth", "gateway", "client")',
            source,
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
