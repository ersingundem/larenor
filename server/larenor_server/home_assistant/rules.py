import secrets
import sqlite3
import uuid

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..errors import ApiError, StartupError
from . import rule_schema
from .models import CommandAttribution, CommandRequest
from .rule_models import RuleCreateRequest, RuleExecuteRequest, RuleRecord


class HomeAssistantRules:
    def __init__(self, adapter):
        self.adapter = adapter
        self._cipher = AESGCM(adapter._key)

    @staticmethod
    def _aad(rule_id):
        return f'larenor-automation-rule-v1:{rule_id}'.encode('ascii')

    def _decode(self, row):
        value = RuleRecord.model_validate_json(
            self._cipher.decrypt(
                row['nonce'], row['ciphertext'], self._aad(row['rule_id'])
            )
        )
        if value.id != row['rule_id']:
            raise ValueError('invalid_rule_identity')
        if (value.ref.coreId, value.ref.homeId) != (
            self.adapter.resources.scope.coreId,
            self.adapter.resources.scope.homeId,
        ):
            raise ValueError('invalid_rule_scope')
        return value

    def validate_storage(self):
        try:
            with self.adapter.db.connection() as connection:
                connection.execute('BEGIN')
                for row in rule_schema.validate(
                    connection, self.adapter._key, self.adapter.resources.scope
                ):
                    self._decode(row)
        except (ValueError, TypeError, InvalidTag, sqlite3.Error):
            raise StartupError('automation_rule_storage_invalid') from None

    def _stored(self, connection, rule_id, resource_id):
        self.adapter.resources._id(rule_id)
        row = connection.execute(
            'SELECT * FROM automation_rule_records WHERE rule_id=?', (rule_id,)
        ).fetchone()
        if row is None:
            raise ApiError('not_found', 404)
        value = self._decode(row)
        if value.ref.id != resource_id:
            raise ApiError('not_found', 404)
        return value

    def _current_target(self, connection, facts, resource_id, record=None):
        row, ref, data, binding = self.adapter._target(
            connection, facts, resource_id
        )
        if record is None:
            return row, ref, data, binding
        self.adapter.resources._require(
            facts,
            row,
            ref,
            data,
            'write',
            expected_revision=record.resourceRevision,
            expected_acl_revision=record.aclRevision,
        )
        if (
            binding is None
            or binding.id != record.bindingId
            or binding.revision != record.bindingRevision
            or binding.serviceId != record.serviceId
            or binding.serviceRevision != record.serviceRevision
        ):
            raise ApiError('ha_rule_changed', 409)
        self.adapter.services._home_assistant_connection(
            connection, record.serviceId, record.serviceRevision
        )
        return row, ref, data, binding

    def create(self, actor, core, home, resource_id, body):
        body = RuleCreateRequest.model_validate(body)
        with self.adapter._tx(actor, core, home, admin=True) as (connection, facts):
            rule_schema.validate(
                connection, self.adapter._key, self.adapter.resources.scope
            )
            row, ref, data, binding = self._current_target(
                connection, facts, resource_id
            )
            self.adapter.resources._require(
                facts,
                row,
                ref,
                data,
                'write',
                expected_revision=body.expectedResourceRevision,
                expected_acl_revision=body.expectedAclRevision,
            )
            if (
                binding is None
                or binding.revision != body.expectedBindingRevision
                or binding.serviceRevision != body.expectedServiceRevision
            ):
                raise ApiError('ha_rule_changed', 409)
            self.adapter.services._home_assistant_connection(
                connection, binding.serviceId, binding.serviceRevision
            )
            if len(rule_schema.rows(connection)) >= rule_schema.MAX_RULES:
                raise ApiError('ha_rule_limit_reached', 429)
            rule = RuleRecord(
                id=uuid.uuid4().hex,
                ref=ref,
                action=body.action,
                creatorId=actor.id,
                resourceRevision=row['revision'],
                aclRevision=row['acl_revision'],
                bindingId=binding.id,
                bindingRevision=binding.revision,
                serviceId=binding.serviceId,
                serviceRevision=binding.serviceRevision,
            )
            nonce = secrets.token_bytes(12)
            ciphertext = self._cipher.encrypt(
                nonce, rule.model_dump_json().encode(), self._aad(rule.id)
            )
            if len(ciphertext) > rule_schema.MAX_CIPHER:
                raise ApiError('server_unavailable', 503)
            connection.execute(
                'INSERT INTO automation_rule_records VALUES(?,?,?)',
                (rule.id, nonce, ciphertext),
            )
            rule_schema.update(
                connection, self.adapter._key, self.adapter.resources.scope
            )
            rule_schema.validate(
                connection, self.adapter._key, self.adapter.resources.scope
            )
            if self._stored(connection, rule.id, resource_id) != rule:
                raise ValueError('rule_write_failed')
            return {'rule': rule.model_dump(mode='json')}

    def get(self, actor, core, home, resource_id, rule_id):
        with self.adapter._tx(actor, core, home, admin=True) as (connection, facts):
            rule_schema.validate(
                connection, self.adapter._key, self.adapter.resources.scope
            )
            self._current_target(connection, facts, resource_id)
            return {
                'rule': self._stored(connection, rule_id, resource_id).model_dump(
                    mode='json'
                )
            }

    def execute(
        self, actor, core, home, resource_id, rule_id, body, *, cancelled=lambda: False
    ):
        body = RuleExecuteRequest.model_validate(body)
        with self.adapter._tx(actor, core, home) as (connection, facts):
            rule_schema.validate(
                connection, self.adapter._key, self.adapter.resources.scope
            )
            rule = self._stored(connection, rule_id, resource_id)
            if rule.revision != body.expectedRuleRevision:
                raise ApiError('ha_rule_changed', 409)
            self._current_target(connection, facts, resource_id, rule)
        command = CommandRequest(
            requestId=body.requestId,
            action=rule.action,
            expectedBindingRevision=rule.bindingRevision,
            expectedResourceRevision=rule.resourceRevision,
            expectedAclRevision=rule.aclRevision,
        )
        attribution = CommandAttribution(
            correlationId=body.requestId,
            source='core_rule',
            reason='explicit_rule_execution',
            serviceId=rule.serviceId,
            serviceRevision=rule.serviceRevision,
            ruleId=rule.id,
            ruleRevision=rule.revision,
            executionId=body.requestId,
        )
        return self.adapter.command(
            actor,
            core,
            home,
            resource_id,
            command,
            cancelled=cancelled,
            attribution=attribution,
        )
