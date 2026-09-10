from contextlib import contextmanager
import sqlite3
import uuid
from urllib.parse import urlsplit
from cryptography.exceptions import InvalidTag

from ..errors import ApiError
from ..services.transport import ServiceTransport, ProbeTransportError
from . import storage
from .models import Event, Policy, Update


class ComponentEgress:
    def __init__(self, services, key, scope):
        self.services, self.key, self.scope = services, key, scope

    @contextmanager
    def _tx(self, actor=None):
        try:
            with self.services.db.transaction() as c:
                if actor is not None:
                    self.services._assert_admin(c, actor)
                yield c, storage.load(c, self.key, self.scope)
        except (ValueError, TypeError, InvalidTag, sqlite3.Error):
            raise ApiError('server_unavailable', 503) from None

    def _connection(self, c, service_id, revision=None):
        row, record = self.services._record(c, service_id, revision)
        if record['kind'] not in {'home_assistant', 'keenetic'}:
            raise ApiError('not_found', 404)
        return self.services._private(row, record)

    @staticmethod
    def _component(connection):
        return (
            'home_assistant_probe'
            if connection.kind == 'home_assistant'
            else 'keenetic_command_worker'
        )

    @classmethod
    def _policy(cls, state, connection):
        component = cls._component(connection)
        return next(
            (p for p in state.policies
             if p.serviceId == connection.id and p.component == component),
            Policy(
                component=component, serviceId=connection.id,
                serviceRevision=connection.revision, revision=0, grants=[]
            ),
        )

    @classmethod
    def _matches(cls, policy, connection):
        parsed = urlsplit(connection.base_url)
        return (policy.component == cls._component(connection) and
                policy.serviceRevision == connection.revision and len(policy.grants) == 1 and
                (policy.grants[0].scheme, policy.grants[0].host, policy.grants[0].port) ==
                (parsed.scheme, parsed.hostname, parsed.port or (443 if parsed.scheme == 'https' else 80)))

    def _event(self, c, state, actor, policy, correlation, reason):
        event = Event(actorId=actor.id, serviceId=policy.serviceId, correlationId=correlation,
                      policyRevision=policy.revision, reason=reason, timestamp=float(self.services.settings.clock()))
        state.events = [*state.events[-255:], event]
        storage.save(c, self.key, self.scope, state)
        c.execute('INSERT INTO service_audit(event,action,status,timestamp,actor_id,target_id) VALUES(?,?,?,?,?,?)',
                  ('admin.component.egress', 'update' if reason == 'policy_replaced' else 'check',
                   'denied' if reason in ('grant_missing', 'probe_unconfirmed') else 'success',
                   event.timestamp, actor.id, policy.serviceId))
        c.execute('DELETE FROM service_audit WHERE id IN (SELECT id FROM service_audit ORDER BY id DESC LIMIT -1 OFFSET 10000)')

    @staticmethod
    def _response(state, policy):
        return {'policy': policy.model_dump(), 'audit': [e.model_dump() for e in state.events if e.serviceId == policy.serviceId][-20:]}

    def read(self, actor, service_id):
        with self._tx(actor) as (c, state):
            return self._response(state, self._policy(state, self._connection(c, service_id)))

    def update(self, actor, service_id, body):
        body = Update.model_validate(body)
        with self._tx(actor) as (c, state):
            connection = self._connection(c, service_id, body.expectedServiceRevision)
            old = self._policy(state, connection)
            if old.revision != body.expectedRevision:
                raise ApiError('revision_conflict', 409)
            policy = Policy(
                component=self._component(connection),
                serviceId=service_id, serviceRevision=connection.revision,
                revision=old.revision + 1, grants=body.grants
            )
            if policy.grants and not self._matches(policy, connection):
                raise ApiError('invalid_request')
            # Explicit edits may retire only grants for deleted service metadata.
            live = {r[0] for r in c.execute('SELECT id FROM service_connections LIMIT 129')}
            if len(live) > 128:
                raise ApiError('server_unavailable', 503)
            state.policies = [p for p in state.policies if p.serviceId in live and p.serviceId != service_id] + [policy]
            self._event(c, state, actor, policy, uuid.uuid4().hex, 'policy_replaced')
            return self._response(state, policy)

    def check_component(self, actor, service_id, revision, component):
        if component not in {'home_assistant_probe', 'keenetic_command_worker'}:
            raise ApiError('outbound_denied', 403)
        with self._tx(actor) as (c, state):
            current = self._connection(c, service_id, revision)
            policy = self._policy(state, current)
            if policy.component != component or not self._matches(policy, current):
                raise ApiError('outbound_denied', 403)
            return policy

    def begin(self, actor, connection):
        denied = False
        with self._tx(actor) as (c, state):
            current = self._connection(c, connection.id, connection.revision)
            policy = self._policy(state, current)
            denied = current != connection or not self._matches(policy, current)
            correlation = uuid.uuid4().hex
            if denied:
                self._event(c, state, actor, policy, correlation, 'grant_missing')
        if denied:
            raise ApiError('outbound_denied', 403)
        return _Lease(self, actor, connection, policy, correlation)


class _Lease:
    def __init__(self, owner, actor, connection, policy, correlation):
        self.owner, self.actor, self.connection = owner, actor, connection
        self.policy, self.correlation = policy, correlation

    def _current(self, c, state):
        self.owner.services._assert_admin(c, self.actor)
        current = self.owner._connection(c, self.connection.id, self.connection.revision)
        if (current != self.connection or self.owner._policy(state, current) != self.policy or
                not self.owner._matches(self.policy, current)):
            raise ApiError('outbound_denied', 403)

    def check(self, address=None):
        with self.owner._tx(self.actor) as (c, state):
            self._current(c, state)
        if address is not None and address not in {p.address for p in self.policy.grants[0].addresses}:
            raise ApiError('outbound_denied', 403)

    def before_send(self):
        with self.owner._tx(self.actor) as (c, state):
            self._current(c, state)
            self.owner._event(c, state, self.actor, self.policy, self.correlation, 'dispatch_authorized')

    def complete(self, c):
        state = storage.load(c, self.owner.key, self.owner.scope)
        self._current(c, state)
        self.owner._event(c, state, self.actor, self.policy, self.correlation, 'probe_completed')

    def failed(self):
        # Already authenticated correlation only; no new authority after revocation.
        with self.owner._tx() as (c, state):
            self.owner._event(c, state, self.actor, self.policy, self.correlation, 'probe_unconfirmed')

    def transport(self, base_url, **limits):
        if base_url != self.connection.base_url:
            raise ApiError('outbound_denied', 403)
        self.check()
        return _Transport(base_url, self, **limits)


class _Transport(ServiceTransport):
    def __init__(self, base_url, lease, **limits):
        self._lease = lease
        super().__init__(base_url, address_guard=lease.check, **limits)

    def request(self, method, path, headers=None, body=None, **options):
        if method != 'GET' or path != '/api/config' or body is not None or options:
            raise ApiError('outbound_denied', 403)
        self._lease.check()
        try:
            result = super().request(method, path, headers, body, before_send=self._lease.before_send)
        except ProbeTransportError as error:
            if error.code == 'address_blocked':
                raise ApiError('outbound_denied', 403) from None
            raise
        self._lease.check()
        return result
