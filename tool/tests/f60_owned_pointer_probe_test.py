"""Ownership and cleanup boundaries; Linux pointer effects run in the hosted probe."""

import subprocess
import unittest
from unittest.mock import Mock, patch

from tool import f60_owned_pointer_probe as probe


class OwnedPointerProbeTest(unittest.TestCase):
    def setUp(self):
        revision = probe.source_revision(probe.ROOT)
        revision_lookup = patch.object(probe, "source_revision", return_value=revision)
        revision_lookup.start()
        self.addCleanup(revision_lookup.stop)

    def test_non_linux_never_starts_or_claims_acceptance(self):
        with patch.object(probe.platform, "system", return_value="Darwin"), \
                patch.object(probe.subprocess, "Popen") as start:
            receipt = probe.run_probe()
        start.assert_not_called()
        self.assertEqual(receipt["stage"], "preflight")
        self.assertEqual(receipt["result"], "failed")
        self.assertFalse(receipt["featureAccepted"])

    def test_existing_socket_or_lock_is_never_touched(self):
        for existing in ("/tmp/.X11-unix/X99", "/tmp/.X99-lock"):
            with self.subTest(existing=existing), \
                    patch.object(probe.platform, "system", return_value="Linux"), \
                    patch.object(probe.os.path, "lexists", side_effect=lambda p: p == existing), \
                    patch.object(probe.subprocess, "Popen") as start:
                receipt = probe.run_probe()
            start.assert_not_called()
            self.assertFalse(receipt["listenerReady"])
            self.assertFalse(receipt["pointerAndButtonObserved"])

    def test_cleanup_failure_cannot_publish_success(self):
        server = Mock()
        server.poll.return_value = None
        server.wait.side_effect = subprocess.TimeoutExpired("owned Xvfb", 5)
        witness = Mock()
        overlap = Mock()
        key = Mock()
        key.observed = True
        key._process.poll.return_value = 0
        with patch.object(probe.platform, "system", return_value="Linux"), \
                patch.object(probe.os.path, "lexists", return_value=False), \
                patch.object(probe.subprocess, "Popen", return_value=server), \
                patch.object(probe.subprocess, "run", return_value=Mock(returncode=0)), \
                patch.object(probe, "Xi2PointerWitness", return_value=overlap), \
                patch.object(probe, "Xi2KeyWitness", return_value=key), \
                patch.object(probe, "_pointer_witness_after_owned_key", return_value=witness), \
                patch.object(probe, "_type_owned_key"), \
                patch.object(probe, "_click_owned_display"):
            receipt = probe.run_probe()
        witness.close.assert_called_once()
        overlap.close.assert_called_once()
        key.close.assert_called_once()
        server.terminate.assert_called_once()
        server.kill.assert_called_once()
        self.assertEqual(receipt["result"], "failed")
        self.assertEqual(receipt["stage"], "cleanup")
        self.assertFalse(receipt["featureAccepted"])

    def test_key_listener_spawn_failure_remains_closed_and_stops_handoff(self):
        server = Mock()
        server.poll.side_effect = [None, 0]
        key = Mock()
        key.start.side_effect = probe.StreamAcceptanceFailure("owned XI2 witness could not start")
        with patch.object(probe.platform, "system", return_value="Linux"), \
                patch.object(probe.os.path, "lexists", return_value=False), \
                patch.object(probe.subprocess, "Popen", return_value=server), \
                patch.object(probe.subprocess, "run", return_value=Mock(returncode=0)), \
                patch.object(probe, "Xi2KeyWitness", return_value=key), \
                patch.object(probe, "Xi2PointerWitness") as pointer:
            receipt = probe.run_probe()
        self.assertEqual(receipt["failureCode"], "keyListenerSpawn")
        self.assertEqual(receipt["stage"], "keyListener")
        self.assertEqual(receipt["result"], "failed")
        pointer.assert_not_called()
        key.close.assert_called_once()


if __name__ == "__main__":
    unittest.main()
