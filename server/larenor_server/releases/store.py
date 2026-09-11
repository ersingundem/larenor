import asyncio
from contextlib import contextmanager
import fcntl
import hashlib
import hmac
import json
import math
import os
from pathlib import Path
import re
import stat
import uuid

from starlette.requests import ClientDisconnect, Request

from ..errors import ApiError, StartupError
from ..files import checked_path, private_create, private_directory, private_read, sync_directory
from .models import (MAX_METADATA_BYTES, PUBLISH_TOKEN, UPLOAD_ID, VERSION,
                     ReleaseSettings, validate_manifest, version_number)
from .verifier import ApkVerifier, compare_verified


MAX_BETA_SOURCE_RECOVERY_ENTRIES = 64
_COMMIT_SHA = re.compile(r"[a-f0-9]{40}\Z")
_APK_SHA256 = re.compile(r"[a-f0-9]{64}\Z")


def _json_read(path: Path) -> dict:
    try:
        value = json.loads(private_read(path, MAX_METADATA_BYTES))
        if not isinstance(value, dict):
            raise ValueError()
        return value
    except (OSError, ValueError, StartupError):
        raise ApiError("server_unavailable", 503) from None


def _json_write(path: Path, value: dict) -> None:
    temporary = path.parent / f".tmp.{uuid.uuid4()}"
    try:
        private_create(temporary, json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode())
        os.replace(temporary, path)
        sync_directory(path.parent)
    finally:
        temporary.unlink(missing_ok=True)


def _private_open(path: Path):
    checked_path(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    stream = os.fdopen(fd, "rb")
    info = os.fstat(stream.fileno())
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or
            stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
        stream.close()
        raise ApiError("server_unavailable", 503)
    return stream


def _valid_beta_receipt(receipt: object, manifest: dict) -> bool:
    expected = {
        "schemaVersion", "channel", "sourceRepository", "sourceWorkflow",
        "sourceRunId", "sourceRunNumber", "releaseId", "releaseTag", "apkAssetId", "versionCode", "commit",
        "apkSha256", "checkedAt",
    }
    checked_at = receipt.get("checkedAt") if isinstance(receipt, dict) else None
    return bool(
        isinstance(receipt, dict) and set(receipt) == expected and
        receipt.get("schemaVersion") == 1 and receipt.get("channel") == "beta" and
        receipt.get("sourceRepository") == "ersingundem/larenor" and
        receipt.get("sourceWorkflow") == ".github/workflows/android-build.yml" and
        type(receipt.get("sourceRunId")) is int and receipt["sourceRunId"] >= 1 and
        type(receipt.get("sourceRunNumber")) is int and receipt["sourceRunNumber"] >= 1 and
        receipt["versionCode"] == 100_000_000 + receipt["sourceRunNumber"] and
        type(receipt.get("releaseId")) is int and receipt["releaseId"] >= 1 and
        type(receipt.get("apkAssetId")) is int and receipt["apkAssetId"] >= 1 and
        type(checked_at) in (int, float) and math.isfinite(checked_at) and checked_at > 0 and
        isinstance(receipt.get("commit"), str) and _COMMIT_SHA.fullmatch(receipt["commit"]) and
        isinstance(receipt.get("apkSha256"), str) and _APK_SHA256.fullmatch(receipt["apkSha256"]) and
        receipt.get("releaseTag") == f"client-beta-v{manifest['versionCode']}" and
        receipt.get("versionCode") == manifest["versionCode"] and
        receipt.get("commit") == manifest["commit"] and
        receipt.get("apkSha256") == manifest["apkSha256"]
    )


class ReleaseService:
    def __init__(self, settings: ReleaseSettings, *, verifier: ApkVerifier | None):
        self.settings = settings
        self.verifier = verifier
        self.root = settings.data_dir
        self.staging = self.root / "staging"
        self.versions = self.root / "versions"
        self.beta_sources = self.root / "beta-sources"
        self.trash = self.root / "trash"
        for directory in (self.root, self.staging, self.versions, self.beta_sources, self.trash):
            private_directory(directory)
        self.lock_file = self.root / ".publish.lock"
        try:
            private_create(self.lock_file, b"")
        except FileExistsError:
            private_read(self.lock_file, 0)
        self.index = self.root / "latest.json"
        self.beta_index = self.root / "latest-beta.json"
        with self._locked():
            self._recover()

    @contextmanager
    def _locked(self):
        with _private_open(self.lock_file) as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            yield

    @contextmanager
    def _upload_lock(self, directory: Path):
        try:
            lock = _private_open(directory / ".lock")
        except FileNotFoundError:
            raise ApiError("release_upload_expired", 409) from None
        with lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise ApiError("release_conflict", 409) from None
            yield

    def authorize_publish(self, token: str | None) -> None:
        expected = self.settings.publisher_token
        if self.settings.publisher_token_file is not None:
            try:
                expected = private_read(self.settings.publisher_token_file, 49).decode("ascii").rstrip("\n")
            except (OSError, UnicodeError, StartupError):
                raise ApiError("server_unavailable", 503) from None
        if expected is None:
            raise ApiError("server_unavailable", 503)
        if not PUBLISH_TOKEN.fullmatch(expected):
            raise ApiError("server_unavailable", 503)
        candidate = token if isinstance(token, str) and PUBLISH_TOKEN.fullmatch(token) else ""
        if not hmac.compare_digest(hashlib.sha256(candidate.encode()).digest(), hashlib.sha256(expected.encode()).digest()):
            raise ApiError("invalid_publish_credential", 401)

    def _manifest(self, version: int) -> dict:
        try:
            manifest = validate_manifest(_json_read(self.versions / str(version) / "manifest.json"))
            if manifest["versionCode"] != version or manifest["certificateSha256"] != self.settings.signer_sha256:
                raise ValueError()
            return manifest
        except (ApiError, ValueError):
            raise ApiError("server_unavailable", 503) from None

    def _published(self) -> list[int]:
        result = []
        for path in self.versions.iterdir():
            if VERSION.fullmatch(path.name):
                private_directory(path)
                result.append(version_number(int(path.name)))
        return sorted(result)

    def _clean_beta_source_artifacts(self, published: list[int]) -> None:
        """Remove only bounded, authenticated leftovers from interrupted writes.

        The caller holds the process-shared release lock. The private directory
        may contain current receipt copies, valid receipts orphaned by retention,
        or the exact temporary names created by ``_json_write``. Anything else
        makes startup fail before cleanup begins.
        """
        try:
            entries = []
            for path in self.beta_sources.iterdir():
                entries.append(path)
                if len(entries) > MAX_BETA_SOURCE_RECOVERY_ENTRIES:
                    raise StartupError("invalid_release_storage")
        except OSError:
            raise StartupError("invalid_release_storage") from None

        published_set = set(published)
        cleanup = []
        try:
            for path in entries:
                raw = private_read(path, MAX_METADATA_BYTES)
                if path.name.startswith(".tmp."):
                    if not UPLOAD_ID.fullmatch(path.name.removeprefix(".tmp.")):
                        raise StartupError("invalid_release_storage")
                    cleanup.append(path)
                    continue
                if not path.name.endswith(".json") or not VERSION.fullmatch(path.name[:-5]):
                    raise StartupError("invalid_release_storage")
                version = version_number(int(path.name[:-5]))
                if version in published_set:
                    continue
                receipt = json.loads(raw)
                if not isinstance(receipt, dict):
                    raise StartupError("invalid_release_storage")
                synthetic_manifest = {
                    "versionCode": version,
                    "commit": receipt.get("commit"),
                    "apkSha256": receipt.get("apkSha256"),
                }
                if not _valid_beta_receipt(receipt, synthetic_manifest):
                    raise StartupError("invalid_release_storage")
                cleanup.append(path)
        except (ApiError, OSError, UnicodeError, ValueError, StartupError):
            raise StartupError("invalid_release_storage") from None

        try:
            for path in cleanup:
                path.unlink()
            if cleanup:
                sync_directory(self.beta_sources)
        except OSError:
            raise StartupError("invalid_release_storage") from None

    def _recover(self) -> None:
        for abandoned in self.trash.iterdir():
            if UPLOAD_ID.fullmatch(abandoned.name):
                self._remove_directory(abandoned)
        for partial in self.staging.iterdir():
            if not UPLOAD_ID.fullmatch(partial.name):
                continue
            if not (partial / "request.json").exists():
                # Creation holds the same process-shared lock. This directory
                # can only be an interrupted initialization, not a live upload.
                self._remove_directory(partial)
            elif ((partial / "client.part").exists() or
                  (partial / "client.apk").exists() and not (partial / "upload.json").exists()):
                # Another worker may still be streaming this file. A free
                # upload lock proves the transfer ended without committing its
                # receipt; its bytes must not occupy a resumable reservation.
                try:
                    with self._upload_lock(partial):
                        self._remove_directory(partial)
                except ApiError as error:
                    if error.code != "release_conflict":
                        raise
        published = self._published()
        self._clean_beta_source_artifacts(published)
        beta_intents = {}
        for version in published:
            manifest = self._manifest(version)
            with _private_open(self.versions / str(version) / "client.apk") as apk:
                if os.fstat(apk.fileno()).st_size != manifest["sizeBytes"]:
                    raise StartupError("invalid_release_storage")
            intent_path = self.versions / str(version) / "beta-intent.json"
            source_path = self.beta_sources / f"{version}.json"
            intent = _json_read(intent_path) if intent_path.exists() else None
            source = _json_read(source_path) if source_path.exists() else None
            if intent is not None and not _valid_beta_receipt(intent, manifest):
                raise StartupError("invalid_release_storage")
            if source is not None and not _valid_beta_receipt(source, manifest):
                raise StartupError("invalid_release_storage")
            if intent is not None and source is not None and intent != source:
                raise StartupError("invalid_release_storage")
            receipt = intent or source
            if receipt is not None:
                # The copy inside the version directory crosses the atomic
                # staging rename. Either external copy can therefore be
                # reconstructed without guessing the release channel.
                if intent is None:
                    _json_write(intent_path, receipt)
                if source is None:
                    _json_write(source_path, receipt)
                beta_intents[version] = receipt
        previous = self._latest_version("stable")
        beta = self._latest_version("beta")
        if previous is not None and previous not in published:
            raise StartupError("published_release_missing")
        if beta is not None:
            if beta not in published or beta not in beta_intents:
                raise StartupError("published_release_missing")
        if beta_intents and (beta is None or max(beta_intents) > beta):
            _json_write(self.beta_index, {"versionCode": max(beta_intents)})
        stable_candidates = [version for version in published
                             if version not in beta_intents]
        if stable_candidates and (previous is None or max(stable_candidates) > previous):
            # A verified directory may have committed before a process crash
            # prevented the latest-pointer update. It is safe to finish it.
            _json_write(self.index, {"versionCode": max(stable_candidates)})
        self._retention()

    def _latest_version(self, channel="stable") -> int | None:
        target = self.index if channel == "stable" else self.beta_index if channel == "beta" else None
        if target is None:
            raise ApiError("invalid_request")
        if not target.exists():
            return None
        value = _json_read(target)
        if set(value) != {"versionCode"}:
            raise ApiError("server_unavailable", 503)
        return version_number(value["versionCode"])

    def latest(self, channel="stable") -> dict | None:
        with self._locked():
            version = self._latest_version(channel)
            return self._manifest(version) if version is not None else None

    def open_apk(self, version: int):
        version_number(version)
        with self._locked():
            if not (self.versions / str(version)).exists():
                raise ApiError("not_found", 404)
            manifest = self._manifest(version)
            stream = _private_open(self.versions / str(version) / "client.apk")
            if os.fstat(stream.fileno()).st_size != manifest["sizeBytes"]:
                stream.close()
                raise ApiError("server_unavailable", 503)
            # Open before releasing the lock. Retention can unlink an old APK
            # without truncating an in-progress reader's file descriptor.
            return manifest, stream

    def _remove_directory(self, directory: Path) -> None:
        checked_path(directory)
        if directory.parent not in (self.staging, self.versions, self.trash):
            raise StartupError("invalid_release_cleanup")
        private_directory(directory)
        allowed = {"request.json", "upload.json", "manifest.json", "beta-intent.json",
                   ".lock", "client.apk", "client.part"}
        for child in directory.iterdir():
            if (child.name not in allowed and not child.name.startswith(".tmp.")) or child.is_dir():
                raise StartupError("unknown_release_storage_file")
        if directory.parent != self.trash:
            retired = self.trash / str(uuid.uuid4())
            original_parent = directory.parent
            os.rename(directory, retired)
            sync_directory(original_parent)
            sync_directory(self.trash)
            directory = retired
        # The namespace change above is atomic. A crash during file removal
        # leaves only a trash entry, never a half-published version/stage.
        for child in directory.iterdir():
            child.unlink()
        directory.rmdir()
        sync_directory(self.trash)

    def _stage(self, version: int, identifier: str) -> tuple[Path, dict]:
        if not UPLOAD_ID.fullmatch(identifier):
            raise ApiError("invalid_request")
        directory = self.staging / identifier
        if not directory.exists():
            raise ApiError("release_upload_expired", 409)
        private_directory(directory)
        request = _json_read(directory / "request.json")
        if set(request) != {"manifest", "expiresAt"} or type(request["expiresAt"]) not in (int, float):
            raise ApiError("server_unavailable", 503)
        manifest = validate_manifest(request["manifest"])
        if manifest["versionCode"] != version or self.settings.clock() >= request["expiresAt"]:
            raise ApiError("release_upload_expired", 409)
        return directory, request

    def _pending(self) -> list[tuple[Path, dict]]:
        pending = []
        for directory in self.staging.iterdir():
            if not UPLOAD_ID.fullmatch(directory.name):
                continue
            private_directory(directory)
            request = _json_read(directory / "request.json")
            if self.settings.clock() >= request.get("expiresAt", 0):
                try:
                    with self._upload_lock(directory):
                        self._remove_directory(directory)
                except ApiError as error:
                    if error.code != "release_conflict":
                        raise
                    pending.append((directory, request))
            else:
                validate_manifest(request.get("manifest"))
                pending.append((directory, request))
        return pending

    def initialize(self, version: int, raw: object) -> tuple[int, dict]:
        manifest = validate_manifest(raw)
        if version_number(version) != manifest["versionCode"]:
            raise ApiError("invalid_request")
        if manifest["certificateSha256"] != self.settings.signer_sha256:
            raise ApiError("release_verification_failed", 422)
        if self.verifier is None:
            raise ApiError("release_verifier_unavailable", 503)
        with self._locked():
            # An explicit publisher rerun also repairs interrupted commits;
            # recovery must not depend on an operator restarting the service.
            self._recover()
            latest = self._latest_version()
            if latest is not None and version < latest:
                raise ApiError("release_conflict", 409)
            if (self.versions / str(version)).exists():
                existing = self._manifest(version)
                if existing["apkSha256"] != manifest["apkSha256"] or existing["sizeBytes"] != manifest["sizeBytes"]:
                    raise ApiError("release_conflict", 409)
                latest = self._latest_version("stable")
                if latest is None or version > latest:
                    _json_write(self.index, {"versionCode": version})
                return 200, {"state": "published", "release": existing}
            pending = self._pending()
            for directory, request in pending:
                previous = request["manifest"]
                if previous["versionCode"] == version:
                    if previous["apkSha256"] != manifest["apkSha256"] or previous["sizeBytes"] != manifest["sizeBytes"]:
                        raise ApiError("release_conflict", 409)
                    state = "uploaded" if (directory / "upload.json").exists() else "awaitingUpload"
                    return 200, {"state": state, "uploadId": directory.name, "versionCode": version, "expiresAt": request["expiresAt"]}
            reserved = sum(item["manifest"]["sizeBytes"] for _, item in pending)
            retained = sum(self._manifest(v)["sizeBytes"] for v in self._published())
            free = os.statvfs(self.root).f_bavail * os.statvfs(self.root).f_frsize
            if (len(pending) >= self.settings.max_active or reserved + retained + manifest["sizeBytes"] > self.settings.max_apk_disk_bytes or
                    free < manifest["sizeBytes"] + 16 * 1024 * 1024):
                raise ApiError("release_capacity", 409)
            identifier = str(uuid.uuid4())
            directory = self.staging / identifier
            private_directory(directory)
            try:
                private_create(directory / ".lock", b"")
                request = {"manifest": manifest, "expiresAt": self.settings.clock() + self.settings.upload_ttl_seconds}
                _json_write(directory / "request.json", request)
                sync_directory(self.staging)
            except BaseException:
                self._remove_directory(directory)
                raise
            return 201, {"state": "awaitingUpload", "uploadId": identifier, "versionCode": version, "expiresAt": request["expiresAt"]}

    async def receive_upload(self, version: int, identifier: str, request: Request) -> dict:
        with self._locked():
            directory, pending = self._stage(version_number(version), identifier)
        with self._upload_lock(directory):
            if (directory / "upload.json").exists():
                raise ApiError("release_conflict", 409)
            expected = pending["manifest"]
            content_type = request.headers.get("content-type", "").split(";", 1)[0].strip().lower()
            if content_type not in ("application/octet-stream", "application/vnd.android.package-archive") or request.headers.get("content-encoding", "identity") != "identity":
                raise ApiError("invalid_request")
            length = request.headers.get("content-length")
            if length is not None:
                try:
                    if int(length) != expected["sizeBytes"]:
                        raise ValueError()
                except ValueError:
                    raise ApiError("invalid_request") from None
            partial = directory / "client.part"
            try:
                fd = os.open(partial, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                digest = hashlib.sha256()
                received = 0
                with os.fdopen(fd, "wb") as output:
                    async with asyncio.timeout(self.settings.upload_timeout_seconds):
                        async for chunk in request.stream():
                            if self.settings.clock() >= pending["expiresAt"]:
                                raise ApiError("release_upload_expired", 409)
                            received += len(chunk)
                            if received > expected["sizeBytes"]:
                                raise ApiError("payload_too_large", 413)
                            output.write(chunk)
                            digest.update(chunk)
                    output.flush()
                    os.fsync(output.fileno())
                if received != expected["sizeBytes"] or digest.hexdigest() != expected["apkSha256"]:
                    raise ApiError("release_verification_failed", 422)
                os.replace(partial, directory / "client.apk")
                _json_write(directory / "upload.json", {"sizeBytes": received, "apkSha256": digest.hexdigest()})
                return {"state": "uploaded", "uploadId": identifier, "versionCode": version}
            except BaseException as error:
                with self._locked():
                    if directory.exists():
                        self._remove_directory(directory)
                if isinstance(error, (ClientDisconnect, asyncio.CancelledError)):
                    raise
                if isinstance(error, TimeoutError):
                    raise ApiError("request_timeout", 408) from None
                raise

    def finalize(self, version: int, identifier: str) -> dict:
        with self._locked():
            directory, pending = self._stage(version_number(version), identifier)
        with self._upload_lock(directory):
            if not (directory / "upload.json").exists():
                raise ApiError("release_upload_incomplete", 409)
            try:
                manifest = pending["manifest"]
                digest = hashlib.sha256()
                size = 0
                with _private_open(directory / "client.apk") as stream:
                    for chunk in iter(lambda: stream.read(65536), b""):
                        size += len(chunk)
                        if size > manifest["sizeBytes"]:
                            raise ApiError("release_verification_failed", 422)
                        digest.update(chunk)
                if size != manifest["sizeBytes"] or digest.hexdigest() != manifest["apkSha256"]:
                    raise ApiError("release_verification_failed", 422)
                if self.verifier is None:
                    raise ApiError("release_verifier_unavailable", 503)
                observed = self.verifier.verify(directory / "client.apk")
                compare_verified(manifest, observed, self.settings.signer_sha256)
                if self.settings.clock() >= pending["expiresAt"]:
                    raise ApiError("release_upload_expired", 409)
            except ApiError as error:
                # Invalid binaries and expired intents cannot be resumed. A
                # missing verifier may be repaired and explicitly retried.
                if error.status == 422 or error.code == "release_upload_expired":
                    with self._locked():
                        self._remove_directory(directory)
                raise
            with self._locked():
                latest = self._latest_version()
                if latest is not None and version <= latest:
                    existing = self._manifest(version) if version == latest else None
                    if existing is not None and existing["apkSha256"] == manifest["apkSha256"]:
                        self._remove_directory(directory)
                        return existing
                    self._remove_directory(directory)
                    raise ApiError("release_conflict", 409)
                _json_write(directory / "manifest.json", manifest)
                os.rename(directory, self.versions / str(version))
                sync_directory(self.staging)
                sync_directory(self.versions)
                _json_write(self.index, {"versionCode": version})
                self._retention()
                return manifest

    def ingest_beta(self, raw_manifest: object, receipt: object, writer) -> dict:
        """Verify and atomically publish one already source-validated beta.

        `writer` receives a fresh exclusive path and must perform one bounded
        download. A failed or uncertain source never advances the beta pointer.
        """
        manifest = validate_manifest(raw_manifest)
        if (not _valid_beta_receipt(receipt, manifest) or
                manifest["certificateSha256"] != self.settings.signer_sha256 or
                not callable(writer)):
            raise ApiError("release_verification_failed", 422)
        version = manifest["versionCode"]
        with self._locked():
            self._recover()
            latest = self._latest_version("beta")
            if latest is not None and version < latest:
                raise ApiError("beta_source_stale", 503)
            existing = self._manifest(version) if (self.versions / str(version)).exists() else None
            if existing is not None:
                identity = ("applicationId", "versionCode", "versionName", "certificateSha256",
                            "apkSha256", "sizeBytes", "minSdk", "commit", "downloadPath")
                if any(existing[key] != manifest[key] for key in identity):
                    raise ApiError("release_conflict", 409)
                _json_write(self.versions / str(version) / "beta-intent.json", receipt)
                _json_write(self.beta_sources / f"{version}.json", receipt)
                _json_write(self.beta_index, {"versionCode": version})
                self._retention()
                return existing
            pending = self._pending()
            retained = sum(self._manifest(item)["sizeBytes"] for item in self._published())
            reserved = sum(item["manifest"]["sizeBytes"] for _, item in pending)
            free = os.statvfs(self.root).f_bavail * os.statvfs(self.root).f_frsize
            if (len(pending) >= self.settings.max_active or
                    retained + reserved + manifest["sizeBytes"] > self.settings.max_apk_disk_bytes or
                    free < manifest["sizeBytes"] + 16 * 1024 * 1024):
                raise ApiError("release_capacity", 409)
            identifier = str(uuid.uuid4())
            directory = self.staging / identifier
            private_directory(directory)
            private_create(directory / ".lock", b"")
            _json_write(directory / "request.json", {
                "manifest": manifest,
                "expiresAt": self.settings.clock() + self.settings.upload_ttl_seconds,
            })
        try:
            with self._upload_lock(directory):
                partial = directory / "client.part"
                writer(partial)
                with _private_open(partial) as stream:
                    digest = hashlib.sha256()
                    size = 0
                    for chunk in iter(lambda: stream.read(65536), b""):
                        size += len(chunk)
                        if size > manifest["sizeBytes"]:
                            raise ApiError("release_verification_failed", 422)
                        digest.update(chunk)
                if size != manifest["sizeBytes"] or digest.hexdigest() != manifest["apkSha256"]:
                    raise ApiError("release_verification_failed", 422)
                os.replace(partial, directory / "client.apk")
                observed = self.verifier.verify(directory / "client.apk") if self.verifier is not None else None
                if observed is None:
                    raise ApiError("release_verifier_unavailable", 503)
                compare_verified(manifest, observed, self.settings.signer_sha256)
                with self._locked():
                    latest = self._latest_version("beta")
                    if latest is not None and version <= latest:
                        current = self._manifest(latest)
                        if (version == latest and current["apkSha256"] == manifest["apkSha256"] and
                                current["commit"] == manifest["commit"]):
                            self._remove_directory(directory)
                            return current
                        raise ApiError("beta_source_stale", 503)
                    _json_write(directory / "manifest.json", manifest)
                    _json_write(directory / "beta-intent.json", receipt)
                    os.rename(directory, self.versions / str(version))
                    sync_directory(self.staging)
                    sync_directory(self.versions)
                    _json_write(self.beta_sources / f"{version}.json", receipt)
                    _json_write(self.beta_index, {"versionCode": version})
                    self._retention()
                    return manifest
        except BaseException:
            with self._locked():
                if directory.exists():
                    self._remove_directory(directory)
            raise

    def _retention(self) -> None:
        versions = self._published()
        protected = {value for value in (
            self._latest_version("stable"), self._latest_version("beta")
        ) if value is not None}
        target = max(self.settings.max_retained, len(protected))
        removable = [version for version in versions if version not in protected][
            :max(0, len(versions) - target)
        ]
        for version in removable:
            self._remove_directory(self.versions / str(version))
            source = self.beta_sources / f"{version}.json"
            source.unlink(missing_ok=True)
        if removable:
            sync_directory(self.beta_sources)
