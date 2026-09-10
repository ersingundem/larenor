"""Additive authenticated storage for durable qBittorrent config jobs."""

from ..errors import StartupError


TABLE = 'media_qbittorrent_configurations'
_COLUMNS = (
    ('id', 'TEXT', 0, None, 1), ('sequence', 'INTEGER', 1, None, 0),
    ('revision', 'INTEGER', 1, None, 0), ('actor_id', 'TEXT', 1, None, 0),
    ('actor_revision', 'INTEGER', 1, None, 0), ('family_id', 'TEXT', 1, None, 0),
    ('request_id', 'TEXT', 1, None, 0), ('preparation_id', 'TEXT', 1, None, 0),
    ('inspection_id', 'TEXT', 1, None, 0), ('state', 'TEXT', 1, None, 0),
    ('phase', 'TEXT', 1, None, 0), ('cancel_requested', 'INTEGER', 1, None, 0),
    ('error_code', 'TEXT', 0, None, 0), ('configuration_state', 'TEXT', 0, None, 0),
    ('created_at', 'INTEGER', 1, None, 0), ('updated_at', 'INTEGER', 1, None, 0),
    ('nonce', 'BLOB', 1, None, 0), ('ciphertext', 'BLOB', 1, None, 0),
)


def _verify(connection):
    columns = tuple(tuple(row) for row in connection.execute(
        f'SELECT name,type,"notnull",dflt_value,pk FROM pragma_table_info(\'{TABLE}\')'))
    if columns != _COLUMNS:
        raise StartupError('media_qbittorrent_configurations_schema_unsupported')
    unique, dispatch = set(), False
    for index in connection.execute(f'PRAGMA index_list({TABLE})'):
        fields = tuple(row[0] for row in connection.execute(
            'SELECT name FROM pragma_index_info(?) ORDER BY seqno', (index['name'],)))
        if index['unique'] and not index['partial']:
            unique.add(fields)
        if index['name'] == 'media_qbittorrent_configurations_dispatch':
            dispatch = fields == ('state', 'sequence') and not index['unique'] and not index['partial']
    if unique != {('id',), ('sequence',), ('actor_id', 'request_id'), ('preparation_id',)} or not dispatch:
        raise StartupError('media_qbittorrent_configurations_schema_unsupported')
    foreign = {tuple(row) for row in connection.execute(
        f'SELECT "table","from","to",on_update,on_delete,match FROM pragma_foreign_key_list(\'{TABLE}\')')}
    if foreign != {
        ('media_preparations', 'preparation_id', 'id', 'NO ACTION', 'NO ACTION', 'NONE'),
        ('media_inspections', 'inspection_id', 'id', 'NO ACTION', 'NO ACTION', 'NONE'),
    }:
        raise StartupError('media_qbittorrent_configurations_schema_unsupported')


def migrate_qbittorrent_configurations(connection):
    marker = connection.execute(
        "SELECT value FROM metadata WHERE key='media_qbittorrent_configurations_schema'",
    ).fetchone()
    tables = {row[0] for row in connection.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'media_qbittorrent_configuration%'")}
    if marker is None:
        if tables:
            raise StartupError('media_qbittorrent_configurations_schema_unsupported')
        connection.execute(f'''CREATE TABLE {TABLE} (
            id TEXT PRIMARY KEY,
            sequence INTEGER NOT NULL UNIQUE CHECK(sequence > 0),
            revision INTEGER NOT NULL CHECK(revision > 0),
            actor_id TEXT NOT NULL,
            actor_revision INTEGER NOT NULL CHECK(actor_revision > 0),
            family_id TEXT NOT NULL,
            request_id TEXT NOT NULL,
            preparation_id TEXT NOT NULL UNIQUE REFERENCES media_preparations(id),
            inspection_id TEXT NOT NULL REFERENCES media_inspections(id),
            state TEXT NOT NULL CHECK(state IN ('queued','running','succeeded','needs_attention','failed','cancelled')),
            phase TEXT NOT NULL CHECK(phase IN ('queued','configuring','complete')),
            cancel_requested INTEGER NOT NULL CHECK(cancel_requested IN (0,1)),
            error_code TEXT,
            configuration_state TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            nonce BLOB NOT NULL,
            ciphertext BLOB NOT NULL,
            UNIQUE(actor_id,request_id)
        )''')
        connection.execute(
            f'CREATE INDEX media_qbittorrent_configurations_dispatch ON {TABLE}(state,sequence)')
        connection.execute(
            "INSERT INTO metadata(key,value) VALUES('media_qbittorrent_configurations_schema','1')")
    elif marker['value'] != '1' or tables != {TABLE}:
        raise StartupError('media_qbittorrent_configurations_schema_unsupported')
    _verify(connection)
