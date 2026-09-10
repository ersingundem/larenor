#!/usr/bin/env python3
"""Build complete, balanced and deterministic pytest file manifests for CI."""

import argparse
import json
import math
from pathlib import Path
import re
from typing import Dict, Optional


class ShardError(ValueError):
    """The requested shard layout cannot cover the test tree exactly."""


def _safe_path(value: str) -> bool:
    path = Path(value)
    return (value == path.as_posix() and not path.is_absolute()
            and value.startswith("tests/test_") and value.endswith(".py")
            and ".." not in path.parts
            and not any(ord(character) < 32 or ord(character) == 127
                        for character in value))


def load_weights(path: Path) -> Dict[str, float]:
    raw = path.read_bytes()
    if not raw or len(raw) > 65_536:
        raise ShardError("server_test_shards_invalid")
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ShardError("server_test_shards_invalid")
            result[key] = value
        return result
    try:
        value = json.loads(raw, object_pairs_hook=unique,
                           parse_constant=lambda _: (_ for _ in ()).throw(
                               ShardError("server_test_shards_invalid")))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise ShardError("server_test_shards_invalid") from None
    if (type(value) is not dict or set(value) != {"schemaVersion", "source", "files"}
            or value["schemaVersion"] != 1 or type(value["source"]) is not dict
            or set(value["source"]) != {"runId", "headSha", "totalSeconds"}
            or type(value["source"]["runId"]) is not int
            or not 0 < value["source"]["runId"] <= 9_223_372_036_854_775_807
            or not re.fullmatch(r"[0-9a-f]{40}", value["source"]["headSha"])
            or type(value["source"]["totalSeconds"]) not in (int, float)
            or not math.isfinite(value["source"]["totalSeconds"])
            or not 0 < value["source"]["totalSeconds"] <= 3_600
            or type(value["files"]) is not dict or not value["files"]):
        raise ShardError("server_test_shards_invalid")
    weights = {}
    for key, weight in value["files"].items():
        if (type(key) is not str or not _safe_path(key)
                or type(weight) not in (int, float) or not math.isfinite(weight)
                or not 0 <= weight <= 600):
            raise ShardError("server_test_shards_invalid")
        weights[key] = float(weight)
    if not math.isclose(sum(weights.values()),
                        float(value["source"]["totalSeconds"]),
                        rel_tol=0, abs_tol=0.001):
        raise ShardError("server_test_shards_invalid")
    return weights


def partition_test_files(root: Path, count: int,
                         weights: Optional[Dict[str, float]] = None) -> list[list[str]]:
    root = root.resolve()
    if count < 2 or not root.is_dir():
        raise ShardError("server_test_shards_invalid")
    files = [path for path in root.rglob("test_*.py")
             if path.is_file() and not path.is_symlink()]
    if len(files) < count:
        raise ShardError("server_test_shards_invalid")
    parent = root.parent
    relative_paths = [path.relative_to(parent).as_posix() for path in files]
    if any(not _safe_path(path) for path in relative_paths):
        raise ShardError("server_test_shards_invalid")
    known = {} if weights is None else weights
    if set(known) - set(relative_paths):
        raise ShardError("server_test_shards_invalid")
    fallback = max(known.values()) if known else 1.0
    predicted = {path: known.get(path, fallback) for path in relative_paths}
    ordered = sorted(relative_paths, key=lambda path: (-predicted[path], path))
    shards: list[list[str]] = [[] for _ in range(count)]
    totals = [0.0] * count
    for path in ordered:
        index = min(range(count),
                    key=lambda item: (totals[item], len(shards[item]), item))
        shards[index].append(path)
        totals[index] += predicted[path]
    if any(not shard for shard in shards):
        raise ShardError("server_test_shards_invalid")
    if weights is not None and min(totals) > 0 \
            and max(totals) > min(totals) * 1.25:
        raise ShardError("server_test_shards_invalid")
    return [sorted(shard) for shard in shards]


def write_manifests(root: Path, count: int, output_dir: Path,
                    weights: Optional[Dict[str, float]] = None) -> None:
    shards = partition_test_files(root, count, weights)
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
    parser.add_argument("--weights", type=Path)
    arguments = parser.parse_args()
    try:
        weights = load_weights(arguments.weights) if arguments.weights else None
        write_manifests(arguments.root, arguments.count, arguments.output_dir, weights)
    except ShardError as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
