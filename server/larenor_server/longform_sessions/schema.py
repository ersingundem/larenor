"""Durable long-form listening session schema."""

from ..errors import StartupError


_TIMER_COLUMNS = (
    ("id", "TEXT", 1, None, 1),
    ("session_id", "TEXT", 1, None, 0),
    ("generation", "INTEGER", 1, None, 0),
    ("actor_id", "TEXT", 1, None, 0),
    ("family_id", "TEXT", 1, None, 0),
    ("actor_revision", "INTEGER", 1, None, 0),
    ("session_revision", "INTEGER", 1, None, 0),
    ("state", "TEXT", 1, None, 0),
    ("deadline", "INTEGER", 1, None, 0),
    ("installation_id", "TEXT", 1, None, 0),
    ("installation_revision", "INTEGER", 1, None, 0),
    ("core_revision", "INTEGER", 1, None, 0),
    ("player_revision", "INTEGER", 1, None, 0),
    ("target_id", "TEXT", 1, None, 0),
    ("provider", "TEXT", 1, None, 0),
    ("target_kind", "TEXT", 1, None, 0),
    ("queue_id", "TEXT", 1, None, 0),
    ("group_members_json", "TEXT", 1, None, 0),
    ("outcome", "TEXT", 1, None, 0),
    ("created_at", "INTEGER", 1, None, 0),
    ("updated_at", "INTEGER", 1, None, 0),
    ("envelope_tag", "TEXT", 1, None, 0),
)


def _create_timer_table(connection):
    connection.execute("""CREATE TABLE longform_sleep_timers (
        id TEXT PRIMARY KEY NOT NULL CHECK(length(id)=32),
        session_id TEXT NOT NULL REFERENCES longform_sessions(id) ON DELETE CASCADE,
        generation INTEGER NOT NULL CHECK(generation>0),
        actor_id TEXT NOT NULL CHECK(length(actor_id)=32),
        family_id TEXT NOT NULL CHECK(length(family_id)=32),
        actor_revision INTEGER NOT NULL CHECK(actor_revision>0),
        session_revision INTEGER NOT NULL CHECK(session_revision>0),
        state TEXT NOT NULL CHECK(state IN
            ('pending','dispatching','succeeded','needs_attention','cancelled')),
        deadline INTEGER NOT NULL CHECK(deadline>0),
        installation_id TEXT NOT NULL CHECK(length(installation_id)=32),
        installation_revision INTEGER NOT NULL CHECK(installation_revision>0),
        core_revision INTEGER NOT NULL CHECK(core_revision>0),
        player_revision INTEGER NOT NULL CHECK(player_revision>0),
        target_id TEXT NOT NULL CHECK(length(target_id) BETWEEN 1 AND 128),
        provider TEXT NOT NULL CHECK(length(provider) BETWEEN 1 AND 128),
        target_kind TEXT NOT NULL CHECK(target_kind IN
            ('homepod','airplay','airplay_group','cast','cast_group','group','other')),
        queue_id TEXT NOT NULL CHECK(length(queue_id) BETWEEN 1 AND 128),
        group_members_json TEXT NOT NULL CHECK(length(group_members_json)<=16384),
        outcome TEXT NOT NULL CHECK(outcome IN
            ('scheduled','authenticated_readback','effect_unknown',
             'authority_retired','cancelled')),
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        envelope_tag TEXT NOT NULL CHECK(length(envelope_tag)=64),
        UNIQUE(session_id,generation)
    )""")
    connection.execute(
        "CREATE INDEX longform_sleep_timer_due ON "
        "longform_sleep_timers(state,deadline,id)"
    )


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
        _create_timer_table(connection)
        connection.execute(
            "INSERT INTO metadata(key,value) VALUES"
            "('longform_session_schema','2')"
        )
    elif marker["value"] == "1" and exists:
        timer_exists = connection.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' "
            "AND name='longform_sleep_timers'"
        ).fetchone()
        if timer_exists:
            raise StartupError("longform_session_schema_unsupported")
        _create_timer_table(connection)
        connection.execute(
            "UPDATE metadata SET value='2' "
            "WHERE key='longform_session_schema'"
        )
    elif marker["value"] != "2" or not exists:
        raise StartupError("longform_session_schema_unsupported")
    timer_exists = connection.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' "
        "AND name='longform_sleep_timers'"
    ).fetchone()
    columns = tuple(tuple(row) for row in connection.execute(
        "SELECT name,type,\"notnull\",dflt_value,pk FROM "
        "pragma_table_info('longform_sleep_timers')"
    ))
    if not timer_exists or columns != _TIMER_COLUMNS:
        raise StartupError("longform_session_schema_unsupported")
