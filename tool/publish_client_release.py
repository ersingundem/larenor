#!/usr/bin/env python3
"""Publish an already signed CI APK through an authenticated, staged protocol.

The release credential is accepted only from an environment variable or a 0600
file. No redirects, proxies, automatic retries, raw responses or private output.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import ssl
import stat
import sys
import time
from urllib.parse import urlsplit

MAX_APK = 512 * 1024 * 1024
TOKEN_ENV = "LARENOR_RELEASE_PUBLISH_TOKEN"
TOKEN_PATTERN = re.compile(r"lpub_[A-Za-z0-9_-]{43}\Z")
UPLOAD_PATTERN = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\Z")
APPLICATION_ID = "com.ersingundem.larenor"


class PublishError(Exception):
    def __init__(self, code: str, *, outcome_unknown: bool = False):
        self.code = code
        self.outcome_unknown = outcome_unknown
        super().__init__(code)


class SafeArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise PublishError("invalid_arguments")


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise PublishError("invalid_metadata")
        result[key] = value
    return result


def read_token(token_file: Path | None, environ=os.environ) -> str:
    configured = environ.get(TOKEN_ENV)
    if token_file is not None and configured:
        raise PublishError("ambiguous_publish_credential")
    if token_file is not None:
        descriptor = os.open(token_file, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(descriptor, "rb") as stream:
            info = os.fstat(stream.fileno())
            if (not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600 or
                    info.st_uid != os.geteuid() or info.st_nlink != 1):
                raise PublishError("publish_credential_not_private")
            raw = stream.read(50)
            if len(raw) > 49:
                raise PublishError("invalid_publish_credential")
            configured = raw.decode("ascii").rstrip("\n")
    if not isinstance(configured, str) or not TOKEN_PATTERN.fullmatch(configured):
        raise PublishError("invalid_publish_credential")
    return configured


def server_url(value: str):
    if (len(value) > 2048 or any(c.isspace() or c == "\\" or ord(c) < 32 for c in value)):
        raise PublishError("invalid_server_url")
    try:
        parsed = urlsplit(value)
        if (parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.username is not None or
                parsed.password is not None or parsed.query or parsed.fragment or '%' in parsed.path or
                any(part in (".", "..") for part in parsed.path.split('/')) or
                not 1 <= (parsed.port or (443 if parsed.scheme == "https" else 80)) <= 65535):
            raise ValueError()
        return parsed
    except ValueError:
        raise PublishError("invalid_server_url") from None


def manifest_from_ci(metadata: dict, size: int, digest: str, *, notes: str = "", published_at: str | None = None) -> dict:
    fields = {"applicationId", "versionName", "versionCode", "certificateSha256", "apkSha256", "commit", "workflowRun"}
    if (not isinstance(metadata, dict) or set(metadata) != fields or metadata["applicationId"] != APPLICATION_ID or
            type(metadata["versionCode"]) is not int or not 1 <= metadata["versionCode"] <= 2147483647 or
            not isinstance(metadata["versionName"], str) or not 1 <= len(metadata["versionName"]) <= 80 or
            not metadata["versionName"].strip() or not isinstance(notes, str) or len(notes) > 12000 or
            type(size) is not int or not 1 <= size <= MAX_APK):
        raise PublishError("invalid_metadata")
    for value in (metadata["versionName"], notes):
        if any(ord(c) < 32 and c not in "\n\t" or ord(c) == 127 or
               0xD800 <= ord(c) <= 0xDFFF for c in value):
            raise PublishError("invalid_metadata")
    for key, length in (("certificateSha256", 64), ("apkSha256", 64), ("commit", 40)):
        if not isinstance(metadata[key], str) or not re.fullmatch(r"[a-fA-F0-9]{" + str(length) + "}", metadata[key]):
            raise PublishError("invalid_metadata")
    if metadata["apkSha256"].lower() != digest:
        raise PublishError("apk_hash_mismatch")
    date = published_at or datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    try:
        when = datetime.fromisoformat(date.replace("Z", "+00:00"))
        if when.tzinfo is None or len(date) > 64 or "T" not in date:
            raise ValueError()
    except ValueError:
        raise PublishError("invalid_metadata") from None
    manifest = {key: metadata[key] for key in fields - {"workflowRun"}}
    manifest.update(schemaVersion=1, sizeBytes=size, minSdk=26,
                    downloadPath=f'/api/v1/client/releases/{metadata["versionCode"]}/apk',
                    publishedAt=date, releaseNotes=notes)
    for key in ("certificateSha256", "apkSha256", "commit"):
        manifest[key] = manifest[key].lower()
    if len(json.dumps(manifest, ensure_ascii=False).encode()) > 65536:
        raise PublishError("invalid_metadata")
    return manifest


class Publisher:
    def __init__(self, base_url: str, token: str, *, timeout: float = 600):
        self.server = server_url(base_url)
        if not TOKEN_PATTERN.fullmatch(token):
            raise PublishError("invalid_publish_credential")
        self._token = token
        self.timeout = timeout

    def _request(self, method: str, suffix: str, *, body: bytes | None = None, stream=None, size: int = 0) -> dict:
        deadline = time.monotonic() + self.timeout
        connection = None
        dispatched = False
        try:
            host = self.server.hostname
            port = self.server.port or (443 if self.server.scheme == "https" else 80)
            # http.client does not use environment proxy settings or follow redirects.
            connection = (http.client.HTTPSConnection(host, port, context=ssl.create_default_context(), timeout=min(20, self.timeout))
                          if self.server.scheme == "https" else http.client.HTTPConnection(host, port, timeout=min(20, self.timeout)))
            path = self.server.path.rstrip('/') + suffix
            data_size = size if stream is not None else len(body or b"")
            connection.putrequest(method, path)
            connection.putheader("Authorization", "Bearer " + self._token)
            connection.putheader("Content-Type", "application/vnd.android.package-archive" if stream is not None else "application/json")
            connection.putheader("Content-Length", str(data_size))
            connection.putheader("Accept", "application/json")
            dispatched = True
            connection.endheaders()
            if stream is not None:
                sent = 0
                while chunk := stream.read(65536):
                    sent += len(chunk)
                    if sent > size or time.monotonic() >= deadline:
                        raise PublishError("upload_outcome_unknown", outcome_unknown=True)
                    connection.sock.settimeout(min(20, max(.001, deadline - time.monotonic())))
                    connection.send(chunk)
                if sent != size:
                    raise PublishError("upload_outcome_unknown", outcome_unknown=True)
            elif body:
                connection.send(body)
            connection.sock.settimeout(min(120, max(.001, deadline - time.monotonic())))
            response = connection.getresponse()
            if 300 <= response.status <= 399:
                raise PublishError("redirect_refused", outcome_unknown=True)
            if response.status not in (200, 201):
                raise PublishError({401: "invalid_publish_credential", 403: "publish_forbidden", 409: "release_conflict",
                                    413: "payload_too_large", 422: "release_verification_failed", 503: "server_unavailable"}.get(response.status, "publish_rejected"),
                                   outcome_unknown=response.status >= 500 or response.status == 408)
            content_length = response.getheader("Content-Length")
            if content_length is not None and (not content_length.isdigit() or int(content_length) > 65536):
                raise PublishError("invalid_server_response", outcome_unknown=True)
            payload = response.read(65537)
            if len(payload) > 65536:
                raise PublishError("invalid_server_response", outcome_unknown=True)
            try:
                result = json.loads(payload, object_pairs_hook=_unique_object)
            except (ValueError, PublishError):
                raise PublishError("invalid_server_response", outcome_unknown=True) from None
            if not isinstance(result, dict):
                raise PublishError("invalid_server_response", outcome_unknown=True)
            return result
        except PublishError:
            raise
        except (OSError, ValueError, http.client.HTTPException):
            raise PublishError("network_outcome_unknown" if dispatched else "connection_failed", outcome_unknown=dispatched) from None
        finally:
            if connection is not None:
                connection.close()

    def publish(self, manifest: dict, stream) -> dict:
        version = manifest["versionCode"]
        prefix = f"/api/v1/client/releases/{version}"
        initialized = self._request("PUT", prefix, body=json.dumps(manifest, ensure_ascii=False).encode())
        if initialized.get("state") == "published":
            return self._published(initialized.get("release"), manifest, "alreadyPublished")
        upload_id = initialized.get("uploadId")
        if (initialized.get("state") not in ("awaitingUpload", "uploaded") or initialized.get("versionCode") != version or
                not isinstance(upload_id, str) or not UPLOAD_PATTERN.fullmatch(upload_id)):
            raise PublishError("invalid_server_response", outcome_unknown=True)
        path = prefix + "/uploads/" + upload_id
        if initialized["state"] == "awaitingUpload":
            stream.seek(0)
            uploaded = self._request("PUT", path + "/apk", stream=stream, size=manifest["sizeBytes"])
            if uploaded != {"state": "uploaded", "uploadId": upload_id, "versionCode": version}:
                raise PublishError("invalid_server_response", outcome_unknown=True)
        published = self._request("POST", path + "/finalize")
        return self._published(published, manifest, "published")

    @staticmethod
    def _published(response, expected: dict, state: str) -> dict:
        if not isinstance(response, dict) or any(response.get(key) != expected[key] for key in
                ("applicationId", "versionCode", "versionName", "certificateSha256", "apkSha256", "sizeBytes", "minSdk", "downloadPath")):
            raise PublishError("invalid_server_response", outcome_unknown=True)
        return {"state": state, "versionCode": expected["versionCode"], "apkSha256": expected["apkSha256"]}


def main(argv=None):
    parser = SafeArgumentParser(description=__doc__)
    parser.add_argument("--server", required=True)
    parser.add_argument("--apk", required=True, type=Path)
    parser.add_argument("--metadata", required=True, type=Path)
    parser.add_argument("--token-file", type=Path)
    parser.add_argument("--notes-file", type=Path)
    args = parser.parse_args(argv)
    token = read_token(args.token_file)
    with args.metadata.open("rb") as source:
        raw = source.read(65537)
    if len(raw) > 65536:
        raise PublishError("invalid_metadata")
    metadata = json.loads(raw, object_pairs_hook=_unique_object)
    notes = ""
    if args.notes_file is not None:
        with args.notes_file.open("rb") as source:
            value = source.read(48001)
        if len(value) > 48000:
            raise PublishError("invalid_metadata")
        notes = value.decode("utf-8")
    descriptor = os.open(args.apk, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or not 1 <= info.st_size <= MAX_APK:
            raise PublishError("invalid_apk_file")
        digest = hashlib.sha256()
        for chunk in iter(lambda: stream.read(65536), b""):
            digest.update(chunk)
        manifest = manifest_from_ci(metadata, info.st_size, digest.hexdigest(), notes=notes)
        stream.seek(0)
        result = Publisher(args.server, token).publish(manifest, stream)
    print(json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        safe = error if isinstance(error, PublishError) else PublishError("publish_unavailable")
        print(json.dumps({"state": "unknown" if safe.outcome_unknown else "rejected", "error": safe.code}, separators=(",", ":")))
        sys.exit(2)
