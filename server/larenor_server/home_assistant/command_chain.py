"""Bounded encrypted append chain, with caller-retained checkpoint comparison.

The authenticated head detects local alteration. A checkpoint kept outside this
database is necessary to detect a complete, internally valid database rollback.
Neither proves a physical event nor protects against a dishonest verifier.
"""
import base64
import hashlib
import hmac
import json
import re
import secrets
import sqlite3

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..errors import ApiError, StartupError
from .command_storage import decode_command
from .schema import MAX_COMMAND_CIPHER, MAX_COMMANDS, command_rows


MAX_ENTRIES = MAX_COMMANDS * 2
ZERO = '0' * 64
TABLES = {
    'command_history_chain': '''CREATE TABLE command_history_chain (
        sequence INTEGER PRIMARY KEY CHECK(sequence>0),
        kind TEXT NOT NULL CHECK(kind IN ('baseline','command_write')),
        request_id TEXT NOT NULL, resource_id TEXT NOT NULL,
        nonce BLOB NOT NULL, ciphertext BLOB NOT NULL,
        previous_hash TEXT NOT NULL, entry_hash TEXT NOT NULL)''',
    'command_history_state': '''CREATE TABLE command_history_state (
        singleton INTEGER PRIMARY KEY CHECK(singleton=1),
        chain_id TEXT NOT NULL, sequence INTEGER NOT NULL CHECK(sequence>=0),
        head_hash TEXT NOT NULL, authentication_tag TEXT NOT NULL)''',
}


def _json(value):
    return json.dumps(value, separators=(',', ':'), ensure_ascii=True, allow_nan=False).encode('ascii')


def _signed(key, domain, value):
    return hmac.new(key, domain + _json(value), hashlib.sha256).hexdigest()


def _state_tag(key, scope, chain_id, sequence, head):
    return _signed(key, b'larenor-command-chain-head-v1\0',
        [scope.coreId, scope.homeId, chain_id, sequence, head])


def _objects(c):
    where = "name GLOB 'command_history_*' OR tbl_name IN ('command_history_chain','command_history_state')"
    bounds = c.execute('SELECT COUNT(*),COALESCE(MAX(length(CAST(name AS BLOB))),0),'
        'COALESCE(MAX(length(CAST(sql AS BLOB))),0) FROM sqlite_master WHERE ' + where).fetchone()
    if bounds[0] > 2 or bounds[1] > 128 or bounds[2] > 2048:
        raise ValueError('invalid_history_storage')
    return {r['name']: r for r in c.execute('SELECT name,type,sql FROM sqlite_master WHERE ' + where)}


def _schema(c):
    marker = c.execute("SELECT typeof(value)='text' AND value='1' FROM metadata WHERE key='command_history_schema'").fetchone()
    objects = _objects(c)
    if marker is None or marker[0] != 1 or set(objects) != set(TABLES) or any(
            row['type'] != 'table' or ' '.join(row['sql'].split()) != ' '.join(TABLES[name].split())
            for name, row in objects.items()):
        raise ValueError('invalid_history_storage')


def _hex_sql(field, size):
    return f"typeof({field})='text' AND length(CAST({field} AS BLOB))={size} AND {field} NOT GLOB '*[^0-9a-f]*'"


def _state(c, key, scope):
    good = ("singleton=1 AND typeof(sequence)='integer' AND sequence BETWEEN 0 AND ? AND " +
        ' AND '.join(_hex_sql(f, size) for f, size in
                     [('chain_id', 32), ('head_hash', 64), ('authentication_tag', 64)]))
    count, bad = c.execute('SELECT COUNT(*),COALESCE(SUM(CASE WHEN ' + good +
        ' THEN 0 ELSE 1 END),0) FROM command_history_state', (MAX_ENTRIES,)).fetchone()
    if count != 1 or bad:
        raise ValueError('invalid_history_storage')
    state = c.execute('SELECT * FROM command_history_state').fetchone()
    if not hmac.compare_digest(state['authentication_tag'], _state_tag(key, scope,
            state['chain_id'], state['sequence'], state['head_hash'])):
        raise ValueError('invalid_history_storage')
    return state


def _rows(c):
    good = ("typeof(sequence)='integer' AND sequence BETWEEN 1 AND ? "
        "AND kind IN ('baseline','command_write') AND typeof(nonce)='blob' AND length(nonce)=12 "
        "AND typeof(ciphertext)='blob' AND length(ciphertext) BETWEEN 16 AND ? AND " +
        ' AND '.join(_hex_sql(f, size) for f, size in
            [('request_id', 32), ('resource_id', 32), ('previous_hash', 64), ('entry_hash', 64)]))
    count, bad = c.execute('SELECT COUNT(*),COALESCE(SUM(CASE WHEN ' + good +
        ' THEN 0 ELSE 1 END),0) FROM command_history_chain', (MAX_ENTRIES, MAX_COMMAND_CIPHER)).fetchone()
    if count > MAX_ENTRIES or bad:
        raise ValueError('invalid_history_storage')
    return c.execute('SELECT * FROM command_history_chain ORDER BY sequence LIMIT ?', (MAX_ENTRIES + 1,)).fetchall()


def _entry_hash(scope, chain_id, sequence, kind, row, previous):
    data = [scope.coreId, scope.homeId, chain_id, sequence, kind, row['request_id'],
        row['resource_id'], hashlib.sha256(row['nonce'] + row['ciphertext']).hexdigest(), previous]
    return hashlib.sha256(b'larenor-command-chain-entry-v1\0' + _json(data)).hexdigest()


def verify(c, key, scope):
    """Verify the entire bounded chain and every current command's last snapshot."""
    _schema(c)
    state, rows = _state(c, key, scope), _rows(c)
    cipher, previous, latest = AESGCM(key), ZERO, {}
    seen_write = False
    for sequence, row in enumerate(rows, 1):
        if row['kind'] == 'baseline' and (seen_write or row['request_id'] in latest):
            raise ValueError('invalid_history_storage')
        seen_write |= row['kind'] == 'command_write'
        if (row['sequence'] != sequence or row['previous_hash'] != previous or
                row['entry_hash'] != _entry_hash(scope, state['chain_id'], sequence, row['kind'], row, previous)):
            raise ValueError('invalid_history_storage')
        decode_command(row, cipher, scope)
        latest[row['request_id']] = (row['resource_id'], row['nonce'], row['ciphertext'])
        previous = row['entry_hash']
    if (state['sequence'], state['head_hash']) != (len(rows), previous):
        raise ValueError('invalid_history_storage')
    current = {row['request_id']: (row['resource_id'], row['nonce'], row['ciphertext']) for row in command_rows(c)}
    if current != latest:
        raise ValueError('invalid_history_storage')
    return state


def append(c, key, scope, row, *, kind='command_write'):
    """Caller verifies the old chain before its command write, in the same TX."""
    state = _state(c, key, scope)
    sequence = state['sequence'] + 1
    if sequence > MAX_ENTRIES:
        raise ApiError('ha_limit_reached', 429)
    head = _entry_hash(scope, state['chain_id'], sequence, kind, row, state['head_hash'])
    c.execute('INSERT INTO command_history_chain VALUES(?,?,?,?,?,?,?,?)',
        (sequence, kind, row['request_id'], row['resource_id'], row['nonce'], row['ciphertext'], state['head_hash'], head))
    c.execute('UPDATE command_history_state SET sequence=?,head_hash=?,authentication_tag=? WHERE singleton=1',
        (sequence, head, _state_tag(key, scope, state['chain_id'], sequence, head)))
    return sequence, head


def migrate_command_history(c, scope, key):
    try:
        marker = c.execute("SELECT 1 FROM metadata WHERE key='command_history_schema'").fetchone()
        if marker is None:
            if _objects(c):
                raise ValueError('invalid_history_storage')
            for sql in TABLES.values():
                c.execute(sql)
            identity = secrets.token_hex(16)
            c.execute('INSERT INTO command_history_state VALUES(1,?,0,?,?)',
                (identity, ZERO, _state_tag(key, scope, identity, 0, ZERO)))
            c.execute("INSERT INTO metadata VALUES('command_history_schema','1')")
            # Existing receipts have no authenticated historical append order.
            # This is a canonical baseline, not a fabricated event chronology.
            for row in command_rows(c):
                append(c, key, scope, row, kind='baseline')
        verify(c, key, scope)
    except (ValueError, TypeError, sqlite3.Error, InvalidTag, ApiError):
        raise StartupError('command_history_storage_invalid') from None


def checkpoint(c, key, scope, expected=None):
    """Called after verify(), inside the same authenticated read transaction."""
    state = _state(c, key, scope)
    payload = [scope.coreId, scope.homeId, state['chain_id'], state['sequence'], state['head_hash']]
    if expected is not None:
        if not isinstance(expected, str) or len(expected) > 512 or re.fullmatch(
                r'[A-Za-z0-9_-]{1,400}\.[0-9a-f]{64}', expected) is None:
            raise ApiError('invalid_request')
        encoded, signature = expected.split('.')
        try:
            decoded = base64.b64decode(encoded + '=' * (-len(encoded) % 4), altchars=b'-_', validate=True)
            previous = json.loads(decoded)
            if (type(previous) is not list or len(previous) != 5 or
                    any(type(previous[i]) is not str or re.fullmatch('[0-9a-f]{32}', previous[i]) is None for i in (0, 1, 2)) or
                    type(previous[3]) is not int or not 0 <= previous[3] <= MAX_ENTRIES or
                    type(previous[4]) is not str or re.fullmatch('[0-9a-f]{64}', previous[4]) is None or
                    _json(previous) != decoded):
                raise ValueError()
        except (ValueError, TypeError, UnicodeError):
            raise ApiError('invalid_request') from None
        if not hmac.compare_digest(signature, _signed(key, b'larenor-command-checkpoint-v1\0', previous)):
            raise ApiError('revision_conflict', 409)
        prefix = c.execute('SELECT entry_hash FROM command_history_chain WHERE sequence=?', (previous[3],)).fetchone()
        prefix_hash = ZERO if previous[3] == 0 else None if prefix is None else prefix[0]
        if previous[:3] != payload[:3] or previous[3] > payload[3] or previous[4] != prefix_hash:
            raise ApiError('revision_conflict', 409)
    token = base64.urlsafe_b64encode(_json(payload)).decode('ascii').rstrip('=')
    token += '.' + _signed(key, b'larenor-command-checkpoint-v1\0', payload)
    return {'schemaVersion': 1, 'scope': scope.model_dump(), 'chainId': state['chain_id'],
        'sequence': state['sequence'], 'headHash': state['head_hash'], 'checkpoint': token,
        'verified': True, 'comparedCheckpoint': expected is not None, 'causalityVerified': False}
