"""Bounded durable schema for Music Assistant party DJ rooms."""

from ..errors import StartupError


def migrate_party_dj(connection):
    marker = connection.execute(
        "SELECT value FROM metadata WHERE key='party_dj_schema'"
    ).fetchone()
    exists = connection.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' "
        "AND name='party_dj_rooms'"
    ).fetchone()
    if marker is None:
        if exists:
            raise StartupError("party_dj_schema_unsupported")
        connection.execute("""CREATE TABLE party_dj_rooms (
            id TEXT PRIMARY KEY NOT NULL CHECK(length(id)=32),
            create_request_id TEXT UNIQUE NOT NULL CHECK(length(create_request_id)=32),
            create_actor_id TEXT NOT NULL CHECK(length(create_actor_id)=32),
            create_family_id TEXT NOT NULL CHECK(length(create_family_id)=32),
            create_hash TEXT NOT NULL CHECK(length(create_hash)=64),
            host_account_id TEXT NOT NULL CHECK(length(host_account_id)=32),
            host_family_id TEXT NOT NULL CHECK(length(host_family_id)=32),
            revision INTEGER NOT NULL CHECK(revision>0),
            authority_json TEXT NOT NULL CHECK(length(authority_json)<=8192),
            invite_digest TEXT NOT NULL CHECK(length(invite_digest)=64),
            proposal_limit INTEGER NOT NULL CHECK(proposal_limit BETWEEN 1 AND 3),
            skip_quorum_percent INTEGER NOT NULL CHECK(skip_quorum_percent BETWEEN 50 AND 100),
            skip_generation INTEGER NOT NULL CHECK(skip_generation>0),
            skip_state TEXT NOT NULL CHECK(skip_state IN ('open','executing','needs_attention')),
            skip_request_id TEXT CHECK(skip_request_id IS NULL OR length(skip_request_id)=32),
            skip_request_hash TEXT CHECK(skip_request_hash IS NULL OR length(skip_request_hash)=64),
            state TEXT NOT NULL CHECK(state IN ('active','closed')),
            expires_at INTEGER NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            envelope_tag TEXT NOT NULL CHECK(length(envelope_tag)=64)
        )""")
        connection.execute("""CREATE TABLE party_dj_participants (
            room_id TEXT NOT NULL REFERENCES party_dj_rooms(id) ON DELETE CASCADE,
            account_id TEXT NOT NULL CHECK(length(account_id)=32),
            family_id TEXT NOT NULL CHECK(length(family_id)=32),
            revision INTEGER NOT NULL CHECK(revision>0),
            request_id TEXT CHECK(request_id IS NULL OR length(request_id)=32),
            request_hash TEXT CHECK(request_hash IS NULL OR length(request_hash)=64),
            joined_at INTEGER NOT NULL,
            last_seen_at INTEGER NOT NULL,
            envelope_tag TEXT NOT NULL CHECK(length(envelope_tag)=64),
            PRIMARY KEY(room_id,account_id)
        )""")
        connection.execute("""CREATE TABLE party_dj_proposals (
            id TEXT PRIMARY KEY NOT NULL CHECK(length(id)=32),
            room_id TEXT NOT NULL REFERENCES party_dj_rooms(id) ON DELETE CASCADE,
            account_id TEXT NOT NULL CHECK(length(account_id)=32),
            family_id TEXT NOT NULL CHECK(length(family_id)=32),
            revision INTEGER NOT NULL CHECK(revision>0),
            media_uri TEXT NOT NULL CHECK(length(media_uri)<=2048),
            name TEXT NOT NULL CHECK(length(name) BETWEEN 1 AND 512),
            provider_setup_id TEXT NOT NULL CHECK(length(provider_setup_id)=32),
            provider_revision INTEGER NOT NULL CHECK(provider_revision>0),
            provider_domain TEXT NOT NULL CHECK(provider_domain IN ('spotify','apple_music','ytmusic')),
            provider_instance_id TEXT NOT NULL CHECK(length(provider_instance_id)<=128),
            manager_revision INTEGER NOT NULL CHECK(manager_revision>0),
            status TEXT NOT NULL CHECK(status IN ('pending','approving','approved','rejected','needs_attention')),
            decision_request_id TEXT CHECK(decision_request_id IS NULL OR length(decision_request_id)=32),
            decision_request_hash TEXT CHECK(decision_request_hash IS NULL OR length(decision_request_hash)=64),
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            envelope_tag TEXT NOT NULL CHECK(length(envelope_tag)=64)
        )""")
        connection.execute("""CREATE TABLE party_dj_proposal_votes (
            proposal_id TEXT NOT NULL REFERENCES party_dj_proposals(id) ON DELETE CASCADE,
            account_id TEXT NOT NULL CHECK(length(account_id)=32),
            family_id TEXT NOT NULL CHECK(length(family_id)=32),
            created_at INTEGER NOT NULL,
            envelope_tag TEXT NOT NULL CHECK(length(envelope_tag)=64),
            PRIMARY KEY(proposal_id,account_id)
        )""")
        connection.execute("""CREATE TABLE party_dj_skip_votes (
            room_id TEXT NOT NULL REFERENCES party_dj_rooms(id) ON DELETE CASCADE,
            generation INTEGER NOT NULL CHECK(generation>0),
            account_id TEXT NOT NULL CHECK(length(account_id)=32),
            family_id TEXT NOT NULL CHECK(length(family_id)=32),
            created_at INTEGER NOT NULL,
            envelope_tag TEXT NOT NULL CHECK(length(envelope_tag)=64),
            PRIMARY KEY(room_id,generation,account_id)
        )""")
        connection.execute("""CREATE TABLE party_dj_requests (
            room_id TEXT NOT NULL REFERENCES party_dj_rooms(id) ON DELETE CASCADE,
            request_id TEXT NOT NULL CHECK(length(request_id)=32),
            actor_id TEXT NOT NULL CHECK(length(actor_id)=32),
            family_id TEXT NOT NULL CHECK(length(family_id)=32),
            request_hash TEXT NOT NULL CHECK(length(request_hash)=64),
            result_json TEXT NOT NULL CHECK(length(result_json)<=262144),
            created_at INTEGER NOT NULL,
            envelope_tag TEXT NOT NULL CHECK(length(envelope_tag)=64),
            PRIMARY KEY(room_id,request_id)
        )""")
        connection.execute(
            "CREATE INDEX party_dj_room_updated ON party_dj_rooms(updated_at)")
        connection.execute(
            "CREATE INDEX party_dj_proposal_room ON "
            "party_dj_proposals(room_id,created_at,id)")
        connection.execute(
            "INSERT INTO metadata(key,value) VALUES('party_dj_schema','1')")
    elif marker["value"] != "1" or not exists:
        raise StartupError("party_dj_schema_unsupported")
