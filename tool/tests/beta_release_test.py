import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "beta_release", ROOT / "tool/beta_release.py"
)
beta_release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(beta_release)


APK = b"synthetic signed apk bytes"
APK_HASH = hashlib.sha256(APK).hexdigest()
MANIFEST_HASH = ""
REPOSITORY = "ersingundem/larenor"
COMMIT = "a" * 40
WORKFLOW = ".github/workflows/android-build.yml"


def metadata(**changes):
    value = {
        "applicationId": "com.ersingundem.larenor",
        "versionName": "1.0.0",
        "versionCode": 100000123,
        "certificateSha256": "b" * 64,
        "apkSha256": APK_HASH,
        "commit": COMMIT,
        "workflowRun": "987654321",
    }
    value.update(changes)
    return value


def source_manifest(**changes):
    value = {
        "schemaVersion": 1,
        "channel": "beta",
        "applicationId": "com.ersingundem.larenor",
        "versionCode": 100000123,
        "versionName": "1.0.0",
        "certificateSha256": "b" * 64,
        "apkSha256": APK_HASH,
        "sizeBytes": len(APK),
        "minSdk": 26,
        "commit": COMMIT,
        "sourceRepository": REPOSITORY,
        "sourceWorkflow": WORKFLOW,
        "sourceRunId": 987654321,
        "sourceRunAttempt": 1,
        "releaseTag": "client-beta-v100000123",
        "apkAssetName": "Larenor-Client-beta-100000123.apk",
        "manifestAssetName": "Larenor-Client-beta-100000123.json",
        "publishedAt": "2026-09-11T12:00:00Z",
    }
    value.update(changes)
    return value


def release(identifier, version, *, immutable=False, **changes):
    apk_name = f"Larenor-Client-beta-{version}.apk"
    manifest_name = f"Larenor-Client-beta-{version}.json"
    value = {
        "id": identifier,
        "tag_name": f"client-beta-v{version}",
        "name": f"Larenor Client beta {version}",
        "target_commitish": COMMIT,
        "draft": False,
        "prerelease": True,
        "immutable": immutable,
        "assets": [
            {"id": identifier * 10 + 1, "name": apk_name,
             "size": len(APK), "digest": "sha256:" + APK_HASH},
            {"id": identifier * 10 + 2, "name": manifest_name,
             "size": 200, "digest": "sha256:" + "c" * 64},
        ],
    }
    value.update(changes)
    return value


class BetaReleaseTest(unittest.TestCase):
    def test_main_workflow_publishes_and_verifies_one_bounded_beta_release(self):
        workflow = (ROOT / ".github/workflows/android-build.yml").read_text()
        signed = workflow.split("  build-signed-release-apk:", 1)[1]
        self.assertIn("contents: write", signed)
        self.assertIn("Require the configured beta signing identity", signed)
        self.assertIn("python3 tool/beta_release.py manifest", signed)
        self.assertIn("gh release create", signed)
        self.assertIn("--draft", signed)
        self.assertIn("gh release edit", signed)
        self.assertIn("--draft=false", signed)
        self.assertIn("python3 tool/beta_release.py verify-release", signed)
        self.assertIn("python3 tool/beta_release.py retention", signed)
        self.assertIn("--keep 8 --max-deletions 4", signed)
        self.assertIn("python3 tool/beta_release.py verify-candidate", signed)
        self.assertIn('gh api --method DELETE "repos/$GITHUB_REPOSITORY/releases/$release_id"', signed)
        self.assertIn('gh api --method DELETE "repos/$GITHUB_REPOSITORY/git/refs/tags/$release_tag"', signed)
        self.assertIn("require_absent", signed)
        self.assertIn("cancel-in-progress: ${{ github.event_name == 'pull_request' }}", workflow)
        self.assertNotIn("Reject an obsolete main commit", signed)
        self.assertNotIn("--clobber", signed)

    def test_manifest_has_exact_beta_version_and_source_identity(self):
        with tempfile.TemporaryDirectory() as raw:
            apk = Path(raw) / "client.apk"
            apk.write_bytes(APK)
            result = beta_release.build_manifest(
                metadata(), apk, repository=REPOSITORY, workflow=WORKFLOW,
                run_attempt="1", published_at="2026-09-11T12:00:00Z",
            )
        self.assertEqual(result, source_manifest())
        self.assertEqual(beta_release.canonical_json(result),
                         json.dumps(result, sort_keys=True, separators=(",", ":")) + "\n")

    def test_manifest_rejects_hash_version_source_and_shape_ambiguity(self):
        with tempfile.TemporaryDirectory() as raw:
            apk = Path(raw) / "client.apk"
            apk.write_bytes(APK)
            cases = [
                metadata(apkSha256="f" * 64),
                metadata(versionCode=True),
                metadata(commit="f" * 39),
                metadata(extra="unexpected"),
                metadata(workflowRun="01"),
            ]
            for candidate in cases:
                with self.subTest(candidate=candidate), self.assertRaises(beta_release.BetaReleaseError):
                    beta_release.build_manifest(
                        candidate, apk, repository=REPOSITORY, workflow=WORKFLOW,
                        run_attempt="1", published_at="2026-09-11T12:00:00Z",
                    )
            for repository, workflow, attempt in [
                ("other/repository", WORKFLOW, "1"),
                (REPOSITORY, "other.yml", "1"),
                (REPOSITORY, WORKFLOW, "2"),
            ]:
                with self.subTest(repository=repository, workflow=workflow, attempt=attempt), self.assertRaises(beta_release.BetaReleaseError):
                    beta_release.build_manifest(
                        metadata(), apk, repository=repository, workflow=workflow,
                        run_attempt=attempt, published_at="2026-09-11T12:00:00Z",
                    )

    def test_published_release_requires_mutable_content_bound_asset_identity(self):
        manifest = source_manifest()
        manifest_bytes = beta_release.canonical_json(manifest).encode()
        expected = release(7, manifest["versionCode"])
        expected["assets"][1].update(
            size=len(manifest_bytes),
            digest="sha256:" + hashlib.sha256(manifest_bytes).hexdigest(),
        )
        beta_release.verify_release(expected, manifest, APK, manifest_bytes, COMMIT)
        defects = [
            {"immutable": True}, {"draft": True}, {"prerelease": False},
            {"tag_name": "client-beta-v100000122"}, {"target_commitish": "d" * 40},
            {"assets": expected["assets"][:1]},
            {"assets": [expected["assets"][0] | {"digest": "sha256:" + "f" * 64}, expected["assets"][1]]},
        ]
        for defect in defects:
            with self.subTest(defect=defect), self.assertRaises(beta_release.BetaReleaseError):
                beta_release.verify_release(expected | defect, manifest, APK, manifest_bytes, COMMIT)

    def test_retention_is_version_ordered_bounded_and_refuses_ambiguous_beta(self):
        values = [release(i, 100000100 + i) for i in range(1, 12)]
        values.append({"id": 99, "tag_name": "v1.0.0", "draft": False})
        self.assertEqual(
            beta_release.retention_candidates([values[:6], values[6:]], keep=8, maximum=4),
            [(1, "client-beta-v100000101", COMMIT),
             (2, "client-beta-v100000102", COMMIT),
             (3, "client-beta-v100000103", COMMIT)],
        )
        with self.assertRaises(beta_release.BetaReleaseError):
            beta_release.retention_candidates([values + [release(30, 100000103)]], keep=8, maximum=4)
        with self.assertRaises(beta_release.BetaReleaseError):
            beta_release.retention_candidates([[release(i, 100000100 + i) for i in range(1, 15)]], keep=8, maximum=4)
        with self.assertRaises(beta_release.BetaReleaseError):
            beta_release.retention_candidates([[release(1, 100000101, immutable=True)]], keep=8, maximum=4)

    def test_delete_candidate_requires_exact_mutable_release_tag_commit_and_assets(self):
        value = release(7, 100000123)
        self.assertEqual(beta_release.verify_candidate(
            value, identifier=7, tag="client-beta-v100000123", commit=COMMIT,
            resolved_tag_commit=COMMIT, allow_draft=False,
        ), 7)
        draft = value | {"draft": True}
        self.assertEqual(beta_release.verify_candidate(
            draft, identifier=7, tag="client-beta-v100000123", commit=COMMIT,
            resolved_tag_commit=COMMIT, allow_draft=True,
        ), 7)
        for candidate, identifier, tag_commit in [
            (value | {"immutable": True}, 7, COMMIT),
            (value | {"target_commitish": "d" * 40}, 7, COMMIT),
            (value | {"assets": value["assets"][:1]}, 7, COMMIT),
            (value, 8, COMMIT),
            (value, 7, "d" * 40),
        ]:
            with self.subTest(candidate=candidate, identifier=identifier, tag_commit=tag_commit), self.assertRaises(beta_release.BetaReleaseError):
                beta_release.verify_candidate(
                    candidate, identifier=identifier, tag="client-beta-v100000123",
                    commit=COMMIT, resolved_tag_commit=tag_commit, allow_draft=True,
                )


if __name__ == "__main__":
    unittest.main()
