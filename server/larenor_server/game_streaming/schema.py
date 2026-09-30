import sqlite3

from ..errors import StartupError


LEGACY_TABLES = {
    "game_stream_hosts": """CREATE TABLE game_stream_hosts (
        id TEXT PRIMARY KEY, registration_id TEXT NOT NULL UNIQUE,
        revision INTEGER NOT NULL CHECK(revision > 0), name TEXT NOT NULL,
        pairing_revision INTEGER NOT NULL CHECK(pairing_revision > 0),
        credential_digest TEXT NOT NULL, capabilities TEXT NOT NULL,
        active INTEGER NOT NULL CHECK(active IN (0,1)), created_at REAL NOT NULL,
        updated_at REAL NOT NULL, envelope_tag TEXT NOT NULL)""",
    "game_stream_sessions": """CREATE TABLE game_stream_sessions (
        id TEXT PRIMARY KEY, owner_id TEXT NOT NULL, family_id TEXT NOT NULL,
        host_id TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision > 0),
        request_key TEXT NOT NULL, request_hash TEXT NOT NULL,
        authority TEXT NOT NULL, expires_at REAL NOT NULL,
        state TEXT NOT NULL CHECK(state IN ('open','retired')),
        created_at REAL NOT NULL, envelope_tag TEXT NOT NULL,
        UNIQUE(owner_id,request_key),
        FOREIGN KEY(host_id) REFERENCES game_stream_hosts(id) ON DELETE RESTRICT)""",
    "game_stream_commands": """CREATE TABLE game_stream_commands (
        id TEXT PRIMARY KEY, session_id TEXT NOT NULL, request_key TEXT NOT NULL,
        request_hash TEXT NOT NULL, intent TEXT NOT NULL
            CHECK(intent IN ('wake','launch','stream','stop')),
        state TEXT NOT NULL CHECK(state IN ('authorized','verified','unknown','rejected')),
        result TEXT, readback_revision INTEGER, created_at REAL NOT NULL,
        completed_at REAL, envelope_tag TEXT NOT NULL,
        UNIQUE(session_id,request_key),
        FOREIGN KEY(session_id) REFERENCES game_stream_sessions(id) ON DELETE RESTRICT)""",
}

V2_TABLES = {
    "game_stream_pairings": """CREATE TABLE game_stream_pairings (
        id TEXT PRIMARY KEY, owner_id TEXT NOT NULL, family_id TEXT NOT NULL,
        actor_revision INTEGER NOT NULL CHECK(actor_revision > 0),
        revision INTEGER NOT NULL CHECK(revision > 0), request_key TEXT NOT NULL,
        request_hash TEXT NOT NULL, grant_digest TEXT, expires_at REAL NOT NULL,
        state TEXT NOT NULL CHECK(state IN ('pending','completed','retired')),
        created_at REAL NOT NULL, completed_at REAL, host_id TEXT,
        native_receipt_digest TEXT, completion_hash TEXT, envelope_tag TEXT NOT NULL,
        UNIQUE(owner_id,family_id,request_key))""",
    "game_stream_hosts": """CREATE TABLE game_stream_hosts (
        id TEXT PRIMARY KEY, pairing_id TEXT NOT NULL UNIQUE, owner_id TEXT NOT NULL,
        revision INTEGER NOT NULL CHECK(revision > 0), name TEXT NOT NULL,
        pairing_revision INTEGER NOT NULL CHECK(pairing_revision > 0),
        binding_digest TEXT NOT NULL, host_observation_digest TEXT NOT NULL,
        capabilities TEXT NOT NULL, catalog_revision INTEGER NOT NULL CHECK(catalog_revision > 0),
        catalog_digest TEXT NOT NULL, last_readback_revision INTEGER,
        assurance TEXT NOT NULL CHECK(assurance='native_observed'),
        active INTEGER NOT NULL CHECK(active IN (0,1)), created_at REAL NOT NULL,
        updated_at REAL NOT NULL, envelope_tag TEXT NOT NULL,
        FOREIGN KEY(pairing_id) REFERENCES game_stream_pairings(id) ON DELETE RESTRICT)""",
    "game_stream_catalog_observations": """CREATE TABLE game_stream_catalog_observations (
        id TEXT PRIMARY KEY, host_id TEXT NOT NULL, owner_id TEXT NOT NULL,
        family_id TEXT NOT NULL, actor_revision INTEGER NOT NULL CHECK(actor_revision > 0),
        revision INTEGER NOT NULL CHECK(revision > 0), request_key TEXT NOT NULL,
        request_hash TEXT NOT NULL, grant_digest TEXT,
        expected_host_revision INTEGER NOT NULL CHECK(expected_host_revision > 0),
        expected_pairing_revision INTEGER NOT NULL CHECK(expected_pairing_revision > 0),
        expected_catalog_revision INTEGER NOT NULL CHECK(expected_catalog_revision > 0),
        expires_at REAL NOT NULL,
        state TEXT NOT NULL CHECK(state IN ('pending','completed','retired')),
        created_at REAL NOT NULL, completed_at REAL, native_receipt_digest TEXT,
        completion_hash TEXT, envelope_tag TEXT NOT NULL,
        UNIQUE(owner_id,family_id,request_key),
        FOREIGN KEY(host_id) REFERENCES game_stream_hosts(id) ON DELETE RESTRICT)""",
    "game_stream_apps": """CREATE TABLE game_stream_apps (
        id TEXT PRIMARY KEY, host_id TEXT NOT NULL, sequence INTEGER NOT NULL CHECK(sequence >= 0),
        observation_digest TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision > 0),
        name TEXT NOT NULL, active INTEGER NOT NULL CHECK(active IN (0,1)),
        envelope_tag TEXT NOT NULL, UNIQUE(host_id,sequence),
        FOREIGN KEY(host_id) REFERENCES game_stream_hosts(id) ON DELETE RESTRICT)""",
    "game_stream_sessions": """CREATE TABLE game_stream_sessions (
        id TEXT PRIMARY KEY, owner_id TEXT NOT NULL, family_id TEXT NOT NULL,
        host_id TEXT NOT NULL, app_id TEXT NOT NULL,
        revision INTEGER NOT NULL CHECK(revision > 0), request_key TEXT NOT NULL,
        request_hash TEXT NOT NULL, core_authority TEXT NOT NULL,
        client_authority TEXT NOT NULL, expires_at REAL NOT NULL,
        state TEXT NOT NULL CHECK(state IN ('open','retired')),
        last_request_key TEXT, last_request_hash TEXT, created_at REAL NOT NULL,
        updated_at REAL NOT NULL, envelope_tag TEXT NOT NULL,
        UNIQUE(owner_id,family_id,request_key),
        FOREIGN KEY(host_id) REFERENCES game_stream_hosts(id) ON DELETE RESTRICT,
        FOREIGN KEY(app_id) REFERENCES game_stream_apps(id) ON DELETE RESTRICT)""",
    "game_stream_commands": """CREATE TABLE game_stream_commands (
        id TEXT PRIMARY KEY, session_id TEXT NOT NULL, request_key TEXT NOT NULL,
        request_hash TEXT NOT NULL, intent TEXT NOT NULL
            CHECK(intent IN ('wake','launch','stream','stop')),
        state TEXT NOT NULL CHECK(state IN ('authorized','native_observed','unknown','rejected')),
        result TEXT, observation_kind TEXT, readback_revision INTEGER,
        native_receipt_digest TEXT, grant_digest TEXT, completion_hash TEXT,
        created_at REAL NOT NULL, completed_at REAL, envelope_tag TEXT NOT NULL,
        UNIQUE(session_id,request_key),
        FOREIGN KEY(session_id) REFERENCES game_stream_sessions(id) ON DELETE RESTRICT)""",
    "game_stream_revocations": """CREATE TABLE game_stream_revocations (
        id TEXT PRIMARY KEY, host_id TEXT NOT NULL, owner_id TEXT NOT NULL,
        family_id TEXT NOT NULL,
        request_key TEXT NOT NULL, request_hash TEXT NOT NULL,
        host_revision INTEGER NOT NULL CHECK(host_revision > 0),
        binding_digest TEXT NOT NULL,
        state TEXT NOT NULL CHECK(state IN ('core_retired','local_cleared','unknown')),
        completion_hash TEXT, created_at REAL NOT NULL, completed_at REAL,
        envelope_tag TEXT NOT NULL, UNIQUE(owner_id,family_id,request_key),
        FOREIGN KEY(host_id) REFERENCES game_stream_hosts(id) ON DELETE RESTRICT)""",
}

TABLES = {
    **V2_TABLES,
    "game_stream_revocations": """CREATE TABLE game_stream_revocations (
        id TEXT PRIMARY KEY, host_id TEXT NOT NULL, owner_id TEXT NOT NULL,
        family_id TEXT NOT NULL,
        request_key TEXT NOT NULL, request_hash TEXT NOT NULL,
        host_revision INTEGER NOT NULL CHECK(host_revision > 0),
        binding_digest TEXT NOT NULL,
        state TEXT NOT NULL CHECK(state IN ('core_retired','local_cleared','unknown')),
        completion_hash TEXT, created_at REAL NOT NULL, completed_at REAL,
        envelope_tag TEXT NOT NULL, readback_revision INTEGER,
        native_receipt_digest TEXT, UNIQUE(owner_id,family_id,request_key),
        FOREIGN KEY(host_id) REFERENCES game_stream_hosts(id) ON DELETE RESTRICT)""",
}


def _exact(actual, expected):
    return set(actual) == set(expected) and all(
        row["type"] == "table"
        and " ".join(row["sql"].split()) == " ".join(expected[name].split())
        for name, row in actual.items()
    )


def migrate_game_streaming(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='game_stream_schema'"
        ).fetchone()
        rows = connection.execute(
            "SELECT name,type,sql FROM sqlite_master WHERE name GLOB 'game_stream_*'"
        ).fetchall()
        actual = {row["name"]: row for row in rows if row["sql"] is not None}
        if marker is None:
            if actual:
                raise ValueError("unmarked_game_stream_storage")
            for statement in TABLES.values():
                connection.execute(statement)
            connection.execute("INSERT INTO metadata VALUES('game_stream_schema','3')")
            return
        if marker["value"] == "1" and _exact(actual, LEGACY_TABLES):
            # v1 rows were based on caller declarations. Retire rather than promote them.
            for name in ("game_stream_commands", "game_stream_sessions", "game_stream_hosts"):
                connection.execute(f"DROP TABLE {name}")
            for statement in TABLES.values():
                connection.execute(statement)
            connection.execute(
                "UPDATE metadata SET value='3' WHERE key='game_stream_schema'")
            return
        if marker["value"] == "2" and _exact(actual, V2_TABLES):
            connection.execute(
                "ALTER TABLE game_stream_revocations ADD COLUMN readback_revision INTEGER")
            connection.execute(
                "ALTER TABLE game_stream_revocations ADD COLUMN native_receipt_digest TEXT")
            connection.execute(
                "UPDATE metadata SET value='3' WHERE key='game_stream_schema'")
            rows = connection.execute(
                "SELECT name,type,sql FROM sqlite_master WHERE name GLOB 'game_stream_*'"
            ).fetchall()
            actual = {row["name"]: row for row in rows if row["sql"] is not None}
        if marker["value"] not in ("2", "3") or not _exact(actual, TABLES):
            raise ValueError("invalid_game_stream_storage")
    except (sqlite3.Error, TypeError, ValueError):
        raise StartupError("game_stream_storage_invalid") from None
