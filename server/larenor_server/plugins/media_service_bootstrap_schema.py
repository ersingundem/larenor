"""Additive authenticated storage for private media bootstrap state."""

from ..errors import StartupError


_COLUMNS = (
    ('id', 'TEXT', 0, None, 1), ('sequence', 'INTEGER', 1, None, 0),
    ('revision', 'INTEGER', 1, None, 0), ('actor_id', 'TEXT', 1, None, 0),
    ('actor_revision', 'INTEGER', 1, None, 0), ('family_id', 'TEXT', 1, None, 0),
    ('request_id', 'TEXT', 1, None, 0), ('installation_id', 'TEXT', 1, None, 0),
    ('installation_revision', 'INTEGER', 1, None, 0), ('state', 'TEXT', 1, None, 0),
    ('credentials_configured', 'INTEGER', 1, None, 0),
    ('wiring_state', 'TEXT', 1, None, 0), ('error_code', 'TEXT', 0, None, 0),
    ('created_at', 'INTEGER', 1, None, 0),
    ('updated_at', 'INTEGER', 1, None, 0), ('nonce', 'BLOB', 1, None, 0),
    ('ciphertext', 'BLOB', 1, None, 0),
)


def _verify(connection):
    columns = tuple(tuple(row) for row in connection.execute(
        "SELECT name,type,\"notnull\",dflt_value,pk FROM pragma_table_info('media_service_bootstraps')"))
    if columns != _COLUMNS:
        raise StartupError('media_service_bootstraps_schema_unsupported')
    unique, state_index = set(), False
    for index in connection.execute('PRAGMA index_list(media_service_bootstraps)'):
        fields = tuple(row[0] for row in connection.execute(
            'SELECT name FROM pragma_index_info(?) ORDER BY seqno', (index['name'],)))
        if index['unique'] and not index['partial']:
            unique.add(fields)
        if index['name'] == 'media_service_bootstraps_state':
            state_index = fields == ('state', 'sequence') and not index['unique'] and not index['partial']
    if unique != {('id',), ('sequence',), ('actor_id', 'request_id'), ('installation_id',)} or not state_index:
        raise StartupError('media_service_bootstraps_schema_unsupported')
    foreign = tuple(tuple(row) for row in connection.execute(
        "SELECT \"table\",\"from\",\"to\",on_update,on_delete,match "
        "FROM pragma_foreign_key_list('media_service_bootstraps')"))
    if foreign != (('media_installations', 'installation_id', 'id',
                    'NO ACTION', 'NO ACTION', 'NONE'),):
        raise StartupError('media_service_bootstraps_schema_unsupported')


def migrate_media_service_bootstraps(connection):
    marker = connection.execute(
        "SELECT value FROM metadata WHERE key='media_service_bootstraps_schema'").fetchone()
    tables = {row[0] for row in connection.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'media_service_bootstrap%'")}
    if marker is None:
        if tables:
            raise StartupError('media_service_bootstraps_schema_unsupported')
        connection.execute('''CREATE TABLE media_service_bootstraps (
            id TEXT PRIMARY KEY,
            sequence INTEGER NOT NULL UNIQUE CHECK(sequence > 0),
            revision INTEGER NOT NULL CHECK(revision > 0),
            actor_id TEXT NOT NULL,
            actor_revision INTEGER NOT NULL CHECK(actor_revision > 0),
            family_id TEXT NOT NULL,
            request_id TEXT NOT NULL,
            installation_id TEXT NOT NULL UNIQUE REFERENCES media_installations(id),
            installation_revision INTEGER NOT NULL CHECK(installation_revision > 0),
            state TEXT NOT NULL CHECK(state IN ('queued','running','credentials_configured','wiring_partial','succeeded','needs_attention','failed','cancelled')),
            credentials_configured INTEGER NOT NULL CHECK(credentials_configured IN (0,1)),
            wiring_state TEXT NOT NULL CHECK(wiring_state IN ('pending','partial','verified')),
            error_code TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            nonce BLOB NOT NULL,
            ciphertext BLOB NOT NULL,
            UNIQUE(actor_id,request_id)
        )''')
        connection.execute('CREATE INDEX media_service_bootstraps_state ON media_service_bootstraps(state,sequence)')
        connection.execute("INSERT INTO metadata(key,value) VALUES('media_service_bootstraps_schema','1')")
    elif marker['value'] != '1' or tables != {'media_service_bootstraps'}:
        raise StartupError('media_service_bootstraps_schema_unsupported')
    _verify(connection)
