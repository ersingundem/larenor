"""Additive migration for multi-service media installation jobs."""

import sqlite3

from larenor_server.plugins.media_installation_schema import (
    migrate_media_installations,
)


def test_schema_one_rows_survive_removal_of_preparation_unique_constraint():
    connection = sqlite3.connect(':memory:')
    connection.row_factory = sqlite3.Row
    connection.execute('CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT)')
    connection.execute(
        "INSERT INTO metadata VALUES('media_installations_schema','1')")
    connection.execute('''CREATE TABLE media_installations (
        id TEXT PRIMARY KEY,
        sequence INTEGER NOT NULL UNIQUE CHECK(sequence > 0),
        revision INTEGER NOT NULL CHECK(revision > 0),
        actor_id TEXT NOT NULL,
        actor_revision INTEGER NOT NULL CHECK(actor_revision > 0),
        family_id TEXT NOT NULL,
        request_id TEXT NOT NULL,
        preparation_id TEXT NOT NULL UNIQUE,
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
        'CREATE INDEX media_installations_state '
        'ON media_installations(state,sequence)')
    row = (
        '1' * 32, 1, 1, '2' * 32, 1, '3' * 32, '4' * 32,
        '5' * 32, '6' * 32, 'queued', 'queued', 0, None, 1, 1,
        b'0' * 12, b'ciphertext',
    )
    connection.execute(
        'INSERT INTO media_installations VALUES('
        + ','.join('?' for _ in row) + ')', row)

    migrate_media_installations(connection)
    migrate_media_installations(connection)

    assert connection.execute(
        "SELECT value FROM metadata WHERE key='media_installations_schema'"
    ).fetchone()[0] == '2'
    assert tuple(connection.execute(
        'SELECT id,preparation_id,nonce,ciphertext FROM media_installations'
    ).fetchone()) == (row[0], row[7], row[-2], row[-1])
    unique = {
        tuple(field[0] for field in connection.execute(
            'SELECT name FROM pragma_index_info(?) ORDER BY seqno',
            (index['name'],)))
        for index in connection.execute(
            'PRAGMA index_list(media_installations)')
        if index['unique']
    }
    assert ('preparation_id',) not in unique
