from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import stat
import tempfile
import threading
import unittest
from unittest import mock
import wave

from tool import f60_sunshine_android_stream as stream


class _Completed:
    def __init__(self, returncode: int = 0, stdout: str = "") -> None:
        self.returncode = returncode
        self.stdout = stdout


class _GroupProcess:
    def __init__(self, pid: int = 4501) -> None:
        self.pid = pid


class _Processes:
    def __init__(self) -> None:
        self.alive_checks = 0

    def require_alive(self) -> None:
        self.alive_checks += 1


class _Api:
    def __init__(self) -> None:
        self.approved: list[tuple[str, str, str]] = []

    def pending_pairing(self, name: str) -> str:
        if name != stream.PAIRING_CLIENT_NAME:
            raise AssertionError(name)
        return "a" * 32

    def approve_pairing(self, pairing_id: str, pin: str, name: str) -> None:
        self.approved.append((pairing_id, pin, name))

    def owned_client_uuid(self, name: str) -> str:
        if name != stream.PAIRING_CLIENT_NAME:
            raise AssertionError(name)
        return "0f5f1830-7253-4ce8-986f-0cb2c7946044"

    def require_owned_client_present(self, name: str, client_uuid: str) -> None:
        if name != stream.PAIRING_CLIENT_NAME:
            raise AssertionError(name)
        if client_uuid != "0f5f1830-7253-4ce8-986f-0cb2c7946044":
            raise AssertionError(client_uuid)


class _Owned:
    def __init__(self, root: Path) -> None:
        self.api = _Api()
        self.processes = _Processes()
        runtime = root / "runtime"
        home = root / "home"
        runtime.mkdir()
        home.mkdir()
        self.material = type("Material", (), {"runtime": runtime, "home": home, "root": root})()


class F60SunshineAndroidStreamTest(unittest.TestCase):
    def _report(self, root: Path, *, body: str = "") -> None:
        (root / "TEST-owned.xml").write_text(
            '<testsuite tests="1" failures="0" errors="0" skipped="0">'
            f'<testcase classname="{stream.TEST_CLASS}" name="{stream.TEST_NAME}">'
            f"{body}</testcase></testsuite>",
            encoding="utf-8",
        )

    def test_pin_message_is_canonical_nonce_bound_and_secret_free_on_failure(self) -> None:
        nonce = "a" * 64
        body = (
            '{"schemaVersion":1,"nonce":"' + nonce + '","pin":"1234"}\n'
        ).encode()
        self.assertEqual("1234", stream.parse_pin_message(body, expected_nonce=nonce))
        for invalid in (
            body.replace(nonce.encode(), b"b" * 64),
            b'{"nonce":"' + nonce.encode() + b'","pin":"1234","schemaVersion":1}\nextra',
            b'{"schemaVersion":1,"nonce":"' + nonce.encode() + b'","pin":"12x4"}\n',
            b'{"schemaVersion":1,"nonce":"' + nonce.encode() + b'","pin":"1234","extra":true}\n',
            b"x" * (stream.PIN_MESSAGE_BYTES + 1),
        ):
            with self.subTest(size=len(invalid)), self.assertRaises(
                stream.StreamAcceptanceFailure
            ) as failure:
                stream.parse_pin_message(invalid, expected_nonce=nonce)
            self.assertNotIn("1234", str(failure.exception))

    def test_pin_bridge_accepts_exactly_one_loopback_message_and_observes_client(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            owned = _Owned(Path(temporary))
            nonce = "c" * 64
            bridge = stream.OneShotPinBridge(owned, nonce=nonce, timeout_seconds=2)
            bridge.start()
            payload = (
                '{"schemaVersion":1,"nonce":"' + nonce + '","pin":"4821"}\n'
            ).encode()
            with socket.create_connection(("127.0.0.1", bridge.host_port), timeout=1) as client:
                client.sendall(payload)
            bridge.wait()
            bridge.close()
            self.assertTrue(bridge.pin_approved)
            self.assertTrue(bridge.paired_client_observed)
            self.assertEqual(
                "0f5f1830-7253-4ce8-986f-0cb2c7946044",
                bridge.paired_client_uuid,
            )
            self.assertEqual(
                [("a" * 32, "4821", stream.PAIRING_CLIENT_NAME)],
                owned.api.approved,
            )
            self.assertGreaterEqual(owned.processes.alive_checks, 2)
            with self.assertRaises(OSError):
                socket.create_connection(("127.0.0.1", bridge.host_port), timeout=0.1)

    def test_owned_tone_is_private_bounded_stereo_pcm(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            tone = Path(temporary) / "tone.wav"
            stream.write_owned_tone(tone)
            self.assertEqual(0o600, stat.S_IMODE(tone.stat().st_mode))
            self.assertLessEqual(tone.stat().st_size, 128 * 1024)
            with wave.open(str(tone), "rb") as wav:
                self.assertEqual(2, wav.getnchannels())
                self.assertEqual(2, wav.getsampwidth())
                self.assertEqual(48_000, wav.getframerate())
                self.assertEqual(24_000, wav.getnframes())

    def test_audio_injection_requires_exact_sunshine_sink_before_fixed_paplay(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            owned = _Owned(root)
            tone = root / "tone.wav"
            stream.write_owned_tone(tone)
            calls = []

            def run(argv, **kwargs):
                calls.append((list(argv), kwargs))
                if argv[:4] == ["/usr/bin/pactl", "list", "short", "sinks"]:
                    return _Completed(stdout="0\tsink-sunshine-stereo\tmodule-null\ts16le\tRUNNING\n")
                return _Completed()

            stream.inject_owned_tone(owned, tone, timeout_seconds=1, runner=run)
            self.assertEqual(
                ["/usr/bin/paplay", "--device=sink-sunshine-stereo", str(tone)],
                calls[-1][0],
            )
            self.assertEqual(subprocess_devnull(), calls[-1][1]["stdout"])

            with self.assertRaises(stream.StreamAcceptanceFailure):
                stream.inject_owned_tone(
                    owned,
                    tone,
                    timeout_seconds=1,
                    runner=lambda *_a, **_k: _Completed(stdout="0\tdefault\tx\tx\tRUNNING\n"),
                    monotonic=iter([0.0, 0.0, 2.0]).__next__,
                    sleeper=lambda _seconds: None,
                )

    def test_adb_reverse_uses_only_fixed_android_port_and_removes_it(self) -> None:
        calls = []

        def run(argv, **kwargs):
            calls.append(list(argv))
            return _Completed()

        stream.install_adb_reverse(35_001, runner=run)
        stream.remove_adb_reverse(runner=run)
        self.assertEqual(
            [
                ["adb", "reverse", "tcp:49361", "tcp:35001"],
                ["adb", "reverse", "--remove", "tcp:49361"],
            ],
            calls,
        )
        for invalid in (0, 65_536):
            with self.assertRaises(stream.StreamAcceptanceFailure):
                stream.install_adb_reverse(invalid, runner=run)

    def test_prebuild_materializes_both_apks_before_provider_deadlines(self) -> None:
        calls = []

        def run(argv, **kwargs):
            calls.append((list(argv), kwargs))
            return _Completed()

        stream.prebuild_android_test(["/private/launcher/gradlew"], runner=run)
        self.assertEqual(
            [
                "/private/launcher/gradlew",
                "--no-daemon",
                ":app:assembleDebug",
                ":app:assembleDebugAndroidTest",
                "-x",
                ":app:compileFlutterBuildDebug",
            ],
            calls[0][0],
        )
        self.assertEqual(stream.PREBUILD_TIMEOUT_SECONDS, calls[0][1]["timeout"])
        self.assertNotIn("connectedDebugAndroidTest", calls[0][0])
        with self.assertRaises(stream.StreamAcceptanceFailure):
            stream.prebuild_android_test([], runner=run)

    def test_main_finishes_prebuild_before_starting_owned_provider(self) -> None:
        order = []
        with tempfile.TemporaryDirectory() as temporary, \
                mock.patch.dict(os.environ, {"RUNNER_TEMP": temporary}), \
                mock.patch.object(stream, "REPORTS", Path(temporary) / "reports"), \
                mock.patch.object(stream, "emulator_version", return_value="37.1.11.0"), \
                mock.patch.object(stream, "package_identity", return_value={}), \
                mock.patch.object(stream, "materialized_gradle_command", return_value=["gradlew"]), \
                mock.patch.object(
                    stream,
                    "prebuild_android_test",
                    side_effect=lambda _gradle: order.append("prebuild"),
                ), \
                mock.patch.object(
                    stream.OwnedSunshineHost,
                    "start",
                    side_effect=lambda **_kwargs: (
                        order.append("provider"),
                        (_ for _ in ()).throw(stream.StreamAcceptanceFailure("stop")),
                    )[1],
                ):
            with self.assertRaises(stream.StreamAcceptanceFailure):
                stream.main()
        self.assertEqual(["prebuild", "provider"], order)

    def test_sigterm_unwinds_the_exact_owned_host_context(self) -> None:
        closed: list[type[BaseException] | None] = []

        class _InterruptHost:
            def __enter__(self):
                return self

            def __exit__(self, exception_type, _exception, _traceback):
                closed.append(exception_type)

            def public_readiness(self):
                return {"state": "host_ready", "streamAccepted": False}

        previous_term = signal.getsignal(signal.SIGTERM)
        previous_interrupt = signal.getsignal(signal.SIGINT)
        with tempfile.TemporaryDirectory() as temporary, \
                mock.patch.dict(os.environ, {"RUNNER_TEMP": temporary}), \
                mock.patch.object(stream, "REPORTS", Path(temporary) / "reports"), \
                mock.patch.object(stream, "emulator_version", return_value="37.1.11.0"), \
                mock.patch.object(stream, "package_identity", return_value={}), \
                mock.patch.object(stream, "materialized_gradle_command", return_value=["gradlew"]), \
                mock.patch.object(stream, "prebuild_android_test"), \
                mock.patch.object(stream.OwnedSunshineHost, "start", return_value=_InterruptHost()), \
                mock.patch.object(
                    stream,
                    "start_owned_visual",
                    side_effect=lambda _owned: signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None),
                ):
            with self.assertRaises(KeyboardInterrupt):
                stream.main()
        self.assertEqual([KeyboardInterrupt], closed)
        self.assertIs(signal.getsignal(signal.SIGTERM), previous_term)
        self.assertIs(signal.getsignal(signal.SIGINT), previous_interrupt)

    def test_xi2_cleanup_targets_the_exact_owned_process_group(self) -> None:
        process = _GroupProcess()
        with mock.patch.object(stream.os, "getpgid", return_value=process.pid) as getpgid, \
                mock.patch.object(stream.os, "killpg") as killpg:
            stream._signal_owned_process_group(process, signal.SIGTERM)
        getpgid.assert_called_once_with(process.pid)
        killpg.assert_called_once_with(process.pid, signal.SIGTERM)
        with mock.patch.object(stream.os, "getpgid", return_value=process.pid + 1), \
                mock.patch.object(stream.os, "killpg") as killpg:
            with self.assertRaises(stream.StreamAcceptanceFailure):
                stream._signal_owned_process_group(process, signal.SIGKILL)
        killpg.assert_not_called()
        for invalid in (_GroupProcess(1), object()):
            with self.assertRaises(stream.StreamAcceptanceFailure):
                stream._signal_owned_process_group(invalid, signal.SIGTERM)

    def test_report_requires_one_exact_non_skipped_named_case(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._report(root)
            self.assertEqual(1, stream.verify_report(root)["tests"])
        for body in ('<skipped message="no"/>', '<failure message="no"/>'):
            with self.subTest(body=body), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                self._report(root, body=body)
                with self.assertRaises(stream.StreamAcceptanceFailure):
                    stream.verify_report(root)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._report(root)
            (root / "extra").mkdir()
            self._report(root / "extra")
            with self.assertRaises(stream.StreamAcceptanceFailure):
                stream.verify_report(root)

    def test_receipt_is_source_bound_and_contains_only_bounded_public_proof(self) -> None:
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(
            stream, "source_revision", return_value="d" * 40,
        ):
            destination = Path(temporary) / stream.RECEIPT_NAME
            stream.write_receipt(
                destination,
                version="36.5.10.0",
                report={"className": stream.TEST_CLASS, "testName": stream.TEST_NAME,
                        "tests": 1, "failures": 0, "errors": 0, "skipped": 0},
                moonlight_package={"aarSha256": "a" * 64, "classesSha256": "b" * 64,
                                   "engineRevision": "engine", "sourceCommit": "c" * 40,
                                   "sourceTree": "e" * 40},
            )
            self.assertEqual(0o600, stat.S_IMODE(destination.stat().st_mode))
            raw = destination.read_text(encoding="utf-8")
            receipt = json.loads(raw)
            self.assertTrue(receipt["streamAccepted"])
            self.assertFalse(receipt["featureAccepted"])
            self.assertEqual("streamAndLocalRetirement", receipt["scope"])
            self.assertTrue(receipt["proof"]["renderedFrame"])
            self.assertTrue(receipt["proof"]["fullPcmWrite"])
            self.assertTrue(receipt["proof"]["softwareKeyEffect"])
            self.assertTrue(receipt["proof"]["localBindingCleared"])
            self.assertFalse(receipt["proof"]["providerPairingRemoved"])
            self.assertEqual(
                "unaccepted", receipt["limits"]["providerPairingRemoval"]
            )
            self.assertEqual("manual", receipt["limits"]["physicalController"])
            for forbidden in ("pin", "nonce", "address", "certificate", "uuid", "password"):
                self.assertNotIn(forbidden, raw.lower())

    def test_stream_scope_never_claims_or_performs_provider_removal(self) -> None:
        source = Path(stream.__file__).read_text(encoding="utf-8")
        self.assertIn(
            "productionNsdPairCatalogLaunchStreamWitnessStopAndLocalRetirement",
            source,
        )
        self.assertIn("require_owned_client_present", source)
        self.assertNotIn("unpair_owned(", source)
        self.assertNotIn("require_client_absent(", source)


def subprocess_devnull() -> int:
    import subprocess

    return subprocess.DEVNULL


if __name__ == "__main__":
    unittest.main()
