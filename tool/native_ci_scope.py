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
    "tool/seerr_managed_ci.py",
    "tool/music_assistant_managed_ci.py",
    "tool/volume_bootstrap_helper.py",
    "tool/media_resource_smoke.py",
)

# The managed characterizers share a deliberately small native substrate. Keep
# that substrate coupled, while service-specific Core changes only repeat the
# matrix which can actually observe them.
_NATIVE_SUBSTRATE_PATTERNS = (
    "server/Dockerfile.volume-bootstrap",
    "server/Dockerfile.volume-bootstrap.dockerignore",
    "server/larenor_server/context.py",
    "server/larenor_server/services/transport.py",
    "server/larenor_server/plugins/catalog.py",
    "server/larenor_server/plugins/packagedcatalog.json",
    "server/larenor_server/plugins/stack_plan.py",
    "server/larenor_server/plugins/resource_*",
    "server/larenor_server/plugins/image_*",
    "server/larenor_server/plugins/network_*",
    "server/larenor_server/plugins/volume_*",
    "server/larenor_server/plugins/managed_container.py",
    "server/larenor_server/plugins/models.py",
    "server/larenor_server/plugins/jellyfin_*",
    "server/larenor_server/plugins/seerr_*",
    "server/larenor_server/plugins/arr_*",
    "server/larenor_server/plugins/qbittorrent_*",
    "server/larenor_server/plugins/shared_library_consumers.py",
    "server/larenor_server/plugins/engine_*.py",
    "server/larenor_server/plugins/installation_*",
    "server/larenor_server/plugins/media_service_bootstrap_models.py",
    "server/larenor_server/plugins/worker.py",
    "server/larenor_server/plugins/docker_probe.py",
    "tool/jellyfin_*",
    "tool/volume_bootstrap_helper.py",
    "tool/media_resource_smoke.py",
)
_WORKFLOW_PATTERNS = {
    "jellyfin-managed-characterization.yml": _NATIVE_SUBSTRATE_PATTERNS + (
        ".github/workflows/jellyfin-managed-characterization.yml",
    ),
    "qbittorrent-managed-characterization.yml": _NATIVE_SUBSTRATE_PATTERNS + (
        ".github/workflows/qbittorrent-managed-characterization.yml",
        "tool/qbittorrent_managed_ci.py",
        "tool/tests/qbittorrent_managed_ci_test.py",
        "tool/tests/qbittorrent_managed_workflow_test.py",
    ),
    "arr-managed-characterization.yml": _NATIVE_SUBSTRATE_PATTERNS + (
        ".github/workflows/arr-managed-characterization.yml",
        "tool/qbittorrent_managed_ci.py",
        "tool/arr_managed_ci.py",
        "tool/tests/arr_managed_ci_test.py",
        "tool/tests/arr_managed_workflow_test.py",
    ),
    "seerr-managed-characterization.yml": _NATIVE_SUBSTRATE_PATTERNS + (
        ".github/workflows/seerr-managed-characterization.yml",
        "tool/qbittorrent_managed_ci.py",
        "tool/seerr_managed_ci.py",
        "tool/tests/seerr_managed_ci_test.py",
        "tool/tests/seerr_managed_workflow_test.py",
    ),
    "music-assistant-managed-characterization.yml": _NATIVE_SUBSTRATE_PATTERNS + (
        ".github/workflows/music-assistant-managed-characterization.yml",
        "tool/qbittorrent_managed_ci.py",
        "tool/music_assistant_managed_ci.py",
        "tool/tests/music_assistant_managed_ci_test.py",
        "tool/tests/music_assistant_managed_workflow_test.py",
        "server/larenor_server/app.py",
        "server/larenor_server/core.py",
        "server/larenor_server/plugins/models.py",
        "server/larenor_server/plugins/music_*",
        "server/tests/test_music_*",
        "server/tests/test_plugin_catalog.py",
    ),
}
_WORKFLOW_REF = re.compile(
    r"^ersingundem/larenor/\.github/workflows/([^/@\s]+)@[^\s]+$"
)


def patterns_for_workflow(workflow_ref: str) -> tuple[str, ...] | None:
    match = _WORKFLOW_REF.fullmatch(workflow_ref)
    if match is None:
        return None
    patterns = _WORKFLOW_PATTERNS.get(match.group(1))
    if patterns is None:
        return None
    return ("tool/native_ci_scope.py", *patterns)


def is_relevant(path: str, patterns: Iterable[str] = RELEVANT_PATTERNS) -> bool:
    normalized = path.removeprefix("./")
    return any(fnmatch.fnmatchcase(normalized, pattern) for pattern in patterns)


def decide_scope(
    *,
    event_name: str,
    base_sha: str,
    head_sha: str,
    changed_files: Callable[[str, str], Iterable[str]],
    patterns: Iterable[str] = RELEVANT_PATTERNS,
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
    if any(is_relevant(path, patterns) for path in paths):
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
    patterns = patterns_for_workflow(os.environ.get("GITHUB_WORKFLOW_REF", ""))
    if event_name == "pull_request" and patterns is None:
        run_native, reason = True, "native-workflow-unknown"
    else:
        run_native, reason = decide_scope(
            event_name=event_name,
            base_sha=base_sha,
            head_sha=head_sha,
            changed_files=git_changed_files,
            patterns=patterns or RELEVANT_PATTERNS,
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
