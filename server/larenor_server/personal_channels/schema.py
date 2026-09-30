"""Durable bounded storage for personal television channels."""

from ..errors import StartupError


def migrate_personal_channels(connection):
    marker = connection.execute(
        "SELECT value FROM metadata WHERE key='personal_channels_schema'"
    ).fetchone()
    names = {row["name"] for row in connection.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND "
        "name IN ('personal_channels','personal_channel_programmes',"
        "'personal_channel_executions')"
    ).fetchall()}
    original = {"personal_channels", "personal_channel_programmes"}
    expected = {*original, "personal_channel_executions"}
    if marker is None:
        if names:
            raise StartupError("personal_channel_schema_unsupported")
        connection.execute("""CREATE TABLE personal_channels (
            id TEXT PRIMARY KEY NOT NULL CHECK(length(id)=32),
            owner_id TEXT NOT NULL CHECK(length(owner_id)=32),
            family_id TEXT NOT NULL CHECK(length(family_id)=32),
            actor_revision INTEGER NOT NULL CHECK(actor_revision>0),
            revision INTEGER NOT NULL CHECK(revision>0),
            name TEXT NOT NULL CHECK(length(name) BETWEEN 1 AND 320),
            starts_at INTEGER NOT NULL,
            loop INTEGER NOT NULL CHECK(loop IN (0,1)),
            cycle_seconds INTEGER NOT NULL CHECK(cycle_seconds BETWEEN 60 AND 604800),
            state TEXT NOT NULL CHECK(state IN ('active','cancelled')),
            create_request_id TEXT NOT NULL UNIQUE CHECK(length(create_request_id)=32),
            create_request_hash TEXT NOT NULL CHECK(length(create_request_hash)=64),
            last_request_id TEXT CHECK(last_request_id IS NULL OR length(last_request_id)=32),
            last_request_hash TEXT CHECK(last_request_hash IS NULL OR length(last_request_hash)=64),
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            envelope_tag TEXT NOT NULL CHECK(length(envelope_tag)=64),
            FOREIGN KEY(owner_id) REFERENCES users(id) ON DELETE CASCADE
        )""")
        connection.execute("""CREATE TABLE personal_channel_programmes (
            id TEXT PRIMARY KEY NOT NULL CHECK(length(id)=32),
            channel_id TEXT NOT NULL CHECK(length(channel_id)=32),
            position INTEGER NOT NULL CHECK(position BETWEEN 0 AND 63),
            revision INTEGER NOT NULL CHECK(revision>0),
            title TEXT NOT NULL CHECK(length(title) BETWEEN 1 AND 960),
            duration_seconds INTEGER NOT NULL CHECK(duration_seconds BETWEEN 60 AND 86400),
            authority_json TEXT CHECK(authority_json IS NULL OR length(authority_json)<=2048),
            state TEXT NOT NULL CHECK(state IN ('scheduled','gap')),
            reason TEXT NOT NULL CHECK(reason IN ('available','deleted','unreachable')),
            envelope_tag TEXT NOT NULL CHECK(length(envelope_tag)=64),
            UNIQUE(channel_id,position),
            FOREIGN KEY(channel_id) REFERENCES personal_channels(id) ON DELETE CASCADE
        )""")
        connection.execute(
            "CREATE INDEX personal_channels_owner ON "
            "personal_channels(owner_id,state,updated_at)"
        )
        _create_executions(connection)
        connection.execute(
            "INSERT INTO metadata(key,value) VALUES('personal_channels_schema','2')"
        )
    elif marker["value"] == "1" and names == original:
        _create_executions(connection)
        connection.execute(
            "UPDATE metadata SET value='2' WHERE key='personal_channels_schema'"
        )
    elif marker["value"] != "2" or names != expected:
        raise StartupError("personal_channel_schema_unsupported")


def _create_executions(connection):
    connection.execute("""CREATE TABLE personal_channel_executions (
        channel_id TEXT PRIMARY KEY NOT NULL CHECK(length(channel_id)=32),
        owner_id TEXT NOT NULL CHECK(length(owner_id)=32),
        family_id TEXT NOT NULL CHECK(length(family_id)=32),
        actor_revision INTEGER NOT NULL CHECK(actor_revision>0),
        channel_revision INTEGER NOT NULL CHECK(channel_revision>0),
        revision INTEGER NOT NULL CHECK(revision>0),
        target_id TEXT NOT NULL CHECK(length(target_id) BETWEEN 1 AND 128),
        state TEXT NOT NULL CHECK(state IN
            ('active','dispatching','needs_attention','cancelled')),
        code TEXT NOT NULL CHECK(code IN
            ('scheduled','authenticated_readback','effect_unknown','gap',
             'source_changed','authority_changed','source_unavailable',
             'target_unavailable','cancelled')),
        programme_id TEXT CHECK(programme_id IS NULL OR length(programme_id)=32),
        programme_revision INTEGER CHECK(
            programme_revision IS NULL OR programme_revision>0),
        occurrence_starts_at INTEGER,
        occurrence_ends_at INTEGER,
        intent_id TEXT CHECK(intent_id IS NULL OR length(intent_id)=32),
        command_id TEXT CHECK(command_id IS NULL OR length(command_id)=32),
        last_request_id TEXT NOT NULL CHECK(length(last_request_id)=32),
        last_request_hash TEXT NOT NULL CHECK(length(last_request_hash)=64),
        updated_at INTEGER NOT NULL,
        envelope_tag TEXT NOT NULL CHECK(length(envelope_tag)=64),
        FOREIGN KEY(channel_id) REFERENCES personal_channels(id) ON DELETE CASCADE,
        FOREIGN KEY(owner_id) REFERENCES users(id) ON DELETE CASCADE,
        CHECK((programme_id IS NULL)=(programme_revision IS NULL)),
        CHECK((programme_id IS NULL)=(occurrence_starts_at IS NULL)),
        CHECK((programme_id IS NULL)=(occurrence_ends_at IS NULL)),
        CHECK(occurrence_starts_at IS NULL OR
              occurrence_starts_at<occurrence_ends_at),
        CHECK((intent_id IS NULL)=(command_id IS NULL))
    )""")
    connection.execute(
        "CREATE INDEX personal_channel_executions_state ON "
        "personal_channel_executions(state,updated_at,channel_id)"
    )
