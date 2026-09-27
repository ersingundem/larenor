"""Durable offline media grant schema."""

from ..errors import StartupError


def migrate_offline_media(connection):
    marker = connection.execute(
        "SELECT value FROM metadata WHERE key='offline_media_schema'"
    ).fetchone()
    exists = connection.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' "
        "AND name='offline_media_grants'"
    ).fetchone()
    if marker is None:
        if exists:
            raise StartupError("offline_media_schema_unsupported")
        connection.execute("""CREATE TABLE offline_media_grants (
            id TEXT PRIMARY KEY NOT NULL CHECK(length(id)=32),
            actor_id TEXT NOT NULL CHECK(length(actor_id)=32),
            family_id TEXT NOT NULL CHECK(length(family_id)=32),
            actor_revision INTEGER NOT NULL CHECK(actor_revision>0),
            revision INTEGER NOT NULL CHECK(revision>0),
            authority_json TEXT NOT NULL CHECK(length(authority_json)<=4096),
            title TEXT NOT NULL CHECK(length(title) BETWEEN 1 AND 960),
            content_length INTEGER NOT NULL CHECK(content_length>0),
            content_sha256 TEXT NOT NULL CHECK(length(content_sha256)=64),
            content_type TEXT NOT NULL CHECK(length(content_type) BETWEEN 1 AND 128),
            chunk_bytes INTEGER NOT NULL CHECK(chunk_bytes BETWEEN 16384 AND 1048576),
            downloaded_bytes INTEGER NOT NULL CHECK(downloaded_bytes>=0),
            state TEXT NOT NULL CHECK(state IN ('granted','transferring','complete','revoked')),
            expires_at INTEGER NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            request_hash TEXT NOT NULL CHECK(length(request_hash)=64),
            envelope_tag TEXT NOT NULL CHECK(length(envelope_tag)=64)
        )""")
        connection.execute(
            "CREATE INDEX offline_media_actor_state ON "
            "offline_media_grants(actor_id,state,updated_at)"
        )
        connection.execute(
            "INSERT INTO metadata(key,value) VALUES('offline_media_schema','1')"
        )
    elif marker["value"] != "1" or not exists:
        raise StartupError("offline_media_schema_unsupported")
