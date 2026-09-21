"""Required checks must ignore only superseded cancellation, never failures."""

import json
import sys
import tempfile
import unittest
from io import BytesIO
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from required_ci_aggregate import current_pr_head, decide

OLD = "a" * 40
NEW = "b" * 40


class _Response:
    status = 200

    def __init__(self, body):
        self._body = BytesIO(json.dumps(body).encode())

    def __enter__(self):
        return self

    def __exit__(self, *_):
        pass

    def read(self, count):
        return self._body.read(count)


class RequiredCiAggregateTest(unittest.TestCase):
    def test_success_and_reused_native_scope_need_no_network(self):
        def forbidden():
            self.fail("successful checks must not query the API")

        self.assertTrue(decide("server", {"SHARD_RESULT": "success"}, forbidden))
        self.assertTrue(decide("flutter", {
            "STATIC_RESULT": "success", "TEST_RESULT": "success"}, forbidden))
        self.assertTrue(decide("native", {
            "SCOPE_RESULT": "success", "RUN_NATIVE": "false",
            "MATRIX_RESULT": "skipped"}, forbidden))

    def test_real_failure_and_unexpected_skip_remain_blocking_after_head_drift(self):
        def forbidden():
            self.fail("real failure must not be masked by a newer PR head")

        for kind, statuses in (
            ("server", {"SHARD_RESULT": "failure"}),
            ("flutter", {"STATIC_RESULT": "failure", "TEST_RESULT": "cancelled"}),
            ("native", {"SCOPE_RESULT": "success", "RUN_NATIVE": "true",
                        "MATRIX_RESULT": "failure"}),
            ("native", {"SCOPE_RESULT": "success", "RUN_NATIVE": "true",
                        "MATRIX_RESULT": "skipped"}),
            ("flutter", {"STATIC_RESULT": "success", "TEST_RESULT": "skipped"}),
            ("flutter", {"STATIC_RESULT": "skipped", "TEST_RESULT": "cancelled"}),
            ("native", {"SCOPE_RESULT": "skipped", "RUN_NATIVE": "",
                        "MATRIX_RESULT": "cancelled"}),
        ):
            with self.subTest(kind=kind, statuses=statuses):
                self.assertFalse(decide(kind, statuses, forbidden))

    def test_only_cancelled_superseded_runs_avoid_false_failure(self):
        cancelled = (
            ("server", {"SHARD_RESULT": "cancelled"}),
            ("flutter", {"STATIC_RESULT": "cancelled", "TEST_RESULT": "success"}),
            ("native", {"SCOPE_RESULT": "cancelled", "RUN_NATIVE": "",
                        "MATRIX_RESULT": "cancelled"}),
        )
        for kind, statuses in cancelled:
            with self.subTest(kind=kind):
                self.assertTrue(decide(kind, statuses, lambda: True))
                self.assertFalse(decide(kind, statuses, lambda: False))
                self.assertFalse(decide(kind, statuses,
                                        lambda: (_ for _ in ()).throw(OSError())))

    def test_exact_pr_head_query_is_bounded_and_fail_closed(self):
        with tempfile.TemporaryDirectory() as root:
            event = Path(root) / "event.json"
            event.write_text(json.dumps({"number": 12, "pull_request": {
                "head": {"sha": OLD},
                "base": {"repo": {"full_name": "ersingundem/larenor"}},
            }}))
            env = {
                "GITHUB_EVENT_NAME": "pull_request",
                "GITHUB_EVENT_PATH": str(event),
                "GITHUB_REPOSITORY": "ersingundem/larenor",
                "GITHUB_TOKEN": "synthetic-token",
            }

            def changed(request, timeout):
                self.assertEqual(timeout, 5)
                self.assertEqual(request.full_url,
                                 "https://api.github.com/repos/ersingundem/larenor/pulls/12")
                return _Response({"number": 12, "head": {"sha": NEW}})

            self.assertEqual(current_pr_head(env, changed), (OLD, NEW))
            self.assertEqual(current_pr_head(env, lambda *_: _Response({
                "number": 13, "head": {"sha": NEW}})), None)
            self.assertEqual(current_pr_head(env, lambda *_: (_ for _ in ())
                                            .throw(OSError())), None)
            env["GITHUB_EVENT_NAME"] = "workflow_dispatch"
            self.assertEqual(current_pr_head(env, changed), None)
            env["GITHUB_EVENT_NAME"] = "pull_request"
            event.write_text("{" + "x" * (1024 * 1024))
            self.assertEqual(current_pr_head(env, changed), None)


if __name__ == "__main__":
    unittest.main()
