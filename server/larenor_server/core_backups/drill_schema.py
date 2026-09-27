from ..errors import StartupError


_COLUMNS = (
    ("id", "TEXT", 0, None, 1),
    ("sequence", "INTEGER", 1, None, 0),
    ("revision", "INTEGER", 1, None, 0),
    ("actor_id", "TEXT", 1, None, 0),
    ("actor_revision", "INTEGER", 1, None, 0),
    ("family_id", "TEXT", 1, None, 0),
    ("request_id", "TEXT", 1, None, 0),
    ("request_hash", "TEXT", 1, None, 0),
    ("deadline_seconds", "INTEGER", 1, None, 0),
    ("state", "TEXT", 1, None, 0),
    ("cancel_requested", "INTEGER", 1, None, 0),
    ("created_at", "INTEGER", 1, None, 0),
    ("updated_at", "INTEGER", 1, None, 0),
    ("receipt_json", "TEXT", 0, None, 0),
    ("scheduled", "INTEGER", 1, "0", 0),
)
_SCHEDULE_COLUMNS = (
    ("id", "INTEGER", 0, None, 1),
    ("revision", "INTEGER", 1, None, 0),
    ("enabled", "INTEGER", 1, None, 0),
    ("next_run_at", "INTEGER", 0, None, 0),
    ("actor_id", "TEXT", 1, None, 0),
    ("actor_revision", "INTEGER", 1, None, 0),
    ("family_id", "TEXT", 1, None, 0),
    ("updated_at", "INTEGER", 1, None, 0),
)


def _verify(connection):
    columns = tuple(
        tuple(row)
        for row in connection.execute(
            'SELECT name,type,"notnull",dflt_value,pk '
            "FROM pragma_table_info('core_recovery_drills')"
        )
    )
    if columns != _COLUMNS:
        raise StartupError("core_recovery_drills_schema_unsupported")
    indexes = {row["name"]: row for row in connection.execute(
        "PRAGMA index_list(core_recovery_drills)"
    )}
    expected = {
        "sqlite_autoindex_core_recovery_drills_1",
        "sqlite_autoindex_core_recovery_drills_2",
        "sqlite_autoindex_core_recovery_drills_3",
        "core_recovery_drills_state",
        "core_recovery_drills_single_active",
    }
    if set(indexes) != expected:
        raise StartupError("core_recovery_drills_schema_unsupported")
    active = indexes["core_recovery_drills_single_active"]
    if not active["unique"] or not active["partial"]:
        raise StartupError("core_recovery_drills_schema_unsupported")
    schedule_columns = tuple(
        tuple(row)
        for row in connection.execute(
            'SELECT name,type,"notnull",dflt_value,pk '
            "FROM pragma_table_info('core_recovery_drill_schedule')"
        )
    )
    if schedule_columns != _SCHEDULE_COLUMNS:
        raise StartupError("core_recovery_drills_schema_unsupported")


def _create_schedule(connection):
    connection.execute(
        """CREATE TABLE core_recovery_drill_schedule (
            id INTEGER PRIMARY KEY CHECK(id=1),
            revision INTEGER NOT NULL CHECK(revision>0),
            enabled INTEGER NOT NULL CHECK(enabled IN (0,1)),
            next_run_at INTEGER,
            actor_id TEXT NOT NULL CHECK(length(actor_id)=32),
            actor_revision INTEGER NOT NULL CHECK(actor_revision>0),
            family_id TEXT NOT NULL CHECK(length(family_id)=32),
            updated_at INTEGER NOT NULL,
            CHECK((enabled=1 AND next_run_at IS NOT NULL) OR
                  (enabled=0 AND next_run_at IS NULL))
        )"""
    )


def migrate_core_recovery_drills(connection):
    marker = connection.execute(
        "SELECT value FROM metadata WHERE key='core_recovery_drills_schema'"
    ).fetchone()
    tables = {
        row[0]
        for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type='table' "
            "AND name LIKE 'core_recovery_drill%'"
        )
    }
    if marker is None:
        if tables:
            raise StartupError("core_recovery_drills_schema_unsupported")
        connection.execute(
            """CREATE TABLE core_recovery_drills (
                id TEXT PRIMARY KEY CHECK(length(id)=32),
                sequence INTEGER NOT NULL UNIQUE CHECK(sequence>0),
                revision INTEGER NOT NULL CHECK(revision>0),
                actor_id TEXT NOT NULL CHECK(length(actor_id)=32),
                actor_revision INTEGER NOT NULL CHECK(actor_revision>0),
                family_id TEXT NOT NULL CHECK(length(family_id)=32),
                request_id TEXT NOT NULL CHECK(length(request_id)=32),
                request_hash TEXT NOT NULL CHECK(length(request_hash)=64),
                deadline_seconds INTEGER NOT NULL CHECK(deadline_seconds BETWEEN 60 AND 3600),
                state TEXT NOT NULL CHECK(state IN (
                    'queued','running','succeeded','failed','cancelled'
                )),
                cancel_requested INTEGER NOT NULL CHECK(cancel_requested IN (0,1)),
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                receipt_json TEXT,
                scheduled INTEGER NOT NULL DEFAULT 0 CHECK(scheduled IN (0,1)),
                UNIQUE(actor_id,request_id)
            )"""
        )
        connection.execute(
            "CREATE INDEX core_recovery_drills_state "
            "ON core_recovery_drills(state,sequence)"
        )
        connection.execute(
            "CREATE UNIQUE INDEX core_recovery_drills_single_active "
            "ON core_recovery_drills((1)) WHERE state IN ('queued','running')"
        )
        _create_schedule(connection)
        connection.execute(
            "INSERT INTO metadata(key,value) "
            "VALUES('core_recovery_drills_schema','3')"
        )
    elif marker["value"] == "1" and tables == {"core_recovery_drills"}:
        _create_schedule(connection)
        connection.execute(
            "ALTER TABLE core_recovery_drills ADD COLUMN scheduled INTEGER "
            "NOT NULL DEFAULT 0 CHECK(scheduled IN (0,1))"
        )
        connection.execute(
            "UPDATE metadata SET value='3' "
            "WHERE key='core_recovery_drills_schema'"
        )
    elif marker["value"] == "2" and tables == {
        "core_recovery_drills",
        "core_recovery_drill_schedule",
    }:
        connection.execute(
            "ALTER TABLE core_recovery_drills ADD COLUMN scheduled INTEGER "
            "NOT NULL DEFAULT 0 CHECK(scheduled IN (0,1))"
        )
        connection.execute(
            "UPDATE metadata SET value='3' "
            "WHERE key='core_recovery_drills_schema'"
        )
    elif marker["value"] != "3" or tables != {
        "core_recovery_drills",
        "core_recovery_drill_schedule",
    }:
        raise StartupError("core_recovery_drills_schema_unsupported")
    _verify(connection)
