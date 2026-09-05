#!/usr/bin/env python3
"""Conservative, bounded GitHub artifact retention. Defaults to a dry run.

The only mutation is DELETE of an old app-debug-apk Actions artifact from the
known completed workflow. GHCR inventory is read-only: without an independently
verified OCI reference graph, every package version remains protected.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import re
import selectors
import stat
import subprocess
import sys
import tempfile
import time


REPOSITORY = "ersingundem/larenor"
PACKAGE = "larenor-server"
ARTIFACTS_PATH = f"repos/{REPOSITORY}/actions/artifacts"
PACKAGE_PATH = f"users/ersingundem/packages/container/{PACKAGE}/versions"
WORKFLOW_PATH = ".github/workflows/android-build.yml"
DEBUG_NAMES = frozenset({"app-debug-apk"})
KEEP_NEWEST = 3
MAX_PAGES = 20
MAX_ITEMS = 2000
MAX_DELETIONS = 20
MAX_RESPONSE_BYTES = 2 * 1024 * 1024
_READ_PATH = re.compile(
    rf"(?:repos/{REPOSITORY}|{ARTIFACTS_PATH}(?:\?per_page=100&page=[1-9][0-9]?|/[1-9][0-9]*)|"
    rf"repos/{REPOSITORY}/actions/runs/[1-9][0-9]*|{PACKAGE_PATH}\?per_page=100&page=[1-9][0-9]?)\Z")
_DELETE_PATH = re.compile(rf"{ARTIFACTS_PATH}/[1-9][0-9]*\Z")


class CleanupError(Exception):
    def __init__(self, code, *, outcome_unknown=False):
        self.code, self.outcome_unknown = code, outcome_unknown
        super().__init__(code)


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise CleanupError("github_invalid_response")
        result[key] = value
    return result


def _run_gh(command, environment, *, deadline):
    """Bound output during reads and share one deadline through process exit."""
    process = None
    try:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, env=environment, bufsize=0)
        output = bytearray()
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    raise subprocess.TimeoutExpired("gh", 20)
                chunk = os.read(process.stdout.fileno(), min(65536, MAX_RESPONSE_BYTES - len(output) + 1))
                if not chunk:
                    break
                if len(output) + len(chunk) > MAX_RESPONSE_BYTES:
                    raise CleanupError("github_response_limit")
                output.extend(chunk)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise subprocess.TimeoutExpired("gh", 20)
        return subprocess.CompletedProcess(command, process.wait(timeout=remaining), bytes(output), b"")
    finally:
        if process is not None:
            if process.poll() is None:
                process.kill()
            process.wait()
            process.stdout.close()


class GitHub:
    """Use existing gh credentials, never print tokens, headers or raw errors."""
    def __init__(self):
        self.requests = 0
        self.deadline = time.monotonic() + 180

    def request(self, path, *, method="GET"):
        if type(path) is not str or not (
            method == "GET" and _READ_PATH.fullmatch(path) or
            method == "DELETE" and _DELETE_PATH.fullmatch(path)
        ):
            raise CleanupError("scope_refused")
        if self.requests >= 200 or time.monotonic() >= self.deadline:
            raise CleanupError("github_request_budget")
        self.requests += 1
        command = ["gh", "api", "--hostname", "github.com", "--method", method,
                   "--include", "-H", "Accept: application/vnd.github+json",
                   "-H", "X-GitHub-Api-Version: 2022-11-28", path]
        environment = os.environ.copy()
        environment.pop("GH_DEBUG", None)
        environment["GH_PROMPT_DISABLED"] = "1"
        try:
            result = _run_gh(command, environment, deadline=min(self.deadline, time.monotonic() + 20))
        except CleanupError as error:
            raise CleanupError(error.code, outcome_unknown=method == "DELETE") from None
        except subprocess.TimeoutExpired:
            raise CleanupError("github_timeout", outcome_unknown=method == "DELETE") from None
        except OSError:
            raise CleanupError("github_unavailable", outcome_unknown=method == "DELETE") from None
        if len(result.stdout) > MAX_RESPONSE_BYTES:
            raise CleanupError("github_response_limit", outcome_unknown=method == "DELETE")
        raw = result.stdout.replace(b"\r\n", b"\n")
        headers, separator, body = raw.partition(b"\n\n")
        status_line = re.match(rb"HTTP/[0-9.]+ ([0-9]{3})(?: |\n|$)", headers)
        if not separator or not status_line:
            raise CleanupError("github_unavailable", outcome_unknown=method == "DELETE")
        status = int(status_line[1])
        if status in (401, 403, 404):
            raise CleanupError({401: "github_unauthorized", 403: "github_forbidden", 404: "github_not_found"}[status])
        expected = 204 if method == "DELETE" else 200
        if result.returncode != 0 or status != expected:
            raise CleanupError("github_unavailable", outcome_unknown=method == "DELETE")
        if method == "DELETE":
            return None
        try:
            return json.loads(body.decode("utf-8"), object_pairs_hook=_unique_object,
                              parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()))
        except (ValueError, UnicodeError, RecursionError):
            raise CleanupError("github_invalid_response") from None


def _integer(value, *, zero=False):
    if type(value) is not int or not (0 if zero else 1) <= value <= 2**63 - 1:
        raise CleanupError("github_invalid_response")
    return value


def _text(value, *, maximum=255):
    if type(value) is not str or not 1 <= len(value) <= maximum or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise CleanupError("github_invalid_response")
    return value


def _date(value):
    if type(value) is not str or not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z", value):
        raise CleanupError("github_invalid_response")
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise CleanupError("github_invalid_response") from None


@dataclass(frozen=True)
class Artifact:
    id: int
    name: str
    size: int
    created: datetime
    updated: datetime
    expires: datetime
    expired: bool
    run_id: int
    digest: str | None
    head_sha: str

    @classmethod
    def parse(cls, value, repository_id):
        try:
            run = value["workflow_run"]
            if (type(value["expired"]) is not bool or
                    _integer(run["repository_id"]) != repository_id or
                    not re.fullmatch(r"[0-9a-f]{40}", run["head_sha"])):
                raise CleanupError("github_invalid_response")
            digest = value.get("digest")
            if digest is not None and (type(digest) is not str or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest)):
                raise CleanupError("github_invalid_response")
            result = cls(_integer(value["id"]), _text(value["name"]), _integer(value["size_in_bytes"], zero=True),
                         _date(value["created_at"]), _date(value["updated_at"]), _date(value["expires_at"]),
                         value["expired"], _integer(run["id"]), digest, run["head_sha"])
            if result.updated < result.created or result.expires < result.created:
                raise CleanupError("github_invalid_response")
            return result
        except (KeyError, TypeError, AttributeError):
            raise CleanupError("github_invalid_response") from None

    def public(self):
        return {"id": self.id, "runId": self.run_id, "bytes": self.size,
                "createdAt": self.created.isoformat().replace("+00:00", "Z")}


def _snapshot(api, repository_id):
    artifacts, ids, expected = [], set(), None
    for page in range(1, MAX_PAGES + 1):
        data = api.request(f"{ARTIFACTS_PATH}?per_page=100&page={page}")
        if type(data) is not dict or type(data.get("artifacts")) is not list:
            raise CleanupError("github_invalid_response")
        total = _integer(data.get("total_count"), zero=True)
        if total > MAX_ITEMS:
            raise CleanupError("github_snapshot_limit")
        if expected is None:
            expected = total
        if total != expected or len(data["artifacts"]) != min(100, expected - len(artifacts)):
            raise CleanupError("github_snapshot_changed")
        for raw in data["artifacts"]:
            artifact = Artifact.parse(raw, repository_id)
            if artifact.id in ids:
                raise CleanupError("github_snapshot_changed")
            artifacts.append(artifact)
            ids.add(artifact.id)
        if len(artifacts) == expected:
            return tuple(artifacts)
    raise CleanupError("github_snapshot_limit")


def _retention(artifacts, now):
    available = sorted((item for item in artifacts if item.name in DEBUG_NAMES and not item.expired and item.expires > now),
                       key=lambda item: (item.created, item.id), reverse=True)
    return tuple(item.id for item in available[:KEEP_NEWEST]), tuple(reversed(available[KEEP_NEWEST:]))


def _completed_debug_run(api, artifact, repository_id):
    run = api.request(f"repos/{REPOSITORY}/actions/runs/{artifact.run_id}")
    try:
        if (_integer(run["id"]) != artifact.run_id or _integer(run["repository"]["id"]) != repository_id
                or run["repository"]["full_name"] != REPOSITORY):
            raise CleanupError("github_invalid_response")
        return run["status"] == "completed" and run["path"] == WORKFLOW_PATH
    except (KeyError, TypeError):
        raise CleanupError("github_invalid_response") from None


def _ghcr_inventory(api):
    report = {"package": "ghcr.io/ersingundem/larenor-server", "status": "blocked",
              "reason": "oci_reference_graph_unverified", "observedVersions": None,
              "retainedVersions": None, "deletedVersions": 0, "reclaimableBytes": None}
    try:
        identifiers = set()
        for page in range(1, MAX_PAGES + 1):
            data = api.request(f"{PACKAGE_PATH}?per_page=100&page={page}")
            if type(data) is not list or len(data) > 100:
                raise CleanupError("github_invalid_response")
            for item in data:
                identifier = _integer(item.get("id")) if type(item) is dict else _integer(None)
                if identifier in identifiers:
                    raise CleanupError("github_snapshot_changed")
                identifiers.add(identifier)
            if len(data) < 100:
                report.update(observedVersions=len(identifiers), retainedVersions=len(identifiers))
                return report
        raise CleanupError("github_snapshot_limit")
    except CleanupError as error:
        report["reason"] = "package_permissions_required" if error.code in ("github_forbidden", "github_unauthorized") else error.code
        return report


def cleanup(api, *, now=None, clock=None, apply=False, max_deletions=MAX_DELETIONS):
    if type(apply) is not bool or type(max_deletions) is not int or not 1 <= max_deletions <= MAX_DELETIONS:
        raise CleanupError("invalid_arguments")
    if clock is not None and now is not None:
        raise CleanupError("invalid_arguments")
    read_clock = clock if clock is not None else (lambda: now) if now is not None else (lambda: datetime.now(timezone.utc))
    def current_time():
        value = read_clock()
        if not isinstance(value, datetime) or value.tzinfo is None or value.utcoffset().total_seconds() != 0:
            raise CleanupError("invalid_arguments")
        return value
    now = current_time()
    artifacts = {"status": "ready", "reason": None, "observedCount": None, "observedBytes": None,
                 "protectedNewestIds": [], "protectedCount": None, "candidates": [], "candidateBytes": 0,
                 "deletedIds": [], "deletedBytes": 0, "outcomeUnknownIds": [],
                 "skippedDuringApply": 0, "remainingCandidates": 0}
    report = {"repository": REPOSITORY, "mode": "apply" if apply else "dry_run",
              "keepNewestDebugArtifacts": KEEP_NEWEST, "maxDeletions": max_deletions, "artifacts": artifacts}
    candidates = []
    try:
        repository = api.request("repos/" + REPOSITORY)
        if type(repository) is not dict or repository.get("full_name") != REPOSITORY:
            raise CleanupError("repository_mismatch")
        repository_id = _integer(repository.get("id"))
        snapshot = _snapshot(api, repository_id)
        newest, possible = _retention(snapshot, now)
        for item in possible:
            if _completed_debug_run(api, item, repository_id):
                candidates.append(item)
        artifacts.update(observedCount=len(snapshot), observedBytes=sum(item.size for item in snapshot),
                         protectedNewestIds=list(newest), protectedCount=len(snapshot) - len(candidates),
                         candidates=[item.public() for item in candidates], candidateBytes=sum(item.size for item in candidates),
                         remainingCandidates=len(candidates))
    except CleanupError as error:
        artifacts.update(status="blocked", reason=error.code)
    report["ghcr"] = _ghcr_inventory(api)
    if not apply or artifacts["status"] == "blocked":
        return report
    for original in candidates[:max_deletions]:
        try:
            # Relist before each deletion so concurrent expiration/cleanup cannot
            # silently turn a candidate into one of the three retained artifacts.
            current = _snapshot(api, repository_id)
            _newest, still_old = _retention(current, current_time())
            if original not in still_old:
                artifacts["skippedDuringApply"] += 1
                continue
            refreshed = Artifact.parse(api.request(f"{ARTIFACTS_PATH}/{original.id}"), repository_id)
            if refreshed != original or not _completed_debug_run(api, refreshed, repository_id):
                artifacts["skippedDuringApply"] += 1
                continue
            # The artifact/run reads also take time. Re-evaluate expiration at
            # the last local boundary before issuing the irreversible request.
            if original not in _retention(current, current_time())[1]:
                artifacts["skippedDuringApply"] += 1
                continue
            api.request(f"{ARTIFACTS_PATH}/{original.id}", method="DELETE")
            artifacts["deletedIds"].append(original.id)
            artifacts["deletedBytes"] += original.size
        except CleanupError as error:
            artifacts.update(status="blocked", reason=error.code)
            if error.outcome_unknown:
                artifacts["outcomeUnknownIds"].append(original.id)
            break  # No automatic retry, especially after a lost DELETE response.
    artifacts["remainingCandidates"] -= len(artifacts["deletedIds"]) + artifacts["skippedDuringApply"]
    return report


@contextmanager
def _apply_lock():
    path = Path(tempfile.gettempdir()) / f"larenor-github-storage-cleanup-{os.getuid()}.lock"
    descriptor = None
    try:
        descriptor = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1:
            raise CleanupError("cleanup_lock_unavailable")
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    except OSError:
        raise CleanupError("cleanup_lock_unavailable") from None
    finally:
        if descriptor is not None:
            os.close(descriptor)


class _ArgumentParser(argparse.ArgumentParser):
    def error(self, _message):
        raise CleanupError("invalid_arguments")


def main(argv=None):
    parser = _ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="Delete only rechecked old debug artifacts; never delete GHCR versions")
    parser.add_argument("--max-deletions", type=int, default=MAX_DELETIONS, help="Maximum debug deletions this invocation (1..20)")
    try:
        args = parser.parse_args(argv)
        if args.apply:
            with _apply_lock():
                report = cleanup(GitHub(), apply=True, max_deletions=args.max_deletions)
        else:
            report = cleanup(GitHub(), apply=False, max_deletions=args.max_deletions)
        print(json.dumps(report, sort_keys=True, indent=2))
        return 1 if report.get("artifacts", {}).get("status") == "blocked" else 0
    except CleanupError as error:
        print(json.dumps({"repository": REPOSITORY, "status": "blocked", "reason": error.code}))
        return 2 if error.code == "invalid_arguments" else 1


if __name__ == "__main__":
    sys.exit(main())
