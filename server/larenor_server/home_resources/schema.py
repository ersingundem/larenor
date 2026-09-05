"""Isolated additive schema under the Core initialization transaction."""
import hashlib
import hmac
import json
import sqlite3

from ..errors import StartupError


MAX_RECORDS = 512
MAX_GRANTS = 128
MAX_TOTAL_GRANTS = 4096
MAX_AUDIT = 10000
TABLES = {
    'home_resource_records': '''CREATE TABLE home_resource_records (
        id TEXT PRIMARY KEY, kind TEXT NOT NULL CHECK(kind IN ('room','resource')),
        revision INTEGER NOT NULL CHECK(revision > 0),
        acl_revision INTEGER NOT NULL CHECK(acl_revision > 0),
        nonce BLOB NOT NULL, ciphertext BLOB NOT NULL)''',
    'home_resource_state': '''CREATE TABLE home_resource_state (
        singleton INTEGER PRIMARY KEY CHECK(singleton=1),
        revision INTEGER NOT NULL CHECK(revision > 0),
        record_count INTEGER NOT NULL CHECK(record_count >= 0),
        grant_count INTEGER NOT NULL CHECK(grant_count >= 0),
        authentication_tag TEXT NOT NULL)''',
    'home_resource_audit': '''CREATE TABLE home_resource_audit (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT,
        action TEXT NOT NULL CHECK(action IN ('create','update','delete','grant')),
        status TEXT NOT NULL CHECK(status IN ('success','denied')),
        actor_id TEXT NOT NULL, target_id TEXT NOT NULL, created_at REAL NOT NULL)''',
}


def state_tag(key, scope, revision, records, grants):
    payload = json.dumps([scope.coreId, scope.homeId, revision, records, grants], separators=(',', ':')).encode('ascii')
    return hmac.new(key, b'larenor-home-resource-state-v1\0' + payload, hashlib.sha256).hexdigest()


def migrate_home_resources(connection, scope, key):
    try:
        marker = connection.execute("SELECT value FROM metadata WHERE key='home_resources_schema'").fetchone()
        actual = {r['name']: r for r in connection.execute(
            "SELECT name,type,sql FROM sqlite_master WHERE name LIKE 'home_resource_%'")}
        if marker is None:
            if actual:
                raise ValueError()
            for statement in TABLES.values():
                connection.execute(statement)
            connection.execute("INSERT INTO metadata VALUES('home_resources_schema','1')")
            connection.execute('INSERT INTO home_resource_state VALUES(1,1,0,0,?)',
                               (state_tag(key, scope, 1, 0, 0),))
        elif marker['value'] != '1' or set(actual) != set(TABLES) or any(
                r['type'] != 'table' or ' '.join(r['sql'].split()) != ' '.join(TABLES[name].split())
                for name, r in actual.items()):
            raise ValueError()
    except (ValueError, TypeError, sqlite3.Error):
        raise StartupError('home_resource_storage_invalid') from None
