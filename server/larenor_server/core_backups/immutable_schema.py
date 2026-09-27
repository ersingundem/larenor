from ..errors import StartupError


_COLUMNS = (
    ("id", "INTEGER", 0, None, 1),
    ("revision", "INTEGER", 1, None, 0),
    ("endpoint", "TEXT", 1, None, 0),
    ("target_id", "TEXT", 1, None, 0),
    ("retention_days", "INTEGER", 1, None, 0),
    ("quota_bytes", "INTEGER", 1, None, 0),
    ("nonce", "BLOB", 1, None, 0),
    ("ciphertext", "BLOB", 1, None, 0),
    ("configured_at", "INTEGER", 1, None, 0),
    ("actor_id", "TEXT", 0, None, 0),
    ("actor_revision", "INTEGER", 0, None, 0),
    ("family_id", "TEXT", 0, None, 0),
    ("next_run_at", "INTEGER", 0, None, 0),
)

_POINT_COLUMNS = (
    ("object_id", "TEXT", 0, None, 1),
    ("sequence", "INTEGER", 1, None, 0),
    ("target_revision", "INTEGER", 1, None, 0),
    ("created_at", "INTEGER", 1, None, 0),
    ("protected_until", "INTEGER", 1, None, 0),
    ("byte_length", "INTEGER", 1, None, 0),
    ("sha256", "TEXT", 1, None, 0),
    ("remote_receipt_id", "TEXT", 1, None, 0),
    ("quota_used_bytes", "INTEGER", 1, None, 0),
)

_JOB_COLUMNS = (
    ("id", "INTEGER", 0, None, 1),
    ("object_id", "TEXT", 1, None, 0),
    ("target_revision", "INTEGER", 1, None, 0),
    ("due_at", "INTEGER", 1, None, 0),
    ("state", "TEXT", 1, None, 0),
    ("protected_until", "INTEGER", 1, None, 0),
    ("byte_length", "INTEGER", 0, None, 0),
    ("sha256", "TEXT", 0, None, 0),
)


def _create_points(connection):
    connection.execute(
        """CREATE TABLE immutable_backup_points (
            object_id TEXT PRIMARY KEY CHECK(length(object_id)=32),
            sequence INTEGER NOT NULL UNIQUE CHECK(sequence>0),
            target_revision INTEGER NOT NULL CHECK(target_revision>0),
            created_at INTEGER NOT NULL,
            protected_until INTEGER NOT NULL CHECK(protected_until>created_at),
            byte_length INTEGER NOT NULL CHECK(byte_length>0 AND byte_length<=536870912),
            sha256 TEXT NOT NULL CHECK(length(sha256)=64),
            remote_receipt_id TEXT NOT NULL CHECK(length(remote_receipt_id) BETWEEN 1 AND 128),
            quota_used_bytes INTEGER NOT NULL CHECK(quota_used_bytes>=byte_length)
        )"""
    )
    connection.execute(
        """CREATE TABLE immutable_backup_job (
            id INTEGER PRIMARY KEY CHECK(id=1),
            object_id TEXT NOT NULL UNIQUE CHECK(length(object_id)=32),
            target_revision INTEGER NOT NULL CHECK(target_revision>0),
            due_at INTEGER NOT NULL,
            state TEXT NOT NULL CHECK(state IN ('queued','prepared')),
            protected_until INTEGER NOT NULL CHECK(protected_until>due_at),
            byte_length INTEGER CHECK(byte_length IS NULL OR byte_length>0),
            sha256 TEXT CHECK(sha256 IS NULL OR length(sha256)=64),
            CHECK((state='queued' AND byte_length IS NULL AND sha256 IS NULL) OR
                  (state='prepared' AND byte_length IS NOT NULL AND sha256 IS NOT NULL))
        )"""
    )


def migrate_immutable_backup_target(connection):
    marker = connection.execute(
        "SELECT value FROM metadata WHERE key='immutable_backup_target_schema'"
    ).fetchone()
    exists = connection.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' "
        "AND name='immutable_backup_target'"
    ).fetchone()
    if marker is None:
        if exists:
            raise StartupError("immutable_backup_target_schema_unsupported")
        connection.execute(
            """CREATE TABLE immutable_backup_target (
                id INTEGER PRIMARY KEY CHECK(id=1),
                revision INTEGER NOT NULL CHECK(revision>0),
                endpoint TEXT NOT NULL CHECK(length(endpoint) BETWEEN 9 AND 2048),
                target_id TEXT NOT NULL CHECK(length(target_id) BETWEEN 3 AND 64),
                retention_days INTEGER NOT NULL CHECK(retention_days BETWEEN 7 AND 3650),
                quota_bytes INTEGER NOT NULL CHECK(quota_bytes>=67108864),
                nonce BLOB NOT NULL CHECK(length(nonce)=12),
                ciphertext BLOB NOT NULL CHECK(length(ciphertext) BETWEEN 96 AND 4096),
                configured_at INTEGER NOT NULL
            )"""
        )
        connection.execute(
            "ALTER TABLE immutable_backup_target ADD COLUMN actor_id TEXT"
        )
        connection.execute(
            "ALTER TABLE immutable_backup_target ADD COLUMN actor_revision INTEGER"
        )
        connection.execute(
            "ALTER TABLE immutable_backup_target ADD COLUMN family_id TEXT"
        )
        connection.execute(
            "ALTER TABLE immutable_backup_target ADD COLUMN next_run_at INTEGER"
        )
        _create_points(connection)
        connection.execute(
            "INSERT INTO metadata(key,value) "
            "VALUES('immutable_backup_target_schema','2')"
        )
    elif marker["value"] == "1" and exists:
        connection.execute(
            "ALTER TABLE immutable_backup_target ADD COLUMN actor_id TEXT"
        )
        connection.execute(
            "ALTER TABLE immutable_backup_target ADD COLUMN actor_revision INTEGER"
        )
        connection.execute(
            "ALTER TABLE immutable_backup_target ADD COLUMN family_id TEXT"
        )
        connection.execute(
            "ALTER TABLE immutable_backup_target ADD COLUMN next_run_at INTEGER"
        )
        _create_points(connection)
        connection.execute(
            "UPDATE metadata SET value='2' "
            "WHERE key='immutable_backup_target_schema'"
        )
    elif marker["value"] != "2" or not exists:
        raise StartupError("immutable_backup_target_schema_unsupported")
    columns = tuple(
        tuple(row)
        for row in connection.execute(
            'SELECT name,type,"notnull",dflt_value,pk '
            "FROM pragma_table_info('immutable_backup_target')"
        )
    )
    if columns != _COLUMNS:
        raise StartupError("immutable_backup_target_schema_unsupported")
    point_columns = tuple(
        tuple(row)
        for row in connection.execute(
            'SELECT name,type,"notnull",dflt_value,pk '
            "FROM pragma_table_info('immutable_backup_points')"
        )
    )
    if point_columns != _POINT_COLUMNS:
        raise StartupError("immutable_backup_target_schema_unsupported")
    job_columns = tuple(
        tuple(row)
        for row in connection.execute(
            'SELECT name,type,"notnull",dflt_value,pk '
            "FROM pragma_table_info('immutable_backup_job')"
        )
    )
    if job_columns != _JOB_COLUMNS:
        raise StartupError("immutable_backup_target_schema_unsupported")
