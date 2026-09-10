"""Immutable target command journal and durable effect-attempt recovery."""

from ..errors import StartupError


_COLUMNS = {
    'music_target_command_previews': (
        ('id', 'TEXT', 0, None, 1), ('request_id', 'TEXT', 1, None, 0),
        ('actor_id', 'TEXT', 1, None, 0), ('actor_revision', 'INTEGER', 1, None, 0),
        ('family_id', 'TEXT', 1, None, 0), ('installation_id', 'TEXT', 1, None, 0),
        ('installation_revision', 'INTEGER', 1, None, 0),
        ('core_revision', 'INTEGER', 1, None, 0),
        ('player_revision', 'INTEGER', 1, None, 0),
        ('provider_digest', 'TEXT', 1, None, 0),
        ('plan_hash', 'TEXT', 1, None, 0), ('created_at', 'INTEGER', 1, None, 0),
        ('expires_at', 'INTEGER', 1, None, 0), ('nonce', 'BLOB', 1, None, 0),
        ('ciphertext', 'BLOB', 1, None, 0)),
    'music_target_commands': (
        ('id', 'TEXT', 0, None, 1), ('request_id', 'TEXT', 1, None, 0),
        ('actor_id', 'TEXT', 1, None, 0), ('actor_revision', 'INTEGER', 1, None, 0),
        ('family_id', 'TEXT', 1, None, 0), ('preview_id', 'TEXT', 1, None, 0),
        ('target_id', 'TEXT', 1, None, 0), ('operation', 'TEXT', 1, None, 0),
        ('created_at', 'INTEGER', 1, None, 0), ('event_hash', 'BLOB', 1, None, 0)),
    'music_target_command_cancellations': (
        ('command_id', 'TEXT', 0, None, 1), ('request_id', 'TEXT', 1, None, 0),
        ('actor_id', 'TEXT', 1, None, 0), ('actor_revision', 'INTEGER', 1, None, 0),
        ('family_id', 'TEXT', 1, None, 0), ('created_at', 'INTEGER', 1, None, 0),
        ('event_hash', 'BLOB', 1, None, 0)),
    'music_target_effect_attempts': (
        ('command_id', 'TEXT', 0, None, 1), ('execution_id', 'TEXT', 1, None, 0),
        ('dispatch_request_id', 'TEXT', 1, None, 0),
        ('actor_id', 'TEXT', 1, None, 0), ('actor_revision', 'INTEGER', 1, None, 0),
        ('family_id', 'TEXT', 1, None, 0), ('installation_id', 'TEXT', 1, None, 0),
        ('installation_revision', 'INTEGER', 1, None, 0),
        ('core_revision', 'INTEGER', 1, None, 0),
        ('player_revision', 'INTEGER', 1, None, 0),
        ('provider_digest', 'TEXT', 1, None, 0), ('state', 'TEXT', 1, None, 0),
        ('created_at', 'INTEGER', 1, None, 0), ('updated_at', 'INTEGER', 1, None, 0),
        ('result_hash', 'TEXT', 1, None, 0), ('event_hash', 'BLOB', 1, None, 0)),
}


def _create(connection):
    connection.execute("""CREATE TABLE music_target_command_previews (
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
      UNIQUE(actor_id,request_id))""")
    connection.execute("""CREATE TABLE music_target_commands (
      id TEXT PRIMARY KEY, request_id TEXT NOT NULL, actor_id TEXT NOT NULL,
      actor_revision INTEGER NOT NULL CHECK(actor_revision > 0),
      family_id TEXT NOT NULL,
      preview_id TEXT NOT NULL UNIQUE REFERENCES music_target_command_previews(id),
      target_id TEXT NOT NULL, operation TEXT NOT NULL,
      created_at INTEGER NOT NULL, event_hash BLOB NOT NULL,
      UNIQUE(actor_id,request_id))""")
    connection.execute("""CREATE TABLE music_target_command_cancellations (
      command_id TEXT PRIMARY KEY REFERENCES music_target_commands(id),
      request_id TEXT NOT NULL UNIQUE, actor_id TEXT NOT NULL,
      actor_revision INTEGER NOT NULL CHECK(actor_revision > 0),
      family_id TEXT NOT NULL, created_at INTEGER NOT NULL,
      event_hash BLOB NOT NULL)""")
    connection.execute("""CREATE TABLE music_target_effect_attempts (
      command_id TEXT PRIMARY KEY REFERENCES music_target_commands(id),
      execution_id TEXT NOT NULL UNIQUE, dispatch_request_id TEXT NOT NULL UNIQUE,
      actor_id TEXT NOT NULL,
      actor_revision INTEGER NOT NULL CHECK(actor_revision > 0),
      family_id TEXT NOT NULL, installation_id TEXT NOT NULL,
      installation_revision INTEGER NOT NULL CHECK(installation_revision > 0),
      core_revision INTEGER NOT NULL CHECK(core_revision > 0),
      player_revision INTEGER NOT NULL CHECK(player_revision > 0),
      provider_digest TEXT NOT NULL,
      state TEXT NOT NULL CHECK(state IN ('pending','unknown','succeeded')),
      created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
      result_hash TEXT NOT NULL, event_hash BLOB NOT NULL)""")


def migrate_music_target_authority(connection):
    marker = connection.execute(
        "SELECT value FROM metadata WHERE key='music_target_authority_schema'"
    ).fetchone()
    names = {row['name'] for row in connection.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE "
        "'music_target_%'").fetchall()}
    expected = set(_COLUMNS)
    if marker is None:
        if names:
            raise StartupError('music_target_authority_schema_unsupported')
        _create(connection)
        connection.execute(
            "INSERT INTO metadata(key,value) VALUES('music_target_authority_schema','2')")
    elif marker['value'] == '1':
        if names != {'music_target_command_previews', 'music_target_commands'}:
            raise StartupError('music_target_authority_schema_unsupported')
        if connection.execute(
                'SELECT 1 FROM music_target_commands LIMIT 1').fetchone():
            # V1 commands had no immutable seal; provenance cannot be invented.
            raise StartupError('music_target_authority_schema_unsupported')
        connection.execute('DROP TABLE music_target_commands')
        connection.execute('DROP TABLE music_target_command_previews')
        _create(connection)
        connection.execute(
            "UPDATE metadata SET value='2' WHERE key='music_target_authority_schema'")
    elif marker['value'] != '2' or names != expected:
        raise StartupError('music_target_authority_schema_unsupported')

    for name, columns in _COLUMNS.items():
        actual = tuple(tuple(row) for row in connection.execute(
            f'SELECT name,type,"notnull",dflt_value,pk FROM pragma_table_info(\'{name}\')'))
        if actual != columns:
            raise StartupError('music_target_authority_schema_unsupported')
