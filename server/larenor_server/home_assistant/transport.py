"""One selected-state GET through the existing bounded, no-proxy transport.

Only the closed state projection leaves this module. Upstream attributes,
headers, exceptions and bodies never become API errors, previews or cache data.
"""
import json
import re
import unicodedata

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


_ENTITY = re.compile(r'([a-z0-9_]{1,64})\.[a-z0-9_]{1,121}\Z')


def read_entity(service, entity_id, *, guard):
    selected = _ENTITY.fullmatch(entity_id) if type(entity_id) is str and len(entity_id) <= 128 else None
    if selected is None:
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
        if (type(state) is not str or not 1 <= len(state) <= 255
                or any(unicodedata.category(char).startswith('C') for char in state)):
            raise ValueError()
        domain = selected.group(1)
        if domain == 'switch' and state == 'unknown':
            state = 'unavailable'
        projection = Projection(kind=domain, state=state)
    except (ValueError, TypeError, UnicodeError, RecursionError):
        raise ApiError('ha_projection_unsupported', 502) from None
    return projection


# Kept as a private compatibility import for older focused tests and workers.
read_switch = read_entity


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
