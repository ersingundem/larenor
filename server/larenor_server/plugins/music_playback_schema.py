"""Encrypted Music Assistant player snapshot journal."""

from ..errors import StartupError


_COLUMNS = (
    ('installation_id', 'TEXT', 0, None, 1),
    ('installation_revision', 'INTEGER', 1, None, 0),
    ('core_revision', 'INTEGER', 1, None, 0),
    ('revision', 'INTEGER', 1, None, 0),
    ('created_at', 'INTEGER', 1, None, 0),
    ('updated_at', 'INTEGER', 1, None, 0),
    ('nonce', 'BLOB', 1, None, 0),
    ('ciphertext', 'BLOB', 1, None, 0),
)


def migrate_music_playback(connection):
    marker = connection.execute(
        "SELECT value FROM metadata WHERE key='music_playback_schema'").fetchone()
    exists = connection.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='music_playback'").fetchone()
    if marker is None:
        if exists:
            raise StartupError('music_playback_schema_unsupported')
        connection.execute('''CREATE TABLE music_playback (
            installation_id TEXT PRIMARY KEY REFERENCES media_installations(id),
            installation_revision INTEGER NOT NULL CHECK(installation_revision > 0),
            core_revision INTEGER NOT NULL CHECK(core_revision > 0),
            revision INTEGER NOT NULL CHECK(revision > 0),
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            nonce BLOB NOT NULL,
            ciphertext BLOB NOT NULL
        )''')
        connection.execute(
            "INSERT INTO metadata(key,value) VALUES('music_playback_schema','1')")
    elif marker['value'] != '1' or not exists:
        raise StartupError('music_playback_schema_unsupported')
    columns = tuple(tuple(row) for row in connection.execute(
        "SELECT name,type,\"notnull\",dflt_value,pk FROM pragma_table_info('music_playback')"))
    if columns != _COLUMNS:
        raise StartupError('music_playback_schema_unsupported')
