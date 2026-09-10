#!/usr/bin/env python3
"""Build complete, balanced and deterministic pytest file manifests for CI."""

import argparse
import hashlib
from pathlib import Path


class ShardError(ValueError):
    """The requested shard layout cannot cover the test tree exactly."""


def partition_test_files(root: Path, count: int) -> list[list[str]]:
    root = root.resolve()
    if count < 2 or not root.is_dir():
        raise ShardError("server_test_shards_invalid")
    files = [path for path in root.rglob("test_*.py")
             if path.is_file() and not path.is_symlink()]
    if len(files) < count:
        raise ShardError("server_test_shards_invalid")
    parent = root.parent
    relative_paths = [path.relative_to(parent).as_posix() for path in files]
    if any(any(ord(character) < 32 or ord(character) == 127 for character in path)
           for path in relative_paths):
        raise ShardError("server_test_shards_invalid")
    ordered = sorted(
        files,
        key=lambda path: (
            hashlib.sha256(path.relative_to(parent).as_posix().encode("utf-8")).digest(),
            path.relative_to(parent).as_posix(),
        ),
    )
    shards: list[list[str]] = [[] for _ in range(count)]
    for index, path in enumerate(ordered):
        shards[index % count].append(path.relative_to(parent).as_posix())
    return [sorted(shard) for shard in shards]


def write_manifests(root: Path, count: int, output_dir: Path) -> None:
    shards = partition_test_files(root, count)
    output_dir.mkdir(parents=True, exist_ok=True)
    if output_dir.is_symlink():
        raise ShardError("server_test_shards_invalid")
    for index, shard in enumerate(shards):
        destination = output_dir / f"{index}.txt"
        temporary = output_dir / f".{index}.tmp"
        temporary.write_text("\n".join(shard) + "\n", encoding="utf-8")
        temporary.replace(destination)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--count", type=int, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        write_manifests(arguments.root, arguments.count, arguments.output_dir)
    except ShardError as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
