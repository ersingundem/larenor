#!/usr/bin/env python3
"""Deterministically balance Flutter test files across CI workers."""

from __future__ import annotations

import argparse
from pathlib import Path


def discover(root: Path) -> tuple[Path, ...]:
    test_root = root / "test"
    if not test_root.is_dir():
        raise ValueError("test_directory_missing")
    files = tuple(sorted(
        path.relative_to(root)
        for path in test_root.rglob("*_test.dart")
        if path.is_file() and not path.is_symlink()
    ))
    if not files:
        raise ValueError("test_files_missing")
    return files


def partitions(root: Path, count: int) -> tuple[tuple[Path, ...], ...]:
    if type(count) is not int or not 2 <= count <= 16:
        raise ValueError("invalid_shard_count")
    buckets: list[list[Path]] = [[] for _ in range(count)]
    weights = [0] * count
    files = discover(root)
    ranked = sorted(
        files,
        key=lambda path: (-(root / path).stat().st_size, path.as_posix()),
    )
    for path in ranked:
        index = min(range(count), key=lambda item: (weights[item], item))
        buckets[index].append(path)
        weights[index] += (root / path).stat().st_size
    result = tuple(tuple(sorted(bucket)) for bucket in buckets)
    if any(not bucket for bucket in result):
        raise ValueError("empty_test_shard")
    return result


def select(root: Path, index: int, count: int) -> tuple[Path, ...]:
    if type(index) is not int or not 0 <= index < count:
        raise ValueError("invalid_shard_index")
    return partitions(root, count)[index]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--index", type=int, required=True)
    parser.add_argument("--count", type=int, required=True)
    args = parser.parse_args()
    try:
        paths = select(args.root.resolve(), args.index, args.count)
    except (OSError, ValueError):
        parser.error("unable to build deterministic Flutter test shard")
    for path in paths:
        print(path.as_posix())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
