"""Durable watch-party room and participant schema."""

from ..errors import StartupError


def migrate_watch_parties(connection):
    marker = connection.execute(
        "SELECT value FROM metadata WHERE key='watch_party_schema'"
    ).fetchone()
    exists = connection.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' "
        "AND name='watch_party_rooms'"
    ).fetchone()
    if marker is None:
        if exists:
            raise StartupError("watch_party_schema_unsupported")
        connection.execute("""CREATE TABLE watch_party_rooms (
            id TEXT PRIMARY KEY NOT NULL CHECK(length(id)=32),
            create_request_id TEXT UNIQUE NOT NULL CHECK(length(create_request_id)=32),
            create_actor_id TEXT NOT NULL CHECK(length(create_actor_id)=32),
            create_hash TEXT NOT NULL CHECK(length(create_hash)=64),
            leader_account_id TEXT NOT NULL CHECK(length(leader_account_id)=32),
            leader_family_id TEXT NOT NULL CHECK(length(leader_family_id)=32),
            revision INTEGER NOT NULL CHECK(revision>0),
            authority_json TEXT NOT NULL CHECK(length(authority_json)<=4096),
            invite_digest TEXT NOT NULL CHECK(length(invite_digest)=64),
            tolerance_ms INTEGER NOT NULL CHECK(tolerance_ms BETWEEN 250 AND 5000),
            command_revision INTEGER NOT NULL CHECK(command_revision>0),
            command_json TEXT NOT NULL CHECK(length(command_json)<=1024),
            state TEXT NOT NULL CHECK(state IN ('active','closed')),
            expires_at INTEGER NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            envelope_tag TEXT NOT NULL CHECK(length(envelope_tag)=64)
        )""")
        connection.execute("""CREATE TABLE watch_party_participants (
            room_id TEXT NOT NULL REFERENCES watch_party_rooms(id) ON DELETE CASCADE,
            account_id TEXT NOT NULL CHECK(length(account_id)=32),
            family_id TEXT NOT NULL CHECK(length(family_id)=32),
            revision INTEGER NOT NULL CHECK(revision>0),
            request_id TEXT NOT NULL CHECK(length(request_id)=32),
            request_hash TEXT NOT NULL CHECK(length(request_hash)=64),
            target_json TEXT CHECK(target_json IS NULL OR length(target_json)<=2048),
            playback_json TEXT CHECK(playback_json IS NULL OR length(playback_json)<=2048),
            joined_at INTEGER NOT NULL,
            last_seen_at INTEGER NOT NULL,
            envelope_tag TEXT NOT NULL CHECK(length(envelope_tag)=64),
            PRIMARY KEY(room_id,account_id)
        )""")
        connection.execute(
            "CREATE UNIQUE INDEX watch_party_join_requests ON "
            "watch_party_participants(room_id,account_id,request_id)"
        )
        connection.execute(
            "INSERT INTO metadata(key,value) VALUES('watch_party_schema','1')"
        )
    elif marker["value"] != "1" or not exists:
        raise StartupError("watch_party_schema_unsupported")
