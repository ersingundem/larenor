"""Authenticated encrypted Proxmox resource bindings."""
import hashlib
import hmac
import json
import sqlite3

from ..errors import StartupError


MAX_BINDINGS = 256
MAX_CIPHER = 2048
TABLE = '''CREATE TABLE proxmox_resource_bindings (
    resource_id TEXT PRIMARY KEY, binding_id TEXT NOT NULL UNIQUE,
    revision INTEGER NOT NULL CHECK(revision > 0), nonce BLOB NOT NULL,
    ciphertext BLOB NOT NULL)'''
STATE = '''CREATE TABLE proxmox_resource_state (
    singleton INTEGER PRIMARY KEY CHECK(singleton=1), authentication_tag TEXT NOT NULL)'''


def rows(c):
    values = c.execute('SELECT * FROM proxmox_resource_bindings ORDER BY resource_id LIMIT ?',
                       (MAX_BINDINGS + 1,)).fetchall()
    if len(values) > MAX_BINDINGS or any(
            type(r['resource_id']) is not str or len(r['resource_id']) != 32 or
            type(r['binding_id']) is not str or len(r['binding_id']) != 32 or
            type(r['revision']) is not int or r['revision'] < 1 or
            type(r['nonce']) is not bytes or len(r['nonce']) != 12 or
            type(r['ciphertext']) is not bytes or not 16 <= len(r['ciphertext']) <= MAX_CIPHER
            for r in values):
        raise ValueError()
    return values


def tag(key, scope, values):
    data = [scope.coreId, scope.homeId, [[r['resource_id'], r['binding_id'], r['revision'],
        hashlib.sha256(r['nonce'] + r['ciphertext']).hexdigest()] for r in values]]
    return hmac.new(key, b'larenor-proxmox-resource-v1\0' + json.dumps(
        data, separators=(',', ':')).encode(), hashlib.sha256).hexdigest()


def validate(c, key, scope):
    values = rows(c)
    state = c.execute('SELECT * FROM proxmox_resource_state LIMIT 2').fetchall()
    if (len(state) != 1 or state[0]['singleton'] != 1 or
            not hmac.compare_digest(state[0]['authentication_tag'], tag(key, scope, values))):
        raise ValueError()
    return values


def update(c, key, scope):
    c.execute('UPDATE proxmox_resource_state SET authentication_tag=? WHERE singleton=1',
              (tag(key, scope, rows(c)),))


def migrate(c, scope, key):
    try:
        marker = c.execute("SELECT value FROM metadata WHERE key='proxmox_resource_schema'").fetchone()
        tables = {r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='table' "
            "AND name IN ('proxmox_resource_bindings','proxmox_resource_state')")}
        if marker is None:
            if tables:
                raise ValueError()
            c.execute(TABLE); c.execute(STATE)
            c.execute("INSERT INTO metadata VALUES('proxmox_resource_schema','1')")
            c.execute('INSERT INTO proxmox_resource_state VALUES(1,?)', (tag(key, scope, []),))
        elif marker['value'] != '1' or tables != {'proxmox_resource_bindings', 'proxmox_resource_state'}:
            raise ValueError()
        validate(c, key, scope)
    except (ValueError, TypeError, sqlite3.Error):
        raise StartupError('proxmox_resource_storage_invalid') from None
