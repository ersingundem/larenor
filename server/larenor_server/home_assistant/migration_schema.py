"""Separate bounded migration receipts; existing HA v2 storage is unchanged."""
import hashlib
import hmac
import json
import sqlite3

from ..errors import StartupError

MAX_RECORDS = 256
MAX_CIPHER = 8192
TABLES = {
    'direct_ha_migrations': '''CREATE TABLE direct_ha_migrations (
        request_id TEXT PRIMARY KEY, resource_id TEXT NOT NULL,
        nonce BLOB NOT NULL, ciphertext BLOB NOT NULL)''',
    'direct_ha_state': '''CREATE TABLE direct_ha_state (
        singleton INTEGER PRIMARY KEY CHECK(singleton=1),
        authentication_tag TEXT NOT NULL)''',
}


def rows(c):
    bounds = c.execute("SELECT COUNT(*),COALESCE(SUM(CASE WHEN "
        "typeof(request_id)='text' AND length(CAST(request_id AS BLOB))=32 AND request_id NOT GLOB '*[^0-9a-f]*' "
        "AND typeof(resource_id)='text' AND length(CAST(resource_id AS BLOB))=32 AND resource_id NOT GLOB '*[^0-9a-f]*' "
        "AND typeof(nonce)='blob' AND length(nonce)=12 "
        "AND typeof(ciphertext)='blob' AND length(ciphertext) BETWEEN 16 AND ? "
        "THEN 0 ELSE 1 END),0) FROM direct_ha_migrations", (MAX_CIPHER,)).fetchone()
    if bounds[0] > MAX_RECORDS or bounds[1]:
        raise ValueError()
    return c.execute('SELECT * FROM direct_ha_migrations ORDER BY request_id LIMIT ?', (MAX_RECORDS+1,)).fetchall()


def tag(key, scope, values):
    data = [scope.coreId, scope.homeId, [[r['request_id'], r['resource_id'],
        hashlib.sha256(r['nonce']+r['ciphertext']).hexdigest()] for r in values]]
    return hmac.new(key, b'larenor-direct-ha-migrations-v1\0'+json.dumps(data,
        separators=(',', ':')).encode(), hashlib.sha256).hexdigest()


def validate(c, key, scope):
    values = rows(c)
    bounds = c.execute("SELECT COUNT(*),COALESCE(SUM(CASE WHEN singleton=1 "
        "AND typeof(authentication_tag)='text' AND length(CAST(authentication_tag AS BLOB))=64 "
        "AND authentication_tag NOT GLOB '*[^0-9a-f]*' THEN 0 ELSE 1 END),0) FROM direct_ha_state").fetchone()
    if bounds[0] != 1 or bounds[1]:
        raise ValueError()
    state = c.execute('SELECT authentication_tag FROM direct_ha_state').fetchone()[0]
    if not hmac.compare_digest(state, tag(key, scope, values)):
        raise ValueError()
    return values


def update(c, key, scope):
    c.execute('UPDATE direct_ha_state SET authentication_tag=? WHERE singleton=1', (tag(key, scope, rows(c)),))


def migrate(c, key, scope):
    try:
        marker = c.execute("SELECT value FROM metadata WHERE key='direct_ha_schema'").fetchone()
        query = "FROM sqlite_master WHERE name GLOB 'direct_ha_*' OR tbl_name IN ('direct_ha_migrations','direct_ha_state')"
        bounds = c.execute('SELECT COUNT(*),COALESCE(MAX(length(CAST(name AS BLOB))),0),'
            'COALESCE(MAX(length(CAST(sql AS BLOB))),0) '+query).fetchone()
        if bounds[0] > 3 or bounds[1] > 128 or bounds[2] > 2048:
            raise ValueError()
        actual = {r['name']: r for r in c.execute('SELECT name,type,sql '+query)}
        if marker is None:
            if actual:
                raise ValueError()
            for sql in TABLES.values():
                c.execute(sql)
            c.execute("INSERT INTO metadata VALUES('direct_ha_schema','1')")
            c.execute('INSERT INTO direct_ha_state VALUES(1,?)', (tag(key, scope, []),))
        else:
            if marker['value'] != '1':
                raise ValueError()
            name = 'sqlite_autoindex_direct_ha_migrations_1'
            index = actual.pop(name, None)
            indexes = [r for r in c.execute('PRAGMA index_list(direct_ha_migrations)') if r['name'] == name]
            columns = c.execute(f'PRAGMA index_info({name})').fetchall()
            if (index is None or index['type'] != 'index' or index['sql'] is not None or
                    len(indexes) != 1 or indexes[0]['origin'] != 'pk' or indexes[0]['unique'] != 1 or
                    indexes[0]['partial'] != 0 or len(columns) != 1 or columns[0]['name'] != 'request_id'):
                raise ValueError()
            if set(actual) != set(TABLES) or any(r['type'] != 'table' or
                    ' '.join(r['sql'].split()) != ' '.join(TABLES[n].split()) for n, r in actual.items()):
                raise ValueError()
            validate(c, key, scope)
    except (ValueError, TypeError, sqlite3.Error):
        raise StartupError('direct_ha_migration_storage_invalid') from None
