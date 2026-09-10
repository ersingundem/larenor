"""Bounded read-only Proxmox cluster summary transport.

Only packaged fixed routes are used. The exported seam returns a closed typed
projection; upstream bodies, credentials and errors never cross the API.
"""
import hashlib
import json
import math
import re
from datetime import datetime, timezone
from urllib.parse import urlencode

from ..errors import ApiError
from ..services.transport import ProbeTransportError, ServiceTransport
from ..vault import validate_json_bounds
from .models import Summary


MAX_BYTES = 1024 * 1024
TIMEOUT = 4.0
_TOKEN = re.compile(r'[^=\s;]+@[^=!\s;]+![A-Za-z0-9._-]{1,64}=[A-Za-z0-9-]{16,128}\Z')
_SESSION = re.compile(r'[A-Za-z0-9_./~+!:=@-]{1,2048}\Z')


def _unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError()
        result[key] = value
    return result


def _data(response, expected=list):
    if response.status in (401, 403):
        raise ApiError('proxmox_upstream_unauthorized', 502)
    if response.status != 200:
        raise ApiError('proxmox_upstream_unavailable', 502)
    try:
        types = [v.split(';', 1)[0].strip().lower() for k, v in response.headers if k == 'content-type']
        if types != ['application/json'] or any(k in ('content-range', 'link') for k, _ in response.headers):
            raise ValueError()
        body = json.loads(response.body, object_pairs_hook=_unique,
            parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        validate_json_bounds(body)
        if type(body) is not dict or type(body.get('data')) is not expected:
            raise ValueError()
        return body['data']
    except (ValueError, TypeError, UnicodeError, RecursionError):
        raise ApiError('proxmox_summary_unsupported', 502) from None


def _number(value, *, integer=False, minimum=0, maximum=2**63 - 1):
    if type(value) not in ((int,) if integer else (int, float)) or not math.isfinite(value):
        raise ValueError()
    if integer and type(value) is not int:
        raise ValueError()
    if not minimum <= value <= maximum:
        raise ValueError()
    return value


def _resources(values):
    nodes, guests, storages = [], [], []
    try:
        if len(values) > 512:
            raise ValueError()
        for item in values:
            if type(item) is not dict:
                raise ValueError()
            kind = item.get('type')
            if kind == 'node':
                nodes.append({'node': item['node'], 'status': item['status'],
                    'cpuRatio': _number(item['cpu'], maximum=1),
                    'memoryUsedBytes': _number(item['mem'], integer=True),
                    'memoryTotalBytes': _number(item['maxmem'], integer=True, minimum=1),
                    'uptimeSeconds': _number(item['uptime'], integer=True)})
            elif kind in ('qemu', 'lxc'):
                guests.append({'vmId': _number(item['vmid'], integer=True, minimum=1, maximum=999999999),
                    'node': item['node'], 'kind': kind, 'name': item['name'], 'status': item['status'],
                    'cpuRatio': _number(item['cpu'], maximum=1),
                    'memoryUsedBytes': _number(item['mem'], integer=True),
                    'memoryTotalBytes': _number(item['maxmem'], integer=True, minimum=1)})
            elif kind == 'storage':
                if item['status'] not in ('available', 'offline'):
                    raise ValueError()
                total = _number(item['maxdisk'], integer=True, minimum=1)
                used = _number(item['disk'], integer=True)
                storages.append({'storage': item['storage'], 'node': item['node'],
                    'kind': item['plugintype'], 'active': item['status'] == 'available',
                    'usedBytes': used, 'totalBytes': total, 'availableBytes': total - used})
            else:
                raise ValueError()
        return nodes, guests, storages
    except (KeyError, TypeError, ValueError):
        raise ApiError('proxmox_summary_unsupported', 502) from None


def _safe(value, *, maximum=128, pattern=None):
    if (type(value) is not str or not value or len(value) > maximum or
            any(ord(c) < 32 or ord(c) == 127 or 0xD800 <= ord(c) <= 0xDFFF for c in value) or
            pattern is not None and re.fullmatch(pattern, value) is None):
        raise ValueError()
    return value


def _timestamp(value):
    seconds = _number(value, integer=True)
    try:
        return datetime.fromtimestamp(seconds, timezone.utc).isoformat().replace('+00:00', 'Z')
    except (OverflowError, OSError, ValueError):
        raise ValueError() from None


def _tasks(values):
    try:
        if len(values) > 20:
            raise ValueError()
        result = []
        for item in values:
            if type(item) is not dict:
                raise ValueError()
            upid = _safe(item['upid'], maximum=4096)
            node = _safe(item['node'], maximum=64, pattern=r'[A-Za-z0-9][A-Za-z0-9._-]*')
            kind = _safe(item['type'], maximum=64, pattern=r'[A-Za-z0-9][A-Za-z0-9._-]*')
            started = _timestamp(item['starttime'])
            end = item.get('endtime')
            raw_status = item.get('status')
            if end is None:
                if raw_status is not None:
                    raise ValueError()
                status, finished = 'running', None
            else:
                if type(raw_status) is not str:
                    raise ValueError()
                _safe(raw_status, maximum=128)
                status = 'succeeded' if raw_status == 'OK' else 'failed'
                finished = _timestamp(end)
            result.append({
                'taskId': hashlib.sha256(upid.encode('utf-8')).hexdigest(),
                'node': node,
                'kind': kind,
                'status': status,
                'startedAt': started,
                'finishedAt': finished,
            })
        return result
    except (KeyError, TypeError, ValueError, UnicodeError):
        raise ApiError('proxmox_summary_unsupported', 502) from None


def read_summary(service, *, guard):
    """Read fixed cluster resources; never dispatch a power/config operation."""
    guard()
    credentials = service.credentials
    try:
        with ServiceTransport(service.base_url, timeout=TIMEOUT, max_bytes=MAX_BYTES) as transport:
            if set(credentials) == {'token'} and _TOKEN.fullmatch(credentials['token']):
                headers = {'Authorization': 'PVEAPIToken=' + credentials['token'], 'Accept': 'application/json'}
            elif set(credentials) == {'username', 'password'}:
                login = transport.request('POST', '/api2/json/access/ticket',
                    headers={'Accept': 'application/json', 'Content-Type': 'application/x-www-form-urlencoded'},
                    body=urlencode(dict(credentials)).encode('ascii'), before_send=guard)
                values = _data(login, dict)
                ticket = values.get('ticket')
                if (values.get('username') != credentials['username'] or values.get('NeedTFA') not in (None, 0, False)
                        or type(ticket) is not str or not _SESSION.fullmatch(ticket)
                        or not ticket.startswith('PVE:' + credentials['username'] + ':')):
                    raise ApiError('proxmox_upstream_unauthorized', 502)
                headers = {'Cookie': 'PVEAuthCookie=' + ticket, 'Accept': 'application/json'}
            else:
                raise ApiError('proxmox_binding_changed', 409)
            response = transport.request('GET', '/api2/json/cluster/resources',
                headers=headers, before_send=guard)
            guard()
            tasks_response = transport.request('GET', '/api2/json/cluster/tasks',
                headers=headers, before_send=guard, query_parameters={'limit': '20'})
    except ApiError:
        raise
    except (ProbeTransportError, KeyError, UnicodeError):
        guard()
        raise ApiError('proxmox_upstream_unavailable', 502) from None
    guard()
    nodes, guests, storages = _resources(_data(response))
    tasks = _tasks(_data(tasks_response))
    try:
        return Summary(nodes=nodes, guests=guests, storages=storages,
                       recentTasks=tasks)
    except (TypeError, ValueError):
        raise ApiError('proxmox_summary_unsupported', 502) from None
