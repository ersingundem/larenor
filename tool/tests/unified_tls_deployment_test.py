import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
OVERLAY = ROOT / "deploy/larenor-server/unified.tls.compose.yaml"


class UnifiedTlsDeploymentTest(unittest.TestCase):
    def test_overlay_uses_fixed_private_mount_and_paired_cli_arguments(self):
        document = json.loads(OVERLAY.read_text())
        self.assertEqual(set(document), {"services"})
        self.assertEqual(set(document["services"]), {"larenor-core"})
        core = document["services"]["larenor-core"]
        self.assertEqual(core["command"], [
            "--host", "0.0.0.0", "--port", "8098",
            "--tls-cert", "/tls/server.pem",
            "--tls-key", "/tls/server.key",
        ])
        self.assertEqual(core["volumes"], [{
            "type": "bind",
            "source": "/var/lib/larenor-server/core/tls",
            "target": "/tls",
            "read_only": True,
            "bind": {"create_host_path": False},
        }])
        encoded = json.dumps(document)
        self.assertNotIn("CERT", encoded.upper().replace("TLS-CERT", ""))
        self.assertNotIn("PASSWORD", encoded.upper())

    def test_health_probe_is_tls_and_pins_the_mounted_certificate(self):
        core = json.loads(OVERLAY.read_text())["services"]["larenor-core"]
        health = core["healthcheck"]
        self.assertEqual(health["test"][:2], ["CMD", "/opt/larenor/.venv/bin/python"])
        script = health["test"][3]
        self.assertIn("https://127.0.0.1:8098/api/v1/health", script)
        self.assertIn("cafile='/tls/server.pem'", script)
        self.assertIn("VERIFY_X509_PARTIAL_CHAIN", script)
        self.assertNotIn("_create_unverified_context", script)
        self.assertNotIn("CERT_NONE", script)


if __name__ == "__main__":
    unittest.main()
