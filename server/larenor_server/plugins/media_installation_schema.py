"""Additive authenticated storage for bounded installation executions."""

from ..errors import StartupError


_COLUMNS = (
    ('id', 'TEXT', 0, None, 1), ('sequence', 'INTEGER', 1, None, 0),
    ('revision', 'INTEGER', 1, None, 0), ('actor_id', 'TEXT', 1, None, 0),
    ('actor_revision', 'INTEGER', 1, None, 0), ('family_id', 'TEXT', 1, None, 0),
    ('request_id', 'TEXT', 1, None, 0), ('preparation_id', 'TEXT', 1, None, 0),
    ('inspection_id', 'TEXT', 1, None, 0), ('state', 'TEXT', 1, None, 0),
    ('phase', 'TEXT', 1, None, 0), ('cancel_requested', 'INTEGER', 1, None, 0),
    ('error_code', 'TEXT', 0, None, 0), ('created_at', 'INTEGER', 1, None, 0),
    ('updated_at', 'INTEGER', 1, None, 0), ('nonce', 'BLOB', 1, None, 0),
    ('ciphertext', 'BLOB', 1, None, 0),
)


def _verify(connection):
    columns = tuple(tuple(row) for row in connection.execute(
        'SELECT name,type,"notnull",dflt_value,pk FROM pragma_table_info(\'media_installations\')'))
    if columns != _COLUMNS:
        raise StartupError('media_installations_schema_unsupported')
    unique, state_index = set(), False
    for index in connection.execute('PRAGMA index_list(media_installations)'):
        fields = tuple(row[0] for row in connection.execute(
            'SELECT name FROM pragma_index_info(?) ORDER BY seqno', (index['name'],)))
        if index['unique'] and not index['partial']:
            unique.add(fields)
        if index['name'] == 'media_installations_state':
            state_index = fields == ('state', 'sequence') and not index['unique'] and not index['partial']
    if unique != {('id',), ('sequence',), ('actor_id', 'request_id')} or not state_index:
        raise StartupError('media_installations_schema_unsupported')


def migrate_media_installations(connection):
    marker = connection.execute("SELECT value FROM metadata WHERE key='media_installations_schema'").fetchone()
    tables = {row[0] for row in connection.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'media_installation%'")}
    if marker is None:
        if tables:
            raise StartupError('media_installations_schema_unsupported')
        connection.execute('''CREATE TABLE media_installations (
            id TEXT PRIMARY KEY,
            sequence INTEGER NOT NULL UNIQUE CHECK(sequence > 0),
            revision INTEGER NOT NULL CHECK(revision > 0),
            actor_id TEXT NOT NULL,
            actor_revision INTEGER NOT NULL CHECK(actor_revision > 0),
            family_id TEXT NOT NULL,
            request_id TEXT NOT NULL,
            preparation_id TEXT NOT NULL,
            inspection_id TEXT NOT NULL,
            state TEXT NOT NULL CHECK(state IN ('queued','running','container_started','needs_attention','failed','cancelled')),
            phase TEXT NOT NULL CHECK(phase IN ('queued','executing','complete')),
            cancel_requested INTEGER NOT NULL CHECK(cancel_requested IN (0,1)),
            error_code TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            nonce BLOB NOT NULL,
            ciphertext BLOB NOT NULL,
            UNIQUE(actor_id,request_id)
        )''')
        connection.execute('CREATE INDEX media_installations_state ON media_installations(state,sequence)')
        connection.execute("INSERT INTO metadata(key,value) VALUES('media_installations_schema','2')")
    elif marker['value'] == '1' and tables == {'media_installations'}:
        connection.execute('ALTER TABLE media_installations RENAME TO media_installations_v1')
        connection.execute('''CREATE TABLE media_installations (
            id TEXT PRIMARY KEY,
            sequence INTEGER NOT NULL UNIQUE CHECK(sequence > 0),
            revision INTEGER NOT NULL CHECK(revision > 0),
            actor_id TEXT NOT NULL,
            actor_revision INTEGER NOT NULL CHECK(actor_revision > 0),
            family_id TEXT NOT NULL,
            request_id TEXT NOT NULL,
            preparation_id TEXT NOT NULL,
            inspection_id TEXT NOT NULL,
            state TEXT NOT NULL CHECK(state IN ('queued','running','container_started','needs_attention','failed','cancelled')),
            phase TEXT NOT NULL CHECK(phase IN ('queued','executing','complete')),
            cancel_requested INTEGER NOT NULL CHECK(cancel_requested IN (0,1)),
            error_code TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            nonce BLOB NOT NULL,
            ciphertext BLOB NOT NULL,
            UNIQUE(actor_id,request_id)
        )''')
        connection.execute(
            'INSERT INTO media_installations SELECT * FROM media_installations_v1')
        connection.execute('DROP TABLE media_installations_v1')
        connection.execute(
            'CREATE INDEX media_installations_state ON media_installations(state,sequence)')
        connection.execute(
            "UPDATE metadata SET value='2' WHERE key='media_installations_schema'")
    elif marker['value'] != '2' or tables != {'media_installations'}:
        raise StartupError('media_installations_schema_unsupported')
    _verify(connection)
