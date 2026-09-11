#!/usr/bin/env python3
"""Create and validate the public, signed Larenor Client beta envelope.

The Android package remains the executable signing subject. The exact manifest,
APK digest, release tag and source commit form a removable public transport
envelope. This helper emits public metadata only and never reads signing secrets.
"""
from __future__ import annotations

import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import sys


APPLICATION_ID = "com.ersingundem.larenor"
OFFICIAL_REPOSITORY = "ersingundem/larenor"
OFFICIAL_WORKFLOW = ".github/workflows/android-build.yml"
MAX_APK_BYTES = 512 * 1024 * 1024
MAX_JSON_BYTES = 128 * 1024
METADATA_FIELDS = {
    "applicationId", "versionName", "versionCode", "certificateSha256",
    "apkSha256", "commit", "workflowRun",
}
MANIFEST_FIELDS = {
    "schemaVersion", "channel", "applicationId", "versionCode", "versionName",
    "certificateSha256", "apkSha256", "sizeBytes", "minSdk", "commit",
    "sourceRepository", "sourceWorkflow", "sourceRunId", "sourceRunAttempt",
    "releaseTag", "apkAssetName", "manifestAssetName", "publishedAt",
}
HEX_40 = re.compile(r"[a-f0-9]{40}\Z")
HEX_64 = re.compile(r"[a-f0-9]{64}\Z")
POSITIVE = re.compile(r"[1-9][0-9]*\Z")
TAG = re.compile(r"client-beta-v([1-9][0-9]{0,9})\Z")


class BetaReleaseError(ValueError):
    """A static validation failure that contains no untrusted input."""


def _fail(code="invalid_beta_release"):
    raise BetaReleaseError(code)


def _pairs(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            _fail("duplicate_json_key")
        value[key] = item
    return value


def read_json(path: Path, maximum=MAX_JSON_BYTES):
    try:
        raw = path.read_bytes()
        if not raw or len(raw) > maximum:
            _fail()
        return json.loads(raw, object_pairs_hook=_pairs)
    except (OSError, UnicodeError, json.JSONDecodeError):
        _fail()


def _positive(value, maximum):
    if type(value) is not int or not 1 <= value <= maximum:
        _fail()
    return value


def _text(value, maximum, pattern=None):
    if (not isinstance(value, str) or not value or len(value) > maximum or
            value.strip() != value or any(ord(char) < 32 or ord(char) == 127 or
                                          0xD800 <= ord(char) <= 0xDFFF for char in value)):
        _fail()
    if pattern is not None and pattern.fullmatch(value) is None:
        _fail()
    return value


def _timestamp(value):
    _text(value, 64)
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None or "T" not in value:
            raise ValueError()
    except ValueError:
        _fail()
    return value


def _sha256(path: Path):
    digest = hashlib.sha256()
    size = 0
    try:
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                size += len(chunk)
                if size > MAX_APK_BYTES:
                    _fail()
                digest.update(chunk)
    except OSError:
        _fail()
    if size < 1:
        _fail()
    return size, digest.hexdigest()


def build_manifest(metadata, apk: Path, *, repository, workflow, run_attempt, published_at):
    if not isinstance(metadata, dict) or set(metadata) != METADATA_FIELDS:
        _fail()
    if repository != OFFICIAL_REPOSITORY or workflow != OFFICIAL_WORKFLOW or run_attempt != "1":
        _fail("untrusted_source")
    version = _positive(metadata.get("versionCode"), 2147483647)
    run_id = _text(metadata.get("workflowRun"), 20, POSITIVE)
    commit = _text(metadata.get("commit"), 40, HEX_40)
    certificate = _text(metadata.get("certificateSha256"), 64, HEX_64)
    expected_hash = _text(metadata.get("apkSha256"), 64, HEX_64)
    version_name = _text(metadata.get("versionName"), 80)
    if metadata.get("applicationId") != APPLICATION_ID:
        _fail()
    size, observed_hash = _sha256(apk)
    if observed_hash != expected_hash:
        _fail("apk_hash_mismatch")
    tag = "client-beta-v%d" % version
    return {
        "schemaVersion": 1,
        "channel": "beta",
        "applicationId": APPLICATION_ID,
        "versionCode": version,
        "versionName": version_name,
        "certificateSha256": certificate,
        "apkSha256": expected_hash,
        "sizeBytes": size,
        "minSdk": 26,
        "commit": commit,
        "sourceRepository": repository,
        "sourceWorkflow": workflow,
        "sourceRunId": int(run_id),
        "sourceRunAttempt": 1,
        "releaseTag": tag,
        "apkAssetName": "Larenor-Client-beta-%d.apk" % version,
        "manifestAssetName": "Larenor-Client-beta-%d.json" % version,
        "publishedAt": _timestamp(published_at),
    }


def canonical_json(value):
    if not isinstance(value, dict) or set(value) != MANIFEST_FIELDS:
        _fail()
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n"


def _asset_map(raw):
    if not isinstance(raw, list) or len(raw) != 2:
        _fail()
    result = {}
    for asset in raw:
        if not isinstance(asset, dict):
            _fail()
        name = asset.get("name")
        if (not isinstance(name, str) or name in result or
                type(asset.get("size")) is not int or asset["size"] < 1 or
                not isinstance(asset.get("digest"), str) or
                re.fullmatch(r"sha256:[a-f0-9]{64}", asset["digest"]) is None):
            _fail()
        result[name] = asset
    return result


def verify_release(release, manifest, apk_bytes, manifest_bytes, resolved_tag_commit):
    if not isinstance(release, dict) or not isinstance(manifest, dict):
        _fail()
    version = _positive(manifest.get("versionCode"), 2147483647)
    tag = "client-beta-v%d" % version
    commit = _text(manifest.get("commit"), 40, HEX_40)
    if (set(manifest) != MANIFEST_FIELDS or manifest.get("channel") != "beta" or
            manifest.get("sourceRepository") != OFFICIAL_REPOSITORY or
            manifest.get("sourceWorkflow") != OFFICIAL_WORKFLOW or
            manifest.get("sourceRunAttempt") != 1 or
            release.get("tag_name") != tag or manifest.get("releaseTag") != tag or
            release.get("name") != "Larenor Client beta %d" % version or
            release.get("target_commitish") != commit or resolved_tag_commit != commit or
            release.get("draft") is not False or release.get("prerelease") is not True or
            release.get("immutable") is not False):
        _fail()
    assets = _asset_map(release.get("assets"))
    expected = {
        manifest["apkAssetName"]: apk_bytes,
        manifest["manifestAssetName"]: manifest_bytes,
    }
    if set(assets) != set(expected):
        _fail()
    for name, content in expected.items():
        if (assets[name]["size"] != len(content) or
                assets[name]["digest"] != "sha256:" + hashlib.sha256(content).hexdigest()):
            _fail()


def _retained_release(raw, *, allow_draft=False):
    if not isinstance(raw, dict):
        _fail()
    tag = raw.get("tag_name")
    if not isinstance(tag, str) or TAG.fullmatch(tag) is None:
        return None
    version = int(TAG.fullmatch(tag).group(1))
    if (type(raw.get("id")) is not int or raw["id"] < 1 or
            raw.get("name") != "Larenor Client beta %d" % version or
            (raw.get("draft") is not False and
             not (allow_draft and raw.get("draft") is True)) or
            raw.get("prerelease") is not True or
            raw.get("immutable") is not False or
            not isinstance(raw.get("target_commitish"), str) or
            HEX_40.fullmatch(raw["target_commitish"]) is None):
        _fail("ambiguous_beta_release")
    assets = _asset_map(raw.get("assets"))
    if set(assets) != {
        "Larenor-Client-beta-%d.apk" % version,
        "Larenor-Client-beta-%d.json" % version,
    }:
        _fail("ambiguous_beta_release")
    return version, raw["id"], tag, raw["target_commitish"]


def verify_candidate(release, *, identifier, tag, commit, resolved_tag_commit,
                     allow_draft):
    if (type(identifier) is not int or identifier < 1 or
            _text(tag, 64, TAG) != tag or _text(commit, 40, HEX_40) != commit or
            resolved_tag_commit != commit):
        _fail("ambiguous_beta_release")
    parsed = _retained_release(release, allow_draft=allow_draft)
    if parsed is None:
        _fail("ambiguous_beta_release")
    _version, observed_id, observed_tag, observed_commit = parsed
    if observed_id != identifier or observed_tag != tag or observed_commit != commit:
        _fail("ambiguous_beta_release")
    return identifier


def retention_candidates(pages, *, keep, maximum):
    if (type(keep) is not int or type(maximum) is not int or
            not 1 <= keep <= 32 or not 1 <= maximum <= 8 or
            not isinstance(pages, list) or len(pages) > 20):
        _fail()
    flattened = []
    for page in pages:
        if not isinstance(page, list) or len(page) > 100:
            _fail()
        flattened.extend(page)
    versions = {}
    for raw in flattened:
        parsed = _retained_release(raw)
        if parsed is None:
            continue
        version, identifier, tag, commit = parsed
        if version in versions or identifier in {item[0] for item in versions.values()}:
            _fail("ambiguous_beta_release")
        versions[version] = (identifier, tag, commit)
    candidates = [versions[version] for version in sorted(versions)[:-keep]]
    if len(candidates) > maximum:
        _fail("retention_backlog_exceeds_bound")
    return candidates


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    manifest = commands.add_parser("manifest")
    manifest.add_argument("--metadata", required=True, type=Path)
    manifest.add_argument("--apk", required=True, type=Path)
    manifest.add_argument("--output", required=True, type=Path)
    manifest.add_argument("--repository", required=True)
    manifest.add_argument("--workflow", required=True)
    manifest.add_argument("--run-attempt", required=True)
    manifest.add_argument("--published-at", required=True)
    verify = commands.add_parser("verify-release")
    verify.add_argument("--release", required=True, type=Path)
    verify.add_argument("--manifest", required=True, type=Path)
    verify.add_argument("--apk", required=True, type=Path)
    verify.add_argument("--tag-commit", required=True)
    retention = commands.add_parser("retention")
    retention.add_argument("--releases", required=True, type=Path)
    retention.add_argument("--keep", type=int, default=8)
    retention.add_argument("--max-deletions", type=int, default=4)
    candidate = commands.add_parser("verify-candidate")
    candidate.add_argument("--release", required=True, type=Path)
    candidate.add_argument("--id", required=True, type=int)
    candidate.add_argument("--tag", required=True)
    candidate.add_argument("--commit", required=True)
    candidate.add_argument("--tag-commit", required=True)
    candidate.add_argument("--allow-draft", action="store_true")
    args = parser.parse_args(argv)
    if args.command == "manifest":
        result = build_manifest(
            read_json(args.metadata, 65536), args.apk,
            repository=args.repository, workflow=args.workflow,
            run_attempt=args.run_attempt, published_at=args.published_at,
        )
        output = canonical_json(result)
        args.output.write_text(output, encoding="ascii")
        print("versionCode=%d" % result["versionCode"])
        print("releaseTag=%s" % result["releaseTag"])
        print("apkAssetName=%s" % result["apkAssetName"])
        print("manifestAssetName=%s" % result["manifestAssetName"])
    elif args.command == "verify-release":
        release = read_json(args.release)
        manifest_value = read_json(args.manifest)
        apk = args.apk.read_bytes()
        manifest_raw = args.manifest.read_bytes()
        verify_release(release, manifest_value, apk, manifest_raw, args.tag_commit)
        print("verified")
    elif args.command == "retention":
        pages = read_json(args.releases, 2 * 1024 * 1024)
        for identifier, tag, commit in retention_candidates(
                pages, keep=args.keep, maximum=args.max_deletions):
            print("%d %s %s" % (identifier, tag, commit))
    else:
        release_value = read_json(args.release)
        print(verify_candidate(
            release_value, identifier=args.id, tag=args.tag, commit=args.commit,
            resolved_tag_commit=args.tag_commit,
            allow_draft=args.allow_draft,
        ))


if __name__ == "__main__":
    try:
        main()
    except (BetaReleaseError, OSError, UnicodeError, json.JSONDecodeError) as error:
        code = str(error) if isinstance(error, BetaReleaseError) else "beta_release_unavailable"
        print("Beta release operation stopped: " + code, file=sys.stderr)
        raise SystemExit(2)
