"""Encrypted provider onboarding intent journal."""

from ..errors import StartupError


_COLUMNS = (
    ('id', 'TEXT', 0, None, 1), ('sequence', 'INTEGER', 1, None, 0),
    ('revision', 'INTEGER', 1, None, 0), ('actor_id', 'TEXT', 1, None, 0),
    ('actor_revision', 'INTEGER', 1, None, 0), ('family_id', 'TEXT', 1, None, 0),
    ('installation_id', 'TEXT', 1, None, 0),
    ('installation_revision', 'INTEGER', 1, None, 0),
    ('state', 'TEXT', 1, None, 0), ('created_at', 'INTEGER', 1, None, 0),
    ('updated_at', 'INTEGER', 1, None, 0), ('nonce', 'BLOB', 1, None, 0),
    ('ciphertext', 'BLOB', 1, None, 0),
)


def _verify(connection):
    columns = tuple(tuple(row) for row in connection.execute(
        "SELECT name,type,\"notnull\",dflt_value,pk "
        "FROM pragma_table_info('music_provider_setups')"))
    if columns != _COLUMNS:
        raise StartupError('music_provider_setups_schema_unsupported')
    indexes = {
        tuple(row[0] for row in connection.execute(
            'SELECT name FROM pragma_index_info(?) ORDER BY seqno', (index['name'],)))
        for index in connection.execute('PRAGMA index_list(music_provider_setups)')
        if index['unique'] and not index['partial']}
    if indexes != {('id',), ('sequence',)}:
        raise StartupError('music_provider_setups_schema_unsupported')


def migrate_music_provider_setups(connection):
    marker = connection.execute(
        "SELECT value FROM metadata WHERE key='music_provider_setups_schema'").fetchone()
    exists = connection.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='music_provider_setups'").fetchone()
    if marker is None:
        if exists:
            raise StartupError('music_provider_setups_schema_unsupported')
        connection.execute('''CREATE TABLE music_provider_setups (
            id TEXT PRIMARY KEY,
            sequence INTEGER NOT NULL UNIQUE CHECK(sequence > 0),
            revision INTEGER NOT NULL CHECK(revision > 0),
            actor_id TEXT NOT NULL,
            actor_revision INTEGER NOT NULL CHECK(actor_revision > 0),
            family_id TEXT NOT NULL,
            installation_id TEXT NOT NULL REFERENCES media_installations(id),
            installation_revision INTEGER NOT NULL CHECK(installation_revision > 0),
            state TEXT NOT NULL CHECK(state IN ('queued','action_required')),
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            nonce BLOB NOT NULL,
            ciphertext BLOB NOT NULL
        )''')
        connection.execute(
            "INSERT INTO metadata(key,value) VALUES('music_provider_setups_schema','1')")
    elif marker['value'] != '1' or not exists:
        raise StartupError('music_provider_setups_schema_unsupported')
    _verify(connection)
