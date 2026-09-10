#!/usr/bin/env python3
"""Decide whether a pull request must repeat native media characterization.

The required matrix jobs always start so branch-protection check names remain
stable. Only their expensive native steps may be skipped, and uncertainty
always falls back to running them.
"""

from __future__ import annotations

import argparse
import fnmatch
import os
from pathlib import Path
import re
import subprocess
from typing import Callable, Iterable


SHA256_RE = re.compile(r"^[0-9a-f]{40}$")
RELEVANT_PATTERNS = (
    "server/**",
    ".github/workflows/*characterization.yml",
    "tool/native_ci_scope.py",
    "tool/jellyfin_*",
    "tool/qbittorrent_managed_ci.py",
    "tool/arr_managed_ci.py",
    "tool/volume_bootstrap_helper.py",
    "tool/media_resource_smoke.py",
)


def is_relevant(path: str, patterns: Iterable[str] = RELEVANT_PATTERNS) -> bool:
    normalized = path.removeprefix("./")
    return any(fnmatch.fnmatchcase(normalized, pattern) for pattern in patterns)


def decide_scope(
    *,
    event_name: str,
    base_sha: str,
    head_sha: str,
    changed_files: Callable[[str, str], Iterable[str]],
) -> tuple[bool, str]:
    """Return ``(run_native, reason)`` and fail open on incomplete evidence."""

    if event_name != "pull_request":
        return True, "non-pull-request"
    if not SHA256_RE.fullmatch(base_sha) or not SHA256_RE.fullmatch(head_sha):
        return True, "invalid-pull-request-revision"
    try:
        paths = tuple(changed_files(base_sha, head_sha))
    except (OSError, subprocess.SubprocessError, UnicodeError):
        return True, "diff-unavailable"
    if any(is_relevant(path) for path in paths):
        return True, "native-input-changed"
    return False, "native-inputs-unchanged"


def git_changed_files(base_sha: str, head_sha: str) -> tuple[str, ...]:
    completed = subprocess.run(
        ["git", "diff", "--name-only", "--no-renames", base_sha, head_sha, "--"],
        check=True,
        capture_output=True,
        text=True,
    )
    return tuple(line for line in completed.stdout.splitlines() if line)


def _append(path: str, line: str) -> None:
    if not path:
        return
    with Path(path).open("a", encoding="utf-8") as stream:
        stream.write(f"{line}\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT", ""))
    parser.add_argument("--summary", default=os.environ.get("GITHUB_STEP_SUMMARY", ""))
    args = parser.parse_args()
    event_name = os.environ.get("GITHUB_EVENT_NAME", "")
    base_sha = os.environ.get("PR_BASE_SHA", "")
    head_sha = os.environ.get("PR_HEAD_SHA", "")
    run_native, reason = decide_scope(
        event_name=event_name,
        base_sha=base_sha,
        head_sha=head_sha,
        changed_files=git_changed_files,
    )
    _append(args.github_output, f"run={'true' if run_native else 'false'}")
    _append(args.github_output, f"reason={reason}")
    revisions = (
        f"base `{base_sha[:12]}`, head `{head_sha[:12]}`"
        if SHA256_RE.fullmatch(base_sha) and SHA256_RE.fullmatch(head_sha)
        else "revision pair unavailable"
    )
    _append(args.summary, (
        f"Native characterization: **{'run' if run_native else 'reused'}** "
        f"({reason}; {revisions})."
    ))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
