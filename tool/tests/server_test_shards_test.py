from pathlib import Path
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


if __name__ == "__main__":
    unittest.main()
