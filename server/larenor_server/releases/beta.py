"""Pull verified public beta releases into private Larenor Core storage.

The source is fixed to GitHub's official API and release asset hosts. No CI
credential or inbound access to the home network is needed. GitHub metadata is
only provenance: the packaged Android verifier remains the final executable
signature and certificate authority.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
import hashlib
import http.client
import json
import math
import os
from pathlib import Path
import re
import ssl
import threading
from urllib.parse import quote, urlsplit

from ..errors import ApiError, StartupError
from .models import APPLICATION_ID, MAX_APK_BYTES


OFFICIAL_REPOSITORY = "ersingundem/larenor"
OFFICIAL_WORKFLOW = ".github/workflows/android-build.yml"
API_HOST = "api.github.com"
ASSET_HOSTS = frozenset({"release-assets.githubusercontent.com", "objects.githubusercontent.com"})
SOURCE_FIELDS = {
    "schemaVersion", "channel", "applicationId", "versionCode", "versionName",
    "certificateSha256", "apkSha256", "sizeBytes", "minSdk", "commit",
    "sourceRepository", "sourceWorkflow", "sourceRunId", "sourceRunAttempt",
    "releaseTag", "apkAssetName", "manifestAssetName", "publishedAt",
}
VERSION_BASE = 100_000_000
ANDROID_MAX_VERSION = 2_100_000_000
TAG = re.compile(r"client-beta-v([1-9][0-9]{0,9})\Z")
HEX_40 = re.compile(r"[a-f0-9]{40}\Z")
HEX_64 = re.compile(r"[a-f0-9]{64}\Z")
ASSET_URL = re.compile(
    r"https://api\.github\.com/repos/ersingundem/larenor/releases/assets/([1-9][0-9]*)\Z"
)


def _unverified(code="beta_source_unverified", status=422):
    raise ApiError(code, status)


def _time(value):
    if not isinstance(value, str) or len(value) > 64 or "T" not in value:
        _unverified()
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            raise ValueError()
        return parsed.timestamp()
    except ValueError:
        _unverified()


def _text(value, maximum, pattern=None):
    if (not isinstance(value, str) or not value or len(value) > maximum or
            value.strip() != value or any(ord(char) < 32 or ord(char) == 127 or
                                          0xD800 <= ord(char) <= 0xDFFF for char in value) or
            pattern is not None and pattern.fullmatch(value) is None):
        _unverified()
    return value


def _integer(value, maximum=2**63 - 1):
    if type(value) is not int or not 1 <= value <= maximum:
        _unverified()
    return value


def _canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode() + b"\n"


def _asset_map(raw):
    if not isinstance(raw, list) or len(raw) != 2:
        _unverified()
    result = {}
    for item in raw:
        if not isinstance(item, dict):
            _unverified()
        name = item.get("name")
        url = item.get("url")
        if (not isinstance(name, str) or name in result or
                type(item.get("size")) is not int or not 1 <= item["size"] <= MAX_APK_BYTES or
                not isinstance(item.get("digest"), str) or
                re.fullmatch(r"sha256:[a-f0-9]{64}", item["digest"]) is None or
                not isinstance(url, str) or ASSET_URL.fullmatch(url) is None or
                _integer(item.get("id")) != int(ASSET_URL.fullmatch(url).group(1))):
            _unverified()
        result[name] = item
    return result


@dataclass(frozen=True)
class GitHubBetaObservation:
    manifest: dict
    release_id: int
    apk_asset_url: str
    apk_asset_id: int
    source_run_number: int
    checked_at: float

    def receipt(self):
        return {
            "schemaVersion": 1,
            "channel": "beta",
            "sourceRepository": self.manifest["sourceRepository"],
            "sourceWorkflow": self.manifest["sourceWorkflow"],
            "sourceRunId": self.manifest["sourceRunId"],
            "sourceRunNumber": self.source_run_number,
            "releaseId": self.release_id,
            "releaseTag": self.manifest["releaseTag"],
            "apkAssetId": self.apk_asset_id,
            "versionCode": self.manifest["versionCode"],
            "commit": self.manifest["commit"],
            "apkSha256": self.manifest["apkSha256"],
            "checkedAt": self.checked_at,
        }

    def local_manifest(self):
        value = self.manifest
        version = value["versionCode"]
        return {
            "schemaVersion": 1,
            "applicationId": APPLICATION_ID,
            "versionCode": version,
            "versionName": value["versionName"],
            "certificateSha256": value["certificateSha256"],
            "apkSha256": value["apkSha256"],
            "sizeBytes": value["sizeBytes"],
            "minSdk": value["minSdk"],
            "commit": value["commit"],
            "downloadPath": f"/api/v1/client/releases/{version}/apk",
            "publishedAt": value["publishedAt"],
            "releaseNotes": "Verified Larenor beta from source commit " + value["commit"][:12],
        }


def validate_workflow_run(run, manifest, *, now):
    if (not isinstance(run, dict) or not isinstance(manifest, dict) or
            type(now) not in (int, float) or not math.isfinite(now) or now <= 0):
        _unverified()
    run_number = run.get("run_number")
    if (type(run_number) is not int or run_number < 1 or
            VERSION_BASE + run_number > ANDROID_MAX_VERSION or
            run.get("id") != manifest.get("sourceRunId") or
            run.get("run_attempt") != 1 or
            run.get("event") not in ("push", "workflow_dispatch") or
            run.get("head_branch") != "main" or
            run.get("head_sha") != manifest.get("commit") or
            run.get("path") != OFFICIAL_WORKFLOW or
            run.get("status") != "completed" or run.get("conclusion") != "success" or
            not isinstance(run.get("repository"), dict) or
            run["repository"].get("full_name") != OFFICIAL_REPOSITORY or
            manifest.get("versionCode") != VERSION_BASE + run_number):
        _unverified()
    created = _time(run.get("created_at"))
    started = _time(run.get("run_started_at"))
    updated = _time(run.get("updated_at"))
    published = _time(manifest.get("publishedAt"))
    if (created > started or started > published or published > updated or
            updated > now + 300 or updated - created > 12 * 60 * 60):
        _unverified()
    return run_number


def validate_github_release(release, manifest, *, resolved_commit, now,
                            source_run_number=None, max_age_seconds=14 * 24 * 60 * 60):
    if (not isinstance(release, dict) or not isinstance(manifest, dict) or
            set(manifest) != SOURCE_FIELDS or
            type(now) not in (int, float) or not math.isfinite(now) or now <= 0 or
            type(max_age_seconds) is not int or
            not 3600 <= max_age_seconds <= 90 * 24 * 60 * 60):
        _unverified()
    version = _integer(manifest.get("versionCode"), 2147483647)
    commit = _text(manifest.get("commit"), 40, HEX_40)
    certificate = _text(manifest.get("certificateSha256"), 64, HEX_64)
    apk_hash = _text(manifest.get("apkSha256"), 64, HEX_64)
    tag = f"client-beta-v{version}"
    apk_name = f"Larenor-Client-beta-{version}.apk"
    manifest_name = f"Larenor-Client-beta-{version}.json"
    if (manifest.get("schemaVersion") != 1 or manifest.get("channel") != "beta" or
            manifest.get("applicationId") != APPLICATION_ID or
            manifest.get("sourceRepository") != OFFICIAL_REPOSITORY or
            manifest.get("sourceWorkflow") != OFFICIAL_WORKFLOW or
            manifest.get("sourceRunAttempt") != 1 or
            type(manifest.get("sourceRunId")) is not int or manifest["sourceRunId"] < 1 or
            manifest.get("minSdk") != 26 or type(manifest.get("sizeBytes")) is not int or
            not 1 <= manifest["sizeBytes"] <= MAX_APK_BYTES or
            manifest.get("releaseTag") != tag or manifest.get("apkAssetName") != apk_name or
            manifest.get("manifestAssetName") != manifest_name or
            release.get("tag_name") != tag or release.get("name") != f"Larenor Client beta {version}" or
            release.get("target_commitish") != commit or resolved_commit != commit or
            release.get("draft") is not False or release.get("prerelease") is not True or
            release.get("immutable") is not False or type(release.get("id")) is not int or release["id"] < 1):
        _unverified()
    _text(manifest.get("versionName"), 80)
    manifest_time = _time(manifest.get("publishedAt"))
    release_time = _time(release.get("published_at"))
    if (release_time > now + 300 or manifest_time > release_time or release_time - manifest_time > 600 or
            now - release_time > max_age_seconds):
        _unverified()
    canonical = _canonical(manifest)
    assets = _asset_map(release.get("assets"))
    if set(assets) != {apk_name, manifest_name}:
        _unverified()
    apk = assets[apk_name]
    source = assets[manifest_name]
    if (apk["size"] != manifest["sizeBytes"] or apk["digest"] != "sha256:" + apk_hash or
            source["size"] != len(canonical) or
            source["digest"] != "sha256:" + hashlib.sha256(canonical).hexdigest()):
        _unverified()
    return GitHubBetaObservation(
        manifest={**manifest, "certificateSha256": certificate, "apkSha256": apk_hash},
        release_id=release["id"], apk_asset_url=apk["url"],
        apk_asset_id=apk["id"], source_run_number=(
            _integer(source_run_number, ANDROID_MAX_VERSION - VERSION_BASE)
            if source_run_number is not None else version - VERSION_BASE
        ), checked_at=float(now),
    )


class _HttpsTransport:
    def __init__(self, timeout_seconds=20):
        if type(timeout_seconds) not in (int, float) or not 1 <= timeout_seconds <= 60:
            raise StartupError("invalid_beta_source_settings")
        self.timeout_seconds = float(timeout_seconds)
        self.context = ssl.create_default_context()

    def _open(self, url, *, accept, allow_asset_redirect=False, redirected=False):
        parsed = urlsplit(url)
        allowed = parsed.hostname == API_HOST or redirected and parsed.hostname in ASSET_HOSTS
        if (parsed.scheme != "https" or not allowed or parsed.port not in (None, 443) or
                parsed.username is not None or parsed.password is not None or parsed.fragment or
                not parsed.path.startswith("/") or "\\" in parsed.path or
                any(part in (".", "..") for part in parsed.path.split("/"))):
            _unverified("beta_source_unavailable", 503)
        connection = http.client.HTTPSConnection(
            parsed.hostname, 443, context=self.context, timeout=self.timeout_seconds
        )
        path = parsed.path + (("?" + parsed.query) if parsed.query else "")
        connection.request("GET", path, headers={
            "Accept": accept,
            "User-Agent": "Larenor-Core-beta/1",
            "X-GitHub-Api-Version": "2022-11-28",
            "Connection": "close",
        })
        response = connection.getresponse()
        if response.status in (301, 302, 303, 307, 308):
            location = response.getheader("Location")
            response.read(4097)
            connection.close()
            if redirected or not allow_asset_redirect or not isinstance(location, str):
                _unverified("beta_source_unavailable", 503)
            return self._open(
                location, accept=accept, allow_asset_redirect=True, redirected=True,
            )
        if response.status != 200:
            response.read(4097)
            connection.close()
            _unverified("beta_source_unavailable", 503)
        return connection, response

    def fetch(self, url, *, accept, maximum):
        connection = response = None
        try:
            connection, response = self._open(
                url, accept=accept, allow_asset_redirect=ASSET_URL.fullmatch(url) is not None,
            )
            length = response.getheader("Content-Length")
            if length is not None and (not length.isdigit() or int(length) > maximum):
                _unverified("beta_source_unavailable", 503)
            value = response.read(maximum + 1)
            if not value or len(value) > maximum:
                _unverified("beta_source_unavailable", 503)
            return value
        except ApiError:
            raise
        except (OSError, ssl.SSLError, http.client.HTTPException, ValueError):
            _unverified("beta_source_unavailable", 503)
        finally:
            if connection is not None:
                connection.close()

    def download(self, url, destination: Path, *, expected_size):
        connection = response = None
        try:
            connection, response = self._open(
                url, accept="application/octet-stream", allow_asset_redirect=True,
            )
            length = response.getheader("Content-Length")
            if length is not None and (not length.isdigit() or int(length) != expected_size):
                _unverified("release_verification_failed", 422)
            received = 0
            descriptor = os.open(
                destination,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o600,
            )
            with os.fdopen(descriptor, "wb") as output:
                while chunk := response.read(min(65536, expected_size - received + 1)):
                    received += len(chunk)
                    if received > expected_size:
                        _unverified("release_verification_failed", 422)
                    output.write(chunk)
                output.flush()
                if received != expected_size:
                    _unverified("release_verification_failed", 422)
                os.fsync(output.fileno())
        except ApiError:
            raise
        except (OSError, ssl.SSLError, http.client.HTTPException, ValueError):
            _unverified("beta_source_unavailable", 503)
        finally:
            if connection is not None:
                connection.close()


def _json(raw, maximum):
    if not isinstance(raw, bytes) or not raw or len(raw) > maximum:
        _unverified()
    def unique(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                _unverified()
            value[key] = item
        return value
    try:
        return json.loads(raw, object_pairs_hook=unique,
                          parse_constant=lambda _value: _unverified())
    except (ValueError, UnicodeError, RecursionError):
        _unverified()


class GitHubBetaSource:
    def __init__(self, *, clock, repository=OFFICIAL_REPOSITORY,
                 max_age_seconds=14 * 24 * 60 * 60, transport=None):
        if (repository != OFFICIAL_REPOSITORY or type(max_age_seconds) is not int or
                not 3600 <= max_age_seconds <= 90 * 24 * 60 * 60):
            raise StartupError("invalid_beta_source_settings")
        self.clock = clock
        self.repository = repository
        self.max_age_seconds = max_age_seconds
        self.transport = transport or _HttpsTransport()

    def observe(self):
        api = f"https://{API_HOST}/repos/{self.repository}/releases?per_page=20"
        releases = _json(self.transport.fetch(api, accept="application/vnd.github+json", maximum=1024 * 1024), 1024 * 1024)
        if not isinstance(releases, list) or len(releases) > 20:
            _unverified()
        candidates = {}
        for release in releases:
            tag = release.get("tag_name") if isinstance(release, dict) else None
            match = TAG.fullmatch(tag) if isinstance(tag, str) else None
            if match is None:
                continue
            version = int(match.group(1))
            if version in candidates:
                _unverified()
            candidates[version] = release
        if not candidates:
            _unverified("beta_source_unavailable", 503)
        release = candidates[max(candidates)]
        tag = release["tag_name"]
        version = int(TAG.fullmatch(tag).group(1))
        assets = release.get("assets")
        if not isinstance(assets, list):
            _unverified()
        name = f"Larenor-Client-beta-{version}.json"
        matches = [item for item in assets if isinstance(item, dict) and item.get("name") == name]
        if len(matches) != 1 or not isinstance(matches[0].get("url"), str):
            _unverified()
        raw = self.transport.fetch(matches[0]["url"], accept="application/octet-stream", maximum=128 * 1024)
        manifest = _json(raw, 128 * 1024)
        if raw != _canonical(manifest):
            _unverified()
        ref_url = f"https://{API_HOST}/repos/{self.repository}/git/ref/tags/{quote(tag, safe='')}"
        ref = _json(self.transport.fetch(ref_url, accept="application/vnd.github+json", maximum=64 * 1024), 64 * 1024)
        try:
            if set(ref["object"]) < {"type", "sha"} or ref["object"]["type"] != "commit":
                _unverified()
            commit = ref["object"]["sha"]
        except (KeyError, TypeError):
            _unverified()
        run_url = (
            f"https://{API_HOST}/repos/{self.repository}/actions/runs/"
            f"{manifest.get('sourceRunId')}/attempts/{manifest.get('sourceRunAttempt')}"
        )
        workflow_run = _json(
            self.transport.fetch(
                run_url, accept="application/vnd.github+json", maximum=256 * 1024,
            ),
            256 * 1024,
        )
        now = self.clock()
        run_number = validate_workflow_run(workflow_run, manifest, now=now)
        return validate_github_release(
            release, manifest, resolved_commit=commit, now=now,
            source_run_number=run_number,
            max_age_seconds=self.max_age_seconds,
        )

    def download_apk(self, observation, destination):
        if not isinstance(observation, GitHubBetaObservation):
            _unverified()
        self.transport.download(
            observation.apk_asset_url, destination,
            expected_size=observation.manifest["sizeBytes"],
        )


class BetaReleaseSynchronizer:
    def __init__(self, service, source, *, clock, poll_seconds=900):
        if type(poll_seconds) is not int or not 60 <= poll_seconds <= 3600:
            raise StartupError("invalid_beta_source_settings")
        self.service = service
        self.source = source
        self.clock = clock
        self.poll_seconds = poll_seconds
        self._lock = threading.Lock()
        self._last_check = None

    def refresh(self):
        with self._lock:
            now = self.clock()
            if type(now) not in (int, float):
                _unverified("beta_source_stale", 503)
            if self._last_check is not None:
                if now < self._last_check:
                    _unverified("beta_source_stale", 503)
                if now - self._last_check < self.poll_seconds:
                    return self.service.latest("beta")
            observation = self.source.observe()
            if not isinstance(observation, GitHubBetaObservation) or observation.checked_at != float(now):
                _unverified()
            current = self.service.latest("beta")
            if current is not None:
                if observation.manifest["versionCode"] < current["versionCode"]:
                    _unverified("beta_source_stale", 503)
                if observation.manifest["versionCode"] == current["versionCode"]:
                    if any(observation.manifest[key] != current[key] for key in (
                            "versionName", "certificateSha256", "apkSha256", "sizeBytes", "minSdk", "commit")):
                        _unverified("beta_source_unverified", 422)
                    self._last_check = float(now)
                    return current
            result = self.service.ingest_beta(
                observation.local_manifest(), observation.receipt(),
                lambda path: self.source.download_apk(observation, path),
            )
            self._last_check = float(now)
            return result
