"""Atomic encrypted bounded policy/audit inventory. No migration grants."""
import secrets
import sqlite3
from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..errors import StartupError
from .models import State


MAX_BYTES = 1024 * 1024
DDL = '''CREATE TABLE component_egress_state (
    singleton INTEGER PRIMARY KEY CHECK(singleton=1),
    nonce BLOB NOT NULL, ciphertext BLOB NOT NULL)'''


def _schema(c):
    marker = c.execute("SELECT typeof(value)='text' AND value='1' FROM metadata WHERE key='component_egress_schema'").fetchone()
    where = "name GLOB 'component_egress_*' OR tbl_name='component_egress_state'"
    count, size = c.execute('SELECT COUNT(*),COALESCE(MAX(length(CAST(sql AS BLOB))),0) FROM sqlite_master WHERE ' + where).fetchone()
    if marker is None or marker[0] != 1 or count != 1 or size > 2048:
        raise ValueError('invalid_egress_storage')
    row = c.execute('SELECT type,name,sql FROM sqlite_master WHERE ' + where).fetchone()
    if row['type'] != 'table' or row['name'] != 'component_egress_state' or ' '.join(row['sql'].split()) != ' '.join(DDL.split()):
        raise ValueError('invalid_egress_storage')


def _aad(scope):
    return f'larenor-component-egress-v1:{scope.coreId}:{scope.homeId}'.encode('ascii')


def load(c, key, scope):
    _schema(c)
    count, bad = c.execute("SELECT COUNT(*),COALESCE(SUM(CASE WHEN singleton=1 AND typeof(nonce)='blob' AND length(nonce)=12 AND typeof(ciphertext)='blob' AND length(ciphertext) BETWEEN 16 AND ? THEN 0 ELSE 1 END),0) FROM component_egress_state", (MAX_BYTES,)).fetchone()
    if count != 1 or bad:
        raise ValueError('invalid_egress_storage')
    row = c.execute('SELECT nonce,ciphertext FROM component_egress_state').fetchone()
    state = State.model_validate_json(AESGCM(key).decrypt(row['nonce'], row['ciphertext'], _aad(scope)))
    if (state.coreId, state.homeId) != (scope.coreId, scope.homeId):
        raise ValueError('invalid_egress_storage')
    return state


def save(c, key, scope, state):
    state = State.model_validate_json(state.model_dump_json())
    nonce = secrets.token_bytes(12)
    encoded = AESGCM(key).encrypt(nonce, state.model_dump_json().encode(), _aad(scope))
    if len(encoded) > MAX_BYTES:
        raise ValueError('invalid_egress_storage')
    c.execute('INSERT INTO component_egress_state VALUES(1,?,?) ON CONFLICT(singleton) DO UPDATE SET nonce=excluded.nonce,ciphertext=excluded.ciphertext', (nonce, encoded))
    if load(c, key, scope) != state:
        raise ValueError('invalid_egress_storage')


def migrate(c, scope, key):
    try:
        marker = c.execute("SELECT 1 FROM metadata WHERE key='component_egress_schema'").fetchone()
        if marker is None:
            if c.execute("SELECT 1 FROM sqlite_master WHERE name GLOB 'component_egress_*' OR tbl_name='component_egress_state'").fetchone():
                raise ValueError('invalid_egress_storage')
            c.execute(DDL)
            c.execute("INSERT INTO metadata VALUES('component_egress_schema','1')")
            save(c, key, scope, State(coreId=scope.coreId, homeId=scope.homeId, policies=[], events=[]))
        load(c, key, scope)
    except (ValueError, TypeError, InvalidTag, sqlite3.Error):
        raise StartupError('component_egress_storage_invalid') from None
