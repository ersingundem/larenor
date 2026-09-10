"""Additive encrypted binding inventory; exact attached objects and keyed state."""
import hashlib
import hmac
import json
import sqlite3
import secrets

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..errors import StartupError
from .command_storage import command_aad, decode_command
from .models import CommandAttribution, StoredCommand

MAX_BINDINGS = 256
MAX_CIPHER = 2048
MAX_COMMANDS = 1024
MAX_COMMAND_CIPHER = 4096
TABLES = {
    'home_assistant_bindings': '''CREATE TABLE home_assistant_bindings (
        resource_id TEXT PRIMARY KEY, binding_id TEXT NOT NULL UNIQUE,
        revision INTEGER NOT NULL CHECK(revision > 0), nonce BLOB NOT NULL,
        ciphertext BLOB NOT NULL)''',
    'home_assistant_state': '''CREATE TABLE home_assistant_state (
        singleton INTEGER PRIMARY KEY CHECK(singleton=1),
        authentication_tag TEXT NOT NULL)''',
    'home_assistant_commands': '''CREATE TABLE home_assistant_commands (
        request_id TEXT PRIMARY KEY, resource_id TEXT NOT NULL,
        nonce BLOB NOT NULL, ciphertext BLOB NOT NULL)''',
}


def _tag_v1(key, scope, rows):
    payload = [scope.coreId, scope.homeId, [[r['resource_id'], r['binding_id'], r['revision'],
        hashlib.sha256(r['nonce'] + r['ciphertext']).hexdigest()] for r in rows]]
    return hmac.new(key, b'larenor-ha-bindings-v1\0' + json.dumps(payload,
        separators=(',', ':'), ensure_ascii=True).encode(), hashlib.sha256).hexdigest()


def tag(key, scope, bindings, commands):
    payload = [scope.coreId, scope.homeId,
        [[r['resource_id'], r['binding_id'], r['revision'],
          hashlib.sha256(r['nonce'] + r['ciphertext']).hexdigest()] for r in bindings],
        [[r['request_id'], r['resource_id'],
          hashlib.sha256(r['nonce'] + r['ciphertext']).hexdigest()] for r in commands]]
    return hmac.new(key, b'larenor-ha-storage-v2\0' + json.dumps(payload,
        separators=(',', ':'), ensure_ascii=True).encode(), hashlib.sha256).hexdigest()


def rows(c):
    # Evaluate lengths/types inside SQLite before materializing any attacker-sized
    # TEXT/BLOB. The keyed state is checked only after these allocation bounds.
    bounds = c.execute("SELECT COUNT(*), COALESCE(SUM(CASE WHEN "
        "typeof(resource_id)='text' AND length(CAST(resource_id AS BLOB))=32 AND resource_id NOT GLOB '*[^0-9a-f]*' "
        "AND typeof(binding_id)='text' AND length(CAST(binding_id AS BLOB))=32 AND binding_id NOT GLOB '*[^0-9a-f]*' "
        "AND typeof(revision)='integer' AND revision>0 "
        "AND typeof(nonce)='blob' AND length(nonce)=12 "
        "AND typeof(ciphertext)='blob' AND length(ciphertext) BETWEEN 16 AND ? "
        "THEN 0 ELSE 1 END),0) FROM home_assistant_bindings", (MAX_CIPHER,)).fetchone()
    if bounds[0] > MAX_BINDINGS or bounds[1]:
        raise ValueError()
    values = c.execute('SELECT * FROM home_assistant_bindings ORDER BY resource_id LIMIT ?', (MAX_BINDINGS + 1,)).fetchall()
    if len(values) > MAX_BINDINGS or any(type(r['nonce']) is not bytes or len(r['nonce']) != 12
            or type(r['ciphertext']) is not bytes or not 16 <= len(r['ciphertext']) <= MAX_CIPHER for r in values):
        raise ValueError()
    return values


def command_rows(c):
    bounds = c.execute("SELECT COUNT(*), COALESCE(SUM(CASE WHEN "
        "typeof(request_id)='text' AND length(CAST(request_id AS BLOB))=32 AND request_id NOT GLOB '*[^0-9a-f]*' "
        "AND typeof(resource_id)='text' AND length(CAST(resource_id AS BLOB))=32 AND resource_id NOT GLOB '*[^0-9a-f]*' "
        "AND typeof(nonce)='blob' AND length(nonce)=12 "
        "AND typeof(ciphertext)='blob' AND length(ciphertext) BETWEEN 16 AND ? "
        "THEN 0 ELSE 1 END),0) FROM home_assistant_commands", (MAX_COMMAND_CIPHER,)).fetchone()
    if bounds[0] > MAX_COMMANDS or bounds[1]:
        raise ValueError()
    values = c.execute('SELECT * FROM home_assistant_commands ORDER BY request_id LIMIT ?',
                       (MAX_COMMANDS + 1,)).fetchall()
    if len(values) > MAX_COMMANDS:
        raise ValueError()
    return values


def validate(c, key, scope):
    values, commands = rows(c), command_rows(c)
    bounds = c.execute("SELECT COUNT(*), COALESCE(SUM(CASE WHEN singleton=1 "
        "AND typeof(authentication_tag)='text' AND length(CAST(authentication_tag AS BLOB))=64 "
        "AND authentication_tag NOT GLOB '*[^0-9a-f]*' THEN 0 ELSE 1 END),0) "
        "FROM home_assistant_state").fetchone()
    if bounds[0] != 1 or bounds[1]:
        raise ValueError()
    state = c.execute('SELECT * FROM home_assistant_state LIMIT 2').fetchall()
    if len(state) != 1 or state[0]['singleton'] != 1 or not hmac.compare_digest(
            state[0]['authentication_tag'], tag(key, scope, values, commands)):
        raise ValueError()
    return values


def update(c, key, scope):
    c.execute('UPDATE home_assistant_state SET authentication_tag=? WHERE singleton=1',
              (tag(key, scope, rows(c), command_rows(c)),))


def _actual(c):
    return {r['name']: r for r in c.execute("SELECT name,type,tbl_name,sql FROM sqlite_master "
        "WHERE name GLOB 'home_assistant_*' OR tbl_name IN "
        "('home_assistant_bindings','home_assistant_state','home_assistant_commands')")}


def _tables(c, actual, expected):
    for n, table, column, origin in [(1, 'home_assistant_bindings', 'resource_id', 'pk'),
                                     (2, 'home_assistant_bindings', 'binding_id', 'u'),
                                     (1, 'home_assistant_commands', 'request_id', 'pk')]:
        name = f'sqlite_autoindex_{table}_{n}'
        if table not in expected:
            continue
        row = actual.pop(name, None)
        indexes = [] if row is None else [x for x in c.execute(f'PRAGMA index_list({table})') if x['name'] == name]
        cols = [] if row is None else c.execute(f'PRAGMA index_info({name})').fetchall()
        if (row is None or row['type'] != 'index' or row['sql'] is not None or len(indexes) != 1
                or indexes[0]['unique'] != 1 or indexes[0]['origin'] != origin or indexes[0]['partial'] != 0
                or len(cols) != 1 or cols[0]['name'] != column):
            raise ValueError()
    if set(actual) != set(expected) or any(r['type'] != 'table' or
            ' '.join(r['sql'].split()) != ' '.join(expected[name].split()) for name, r in actual.items()):
        raise ValueError()


def migrate_home_assistant(c, scope, key):
    try:
        marker = c.execute("SELECT value FROM metadata WHERE key='home_assistant_schema'").fetchone()
        bounds = c.execute("SELECT COUNT(*),COALESCE(MAX(length(CAST(name AS BLOB))),0),COALESCE(MAX(length(CAST(sql AS BLOB))),0) "
            "FROM sqlite_master WHERE name GLOB 'home_assistant_*' OR tbl_name IN "
            "('home_assistant_bindings','home_assistant_state','home_assistant_commands')").fetchone()
        if bounds[0] > 6 or bounds[1] > 128 or bounds[2] > 2048:
            raise ValueError()
        actual = _actual(c)
        if marker is None:
            if actual:
                raise ValueError()
            for sql in TABLES.values():
                c.execute(sql)
            c.execute("INSERT INTO metadata VALUES('home_assistant_schema','3')")
            c.execute('INSERT INTO home_assistant_state VALUES(1,?)', (tag(key, scope, [], []),))
        elif marker['value'] == '1':
            legacy = {name: TABLES[name] for name in ('home_assistant_bindings', 'home_assistant_state')}
            _tables(c, actual, legacy)
            bindings = rows(c)
            state = c.execute('SELECT * FROM home_assistant_state LIMIT 2').fetchall()
            if len(state) != 1 or not hmac.compare_digest(
                    state[0]['authentication_tag'], _tag_v1(key, scope, bindings)):
                raise ValueError()
            c.execute(TABLES['home_assistant_commands'])
            c.execute("UPDATE metadata SET value='2' WHERE key='home_assistant_schema'")
            update(c, key, scope)
        else:
            if marker['value'] not in ('2', '3'):
                raise ValueError()
            _tables(c, actual, TABLES)
            validate(c, key, scope)
        if marker is not None and marker['value'] in ('1', '2'):
            # The caller holds the Core initialization transaction. Verify the
            # old keyed inventory before rewriting any ciphertext or marker.
            validate(c, key, scope)
            cipher = AESGCM(key)
            for row in command_rows(c):
                old = decode_command(row, cipher, scope, legacy=True)
                value = StoredCommand(request=old.request, receipt=old.receipt,
                    attribution=CommandAttribution(correlationId=old.request.requestId,
                        source='unknown', reason='unknown', serviceId=None, serviceRevision=None))
                nonce = secrets.token_bytes(12)
                encrypted = cipher.encrypt(nonce, value.model_dump_json().encode(), command_aad(row))
                if len(encrypted) > MAX_COMMAND_CIPHER:
                    raise ValueError()
                c.execute('UPDATE home_assistant_commands SET nonce=?,ciphertext=? WHERE request_id=?',
                          (nonce, encrypted, row['request_id']))
                saved = c.execute('SELECT * FROM home_assistant_commands WHERE request_id=?',
                                  (row['request_id'],)).fetchone()
                if saved is None or decode_command(saved, cipher, scope) != value:
                    raise ValueError()
            update(c, key, scope)
            validate(c, key, scope)
            c.execute("UPDATE metadata SET value='3' WHERE key='home_assistant_schema'")
            if c.execute("SELECT value FROM metadata WHERE key='home_assistant_schema'").fetchone()[0] != '3':
                raise ValueError()
    except (ValueError, TypeError, sqlite3.Error, InvalidTag):
        raise StartupError('home_assistant_storage_invalid') from None
