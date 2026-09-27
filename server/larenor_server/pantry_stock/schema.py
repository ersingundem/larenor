import json
import secrets
import sqlite3

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..errors import StartupError
from .ledger import PantryLedger


TABLE = """CREATE TABLE pantry_stock_state (
    singleton INTEGER PRIMARY KEY CHECK(singleton=1),
    revision INTEGER NOT NULL CHECK(revision >= 0),
    nonce BLOB NOT NULL,
    ciphertext BLOB NOT NULL)"""


def _aad(scope, revision):
    return (f'larenor-pantry-stock-v1:{scope.coreId}:{scope.homeId}:'
            f'{revision}').encode('ascii')


def migrate_pantry_stock(connection, key, scope):
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='pantry_stock_schema'"
        ).fetchone()
        rows = connection.execute(
            "SELECT name,type,tbl_name,sql FROM sqlite_master "
            "WHERE name GLOB 'pantry_stock_*' OR tbl_name='pantry_stock_state'"
        ).fetchall()
        by_name = {row['name']: row for row in rows}
        if marker is None:
            if by_name:
                raise ValueError('unmarked_pantry_stock')
            connection.execute(TABLE)
            state = PantryLedger().export_state()
            plain = json.dumps(
                state, sort_keys=True, separators=(',', ':'),
                ensure_ascii=False).encode('utf-8')
            nonce = secrets.token_bytes(12)
            connection.execute(
                "INSERT INTO pantry_stock_state VALUES(1,0,?,?)",
                (nonce, AESGCM(key).encrypt(nonce, plain, _aad(scope, 0))))
            connection.execute(
                "INSERT INTO metadata VALUES('pantry_stock_schema','1')")
            return
        table = by_name.pop('pantry_stock_state', None)
        if (marker['value'] != '1' or table is None or
                table['type'] != 'table' or
                ' '.join(table['sql'].split()) != ' '.join(TABLE.split()) or
                by_name):
            raise ValueError('invalid_pantry_stock_schema')
        indexes = connection.execute(
            'PRAGMA index_list(pantry_stock_state)').fetchall()
        columns = connection.execute(
            'PRAGMA table_info(pantry_stock_state)').fetchall()
        if indexes or [
            (row['cid'], row['name'], row['type'], row['notnull'],
             row['dflt_value'], row['pk']) for row in columns
        ] != [
            (0, 'singleton', 'INTEGER', 0, None, 1),
            (1, 'revision', 'INTEGER', 1, None, 0),
            (2, 'nonce', 'BLOB', 1, None, 0),
            (3, 'ciphertext', 'BLOB', 1, None, 0),
        ]:
            raise ValueError('invalid_pantry_stock_table')
    except (ValueError, TypeError, sqlite3.Error):
        raise StartupError('pantry_stock_storage_invalid') from None
