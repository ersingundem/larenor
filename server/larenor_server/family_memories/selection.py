import hashlib
import hmac
import json
import math
import secrets
import sqlite3
import time
from collections.abc import Callable
from dataclasses import asdict, dataclass

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..auth import Principal
from ..database import Database
from ..errors import ApiError, StartupError
from .models import _id, _safe_text, _uuid

MAX_ALBUMS = 64
MAX_ASSETS = 250
MAX_MEMBERS = 32


@dataclass(frozen=True)
class MemoryAlbumAuthority:
    core_id: str
    home_id: str
    account_id: str
    session_id: str
    members_revision: int

    def __post_init__(self):
        if (
            not all(
                _id(value)
                for value in (
                    self.core_id,
                    self.home_id,
                    self.account_id,
                    self.session_id,
                )
            )
            or type(self.members_revision) is not int
            or not 1 <= self.members_revision <= 2**63 - 1
        ):
            raise ValueError("invalid_memory_authority")


@dataclass(frozen=True)
class MemorySelection:
    asset_id: str
    source_album_id: str
    source_etag: str

    def __post_init__(self):
        if (
            not _uuid(self.asset_id)
            or not _uuid(self.source_album_id)
            or not isinstance(self.source_etag, str)
            or len(self.source_etag) != 64
            or any(
                character not in "0123456789abcdef" for character in self.source_etag
            )
        ):
            raise ValueError("invalid_memory_selection")


@dataclass(frozen=True)
class MemoryAlbum:
    id: str
    revision: int
    title: str
    visibility: str
    owner_id: str
    member_ids: tuple[str, ...]
    service_id: str
    service_revision: int
    assets: tuple[MemorySelection, ...]
    updated_at: float


class MemoryAlbumStore:
    """Encrypted selection manifests; originals and provider credentials never enter SQLite."""

    def __init__(
        self,
        database: Database,
        *,
        encryption_key: bytes,
        audit_key: bytes,
        clock: Callable[[], float] = time.time,
    ):
        if (
            not isinstance(encryption_key, bytes)
            or len(encryption_key) != 32
            or not isinstance(audit_key, bytes)
            or len(audit_key) != 32
            or not callable(clock)
        ):
            raise ValueError("invalid_memory_album_keys")
        self.database = database
        self._cipher = AESGCM(encryption_key)
        self._audit_key = audit_key
        self._clock = clock

    @staticmethod
    def migrate(connection: sqlite3.Connection) -> None:
        try:
            marker = connection.execute(
                "SELECT value FROM metadata WHERE key='memory_album_schema'"
            ).fetchone()
            row = connection.execute(
                "SELECT sql FROM sqlite_master WHERE type='table' AND name='memory_albums'"
            ).fetchone()
            expected = """CREATE TABLE memory_albums (
                id TEXT PRIMARY KEY, core_id TEXT NOT NULL, home_id TEXT NOT NULL,
                owner_id TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision > 0),
                service_id TEXT NOT NULL, service_revision INTEGER NOT NULL CHECK(service_revision > 0),
                nonce BLOB NOT NULL, ciphertext BLOB NOT NULL, payload_hash TEXT NOT NULL,
                updated_at REAL NOT NULL, record_hash TEXT NOT NULL)"""
            if marker is None:
                if row is not None:
                    raise ValueError
                connection.execute(expected)
                connection.execute(
                    "CREATE INDEX memory_album_scope ON memory_albums(core_id,home_id,owner_id,updated_at,id)"
                )
                connection.execute(
                    "INSERT INTO metadata VALUES('memory_album_schema','1')"
                )
                return
            indexes = connection.execute(
                "SELECT sql FROM sqlite_master WHERE type='index' AND name='memory_album_scope'"
            ).fetchone()
            if (
                marker["value"] != "1"
                or row is None
                or " ".join(row["sql"].split()) != " ".join(expected.split())
                or indexes is None
            ):
                raise ValueError
        except (sqlite3.Error, TypeError, ValueError):
            raise StartupError("memory_album_storage_invalid") from None

    @staticmethod
    def _scope(authority: MemoryAlbumAuthority):
        return authority.core_id, authority.home_id

    @staticmethod
    def _authorize(actor: Principal, authority: MemoryAlbumAuthority):
        if actor.id != authority.account_id or actor.family_id != authority.session_id:
            raise ApiError("memory_authority_changed", 409)

    def _aad(self, row) -> bytes:
        return (
            f"larenor-memory-album-v1:{row['id']}:{row['core_id']}:{row['home_id']}:"
            f"{row['owner_id']}:{row['revision']}:{row['service_id']}:{row['service_revision']}"
        ).encode("ascii")

    def _record_hash(self, row) -> str:
        values = [
            row[key]
            for key in (
                "id",
                "core_id",
                "home_id",
                "owner_id",
                "revision",
                "service_id",
                "service_revision",
                "payload_hash",
                "updated_at",
            )
        ]
        return hmac.new(
            self._audit_key,
            b"larenor-memory-album-record-v1\0"
            + json.dumps(values, separators=(",", ":")).encode(),
            hashlib.sha256,
        ).hexdigest()

    def _decode(self, row) -> MemoryAlbum:
        try:
            if not hmac.compare_digest(row["record_hash"], self._record_hash(row)):
                raise ValueError
            plain = self._cipher.decrypt(
                row["nonce"], row["ciphertext"], self._aad(row)
            )
            if not hmac.compare_digest(
                hashlib.sha256(plain).hexdigest(), row["payload_hash"]
            ):
                raise ValueError
            value = json.loads(plain)
            assets = tuple(MemorySelection(**item) for item in value.pop("assets"))
            members = tuple(value.pop("member_ids"))
            album = MemoryAlbum(
                id=row["id"],
                revision=row["revision"],
                owner_id=row["owner_id"],
                service_id=row["service_id"],
                service_revision=row["service_revision"],
                updated_at=row["updated_at"],
                member_ids=members,
                assets=assets,
                **value,
            )
            self._validate_album(album)
            return album
        except (InvalidTag, KeyError, TypeError, ValueError, json.JSONDecodeError):
            raise StartupError("memory_album_storage_invalid") from None

    @staticmethod
    def _validate_album(album: MemoryAlbum) -> None:
        if (
            not _id(album.id)
            or not _id(album.owner_id)
            or not _id(album.service_id)
            or type(album.revision) is not int
            or not 1 <= album.revision <= 2**63 - 1
            or type(album.service_revision) is not int
            or not 1 <= album.service_revision <= 2**63 - 1
            or not _safe_text(album.title, 120)
            or album.visibility not in {"personal", "shared"}
            or not isinstance(album.member_ids, tuple)
            or not 1 <= len(album.member_ids) <= MAX_MEMBERS
            or len(set(album.member_ids)) != len(album.member_ids)
            or album.owner_id not in album.member_ids
            or any(not _id(item) for item in album.member_ids)
            or album.visibility == "personal"
            and album.member_ids != (album.owner_id,)
            or not isinstance(album.assets, tuple)
            or len(album.assets) > MAX_ASSETS
            or len({item.asset_id for item in album.assets}) != len(album.assets)
            or not isinstance(album.updated_at, (int, float))
            or isinstance(album.updated_at, bool)
            or not math.isfinite(album.updated_at)
            or album.updated_at < 0
        ):
            raise ValueError("invalid_memory_album")

    def _save(self, connection, album: MemoryAlbum, scope: tuple[str, str]) -> None:
        self._validate_album(album)
        payload = json.dumps(
            {
                "title": album.title,
                "visibility": album.visibility,
                "member_ids": list(album.member_ids),
                "assets": [asdict(item) for item in album.assets],
            },
            sort_keys=True,
            separators=(",", ":"),
        ).encode()
        nonce = secrets.token_bytes(12)
        shell = {
            "id": album.id,
            "core_id": scope[0],
            "home_id": scope[1],
            "owner_id": album.owner_id,
            "revision": album.revision,
            "service_id": album.service_id,
            "service_revision": album.service_revision,
            "payload_hash": hashlib.sha256(payload).hexdigest(),
            "updated_at": album.updated_at,
        }
        ciphertext = self._cipher.encrypt(nonce, payload, self._aad(shell))
        shell["record_hash"] = self._record_hash(shell)
        connection.execute(
            "INSERT INTO memory_albums VALUES(?,?,?,?,?,?,?,?,?,?,?,?) "
            "ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,"
            "service_revision=excluded.service_revision,nonce=excluded.nonce,"
            "ciphertext=excluded.ciphertext,payload_hash=excluded.payload_hash,"
            "updated_at=excluded.updated_at,record_hash=excluded.record_hash",
            (
                shell["id"],
                shell["core_id"],
                shell["home_id"],
                shell["owner_id"],
                shell["revision"],
                shell["service_id"],
                shell["service_revision"],
                nonce,
                ciphertext,
                shell["payload_hash"],
                shell["updated_at"],
                shell["record_hash"],
            ),
        )

    def create(
        self,
        actor: Principal,
        authority: MemoryAlbumAuthority,
        *,
        album_id: str,
        title: str,
        visibility: str,
        member_ids: tuple[str, ...],
        service_id: str,
        service_revision: int,
    ) -> MemoryAlbum:
        self._authorize(actor, authority)
        now = self._clock()
        album = MemoryAlbum(
            album_id,
            1,
            title.strip(),
            visibility,
            actor.id,
            member_ids,
            service_id,
            service_revision,
            (),
            now,
        )
        self._validate_album(album)
        scope = self._scope(authority)
        with self.database.transaction() as connection:
            count = connection.execute(
                "SELECT COUNT(*) FROM memory_albums WHERE core_id=? AND home_id=?",
                scope,
            ).fetchone()[0]
            if count >= MAX_ALBUMS:
                raise ApiError("memory_album_limit_reached", 413)
            if connection.execute(
                "SELECT 1 FROM memory_albums WHERE id=?", (album_id,)
            ).fetchone():
                raise ApiError("memory_album_conflict", 409)
            self._save(connection, album, scope)
        return album

    def read(
        self, actor: Principal, authority: MemoryAlbumAuthority, album_id: str
    ) -> MemoryAlbum:
        self._authorize(actor, authority)
        with self.database.connection() as connection:
            row = connection.execute(
                "SELECT * FROM memory_albums WHERE id=?", (album_id,)
            ).fetchone()
            if row is None or (row["core_id"], row["home_id"]) != self._scope(
                authority
            ):
                raise ApiError("not_found", 404)
            album = self._decode(row)
        if actor.id not in album.member_ids:
            raise ApiError("not_found", 404)
        return album

    def replace(
        self,
        actor: Principal,
        authority: MemoryAlbumAuthority,
        *,
        album_id: str,
        expected_revision: int,
        service_id: str,
        service_revision: int,
        assets: tuple[MemorySelection, ...],
    ) -> MemoryAlbum:
        current = self.read(actor, authority, album_id)
        if (
            current.revision != expected_revision
            or current.service_id != service_id
            or current.service_revision != service_revision
            or expected_revision >= 2**63 - 1
        ):
            raise ApiError("memory_album_changed", 409)
        updated = MemoryAlbum(
            **{
                **asdict(current),
                "revision": current.revision + 1,
                "assets": assets,
                "updated_at": self._clock(),
            }
        )
        self._validate_album(updated)
        with self.database.transaction() as connection:
            row = connection.execute(
                "SELECT revision FROM memory_albums WHERE id=?", (album_id,)
            ).fetchone()
            if row is None or row["revision"] != expected_revision:
                raise ApiError("memory_album_changed", 409)
            self._save(connection, updated, self._scope(authority))
        return updated

    def purge_source_asset(
        self, *, service_id: str, service_revision: int, asset_id: str
    ) -> int:
        if (
            not _id(service_id)
            or not _uuid(asset_id)
            or type(service_revision) is not int
            or service_revision < 1
        ):
            raise ApiError("invalid_request", 400)
        changed = 0
        with self.database.transaction() as connection:
            rows = connection.execute(
                "SELECT * FROM memory_albums WHERE service_id=? AND service_revision=? ORDER BY id",
                (service_id, service_revision),
            ).fetchall()
            for row in rows:
                album = self._decode(row)
                assets = tuple(
                    item for item in album.assets if item.asset_id != asset_id
                )
                if assets == album.assets:
                    continue
                updated = MemoryAlbum(
                    **{
                        **asdict(album),
                        "revision": album.revision + 1,
                        "assets": assets,
                        "updated_at": self._clock(),
                    }
                )
                self._save(connection, updated, (row["core_id"], row["home_id"]))
                changed += 1
        return changed
