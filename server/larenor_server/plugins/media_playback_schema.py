"""Durable one-use intents and receipts for managed media playback."""

from ..errors import StartupError


def migrate_media_playback(connection):
    marker = connection.execute(
        "SELECT value FROM metadata WHERE key='media_playback_schema'"
    ).fetchone()
    exists = connection.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' "
        "AND name='media_playback_intents'"
    ).fetchone()
    if marker is None:
        if exists:
            raise StartupError('media_playback_schema_unsupported')
        connection.execute('''CREATE TABLE media_playback_intents (
            id TEXT PRIMARY KEY NOT NULL CHECK(length(id)=32),
            actor_id TEXT NOT NULL CHECK(length(actor_id)=32),
            installation_id TEXT NOT NULL CHECK(length(installation_id)=32),
            installation_revision INTEGER NOT NULL CHECK(installation_revision>0),
            snapshot_revision INTEGER NOT NULL CHECK(snapshot_revision>0),
            jellyfin_service_revision INTEGER NOT NULL CHECK(jellyfin_service_revision>0),
            item_id TEXT NOT NULL CHECK(length(item_id)=32),
            media_key TEXT NOT NULL CHECK(length(media_key) BETWEEN 1 AND 96),
            playback_revision INTEGER NOT NULL CHECK(playback_revision>0),
            targets_json TEXT NOT NULL CHECK(length(targets_json)<=65536),
            expires_at INTEGER NOT NULL,
            consumed_by TEXT UNIQUE CHECK(consumed_by IS NULL OR length(consumed_by)=32)
        )''')
        connection.execute('''CREATE TABLE media_playback_receipts (
            request_id TEXT PRIMARY KEY NOT NULL CHECK(length(request_id)=32),
            intent_id TEXT UNIQUE NOT NULL REFERENCES media_playback_intents(id),
            actor_id TEXT NOT NULL CHECK(length(actor_id)=32),
            request_json TEXT NOT NULL CHECK(length(request_json)<=4096),
            state TEXT NOT NULL CHECK(state IN ('pending','succeeded')),
            receipt_json TEXT CHECK(receipt_json IS NULL OR length(receipt_json)<=4096),
            created_at INTEGER NOT NULL
        )''')
        connection.execute(
            "INSERT INTO metadata(key,value) VALUES('media_playback_schema','1')"
        )
    elif marker['value'] != '1' or not exists:
        raise StartupError('media_playback_schema_unsupported')
