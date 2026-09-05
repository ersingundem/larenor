"""Synthetic GitHub storage snapshots; never contact GitHub or delete artifacts."""

import copy
from datetime import datetime, timedelta, timezone
import io
import json
import os
import time
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from github_storage_cleanup import (
    ARTIFACTS_PATH, PACKAGE_PATH, REPOSITORY, WORKFLOW_PATH,
    CleanupError, GitHub, _run_gh, cleanup, main,
)


NOW = datetime(2026, 9, 5, 12, tzinfo=timezone.utc)
REPO_ID = 1351560782


def artifact(identifier, *, name="app-debug-apk", days=1, expired=False, size=100):
    created = NOW - timedelta(days=days, seconds=identifier)
    return {"id": identifier, "name": name, "size_in_bytes": size,
            "created_at": created.isoformat().replace("+00:00", "Z"),
            "updated_at": created.isoformat().replace("+00:00", "Z"),
            "expires_at": (NOW + timedelta(days=1)).isoformat().replace("+00:00", "Z"),
            "expired": expired, "digest": "sha256:" + "a" * 64,
            "workflow_run": {"id": 1000 + identifier, "repository_id": REPO_ID,
                             "head_repository_id": REPO_ID, "head_sha": "b" * 40}}


class FakeGitHub:
    def __init__(self, artifacts=None, versions=None):
        self.artifacts = copy.deepcopy(artifacts or [])
        self.versions = copy.deepcopy(versions or [])
        self.calls = []
        self.run_overrides = {}
        self.before_request = None
        self.package_error = None
        self.delete_error = None

    def request(self, path, *, method="GET"):
        self.calls.append((method, path))
        if self.before_request:
            result = self.before_request(self, path, method)
            if result is not None:
                return result
        if path == "repos/" + REPOSITORY:
            return {"id": REPO_ID, "full_name": REPOSITORY}
        if path.startswith(ARTIFACTS_PATH + "?"):
            page = int(path.split("page=")[-1])
            return {"total_count": len(self.artifacts), "artifacts": copy.deepcopy(self.artifacts[(page - 1) * 100:page * 100])}
        if path.startswith(PACKAGE_PATH + "?"):
            if self.package_error:
                raise CleanupError(self.package_error)
            page = int(path.split("page=")[-1])
            return copy.deepcopy(self.versions[(page - 1) * 100:page * 100])
        if path.startswith(ARTIFACTS_PATH + "/"):
            identifier = int(path.rsplit("/", 1)[1])
            found = next((value for value in self.artifacts if value["id"] == identifier), None)
            if found is None:
                raise CleanupError("github_not_found")
            if method == "DELETE":
                if self.delete_error:
                    raise CleanupError(self.delete_error, outcome_unknown=True)
                self.artifacts.remove(found)
                return None
            return copy.deepcopy(found)
        if "/actions/runs/" in path:
            identifier = int(path.rsplit("/", 1)[1])
            return {"id": identifier, "status": "completed", "path": WORKFLOW_PATH,
                    "repository": {"id": REPO_ID, "full_name": REPOSITORY},
                    **self.run_overrides.get(identifier, {})}
        raise AssertionError(path)

    @property
    def deletes(self):
        return [path for method, path in self.calls if method == "DELETE"]


class GitHubStorageCleanupTest(unittest.TestCase):
    def test_default_dry_run_preserves_newest_three_and_all_unknown_outputs(self):
        values = [artifact(i) for i in range(1, 9)] + [
            artifact(20, name="app-signed-release-apk-63"),
            artifact(21, name="test-evidence"), artifact(22, name="app-debug.apk"),
            artifact(23, name="app-debug-apk-custom")]
        api = FakeGitHub(values)
        report = cleanup(api, now=NOW)
        self.assertEqual(report["mode"], "dry_run")
        self.assertEqual([row["id"] for row in report["artifacts"]["candidates"]], [8, 7, 6, 5, 4])
        self.assertEqual(report["artifacts"]["candidateBytes"], 500)
        self.assertEqual(report["artifacts"]["protectedNewestIds"], [1, 2, 3])
        self.assertEqual(report["artifacts"]["deletedBytes"], 0)
        self.assertEqual(api.deletes, [])

    def test_apply_rechecks_and_deletes_only_reviewed_debug_artifacts(self):
        api = FakeGitHub([artifact(i) for i in range(1, 6)])
        report = cleanup(api, now=NOW, apply=True)
        self.assertEqual(report["artifacts"]["deletedIds"], [5, 4])
        self.assertEqual(report["artifacts"]["deletedBytes"], 200)
        self.assertEqual({value["id"] for value in api.artifacts}, {1, 2, 3})
        for path in api.deletes:
            index = api.calls.index(("DELETE", path))
            self.assertIn(("GET", path), api.calls[:index])
            run_id = 1000 + int(path.rsplit("/", 1)[1])
            self.assertEqual(api.calls[index - 1], ("GET", f"repos/{REPOSITORY}/actions/runs/{run_id}"))
        self.assertFalse(any("packages" in path for path in api.deletes))

    def test_complete_pagination_is_used_before_retention(self):
        values = [artifact(i, name="test-evidence") for i in range(100, 201)]
        values += [artifact(i) for i in range(1, 6)]
        report = cleanup(FakeGitHub(values), now=NOW)
        self.assertEqual(report["artifacts"]["observedCount"], 106)
        self.assertEqual([row["id"] for row in report["artifacts"]["candidates"]], [5, 4])

    def test_changing_or_duplicate_pagination_blocks_deletion(self):
        for defect in ("total", "duplicate", "short", "limit"):
            with self.subTest(defect=defect):
                api = FakeGitHub([artifact(i) for i in range(1, 106)])
                def change(api, path, method):
                    if path == ARTIFACTS_PATH + "?per_page=100&page=2":
                        if defect == "total": return {"total_count": 106, "artifacts": api.artifacts[100:]}
                        if defect == "duplicate": return {"total_count": 105, "artifacts": api.artifacts[:5]}
                        if defect == "short": return {"total_count": 105, "artifacts": []}
                    if defect == "limit" and path.startswith(ARTIFACTS_PATH + "?"):
                        return {"total_count": 2001, "artifacts": api.artifacts[:100]}
                api.before_request = change
                report = cleanup(api, now=NOW, apply=True)
                self.assertEqual(report["artifacts"]["status"], "blocked")
                self.assertEqual(api.deletes, [])

    def test_running_expired_unknown_workflow_and_wrong_repo_are_not_deleted(self):
        api = FakeGitHub([artifact(i) for i in range(1, 8)] + [artifact(8, expired=True)])
        api.run_overrides = {1004: {"status": "in_progress"}, 1005: {"path": ".github/workflows/release.yml"},
                             1006: {"repository": {"id": 999, "full_name": "another/repo"}}}
        report = cleanup(api, now=NOW, apply=True)
        self.assertEqual(report["artifacts"]["status"], "blocked")
        self.assertEqual(api.deletes, [])

    def test_in_progress_and_other_workflows_are_preserved_without_global_failure(self):
        api = FakeGitHub([artifact(i) for i in range(1, 7)] + [artifact(8, expired=True)])
        api.run_overrides = {1004: {"status": "in_progress"}, 1005: {"path": ".github/workflows/release.yml"}}
        report = cleanup(api, now=NOW, apply=True)
        self.assertEqual(report["artifacts"]["deletedIds"], [6])

    def test_recheck_preserves_candidate_that_becomes_one_of_latest_three(self):
        api = FakeGitHub([artifact(i) for i in range(1, 5)])
        seen = 0
        def race(api, path, method):
            nonlocal seen
            if path.startswith(ARTIFACTS_PATH + "?"):
                seen += 1
                if seen == 2:
                    api.artifacts = [item for item in api.artifacts if item["id"] != 1]
        api.before_request = race
        report = cleanup(api, now=NOW, apply=True)
        self.assertEqual(api.deletes, [])
        self.assertEqual(report["artifacts"]["skippedDuringApply"], 1)

    def test_changed_artifact_or_restarted_run_is_not_deleted(self):
        for race_kind in ("artifact", "run"):
            with self.subTest(race=race_kind):
                api = FakeGitHub([artifact(i) for i in range(1, 5)])
                def race(api, path, method):
                    if path == ARTIFACTS_PATH + "/4" and method == "GET":
                        if race_kind == "artifact":
                            api.artifacts[-1]["name"] = "app-signed-release-apk-90"
                        else:
                            api.run_overrides[1004] = {"status": "in_progress"}
                api.before_request = race
                report = cleanup(api, now=NOW, apply=True)
                self.assertEqual(api.deletes, [])
                self.assertEqual(report["artifacts"]["skippedDuringApply"], 1)

    def test_uncertain_delete_is_not_retried_or_counted_as_reclaimed(self):
        api = FakeGitHub([artifact(i) for i in range(1, 6)])
        api.delete_error = "github_timeout"
        report = cleanup(api, now=NOW, apply=True)
        self.assertEqual(len(api.deletes), 1)
        self.assertEqual(report["artifacts"]["deletedBytes"], 0)
        self.assertEqual(report["artifacts"]["status"], "blocked")
        self.assertEqual(report["artifacts"]["outcomeUnknownIds"], [5])

    def test_delete_limit_bounds_each_invocation(self):
        api = FakeGitHub([artifact(i) for i in range(1, 12)])
        report = cleanup(api, now=NOW, apply=True, max_deletions=2)
        self.assertEqual(report["artifacts"]["deletedIds"], [11, 10])
        self.assertEqual(report["artifacts"]["remainingCandidates"], 6)

    def test_ghcr_permissions_are_reported_without_preventing_safe_artifact_cleanup(self):
        api = FakeGitHub([artifact(i) for i in range(1, 5)])
        api.package_error = "github_forbidden"
        report = cleanup(api, now=NOW, apply=True)
        self.assertEqual(report["artifacts"]["deletedIds"], [4])
        self.assertEqual(report["ghcr"]["reason"], "package_permissions_required")
        self.assertIsNone(report["ghcr"]["observedVersions"])
        self.assertIsNone(report["ghcr"]["reclaimableBytes"])

    def test_untagged_children_attestations_and_all_tags_remain_protected(self):
        # This closed slice cannot prove OCI references. Even an untagged child
        # of a retained index and old intermediate manifests are never deleted.
        versions = [{"id": i, "name": "sha256:" + f"{i:064x}", "metadata": {"container": {"tags": tags}}}
                    for i, tags in enumerate(([], ["latest"], ["main"], ["stable"], ["v1.2.3"],
                                              ["release-1"], ["unknown"], ["sha-" + "a" * 40],
                                              ["sha-" + "b" * 40 + "-amd64"]), 1)]
        api = FakeGitHub(versions=versions)
        report = cleanup(api, now=NOW, apply=True)
        self.assertEqual(report["ghcr"]["reason"], "oci_reference_graph_unverified")
        self.assertEqual(report["ghcr"]["observedVersions"], 9)
        self.assertEqual(report["ghcr"]["retainedVersions"], 9)
        self.assertEqual(api.deletes, [])

    def test_invalid_metadata_does_not_echo_raw_values_or_delete(self):
        for field, value in (("id", True), ("size_in_bytes", -1), ("expired", 0),
                             ("created_at", "synthetic-secret"), ("name", "secret\nvalue")):
            with self.subTest(field=field):
                items = [artifact(i) for i in range(1, 5)]
                items[-1][field] = value
                api = FakeGitHub(items)
                report = cleanup(api, now=NOW, apply=True)
                self.assertEqual(report["artifacts"]["status"], "blocked")
                self.assertNotIn("secret", json.dumps(report))
                self.assertEqual(api.deletes, [])

    def test_cli_defaults_to_dry_run_and_rejects_arbitrary_scope(self):
        for args, applied in (([], False), (["--apply"], True)):
            with self.subTest(args=args), patch("github_storage_cleanup.GitHub") as api, patch("github_storage_cleanup.cleanup", return_value={"mode": "fixture"}) as run, patch("sys.stdout", new_callable=io.StringIO):
                self.assertEqual(main(args), 0)
                self.assertEqual(run.call_args.kwargs["apply"], applied)
        with patch("sys.stdout", new_callable=io.StringIO) as output:
            self.assertEqual(main(["--repo", "arbitrary/private-secret"]), 2)
        self.assertNotIn("private-secret", output.getvalue())

    def test_gh_transport_is_explicit_bounded_and_redacts_failure_output(self):
        completed = subprocess.CompletedProcess([], 0, b'HTTP/2.0 200 OK\r\ncontent-type: application/json\r\n\r\n{"id":1}', b'')
        with patch("github_storage_cleanup._run_gh", return_value=completed) as run:
            self.assertEqual(GitHub().request("repos/" + REPOSITORY), {"id": 1})
            command = run.call_args.args[0]
            self.assertIn("--hostname", command)
            self.assertIn("github.com", command)
            self.assertFalse(run.call_args.kwargs.get("shell", False))
            self.assertLessEqual(run.call_args.kwargs["deadline"] - time.monotonic(), 20)
        for completed in (subprocess.CompletedProcess([], 1, b'HTTP/2.0 403 Forbidden\r\n\r\n{"message":"private-token"}', b'private-token'),
                          subprocess.CompletedProcess([], 0, b'HTTP/2.0 200 OK\r\n\r\n{"id":1,"id":2}', b'')):
            with patch("github_storage_cleanup._run_gh", return_value=completed), self.assertRaises(CleanupError) as caught:
                GitHub().request("repos/" + REPOSITORY)
            self.assertNotIn("private-token", str(caught.exception))

    def test_expiration_during_final_run_recheck_does_not_reduce_three_available(self):
        values = [artifact(i) for i in range(1, 5)]
        values[0]["expires_at"] = (NOW + timedelta(seconds=1)).isoformat().replace("+00:00", "Z")
        api = FakeGitHub(values)
        times = iter([NOW, NOW, NOW + timedelta(seconds=2)])
        report = cleanup(api, clock=lambda: next(times), apply=True)
        self.assertEqual(api.deletes, [])
        self.assertEqual(report["artifacts"]["skippedDuringApply"], 1)

    def run_synthetic_child(self, script, *, maximum=32, timeout=.3):
        original_popen, original_read = subprocess.Popen, os.read
        children, reads = [], []
        def spawn(command, **kwargs):
            self.assertEqual(kwargs["stderr"], subprocess.DEVNULL)
            self.assertEqual(kwargs["stdin"], subprocess.DEVNULL)
            child = original_popen([sys.executable, "-c", script], **kwargs)
            children.append(child)
            return child
        def read(fd, size):
            if children and not children[0].stdout.closed and fd == children[0].stdout.fileno():
                reads.append(size)
            return original_read(fd, size)
        started = time.monotonic()
        value, failure = None, None
        with patch("subprocess.Popen", side_effect=spawn), patch("os.read", side_effect=read), patch("github_storage_cleanup.MAX_RESPONSE_BYTES", maximum):
            try:
                value = _run_gh(["synthetic"], os.environ.copy(), deadline=started + timeout)
            except (CleanupError, subprocess.TimeoutExpired) as error:
                failure = error
        for child in children:
            self.assertIsNotNone(child.returncode)
            self.assertTrue(child.stdout.closed)
        self.assertLess(time.monotonic() - started, 2)
        self.assertLessEqual(max(reads, default=0), maximum + 1)
        return value, failure

    def test_transport_stops_stdout_flood_during_read_and_reaps_child(self):
        value, failure = self.run_synthetic_child('import os\nwhile True: os.write(1,b"x"*65536)')
        self.assertIsNone(value)
        self.assertEqual(failure.code, "github_response_limit")

    def test_transport_discards_stderr_and_accepts_exact_stdout_limit(self):
        value, failure = self.run_synthetic_child('import os; os.write(2,b"secret"*200000); os.write(1,b"x"*32)')
        self.assertIsNone(failure)
        self.assertEqual(value.stdout, b"x" * 32)

    def test_transport_shared_deadline_limits_drip_and_wait_after_eof(self):
        for script in ('import os,time\nwhile True:\n os.write(1,b"x"); time.sleep(.02)',
                       'import os,time; os.close(1); time.sleep(5)'):
            with self.subTest(script=script):
                value, failure = self.run_synthetic_child(script, maximum=1024)
                self.assertIsNone(value)
                self.assertIsInstance(failure, subprocess.TimeoutExpired)

    def test_gh_transport_refuses_package_deletion_and_other_repositories(self):
        for path, method in ((PACKAGE_PATH + "/1", "DELETE"), ("repos/other/repo/actions/artifacts/1", "DELETE"),
                             ("https://other.invalid", "GET"), ("repos/" + REPOSITORY + "/releases/1", "DELETE")):
            with self.subTest(path=path), patch("subprocess.Popen") as run, self.assertRaises(CleanupError):
                GitHub().request(path, method=method)
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
