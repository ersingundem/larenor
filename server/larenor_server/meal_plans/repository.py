"""Encrypted, account-owned weekly meal plans with person ACL readback."""
import hashlib
import hmac
import json
import re
import secrets
import sqlite3

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..errors import ApiError, StartupError
from ..home_resources.models import HomeScope
from . import schema
from .models import (
    MealPlan,
    MealPlanAuthority,
    MealPlanResponse,
    PutMealPlanRequest,
    StoredMealPlan,
)


class MealPlanRepository:
    def __init__(self, db, auth, settings, key, context, people):
        self.db, self.auth, self.settings = db, auth, settings
        self.scope = HomeScope.model_validate(context.model_dump())
        self.people = people
        self._key, self._cipher = key, AESGCM(key)

    @staticmethod
    def _identity(value):
        if not isinstance(value, str) or not re.fullmatch(r'[0-9a-f]{32}', value):
            raise ValueError('invalid_identity')

    @staticmethod
    def _revision(value, *, empty=False):
        lower = 0 if empty else 1
        if type(value) is not int or not lower <= value <= 2**63 - 1:
            raise ValueError('invalid_revision')

    def _scope(self, core_id, home_id):
        if (core_id, home_id) != (self.scope.coreId, self.scope.homeId):
            raise ApiError('not_found', 404)

    def _aad(self, owner_id, revision):
        return (
            f'larenor-meal-plan-v1:{self.scope.coreId}:{self.scope.homeId}:'
            f'{owner_id}:{revision}'
        ).encode('ascii')

    def _receipt_aad(self, owner_id, family_id, request_id, request_hash):
        return (
            f'larenor-meal-plan-receipt-v1:{self.scope.coreId}:'
            f'{self.scope.homeId}:{owner_id}:{family_id}:{request_id}:'
            f'{request_hash}'
        ).encode('ascii')

    def _decode(self, row):
        self._identity(row['owner_id'])
        self._revision(row['revision'])
        if (type(row['nonce']) is not bytes or len(row['nonce']) != 12 or
                type(row['ciphertext']) is not bytes or
                not 16 <= len(row['ciphertext']) <= 65536):
            raise ValueError('invalid_storage')
        return StoredMealPlan.model_validate_json(
            self._cipher.decrypt(
                row['nonce'], row['ciphertext'],
                self._aad(row['owner_id'], row['revision']),
            )
        )

    def _save(self, connection, owner_id, revision, plan):
        plan = StoredMealPlan.model_validate(plan)
        plain = plan.model_dump_json().encode('utf-8')
        if len(plain) > 65520:
            raise ApiError('invalid_request')
        nonce = secrets.token_bytes(12)
        ciphertext = self._cipher.encrypt(
            nonce, plain, self._aad(owner_id, revision))
        connection.execute(
            'INSERT INTO meal_plan_records VALUES(?,?,?,?) '
            'ON CONFLICT(owner_id) DO UPDATE SET '
            'revision=excluded.revision,nonce=excluded.nonce,'
            'ciphertext=excluded.ciphertext',
            (owner_id, revision, nonce, ciphertext),
        )

    def _actor(self, connection, actor, *, expected=None):
        self.auth.assert_current(connection, actor)
        if actor.must_change_password:
            raise ApiError('password_change_required', 403)
        row = connection.execute(
            'SELECT id,revision,disabled,must_change_password FROM users WHERE id=?',
            (actor.id,),
        ).fetchone()
        if (row is None or row['disabled'] or row['must_change_password']):
            raise ApiError('invalid_session', 401)
        if expected is not None and row['revision'] != expected:
            raise ApiError('revision_conflict', 409)
        return row

    def _authority(self, actor, account, revision):
        return MealPlanAuthority(
            **self.scope.model_dump(), accountId=actor.id,
            sessionFamilyId=actor.family_id,
            accountRevision=account['revision'], planRevision=revision,
        ).model_dump()

    def _validate_people(self, connection, actor, plan, action):
        checked = set()
        for entry in plan.entries:
            key = (entry.personId, entry.expectedPersonRevision,
                   entry.expectedPersonAclRevision)
            if key in checked:
                continue
            self.people.authorize_connection(
                connection, actor, entry.personId, action,
                expected_revision=entry.expectedPersonRevision,
                expected_acl_revision=entry.expectedPersonAclRevision,
            )
            checked.add(key)

    def _public(self, actor, account, row, plan):
        revision = 0 if row is None else row['revision']
        return {
            'authority': self._authority(actor, account, revision),
            'plan': None if row is None else MealPlan(
                **plan.model_dump(), schemaVersion=1,
                revision=revision,
            ).model_dump(),
        }

    def _request_hash(self, body):
        value = json.dumps(
            body.model_dump(mode='json'), sort_keys=True,
            separators=(',', ':'), ensure_ascii=False,
        ).encode('utf-8')
        return hmac.new(
            self._key, b'larenor-meal-plan-request-v1\0' + value,
            hashlib.sha256,
        ).hexdigest()

    def _receipt(self, connection, actor, request_id, request_hash):
        row = connection.execute(
            'SELECT * FROM meal_plan_receipts WHERE '
            'owner_id=? AND family_id=? AND request_id=?',
            (actor.id, actor.family_id, request_id),
        ).fetchone()
        if row is None:
            return None
        if not hmac.compare_digest(row['request_hash'], request_hash):
            raise ApiError('idempotency_conflict', 409)
        if (type(row['nonce']) is not bytes or len(row['nonce']) != 12 or
                type(row['ciphertext']) is not bytes or
                not 16 <= len(row['ciphertext']) <= 65536):
            raise ValueError('invalid_receipt')
        return MealPlanResponse.model_validate_json(
            self._cipher.decrypt(
                row['nonce'], row['ciphertext'], self._receipt_aad(
                    actor.id, actor.family_id, request_id, request_hash),
            )
        )

    def _save_receipt(self, connection, actor, request_id, request_hash, result):
        response = MealPlanResponse.model_validate(result)
        plain = response.model_dump_json().encode('utf-8')
        if len(plain) > 65520:
            raise ApiError('invalid_request')
        nonce = secrets.token_bytes(12)
        connection.execute(
            'INSERT INTO meal_plan_receipts('
            'owner_id,family_id,request_id,request_hash,nonce,ciphertext) '
            'VALUES(?,?,?,?,?,?)',
            (actor.id, actor.family_id, request_id, request_hash, nonce,
             self._cipher.encrypt(nonce, plain, self._receipt_aad(
                 actor.id, actor.family_id, request_id, request_hash))),
        )
        connection.execute(
            'DELETE FROM meal_plan_receipts WHERE sequence IN ('
            'SELECT sequence FROM meal_plan_receipts WHERE owner_id=? '
            'ORDER BY sequence DESC LIMIT -1 OFFSET ?)',
            (actor.id, schema.MAX_RECEIPTS_PER_ACCOUNT),
        )
        connection.execute(
            'DELETE FROM meal_plan_receipts WHERE sequence IN ('
            'SELECT sequence FROM meal_plan_receipts '
            'ORDER BY sequence DESC LIMIT -1 OFFSET ?)',
            (schema.MAX_RECEIPTS,),
        )

    def validate_storage(self):
        try:
            with self.db.transaction() as connection:
                records = connection.execute(
                    'SELECT * FROM meal_plan_records LIMIT ?',
                    (schema.MAX_RECORDS + 1,),
                ).fetchall()
                if len(records) > schema.MAX_RECORDS:
                    raise ValueError('invalid_records')
                for row in records:
                    self._decode(row)
                receipts = connection.execute(
                    'SELECT * FROM meal_plan_receipts LIMIT ?',
                    (schema.MAX_RECEIPTS + 1,),
                ).fetchall()
                if len(receipts) > schema.MAX_RECEIPTS:
                    raise ValueError('invalid_receipts')
                per_owner = {}
                for row in receipts:
                    self._identity(row['owner_id'])
                    self._identity(row['family_id'])
                    self._identity(row['request_id'])
                    if not re.fullmatch(r'[0-9a-f]{64}', row['request_hash'] or ''):
                        raise ValueError('invalid_receipt')
                    if (type(row['nonce']) is not bytes or len(row['nonce']) != 12 or
                            type(row['ciphertext']) is not bytes or
                            not 16 <= len(row['ciphertext']) <= 65536):
                        raise ValueError('invalid_receipt')
                    MealPlanResponse.model_validate_json(self._cipher.decrypt(
                        row['nonce'], row['ciphertext'], self._receipt_aad(
                            row['owner_id'], row['family_id'], row['request_id'],
                            row['request_hash']),
                    ))
                    per_owner[row['owner_id']] = per_owner.get(row['owner_id'], 0) + 1
                    if per_owner[row['owner_id']] > schema.MAX_RECEIPTS_PER_ACCOUNT:
                        raise ValueError('invalid_receipts')
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise StartupError('meal_plan_storage_invalid') from None

    def get(self, actor, core_id, home_id):
        self._scope(core_id, home_id)
        self.auth.rate_limit([('meal_plan_read', actor.id, 120)])
        try:
            with self.db.transaction() as connection:
                account = self._actor(connection, actor)
                row = connection.execute(
                    'SELECT * FROM meal_plan_records WHERE owner_id=?',
                    (actor.id,),
                ).fetchone()
                plan = None if row is None else self._decode(row)
                if plan is not None:
                    self._validate_people(connection, actor, plan, 'read')
                return self._public(actor, account, row, plan)
        except ApiError:
            raise
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError('server_unavailable', 503) from None

    def put(self, actor, core_id, home_id, value):
        body = PutMealPlanRequest.model_validate(value)
        self._scope(core_id, home_id)
        self.auth.rate_limit([('meal_plan_write', actor.id, 60)])
        request_hash = self._request_hash(body)
        try:
            with self.db.transaction() as connection:
                account = self._actor(
                    connection, actor, expected=body.expectedAccountRevision)
                replay = self._receipt(
                    connection, actor, body.requestId, request_hash)
                if replay is not None:
                    current = connection.execute(
                        'SELECT * FROM meal_plan_records WHERE owner_id=?',
                        (actor.id,),
                    ).fetchone()
                    current_revision = 0 if current is None else current['revision']
                    if replay.authority.model_dump() != self._authority(
                            actor, account, current_revision):
                        raise ApiError('operation_replay', 409)
                    if replay.plan is not None:
                        self._validate_people(
                            connection, actor, replay.plan, 'write')
                    return replay.model_dump()
                row = connection.execute(
                    'SELECT * FROM meal_plan_records WHERE owner_id=?',
                    (actor.id,),
                ).fetchone()
                current_revision = 0 if row is None else row['revision']
                if current_revision != body.expectedRevision:
                    raise ApiError('revision_conflict', 409)
                plan = StoredMealPlan.model_validate({
                    name: getattr(body, name)
                    for name in ('weekStart', 'recipes', 'entries')
                })
                self._validate_people(connection, actor, plan, 'write')
                existing = None if row is None else self._decode(row)
                revision = current_revision
                if existing != plan:
                    if revision >= 2**63 - 1:
                        raise ApiError('revision_conflict', 409)
                    revision += 1
                    self._save(connection, actor.id, revision, plan)
                    row = {'owner_id': actor.id, 'revision': revision}
                result = self._public(actor, account, row, plan)
                self._save_receipt(
                    connection, actor, body.requestId, request_hash, result)
                return result
        except ApiError:
            raise
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError('server_unavailable', 503) from None
