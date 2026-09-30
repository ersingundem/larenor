"""Nonsecret source provenance for hosted native acceptance receipts."""

from __future__ import annotations

import os
from pathlib import Path
import re
import shutil
import subprocess


_REVISION = re.compile(r"[0-9a-f]{40}")


class NativeAcceptanceReceiptError(RuntimeError):
    pass


def source_revision(root: Path) -> str:
    """Return the real Git HEAD and bind it to GITHUB_SHA when hosted."""
    try:
        repository = root.resolve(strict=True)
    except OSError as error:
        raise NativeAcceptanceReceiptError(
            "native acceptance repository is unavailable"
        ) from error
    if not repository.is_dir():
        raise NativeAcceptanceReceiptError(
            "native acceptance repository is unavailable"
        )
    git_value = shutil.which("git")
    if git_value is None:
        raise NativeAcceptanceReceiptError(
            "native acceptance Git executable is unavailable"
        )
    try:
        git = Path(git_value).resolve(strict=True)
    except OSError as error:
        raise NativeAcceptanceReceiptError(
            "native acceptance Git executable is unavailable"
        ) from error
    if not git.is_file():
        raise NativeAcceptanceReceiptError(
            "native acceptance Git executable is unavailable"
        )
    try:
        result = subprocess.run(
            [str(git), "-C", str(repository), "rev-parse", "--verify", "HEAD"],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise NativeAcceptanceReceiptError(
            "native acceptance source revision is unavailable"
        ) from error
    lines = result.stdout.splitlines()
    if (
        result.returncode != 0
        or len(lines) != 1
        or _REVISION.fullmatch(lines[0]) is None
    ):
        raise NativeAcceptanceReceiptError(
            "native acceptance source revision is unavailable"
        )
    revision = lines[0]
    hosted = os.environ.get("GITHUB_SHA")
    if hosted is not None and (
        _REVISION.fullmatch(hosted) is None or hosted != revision
    ):
        raise NativeAcceptanceReceiptError(
            "native acceptance hosted revision does not match Git HEAD"
        )
    return revision
