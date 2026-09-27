"""Durable long-form listening session schema."""

from ..errors import StartupError


def migrate_longform_sessions(connection):
    marker = connection.execute(
        "SELECT value FROM metadata WHERE key='longform_session_schema'"
    ).fetchone()
    exists = connection.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' "
        "AND name='longform_sessions'"
    ).fetchone()
    if marker is None:
        if exists:
            raise StartupError("longform_session_schema_unsupported")
        connection.execute("""CREATE TABLE longform_sessions (
            id TEXT PRIMARY KEY NOT NULL CHECK(length(id)=32),
            actor_id TEXT NOT NULL CHECK(length(actor_id)=32),
            family_id TEXT NOT NULL CHECK(length(family_id)=32),
            actor_revision INTEGER NOT NULL CHECK(actor_revision>0),
            revision INTEGER NOT NULL CHECK(revision>0),
            media_key TEXT NOT NULL CHECK(length(media_key)=64),
            installation_id TEXT NOT NULL CHECK(length(installation_id)=32),
            installation_revision INTEGER NOT NULL CHECK(installation_revision>0),
            core_revision INTEGER NOT NULL CHECK(core_revision>0),
            manager_revision INTEGER NOT NULL CHECK(manager_revision>0),
            provider_instance_id TEXT NOT NULL CHECK(length(provider_instance_id)<=128),
            media_uri TEXT NOT NULL CHECK(length(media_uri)<=2048),
            media_type TEXT NOT NULL CHECK(media_type IN ('audiobook','podcast_episode')),
            title TEXT NOT NULL CHECK(length(title) BETWEEN 1 AND 2048),
            duration_seconds REAL NOT NULL CHECK(duration_seconds>0),
            position_seconds REAL NOT NULL CHECK(position_seconds>=0),
            playback_state TEXT NOT NULL CHECK(playback_state IN ('paused','playing','ended')),
            sleep_ends_at INTEGER,
            bookmarks_json TEXT NOT NULL CHECK(length(bookmarks_json)<=32768),
            request_id TEXT NOT NULL CHECK(length(request_id)=32),
            request_hash TEXT NOT NULL CHECK(length(request_hash)=64),
            updated_at INTEGER NOT NULL,
            envelope_tag TEXT NOT NULL CHECK(length(envelope_tag)=64),
            UNIQUE(actor_id,media_key)
        )""")
        connection.execute(
            "CREATE INDEX longform_session_actor_updated ON "
            "longform_sessions(actor_id,updated_at)"
        )
        connection.execute(
            "INSERT INTO metadata(key,value) VALUES"
            "('longform_session_schema','1')"
        )
    elif marker["value"] != "1" or not exists:
        raise StartupError("longform_session_schema_unsupported")
