"""Durable secret-free observations for exact F30 snapshot reads."""

from ..errors import StartupError


TABLE = 'media_archive_snapshots'
_COLUMNS = (
    ('installation_id', 'TEXT', 1, None, 1),
    ('snapshot_revision', 'INTEGER', 1, None, 2),
    ('installation_revision', 'INTEGER', 1, None, 0),
    ('state', 'TEXT', 1, None, 0),
    ('source_fingerprint', 'TEXT', 1, None, 0),
    ('observed_at', 'INTEGER', 1, None, 0),
    ('retired_at', 'INTEGER', 0, None, 0),
    ('observation_json', 'TEXT', 1, None, 0),
    ('digest', 'TEXT', 1, None, 0),
)


def _verify(connection):
    columns = tuple(tuple(row) for row in connection.execute(
        f'SELECT name,type,"notnull",dflt_value,pk '
        f"FROM pragma_table_info('{TABLE}')"))
    if columns != _COLUMNS:
        raise StartupError('media_archive_snapshots_schema_unsupported')
    active = False
    for index in connection.execute(f'PRAGMA index_list({TABLE})'):
        fields = tuple(row[0] for row in connection.execute(
            'SELECT name FROM pragma_index_info(?) ORDER BY seqno',
            (index['name'],)))
        if index['name'] == 'media_archive_snapshots_active':
            active = (fields == ('installation_id',)
                      and bool(index['unique']) and bool(index['partial']))
    foreign = tuple(tuple(row) for row in connection.execute(
        f'SELECT "table","from","to",on_update,on_delete,match '
        f"FROM pragma_foreign_key_list('{TABLE}')"))
    if (not active or foreign != (('media_installations', 'installation_id',
                                    'id', 'NO ACTION', 'NO ACTION', 'NONE'),)):
        raise StartupError('media_archive_snapshots_schema_unsupported')


def migrate_media_archive_snapshots(connection):
    marker = connection.execute(
        "SELECT value FROM metadata WHERE key='media_archive_snapshots_schema'"
    ).fetchone()
    tables = {row[0] for row in connection.execute(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name LIKE 'media_archive_snapshot%'")}
    if marker is None:
        if tables:
            raise StartupError('media_archive_snapshots_schema_unsupported')
        connection.execute(f'''CREATE TABLE {TABLE} (
            installation_id TEXT NOT NULL REFERENCES media_installations(id),
            snapshot_revision INTEGER NOT NULL CHECK(snapshot_revision > 0),
            installation_revision INTEGER NOT NULL CHECK(installation_revision > 0),
            state TEXT NOT NULL CHECK(state IN ('active','retired')),
            source_fingerprint TEXT NOT NULL CHECK(length(source_fingerprint)=64),
            observed_at INTEGER NOT NULL CHECK(observed_at > 0),
            retired_at INTEGER,
            observation_json TEXT NOT NULL,
            digest TEXT NOT NULL CHECK(length(digest)=64),
            PRIMARY KEY(installation_id,snapshot_revision),
            CHECK((state='active' AND retired_at IS NULL) OR
                  (state='retired' AND retired_at IS NOT NULL AND
                   retired_at >= observed_at))
        )''')
        connection.execute(
            f'CREATE UNIQUE INDEX media_archive_snapshots_active ON {TABLE}'
            "(installation_id) WHERE state='active'")
        connection.execute(
            "INSERT INTO metadata(key,value) "
            "VALUES('media_archive_snapshots_schema','1')")
    elif marker['value'] != '1' or tables != {TABLE}:
        raise StartupError('media_archive_snapshots_schema_unsupported')
    _verify(connection)
