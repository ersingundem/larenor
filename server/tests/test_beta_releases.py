from dataclasses import dataclass
import hashlib
import json
import os
import uuid

import pytest
from fastapi.testclient import TestClient

from conftest import Clock, auth, ready
from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.errors import ApiError
from larenor_server.errors import StartupError
from larenor_server.releases import ReleaseSettings, ReleaseService, build_release_router
from larenor_server.releases import store as release_store
from larenor_server.releases.beta import (
    BetaReleaseSynchronizer,
    GitHubBetaObservation,
    GitHubBetaSource,
    _HttpsTransport,
    validate_github_release,
    validate_workflow_run,
)


APK = b"bounded synthetic signed beta"
DIGEST = hashlib.sha256(APK).hexdigest()
CERT = "b" * 64
COMMIT = "a" * 40
VERSION = 100000123
NOW = 1789128000.0
PREFIX = "/api/v1/client/releases"


def source_manifest(version=VERSION, **changes):
    result = {
        "schemaVersion": 1,
        "channel": "beta",
        "applicationId": "com.ersingundem.larenor",
        "versionCode": version,
        "versionName": "1.0.0",
        "certificateSha256": CERT,
        "apkSha256": DIGEST,
        "sizeBytes": len(APK),
        "minSdk": 26,
        "commit": COMMIT,
        "sourceRepository": "ersingundem/larenor",
        "sourceWorkflow": ".github/workflows/android-build.yml",
        "sourceRunId": 987654321,
        "sourceRunAttempt": 1,
        "releaseTag": f"client-beta-v{version}",
        "apkAssetName": f"Larenor-Client-beta-{version}.apk",
        "manifestAssetName": f"Larenor-Client-beta-{version}.json",
        "publishedAt": "2026-09-11T12:00:00Z",
    }
    result.update(changes)
    return result


def release(manifest=None, **changes):
    manifest = manifest or source_manifest()
    raw = json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode() + b"\n"
    result = {
        "id": 77,
        "tag_name": manifest["releaseTag"],
        "name": f"Larenor Client beta {manifest['versionCode']}",
        "target_commitish": manifest["commit"],
        "draft": False,
        "prerelease": True,
        "immutable": False,
        "published_at": "2026-09-11T12:00:05Z",
        "assets": [
            {
                "id": 771,
                "name": manifest["apkAssetName"],
                "size": len(APK),
                "digest": "sha256:" + DIGEST,
                "url": "https://api.github.com/repos/ersingundem/larenor/releases/assets/771",
            },
            {
                "id": 772,
                "name": manifest["manifestAssetName"],
                "size": len(raw),
                "digest": "sha256:" + hashlib.sha256(raw).hexdigest(),
                "url": "https://api.github.com/repos/ersingundem/larenor/releases/assets/772",
            },
        ],
    }
    result.update(changes)
    return result


def workflow_run(manifest=None, **changes):
    manifest = manifest or source_manifest()
    result = {
        "id": manifest["sourceRunId"],
        "run_number": manifest["versionCode"] - 100_000_000,
        "run_attempt": 1,
        "event": "push",
        "head_branch": "main",
        "head_sha": manifest["commit"],
        "path": ".github/workflows/android-build.yml",
        "status": "completed",
        "conclusion": "success",
        "created_at": "2026-09-11T11:00:00Z",
        "run_started_at": "2026-09-11T11:01:00Z",
        "updated_at": "2026-09-11T12:00:00Z",
        "repository": {"full_name": "ersingundem/larenor"},
    }
    result.update(changes)
    return result


class Verifier:
    def __init__(self):
        self.calls = 0
        self.version = VERSION
        self.digest = DIGEST

    def verify(self, path):
        self.calls += 1
        assert hashlib.sha256(path.read_bytes()).hexdigest() == self.digest
        return {
            "schemaVersion": 1,
            "verified": True,
            "applicationId": "com.ersingundem.larenor",
            "versionCode": self.version,
            "versionName": "1.0.0",
            "minSdk": 26,
            "certificateSha256": CERT,
            "debuggable": False,
        }


class Source:
    def __init__(self, observation):
        self.observation = observation
        self.observations = 0
        self.downloads = 0
        self.failure = None

    def observe(self):
        self.observations += 1
        if self.failure:
            raise self.failure
        return self.observation

    def download_apk(self, observation, destination):
        assert observation is self.observation
        self.downloads += 1
        destination.write_bytes(APK)
        destination.chmod(0o600)


class Transport:
    def __init__(self, releases, manifest, run=None):
        self.releases = releases
        self.manifest = manifest
        self.run = run or workflow_run(manifest)
        self.fetches = []
        self.downloads = []

    def fetch(self, url, *, accept, maximum):
        self.fetches.append((url, accept, maximum))
        if url.endswith("/releases?per_page=20"):
            return json.dumps(self.releases, separators=(",", ":")).encode()
        if url.endswith("/releases/assets/772"):
            return json.dumps(self.manifest, sort_keys=True, separators=(",", ":")).encode() + b"\n"
        if url.endswith("/git/ref/tags/client-beta-v100000123"):
            return json.dumps({"object": {"type": "commit", "sha": COMMIT}}).encode()
        if url.endswith("/actions/runs/987654321/attempts/1"):
            return json.dumps(self.run, separators=(",", ":")).encode()
        raise AssertionError(url)

    def download(self, url, destination, *, expected_size):
        self.downloads.append((url, destination, expected_size))
        destination.write_bytes(APK)
        destination.chmod(0o600)


@dataclass
class Harness:
    app: object
    client: TestClient
    clock: Clock
    service: ReleaseService
    verifier: Verifier
    source: Source
    synchronizer: BetaReleaseSynchronizer


@pytest.fixture
def beta_server(tmp_path):
    root = tmp_path.resolve()
    clock = Clock(NOW)
    verifier = Verifier()
    service = ReleaseService(
        ReleaseSettings(root / "releases", signer_sha256=CERT, publisher_token="lpub_" + "P" * 43, clock=clock),
        verifier=verifier,
    )
    manifest = source_manifest()
    observation = validate_github_release(release(manifest), manifest, resolved_commit=COMMIT, now=clock())
    source = Source(observation)
    sync = BetaReleaseSynchronizer(service, source, clock=clock, poll_seconds=300)
    settings = Settings(root / "data", root / "secrets/vault.key", clock=clock,
                        login_ip_limit=100, login_account_limit=100, login_global_limit=100)
    app = create_app(settings, routers=(build_release_router(service, beta=sync),))
    with TestClient(app) as client:
        yield Harness(app, client, clock, service, verifier, source, sync)


def test_authenticated_beta_read_pulls_once_verifies_and_publishes_locally(beta_server):
    harness = beta_server
    pair = ready((harness.app, harness.client, harness.app.state.core.settings, harness.clock))
    assert harness.client.get(f"{PREFIX}/latest?platform=android&channel=beta").status_code == 401
    response = harness.client.get(f"{PREFIX}/latest?platform=android&channel=beta", headers=auth(pair))
    assert response.status_code == 200
    body = response.json()
    assert body == {
        "schemaVersion": 1,
        "applicationId": "com.ersingundem.larenor",
        "versionCode": VERSION,
        "versionName": "1.0.0",
        "certificateSha256": CERT,
        "apkSha256": DIGEST,
        "sizeBytes": len(APK),
        "minSdk": 26,
        "commit": COMMIT,
        "downloadPath": f"{PREFIX}/{VERSION}/apk",
        "publishedAt": "2026-09-11T12:00:00Z",
        "releaseNotes": "Verified Larenor beta from source commit " + COMMIT[:12],
    }
    assert harness.client.get(f"{PREFIX}/latest?platform=android&channel=stable", headers=auth(pair)).status_code == 204
    assert harness.client.get(body["downloadPath"], headers=auth(pair)).content == APK
    assert (harness.source.observations, harness.source.downloads, harness.verifier.calls) == (1, 1, 1)
    again = harness.client.get(f"{PREFIX}/latest?platform=android&channel=beta", headers=auth(pair))
    assert again.json() == body
    assert (harness.source.observations, harness.source.downloads, harness.verifier.calls) == (1, 1, 1)


def test_github_source_uses_only_exact_public_api_asset_and_tag_contract(tmp_path):
    manifest = source_manifest()
    transport = Transport([{"tag_name": "unrelated"}, release(manifest)], manifest)
    source = GitHubBetaSource(clock=lambda: NOW, transport=transport)

    observation = source.observe()
    destination = tmp_path / "client.apk"
    source.download_apk(observation, destination)

    assert observation.manifest == manifest
    assert transport.fetches == [
        ("https://api.github.com/repos/ersingundem/larenor/releases?per_page=20",
         "application/vnd.github+json", 1024 * 1024),
        ("https://api.github.com/repos/ersingundem/larenor/releases/assets/772",
         "application/octet-stream", 128 * 1024),
        ("https://api.github.com/repos/ersingundem/larenor/git/ref/tags/client-beta-v100000123",
         "application/vnd.github+json", 64 * 1024),
        ("https://api.github.com/repos/ersingundem/larenor/actions/runs/987654321/attempts/1",
         "application/vnd.github+json", 256 * 1024),
    ]
    assert [(url, expected) for url, _path, expected in transport.downloads] == [
        ("https://api.github.com/repos/ersingundem/larenor/releases/assets/771", len(APK)),
    ]
    assert destination.read_bytes() == APK
    assert destination.stat().st_mode & 0o777 == 0o600


@pytest.mark.parametrize("damage", [
    {"immutable": True}, {"draft": True}, {"prerelease": False},
    {"target_commitish": "c" * 40}, {"tag_name": "client-beta-v100000122"},
    {"published_at": "2026-08-01T00:00:00Z"},
])
def test_github_release_identity_or_staleness_is_rejected(damage):
    with pytest.raises(ApiError, match="beta_source_unverified"):
        validate_github_release(release(**damage), source_manifest(), resolved_commit=COMMIT, now=NOW)


def test_manifest_asset_shape_digest_and_source_are_exact():
    manifest = source_manifest()
    cases = [
        source_manifest(sourceRepository="attacker/repository"),
        source_manifest(sourceWorkflow=".github/workflows/other.yml"),
        source_manifest(sourceRunAttempt=2),
        source_manifest(apkSha256="f" * 64),
        source_manifest(extra="private"),
    ]
    for changed in cases:
        with pytest.raises(ApiError, match="beta_source_unverified"):
            validate_github_release(release(changed), changed, resolved_commit=COMMIT, now=NOW)
    duplicate = release(manifest)
    duplicate["assets"] = [duplicate["assets"][0], duplicate["assets"][0]]
    with pytest.raises(ApiError, match="beta_source_unverified"):
        validate_github_release(duplicate, manifest, resolved_commit=COMMIT, now=NOW)


@pytest.mark.parametrize("damage", [
    {"id": 1}, {"run_number": 124}, {"run_attempt": 2}, {"event": "pull_request"},
    {"head_branch": "feature"}, {"head_sha": "c" * 40},
    {"path": ".github/workflows/other.yml"}, {"status": "in_progress"},
    {"conclusion": "failure"}, {"repository": {"full_name": "attacker/repository"}},
    {"updated_at": "2026-09-12T02:00:00Z"},
])
def test_workflow_run_provenance_is_exact_bounded_and_successful(damage):
    with pytest.raises(ApiError, match="beta_source_unverified"):
        validate_workflow_run(workflow_run(**damage), source_manifest(), now=NOW)


def test_workflow_dispatch_from_main_is_valid_provenance():
    assert validate_workflow_run(
        workflow_run(event="workflow_dispatch"), source_manifest(), now=NOW,
    ) == 123


class HttpResponse:
    def __init__(self, status, *, location=None, body=b"bounded"):
        self.status = status
        self.location = location
        self.body = body

    def getheader(self, name):
        if name == "Location":
            return self.location
        if name == "Content-Length":
            return str(len(self.body))
        return None

    def read(self, maximum):
        return self.body[:maximum]


class HttpConnection:
    def __init__(self, response):
        self.response = response
        self.closed = False

    def request(self, *_args, **_kwargs):
        return None

    def getresponse(self):
        return self.response

    def close(self):
        self.closed = True


@pytest.mark.parametrize("response", [
    HttpResponse(403, body=b"rate limit detail that must not escape"),
    HttpResponse(302, location="https://release-assets.githubusercontent.com/unexpected"),
])
def test_workflow_provenance_transport_rejects_rate_limit_and_redirect(monkeypatch, response):
    connection = HttpConnection(response)
    monkeypatch.setattr("larenor_server.releases.beta.http.client.HTTPSConnection",
                        lambda *_args, **_kwargs: connection)
    transport = _HttpsTransport(timeout_seconds=1)
    with pytest.raises(ApiError, match="beta_source_unavailable") as error:
        transport.fetch(
            "https://api.github.com/repos/ersingundem/larenor/actions/runs/987654321/attempts/1",
            accept="application/vnd.github+json", maximum=256 * 1024,
        )
    assert "rate limit" not in str(error.value)
    assert connection.closed


def test_beta_transport_rejects_an_extra_host_without_opening_a_connection(monkeypatch):
    monkeypatch.setattr(
        "larenor_server.releases.beta.http.client.HTTPSConnection",
        lambda *_args, **_kwargs: pytest.fail("unexpected network attempt"),
    )
    with pytest.raises(ApiError, match="beta_source_unavailable"):
        _HttpsTransport(timeout_seconds=1).fetch(
            "https://attacker.invalid/releases", accept="application/vnd.github+json",
            maximum=1024,
        )


def test_downgrade_changed_same_version_clock_rollback_and_source_failure_fail_closed(beta_server):
    harness = beta_server
    harness.synchronizer.refresh()
    harness.clock.now += 301
    older = source_manifest(VERSION - 1)
    harness.source.observation = validate_github_release(release(older), older, resolved_commit=COMMIT, now=harness.clock())
    with pytest.raises(ApiError, match="beta_source_stale"):
        harness.synchronizer.refresh()
    assert harness.service.latest("beta")["versionCode"] == VERSION
    harness.source.observation = validate_github_release(release(), source_manifest(), resolved_commit=COMMIT, now=harness.clock())
    harness.clock.now = NOW - 10
    with pytest.raises(ApiError, match="beta_source_stale"):
        harness.synchronizer.refresh()
    harness.clock.now += 400
    harness.source.failure = ApiError("beta_source_unavailable", 503)
    with pytest.raises(ApiError, match="beta_source_unavailable"):
        harness.synchronizer.refresh()
    assert harness.source.downloads == 1


def test_download_hash_or_apk_identity_failure_never_advances_beta(beta_server):
    harness = beta_server
    def tamper(_observation, destination):
        destination.write_bytes(b"tampered")
        destination.chmod(0o600)
    harness.source.download_apk = tamper
    with pytest.raises(ApiError, match="release_verification_failed"):
        harness.synchronizer.refresh()
    assert harness.service.latest("beta") is None
    assert not list(harness.service.staging.iterdir())
    assert harness.verifier.calls == 0


def test_nonfinite_receipt_is_rejected_before_download(beta_server):
    harness = beta_server
    receipt = harness.source.observation.receipt()
    receipt["checkedAt"] = float("nan")
    called = False

    def writer(_path):
        nonlocal called
        called = True

    with pytest.raises(ApiError, match="release_verification_failed"):
        harness.service.ingest_beta(harness.source.observation.local_manifest(), receipt, writer)
    assert not called
    assert harness.service.latest("beta") is None


def test_restart_rejects_changed_beta_source_receipt(beta_server):
    harness = beta_server
    harness.synchronizer.refresh()
    receipt_path = harness.service.beta_sources / f"{VERSION}.json"
    receipt = json.loads(receipt_path.read_bytes())
    receipt["sourceRepository"] = "attacker/repository"
    receipt_path.write_text(json.dumps(receipt))

    with pytest.raises(StartupError, match="invalid_release_storage"):
        ReleaseService(harness.service.settings, verifier=harness.verifier)


def test_crash_after_beta_rename_recovers_only_beta_and_never_promotes_stable(beta_server, monkeypatch):
    import larenor_server.releases.store as store

    harness = beta_server
    original_write = store._json_write
    source_receipt = harness.service.beta_sources / f"{VERSION}.json"

    def interrupted(path, value):
        if path == source_receipt:
            raise OSError("synthetic crash before external beta receipt")
        original_write(path, value)

    monkeypatch.setattr(store, "_json_write", interrupted)
    with pytest.raises(OSError, match="synthetic crash"):
        harness.synchronizer.refresh()

    version_dir = harness.service.versions / str(VERSION)
    assert (version_dir / "beta-intent.json").exists()
    assert not harness.service.index.exists()
    assert not harness.service.beta_index.exists()
    assert not source_receipt.exists()
    assert not list(harness.service.staging.iterdir())

    monkeypatch.setattr(store, "_json_write", original_write)
    recovered = ReleaseService(harness.service.settings, verifier=harness.verifier)
    assert recovered.latest("stable") is None
    assert recovered.latest("beta")["versionCode"] == VERSION
    assert json.loads(source_receipt.read_bytes()) == json.loads(
        (version_dir / "beta-intent.json").read_bytes()
    )


def _private_write(path, value):
    path.write_bytes(value)
    path.chmod(0o600)


def _orphan_receipt(service, version):
    receipt = json.loads((service.beta_sources / f"{VERSION}.json").read_bytes())
    receipt.update({
        "sourceRunNumber": version - 100_000_000,
        "releaseTag": f"client-beta-v{version}",
        "versionCode": version,
    })
    return json.dumps(receipt, separators=(",", ":")).encode()


def test_restart_cleans_bounded_known_beta_artifacts_without_changing_serving(beta_server):
    harness = beta_server
    harness.synchronizer.refresh()
    orphan_version = VERSION - 1
    orphan = harness.service.beta_sources / f"{orphan_version}.json"
    temporary = harness.service.beta_sources / f".tmp.{uuid.uuid4()}"
    _private_write(orphan, _orphan_receipt(harness.service, orphan_version))
    _private_write(temporary, b'{"interrupted":')

    recovered = ReleaseService(harness.service.settings, verifier=harness.verifier)

    assert not orphan.exists()
    assert not temporary.exists()
    assert recovered.latest("stable") is None
    assert recovered.latest("beta")["versionCode"] == VERSION
    manifest, stream = recovered.open_apk(VERSION)
    with stream:
        assert manifest["apkSha256"] == DIGEST
        assert stream.read() == APK


@pytest.mark.parametrize("name,value", [
    ("foreign.json", b"{}"),
    (".tmp.not-a-managed-uuid", b"partial"),
    (f"{VERSION - 1}.json", b'{"schemaVersion":1}'),
])
def test_restart_fails_closed_before_cleaning_when_beta_source_inventory_is_suspicious(
        beta_server, name, value):
    harness = beta_server
    harness.synchronizer.refresh()
    valid_orphan_version = VERSION - 2
    valid_orphan = harness.service.beta_sources / f"{valid_orphan_version}.json"
    temporary = harness.service.beta_sources / f".tmp.{uuid.uuid4()}"
    suspicious = harness.service.beta_sources / name
    _private_write(valid_orphan, _orphan_receipt(harness.service, valid_orphan_version))
    _private_write(temporary, b"partial")
    _private_write(suspicious, value)

    with pytest.raises(StartupError, match="invalid_release_storage"):
        ReleaseService(harness.service.settings, verifier=harness.verifier)

    assert valid_orphan.exists()
    assert temporary.exists()
    assert suspicious.exists()
    assert harness.service.latest("beta")["versionCode"] == VERSION


def test_restart_bounds_beta_source_inventory_before_cleaning(beta_server):
    harness = beta_server
    temporary_files = []
    for _ in range(release_store.MAX_BETA_SOURCE_RECOVERY_ENTRIES + 1):
        temporary = harness.service.beta_sources / f".tmp.{uuid.uuid4()}"
        _private_write(temporary, b"partial")
        temporary_files.append(temporary)

    with pytest.raises(StartupError, match="invalid_release_storage"):
        ReleaseService(harness.service.settings, verifier=harness.verifier)

    assert all(path.exists() for path in temporary_files)


@pytest.mark.parametrize("damage", [
    "missing-beta-version",
    "malformed-beta-index",
    "missing-stable-version",
    "malformed-stable-index",
    "corrupt-receipt",
])
def test_restart_validates_active_beta_before_cleaning_any_recovery_evidence(
        beta_server, damage):
    harness = beta_server
    harness.synchronizer.refresh()
    orphan_version = VERSION - 1
    orphan = harness.service.beta_sources / f"{orphan_version}.json"
    temporary = harness.service.beta_sources / f".tmp.{uuid.uuid4()}"
    active_receipt = harness.service.beta_sources / f"{VERSION}.json"
    _private_write(orphan, _orphan_receipt(harness.service, orphan_version))
    _private_write(temporary, b"interrupted")
    if damage == "missing-beta-version":
        harness.service._remove_directory(harness.service.versions / str(VERSION))
    elif damage == "malformed-beta-index":
        harness.service.beta_index.write_text("{}")
        harness.service.beta_index.chmod(0o600)
    elif damage == "missing-stable-version":
        harness.service.index.write_text(json.dumps({"versionCode": VERSION - 1}))
        harness.service.index.chmod(0o600)
    elif damage == "malformed-stable-index":
        harness.service.index.write_text("{}")
        harness.service.index.chmod(0o600)
    else:
        receipt = json.loads(active_receipt.read_bytes())
        receipt["apkSha256"] = "f" * 64
        active_receipt.write_text(json.dumps(receipt))
        active_receipt.chmod(0o600)

    with pytest.raises(StartupError):
        ReleaseService(harness.service.settings, verifier=harness.verifier)

    assert orphan.exists()
    assert temporary.exists()
    assert active_receipt.exists()


@pytest.mark.parametrize("kind", ["public-mode", "directory", "symlink", "hardlink"])
def test_restart_rejects_unsafe_beta_source_files_without_cleaning(kind, beta_server):
    harness = beta_server
    harness.synchronizer.refresh()
    orphan_version = VERSION - 1
    suspicious = harness.service.beta_sources / f"{orphan_version}.json"
    temporary = harness.service.beta_sources / f".tmp.{uuid.uuid4()}"
    _private_write(temporary, b"interrupted")
    if kind == "directory":
        suspicious.mkdir(mode=0o700)
    elif kind == "symlink":
        suspicious.symlink_to(harness.service.beta_sources / f"{VERSION}.json")
    else:
        _private_write(suspicious, _orphan_receipt(harness.service, orphan_version))
        if kind == "public-mode":
            suspicious.chmod(0o644)
        else:
            linked = harness.service.beta_sources / f"{orphan_version - 1}.json"
            os.link(suspicious, linked)

    with pytest.raises(StartupError, match="invalid_release_storage"):
        ReleaseService(harness.service.settings, verifier=harness.verifier)

    assert temporary.exists()
    assert suspicious.exists()


def test_same_size_beta_apk_tamper_fails_recovery_and_open(beta_server):
    harness = beta_server
    harness.synchronizer.refresh()
    orphan_version = VERSION - 1
    orphan = harness.service.beta_sources / f"{orphan_version}.json"
    temporary = harness.service.beta_sources / f".tmp.{uuid.uuid4()}"
    _private_write(orphan, _orphan_receipt(harness.service, orphan_version))
    _private_write(temporary, b"interrupted")
    apk = harness.service.versions / str(VERSION) / "client.apk"
    apk.write_bytes(b"x" * len(APK))
    apk.chmod(0o600)

    with pytest.raises(ApiError, match="server_unavailable"):
        harness.service.open_apk(VERSION)
    with pytest.raises(StartupError, match="invalid_release_storage"):
        ReleaseService(harness.service.settings, verifier=harness.verifier)
    assert orphan.exists()
    assert temporary.exists()
