import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW_PATH = ROOT / ".github/workflows/server-test.yml"
WORKFLOW = WORKFLOW_PATH.read_text(encoding="utf-8")


def _job_condition(job_name: str) -> str:
    match = re.search(
        rf"(?ms)^  {re.escape(job_name)}:\n(?P<body>.*?)(?=^  [a-z0-9-]+:\n|\Z)",
        WORKFLOW,
    )
    if match is None:
        raise AssertionError(f"missing job: {job_name}")
    condition = re.search(r"(?m)^    if: (?P<value>.+)$", match.group("body"))
    return condition.group("value") if condition is not None else "true"


def _selected(condition: str, *, event_name: str, scope: str) -> bool:
    """Evaluate the deliberately bounded boolean grammar used by this workflow."""
    pattern = re.compile(
        r"always\(\)|true|github\.event_name|inputs\.scope|==|!=|&&|\|\||"
        r"\(|\)|'[^']*'"
    )
    tokens = pattern.findall(condition)
    if "".join(tokens) != re.sub(r"\s+", "", condition):
        raise AssertionError(f"unexpected workflow condition: {condition}")
    position = 0

    def expression() -> bool:
        nonlocal position
        value = conjunction()
        while position < len(tokens) and tokens[position] == "||":
            position += 1
            right = conjunction()
            value = value or right
        return value

    def conjunction() -> bool:
        nonlocal position
        value = primary()
        while position < len(tokens) and tokens[position] == "&&":
            position += 1
            right = primary()
            value = value and right
        return value

    def primary() -> bool:
        nonlocal position
        if position >= len(tokens):
            raise AssertionError(f"incomplete workflow condition: {condition}")
        token = tokens[position]
        if token == "(":
            position += 1
            value = expression()
            if position >= len(tokens) or tokens[position] != ")":
                raise AssertionError(f"unclosed workflow condition: {condition}")
            position += 1
            return value
        if token in {"always()", "true"}:
            position += 1
            return True
        if token not in {"github.event_name", "inputs.scope"}:
            raise AssertionError(f"unexpected workflow operand: {token}")
        left = event_name if token == "github.event_name" else scope
        if position + 2 >= len(tokens) or tokens[position + 1] not in {"==", "!="}:
            raise AssertionError(f"invalid workflow comparison: {condition}")
        operator, quoted = tokens[position + 1 : position + 3]
        if not quoted.startswith("'"):
            raise AssertionError(f"unquoted workflow comparison: {condition}")
        position += 3
        right = quoted[1:-1]
        return left == right if operator == "==" else left != right

    result = expression()
    if position != len(tokens):
        raise AssertionError(f"trailing workflow condition: {condition}")
    return result


class ServerTestWorkflowTest(unittest.TestCase):
    def test_server_shards_install_and_verify_real_paired_media_runtime(self):
        shard = WORKFLOW.split("  server-test-shard:\n", 1)[1].split(
            "\n  server-test:\n", 1
        )[0]
        self.assertIn(
            "sudo apt-get install --yes --no-install-recommends ffmpeg",
            shard,
        )
        self.assertIn("LARENOR_TEST_FFMPEG=/usr/bin/ffmpeg", shard)
        self.assertIn("LARENOR_TEST_FFPROBE=/usr/bin/ffprobe", shard)
        self.assertIn("/usr/bin/ffmpeg -hide_banner -version", shard)
        self.assertIn("/usr/bin/ffprobe -hide_banner -version", shard)
        self.assertLess(
            shard.index("Install and verify the real OCR and media runtimes"),
            shard.index("Exercise authentication, authorization"),
        )

    def test_reusable_default_scope_selects_every_required_server_gate(self):
        call_scope = re.search(
            r"(?ms)^  workflow_call:\n"
            r"    inputs:\n"
            r"      scope:\n"
            r"        description: [^\n]+\n"
            r"        required: false\n"
            r"        default: all\n"
            r"        type: string\n",
            WORKFLOW,
        )
        self.assertIsNotNone(call_scope)
        resolved_scope = "all"
        required = {
            "f08-linux-cgroup",
            "host-workers-linux",
            "server-test-shard",
            "server-test",
        }
        for job in required:
            with self.subTest(job=job):
                self.assertTrue(
                    _selected(
                        _job_condition(job),
                        event_name="workflow_dispatch",
                        scope=resolved_scope,
                    )
                )
        for job in {
            "f60-sunshine-owned-host",
            "f60-sunshine-android-discovery",
            "f60-sunshine-android-stream",
        }:
            with self.subTest(job=job):
                self.assertFalse(
                    _selected(
                        _job_condition(job),
                        event_name="workflow_dispatch",
                        scope=resolved_scope,
                    )
                )

        aggregate = WORKFLOW.split("  server-test:\n", 1)[1]
        self.assertIn(
            "needs: [server-test-shard, f08-linux-cgroup, host-workers-linux]",
            aggregate,
        )
        self.assertIn("python3 tool/required_ci_aggregate.py server", aggregate)

    def test_explicit_manual_provider_scope_remains_isolated(self):
        expected = {
            "f60-host": "f60-sunshine-owned-host",
            "f60-discovery": "f60-sunshine-android-discovery",
            "f60-stream": "f60-sunshine-android-stream",
        }
        all_jobs = {
            "f08-linux-cgroup",
            "host-workers-linux",
            "server-test-shard",
            "server-test",
            *expected.values(),
        }
        for scope, selected_job in expected.items():
            selected = {
                job
                for job in all_jobs
                if _selected(
                    _job_condition(job),
                    event_name="workflow_dispatch",
                    scope=scope,
                )
            }
            with self.subTest(scope=scope):
                self.assertEqual(selected, {selected_job})


if __name__ == "__main__":
    unittest.main()
