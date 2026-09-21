"""Preserve required checks while silencing superseded cancellation noise.

Only a cancelled dependency on a PR whose *current* head differs from the
event's exact head can pass. A genuine failure, current-head cancellation,
missing permission, malformed response, or API outage remains blocking.
"""

from __future__ import annotations

import json
import os
import re
import sys
from collections.abc import Callable, Mapping
from pathlib import Path
from urllib.request import Request, urlopen

_SHA = re.compile(r"^[0-9a-f]{40}$")
_REPO = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
_RESULTS = {
    "server": ("SHARD_RESULT",),
    "flutter": ("STATIC_RESULT", "TEST_RESULT"),
    "native": ("SCOPE_RESULT", "MATRIX_RESULT"),
}


def current_pr_head(
    env: Mapping[str, str], opener: Callable = urlopen,
) -> tuple[str, str] | None:
    """Return (event head, live PR head), or None on any uncertainty."""
    try:
        if env.get("GITHUB_EVENT_NAME") != "pull_request":
            return None
        repo = env.get("GITHUB_REPOSITORY", "")
        token = env.get("GITHUB_TOKEN", "")
        path = Path(env.get("GITHUB_EVENT_PATH", ""))
        if not _REPO.fullmatch(repo) or not token or path.stat().st_size > 1024 * 1024:
            return None
        event = json.loads(path.read_text(encoding="utf-8"))
        number = event["number"]
        pull = event["pull_request"]
        old = pull["head"]["sha"]
        if (type(number) is not int or number < 1 or
                pull["base"]["repo"]["full_name"] != repo or
                not isinstance(old, str) or not _SHA.fullmatch(old)):
            return None
        request = Request(
            f"https://api.github.com/repos/{repo}/pulls/{number}",
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {token}",
                "User-Agent": "larenor-required-ci-aggregate",
                "X-GitHub-Api-Version": "2022-11-28",
            },
        )
        with opener(request, timeout=5) as response:
            if response.status != 200:
                return None
            raw = response.read(1024 * 1024 + 1)
        if len(raw) > 1024 * 1024:
            return None
        current = json.loads(raw)
        new = current["head"]["sha"]
        if (current["number"] != number or not isinstance(new, str) or
                not _SHA.fullmatch(new)):
            return None
        return old, new
    except (KeyError, OSError, UnicodeError, ValueError, TypeError):
        return None


def decide(kind: str, statuses: Mapping[str, str], superseded: Callable[[], bool]) -> bool:
    """Fail closed for every current or genuinely failed required dependency."""
    if kind not in _RESULTS:
        return False
    results = tuple(statuses.get(name, "") for name in _RESULTS[kind])
    if kind == "native":
        run = statuses.get("RUN_NATIVE", "")
        if results[0] == "success" and (
            (run == "true" and results[1] == "success") or
            (run == "false" and results[1] == "skipped")
        ):
            return True
        if run not in ("", "true", "false"):
            return False
    elif all(result == "success" for result in results):
        return True

    # Never turn a real shard failure, unknown result, or unexpected skip into
    # success. A canceled *old* revision is no longer the PR's required head.
    if ("cancelled" not in results or
            any(result not in ("success", "cancelled", "skipped") for result in results)):
        return False
    try:
        return superseded()
    except (OSError, ValueError, TypeError):
        return False


def main() -> int:
    if len(sys.argv) != 2:
        return 2
    kind = sys.argv[1]
    if kind not in _RESULTS:
        return 2

    def superseded() -> bool:
        heads = current_pr_head(os.environ)
        return heads is not None and heads[0] != heads[1]

    passed = decide(kind, os.environ, superseded)
    if passed:
        print("Required CI aggregate passed or its canceled PR head was superseded.")
        return 0
    print("Required CI dependency failed, was canceled on the current head, or could not be verified.",
          file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
