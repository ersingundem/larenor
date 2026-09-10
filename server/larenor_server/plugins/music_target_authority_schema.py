"""Immutable encrypted preview and one-use blocked command journal."""

from ..errors import StartupError


_PREVIEW_COLUMNS = (
    ('id', 'TEXT', 0, None, 1), ('request_id', 'TEXT', 1, None, 0),
    ('actor_id', 'TEXT', 1, None, 0), ('actor_revision', 'INTEGER', 1, None, 0),
    ('family_id', 'TEXT', 1, None, 0), ('installation_id', 'TEXT', 1, None, 0),
    ('installation_revision', 'INTEGER', 1, None, 0),
    ('core_revision', 'INTEGER', 1, None, 0),
    ('player_revision', 'INTEGER', 1, None, 0),
    ('provider_digest', 'TEXT', 1, None, 0), ('plan_hash', 'TEXT', 1, None, 0),
    ('created_at', 'INTEGER', 1, None, 0), ('expires_at', 'INTEGER', 1, None, 0),
    ('nonce', 'BLOB', 1, None, 0), ('ciphertext', 'BLOB', 1, None, 0),
)
_COMMAND_COLUMNS = (
    ('id', 'TEXT', 0, None, 1), ('request_id', 'TEXT', 1, None, 0),
    ('actor_id', 'TEXT', 1, None, 0), ('actor_revision', 'INTEGER', 1, None, 0),
    ('family_id', 'TEXT', 1, None, 0), ('preview_id', 'TEXT', 1, None, 0),
    ('target_id', 'TEXT', 1, None, 0), ('operation', 'TEXT', 1, None, 0),
    ('created_at', 'INTEGER', 1, None, 0),
)


def migrate_music_target_authority(connection):
    marker = connection.execute(
        "SELECT value FROM metadata WHERE key='music_target_authority_schema'"
    ).fetchone()
    existing = {row['name'] for row in connection.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name IN "
        "('music_target_command_previews','music_target_commands')").fetchall()}
    if marker is None:
        if existing:
            raise StartupError('music_target_authority_schema_unsupported')
        connection.execute('''CREATE TABLE music_target_command_previews (
          id TEXT PRIMARY KEY, request_id TEXT NOT NULL, actor_id TEXT NOT NULL,
          actor_revision INTEGER NOT NULL CHECK(actor_revision > 0),
          family_id TEXT NOT NULL,
          installation_id TEXT NOT NULL REFERENCES media_installations(id),
          installation_revision INTEGER NOT NULL CHECK(installation_revision > 0),
          core_revision INTEGER NOT NULL CHECK(core_revision > 0),
          player_revision INTEGER NOT NULL CHECK(player_revision > 0),
          provider_digest TEXT NOT NULL, plan_hash TEXT NOT NULL,
          created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
          nonce BLOB NOT NULL, ciphertext BLOB NOT NULL,
          UNIQUE(actor_id,request_id))''')
        connection.execute('''CREATE TABLE music_target_commands (
          id TEXT PRIMARY KEY, request_id TEXT NOT NULL, actor_id TEXT NOT NULL,
          actor_revision INTEGER NOT NULL CHECK(actor_revision > 0),
          family_id TEXT NOT NULL,
          preview_id TEXT NOT NULL UNIQUE REFERENCES music_target_command_previews(id),
          target_id TEXT NOT NULL, operation TEXT NOT NULL,
          created_at INTEGER NOT NULL, UNIQUE(actor_id,request_id))''')
        connection.execute(
            "INSERT INTO metadata(key,value) VALUES('music_target_authority_schema','1')")
    elif marker['value'] != '1' or existing != {
            'music_target_command_previews', 'music_target_commands'}:
        raise StartupError('music_target_authority_schema_unsupported')
    for name, expected in (
            ('music_target_command_previews', _PREVIEW_COLUMNS),
            ('music_target_commands', _COMMAND_COLUMNS)):
        columns = tuple(tuple(row) for row in connection.execute(
            f'SELECT name,type,"notnull",dflt_value,pk FROM pragma_table_info(\'{name}\')'))
        if columns != expected:
            raise StartupError('music_target_authority_schema_unsupported')
