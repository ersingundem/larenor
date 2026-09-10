from pathlib import Path
import json
import sys
import unittest


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


class ServerTestShardsTest(unittest.TestCase):
    def test_partition_is_complete_disjoint_balanced_and_stable(self):
        from server_test_shards import partition_test_files

        from tempfile import TemporaryDirectory
        with TemporaryDirectory() as directory:
            root = Path(directory) / "tests"
            root.mkdir()
            expected = set()
            for index in range(11):
                path = root / f"test_case_{index:02d}.py"
                path.write_text("def test_fixture(): pass\n")
                expected.add(f"tests/{path.name}")
            (root / "helper.py").write_text("ignored = True\n")

            first = partition_test_files(root, 3)
            second = partition_test_files(root, 3)

            self.assertEqual(first, second)
            self.assertEqual(set().union(*map(set, first)), expected)
            self.assertEqual(sum(map(len, first)), len(expected))
            self.assertLessEqual(max(map(len, first)) - min(map(len, first)), 1)

    def test_partition_rejects_invalid_or_empty_inputs(self):
        from server_test_shards import ShardError, partition_test_files

        from tempfile import TemporaryDirectory
        with TemporaryDirectory() as directory:
            root = Path(directory) / "tests"
            root.mkdir()
            for count in (0, 1, 4):
                with self.subTest(count=count), self.assertRaises(ShardError):
                    partition_test_files(root, count)
            (root / "test_one.py").write_text("def test_fixture(): pass\n")
            with self.assertRaises(ShardError):
                partition_test_files(root, 2)

    def test_partition_rejects_manifest_control_characters(self):
        from server_test_shards import ShardError, partition_test_files

        from tempfile import TemporaryDirectory
        with TemporaryDirectory() as directory:
            root = Path(directory) / "tests"
            root.mkdir()
            (root / "test_safe.py").write_text("def test_fixture(): pass\n")
            (root / "test_bad\n--collect-only.py").write_text(
                "def test_fixture(): assert False\n",
            )
            with self.assertRaises(ShardError):
                partition_test_files(root, 2)

    def test_weighted_partition_uses_lpt_and_keeps_zero_weight_files_balanced(self):
        from server_test_shards import partition_test_files

        from tempfile import TemporaryDirectory
        with TemporaryDirectory() as directory:
            root = Path(directory) / "tests"
            root.mkdir()
            weights = {}
            for index, weight in enumerate((9, 8, 7, 6, 5, 4)):
                path = root / f"test_case_{index}.py"
                path.write_text("def test_fixture(): pass\n")
                weights[f"tests/{path.name}"] = float(weight)

            shards = partition_test_files(root, 3, weights)

            self.assertEqual([len(shard) for shard in shards], [2, 2, 2])
            totals = [sum(weights[path] for path in shard) for shard in shards]
            self.assertEqual(totals, [13, 13, 13])

            zero_weights = {path: 0.0 for path in weights}
            zero_shards = partition_test_files(root, 3, zero_weights)
            self.assertEqual([len(shard) for shard in zero_shards], [2, 2, 2])

    def test_load_weights_validates_provenance_and_total(self):
        from server_test_shards import ShardError, load_weights

        from tempfile import TemporaryDirectory
        with TemporaryDirectory() as directory:
            path = Path(directory) / "weights.json"
            payload = {
                "schemaVersion": 1,
                "source": {
                    "runId": 123,
                    "headSha": "a" * 40,
                    "totalSeconds": 3.5,
                },
                "files": {
                    "tests/test_one.py": 1.25,
                    "tests/test_two.py": 2.25,
                },
            }
            path.write_text(json.dumps(payload))
            self.assertEqual(load_weights(path), payload["files"])

            for mutation in (
                lambda value: value["source"].update(runId=0),
                lambda value: value["source"].update(totalSeconds=4),
                lambda value: value["files"].update({"tests/test_bad.py": float("nan")}),
            ):
                candidate = json.loads(json.dumps(payload))
                mutation(candidate)
                path.write_text(json.dumps(candidate))
                with self.subTest(candidate=candidate), self.assertRaises(ShardError):
                    load_weights(path)


if __name__ == "__main__":
    unittest.main()
