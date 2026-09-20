"""Encrypted authenticated readback state for the internal music engine."""

from ..errors import StartupError


_CORE_COLUMNS = (
    ('installation_id', 'TEXT', 0, None, 1),
    ('installation_revision', 'INTEGER', 1, None, 0),
    ('revision', 'INTEGER', 1, None, 0),
    ('created_at', 'INTEGER', 1, None, 0),
    ('updated_at', 'INTEGER', 1, None, 0),
    ('nonce', 'BLOB', 1, None, 0),
    ('ciphertext', 'BLOB', 1, None, 0),
)

_ROTATION_COLUMNS = (
    ('request_id', 'TEXT', 0, None, 1),
    ('sequence', 'INTEGER', 1, None, 0),
    ('state', 'TEXT', 1, None, 0),
    ('actor_id', 'TEXT', 1, None, 0),
    ('actor_revision', 'INTEGER', 1, None, 0),
    ('family_id', 'TEXT', 1, None, 0),
    ('core_id', 'TEXT', 1, None, 0),
    ('home_id', 'TEXT', 1, None, 0),
    ('installation_id', 'TEXT', 1, None, 0),
    ('installation_revision', 'INTEGER', 1, None, 0),
    ('worker_revision', 'INTEGER', 1, None, 0),
    ('provider_setup_id', 'TEXT', 1, None, 0),
    ('provider_revision', 'INTEGER', 1, None, 0),
    ('created_at', 'INTEGER', 1, None, 0),
    ('updated_at', 'INTEGER', 1, None, 0),
    ('nonce', 'BLOB', 1, None, 0),
    ('ciphertext', 'BLOB', 1, None, 0),
)


def _verify(connection):
    columns = tuple(tuple(row) for row in connection.execute(
        "SELECT name,type,\"notnull\",dflt_value,pk "
        "FROM pragma_table_info('music_assistant_core')"))
    if columns != _CORE_COLUMNS:
        raise StartupError('music_assistant_core_schema_unsupported')
    rotation_columns = tuple(tuple(row) for row in connection.execute(
        "SELECT name,type,\"notnull\",dflt_value,pk "
        "FROM pragma_table_info('music_assistant_key_rotations')"))
    if rotation_columns != _ROTATION_COLUMNS:
        raise StartupError('music_assistant_core_schema_unsupported')
    indexes = {
        tuple(row[0] for row in connection.execute(
            'SELECT name FROM pragma_index_info(?) ORDER BY seqno',
            (index['name'],)))
        for index in connection.execute(
            'PRAGMA index_list(music_assistant_key_rotations)')
        if index['unique'] and not index['partial']}
    if indexes != {('request_id',), ('sequence',)}:
        raise StartupError('music_assistant_core_schema_unsupported')


def _create_rotations(connection):
    connection.execute('''CREATE TABLE music_assistant_key_rotations (
        request_id TEXT PRIMARY KEY,
        sequence INTEGER NOT NULL UNIQUE CHECK(sequence > 0),
        state TEXT NOT NULL CHECK(state IN ('preparing','activated','retired')),
        actor_id TEXT NOT NULL,
        actor_revision INTEGER NOT NULL CHECK(actor_revision > 0),
        family_id TEXT NOT NULL,
        core_id TEXT NOT NULL,
        home_id TEXT NOT NULL,
        installation_id TEXT NOT NULL REFERENCES music_assistant_core(installation_id),
        installation_revision INTEGER NOT NULL CHECK(installation_revision > 0),
        worker_revision INTEGER NOT NULL CHECK(worker_revision > 0),
        provider_setup_id TEXT NOT NULL REFERENCES music_provider_setups(id),
        provider_revision INTEGER NOT NULL CHECK(provider_revision > 0),
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        nonce BLOB NOT NULL,
        ciphertext BLOB NOT NULL
    )''')


def migrate_music_assistant_core(connection):
    marker = connection.execute(
        "SELECT value FROM metadata WHERE key='music_assistant_core_schema'").fetchone()
    exists = connection.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='music_assistant_core'").fetchone()
    if marker is None:
        if exists:
            raise StartupError('music_assistant_core_schema_unsupported')
        connection.execute('''CREATE TABLE music_assistant_core (
            installation_id TEXT PRIMARY KEY REFERENCES media_installations(id),
            installation_revision INTEGER NOT NULL CHECK(installation_revision > 0),
            revision INTEGER NOT NULL CHECK(revision > 0),
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            nonce BLOB NOT NULL,
            ciphertext BLOB NOT NULL
        )''')
        _create_rotations(connection)
        connection.execute(
            "INSERT INTO metadata(key,value) VALUES('music_assistant_core_schema','2')")
    elif marker['value'] == '1' and exists:
        rotation_exists = connection.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' "
            "AND name='music_assistant_key_rotations'").fetchone()
        if rotation_exists:
            raise StartupError('music_assistant_core_schema_unsupported')
        _create_rotations(connection)
        connection.execute(
            "UPDATE metadata SET value='2' "
            "WHERE key='music_assistant_core_schema'")
    elif marker['value'] != '2' or not exists:
        raise StartupError('music_assistant_core_schema_unsupported')
    _verify(connection)
