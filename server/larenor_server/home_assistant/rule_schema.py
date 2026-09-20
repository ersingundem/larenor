"""Bounded encrypted immutable HA rule inventory."""

import hashlib
import hmac
import json
import sqlite3

from ..errors import StartupError


MAX_RULES = 128
MAX_CIPHER = 4096
TABLES = {
    'automation_rule_records': '''CREATE TABLE automation_rule_records (
        rule_id TEXT PRIMARY KEY, nonce BLOB NOT NULL, ciphertext BLOB NOT NULL)''',
    'automation_rule_state': '''CREATE TABLE automation_rule_state (
        singleton INTEGER PRIMARY KEY CHECK(singleton=1),
        authentication_tag TEXT NOT NULL)''',
}


def rows(connection):
    bounds = connection.execute(
        "SELECT COUNT(*),COALESCE(SUM(CASE WHEN "
        "typeof(rule_id)='text' AND length(CAST(rule_id AS BLOB))=32 "
        "AND rule_id NOT GLOB '*[^0-9a-f]*' "
        "AND typeof(nonce)='blob' AND length(nonce)=12 "
        "AND typeof(ciphertext)='blob' AND length(ciphertext) BETWEEN 16 AND ? "
        "THEN 0 ELSE 1 END),0) FROM automation_rule_records",
        (MAX_CIPHER,),
    ).fetchone()
    if bounds[0] > MAX_RULES or bounds[1]:
        raise ValueError('invalid_rule_inventory')
    return connection.execute(
        'SELECT * FROM automation_rule_records ORDER BY rule_id LIMIT ?',
        (MAX_RULES + 1,),
    ).fetchall()


def _tag(key, scope, values):
    payload = [scope.coreId, scope.homeId, [
        [row['rule_id'], hashlib.sha256(row['nonce'] + row['ciphertext']).hexdigest()]
        for row in values
    ]]
    return hmac.new(
        key,
        b'larenor-automation-rules-v1\0'
        + json.dumps(payload, separators=(',', ':'), ensure_ascii=True).encode(),
        hashlib.sha256,
    ).hexdigest()


def validate(connection, key, scope):
    marker = connection.execute(
        "SELECT value,typeof(value) AS value_type FROM metadata "
        "WHERE key='automation_rule_schema'"
    ).fetchone()
    bounds = connection.execute(
        "SELECT COUNT(*),COALESCE(MAX(length(CAST(name AS BLOB))),0),"
        "COALESCE(MAX(length(CAST(sql AS BLOB))),0) FROM sqlite_master "
        "WHERE name GLOB 'automation_rule_*' "
        "OR tbl_name IN ('automation_rule_records','automation_rule_state')"
    ).fetchone()
    if (marker is None or marker['value_type'] != 'text' or marker['value'] != '1'
            or bounds[0] > 3 or bounds[1] > 128 or bounds[2] > 2048):
        raise ValueError('invalid_rule_schema')
    actual = {
        row['name']: row
        for row in connection.execute(
            "SELECT name,type,tbl_name,sql FROM sqlite_master "
            "WHERE name GLOB 'automation_rule_*' "
            "OR tbl_name IN ('automation_rule_records','automation_rule_state')"
        )
    }
    index = actual.pop('sqlite_autoindex_automation_rule_records_1', None)
    indexes = connection.execute(
        'PRAGMA index_list(automation_rule_records)'
    ).fetchall()
    columns = connection.execute(
        'PRAGMA index_info(sqlite_autoindex_automation_rule_records_1)'
    ).fetchall()
    if (
        index is None
        or index['type'] != 'index'
        or index['sql'] is not None
        or len(indexes) != 1
        or indexes[0]['unique'] != 1
        or indexes[0]['origin'] != 'pk'
        or indexes[0]['partial'] != 0
        or len(columns) != 1
        or columns[0]['name'] != 'rule_id'
        or set(actual) != set(TABLES)
        or any(
            row['type'] != 'table'
            or ' '.join(row['sql'].split()) != ' '.join(TABLES[name].split())
            for name, row in actual.items()
        )
    ):
        raise ValueError('invalid_rule_schema')
    values = rows(connection)
    state = connection.execute(
        "SELECT * FROM automation_rule_state WHERE singleton=1"
    ).fetchall()
    if (
        len(state) != 1
        or type(state[0]['authentication_tag']) is not str
        or len(state[0]['authentication_tag']) != 64
        or not hmac.compare_digest(
            state[0]['authentication_tag'], _tag(key, scope, values)
        )
    ):
        raise ValueError('invalid_rule_state')
    return values


def update(connection, key, scope):
    connection.execute(
        'UPDATE automation_rule_state SET authentication_tag=? WHERE singleton=1',
        (_tag(key, scope, rows(connection)),),
    )


def migrate(connection, scope, key):
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='automation_rule_schema'"
        ).fetchone()
        objects = connection.execute(
            "SELECT COUNT(*) FROM sqlite_master WHERE name GLOB 'automation_rule_*' "
            "OR tbl_name IN ('automation_rule_records','automation_rule_state')"
        ).fetchone()[0]
        if marker is None:
            if objects:
                raise ValueError('partial_rule_schema')
            for statement in TABLES.values():
                connection.execute(statement)
            connection.execute(
                "INSERT INTO metadata VALUES('automation_rule_schema','1')"
            )
            connection.execute(
                'INSERT INTO automation_rule_state VALUES(1,?)',
                (_tag(key, scope, []),),
            )
        elif marker['value'] != '1':
            raise ValueError('unsupported_rule_schema')
        validate(connection, key, scope)
    except (ValueError, TypeError, sqlite3.Error):
        raise StartupError('automation_rule_storage_invalid') from None
