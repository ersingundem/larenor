"""Actual, privacy-scoped Frigate metadata/semantic search for normal Core.

Only explicit HA Frigate camera resources are mapped. Private provider IDs,
configuration and credentials never leave this adapter.
"""

from collections import OrderedDict
from contextlib import contextmanager
from contextvars import ContextVar
import hashlib
import hmac
from http.cookies import SimpleCookie
import json
import math
import re
import secrets
import threading
import time
from typing import Literal

from pydantic import Field, field_validator

from ..errors import ApiError, StartupError
from ..home_resources.models import FrozenModel, Identity
from ..home_assistant.read_only_websocket import HomeAssistantReadOnlyWebSocket, HomeAssistantWebSocketError
from ..services.transport import ServiceTransport, ProbeTransportError
from ..camera_profiles.ha_provider import _json
from .runtime import CameraSearchRuntime
from .private_event_binding import FrigatePrivateEventBindings
from .index import _terms, _term_matches
from .models import (CameraSearchAuthority, CameraSearchContextResponse,
                     CameraSearchPage, CameraSearchMatch, CameraEvidenceLink, safe_text)

_BUDGET = ContextVar('frigate_search_budget', default=None)
_CAMERA = re.compile(r'^[A-Za-z0-9_-]{1,80}$')
_EVENT = re.compile(r'^[A-Za-z0-9_.-]{1,128}$')
_JWT = re.compile(r'^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$')


class _ClipTransport(ServiceTransport):
    # Only instantiated below for the fixed, freshly authorized Frigate clip path.
    max_response_bytes = 64 * 1024 * 1024


class FrigateSearchBinding(FrozenModel):
    schemaVersion: Literal[1]
    expectedRevision: int = Field(ge=0, lt=2**63 - 1)
    serviceId: Identity
    expectedServiceRevision: int = Field(ge=1, lt=2**63 - 1)
    cameraResourceIds: list[Identity] = Field(min_length=1, max_length=16)

    @field_validator('cameraResourceIds')
    @classmethod
    def unique(cls, value):
        if len(set(value)) != len(value):
            raise ValueError('duplicate_camera')
        return value


class FrigateCameraSearchRuntime(FrigatePrivateEventBindings, CameraSearchRuntime):
    def __init__(self, ha, services, store, context, key, clock):
        self.ha, self.services, self.store = ha, services, store
        self.core_id, self.home_id = context.coreId, context.homeId
        self.clock = clock
        self.key = hmac.new(key, b'frigate-camera-search-v1', hashlib.sha256).digest()
        self._lock = threading.RLock()
        self._cursors = OrderedDict()
        self._evidence = OrderedDict()
        self._saved()  # Verify the encrypted source contract on restart.

    @contextmanager
    def _budget(self):
        previous = _BUDGET.get()
        token = _BUDGET.set(min(previous, time.monotonic() + 16) if previous else time.monotonic() + 16)
        try:
            yield
        finally:
            _BUDGET.reset(token)

    @staticmethod
    def _timeout():
        deadline = _BUDGET.get()
        remaining = 4 if deadline is None else deadline - time.monotonic()
        if remaining <= 0:
            raise ApiError('request_timeout', 408)
        return min(4, remaining)

    def _opaque(self, kind, value):
        return hmac.new(self.key, (kind + ':' + value).encode(), hashlib.sha256).hexdigest()[:32]

    def _saved(self):
        raw = self.store.get('search-configuration')
        if raw is None:
            return None
        try:
            if (set(raw) != {'revision', 'settings', 'bindings', 'mapping', 'provenance'}
                    or type(raw['revision']) is not int or not 1 <= raw['revision'] < 2**63 - 1):
                raise ValueError
            settings = FrigateSearchBinding.model_validate(raw['settings'])
            if (type(raw['bindings']) is not dict or type(raw['mapping']) is not dict
                    or set(raw['bindings']) != set(settings.cameraResourceIds)
                    or set(raw['mapping']) != set(settings.cameraResourceIds)
                    or any(not isinstance(value, str) or not _CAMERA.fullmatch(value)
                           for value in raw['mapping'].values())
                    or len(set(raw['mapping'].values())) != len(raw['mapping'])
                    or type(raw['provenance']) is not dict
                    or set(raw['provenance']) != set(settings.cameraResourceIds)):
                raise ValueError
            for rid, values in raw['bindings'].items():
                if (type(values) is not list or len(values) != 7
                        or any(type(values[i]) is not int or not 1 <= values[i] < 2**63 for i in (0, 1, 3, 6))
                        or any(not isinstance(values[i], str) or not re.fullmatch('[0-9a-f]{32}', values[i]) for i in (2, 5))
                        or not isinstance(values[4], str) or not re.fullmatch(r'camera\.[a-z0-9_]{1,128}', values[4])):
                    raise ValueError
                provenance = raw['provenance'][rid]
                if (type(provenance) is not list or len(provenance) != 3
                        or any(not isinstance(v, str) or not 1 <= len(v) <= 256 for v in provenance)
                        or provenance[2] != provenance[0] + ':camera:' + raw['mapping'][rid]):
                    raise ValueError
            return raw
        except (ValueError, TypeError):
            raise StartupError('camera_profile_storage_invalid') from None

    def _service(self, connection, service_id, revision):
        row, record = self.services._record(connection, service_id, revision)
        if (record['kind'] != 'frigate'
                or record['verification']['state'] not in {'reachable', 'authenticated'}
                or set(record['credentials']) not in (set(), {'token'}, {'username', 'password'})):
            raise ApiError('camera_search_source_unavailable', 503)
        return self.services._private(row, record)

    @staticmethod
    def _service_digest(service):
        return hashlib.sha256(json.dumps([service.id, service.revision, service.base_url,
            dict(service.credentials)], sort_keys=True).encode()).digest()

    def _resource(self, connection, facts, resource_id):
        fingerprint, row, _ref, binding, service = self.ha._facts(connection, facts, resource_id)
        if binding.entityId.split('.')[0] != 'camera':
            raise ApiError('camera_search_source_unavailable', 409)
        label = self.ha.resources._target(connection, resource_id)[2].label
        metadata = [row['revision'], row['acl_revision'], binding.id, binding.revision,
                    binding.entityId, service.id, service.revision]
        return metadata, fingerprint, binding, service, label

    def _registry(self, resources, guard):
        if len({item[3].id for item in resources.values()}) != 1:
            raise ApiError('revision_conflict', 409)
        try:
            with HomeAssistantReadOnlyWebSocket(next(iter(resources.values()))[3]).session(
                    timeout=self._timeout(), before_io=guard, after_io=guard) as session:
                registry = session.list_entity_registry()
        except HomeAssistantWebSocketError:
            raise ApiError('camera_search_source_unavailable', 503) from None
        result, provenance = {}, {}
        for rid, (_meta, _fingerprint, binding, _service, _label) in resources.items():
            matches = [row for row in registry if row.get('entity_id') == binding.entityId]
            if len(matches) != 1:
                raise ApiError('revision_conflict', 409)
            row = matches[0]
            entry, unique = row.get('config_entry_id'), row.get('unique_id')
            if (row.get('platform') != 'frigate' or row.get('disabled_by') is not None
                    or not isinstance(entry, str) or not entry or len(entry) > 128
                    or not isinstance(unique, str) or not unique.startswith(entry + ':camera:')
                    or not isinstance(row.get('device_id'), str) or not row['device_id']):
                raise ApiError('revision_conflict', 409)
            name = unique.removeprefix(entry + ':camera:')
            if not _CAMERA.fullmatch(name) or name == 'birdseye':
                raise ApiError('camera_search_source_unavailable', 409)
            result[rid] = name
            provenance[rid] = [entry, row['device_id'], unique]
        if len(set(result.values())) != len(result):
            raise ApiError('revision_conflict', 409)
        return result, provenance

    def _request(self, service, method, path, guard, *, token=None, query=None, body=None, max_bytes=2 * 1024 * 1024):
        guard()
        headers = {'Accept': 'application/json'}
        if token is not None:
            if not isinstance(token, str) or not 1 <= len(token) <= 4096 or any(ord(c) < 32 or ord(c) == 127 for c in token):
                raise ApiError('camera_search_source_unavailable', 503)
            headers['Authorization'] = 'Bearer ' + token
        if body is not None:
            headers['Content-Type'] = 'application/json'
        transport = None
        try:
            factory = _ClipTransport if path.endswith('/clip.mp4') and method == 'GET' else ServiceTransport
            transport = factory(service.base_url, timeout=self._timeout(), max_bytes=max_bytes)
            response = transport.request(method, path, headers=headers, query_parameters=query,
                body=None if body is None else json.dumps(body).encode(), before_send=guard)
            guard()
            if response.status != 200:
                raise ApiError('camera_search_source_unavailable', 503)
            return response
        except ProbeTransportError:
            raise ApiError('camera_search_source_unavailable', 503) from None
        finally:
            if transport is not None:
                transport.close()

    def _token(self, service, guard):
        if not service.credentials:
            return None
        if set(service.credentials) == {'token'}:
            return service.credentials['token']
        response = self._request(service, 'POST', '/api/login', guard,
            body={'user': service.credentials['username'], 'password': service.credentials['password']})
        tokens = []
        for name, value in response.headers:
            if name.lower() != 'set-cookie':
                continue
            cookie = SimpleCookie()
            try:
                cookie.load(value)
            except Exception:
                raise ApiError('camera_search_source_unavailable', 503) from None
            tokens.extend(item.value for item in cookie.values() if _JWT.fullmatch(item.value))
        if len(tokens) != 1 or len(tokens[0]) > 4096:
            raise ApiError('camera_search_source_unavailable', 503)
        return tokens[0]

    def _get(self, service, path, guard, token, query=None):
        response = self._request(service, 'GET', path, guard, token=token, query=query)
        if [v.split(';')[0].strip().lower() for k, v in response.headers if k.lower() == 'content-type'] != ['application/json']:
            raise ApiError('camera_search_source_unavailable', 503)
        return _json(response.body)

    def _provider(self, service, guard):
        token = self._token(service, guard)
        profile = self._get(service, '/api/profile', guard, token)
        config = self._get(service, '/api/config', guard, token)
        if (type(profile) is not dict or type(profile.get('allowed_cameras')) is not list
                or len(profile['allowed_cameras']) > 512
                or any(not isinstance(name, str) or not _CAMERA.fullmatch(name) for name in profile['allowed_cameras'])
                or type(config) is not dict or type(config.get('cameras')) is not dict
                or len(config['cameras']) > 512):
            raise ApiError('camera_search_source_unavailable', 503)
        names = set(profile['allowed_cameras']) & set(config['cameras'])
        semantic = config.get('semantic_search', {}).get('enabled') if type(config.get('semantic_search')) is dict else False
        if type(semantic) is not bool:
            raise ApiError('camera_search_source_unavailable', 503)
        return token, names, semantic

    def source_state(self, actor):
        self.ha.auth.rate_limit([('camera_search_configuration', actor.id, 30)])
        raw = self._saved()
        with self.ha._tx(actor, self.core_id, self.home_id, admin=True,
                         consume_rate_limit=False) as (connection, facts):
            rows = connection.execute('SELECT id FROM home_resource_records WHERE kind=\'resource\' LIMIT 513').fetchall()
            if len(rows) > 512:
                raise ApiError('camera_profile_audit_limit', 429)
            cameras = []
            for row in rows:
                try:
                    resource = self._resource(connection, facts, row['id'])
                    cameras.append({'id': row['id'], 'name': resource[4]})
                except ApiError as error:
                    if error.code not in {'not_found', 'ha_binding_changed', 'camera_search_source_unavailable'}:
                        raise
        public = self.services.list(actor)['services']
        services = [{'id': item['id'], 'revision': item['revision'], 'name': item['name']}
                    for item in public if item['kind'] == 'frigate'
                    and item['verification']['state'] in {'reachable', 'authenticated'}
                    and set(item['credentialKeys']) in (set(), {'token'}, {'username', 'password'})]
        return {'schemaVersion': 1, 'revision': 0 if raw is None else raw['revision'],
                'settings': None if raw is None else raw['settings'], 'services': services, 'cameras': cameras}

    def configure(self, actor, body):
        settings = FrigateSearchBinding.model_validate(body)
        with self._budget():
            with self.ha._tx(actor, self.core_id, self.home_id, admin=True,
                             consume_rate_limit=False) as (connection, _facts):
                service = self._service(connection, settings.serviceId, settings.expectedServiceRevision)
                resources = {rid: self._resource(connection, _facts, rid) for rid in settings.cameraResourceIds}
            def guard():
                with self.ha._tx(actor, self.core_id, self.home_id, admin=True,
                                 consume_rate_limit=False) as (connection, facts):
                    if self._service_digest(self._service(connection, service.id, service.revision)) != self._service_digest(service):
                        raise ApiError('revision_conflict', 409)
                    for rid, item in resources.items():
                        if self.ha._facts(connection, facts, rid)[0] != item[1]:
                            raise ApiError('revision_conflict', 409)
            mapping, provenance = self._registry(resources, guard)
            if len(','.join(mapping.values())) > 256:
                raise ApiError('invalid_request', 400)
            _token, names, _semantic = self._provider(service, guard)
            if not set(mapping.values()) <= names:
                raise ApiError('revision_conflict', 409)
            with self.ha._tx(actor, self.core_id, self.home_id, admin=True,
                             consume_rate_limit=False) as (connection, facts):
                if self._service_digest(self._service(connection, service.id, service.revision)) != self._service_digest(service):
                    raise ApiError('revision_conflict', 409)
                for rid, item in resources.items():
                    if self.ha._facts(connection, facts, rid)[0] != item[1]:
                        raise ApiError('revision_conflict', 409)
                old = self.store.get('search-configuration', connection)
                revision = 0 if old is None else old['revision']
                if revision != settings.expectedRevision:
                    raise ApiError('revision_conflict', 409)
                self.store.put('search-configuration', {'revision': revision + 1,
                    'settings': settings.model_dump(mode='json'),
                    'bindings': {rid: item[0] for rid, item in resources.items()},
                    'mapping': mapping, 'provenance': provenance}, connection=connection)
            with self._lock:
                self._cursors.clear()
                self._evidence.clear()
            return self.source_state(actor)

    def _live(self, actor, core_id, home_id):
        if (core_id, home_id) != (self.core_id, self.home_id):
            raise ApiError('not_found', 404)
        raw = self._saved()
        if raw is None:
            raise ApiError('camera_search_not_configured', 503)
        settings = FrigateSearchBinding.model_validate(raw['settings'])
        resources = {}
        with self.ha._tx(actor, core_id, home_id, consume_rate_limit=False) as (connection, facts):
            service = self._service(connection, settings.serviceId, settings.expectedServiceRevision)
            for rid in settings.cameraResourceIds:
                try:
                    item = self._resource(connection, facts, rid)
                except ApiError as error:
                    if error.code == 'not_found':
                        continue  # No existence oracle for inaccessible cameras.
                    raise
                if item[0] != raw['bindings'][rid]:
                    raise ApiError('revision_conflict', 409)
                resources[rid] = item
            if not resources:
                raise ApiError('forbidden', 403)
            home_revision = self.ha.resources._state(connection)['revision']
            authority = CameraSearchAuthority(schemaVersion=1, coreId=core_id, homeId=home_id,
                homeRevision=home_revision, accountId=actor.id, accountRevision=facts.revision,
                memberRevision=home_revision, sessionFamilyId=actor.family_id, role=facts.role,
                accessibleCameraIds=sorted(resources), allowPrivateEvidence=facts.role == 'admin',
                active=True, canSearch=True)
        return raw, service, resources, authority

    def _prepare(self, actor, core_id, home_id):
        raw, service, resources, authority = self._live(actor, core_id, home_id)
        def guard():
            fresh, current, latest, current_authority = self._live(actor, core_id, home_id)
            if (fresh != raw or current_authority != authority
                    or self._service_digest(current) != self._service_digest(service)
                    or {rid: item[1] for rid, item in latest.items()} != {rid: item[1] for rid, item in resources.items()}):
                raise ApiError('revision_conflict', 409)
        mapping, provenance = self._registry(resources, guard)
        if any(mapping[rid] != raw['mapping'][rid] or provenance[rid] != raw['provenance'][rid] for rid in mapping):
            raise ApiError('revision_conflict', 409)
        token, names, semantic = self._provider(service, guard)
        if not set(mapping.values()) <= names:
            raise ApiError('revision_conflict', 409)
        return raw, service, authority, mapping, token, semantic, guard

    def context(self, core, actor, core_id, home_id):
        core.auth.rate_limit([('camera_search_read', actor.id, 120)])
        with self._budget():
            raw, _service, authority, _mapping, _token, _semantic, guard = self._prepare(actor, core_id, home_id)
            guard()
            return CameraSearchContextResponse(schemaVersion=1, coreId=core_id, homeId=home_id,
                indexRevision=raw['revision'], cameraIds=authority.accessibleCameraIds, maxWindowDays=31)

    def _matches(self, data, mapping, authority, revision, request, semantic, service):
        if type(data) is not list or len(data) > 1000:
            raise ApiError('camera_search_source_unavailable', 503)
        inverse = {value: rid for rid, value in mapping.items() if rid in request.cameraIds}
        matches, lookups, seen = [], {}, set()
        terms = _terms(request.query)
        for item in data:
            if type(item) is not dict or not isinstance(item.get('id'), str) or not _EVENT.fullmatch(item['id']):
                raise ApiError('camera_search_source_unavailable', 503)
            native = item['id']
            if native in seen:
                raise ApiError('camera_search_source_unavailable', 503)
            seen.add(native)
            camera = item.get('camera')
            if camera not in inverse:
                raise ApiError('revision_conflict', 409)
            start, end = item.get('start_time'), item.get('end_time')
            if end is None:
                continue  # In-progress events do not have complete clip evidence.
            if (type(start) not in (int, float) or type(end) not in (int, float)
                    or not math.isfinite(start) or not math.isfinite(end) or not 0 <= start < end
                    or end - start > 86400 or item.get('has_clip') is not True):
                raise ApiError('camera_search_source_unavailable', 503)
            start_ms, end_ms = int(start * 1000), int(end * 1000)
            if not request.startMs <= start_ms < request.endMs:
                raise ApiError('revision_conflict', 409)
            label, detail = item.get('label'), item.get('data')
            if not isinstance(label, str) or not label or len(label) > 120 or type(detail) is not dict:
                raise ApiError('camera_search_source_unavailable', 503)
            description = detail.get('description')
            if description is not None and (not isinstance(description, str) or len(description) > 8192):
                raise ApiError('camera_search_source_unavailable', 503)
            try:
                summary = safe_text(' '.join((description or label).split())[:240])
            except ValueError:
                raise ApiError('camera_search_source_unavailable', 503) from None
            metadata = _terms(label + ' ' + summary)
            matched = [term for term in terms if any(_term_matches(term, word) for word in metadata)]
            if not semantic and not matched:
                continue
            event = self._opaque('event', service.id + ':' + native)
            clip = self._opaque('clip', service.id + ':' + native)
            canonical = [camera, native, start_ms, end_ms, label, description, item['has_clip']]
            capture_revision = int(hashlib.sha256(json.dumps(canonical, ensure_ascii=False).encode()).hexdigest()[:13], 16) + 1
            evidence = CameraEvidenceLink(schemaVersion=1, kind='camera_evidence', coreId=authority.coreId,
                homeId=authority.homeId, cameraId=inverse[camera], clipId=clip, eventId=event,
                captureRevision=capture_revision, indexRevision=revision, capturedAtMs=start_ms)
            matches.append(CameraSearchMatch(schemaVersion=1, startMs=start_ms, endMs=end_ms,
                summary=summary, matchedTerms=(matched or [request.query])[:16], evidence=evidence))
            lookups[event] = (native, evidence)
        return matches, lookups

    def search(self, core, actor, core_id, home_id, request):
        core.auth.rate_limit([('camera_search_read', actor.id, 120)])
        with self._budget():
            raw, service, authority, mapping, token, semantic, guard = self._prepare(actor, core_id, home_id)
            if request.expectedIndexRevision != raw['revision'] or not set(request.cameraIds) <= set(mapping):
                raise ApiError('revision_conflict', 409)
            selected = ','.join(sorted(mapping[rid] for rid in request.cameraIds))
            if len(selected) > 256:
                raise ApiError('invalid_request', 400)
            query = {'cameras': selected, 'after': str(request.startMs / 1000 - .001),
                'before': str(request.endMs / 1000), 'has_clip': 'true' if semantic else '1',
                'include_thumbnails': '0', 'limit': '1001', 'sort': 'relevance' if semantic else 'date_desc'}
            if semantic:
                query.update({'query': request.query, 'search_type': 'thumbnail,description'})
            else:
                query['in_progress'] = '0'
            data = self._get(service, '/api/events/search' if semantic else '/api/events', guard, token, query)
            matches, lookups = self._matches(data, mapping, authority, raw['revision'], request, semantic, service)
            guard()
            signature = hashlib.sha256(json.dumps([authority.model_dump(mode='json'),
                request.model_dump(mode='json', exclude={'cursor'}),
                [value.model_dump(mode='json') for value in matches]], sort_keys=True).encode()).hexdigest()
            offset = 0
            with self._lock:
                if request.cursor is not None:
                    saved = self._cursors.get(request.cursor)
                    if saved is None or saved[0] != signature or saved[2] < self.clock():
                        raise ApiError('revision_conflict', 409)
                    offset = saved[1]
                next_cursor = None
                if offset + request.pageSize < len(matches):
                    nonce = secrets.token_urlsafe(24)
                    next_cursor = nonce + '.' + hmac.new(self.key, nonce.encode(), hashlib.sha256).hexdigest()
                    self._cursors[next_cursor] = (signature, offset + request.pageSize, self.clock() + 120)
                    while len(self._cursors) > 256:
                        self._cursors.popitem(last=False)
                for event, value in lookups.items():
                    self._evidence[(actor.id, actor.family_id, event)] = (service.id, raw['revision'], *value, self.clock() + 120, request.query)
                while len(self._evidence) > 2048:
                    self._evidence.popitem(last=False)
            page = matches[offset:offset + request.pageSize]
            filtered = core.camera_search_feedback.filter_reported(actor, request.query, page)
            guard()
            return CameraSearchPage(schemaVersion=1, indexRevision=raw['revision'],
                mode='semantic_assisted' if semantic else 'local_metadata', status='ready' if semantic else 'degraded',
                degradedReason=None if semantic else 'semantic_provider_unavailable',
                results=filtered, nextCursor=next_cursor)

    def feedback(self, core, actor, core_id, home_id, body):
        core.auth.rate_limit([('camera_search_feedback', actor.id, 120)])
        with self._budget():
            raw, service, authority, _mapping, token, _semantic, guard = self._prepare(actor, core_id, home_id)
            with self._lock:
                saved = self._evidence.get((actor.id, actor.family_id, body.evidence.eventId))
            if (saved is None or saved[0] != service.id or saved[1] != raw['revision']
                    or saved[3] != body.evidence or saved[4] < self.clock() or saved[5] != body.query
                    or body.expectedIndexRevision != raw['revision']
                    or body.evidence.cameraId not in authority.accessibleCameraIds):
                raise ApiError('revision_conflict', 409)
            data = self._get(service, '/api/events/' + saved[2], guard, token)
            if (type(data) is not dict or data.get('id') != saved[2]
                    or data.get('has_clip') is not True):
                raise ApiError('revision_conflict', 409)
            # Re-read the exact event rather than trusting an old search result.
            from .models import CameraSearchRequest
            check = CameraSearchRequest(schemaVersion=1, query=body.query,
                expectedIndexRevision=raw['revision'], startMs=body.evidence.capturedAtMs,
                endMs=body.evidence.capturedAtMs + 86400000, cameraIds=[body.evidence.cameraId], pageSize=1)
            verified, _lookups = self._matches([data], _mapping, authority, raw['revision'], check, True, service)
            if len(verified) != 1 or verified[0].evidence != body.evidence:
                raise ApiError('revision_conflict', 409)
            guard()
            result = core.camera_search_feedback.record(actor, body)
            guard()
            return result

    def clip(self, core, actor, core_id, home_id, evidence):
        """Read only the exact recently searched event, with fresh authority."""
        core.auth.rate_limit([('camera_search_clip', actor.id, 30)])
        with self._budget():
            raw, service, authority, mapping, token, _, guard = self._prepare(actor, core_id, home_id)
            with self._lock:
                saved = self._evidence.get((actor.id, actor.family_id, evidence.eventId))
            if (saved is None or saved[0] != service.id or saved[1] != raw['revision']
                    or saved[3] != evidence or saved[4] < self.clock()
                    or evidence.cameraId not in authority.accessibleCameraIds):
                raise ApiError('revision_conflict', 409)
            from .models import CameraSearchRequest
            request = CameraSearchRequest(schemaVersion=1, query=saved[5],
                expectedIndexRevision=raw['revision'], startMs=evidence.capturedAtMs,
                endMs=evidence.capturedAtMs + 86400000, cameraIds=[evidence.cameraId], pageSize=1)
            def verify_event():
                current = self._get(service, '/api/events/' + saved[2], guard, token)
                if type(current) is not dict or current.get('id') != saved[2]:
                    raise ApiError('revision_conflict', 409)
                matches, _ = self._matches([current], mapping, authority, raw['revision'], request, True, service)
                if len(matches) != 1 or matches[0].evidence != evidence:
                    raise ApiError('revision_conflict', 409)
            verify_event()
            response = self._request(service, 'GET', '/api/events/' + saved[2] + '/clip.mp4',
                guard, token=token, max_bytes=64 * 1024 * 1024)
            headers = {name.lower(): value for name, value in response.headers}
            if (headers.get('content-type', '').split(';')[0].strip().lower() != 'video/mp4'
                    or len(response.body) < 24 or response.body[4:8] != b'ftyp'
                    or not 16 <= int.from_bytes(response.body[:4], 'big') <= len(response.body)):
                raise ApiError('camera_search_source_unavailable', 503)
            # Metadata and provider permissions can change while Frigate builds the clip.
            fresh, fresh_service, fresh_authority, fresh_mapping, _, _, fresh_guard = self._prepare(actor, core_id, home_id)
            if (fresh['revision'] != raw['revision'] or fresh_authority != authority
                    or fresh_mapping != mapping or self._service_digest(fresh_service) != self._service_digest(service)):
                raise ApiError('revision_conflict', 409)
            verify_event()
            fresh_guard()
            return response.body
