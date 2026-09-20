#!/usr/bin/env python3
"""Fail-open scope decision for the required Server test shards.

The four shard jobs and their aggregate check always start. Expensive Server
toolchain and pytest steps may be skipped only when an exact pull-request diff
contains solely reviewed Flutter, Android UI, or documentation paths.
"""

from __future__ import annotations

import argparse
import fnmatch
import os
from pathlib import Path
import re
import subprocess
from typing import Callable, Iterable


SHA_RE = re.compile(r"^[0-9a-f]{40}$")
SAFE_SKIP_PATTERNS = (
    "lib/**",
    "test/**",
    "integration_test/**",
    "android/**",
    "assets/**",
    "docs/**",
    "README.md",
    "LICENSE",
    "NOTICE",
    "THIRD_PARTY_NOTICES.md",
    ".metadata",
    "analysis_options.yaml",
    "l10n.yaml",
    "pubspec.yaml",
    "pubspec.lock",
    ".github/workflows/arr-managed-characterization.yml",
    ".github/workflows/jellyfin-managed-characterization.yml",
    ".github/workflows/music-assistant-managed-characterization.yml",
    ".github/workflows/qbittorrent-managed-characterization.yml",
    ".github/workflows/seerr-managed-characterization.yml",
    ".github/workflows/unified-media-stack-managed.yml",
    "deploy/larenor-server/.env.example",
    "deploy/larenor-server/unified.compose.yaml",
    "deploy/larenor-server/unified_package.py",
    "deploy/larenor-server/deployment_bundle.py",
    "tool/native_ci_scope.py",
    "tool/tests/native_ci_scope_test.py",
    "tool/unified_media_stack_managed_ci.py",
    "tool/tests/unified_media_stack_*",
)


def is_server_relevant(path: str) -> bool:
    """Return false only for the reviewed Client and documentation allowlist."""

    if not path or path.startswith("/") or "\\" in path:
        return True
    normalized = path.removeprefix("./")
    if (
        normalized in (".", "..")
        or normalized.startswith("../")
        or "/../" in normalized
        or any(ord(character) < 32 or ord(character) == 127 for character in normalized)
    ):
        return True
    return not any(
        fnmatch.fnmatchcase(normalized, pattern) for pattern in SAFE_SKIP_PATTERNS
    )


def decide_scope(
    *,
    event_name: str,
    base_sha: str,
    head_sha: str,
    changed_files: Callable[[str, str], Iterable[str]],
) -> tuple[bool, str]:
    """Return ``(run_server, reason)``; incomplete evidence always runs."""

    if event_name != "pull_request":
        return True, "non-pull-request"
    if not base_sha or not head_sha:
        return True, "missing-pull-request-revision"
    if not SHA_RE.fullmatch(base_sha) or not SHA_RE.fullmatch(head_sha):
        return True, "invalid-pull-request-revision"
    try:
        paths = tuple(changed_files(base_sha, head_sha))
    except (OSError, subprocess.SubprocessError, UnicodeError):
        return True, "diff-unavailable"
    if not paths:
        return True, "diff-empty"
    if any(is_server_relevant(path) for path in paths):
        return True, "server-input-changed"
    return False, "server-inputs-unchanged"


def git_changed_files(base_sha: str, head_sha: str) -> tuple[str, ...]:
    completed = subprocess.run(
        [
            "git",
            "diff",
            "--name-only",
            "-z",
            "--no-renames",
            base_sha,
            head_sha,
            "--",
        ],
        check=True,
        capture_output=True,
    )
    raw = completed.stdout
    if raw and not raw.endswith(b"\0"):
        raise UnicodeError("unterminated git path output")
    return tuple(
        part.decode("utf-8", errors="strict") for part in raw.split(b"\0") if part
    )


def _append(path: str, line: str) -> None:
    if not path:
        return
    with Path(path).open("a", encoding="utf-8") as stream:
        stream.write(line + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT", ""))
    parser.add_argument("--summary", default=os.environ.get("GITHUB_STEP_SUMMARY", ""))
    args = parser.parse_args()
    base_sha = os.environ.get("PR_BASE_SHA", "")
    head_sha = os.environ.get("PR_HEAD_SHA", "")
    run_server, reason = decide_scope(
        event_name=os.environ.get("GITHUB_EVENT_NAME", ""),
        base_sha=base_sha,
        head_sha=head_sha,
        changed_files=git_changed_files,
    )
    _append(args.github_output, f"run={'true' if run_server else 'false'}")
    _append(args.github_output, f"reason={reason}")
    revisions = (
        f"base `{base_sha[:12]}`, head `{head_sha[:12]}`"
        if SHA_RE.fullmatch(base_sha) and SHA_RE.fullmatch(head_sha)
        else "revision pair unavailable"
    )
    _append(
        args.summary,
        f"Server scope: **{'run' if run_server else 'reused'}** "
        f"({reason}; {revisions}).",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
