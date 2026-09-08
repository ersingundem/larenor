"""One selected-state GET through the existing bounded, no-proxy transport.

Only the closed state projection leaves this module. Upstream attributes,
headers, exceptions and bodies never become API errors, previews or cache data.
"""
import json
import re

from ..errors import ApiError
from ..services.transport import ServiceTransport, ProbeTransportError
from ..vault import validate_json_bounds
from .models import Projection


MAX_BYTES = 65536
TIMEOUT = 3.0


def _unique(pairs):
    value = {}
    for key, child in pairs:
        if key in value:
            raise ValueError()
        value[key] = child
    return value


def read_switch(service, entity_id, *, guard):
    if not re.fullmatch(r'switch\.[a-z0-9_]{1,121}', entity_id):
        raise ApiError('invalid_request')
    guard()
    try:
        with ServiceTransport(service.base_url, timeout=TIMEOUT, max_bytes=MAX_BYTES) as transport:
            response = transport.request('GET', '/api/states/' + entity_id,
                headers={'Authorization': 'Bearer ' + service.credentials['token'], 'Accept': 'application/json'},
                before_send=guard)
    except (ProbeTransportError, KeyError):
        guard()
        raise ApiError('ha_upstream_unavailable', 502) from None
    guard()
    if response.status == 401:
        raise ApiError('ha_upstream_unauthorized', 502)
    if response.status != 200:
        raise ApiError('ha_upstream_unavailable', 502)
    try:
        types = [v.split(';', 1)[0].strip().lower() for k, v in response.headers if k == 'content-type']
        if types != ['application/json'] or any(k in ('content-range', 'link') for k, _ in response.headers):
            raise ValueError()
        data = json.loads(response.body, object_pairs_hook=_unique,
            parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        validate_json_bounds(data)
        if not isinstance(data, dict) or data.get('entity_id') != entity_id:
            raise ValueError()
        state = data.get('state')
        projection = Projection(state='unavailable' if state == 'unknown' else state)
    except (ValueError, TypeError, UnicodeError, RecursionError):
        raise ApiError('ha_projection_unsupported', 502) from None
    return projection


def command_switch(service, entity_id, action, *, guard):
    """Dispatch once and return a closed provider outcome.

    A transport failure is indeterminate because the request may have reached
    Home Assistant. Callers must persist that as unknown and never replay it.
    """
    if (not re.fullmatch(r'switch\.[a-z0-9_]{1,121}', entity_id)
            or action not in ('turn_on', 'turn_off')):
        raise ApiError('invalid_request')
    guard()
    body = json.dumps({'entity_id': entity_id}, separators=(',', ':')).encode('ascii')
    try:
        with ServiceTransport(service.base_url, timeout=TIMEOUT, max_bytes=MAX_BYTES) as transport:
            response = transport.request('POST', '/api/services/switch/' + action,
                headers={'Authorization': 'Bearer ' + service.credentials['token'],
                         'Accept': 'application/json', 'Content-Type': 'application/json'},
                body=body, before_send=guard)
    except (ProbeTransportError, KeyError):
        return None
    if response.status == 200:
        return True
    if response.status in (400, 401, 403, 404, 405, 422):
        return False
    return None
