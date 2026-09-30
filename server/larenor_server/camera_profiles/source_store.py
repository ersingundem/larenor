"""Encrypted, bounded camera bindings, observations, and dispatch records."""

import hashlib
import hmac
import json
import secrets
import sqlite3

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..errors import ApiError, StartupError

SQL = """CREATE TABLE camera_provider_records (
    id TEXT PRIMARY KEY, nonce BLOB NOT NULL, ciphertext BLOB NOT NULL)"""
STATE_SQL = """CREATE TABLE camera_provider_state (
    singleton INTEGER PRIMARY KEY CHECK(singleton=1), authentication_tag TEXT NOT NULL)"""
MAX_RECORDS = 4096
MAX_STORAGE_BYTES = 16 * 1024 * 1024


def migrate_camera_provider(connection, key, core_id, home_id):
    row = connection.execute("SELECT type,sql FROM sqlite_master WHERE name='camera_provider_records'").fetchone()
    marker = connection.execute("SELECT value FROM metadata WHERE key='camera_provider_schema'").fetchone()
    actual = {item['name']: item for item in connection.execute(
        "SELECT name,type,sql FROM sqlite_master WHERE name LIKE 'camera_provider_%' "
        "OR (tbl_name IN ('camera_provider_records','camera_provider_state') AND sql IS NOT NULL)")}
    if row is None and marker is None:
        if actual:
            raise StartupError('camera_profile_storage_invalid')
        connection.execute(SQL)
        connection.execute(STATE_SQL)
        connection.execute("INSERT INTO metadata VALUES('camera_provider_schema','1')")
        store = CameraProviderStore(None, key, core_id, home_id)
        connection.execute('INSERT INTO camera_provider_state VALUES(1,?)', (store._inventory_tag(connection),))
    elif (row is None or marker is None or marker['value'] != '1'
          or set(actual) != {'camera_provider_records', 'camera_provider_state'}
          or any(item['type'] != 'table' or ' '.join(item['sql'].split()) != ' '.join(statement.split())
                 for name, statement in [('camera_provider_records', SQL), ('camera_provider_state', STATE_SQL)]
                 for item in [actual[name]])):
        raise StartupError('camera_profile_storage_invalid')


class CameraProviderStore:
    def __init__(self, database, key, core_id, home_id):
        self.db = database
        self._cipher = AESGCM(hmac.new(key, b'camera-provider-store-v1', hashlib.sha256).digest())
        self._seal_key = hmac.new(key, b'camera-provider-inventory-v1', hashlib.sha256).digest()
        self._scope = f'{core_id}:{home_id}'

    def _inventory_tag(self, connection):
        digest = hashlib.sha256(self._scope.encode())
        rows = connection.execute('SELECT * FROM camera_provider_records ORDER BY id LIMIT ?',
                                  (MAX_RECORDS + 1,)).fetchall()
        if len(rows) > MAX_RECORDS:
            raise StartupError('camera_profile_storage_invalid')
        total = 0
        for row in rows:
            if (not isinstance(row['id'], str) or not 1 <= len(row['id']) <= 160
                    or type(row['nonce']) is not bytes or len(row['nonce']) != 12
                    or type(row['ciphertext']) is not bytes or not 16 <= len(row['ciphertext']) <= 131072):
                raise StartupError('camera_profile_storage_invalid')
            raw = row['id'].encode() + row['nonce'] + row['ciphertext']
            total += len(raw)
            if total > MAX_STORAGE_BYTES:
                raise StartupError('camera_profile_storage_invalid')
            digest.update(len(raw).to_bytes(4, 'big') + raw)
        return hmac.new(self._seal_key, digest.digest(), hashlib.sha256).hexdigest()

    def _verify(self, connection):
        rows = connection.execute('SELECT * FROM camera_provider_state LIMIT 2').fetchall()
        if (len(rows) != 1 or rows[0]['singleton'] != 1
                or not isinstance(rows[0]['authentication_tag'], str)
                or not hmac.compare_digest(rows[0]['authentication_tag'], self._inventory_tag(connection))):
            raise StartupError('camera_profile_storage_invalid')

    def _decode(self, row):
        try:
            if (not isinstance(row['id'], str) or not 1 <= len(row['id']) <= 160
                    or type(row['nonce']) is not bytes or len(row['nonce']) != 12
                    or type(row['ciphertext']) is not bytes
                    or not 16 <= len(row['ciphertext']) <= 131072):
                raise ValueError
            raw = self._cipher.decrypt(row['nonce'], row['ciphertext'],
                                       f'camera-provider-v1:{self._scope}:{row["id"]}'.encode())
            value = json.loads(raw)
            if type(value) is not dict:
                raise ValueError
            return value
        except (ValueError, TypeError, InvalidTag):
            raise StartupError('camera_profile_storage_invalid') from None

    def get(self, key, connection=None):
        if connection is None:
            with self.db.connection() as current:
                current.execute('BEGIN')
                return self.get(key, current)
        self._verify(connection)
        row = connection.execute('SELECT * FROM camera_provider_records WHERE id=?', (key,)).fetchone()
        return None if row is None else self._decode(row)

    def put(self, key, value, *, connection=None, create_only=False):
        if connection is None:
            with self.db.transaction() as current:
                return self.put(key, value, connection=current, create_only=create_only)
        old = self.get(key, connection)
        if create_only and old is not None:
            raise ApiError('idempotency_conflict', 409)
        if old is None and connection.execute('SELECT COUNT(*) FROM camera_provider_records').fetchone()[0] >= MAX_RECORDS:
            raise ApiError('camera_profile_audit_limit', 429)
        raw = json.dumps(value, ensure_ascii=True, separators=(',', ':'), allow_nan=False).encode()
        if len(raw) > 131056:
            raise ApiError('invalid_request')
        nonce = secrets.token_bytes(12)
        encrypted = self._cipher.encrypt(nonce, raw, f'camera-provider-v1:{self._scope}:{key}'.encode())
        connection.execute('INSERT INTO camera_provider_records VALUES(?,?,?) '
                           'ON CONFLICT(id) DO UPDATE SET nonce=excluded.nonce,ciphertext=excluded.ciphertext',
                           (key, nonce, encrypted))
        connection.execute('UPDATE camera_provider_state SET authentication_tag=? WHERE singleton=1',
                           (self._inventory_tag(connection),))

    def observe(self, key, value):
        digest = hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()).hexdigest()
        with self.db.transaction() as connection:
            old = self.get('observation:' + key, connection)
            if old is not None and (set(old) != {'revision', 'digest'}
                    or type(old['revision']) is not int or not 1 <= old['revision'] < 2**63 - 1
                    or not isinstance(old['digest'], str) or len(old['digest']) != 64):
                raise StartupError('camera_profile_storage_invalid')
            revision = 1 if old is None else old['revision'] + int(old['digest'] != digest)
            if old is None or old['digest'] != digest:
                self.put('observation:' + key, {'revision': revision, 'digest': digest}, connection=connection)
            return revision

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                connection.execute('BEGIN')
                self._verify(connection)
                rows = connection.execute('SELECT * FROM camera_provider_records LIMIT ?', (MAX_RECORDS + 1,)).fetchall()
                if len(rows) > MAX_RECORDS:
                    raise ValueError
                for row in rows:
                    self._decode(row)
        except (sqlite3.Error, ValueError, TypeError):
            raise StartupError('camera_profile_storage_invalid') from None
