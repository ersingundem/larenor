"""Explicit encrypted Immich album grants for normal Core operation."""

import hashlib
import hmac
import json
import secrets
import sqlite3

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..errors import ApiError, StartupError
from .immich import ImmichAlbumCatalog, compatible_version
from .models import MemoryError, MemoryPolicy, _id, _uuid


_SQL = """CREATE TABLE memory_source_bindings (
    account_id TEXT PRIMARY KEY REFERENCES users(id),
    account_revision INTEGER NOT NULL CHECK(account_revision > 0),
    revision INTEGER NOT NULL CHECK(revision > 0),
    nonce BLOB NOT NULL, ciphertext BLOB NOT NULL)"""


class MemorySourceBindings:
    def __init__(self, database, auth, services, context, key, authority_provider,
                 *, catalog_factory=ImmichAlbumCatalog):
        self.db, self.auth, self.services, self.context = database, auth, services, context
        self._cipher = AESGCM(hmac.new(key, b"larenor-memory-source-v1", hashlib.sha256).digest())
        self._authority_provider, self._catalog_factory = authority_provider, catalog_factory

    @staticmethod
    def migrate(connection):
        row = connection.execute("SELECT sql FROM sqlite_master WHERE type='table' "
                                 "AND name='memory_source_bindings'").fetchone()
        marker = connection.execute("SELECT value FROM metadata WHERE key='memory_source_schema'").fetchone()
        if row is None and marker is None:
            connection.execute(_SQL)
            connection.execute("INSERT INTO metadata VALUES('memory_source_schema','1')")
        elif (row is None or marker is None or marker['value'] != '1'
              or ' '.join(row['sql'].split()) != ' '.join(_SQL.split())):
            raise StartupError("memory_source_storage_invalid")

    def _aad(self, account_id, account_revision, revision):
        return (f"larenor-memory-source-v1:{self.context.coreId}:{self.context.homeId}:"
                f"{account_id}:{account_revision}:{revision}").encode("ascii")

    def _decode(self, row):
        try:
            if (not _id(row['account_id']) or type(row['account_revision']) is not int
                    or type(row['revision']) is not int
                    or not 1 <= row['revision'] < 2**63 - 1
                    or not 1 <= row['account_revision'] < 2**63
                    or type(row['nonce']) is not bytes or len(row['nonce']) != 12
                    or type(row['ciphertext']) is not bytes
                    or not 16 <= len(row['ciphertext']) <= 32768):
                raise ValueError()
            value = json.loads(self._cipher.decrypt(row['nonce'], row['ciphertext'],
                self._aad(row['account_id'], row['account_revision'], row['revision'])))
            if type(value) is not dict or set(value) != {'binding', 'albums'}:
                raise ValueError()
            binding = value['binding']
            albums = value['albums']
            if binding is None:
                if albums != []:
                    raise ValueError()
            else:
                if type(binding) is not dict or set(binding) != {
                        'serviceId', 'serviceRevision', 'allowedAlbumIds', 'faceSearchEnabled'}:
                    raise ValueError()
                MemoryPolicy(self.context.coreId, self.context.homeId, row['account_id'],
                    binding['serviceId'], binding['serviceRevision'],
                    tuple(binding['allowedAlbumIds']), binding['faceSearchEnabled'])
                if (type(albums) is not list or len(albums) != len(binding['allowedAlbumIds'])
                        or [item['albumId'] for item in albums] != binding['allowedAlbumIds']
                        or any(type(item) is not dict or set(item) != {'albumId', 'title'}
                               or type(item['title']) is not str or not 1 <= len(item['title']) <= 256
                               or any(ord(char) < 32 or ord(char) == 127 for char in item['title'])
                               for item in albums)):
                    raise ValueError()
            return value
        except (InvalidTag, ValueError, TypeError, KeyError, MemoryError):
            raise ApiError("memory_source_storage_invalid", 503) from None

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                rows = connection.execute('SELECT * FROM memory_source_bindings LIMIT 129').fetchall()
                if len(rows) > 128:
                    raise ApiError('memory_source_storage_invalid', 503)
                for row in rows:
                    self._decode(row)
        except (ApiError, sqlite3.Error):
            raise StartupError('memory_source_storage_invalid') from None

    def _authorize(self, connection, actor, account_id=None, *, admin=False):
        self.auth.assert_current(connection, actor)
        if actor.must_change_password or (admin or account_id not in (None, actor.id)) and actor.role != 'admin':
            raise ApiError('forbidden', 403)
        target = account_id or actor.id
        if not _id(target):
            raise ApiError('invalid_request')
        row = connection.execute('SELECT id,username,revision FROM users WHERE id=? '
                                 'AND disabled=0 AND must_change_password=0', (target,)).fetchone()
        if row is None:
            raise ApiError('memory_members_changed', 409)
        return row

    def _stored(self, connection, target):
        row = connection.execute('SELECT * FROM memory_source_bindings WHERE account_id=?',
                                 (target['id'],)).fetchone()
        if row is None:
            return 0, {'binding': None, 'albums': []}
        value = self._decode(row)
        if row['account_revision'] != target['revision']:
            value = {'binding': None, 'albums': []}
        return row['revision'], value

    def _service(self, connection, service_id, revision):
        row, record = self.services._record(connection, service_id, revision)
        if (record['kind'] != 'immich' or record['verification']['state'] != 'authenticated'
                or set(record['credentials']) not in ({'apiKey'}, {'token'})
                or not compatible_version(record['verification'].get('version'))):
            raise ApiError('memory_binding_changed', 409)
        return self.services._private(row, record)

    def _save(self, connection, target, revision, value):
        if revision >= 2**63 - 2:
            raise ApiError('memory_binding_changed', 409)
        nonce = secrets.token_bytes(12)
        ciphertext = self._cipher.encrypt(nonce, json.dumps(value, ensure_ascii=True,
            sort_keys=True, separators=(',', ':'), allow_nan=False).encode('ascii'),
            self._aad(target['id'], target['revision'], revision + 1))
        connection.execute('INSERT INTO memory_source_bindings VALUES(?,?,?,?,?) '
            'ON CONFLICT(account_id) DO UPDATE SET account_revision=excluded.account_revision,'
            'revision=excluded.revision,nonce=excluded.nonce,ciphertext=excluded.ciphertext',
            (target['id'], target['revision'], revision + 1, nonce, ciphertext))

    def state(self, actor, body):
        authority, _member_ids = self._authority_provider(actor)
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            target = self._authorize(connection, actor, body.accountId)
            revision, value = self._stored(connection, target)
            services, members = [], []
            if actor.role == 'admin':
                members = [dict(accountId=row['id'], username=row['username'], revision=row['revision'])
                    for row in connection.execute('SELECT id,username,revision FROM users '
                        'WHERE disabled=0 AND must_change_password=0 ORDER BY username,id LIMIT 33')]
                if len(members) > 32:
                    raise ApiError('memory_members_changed', 409)
                rows = connection.execute('SELECT * FROM service_connections ORDER BY id LIMIT 129').fetchall()
                if len(rows) > 128:
                    raise ApiError('memory_service_unavailable', 503)
                for row in rows:
                    record = self.services._decode(row)
                    if (record['kind'] == 'immich' and record['verification']['state'] == 'authenticated'
                            and compatible_version(record['verification'].get('version'))):
                        services.append(dict(serviceId=row['id'], serviceRevision=row['revision'], name=record['name']))
            return {'requestId': body.requestId, 'source': {
                'schemaVersion': 1, 'accountId': target['id'], 'accountRevision': target['revision'],
                'revision': revision, 'canManage': actor.role == 'admin',
                'binding': value['binding'], 'albums': value['albums'],
                'services': services, 'members': members,
                'membersRevision': authority.members_revision}}

    def catalog(self, actor, body):
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            self._authorize(connection, actor, admin=True)
            source = self._service(connection, body.serviceId, body.expectedServiceRevision)
        try:
            with self._catalog_factory(source) as reader:
                albums = reader.albums()
        except MemoryError as error:
            raise ApiError('memory_' + error.code, 503) from None
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            self._authorize(connection, actor, admin=True)
            self._service(connection, body.serviceId, body.expectedServiceRevision)
        return {'requestId': body.requestId, 'albums': list(albums)}

    def grant(self, actor, body):
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            target = self._authorize(connection, actor, body.accountId, admin=True)
            if target['revision'] != body.expectedAccountRevision:
                raise ApiError('memory_members_changed', 409)
        albums = self.catalog(actor, body)['albums']
        selected = tuple(body.allowedAlbumIds)
        if (not 1 <= len(selected) <= 32 or len(set(selected)) != len(selected)
                or any(not _uuid(value) for value in selected)
                or not set(selected).issubset({value['albumId'] for value in albums})):
            raise ApiError('memory_album_forbidden', 409)
        names = {value['albumId']: value['title'] for value in albums}
        value = {'binding': {'serviceId': body.serviceId,
            'serviceRevision': body.expectedServiceRevision,
            'allowedAlbumIds': list(selected), 'faceSearchEnabled': False},
            'albums': [{'albumId': value, 'title': names[value]} for value in selected]}
        with self.db.transaction() as connection:
            target = self._authorize(connection, actor, body.accountId, admin=True)
            if target['revision'] != body.expectedAccountRevision:
                raise ApiError('memory_members_changed', 409)
            self._service(connection, body.serviceId, body.expectedServiceRevision)
            revision, _old = self._stored(connection, target)
            if revision != body.expectedRevision:
                raise ApiError('memory_binding_changed', 409)
            self._save(connection, target, revision, value)
        return self.state(actor, body)

    def consent(self, actor, body):
        with self.db.transaction() as connection:
            target = self._authorize(connection, actor)
            revision, value = self._stored(connection, target)
            binding = value['binding']
            if revision != body.expectedRevision or binding is None:
                raise ApiError('memory_binding_changed', 409)
            self._service(connection, binding['serviceId'], binding['serviceRevision'])
            binding['faceSearchEnabled'] = body.enabled
            self._save(connection, target, revision, value)
        return self.state(actor, body)

    def revoke(self, actor, body):
        with self.db.transaction() as connection:
            target = self._authorize(connection, actor, body.accountId)
            revision, _value = self._stored(connection, target)
            if revision != body.expectedRevision or target['revision'] != body.expectedAccountRevision:
                raise ApiError('memory_binding_changed', 409)
            self._save(connection, target, revision, {'binding': None, 'albums': []})
        return self.state(actor, body)

    def resolve(self, actor, service_id=None, revision=None):
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            target = self._authorize(connection, actor)
            _generation, value = self._stored(connection, target)
            binding = value['binding']
            if binding is None:
                raise MemoryError('policy_unavailable')
            if (service_id is not None and binding['serviceId'] != service_id
                    or revision is not None and binding['serviceRevision'] != revision):
                raise MemoryError('binding_changed')
            source = self._service(connection, binding['serviceId'], binding['serviceRevision'])
            return (MemoryPolicy(self.context.coreId, self.context.homeId, actor.id,
                source.id, source.revision, tuple(binding['allowedAlbumIds']),
                binding['faceSearchEnabled'], _generation), source)

    def policy(self, actor, service_id, revision):
        return self.resolve(actor, service_id, revision)[0]

    def connection(self, actor, service_id, revision):
        return self.resolve(actor, service_id, revision)[1]
