import json
import os
from pathlib import Path
import stat
import struct
import tempfile
import unittest
from unittest import mock

from tool import f62_owned_microphone as pulse
from tool import f62_owned_shadow_channels as shadow


class OwnedMicrophoneTest(unittest.TestCase):
    def _record(self, root, ordinal=1, flags=3, packets=10, matched=3,
                prearm=0, errors=0, reserved=bytes(24)):
        path = Path(f"{root}/microphone.{ordinal}")
        path.write_bytes(struct.pack("<8sII6I24s", b"LRNF62M1", 1, 64,
                                    ordinal, flags, packets, matched,
                                    prearm, errors, reserved))
        path.chmod(0o600)
        return path

    def test_real_host_tone_and_disabled_successor_have_distinct_receipts(self):
        with tempfile.TemporaryDirectory() as directory:
            self._record(directory)
            self._record(directory, ordinal=2, flags=0, packets=0, matched=0)
            value = shadow.read_microphone_lifetimes(Path(directory) / "microphone")
            self.assertEqual(value["enabled"]["matchingPackets"], 3)
            self.assertEqual(value["disabled"]["packets"], 0)

    def test_pending_capture_or_submit_cannot_replace_host_received_tone(self):
        for changes in ({"flags": 0}, {"flags": 1, "matched": 0},
                        {"matched": 0}, {"prearm": 1}, {"errors": 1}):
            with self.subTest(changes=changes), tempfile.TemporaryDirectory() as directory:
                self._record(directory, **changes)
                self._record(directory, ordinal=2, flags=0, packets=0, matched=0)
                with self.assertRaises(shadow.FixtureError):
                    shadow.read_microphone_lifetimes(Path(directory) / "microphone")

    def test_disabled_successor_cannot_reuse_enabled_lifetime_or_receive_pcm(self):
        for changes in ({"flags": 1}, {"flags": 2}, {"packets": 1},
                        {"packets": 1, "matched": 1}, {"prearm": 1}, {"errors": 1}):
            with self.subTest(changes=changes), tempfile.TemporaryDirectory() as directory:
                self._record(directory)
                disabled = {"flags": 0, "packets": 0, "matched": 0, **changes}
                self._record(directory, ordinal=2, **disabled)
                with self.assertRaises(shadow.FixtureError):
                    shadow.read_microphone_lifetimes(Path(directory) / "microphone")

    def test_witness_rejects_unknown_bits_counts_reserved_and_nonprivate_files(self):
        for changes in ({"flags": 4}, {"matched": 11}, {"packets": 60001},
                        {"reserved": b"x" + bytes(23)}):
            with self.subTest(changes=changes), tempfile.TemporaryDirectory() as directory:
                path = self._record(directory, **changes)
                with self.assertRaises(shadow.FixtureError):
                    shadow.parse_microphone_witness(path)
        for mutation in ("world", "tail", "link", "hardlink"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                path = self._record(directory)
                if mutation == "world":
                    path.chmod(0o644)
                elif mutation == "tail":
                    path.write_bytes(path.read_bytes() + b"x")
                elif mutation == "link":
                    target = path.with_suffix(".target")
                    path.rename(target)
                    path.symlink_to(target)
                else:
                    os.link(path, path.with_suffix(".other"))
                with self.assertRaises(shadow.FixtureError):
                    shadow.parse_microphone_witness(path)

    def test_third_session_or_base_file_invalidates_two_lifetime_proof(self):
        for extra in ("microphone", "microphone.3"):
            with self.subTest(extra=extra), tempfile.TemporaryDirectory() as directory:
                self._record(directory)
                self._record(directory, ordinal=2, flags=0, packets=0, matched=0)
                (Path(directory) / extra).symlink_to("missing")
                with self.assertRaises(shadow.FixtureError):
                    shadow.read_microphone_lifetimes(Path(directory) / "microphone")

    def test_nonce_tone_is_nonzero_stereo_and_changes_frequency_per_nonce(self):
        first = pulse.tone_bytes("0" * 64)
        second = pulse.tone_bytes("0001" + "0" * 60)
        self.assertEqual(len(first), 44100 * 3 * 4)
        self.assertNotEqual(first, second)
        for offset in range(0, len(first), 4):
            left, right = struct.unpack_from("<hh", first, offset)
            self.assertIn(left, (-8192, 8192))
            self.assertEqual(left, right)
        for nonce in (None, True, "0" * 63, "0" * 65, "A" * 64, "0" * 64 + "\n"):
            with self.subTest(nonce_type=type(nonce).__name__), self.assertRaises(pulse.MicrophoneFixtureError):
                pulse.tone_bytes(nonce)

    def test_private_source_never_uses_inherited_hardware_or_output_feedback(self):
        with tempfile.TemporaryDirectory(prefix="larenor-mic-") as directory:
            path = Path(directory)
            path.chmod(0o700)
            with mock.patch.dict(os.environ, {"PULSE_SOURCE": "host-hardware", "PULSE_SERVER": "host"}):
                env = pulse.pulse_environment(path)
            self.assertEqual(env["PULSE_SERVER"], f"unix:{path}/native")
            self.assertEqual(env["PULSE_SOURCE"], "larenor_owned_microphone.monitor")
            self.assertEqual(env["PULSE_SINK"], "larenor_owned_output")
            path.chmod(0o755)
            with self.assertRaises(pulse.MicrophoneFixtureError):
                pulse.pulse_environment(path)

    def test_private_tone_file_cannot_overwrite_or_follow_link_and_buffer_is_wiped(self):
        with tempfile.TemporaryDirectory(prefix="larenor-mic-") as directory:
            path = Path(directory)
            path.chmod(0o700)
            data = bytearray(b"test-pcm")
            with mock.patch.object(pulse, "verified_pulse"), mock.patch.object(pulse, "tone_bytes", return_value=data), mock.patch.object(pulse.subprocess, "Popen") as process:
                pulse.start_tone(path, "0" * 64, path)
            tone = path / "owned-microphone-tone.pcm"
            self.assertEqual(tone.read_bytes(), b"test-pcm")
            self.assertEqual(stat.S_IMODE(tone.stat().st_mode), 0o600)
            self.assertEqual(data, bytes(len(data)))
            self.assertEqual(process.call_args.kwargs["env"]["PULSE_SOURCE"], "larenor_owned_microphone.monitor")
            with self.assertRaises(FileExistsError):
                pulse.private_file(tone, b"overwrite")
            link = path / "link"
            link.symlink_to(tone)
            with self.assertRaises(OSError):
                pulse.private_file(link, b"overwrite")
            self.assertEqual(tone.read_bytes(), b"test-pcm")

    def test_process_record_boolean_schema_and_changed_identity_fail_before_signals(self):
        with tempfile.TemporaryDirectory(prefix="larenor-mic-") as directory:
            path = Path(directory)
            path.chmod(0o700)
            pulse.private_file(path / "process.json", json.dumps({"schemaVersion": True, "pid": 123, "start": "456"}).encode())
            with mock.patch.object(pulse, "_process_start") as start:
                with self.assertRaises(pulse.MicrophoneFixtureError):
                    pulse.verified_pulse(path)
                start.assert_not_called()

    def test_cleanup_uses_stable_kernel_handle_and_rechecks_before_any_signal(self):
        with mock.patch.object(pulse, "verified_pulse", side_effect=[123, pulse.MicrophoneFixtureError("changed")]), mock.patch.object(pulse.os, "pidfd_open", create=True, return_value=9), mock.patch.object(pulse.signal, "pidfd_send_signal", create=True) as send, mock.patch.object(pulse.os, "close") as close:
            with self.assertRaises(pulse.MicrophoneFixtureError):
                pulse.stop(Path("/owned"))
            send.assert_not_called()
            close.assert_called_once_with(9)


if __name__ == "__main__":
    unittest.main()
