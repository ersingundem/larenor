from pathlib import Path

import pytest
from larenor_server.auth import Principal
from larenor_server.database import Database
from larenor_server.errors import ApiError, StartupError
from larenor_server.family_memories import (
    MemoryAlbumAuthority,
    MemoryAlbumStore,
    MemorySelection,
)

OWNER = "a" * 32
MEMBER = "b" * 32
OUTSIDER = "c" * 32
SESSION = "d" * 32
CORE = "e" * 32
HOME = "f" * 32
SERVICE = "1" * 32
ALBUM = "2" * 32
SOURCE_ALBUM = "11111111-1111-4111-8111-111111111111"
ASSET = "22222222-2222-4222-8222-222222222222"
OTHER_ASSET = "33333333-3333-4333-8333-333333333333"


def actor(account=OWNER, family=SESSION):
    return Principal(account, "member", "member", False, family, "token")


def authority(account=OWNER, family=SESSION):
    return MemoryAlbumAuthority(CORE, HOME, account, family, 7)


def selection(asset=ASSET):
    return MemorySelection(asset, SOURCE_ALBUM, "9" * 64)


def store(path: Path, *, now=1_800_000_000.0):
    database = Database(path)
    if not path.exists():
        database.create_schema()
    with database.transaction() as connection:
        MemoryAlbumStore.migrate(connection)
    return MemoryAlbumStore(
        database,
        encryption_key=bytes.fromhex("38" * 32),
        audit_key=bytes.fromhex("83" * 32),
        clock=lambda: now,
    )


def test_personal_and_shared_membership_stays_encrypted_and_fail_closed(tmp_path):
    path = tmp_path / "core.sqlite3"
    albums = store(path)
    personal = albums.create(
        actor(),
        authority(),
        album_id=ALBUM,
        title="Aile yazı",
        visibility="personal",
        member_ids=(OWNER,),
        service_id=SERVICE,
        service_revision=4,
    )
    updated = albums.replace(
        actor(),
        authority(),
        album_id=ALBUM,
        expected_revision=personal.revision,
        service_id=SERVICE,
        service_revision=4,
        assets=(selection(),),
    )
    assert updated.revision == 2
    assert albums.read(actor(), authority(), ALBUM).assets == (selection(),)
    with pytest.raises(ApiError, match="not_found"):
        albums.read(actor(MEMBER), authority(MEMBER), ALBUM)
    with pytest.raises(ApiError, match="memory_authority_changed"):
        albums.read(actor(family="0" * 32), authority(), ALBUM)
    with Database(path).connection() as connection:
        row = connection.execute("SELECT ciphertext FROM memory_albums").fetchone()
    assert b"Aile" not in row["ciphertext"]
    assert ASSET.encode() not in row["ciphertext"]


def test_shared_album_allows_only_exact_members_and_revision_bound_replace(tmp_path):
    albums = store(tmp_path / "core.sqlite3")
    created = albums.create(
        actor(),
        authority(),
        album_id=ALBUM,
        title="Paylaşılan anılar",
        visibility="shared",
        member_ids=(OWNER, MEMBER),
        service_id=SERVICE,
        service_revision=4,
    )
    assert albums.read(actor(MEMBER), authority(MEMBER), ALBUM).title == created.title
    with pytest.raises(ApiError, match="not_found"):
        albums.read(actor(OUTSIDER), authority(OUTSIDER), ALBUM)
    with pytest.raises(ApiError, match="memory_album_changed"):
        albums.replace(
            actor(),
            authority(),
            album_id=ALBUM,
            expected_revision=2,
            service_id=SERVICE,
            service_revision=4,
            assets=(selection(),),
        )
    with pytest.raises(ApiError, match="memory_album_changed"):
        albums.replace(
            actor(),
            authority(),
            album_id=ALBUM,
            expected_revision=1,
            service_id=SERVICE,
            service_revision=5,
            assets=(selection(),),
        )


def test_source_deletion_purges_every_manifest_and_tampering_blocks_reads(tmp_path):
    path = tmp_path / "core.sqlite3"
    albums = store(path)
    created = albums.create(
        actor(),
        authority(),
        album_id=ALBUM,
        title="Tablet albümü",
        visibility="shared",
        member_ids=(OWNER, MEMBER),
        service_id=SERVICE,
        service_revision=4,
    )
    albums.replace(
        actor(),
        authority(),
        album_id=ALBUM,
        expected_revision=created.revision,
        service_id=SERVICE,
        service_revision=4,
        assets=(selection(), selection(OTHER_ASSET)),
    )
    assert (
        albums.purge_source_asset(
            service_id=SERVICE,
            service_revision=4,
            asset_id=ASSET,
        )
        == 1
    )
    current = albums.read(actor(), authority(), ALBUM)
    assert current.revision == 3
    assert [item.asset_id for item in current.assets] == [OTHER_ASSET]
    assert (
        albums.purge_source_asset(
            service_id=SERVICE,
            service_revision=4,
            asset_id=ASSET,
        )
        == 0
    )
    with Database(path).transaction() as connection:
        connection.execute(
            "UPDATE memory_albums SET owner_id=? WHERE id=?", (OUTSIDER, ALBUM)
        )
    with pytest.raises(StartupError, match="memory_album_storage_invalid"):
        albums.read(actor(), authority(), ALBUM)
