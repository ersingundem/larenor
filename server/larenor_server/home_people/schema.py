"""Isolated additive schema under the Core initialization transaction."""
import hashlib
import hmac
import json
import sqlite3

from ..errors import StartupError


MAX_RECORDS = 128
MAX_GRANTS = 128
MAX_TOTAL_GRANTS = 4096
MAX_AUDIT = 10000
TABLES = {
    'home_people_records': '''CREATE TABLE home_people_records (
        id TEXT PRIMARY KEY, kind TEXT NOT NULL CHECK(kind='person'),
        revision INTEGER NOT NULL CHECK(revision > 0),
        acl_revision INTEGER NOT NULL CHECK(acl_revision > 0),
        nonce BLOB NOT NULL, ciphertext BLOB NOT NULL)''',
    'home_people_state': '''CREATE TABLE home_people_state (
        singleton INTEGER PRIMARY KEY CHECK(singleton=1),
        revision INTEGER NOT NULL CHECK(revision > 0),
        record_count INTEGER NOT NULL CHECK(record_count >= 0),
        grant_count INTEGER NOT NULL CHECK(grant_count >= 0),
        authentication_tag TEXT NOT NULL)''',
    'home_people_audit': '''CREATE TABLE home_people_audit (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT,
        action TEXT NOT NULL CHECK(action IN ('create','update','delete','grant')),
        status TEXT NOT NULL CHECK(status IN ('success','denied')),
        actor_id TEXT NOT NULL, target_id TEXT NOT NULL, created_at REAL NOT NULL)''',
}


def state_tag(key, scope, revision, records, grants):
    payload = json.dumps([scope.coreId, scope.homeId, revision, records, grants], separators=(',', ':')).encode('ascii')
    return hmac.new(key, b'larenor-home-person-state-v1\0' + payload, hashlib.sha256).hexdigest()


def migrate_home_people(connection, scope, key):
    try:
        marker = connection.execute("SELECT value FROM metadata WHERE key='home_people_schema'").fetchone()
        actual = {r['name']: r for r in connection.execute(
            "SELECT name,type,tbl_name,sql FROM sqlite_master WHERE name GLOB 'home_people_*' "
            "OR tbl_name IN ('home_people_records','home_people_state','home_people_audit')")}
        if marker is not None:
            # SQLite owns one implicit index for the TEXT primary key. Match
            # that exact index; arbitrary names attached to our tables still fail.
            name = 'sqlite_autoindex_home_people_records_1'
            primary = actual.pop(name, None)
            if (primary is None or primary['type'] != 'index' or
                    primary['tbl_name'] != 'home_people_records' or primary['sql'] is not None):
                raise ValueError()
            indexes = connection.execute('PRAGMA index_list(home_people_records)').fetchall()
            columns = connection.execute('PRAGMA index_info(sqlite_autoindex_home_people_records_1)').fetchall()
            if ([(r['name'], r['unique'], r['origin'], r['partial']) for r in indexes] !=
                    [(name, 1, 'pk', 0)] or
                    [(r['seqno'], r['cid'], r['name']) for r in columns] != [(0, 0, 'id')]):
                raise ValueError()
        if marker is None:
            if actual:
                raise ValueError()
            for statement in TABLES.values():
                connection.execute(statement)
            connection.execute("INSERT INTO metadata VALUES('home_people_schema','1')")
            connection.execute('INSERT INTO home_people_state VALUES(1,1,0,0,?)',
                               (state_tag(key, scope, 1, 0, 0),))
        elif marker['value'] != '1' or set(actual) != set(TABLES) or any(
                r['type'] != 'table' or ' '.join(r['sql'].split()) != ' '.join(TABLES[name].split())
                for name, r in actual.items()):
            raise ValueError()
    except (ValueError, TypeError, sqlite3.Error):
        raise StartupError('home_people_storage_invalid') from None
