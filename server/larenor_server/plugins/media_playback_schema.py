"""Durable one-use intents and receipts for managed media playback."""

from ..errors import StartupError


_INTENTS_SQL = '''CREATE TABLE media_playback_intents (
    id TEXT PRIMARY KEY NOT NULL CHECK(length(id)=32),
    actor_id TEXT NOT NULL CHECK(length(actor_id)=32),
    actor_revision INTEGER NOT NULL CHECK(actor_revision>0),
    family_id TEXT NOT NULL CHECK(length(family_id)=32),
    installation_id TEXT NOT NULL CHECK(length(installation_id)=32),
    installation_revision INTEGER NOT NULL CHECK(installation_revision>0),
    snapshot_revision INTEGER NOT NULL CHECK(snapshot_revision>0),
    jellyfin_service_revision INTEGER NOT NULL CHECK(jellyfin_service_revision>0),
    item_id TEXT NOT NULL CHECK(length(item_id)=32),
    media_key TEXT NOT NULL CHECK(length(media_key) BETWEEN 1 AND 96),
    playback_revision INTEGER NOT NULL CHECK(playback_revision>0),
    targets_json TEXT NOT NULL CHECK(length(targets_json)<=65536),
    expires_at INTEGER NOT NULL,
    consumed_by TEXT UNIQUE CHECK(consumed_by IS NULL OR length(consumed_by)=32)
)'''

_RECEIPTS_SQL = '''CREATE TABLE media_playback_receipts (
    request_id TEXT PRIMARY KEY NOT NULL CHECK(length(request_id)=32),
    intent_id TEXT UNIQUE NOT NULL REFERENCES media_playback_intents(id),
    actor_id TEXT NOT NULL CHECK(length(actor_id)=32),
    request_json TEXT NOT NULL CHECK(length(request_json)<=4096),
    state TEXT NOT NULL CHECK(state IN ('pending','succeeded')),
    receipt_json TEXT CHECK(receipt_json IS NULL OR length(receipt_json)<=4096),
    created_at INTEGER NOT NULL
)'''

_INTENT_COLUMNS = (
    'id', 'actor_id', 'actor_revision', 'family_id', 'installation_id',
    'installation_revision', 'snapshot_revision',
    'jellyfin_service_revision', 'item_id', 'media_key',
    'playback_revision', 'targets_json', 'expires_at', 'consumed_by',
)
_RECEIPT_COLUMNS = (
    'request_id', 'intent_id', 'actor_id', 'request_json', 'state',
    'receipt_json', 'created_at',
)


def _columns(connection, table):
    return tuple(row['name'] for row in connection.execute(
        f"PRAGMA table_info('{table}')"))


def _verify(connection):
    if (_columns(connection, 'media_playback_intents') != _INTENT_COLUMNS
            or _columns(connection, 'media_playback_receipts')
            != _RECEIPT_COLUMNS):
        raise StartupError('media_playback_schema_unsupported')


def _create(connection):
    connection.execute(_INTENTS_SQL)
    connection.execute(_RECEIPTS_SQL)


def migrate_media_playback(connection):
    marker = connection.execute(
        "SELECT value FROM metadata WHERE key='media_playback_schema'"
    ).fetchone()
    tables = {row['name'] for row in connection.execute(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name IN ('media_playback_intents','media_playback_receipts')")}
    if marker is None:
        if tables:
            raise StartupError('media_playback_schema_unsupported')
        _create(connection)
        connection.execute(
            "INSERT INTO metadata(key,value) VALUES('media_playback_schema','2')"
        )
    elif marker['value'] == '1' and tables == {
            'media_playback_intents', 'media_playback_receipts'}:
        # V1 intents have no account-revision or session-family binding. There
        # is no safe value to infer, so all untrusted one-use state is retired.
        connection.execute(
            'ALTER TABLE media_playback_receipts '
            'RENAME TO media_playback_receipts_v1')
        connection.execute(
            'ALTER TABLE media_playback_intents '
            'RENAME TO media_playback_intents_v1')
        _create(connection)
        connection.execute('DROP TABLE media_playback_receipts_v1')
        connection.execute('DROP TABLE media_playback_intents_v1')
        connection.execute(
            "UPDATE metadata SET value='2' "
            "WHERE key='media_playback_schema'")
    elif marker['value'] != '2' or tables != {
            'media_playback_intents', 'media_playback_receipts'}:
        raise StartupError('media_playback_schema_unsupported')
    _verify(connection)
