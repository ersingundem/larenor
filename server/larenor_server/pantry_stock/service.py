import json
import secrets

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from pydantic import ValidationError

from ..errors import ApiError, StartupError
from ..home_resources.models import HomeScope
from .ledger import PantryConflict, PantryLedger


class PantryStockService:
    MAX_STATE_BYTES = 2 * 1024 * 1024

    def __init__(self, db, auth, settings, key, context):
        self.db, self.auth, self.settings = db, auth, settings
        self._cipher = AESGCM(key)
        self.scope = HomeScope.model_validate(context.model_dump())

    def _aad(self, revision):
        return (f'larenor-pantry-stock-v1:{self.scope.coreId}:'
                f'{self.scope.homeId}:{revision}').encode('ascii')

    def _scope(self, core_id, home_id):
        if (core_id, home_id) != (self.scope.coreId, self.scope.homeId):
            raise ApiError('not_found', 404)

    def _rate_limit(self, actor, *, write=False):
        self.auth.rate_limit([
            ('pantry_stock_write' if write else 'pantry_stock_read',
             actor.id, 120)])

    def _actor(self, connection, actor, core_id, home_id):
        self.auth.assert_current(connection, actor)
        self._scope(core_id, home_id)
        row = connection.execute(
            'SELECT id,disabled,must_change_password FROM users WHERE id=?',
            (actor.id,)).fetchone()
        if (row is None or row['disabled'] or row['must_change_password'] or
                actor.must_change_password):
            raise ApiError('invalid_session', 401)

    def _read(self, connection):
        rows = connection.execute(
            'SELECT * FROM pantry_stock_state LIMIT 2').fetchall()
        if len(rows) != 1:
            raise ValueError('invalid_pantry_stock_state')
        row = rows[0]
        if (row['singleton'] != 1 or type(row['revision']) is not int or
                not 0 <= row['revision'] <= 2**63 - 1 or
                type(row['nonce']) is not bytes or len(row['nonce']) != 12 or
                type(row['ciphertext']) is not bytes or
                not 16 <= len(row['ciphertext']) <= self.MAX_STATE_BYTES):
            raise ValueError('invalid_pantry_stock_state')
        value = json.loads(self._cipher.decrypt(
            row['nonce'], row['ciphertext'], self._aad(row['revision'])
        ).decode('utf-8'))
        ledger = PantryLedger.from_state(value)
        if ledger.snapshot().revision != row['revision']:
            raise ValueError('invalid_pantry_stock_state')
        return ledger

    def _save(self, connection, ledger):
        state = ledger.export_state()
        plain = json.dumps(
            state, sort_keys=True, separators=(',', ':'),
            ensure_ascii=False).encode('utf-8')
        if len(plain) > self.MAX_STATE_BYTES - 16:
            raise ApiError('receipt_capacity', 409)
        nonce = secrets.token_bytes(12)
        revision = state['revision']
        ciphertext = self._cipher.encrypt(nonce, plain, self._aad(revision))
        updated = connection.execute(
            'UPDATE pantry_stock_state SET revision=?,nonce=?,ciphertext=? '
            'WHERE singleton=1', (revision, nonce, ciphertext))
        if updated.rowcount != 1:
            raise ValueError('invalid_pantry_stock_state')

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                self._read(connection)
        except (InvalidTag, UnicodeError, json.JSONDecodeError,
                ValidationError, PantryConflict, ValueError, TypeError):
            raise StartupError('pantry_stock_storage_invalid') from None

    def snapshot(self, actor, core_id, home_id):
        self._rate_limit(actor)
        try:
            with self.db.connection() as connection:
                self._actor(connection, actor, core_id, home_id)
                ledger = self._read(connection)
                return {'scope': self.scope, 'snapshot': ledger.snapshot()}
        except (InvalidTag, UnicodeError, json.JSONDecodeError,
                ValidationError, PantryConflict, ValueError, TypeError):
            raise StartupError('pantry_stock_storage_invalid') from None

    def receive(self, actor, core_id, home_id, body):
        return self._mutate(actor, core_id, home_id, body, 'receive')

    def consume(self, actor, core_id, home_id, body):
        return self._mutate(actor, core_id, home_id, body, 'consume')

    def undo(self, actor, core_id, home_id, body):
        return self._mutate(actor, core_id, home_id, body, 'undo')

    def _mutate(self, actor, core_id, home_id, body, operation):
        self._rate_limit(actor, write=True)
        try:
            with self.db.transaction() as connection:
                self._actor(connection, actor, core_id, home_id)
                ledger = self._read(connection)
                if operation == 'receive':
                    receipt = ledger.receive(
                        request_id=body.requestId,
                        expected_revision=body.expectedRevision,
                        lot=body.lot)
                elif operation == 'consume':
                    receipt = ledger.consume(
                        request_id=body.requestId,
                        expected_revision=body.expectedRevision,
                        ingredient_key=body.ingredientKey,
                        amount=body.amount)
                else:
                    receipt = ledger.undo(
                        request_id=body.requestId,
                        expected_revision=body.expectedRevision,
                        movement_id=body.movementId)
                self._save(connection, ledger)
                return {
                    'scope': self.scope,
                    'receipt': receipt,
                    'snapshot': ledger.snapshot(),
                }
        except PantryConflict as error:
            status = 400 if error.code == 'invalid_request' else 409
            raise ApiError(error.code, status) from None
        except (InvalidTag, UnicodeError, json.JSONDecodeError,
                ValidationError, ValueError, TypeError):
            raise StartupError('pantry_stock_storage_invalid') from None
