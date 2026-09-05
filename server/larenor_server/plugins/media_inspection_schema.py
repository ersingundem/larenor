"""Additive authenticated inspection receipts, independent of expiring sessions."""

from ..errors import StartupError


_COLUMNS = (
    ('id', 'TEXT', 0, None, 1), ('sequence', 'INTEGER', 1, None, 0),
    ('revision', 'INTEGER', 1, None, 0), ('actor_id', 'TEXT', 1, None, 0),
    ('actor_revision', 'INTEGER', 1, None, 0), ('family_id', 'TEXT', 1, None, 0),
    ('request_id', 'TEXT', 1, None, 0), ('preparation_id', 'TEXT', 1, None, 0),
    ('state', 'TEXT', 1, None, 0), ('phase', 'TEXT', 1, None, 0),
    ('cancel_requested', 'INTEGER', 1, None, 0), ('error_code', 'TEXT', 0, None, 0),
    ('created_at', 'INTEGER', 1, None, 0), ('updated_at', 'INTEGER', 1, None, 0),
    ('nonce', 'BLOB', 1, None, 0), ('ciphertext', 'BLOB', 1, None, 0),
)


def _verify_schema(connection):
    columns = tuple(tuple(row) for row in connection.execute(
        'SELECT name,type,"notnull",dflt_value,pk FROM pragma_table_info(\'media_inspections\')'))
    if columns != _COLUMNS:
        raise StartupError('media_inspections_schema_unsupported')
    unique, state_index = set(), False
    for index in connection.execute('PRAGMA index_list(media_inspections)'):
        fields = tuple(row[0] for row in connection.execute(
            'SELECT name FROM pragma_index_info(?) ORDER BY seqno', (index['name'],)))
        if index['unique'] and not index['partial']:
            unique.add(fields)
        if index['name'] == 'media_inspections_state':
            state_index = fields == ('state', 'sequence') and not index['unique'] and not index['partial']
    if unique != {('id',), ('sequence',), ('actor_id', 'request_id')} or not state_index:
        raise StartupError('media_inspections_schema_unsupported')


def migrate_media_inspections(connection):
    marker = connection.execute("SELECT value FROM metadata WHERE key='media_inspections_schema'").fetchone()
    tables = {row[0] for row in connection.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'media_inspection%'")}
    if marker is None:
        if tables:
            raise StartupError('media_inspections_schema_unsupported')
        connection.execute('''CREATE TABLE media_inspections (
            id TEXT PRIMARY KEY,
            sequence INTEGER NOT NULL UNIQUE CHECK(sequence > 0),
            revision INTEGER NOT NULL CHECK(revision > 0),
            actor_id TEXT NOT NULL,
            actor_revision INTEGER NOT NULL CHECK(actor_revision > 0),
            family_id TEXT NOT NULL,
            request_id TEXT NOT NULL,
            preparation_id TEXT NOT NULL,
            state TEXT NOT NULL CHECK(state IN ('queued','running','succeeded','failed','cancelled','needs_attention')),
            phase TEXT NOT NULL CHECK(phase IN ('queued','checking_requirements','complete')),
            cancel_requested INTEGER NOT NULL CHECK(cancel_requested IN (0,1)),
            error_code TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            nonce BLOB NOT NULL,
            ciphertext BLOB NOT NULL,
            UNIQUE(actor_id,request_id)
        )''')
        connection.execute('CREATE INDEX media_inspections_state ON media_inspections(state,sequence)')
        connection.execute("INSERT INTO metadata(key,value) VALUES('media_inspections_schema','1')")
    elif marker['value'] != '1' or tables != {'media_inspections'}:
        raise StartupError('media_inspections_schema_unsupported')
    _verify_schema(connection)
