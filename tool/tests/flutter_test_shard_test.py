"""Tests for deterministic, exhaustive Flutter CI sharding."""

from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tool"))

from flutter_test_shard import discover, partitions, select


class FlutterTestShardTest(unittest.TestCase):
    def fixture(self):
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        for name, size in (
            ("test/a_test.dart", 100),
            ("test/feature/b_test.dart", 80),
            ("test/feature/c_test.dart", 60),
            ("test/d_test.dart", 40),
            ("test/not_a_fixture.dart", 1000),
        ):
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"x" * size)
        return temporary, root

    def test_partitions_are_exhaustive_disjoint_and_deterministic(self):
        temporary, root = self.fixture()
        self.addCleanup(temporary.cleanup)
        first = partitions(root, 2)
        second = partitions(root, 2)
        flattened = [path for bucket in first for path in bucket]
        self.assertEqual(first, second)
        self.assertEqual(len(flattened), len(set(flattened)))
        self.assertEqual(set(flattened), set(discover(root)))
        self.assertTrue(all(bucket for bucket in first))
        weights = [
            sum((root / path).stat().st_size for path in bucket)
            for bucket in first
        ]
        self.assertLessEqual(max(weights) - min(weights), 40)

    def test_select_rejects_invalid_counts_and_indices(self):
        temporary, root = self.fixture()
        self.addCleanup(temporary.cleanup)
        for count, index in ((1, 0), (17, 0), (2, -1), (2, 2)):
            with self.subTest(count=count, index=index):
                with self.assertRaises(ValueError):
                    select(root, index, count)

    def test_workflow_preserves_required_gate_and_isolated_evidence(self):
        workflow = (ROOT / ".github/workflows/analyze-test.yml").read_text()
        self.assertIn("  analyze-test:", workflow)
        self.assertIn("needs: [static-analysis, flutter-test]", workflow)
        self.assertIn("shard: [0, 1, 2, 3]", workflow)
        self.assertIn("fail-fast: false", workflow)
        self.assertIn("name: test-evidence-" + chr(36) + "{{ matrix.shard }}", workflow)
        self.assertIn(chr(36) + "{shard_files[@]}", workflow)
        self.assertIn("timeout-minutes: 15", workflow)

    def test_repository_has_four_nonempty_complete_shards(self):
        shards = partitions(ROOT, 4)
        files = [path for shard in shards for path in shard]
        self.assertTrue(all(shards))
        self.assertEqual(set(files), set(discover(ROOT)))
        self.assertEqual(len(files), len(set(files)))


if __name__ == "__main__":
    unittest.main()
