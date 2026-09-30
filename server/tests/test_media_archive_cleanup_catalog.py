import json
import time

import pytest

from larenor_server.media_archive_actions.cleanup_catalog import (
    ArchiveCleanupCatalogError, AuthenticatedArchiveCleanupItem,
    AuthenticatedArchiveTorrent, PrivateArchiveCleanupCatalog,
)
from larenor_server.media_archive_actions.models import (
    ArchiveActionAuthority, PrivateArchiveActionCommand,
)
from larenor_server.media_archive_actions.source_resolver import (
    ApprovedArchiveMount, PrivateArchiveResolverCatalog,
)
from test_media_archive_core_read import authority as collection_authority


KEY = b"cleanup catalog key material 12345"


class Authority:
    def __init__(self, value):
        self.value = value

    def current_archive_action_authority(self, installation_id, *, deadline):
        assert installation_id == self.value.installationId
        assert time.monotonic() < deadline
        return self.value


def action_authority(value):
    return ArchiveActionAuthority(
        installationId=value.installationId,
        installationRevision=value.installationRevision,
        snapshotRevision=value.snapshotRevision,
        sourceRevisions={item.serviceId: item.serviceRevision
                         for item in value.sources})


def duplicate(authority):
    return PrivateArchiveActionCommand(
        operationId="9" * 32, operation="cleanup_duplicate",
        authority=authority,
        candidate={
            "candidateId": "9" * 64, "kind": "duplicate",
            "title": "Duplicate", "potentialBytes": 100,
            "confidence": "high", "comparison": {
                "basis": "keep_largest_copy", "observedBytes": 200,
                "estimatedRetainedBytes": 100,
                "estimatedSavingBytes": 100},
            "evidence": ["content_hash_match", "multiple_playable_files",
                         "largest_copy_excluded"], "actionType": "cleanup"},
        target={"targetType": "duplicate", "keepItemId": "1" * 32,
                "deleteItemIds": ["2" * 32]},
        evidenceDigest="9" * 64, reservedBytes=0, retainOriginal=False)


@pytest.fixture
def catalog(tmp_path):
    roots = {name: tmp_path / name for name in ("store", "work", "retained", "library")}
    for root in roots.values():
        root.mkdir(mode=0o700)
    config = PrivateArchiveResolverCatalog(
        str(roots["store"]), str(roots["work"]), str(roots["retained"]),
        KEY, (ApprovedArchiveMount(
            "primary", "/media", str(roots["library"])),))
    current = collection_authority()
    action = action_authority(current)
    files = []
    records = []
    for item, name, file_id in (("1" * 32, "keep.mkv", 11),
                                ("2" * 32, "delete.mkv", 12)):
        path = roots["library"] / name
        path.write_bytes(b"x" * 100)
        path.chmod(0o600)
        files.append(path)
        records.append(AuthenticatedArchiveCleanupItem(
            item, "movie:tmdb:1", "/media/" + name, 100,
            "radarr", file_id, "/data/movies/" + name))
    return config, current, action, records, files


def test_sealed_cleanup_catalog_reopens_and_blocks_active_import(catalog):
    config, current, action, records, files = catalog
    torrent = AuthenticatedArchiveTorrent(
        "a" * 40, "movie:tmdb:2", "/data/downloads/movies/other", 50,
        "complete", True, True)
    with PrivateArchiveCleanupCatalog(config) as publisher:
        assert publisher.replace_collection_authenticated(
            current, records, [torrent], deadline=time.monotonic()+5,
            gate=lambda: True) == 1
    with PrivateArchiveCleanupCatalog(
            config, authority_reader=Authority(action)) as resolver:
        plan = resolver.resolve(duplicate(action), deadline=time.monotonic()+5)
        assert plan.keep.itemId == "1" * 32
        assert [item.itemId for item in plan.delete] == ["2" * 32]
        files[1].unlink()
        recovered = resolver.resolve(
            duplicate(action), deadline=time.monotonic()+5,
            require_delete_present=False)
        assert recovered.planDigest == plan.planDigest

    files[1].write_bytes(b"x" * 100)
    active = AuthenticatedArchiveTorrent(
        "b" * 40, "movie:tmdb:1", "/data/downloads/movies/active", 100,
        "seeding", True, False)
    with PrivateArchiveCleanupCatalog(config) as publisher:
        publisher.replace_collection_authenticated(
            current, records, [active], deadline=time.monotonic()+5,
            gate=lambda: True)
    with PrivateArchiveCleanupCatalog(
            config, authority_reader=Authority(action)) as resolver:
        with pytest.raises(ArchiveCleanupCatalogError, match="evidence_changed"):
            resolver.resolve(duplicate(action), deadline=time.monotonic()+5)


def test_cleanup_catalog_hmac_tamper_fails_closed(catalog):
    config, current, action, records, _files = catalog
    with PrivateArchiveCleanupCatalog(config) as publisher:
        publisher.replace_collection_authenticated(
            current, records, [], deadline=time.monotonic()+5,
            gate=lambda: True)
    path = config.storeRoot + "/media-archive-cleanup.json"
    value = json.loads(open(path, encoding="ascii").read())
    value["payload"]["items"][0]["serviceFileId"] += 1
    open(path, "w", encoding="ascii").write(json.dumps(value))
    with PrivateArchiveCleanupCatalog(
            config, authority_reader=Authority(action)) as resolver:
        with pytest.raises(ArchiveCleanupCatalogError):
            resolver.resolve(duplicate(action), deadline=time.monotonic()+5)
