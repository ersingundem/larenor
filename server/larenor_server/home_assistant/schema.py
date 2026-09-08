"""Additive encrypted binding inventory; exact attached objects and keyed state."""
import hashlib
import hmac
import json
import sqlite3

from ..errors import StartupError

MAX_BINDINGS = 256
MAX_CIPHER = 2048
TABLES = {
    'home_assistant_bindings': '''CREATE TABLE home_assistant_bindings (
        resource_id TEXT PRIMARY KEY, binding_id TEXT NOT NULL UNIQUE,
        revision INTEGER NOT NULL CHECK(revision > 0), nonce BLOB NOT NULL,
        ciphertext BLOB NOT NULL)''',
    'home_assistant_state': '''CREATE TABLE home_assistant_state (
        singleton INTEGER PRIMARY KEY CHECK(singleton=1),
        authentication_tag TEXT NOT NULL)''',
}


def tag(key, scope, rows):
    payload = [scope.coreId, scope.homeId, [[r['resource_id'], r['binding_id'], r['revision'],
        hashlib.sha256(r['nonce'] + r['ciphertext']).hexdigest()] for r in rows]]
    return hmac.new(key, b'larenor-ha-bindings-v1\0' + json.dumps(payload,
        separators=(',', ':'), ensure_ascii=True).encode(), hashlib.sha256).hexdigest()


def rows(c):
    bounds = c.execute('SELECT COUNT(*), MAX(length(nonce)), MAX(length(ciphertext)) FROM home_assistant_bindings').fetchone()
    if bounds[0] > MAX_BINDINGS or (bounds[0] and (bounds[1] != 12 or bounds[2] > MAX_CIPHER)):
        raise ValueError()
    values = c.execute('SELECT * FROM home_assistant_bindings ORDER BY resource_id LIMIT ?', (MAX_BINDINGS + 1,)).fetchall()
    if len(values) > MAX_BINDINGS or any(type(r['nonce']) is not bytes or len(r['nonce']) != 12
            or type(r['ciphertext']) is not bytes or not 16 <= len(r['ciphertext']) <= MAX_CIPHER for r in values):
        raise ValueError()
    return values


def validate(c, key, scope):
    values = rows(c)
    state = c.execute('SELECT * FROM home_assistant_state LIMIT 2').fetchall()
    if len(state) != 1 or state[0]['singleton'] != 1 or not hmac.compare_digest(
            state[0]['authentication_tag'], tag(key, scope, values)):
        raise ValueError()
    return values


def update(c, key, scope):
    c.execute('UPDATE home_assistant_state SET authentication_tag=? WHERE singleton=1', (tag(key, scope, rows(c)),))


def migrate_home_assistant(c, scope, key):
    try:
        marker = c.execute("SELECT value FROM metadata WHERE key='home_assistant_schema'").fetchone()
        actual = {r['name']: r for r in c.execute("SELECT name,type,tbl_name,sql FROM sqlite_master "
            "WHERE name GLOB 'home_assistant_*' OR tbl_name IN ('home_assistant_bindings','home_assistant_state')")}
        if marker is None:
            if actual:
                raise ValueError()
            for sql in TABLES.values():
                c.execute(sql)
            c.execute("INSERT INTO metadata VALUES('home_assistant_schema','1')")
            c.execute('INSERT INTO home_assistant_state VALUES(1,?)', (tag(key, scope, []),))
        else:
            if marker['value'] != '1':
                raise ValueError()
            for n, column, origin in [(1, 'resource_id', 'pk'), (2, 'binding_id', 'u')]:
                name = f'sqlite_autoindex_home_assistant_bindings_{n}'
                r = actual.pop(name, None)
                indexes = [x for x in c.execute('PRAGMA index_list(home_assistant_bindings)') if x['name'] == name]
                cols = c.execute(f'PRAGMA index_info({name})').fetchall()
                if (r is None or r['type'] != 'index' or r['sql'] is not None or len(indexes) != 1
                        or indexes[0]['unique'] != 1 or indexes[0]['origin'] != origin or indexes[0]['partial'] != 0
                        or len(cols) != 1 or cols[0]['name'] != column):
                    raise ValueError()
            if set(actual) != set(TABLES) or any(r['type'] != 'table' or
                    ' '.join(r['sql'].split()) != ' '.join(TABLES[name].split()) for name, r in actual.items()):
                raise ValueError()
            validate(c, key, scope)
    except (ValueError, TypeError, sqlite3.Error):
        raise StartupError('home_assistant_storage_invalid') from None
