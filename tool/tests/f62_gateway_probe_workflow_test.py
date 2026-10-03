from __future__ import annotations

from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/server-test.yml"


class GatewayProbeWorkflowTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.raw = WORKFLOW.read_text()
        start = cls.raw.index("  f62-gateway-linux-probe:")
        end = cls.raw.index("\n  f60-owned-input-probe:", start)
        cls.job = cls.raw[start:end]

    def test_scope_is_explicit_manual_only_and_bounded(self):
        self.assertIn("          - f62-gateway-probe", self.raw)
        self.assertIn(
            "if: github.event_name == 'workflow_dispatch' && inputs.scope == 'f62-gateway-probe'",
            self.job,
        )
        self.assertIn("timeout-minutes: 15", self.job)
        self.assertNotIn(
            "f62-gateway-linux-probe", self.raw[self.raw.index("  server-test:") :]
        )

    def test_checkout_and_owned_runner_identity_are_exact(self):
        self.assertIn(
            "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1", self.job
        )
        self.assertIn("persist-credentials: false", self.job)
        self.assertIn('test "$RUNNER_ENVIRONMENT" = github-hosted', self.job)
        self.assertIn('test "$(git rev-parse HEAD)" = "$GITHUB_SHA"', self.job)
        self.assertIn(
            "refs/heads/main|refs/heads/codex/project-completion-100", self.job
        )

    def test_archives_and_toolchain_are_hash_pinned_without_cache(self):
        for digest in (
            "2852af0cb20a13139b3448992e69b868e50ed0f8a1e5940ee1de9e19a123b613",
            "4a2629026896cb4e26fb8ed2d6ca6aa4ab89ca95528dfbae2550c2f6bc866991",
            "b96e24cddfdf4b6eee939dc1558734f29534c7e0ebae650858c8ba715a166907",
        ):
            self.assertIn(digest, self.job)
        self.assertIn("go version go1.25.0 linux/amd64", self.job)
        self.assertIn("sha256sum --check --strict", self.job)
        self.assertNotIn("actions/cache", self.job)
        self.assertNotIn("setup-go", self.job)

    def test_real_build_and_probe_commands_are_used(self):
        self.assertIn("tool/f62_rdpgw_owned_fixture.py build", self.job)
        self.assertIn("tool/f62_gateway_linux_probe.py build-freerdp", self.job)
        self.assertIn("tool/f62_gateway_linux_probe.py run", self.job)
        self.assertIn("cmake", self.job)
        self.assertIn("ninja-build", self.job)
        self.assertIn("xvfb", self.job)
        self.assertIn("iptables", self.job)
        self.assertIn("LARENOR_F62_OWNED_RDGW: required", self.job)

    def test_cleanup_runs_always_and_only_closed_receipt_is_uploaded(self):
        self.assertIn("if: always()", self.job)
        self.assertIn("tool/f62_rdpgw_owned_fixture.py cleanup", self.job)
        self.assertIn("rm -rf --one-file-system", self.job)
        self.assertIn("if: success()", self.job)
        self.assertIn("f62-gateway-probe-receipt.json", self.job)
        self.assertNotIn(
            "configure.log", self.job[self.job.index("Preserve only the closed") :]
        )
        self.assertNotIn(
            "compile.log", self.job[self.job.index("Preserve only the closed") :]
        )

    def test_dependency_installation_uses_resolved_exact_candidates(self):
        self.assertIn("apt-cache policy", self.job)
        self.assertIn('"$package=$candidate"', self.job)
        self.assertIn("dpkg-query --show", self.job)
        self.assertIn("--no-install-recommends", self.job)


if __name__ == "__main__":
    unittest.main(verbosity=2)
