"""Actual private Home Assistant switch read/action camera composition.

The administrator explicitly pairs recording/detection switch resources. The
adapter never infers hardware microphone privacy or assigns arbitrary entities.
"""

import hashlib
import json
import threading
import time
from contextlib import contextmanager
from contextvars import ContextVar
from functools import wraps

from ..errors import ApiError, StartupError
from ..services.transport import ServiceTransport, ProbeTransportError
from ..vault import validate_json_bounds
from ..home_assistant.read_only_websocket import (
    HomeAssistantReadOnlyWebSocket, HomeAssistantWebSocketError)
from .models import (CameraMode, CameraProfileAuthority, CameraProfilePolicy,
                     CameraProviderSupport, CameraReadback, CameraScope,
                     CameraWorkerCommand, PresenceSignal, WorkerReadback)
from .source_models import CameraSourceSettings, CameraSourceReconcile
from .source_store import CameraProviderStore

_DEADLINE = ContextVar('camera_provider_deadline', default=None)
_ACTOR = ContextVar('camera_provider_actor', default=None)


def bounded(operation):
    @wraps(operation)
    def call(self, *args, **kwargs):
        with self.operation_budget():
            return operation(self, *args, **kwargs)
    return call


def _identity(value):
    return hashlib.sha256(value.encode()).hexdigest()[:32]


def _json(raw):
    def pairs(values):
        result = {}
        for key, value in values:
            if key in result:
                raise ValueError
            result[key] = value
        return result
    try:
        value = json.loads(raw, object_pairs_hook=pairs,
                           parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        validate_json_bounds(value)
        return value
    except (ValueError, TypeError, UnicodeError, RecursionError, ApiError):
        raise ApiError('camera_profile_provider_unavailable', 503) from None


class HomeAssistantCameraProvider:
    fresh_observation_times = True
    def __init__(self, ha, database, key, context, clock, *, transport_factory=ServiceTransport,
                 websocket_factory=HomeAssistantReadOnlyWebSocket):
        self.ha, self.db = ha, database
        self.core_id, self.home_id = context.coreId, context.homeId
        self._clock, self._transport = clock, transport_factory
        self._websocket = websocket_factory
        self.store = CameraProviderStore(database, key, self.core_id, self.home_id)
        self.store.validate_storage()
        self._dispatch_lock = threading.Lock()
        self.profile_id = _identity(f'camera-profile:{self.core_id}:{self.home_id}')

    @contextmanager
    def operation_budget(self):
        existing = _DEADLINE.get()
        deadline = time.monotonic() + 16
        token = _DEADLINE.set(deadline if existing is None else min(existing, deadline))
        try:
            yield
        finally:
            _DEADLINE.reset(token)

    @contextmanager
    def request_context(self, actor):
        token = _ACTOR.set(actor)
        try:
            with self.operation_budget():
                yield
        finally:
            _ACTOR.reset(token)

    @staticmethod
    def _remaining():
        deadline = _DEADLINE.get()
        remaining = 4 if deadline is None else deadline - time.monotonic()
        if remaining <= 0:
            raise ApiError('request_timeout', 408)
        return min(4, remaining)

    def _actor_facts(self, actor):
        with self.ha._tx(actor, self.core_id, self.home_id, admin=True,
                         consume_rate_limit=False) as (connection, facts):
            home_revision = self.ha.resources._state(connection)['revision']
        return CameraProfileAuthority(schemaVersion=1, coreId=self.core_id,
            homeId=self.home_id, homeRevision=home_revision, accountId=actor.id,
            accountRevision=facts.revision, sessionFamilyId=actor.family_id,
            role=facts.role, active=True, canManageCameraProfiles=True)

    def authority(self, account_id):
        actor = _ACTOR.get()
        return None if actor is None or actor.id != account_id else self._actor_facts(actor)

    def _resolve(self, actor, resource_id, domain=None):
        with self.ha._tx(actor, self.core_id, self.home_id, admin=True,
                         consume_rate_limit=False) as (connection, facts):
            fingerprint, row, ref, binding, service = self.ha._facts(connection, facts, resource_id)
            self.ha.resources._require(facts, row, ref, self.ha.resources._target(connection, resource_id)[2], action='write' if domain == 'switch' else 'read')
            label = self.ha.resources._target(connection, resource_id)[2].label
            if domain is not None and binding.entityId.split('.')[0] != domain:
                raise ApiError('camera_profile_provider_unavailable', 409)
            metadata = [resource_id, row['revision'], row['acl_revision'],
                        binding.id, binding.revision, service.id, service.revision]
        return metadata, fingerprint, binding, service, label

    def _fresh(self, actor, resource_id, fingerprint):
        self.ha._fresh(actor, self.core_id, self.home_id, resource_id,
                       fingerprint, None, lambda: False, admin=True,
                       consume_rate_limit=False)

    def _request(self, connection, method, path, body=None, guard=None):
        token = connection.credentials.get('token')
        if (not isinstance(token, str) or not token
                or any(ord(c) < 32 or ord(c) == 127 for c in token)):
            raise ApiError('camera_profile_provider_unavailable', 503)
        headers = {'Authorization': 'Bearer ' + token, 'Accept': 'application/json'}
        if body is not None:
            headers['Content-Type'] = 'application/json'
        transport = None
        try:
            transport = self._transport(connection.base_url, timeout=self._remaining(), max_bytes=65536)
            response = transport.request(method, path, headers=headers,
                body=None if body is None else json.dumps(body, separators=(',', ':')).encode(),
                before_send=guard)
            if response.status != 200:
                raise ApiError('camera_profile_provider_unavailable', 503)
            if [value.split(';')[0].strip().lower() for name, value in response.headers
                    if name.lower() == 'content-type'] != ['application/json']:
                raise ApiError('camera_profile_provider_unavailable', 503)
            return _json(response.body)
        except ProbeTransportError:
            raise ApiError('camera_profile_provider_unavailable', 503) from None
        finally:
            if transport is not None:
                transport.close()

    def _read(self, actor, resource_id, resolved):
        metadata, fingerprint, binding, service, _label = resolved
        self._fresh(actor, resource_id, fingerprint)
        value = self._request(service, 'GET', '/api/states/' + binding.entityId,
                              guard=lambda: self._fresh(actor, resource_id, fingerprint))
        self._fresh(actor, resource_id, fingerprint)
        if (type(value) is not dict or value.get('entity_id') != binding.entityId
                or type(value.get('state')) is not str or len(value['state']) > 255
                or type(value.get('attributes')) is not dict
                or type(value.get('last_updated')) is not str
                or type(value.get('context')) is not dict
                or any(ord(c) < 32 or ord(c) == 127 for c in value['state'])):
            raise ApiError('camera_profile_provider_unavailable', 503)
        return value

    def source_state(self, actor):
        self._actor_facts(actor)
        saved = self.store.get('configuration')
        with self.ha._tx(actor, self.core_id, self.home_id, admin=True,
                         consume_rate_limit=False) as (connection, _facts):
            rows = connection.execute('SELECT id,kind FROM home_resource_records ORDER BY id LIMIT 513').fetchall()
            if len(rows) > 512:
                raise ApiError('camera_profile_audit_limit', 429)
            areas = [{'id': row['id'], 'name': self.ha.resources._target(connection, row['id'])[2].label}
                     for row in rows if row['kind'] == 'room']
        resources = []
        for row in rows:
            if row['kind'] != 'resource':
                continue
            try:
                resolved = self._resolve(actor, row['id'])
            except ApiError as error:
                if error.code in {'not_found', 'ha_binding_changed'}:
                    continue
                raise
            domain = resolved[2].entityId.split('.')[0]
            if domain in {'switch', 'person', 'device_tracker', 'binary_sensor'}:
                resources.append({'id': row['id'], 'name': resolved[4], 'domain': domain})
        return {'schemaVersion': 1, 'revision': 0 if saved is None else saved['revision'],
                'settings': None if saved is None else saved['settings'],
                'resources': resources, 'areas': areas}

    def _pending(self):
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            self.store._verify(connection)
            rows = connection.execute("SELECT * FROM camera_provider_records WHERE id LIKE 'command:%' ORDER BY id").fetchall()
            pending = []
            for row in rows:
                record = self.store._decode(row)
                if record.get('result') is None and record.get('resolved') is not True:
                    pending.append((row['id'].removeprefix('command:'), record))
            return pending

    @bounded
    def recoveries(self, actor):
        self._actor_facts(actor)
        pending = self._pending()
        if not pending:
            return []
        policy, settings, resolved = self._policy(actor)
        results = []
        for command_id, saved in pending:
            index = next((i for i, camera in enumerate(policy.cameras)
                          if camera.cameraId == saved['cameraId']), None)
            if index is None:
                continue
            scope = policy.cameras[index]
            observed = self._camera_readback(actor, settings.cameras[index], scope,
                                            *resolved[1 + index * 2:3 + index * 2])
            results.append({'schemaVersion': 1, 'commandId': command_id,
                'label': resolved[1 + index * 2][4],
                'cameraId': scope.cameraId, 'expectedSourceRevision': policy.profileRevision,
                'expectedStateRevision': observed.stateRevision, 'mode': observed.mode.model_dump(mode='json')})
        return results

    @bounded
    def reconcile(self, actor, raw):
        request = CameraSourceReconcile.model_validate(raw)
        if not self._dispatch_lock.acquire(blocking=False):
            raise ApiError('revision_conflict', 409)
        try:
            authority = self._actor_facts(actor)
            policy, settings, resolved = self._policy(actor)
            if policy.profileRevision != request.expectedSourceRevision:
                raise ApiError('revision_conflict', 409)
            index = next((i for i, camera in enumerate(policy.cameras)
                          if camera.cameraId == request.cameraId), None)
            if index is None:
                raise ApiError('revision_conflict', 409)
            key = 'command:' + request.commandId
            saved = self.store.get(key)
            if saved is None or saved.get('cameraId') != request.cameraId or saved.get('result') is not None:
                raise ApiError('revision_conflict', 409)
            scope, pair = policy.cameras[index], settings.cameras[index]
            first, second = resolved[1 + index * 2:3 + index * 2]
            before = self._camera_readback(actor, pair, scope, first, second)
            after = self._camera_readback(actor, pair, scope, first, second)
            if (before.stateRevision != request.expectedStateRevision
                    or after.stateRevision != before.stateRevision
                    or before.mode != request.mode or after.mode != request.mode
                    or self._actor_facts(actor) != authority or self._policy(actor)[0] != policy):
                raise ApiError('revision_conflict', 409)
            with self.ha._tx(actor, self.core_id, self.home_id, admin=True,
                             consume_rate_limit=False) as (connection, facts):
                configuration = self.store.get('configuration', connection)
                if (self.store.get(key, connection) != saved
                        or configuration is None
                        or configuration['revision'] != policy.profileRevision
                        or facts.revision != authority.accountRevision
                        or facts.role != authority.role
                        or self.ha.resources._state(connection)['revision'] != authority.homeRevision):
                    raise ApiError('revision_conflict', 409)
                for metadata, fingerprint, _binding, _service, _label in resolved:
                    current = self.ha._facts(connection, facts, metadata[0])[0]
                    if current != fingerprint:
                        raise ApiError('revision_conflict', 409)
                self.store.put(key, {**saved, 'resolved': True,
                    'reconciled': after.model_dump(mode='json')}, connection=connection)
            # The old command remains unknown and can never be resent. Only
            # this separately confirmed, read-only current-state boundary clears
            # the interlock for a future explicit action.
            return {'schemaVersion': 1, 'commandId': request.commandId,
                    'status': 'current_state_confirmed'}
        finally:
            self._dispatch_lock.release()

    def _settings(self):
        saved = self.store.get('configuration')
        if saved is None:
            raise ApiError('camera_profile_provider_unavailable', 503)
        try:
            if (set(saved) != {'revision', 'settings', 'bindings', 'provenance'}
                    or type(saved['revision']) is not int or not 1 <= saved['revision'] < 2**63 - 1):
                raise ValueError
            return saved, CameraSourceSettings.model_validate(saved['settings'])
        except (ValueError, TypeError):
            raise StartupError('camera_profile_storage_invalid') from None

    def _provenance(self, actor, settings, resolved):
        def guard():
            self._remaining()
            for item in resolved:
                self._fresh(actor, item[0][0], item[1])
        try:
            with self._websocket(resolved[0][3]).session(
                    timeout=self._remaining(), before_io=guard, after_io=guard) as session:
                entries = session.list_entity_registry()
        except HomeAssistantWebSocketError:
            raise ApiError('camera_profile_provider_unavailable', 503) from None
        selected = {item[2].entityId for item in resolved[1:]}
        found = {}
        for entry in entries:
            entity = entry.get('entity_id')
            if entity not in selected:
                continue
            if (entity in found or entry.get('platform') != 'frigate'
                    or entry.get('disabled_by') is not None
                    or any(not isinstance(entry.get(key), str) or not 1 <= len(entry[key]) <= 255
                           or any(ord(c) < 32 or ord(c) == 127 for c in entry[key])
                           for key in ['config_entry_id', 'device_id', 'unique_id'])):
                raise ApiError('camera_profile_provider_unavailable', 409)
            found[entity] = {key: entry[key] for key in ['config_entry_id', 'device_id', 'unique_id']}
        if set(found) != selected:
            raise ApiError('camera_profile_provider_unavailable', 409)
        provenance = []
        for index, _pair in enumerate(settings.cameras):
            first, second = resolved[1 + index * 2:3 + index * 2]
            recording, detection = found[first[2].entityId], found[second[2].entityId]
            prefix = recording['config_entry_id'] + ':switch:'
            record_id, detect_id = recording['unique_id'], detection['unique_id']
            if (recording['device_id'] != detection['device_id']
                    or recording['config_entry_id'] != detection['config_entry_id']
                    or not record_id.startswith(prefix) or not record_id.endswith('_recordings')
                    or not detect_id.startswith(prefix) or not detect_id.endswith('_detect')
                    or record_id.removesuffix('_recordings') != detect_id.removesuffix('_detect')
                    or len(record_id.removesuffix('_recordings')) <= len(prefix)):
                raise ApiError('camera_profile_provider_unavailable', 409)
            provenance.append(hashlib.sha256(json.dumps([recording, detection], sort_keys=True).encode()).hexdigest())
        return provenance

    @bounded
    def configure(self, actor, raw):
        settings = CameraSourceSettings.model_validate(raw)
        self._actor_facts(actor)
        ids = [settings.presenceResourceId] + [rid for pair in settings.cameras
                for rid in (pair.recordingResourceId, pair.detectionResourceId)]
        resolved = [self._resolve(actor, rid, None if index == 0 else 'switch') for index, rid in enumerate(ids)]
        if len({item[3].id for item in resolved}) != 1:
            raise ApiError('revision_conflict', 409)
        provenance = self._provenance(actor, settings, resolved)
        for rid, item in zip(ids, resolved):
            state = self._read(actor, rid, item)
            if rid != settings.presenceResourceId and state['state'] not in {'on', 'off'}:
                raise ApiError('camera_profile_provider_unavailable', 409)
        self._presence_state(resolved[0][2], self._read(actor, ids[0], resolved[0]))
        with self.ha._tx(actor, self.core_id, self.home_id, admin=True,
                         consume_rate_limit=False) as (connection, _facts):
            for pair in settings.cameras:
                self.ha.resources.validate_reference(connection, pair.areaId, 'room', missing='not_found')
            for rid, item in zip(ids, resolved):
                if self.ha._facts(connection, _facts, rid)[0] != item[1]:
                    raise ApiError('revision_conflict', 409)
            previous = self.store.get('configuration', connection)
            revision = 0 if previous is None else previous['revision']
            if settings.expectedRevision != revision:
                raise ApiError('revision_conflict', 409)
            self.store.put('configuration', {'revision': revision + 1,
                'settings': settings.model_dump(mode='json'),
                'bindings': [item[0] for item in resolved], 'provenance': provenance}, connection=connection)
        return self.source_state(actor)

    @staticmethod
    def _presence_state(binding, value):
        domain = binding.entityId.split('.')[0]
        state = value['state']
        if state in {'unavailable', 'unknown'}:
            return 'unknown'
        if domain in {'person', 'device_tracker'}:
            return 'home' if state == 'home' else 'away'
        if (domain == 'binary_sensor' and value['attributes'].get('device_class') in {'occupancy', 'presence'}
                and state in {'on', 'off'}):
            return 'home' if state == 'on' else 'away'
        raise ApiError('camera_profile_provider_unavailable', 409)

    def _policy(self, actor):
        saved, settings = self._settings()
        ids = [settings.presenceResourceId] + [rid for pair in settings.cameras
               for rid in (pair.recordingResourceId, pair.detectionResourceId)]
        resolved = [self._resolve(actor, rid, None if index == 0 else 'switch') for index, rid in enumerate(ids)]
        if [item[0] for item in resolved] != saved['bindings']:
            raise ApiError('revision_conflict', 409)
        if self._provenance(actor, settings, resolved) != saved['provenance']:
            raise ApiError('revision_conflict', 409)
        scopes = []
        with self.ha._tx(actor, self.core_id, self.home_id, admin=True,
                         consume_rate_limit=False) as (connection, _facts):
            for index, pair in enumerate(settings.cameras):
                area, _ref, _data = self.ha.resources._target(connection, pair.areaId)
                if area['kind'] != 'room':
                    raise ApiError('revision_conflict', 409)
                metadata = resolved[1 + index * 2][0]
                scopes.append(CameraScope(schemaVersion=1,
                    cameraId=_identity(pair.recordingResourceId + pair.detectionResourceId),
                    cameraRevision=saved['revision'], areaId=pair.areaId, areaRevision=area['revision'],
                    serviceId=metadata[5], serviceRevision=metadata[6],
                    bindingId=_identity(json.dumps([metadata, resolved[2 + index * 2][0]])),
                    bindingRevision=saved['revision']))
        policy = CameraProfilePolicy(schemaVersion=1, coreId=self.core_id, homeId=self.home_id,
            profileId=self.profile_id, profileRevision=saved['revision'],
            presenceSourceId=settings.presenceResourceId, presenceSourceRevision=saved['revision'],
            cameras=scopes, active=True, **settings.model_dump(exclude={
                'schemaVersion', 'expectedRevision', 'presenceResourceId', 'cameras'}))
        return policy, settings, resolved

    def policy_for(self, profile_id):
        if profile_id != self.profile_id:
            return None
        actor = _ACTOR.get()
        return None if actor is None else self._policy(actor)[0]

    @staticmethod
    def _state_fact(value):
        return [value['entity_id'], value['state'], value['last_updated'], value['context']]

    def _camera_readback(self, actor, pair, scope, first, second):
        values = [self._read(actor, rid, resolved) for rid, resolved in zip(
            (pair.recordingResourceId, pair.detectionResourceId), (first, second))]
        if any(value['state'] not in {'on', 'off'} for value in values):
            raise ApiError('camera_profile_provider_unavailable', 503)
        revision = self.store.observe(scope.cameraId, [self._state_fact(v) for v in values])
        return CameraReadback(schemaVersion=1, coreId=self.core_id, homeId=self.home_id,
            camera=scope, stateRevision=revision,
            mode=CameraMode(recording='enabled' if values[0]['state'] == 'on' else 'paused',
                            detection='enabled' if values[1]['state'] == 'on' else 'disabled'),
            observedAtMs=int(self._clock() * 1000))

    @bounded
    def snapshot(self, actor):
        authority = self._actor_facts(actor)
        policy, settings, resolved = self._policy(actor)
        presence = self._read(actor, settings.presenceResourceId, resolved[0])
        signal = PresenceSignal(schemaVersion=1, coreId=self.core_id, homeId=self.home_id,
            sourceId=settings.presenceResourceId, sourceRevision=policy.presenceSourceRevision,
            signalRevision=self.store.observe(settings.presenceResourceId, self._state_fact(presence)),
            observedAtMs=int(self._clock() * 1000), state=self._presence_state(resolved[0][2], presence))
        readbacks, support = [], []
        for index, (pair, scope) in enumerate(zip(settings.cameras, policy.cameras)):
            first, second = resolved[1 + index * 2:3 + index * 2]
            observed = self._camera_readback(actor, pair, scope, first, second)
            readbacks.append(observed)
            support.append(CameraProviderSupport(schemaVersion=1, camera=scope,
                displayName=first[4], providerRevision=policy.profileRevision,
                recordingSupported=True, detectionSupported=True, verifiedAtMs=observed.observedAtMs))
        if self._actor_facts(actor) != authority or self._policy(actor)[0] != policy:
            raise ApiError('revision_conflict', 409)
        return authority, policy, signal, readbacks, support

    @bounded
    def apply(self, raw):
        if not self._dispatch_lock.acquire(blocking=False):
            raise ApiError('revision_conflict', 409)
        try:
            return self._apply(raw)
        finally:
            self._dispatch_lock.release()

    def _apply(self, raw):
        command = CameraWorkerCommand.model_validate(raw)
        actor = _ACTOR.get()
        if actor is None or actor.id != command.actorAccountId:
            raise ApiError('forbidden', 403)
        authority = self._actor_facts(actor)
        policy, settings, resolved = self._policy(actor)
        if ((command.coreId, command.homeId, command.profileId, command.profileRevision)
                != (self.core_id, self.home_id, policy.profileId, policy.profileRevision)):
            raise ApiError('revision_conflict', 409)
        index = next((i for i, scope in enumerate(policy.cameras) if scope == command.camera), None)
        if index is None:
            raise ApiError('revision_conflict', 409)
        pair = settings.cameras[index]
        first, second = resolved[1 + index * 2:3 + index * 2]
        key = 'command:' + command.commandId
        digest = hashlib.sha256(command.model_dump_json().encode()).hexdigest()
        with self.db.transaction() as connection:
            existing = self.store.get(key, connection)
            if existing is not None:
                if existing.get('digest') != digest:
                    raise ApiError('idempotency_conflict', 409)
                if existing.get('result') is not None:
                    return WorkerReadback.model_validate(existing['result'])
                raise ApiError('camera_profile_provider_unavailable', 503)
            rows = connection.execute("SELECT * FROM camera_provider_records WHERE id LIKE 'command:%'").fetchall()
            if any((record := self.store._decode(row)).get('cameraId') == command.camera.cameraId
                   and record.get('result') is None and record.get('resolved') is not True for row in rows):
                raise ApiError('camera_profile_provider_unavailable', 503)
            self.store.put(key, {'digest': digest, 'cameraId': command.camera.cameraId,
                'result': None}, connection=connection, create_only=True)
        # Any process failure after reservation stays unresolved and can never
        # replay this command. A partial pair is surfaced by the coordinator.
        before = self._camera_readback(actor, pair, command.camera, first, second)
        if before.stateRevision != command.expectedStateRevision:
            raise ApiError('revision_conflict', 409)
        for rid, item, desired in zip((pair.recordingResourceId, pair.detectionResourceId),
                (first, second), (command.desiredMode.recording == 'enabled', command.desiredMode.detection == 'enabled')):
            state = self._read(actor, rid, item)
            target = 'on' if desired else 'off'
            if state['state'] == target:
                continue
            if self._actor_facts(actor) != authority or self._policy(actor)[0] != policy:
                raise ApiError('revision_conflict', 409)
            self._fresh(actor, rid, item[1])
            def guard():
                self._remaining()
                self._fresh(actor, rid, item[1])
                if self._actor_facts(actor) != authority or self._policy(actor)[0] != policy:
                    raise ApiError('revision_conflict', 409)
            response = self._request(item[3], 'POST', '/api/services/switch/turn_' + target,
                                     {'entity_id': item[2].entityId}, guard=guard)
            if type(response) is not list:
                raise ApiError('camera_profile_provider_unavailable', 503)
            # Frigate's HA switch updates from its MQTT state response, not
            # optimistically from the service invocation. Read that state.
            poll_deadline = min(time.monotonic() + 4, _DEADLINE.get())
            while True:
                after = self._read(actor, rid, item)
                if after['state'] == target and self._state_fact(after) != self._state_fact(state):
                    break
                remaining = poll_deadline - time.monotonic()
                if remaining <= 0:
                    raise ApiError('camera_profile_provider_unavailable', 503)
                time.sleep(min(.15, remaining))
        observed = self._camera_readback(actor, pair, command.camera, first, second)
        if (observed.mode != command.desiredMode or observed.stateRevision <= before.stateRevision
                or self._actor_facts(actor) != authority or self._policy(actor)[0] != policy):
            raise ApiError('revision_conflict', 409)
        result = WorkerReadback(schemaVersion=1, commandId=command.commandId,
            camera=observed.camera, stateRevision=observed.stateRevision,
            mode=observed.mode, observedAtMs=observed.observedAtMs)
        self.store.put(key, {'digest': digest, 'cameraId': command.camera.cameraId,
                            'result': result.model_dump(mode='json')})
        return result
