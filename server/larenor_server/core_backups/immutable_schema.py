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
            "INSERT INTO metadata(key,value) "
            "VALUES('immutable_backup_target_schema','1')"
        )
    elif marker["value"] != "1" or not exists:
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

