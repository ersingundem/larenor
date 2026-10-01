from __future__ import annotations

import hashlib
import io
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


class _PointerProcess:
    def __init__(self, stdout) -> None:
        self.stdout = stdout

    def poll(self):
        return 0

    def wait(self, timeout=None):
        return 0


class _Processes:
    def __init__(self) -> None:
        self.alive_checks = 0
        self.sunshine_stopped = False

    def require_alive(self) -> None:
        self.alive_checks += 1

    def stop_sunshine(self) -> None:
        self.sunshine_stopped = True


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

    def test_actual_ddmlib_aggregate_keeps_stream_identity_and_zero_skip(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._report(root)
            path = root / "TEST-owned.xml"
            child = path.read_text()
            wrapper = '<testsuites tests="1" failures="0" errors="0" skipped="0">'
            path.write_text(wrapper + child + '</testsuites>')
            self.assertEqual(1, stream.verify_report(root)["tests"])
            for body in (
                child.replace('tests="1"', 'tests="2"'),
                child.replace('skipped="0"', 'skipped="1"'),
                child + child,
                child.replace(stream.TEST_NAME, "unrelatedTest"),
                child.replace('</testcase>', '<failure/></testcase>'),
            ):
                with self.subTest(body=body):
                    path.write_text(wrapper + body + '</testsuites>')
                    with self.assertRaises(stream.StreamAcceptanceFailure):
                        stream.verify_report(root)

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

    def test_private_phase_bridge_requires_exact_touch_then_stops_owned_sunshine(self) -> None:
        class Gamepad:
            def __init__(self) -> None:
                self.armed = False
                self.observed = False
                self.disarmed = False

            def arm(self) -> None:
                self.armed = True

            def wait_effect(self) -> None:
                if not self.armed:
                    raise AssertionError("gamepad not armed")
                self.observed = True

            def disarm(self) -> None:
                self.disarmed = True

        class Witness:
            def __init__(self, _owned) -> None:
                self.started = False
                self.closed = False
                self.observed = False

            def start(self) -> None:
                self.started = True

            def wait(self, _timeout) -> None:
                if not self.started:
                    raise AssertionError("not armed")
                self.observed = True

            def close(self) -> None:
                self.closed = True

        with tempfile.TemporaryDirectory() as temporary:
            owned = _Owned(Path(temporary))
            nonce = "e" * 64
            witnesses = []
            gamepad = Gamepad()

            def witness_factory(current):
                witness = Witness(current)
                witnesses.append(witness)
                return witness

            bridge = stream.PhaseControlBridge(
                owned,
                nonce=nonce,
                paired_client_uuid=lambda: "0f5f1830-7253-4ce8-986f-0cb2c7946044",
                gamepad=gamepad,
                timeout_seconds=2,
                witness_factory=witness_factory,
            )
            bridge.start()
            with socket.create_connection(("127.0.0.1", bridge.host_port), timeout=1) as client, \
                    client.makefile("rwb", buffering=0) as control:
                for request, response in (
                    ("touch_ready", "touch_armed"),
                    ("touch_sent", "touch_observed"),
                    ("gamepad_ready", "gamepad_armed"),
                    ("gamepad_sent", "gamepad_observed"),
                    ("disconnect_ready", "owned_sunshine_stopped"),
                ):
                    control.write(stream._control_message(nonce=nonce, phase=request))
                    self.assertEqual(
                        stream._control_message(nonce=nonce, phase=response),
                        control.readline(stream.CONTROL_MESSAGE_BYTES + 1),
                    )
            bridge.wait()
            bridge.close()
            self.assertTrue(bridge.touch_observed)
            self.assertTrue(bridge.gamepad_observed)
            self.assertTrue(gamepad.observed)
            self.assertTrue(gamepad.disarmed)
            self.assertTrue(bridge.provider_pairing_present_before_disconnect)
            self.assertTrue(bridge.sunshine_stopped)
            self.assertTrue(owned.processes.sunshine_stopped)
            self.assertTrue(witnesses[0].closed)

    def test_key_witness_accepts_only_the_actual_a_press_release_after_utf8_listing(self) -> None:
        witness = stream.Xi2KeyWitness(None)
        witness._process = _PointerProcess(io.BytesIO(
            "owned device é\n".encode("utf-8")
            + b"EVENT type 2 (KeyPress)\n    detail: 38\n"
            + b"EVENT type 6 (Motion)\n    detail: 56\n"
            + b"EVENT type 3 (KeyRelease)\n    detail: 38\n"
        ))
        witness._read()
        witness.wait(1)
        self.assertTrue(witness.observed)

    def test_key_witness_rejects_stale_release_fields_and_unbounded_or_truncated_lines(self) -> None:
        for body in (
            b"EVENT type 2 (KeyPress)\n    detail: 38\n"
            b"EVENT type 3 (KeyRelease)\n    detail: 56\n"
            b"EVENT type 6 (Motion)\n    detail: 38\n",
            b"EVENT type 2 (KeyPress)\n    detail: 38\nEVENT type 3 (KeyRelease)",
            b"x" * (stream.XI2_LINE_BYTES + 1) + b"\n"
            b"EVENT type 2 (KeyPress)\n    detail: 38\n"
            b"EVENT type 3 (KeyRelease)\n    detail: 38\n",
        ):
            with self.subTest(size=len(body)):
                witness = stream.Xi2KeyWitness(None)
                witness._process = _PointerProcess(io.BytesIO(body))
                witness._read()
                self.assertFalse(witness.observed)
                with self.assertRaises(stream.StreamAcceptanceFailure):
                    witness.wait(1)

    def test_pointer_witness_requires_movement_and_primary_button_pair(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            owned = _Owned(Path(temporary))
            witness = stream.Xi2PointerWitness(owned)
            witness._collect_effects = True
            witness._process = _PointerProcess(io.BytesIO(
                b"\xffowned-device\n"
                b"EVENT type 6 (Motion)\n    root: 10.00/20.00\n"
                b"EVENT type 4 (ButtonPress)\n    detail: 1\n"
                b"EVENT type 6 (Motion)\n    root: 40.00/60.00\n"
                b"EVENT type 5 (ButtonRelease)\n    detail: 1\n"
            ))
            witness._read()
            witness.wait(1)
            self.assertTrue(witness.observed)

            incomplete = stream.Xi2PointerWitness(owned)
            incomplete._collect_effects = True
            incomplete._process = _PointerProcess(io.BytesIO(
                b"EVENT type 6 (Motion)\n    root: 10.00/20.00\n"
                b"EVENT type 4 (ButtonPress)\n    detail: 1\n"
                b"EVENT type 5 (ButtonRelease)\n    detail: 1\n"
            ))
            incomplete._read()
            with self.assertRaises(stream.StreamAcceptanceFailure):
                incomplete.wait(1)

    def test_pointer_listener_arms_only_after_its_owned_probe_is_observed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            owned = _Owned(Path(temporary))
            read_descriptor, write_descriptor = os.pipe()
            reader = os.fdopen(read_descriptor, "rb", buffering=0)
            writer = os.fdopen(write_descriptor, "wb", buffering=0)
            process = _PointerProcess(reader)
            probes = []

            def probe(x, y):
                probes.append((x, y))
                writer.write(
                    f"EVENT type 6 (Motion)\n    root: {x}.00/{y}.00\n".encode("ascii")
                )

            try:
                with mock.patch.object(stream.subprocess, "Popen", return_value=process):
                    witness = stream.Xi2PointerWitness(owned, readiness_probe=probe)
                    witness.start()
                self.assertGreaterEqual(len(probes), 1)
                self.assertFalse(witness.observed)
                writer.write(
                    b"EVENT type 6 (Motion)\n    root: 40.00/60.00\n"
                    b"EVENT type 4 (ButtonPress)\n    detail: 1\n"
                    b"EVENT type 6 (Motion)\n    root: 80.00/90.00\n"
                    b"EVENT type 5 (ButtonRelease)\n    detail: 1\n"
                )
                witness.wait(1)
            finally:
                writer.close()
                reader.close()

    def test_pointer_listener_fails_closed_when_probe_is_never_observed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            owned = _Owned(Path(temporary))
            process = _PointerProcess(io.BytesIO(b"\xffowned-device\n"))
            with mock.patch.object(stream.subprocess, "Popen", return_value=process):
                witness = stream.Xi2PointerWitness(
                    owned,
                    readiness_probe=lambda _x, _y: None,
                    readiness_timeout_seconds=0.05,
                )
                with self.assertRaisesRegex(
                    stream.StreamAcceptanceFailure, "listener is not ready"
                ):
                    witness.start()

    def test_pointer_parser_resets_on_unknown_event_and_rejects_truncation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            owned = _Owned(Path(temporary))
            stale = stream.Xi2PointerWitness(owned)
            stale._collect_effects = True
            stale._process = _PointerProcess(io.BytesIO(
                b"EVENT type 6 (Motion)\n    root: 10.00/20.00\n"
                b"EVENT type 1 (DeviceChanged)\n    root: 40.00/60.00\n"
                b"EVENT type 4 (ButtonPress)\n    detail: 1\n"
                b"EVENT type 11 (HierarchyChanged)\n    detail: 1\n"
                b"EVENT type 5 (ButtonRelease)\n    detail: 1\n"
            ))
            stale._read()
            with self.assertRaises(stream.StreamAcceptanceFailure):
                stale.wait(1)

            malformed = stream.Xi2PointerWitness(owned)
            malformed._collect_effects = True
            malformed._process = _PointerProcess(io.BytesIO(
                b"EVENT type 6 (Motion)\n    root: 10.00/20.00\n"
                b"EVENT type 4 (ButtonPress)"
            ))
            malformed._read()
            self.assertIsInstance(malformed._failure, stream.StreamAcceptanceFailure)
            with self.assertRaises(stream.StreamAcceptanceFailure):
                malformed.wait(1)

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
        stream.install_adb_reverse(
            35_002, android_port=stream.ANDROID_CONTROL_PORT, runner=run
        )
        stream.remove_adb_reverse(
            android_port=stream.ANDROID_CONTROL_PORT, runner=run
        )
        self.assertEqual(
            [
                ["adb", "reverse", "tcp:49361", "tcp:35001"],
                ["adb", "reverse", "--remove", "tcp:49361"],
                ["adb", "reverse", "tcp:49362", "tcp:35002"],
                ["adb", "reverse", "--remove", "tcp:49362"],
            ],
            calls,
        )
        for invalid in (0, 65_536):
            with self.assertRaises(stream.StreamAcceptanceFailure):
                stream.install_adb_reverse(invalid, runner=run)
        with self.assertRaises(stream.StreamAcceptanceFailure):
            stream.install_adb_reverse(35_003, android_port=49_363, runner=run)

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
            ],
            calls[0][0],
        )
        self.assertEqual(stream.PREBUILD_TIMEOUT_SECONDS, calls[0][1]["timeout"])
        self.assertNotIn("connectedDebugAndroidTest", calls[0][0])
        with self.assertRaises(stream.StreamAcceptanceFailure):
            stream.prebuild_android_test([], runner=run)

    def test_main_finishes_prebuild_before_starting_owned_provider(self) -> None:
        order = []

        class GamepadContext:
            def __enter__(self):
                order.append("gamepad-acl")
                return self

            def __exit__(self, *_args):
                return None

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
                    stream, "OwnedGamepadAccess", return_value=GamepadContext()
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
        self.assertEqual(["prebuild", "gamepad-acl", "provider"], order)

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
                mock.patch.object(stream, "OwnedGamepadAccess", return_value=_InterruptHost()), \
                mock.patch.object(stream.OwnedSunshineHost, "start", return_value=_InterruptHost()), \
                mock.patch.object(
                    stream,
                    "start_owned_visual",
                    side_effect=lambda _owned: signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None),
                ):
            with self.assertRaises(KeyboardInterrupt):
                stream.main()
        self.assertEqual([KeyboardInterrupt, KeyboardInterrupt], closed)
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
                host_proof={
                    "touchMouseEffect": True,
                    "gamepadEffect": True,
                    "providerPairingPresentBeforeDisconnect": True,
                    "ownedSunshineStopped": True,
                },
            )
            self.assertEqual(0o600, stat.S_IMODE(destination.stat().st_mode))
            raw = destination.read_text(encoding="utf-8")
            receipt = json.loads(raw)
            self.assertTrue(receipt["streamAccepted"])
            self.assertFalse(receipt["featureAccepted"])
            self.assertEqual(
                "twoStreamOscInputDisconnectAndLocalRetirement", receipt["scope"]
            )
            self.assertTrue(receipt["proof"]["renderedFrame"])
            self.assertTrue(receipt["proof"]["fullPcmWrite"])
            self.assertTrue(receipt["proof"]["softwareKeyEffect"])
            self.assertTrue(receipt["proof"]["touchMouseEffect"])
            self.assertTrue(receipt["proof"]["gamepadEffect"])
            self.assertEqual("moonlightOnScreenController", receipt["inputMode"])
            self.assertTrue(receipt["proof"]["connectionTerminated"])
            self.assertTrue(receipt["proof"]["zeroRedispatch"])
            self.assertTrue(
                receipt["proof"]["providerPairingPresentBeforeDisconnect"]
            )
            self.assertTrue(receipt["proof"]["localBindingCleared"])
            self.assertFalse(receipt["proof"]["providerPairingRemoved"])
            self.assertEqual(
                "unaccepted", receipt["limits"]["providerPairingRemoval"]
            )
            self.assertEqual("manual", receipt["limits"]["externalController"])
            self.assertEqual("manual", receipt["limits"]["controllerRumble"])
            for forbidden in ("pin", "nonce", "address", "certificate", "uuid", "password"):
                self.assertNotIn(forbidden, raw.lower())

    def test_stream_scope_never_claims_or_performs_provider_removal(self) -> None:
        source = Path(stream.__file__).read_text(encoding="utf-8")
        self.assertIn(
            "productionNsdPairCatalogTwoStreamLifetimesTouchStopDisconnectAndLocalRetirement",
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
