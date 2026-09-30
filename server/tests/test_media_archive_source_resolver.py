"""Private archive resolution uses sealed IDs, mounts and live authority."""

from dataclasses import replace
import json
import sqlite3
import time

import pytest

from larenor_server.media_archive_actions.journal import action_command_digest
from larenor_server.media_archive_actions.models import (
    ArchiveActionAuthority,
    ArchiveActionCandidate,
    PrivateArchiveActionCommand,
)
from larenor_server.media_archive_actions.source_resolver import (
    ApprovedArchiveMount,
    ArchiveSourceResolverError,
    AuthenticatedArchiveSourceRecord,
    PrivateMediaArchiveSourceResolver,
    PrivateArchiveResolverCatalog,
    UnmanicLibraryReadback,
    VerifiedUnmanicLibrary,
    build_private_media_archive_source_publisher,
    build_private_media_archive_source_resolver,
)
from larenor_server.media_archive_actions.unmanic import UnmanicResponse
from test_media_archive_core_read import NOW, authority as collection_authority
from test_media_archive_worker_ipc import private as worker_collection


KEY = b"archive resolver test key material!" * 2
ITEM = "3" * 32
INSTALLATION = "2" * 32
MEDIA_KEY = "movie:tmdb:42"


def authority(snapshot=9):
    return ArchiveActionAuthority(
        installationId=INSTALLATION,
        installationRevision=4,
        snapshotRevision=snapshot,
        sourceRevisions={
            "jellyfin": 3,
            "sonarr": 5,
            "radarr": 6,
            "qbittorrent": 7,
        },
    )


def command(current=None):
    current = current or authority()
    return PrivateArchiveActionCommand(
        operationId="1" * 32,
        operation="stage_transcode",
        authority=current,
        candidate=ArchiveActionCandidate(
            candidateId="b" * 64,
            kind="transcode",
            title="Archive item",
            potentialBytes=512,
            confidence="medium",
            comparison={
                "basis": "bounded_transcode_estimate",
                "observedBytes": 4096,
                "estimatedRetainedBytes": 3584,
                "estimatedSavingBytes": 512,
            },
            evidence=[
                "source_profile_verified",
                "target_playback_verified",
                "bounded_size_estimate",
            ],
            actionType="optimize",
        ),
        target={
            "targetType": "transcode",
            "sourceItemId": ITEM,
            "mediaKey": MEDIA_KEY,
            "sourceCodec": "h264",
            "targetCodec": "hevc",
            "sourceBitrate": 8192,
            "targetBitrate": 4096,
            "durationSeconds": 1,
            "sourceSizeBytes": 4096,
            "targetPlaybackVerified": True,
        },
        evidenceDigest="a" * 64,
        reservedBytes=4096,
        retainOriginal=True,
    )


def cleanup_command(source, current):
    return PrivateArchiveActionCommand(
        operationId="4" * 32,
        operation="cleanup_retained_original",
        authority=current,
        candidate=source.candidate,
        sourceJobId="5" * 32,
        sourceJobRevision=3,
        target={
            "targetType": "retained_original",
            "sourceOperationId": source.operationId,
        },
        evidenceDigest="d" * 64,
        reservedBytes=0,
        retainOriginal=False,
    )


class AuthorityReader:
    def __init__(self, value):
        self.value = value

    def current_archive_action_authority(self, installation_id, *, deadline):
        assert (installation_id == self.value.installationId
                and time.monotonic() < deadline)
        return self.value


class LibraryReader:
    def __init__(self, work_root, library_id=42, digest="c" * 64):
        self.value = VerifiedUnmanicLibrary(
            libraryId=library_id,
            workRoot=str(work_root),
            configDigest=digest,
        )

    def read_verified_library(self, *, deadline):
        assert time.monotonic() < deadline
        return self.value


@pytest.fixture
def roots(tmp_path):
    values = {name: tmp_path / name for name in (
        "resolver", "library", "work", "retained")}
    for path in values.values():
        path.mkdir(mode=0o700)
    source = values["library"] / "Movies" / "archive.mkv"
    source.parent.mkdir(mode=0o700)
    source.write_bytes(b"x" * 4096)
    source.chmod(0o600)
    return values, source


def source_record(**changes):
    values = {
        "sourceItemId": ITEM,
        "mediaKey": MEDIA_KEY,
        "sourcePath": "/media/Movies/archive.mkv",
        "sourceSizeBytes": 4096,
        "sourceCodec": "h264",
        "sourceBitrate": 8192,
        "durationSeconds": 1,
    }
    values.update(changes)
    return AuthenticatedArchiveSourceRecord(**values)


def build(roots, *, current=None, library_id=42, digest="c" * 64):
    values, _source = roots
    current_reader = AuthorityReader(current or authority())
    unmanic_reader = LibraryReader(values["work"], library_id, digest)
    resolver = PrivateMediaArchiveSourceResolver(
        values["resolver"], KEY,
        approved_mounts=(ApprovedArchiveMount(
            "primary", "/media", str(values["library"])),),
        work_root=values["work"],
        retained_root=values["retained"],
        authority_reader=current_reader,
        unmanic_reader=unmanic_reader,
    )
    return resolver, current_reader, unmanic_reader


def test_sealed_mapping_reopens_and_uses_actual_unmanic_library_id(roots):
    resolver, current, unmanic = build(roots, library_id=42)
    try:
        assert resolver.replace_authenticated(
            authority(), [source_record()], deadline=time.monotonic() + 5) == 1
        resolved = resolver.resolve(command(), deadline=time.monotonic() + 5)
        assert resolved.libraryId == 42
        assert resolved.path == str(roots[1])
        assert resolved.commandDigest == action_command_digest(command())
        assert repr(resolved) == "ResolvedArchiveActionSource(<private>)"
    finally:
        resolver.close()

    reopened = PrivateMediaArchiveSourceResolver(
        roots[0]["resolver"], KEY,
        approved_mounts=(ApprovedArchiveMount(
            "primary", "/media", str(roots[0]["library"])),),
        work_root=roots[0]["work"], retained_root=roots[0]["retained"],
        authority_reader=current, unmanic_reader=unmanic)
    try:
        assert reopened.resolve(
            command(), deadline=time.monotonic() + 5).path == str(roots[1])
    finally:
        reopened.close()


def test_private_collection_grant_publishes_exact_action_authority(roots):
    selected = worker_collection(
        current=collection_authority(observed=NOW - 1)).authority
    action = ArchiveActionAuthority(
        installationId=selected.installationId,
        installationRevision=selected.installationRevision,
        snapshotRevision=selected.snapshotRevision,
        sourceRevisions={item.serviceId: item.serviceRevision
                         for item in selected.sources},
    )
    resolver, _current, _unmanic = build(roots, current=action)
    try:
        assert resolver.replace_collection_authenticated(
            selected, [source_record()], deadline=time.monotonic() + 5,
            gate=lambda: True) == 1
        resolved = resolver.resolve(
            command(action), deadline=time.monotonic() + 5)
        assert resolved.sourceItemId == ITEM and resolved.libraryId == 42
    finally:
        resolver.close()


def test_source_and_unmanic_authority_drift_fail_closed(roots):
    resolver, current, unmanic = build(roots)
    try:
        resolver.replace_authenticated(
            authority(), [source_record()], deadline=time.monotonic() + 5)
        current.value = authority(snapshot=10)
        with pytest.raises(ArchiveSourceResolverError) as caught:
            resolver.resolve(command(), deadline=time.monotonic() + 5)
        assert caught.value.code == "authority_changed"

        current.value = authority()
        unmanic.value = replace(unmanic.value, libraryId=7)
        with pytest.raises(ArchiveSourceResolverError) as caught:
            resolver.resolve(command(), deadline=time.monotonic() + 5)
        assert caught.value.code == "authority_changed"
    finally:
        resolver.close()


def test_empty_authenticated_refresh_retires_old_source_mapping(roots):
    resolver, _current, _unmanic = build(roots)
    try:
        resolver.replace_authenticated(
            authority(), [source_record()], deadline=time.monotonic() + 5)
        assert resolver.replace_authenticated(
            authority(), [], deadline=time.monotonic() + 5) == 2
        with pytest.raises(ArchiveSourceResolverError) as caught:
            resolver.resolve(command(), deadline=time.monotonic() + 5)
        assert caught.value.code == "evidence_changed"
    finally:
        resolver.close()


def test_resolve_requires_old_profile_but_recovery_authorize_allows_replacement(roots):
    resolver, _current, _unmanic = build(roots)
    try:
        resolver.replace_authenticated(
            authority(), [source_record()], deadline=time.monotonic() + 5)
        roots[1].write_bytes(b"new-hevc-output")
        with pytest.raises(ArchiveSourceResolverError) as caught:
            resolver.resolve(command(), deadline=time.monotonic() + 5)
        assert caught.value.code == "evidence_changed"
        assert resolver.authorize(
            command(), deadline=time.monotonic() + 5) is True
    finally:
        resolver.close()


def test_retained_cleanup_uses_current_authority_without_old_source_cache(
        roots):
    resolver, current, _unmanic = build(roots)
    source = command()
    try:
        resolver.replace_authenticated(
            authority(), [source_record()], deadline=time.monotonic() + 5)
        # The installed output is now a different profile/size and the next
        # authenticated collection legitimately excludes HEVC from transcodes.
        roots[1].write_bytes(b"hevc-output")
        current.value = authority(snapshot=10)
        resolver.replace_authenticated(
            current.value, [], deadline=time.monotonic() + 5)
        cleanup = cleanup_command(source, current.value)

        assert resolver.authorize_retained(
            cleanup, source, str(roots[1]),
            deadline=time.monotonic() + 5)
        assert not resolver.authorize_retained(
            cleanup.model_copy(update={"authority": authority()}),
            source, str(roots[1]), deadline=time.monotonic() + 5)
        assert not resolver.authorize_retained(
            cleanup, source, str(roots[0]["retained"] / "foreign.mkv"),
            deadline=time.monotonic() + 5)
    finally:
        resolver.close()


def test_descriptor_walk_rejects_symlink_source(roots):
    resolver, _current, _unmanic = build(roots)
    try:
        roots[1].unlink()
        roots[1].symlink_to("outside.mkv")
        with pytest.raises(ArchiveSourceResolverError) as caught:
            resolver.replace_authenticated(
                authority(), [source_record()], deadline=time.monotonic() + 5)
        assert caught.value.code == "source_path_rejected"
    finally:
        resolver.close()


def test_database_tamper_is_rejected_on_reopen(roots):
    resolver, current, unmanic = build(roots)
    resolver.replace_authenticated(
        authority(), [source_record()], deadline=time.monotonic() + 5)
    database = resolver.database_path
    resolver.close()
    with sqlite3.connect(database) as connection:
        connection.execute(
            "UPDATE sources SET source_size_bytes=source_size_bytes+1")
    with pytest.raises(ArchiveSourceResolverError):
        PrivateMediaArchiveSourceResolver(
            roots[0]["resolver"], KEY,
            approved_mounts=(ApprovedArchiveMount(
                "primary", "/media", str(roots[0]["library"])),),
            work_root=roots[0]["work"], retained_root=roots[0]["retained"],
            authority_reader=current, unmanic_reader=unmanic)


def test_unmanic_readback_selects_exact_work_root_and_hashes_full_config(roots):
    calls = []

    def exchange(request, deadline):
        calls.append(request)
        if request.method == "GET":
            value = {"libraries": [
                {"id": 7, "name": "Other", "path": "/other",
                 "locked": False, "enable_remote_only": False,
                 "enable_scanner": False, "enable_inotify": False,
                 "tags": []},
                {"id": 42, "name": "F30", "path": str(roots[0]["work"]),
                 "locked": True, "enable_remote_only": True,
                 "enable_scanner": False, "enable_inotify": False,
                 "tags": ["larenor"]},
            ]}
        else:
            assert json.loads(request.body) == {"id": 42}
            value = {
                "library_config": {
                    "id": 42, "name": "F30", "path": str(roots[0]["work"]),
                    "locked": True, "enable_remote_only": True,
                    "enable_scanner": False, "enable_inotify": False,
                    "priority_score": 0, "tags": ["larenor"],
                },
                "plugins": {"enabled_plugins": []},
            }
        return UnmanicResponse(
            200, "application/json", json.dumps(value).encode("utf-8"))

    result = UnmanicLibraryReadback(
        exchange, roots[0]["work"]).read_verified_library(
            deadline=time.monotonic() + 5)
    assert result.libraryId == 42 and result.workRoot == str(roots[0]["work"])
    assert len(result.configDigest) == 64
    assert [(item.method, item.path) for item in calls] == [
        ("GET", "/unmanic/api/v2/settings/libraries"),
        ("POST", "/unmanic/api/v2/settings/library/read"),
    ]

    rejected = UnmanicLibraryReadback(
        lambda _request, _deadline: UnmanicResponse(
            500, "application/json", b'{"libraries":[]}'),
        roots[0]["work"])
    with pytest.raises(ArchiveSourceResolverError) as caught:
        rejected.read_verified_library(deadline=time.monotonic() + 5)
    assert caught.value.code == "unmanic_authority_changed"


def test_private_repr_does_not_disclose_paths(roots):
    mount = ApprovedArchiveMount("primary", "/media", str(roots[0]["library"]))
    record = source_record()
    verified = VerifiedUnmanicLibrary(42, str(roots[0]["work"]), "c" * 64)
    resolver, _current, _unmanic = build(roots)
    try:
        assert repr(mount) == "ApprovedArchiveMount(<private>)"
        assert repr(record) == "AuthenticatedArchiveSourceRecord(<private>)"
        assert repr(verified) == "VerifiedUnmanicLibrary(<private>)"
        assert repr(resolver) == "PrivateMediaArchiveSourceResolver(<private>)"
    finally:
        resolver.close()


def test_runtime_factory_reads_only_exact_private_catalog_and_raw_key(roots):
    key_file = roots[0]["resolver"].parent / "resolver.key"
    key_file.write_bytes(KEY[:32])
    key_file.chmod(0o600)
    catalog_file = roots[0]["resolver"].parent / "resolver.json"
    catalog_file.write_text(json.dumps({
        "schemaVersion": 1,
        "storeRoot": str(roots[0]["resolver"]),
        "workRoot": str(roots[0]["work"]),
        "retainedRoot": str(roots[0]["retained"]),
        "authenticationKeyFile": str(key_file),
        "approvedMounts": [{
            "mountId": "primary",
            "jellyfinRoot": "/media",
            "hostRoot": str(roots[0]["library"]),
        }],
    }))
    catalog_file.chmod(0o600)
    catalog = PrivateArchiveResolverCatalog.load(catalog_file)
    assert catalog.authenticationKey == KEY[:32]
    assert repr(catalog) == "PrivateArchiveResolverCatalog(<private>)"

    def exchange(_request, _deadline):
        pytest.fail("factory must not contact Unmanic before a resolution")

    resolver = build_private_media_archive_source_resolver(
        catalog_file, authority_reader=AuthorityReader(authority()),
        unmanic_exchange=exchange)
    try:
        assert repr(resolver) == "PrivateMediaArchiveSourceResolver(<private>)"
    finally:
        resolver.close()

    publisher = build_private_media_archive_source_publisher(
        catalog_file, unmanic_exchange=exchange)
    try:
        assert repr(publisher) == "PrivateMediaArchiveSourceResolver(<private>)"
    finally:
        publisher.close()

    value = json.loads(catalog_file.read_text())
    value["libraryId"] = 7
    catalog_file.write_text(json.dumps(value))
    catalog_file.chmod(0o600)
    with pytest.raises(ArchiveSourceResolverError):
        PrivateArchiveResolverCatalog.load(catalog_file)
