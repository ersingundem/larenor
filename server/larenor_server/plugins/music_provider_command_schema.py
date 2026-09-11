"""Secret-free, immutable provider command intent journal."""

from ..errors import StartupError


_PREVIEW_COLUMNS = (
    'id', 'request_id', 'revision', 'actor_id', 'actor_revision', 'family_id',
    'installation_id', 'installation_revision', 'provider_setup_id',
    'provider_revision', 'provider_domain', 'command', 'plan_hash',
    'created_at', 'expires_at',
)
_COMMAND_COLUMNS = (
    'id', 'request_id', 'revision', 'actor_id', 'actor_revision', 'family_id',
    'preview_id', 'installation_id', 'installation_revision',
    'provider_setup_id', 'provider_revision', 'provider_domain', 'command',
    'state', 'error_code', 'created_at',
)


def _create(connection, name, body):
    exists = connection.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)).fetchone()
    if exists:
        raise StartupError('music_provider_commands_schema_unsupported')
    connection.execute(body)


def migrate_music_provider_commands(connection):
    marker = connection.execute(
        "SELECT value FROM metadata WHERE key='music_provider_commands_schema'").fetchone()
    if marker is None:
        _create(connection, 'music_provider_command_previews', '''CREATE TABLE music_provider_command_previews (
            id TEXT PRIMARY KEY, request_id TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision=1),
            actor_id TEXT NOT NULL, actor_revision INTEGER NOT NULL CHECK(actor_revision>0), family_id TEXT NOT NULL,
            installation_id TEXT NOT NULL REFERENCES media_installations(id), installation_revision INTEGER NOT NULL CHECK(installation_revision>0),
            provider_setup_id TEXT NOT NULL REFERENCES music_provider_setups(id), provider_revision INTEGER NOT NULL CHECK(provider_revision>0),
            provider_domain TEXT NOT NULL,
            command TEXT NOT NULL CHECK(command IN ('enable','disable')), plan_hash TEXT NOT NULL,
            created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, UNIQUE(actor_id,request_id)
        )''')
        _create(connection, 'music_provider_commands', '''CREATE TABLE music_provider_commands (
            id TEXT PRIMARY KEY, request_id TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision=1),
            actor_id TEXT NOT NULL, actor_revision INTEGER NOT NULL CHECK(actor_revision>0), family_id TEXT NOT NULL,
            preview_id TEXT NOT NULL REFERENCES music_provider_command_previews(id),
            installation_id TEXT NOT NULL REFERENCES media_installations(id), installation_revision INTEGER NOT NULL CHECK(installation_revision>0),
            provider_setup_id TEXT NOT NULL REFERENCES music_provider_setups(id), provider_revision INTEGER NOT NULL CHECK(provider_revision>0),
            provider_domain TEXT NOT NULL,
            command TEXT NOT NULL CHECK(command IN ('enable','disable')), state TEXT NOT NULL CHECK(state='blocked'),
            error_code TEXT NOT NULL CHECK(error_code='effect_unavailable'), created_at INTEGER NOT NULL,
            UNIQUE(actor_id,request_id)
        )''')
        connection.execute("INSERT INTO metadata(key,value) VALUES('music_provider_commands_schema','1')")
    elif marker['value'] != '1':
        raise StartupError('music_provider_commands_schema_unsupported')
    for name in ('music_provider_command_previews', 'music_provider_commands'):
        if connection.execute(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)).fetchone() is None:
            raise StartupError('music_provider_commands_schema_unsupported')
    for name, expected in (
        ('music_provider_command_previews', _PREVIEW_COLUMNS),
        ('music_provider_commands', _COMMAND_COLUMNS),
    ):
        actual = tuple(row['name'] for row in connection.execute(
            f"PRAGMA table_info('{name}')"))
        if actual != expected:
            raise StartupError('music_provider_commands_schema_unsupported')
