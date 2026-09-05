"""Synthetic Unix Engine only: digest pins, bounded progress and no raw errors."""

from contextlib import contextmanager
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import threading
import time
from urllib.parse import parse_qs, urlsplit, unquote

import pytest

from larenor_server.context import ContextResponse
from larenor_server.plugins.catalog import load_catalog
from larenor_server.plugins.docker_probe import DockerEndpoint
from larenor_server.plugins.resource_models import WorkerPolicyBinding
from larenor_server.plugins.resource_plan import build_resource_plan
from larenor_server.plugins.stack_plan import build_media_stack_plan
from larenor_server.plugins.image_resources import (
    ImageResourceError, ImagePullLimits, UnixImageEngine, image_binding,
)


@pytest.fixture
def source():
    catalog = load_catalog()
    policy = WorkerPolicyBinding(schemaVersion=1, workerPolicyVersion=3, workerPolicyDigest='d' * 64)
    stack = build_media_stack_plan(catalog, {}, 'linux/amd64',
                                  ContextResponse(schemaVersion=1, coreId='a' * 32, homeId='b' * 32), 'c' * 32)
    plan = build_resource_plan(stack, catalog, policy)
    return plan, stack, catalog, policy


@pytest.fixture
def binding(source):
    return image_binding(*source, source[0].resources[0].resourceId)


def image(item):
    return {'Id': item.config_digest, 'Os': 'linux', 'Architecture': 'amd64',
            'RepoDigests': [item.reference], 'Config': {'Env': ['PRIVATE=never-display']}}


def response(value, *, status=200, chunked=False, content_type='application/json'):
    body = value if isinstance(value, bytes) else json.dumps(value).encode()
    headers = f'HTTP/1.1 {status} result\r\nContent-Type: {content_type}\r\n'
    if chunked:
        return (headers.encode() + b'Transfer-Encoding: chunked\r\n\r\n' +
                b''.join(f'{len(piece):x}\r\n'.encode() + piece + b'\r\n'
                         for piece in (body[:3], body[3:]) if piece) + b'0\r\n\r\n')
    return headers.encode() + f'Content-Length: {len(body)}\r\n\r\n'.encode() + body


VERSION = {'MinAPIVersion': '1.24', 'ApiVersion': '1.47', 'Os': 'linux', 'Arch': 'amd64'}


@contextmanager
def engine_server(replies, *, version=VERSION, limits=None, peer=None):
    """Each reconnect must check version on the same authenticated socket."""
    with tempfile.TemporaryDirectory(prefix='li-', dir='/private/tmp' if sys.platform == 'darwin' else '/tmp') as directory:
        path = Path(directory) / 'engine.sock'
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(path))
        path.chmod(0o600)
        listener.listen(4)
        listener.settimeout(0.1)
        calls, failures = [], []
        stopped = threading.Event()

        def request(connection):
            data = bytearray()
            while not data.endswith(b'\r\n\r\n'):
                part = connection.recv(1)
                if not part:
                    return None
                data.extend(part)
                if len(data) > 16384:
                    raise AssertionError('request exceeded limit')
            calls.append(bytes(data))
            return bytes(data)

        def serve():
            try:
                while not stopped.is_set():
                    try:
                        connection, _ = listener.accept()
                    except socket.timeout:
                        continue
                    with connection:
                        connection.settimeout(2)
                        if request(connection) is None:
                            continue
                        connection.sendall(response(version))
                        if request(connection) is None:
                            continue
                        reply = replies.pop(0)
                        if callable(reply):
                            reply(connection)
                        else:
                            connection.sendall(reply)
            except (BrokenPipeError, ConnectionResetError):
                pass
            except Exception as error:
                if not stopped.is_set():
                    failures.append(error)

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        engine = UnixImageEngine(DockerEndpoint(str(path), os.getuid()), limits=limits or ImagePullLimits(),
                                 peer_uid=peer or (lambda _: os.getuid()))
        try:
            yield engine, calls
        finally:
            stopped.set()
            listener.close()
            thread.join(3)
            assert not thread.is_alive()
            assert not failures


def test_binding_is_catalog_rederived_and_hidden_config_never_in_repr(source, binding):
    assert binding.reference.endswith('@' + source[0].resources[0].image.digest)
    with pytest.raises(ImageResourceError, match='^invalid_image_binding$'):
        image_binding(*source, source[0].resources[1].resourceId)
    bad = source[0].model_copy(update={'workerPolicyDigest': 'e' * 64})
    with pytest.raises(ImageResourceError, match='^invalid_image_binding$'):
        image_binding(bad, *source[1:], source[0].resources[0].resourceId)
    with engine_server([response(image(binding))]) as (engine, calls):
        result = engine.inspect(binding)
    assert result.image_id == binding.config_digest
    assert 'PRIVATE' not in repr(result) and 'never-display' not in repr(result)
    assert b'GET /version HTTP/1.1' in calls[0]
    assert b'Connection: keep-alive' in calls[0]
    assert unquote(calls[1].split(b' ')[1].decode()) == '/v1.47/images/' + binding.reference + '/json'
    assert not any(b'X-Registry-Auth' in call or b'Authorization' in call for call in calls)


@pytest.mark.parametrize('change', [
    {'Id': 'sha256:' + '0' * 64}, {'Os': 'windows'}, {'Architecture': 'arm64'},
    {'RepoDigests': []}, {'RepoDigests': ['ghcr.io/foreign/image@sha256:' + '0' * 64]},
    {'Config': None}, {'Variant': 'unexpected'},
])
def test_inspect_rejects_wrong_config_platform_reference_and_configuration(binding, change):
    value = {**image(binding), **change}
    with engine_server([response(value)]) as (engine, _):
        with pytest.raises(ImageResourceError, match='^image_unverified$'):
            engine.inspect(binding)


def test_missing_cache_is_explicit_and_not_an_implicit_pull(binding):
    with engine_server([response({'message': 'private registry details'}, status=404)]) as (engine, calls):
        assert engine.inspect(binding) is None
    assert len(calls) == 2 and not any(b'POST' in call for call in calls)


def test_missing_cache_reply_cannot_bypass_endpoint_revalidation(binding):
    def changed(connection):
        Path(engine._endpoint.path).chmod(0o666)
        connection.sendall(response({'message': 'not found'}, status=404))

    with engine_server([changed]) as (engine, calls):
        with pytest.raises(ImageResourceError, match='^image_engine_unavailable$'):
            engine.inspect(binding)
    assert len(calls) == 2


def test_missing_cache_reply_cannot_bypass_cancellation(binding, monkeypatch):
    from larenor_server.plugins import image_resources
    cancelled = threading.Event()
    original = image_resources._headers

    def headers(reader):
        status, values = original(reader)
        if status == 404:
            cancelled.set()
        return status, values

    monkeypatch.setattr(image_resources, '_headers', headers)
    with engine_server([response({}, status=404)]) as (engine, calls):
        with pytest.raises(ImageResourceError, match='^image_cancelled$'):
            engine.inspect(binding, cancelled=cancelled)
    assert len(calls) == 2


@pytest.mark.parametrize('chunked', [False, True])
def test_pull_is_fixed_digest_only_and_discards_progress(binding, chunked):
    with engine_server([response(b'{"status":"Downloading","id":"private-value"}\n{"status":"Done"}\n',
                                         chunked=chunked)]) as (engine, calls):
        assert engine.pull(binding) is None
    method, raw, _ = calls[1].split(b' ', 2)
    target = urlsplit(raw.decode())
    assert method == b'POST' and target.path == '/v1.47/images/create'
    assert parse_qs(target.query) == {'fromImage': [binding.reference], 'platform': ['linux/amd64']}
    assert b'Content-Length: 0\r\n' in calls[1]


@pytest.mark.parametrize('body,code', [
    (b'{"error":"token=private-value"}\n', 'image_pull_failed'),
    (b'{"errorDetail":{"message":"private-value"}}\n', 'image_pull_failed'),
    (b'{"status":"Done"}', 'image_protocol'), (b'', 'image_protocol'),
    (b'[]\n', 'image_protocol'), (b'{"status":1,"status":2}\n', 'image_protocol'),
    (b'{"progressDetail":{"current":NaN}}\n', 'image_protocol'),
    (b'private-value\n', 'image_protocol'),
])
def test_http_200_is_not_pull_success(binding, body, code):
    with engine_server([response(body)]) as (engine, _):
        with pytest.raises(ImageResourceError, match='^' + code + '$') as error:
            engine.pull(binding)
    assert 'private-value' not in str(error.value)


@pytest.mark.parametrize('status', [301, 401, 404, 500])
def test_pull_http_error_is_static_and_never_follows_redirect(binding, status):
    with engine_server([response({'message': 'private-value'}, status=status)]) as (engine, calls):
        with pytest.raises(ImageResourceError, match='^image_pull_failed$'):
            engine.pull(binding)
    assert len(calls) == 2


@pytest.mark.parametrize('limits,body', [
    (dict(max_line_bytes=32), b'{"status":"' + b'x' * 33 + b'"}\n'),
    (dict(max_events=1), b'{"status":"one"}\n{"status":"two"}\n'),
    (dict(max_total_bytes=32), b'{"status":"' + b'x' * 33 + b'"}\n'),
    (dict(max_chunks=1), b'{"status":"Done"}\n'),
])
def test_progress_has_independent_line_event_byte_chunk_limits(binding, limits, body):
    with engine_server([response(body, chunked=True)], limits=ImagePullLimits(**limits)) as (engine, _):
        with pytest.raises(ImageResourceError, match='^image_stream_limit$'):
            engine.pull(binding)


@pytest.mark.parametrize('version', [{**VERSION, 'ApiVersion': '1.46'},
                                      {**VERSION, 'MinAPIVersion': '1.48'},
                                      {**VERSION, 'Arch': 'arm64'},
                                      {**VERSION, 'MinAPIVersion': True}])
def test_current_mutation_socket_must_advertise_supported_api(binding, version):
    with engine_server([], version=version) as (engine, calls):
        with pytest.raises(ImageResourceError, match='^image_api_unsupported$'):
            engine.pull(binding)
    assert len(calls) == 1


def test_untrusted_peer_prevents_even_version_request(binding):
    with engine_server([], peer=lambda _: os.getuid() + 1) as (engine, calls):
        with pytest.raises(ImageResourceError, match='^image_engine_unavailable$'):
            engine.pull(binding)
    assert not calls


@pytest.mark.parametrize('field,value', [('total_seconds', True), ('idle_seconds', float('inf')),
                                        ('max_events', True), ('max_total_bytes', 0),
                                        ('max_line_bytes', 1048577), ('max_chunks', 1000001)])
def test_limits_are_strict_and_bounded(field, value):
    with pytest.raises(ImageResourceError, match='^invalid_image_limits$'):
        ImagePullLimits(**{field: value})


def test_cancel_before_connection_causes_no_io(binding):
    cancelled = threading.Event()
    cancelled.set()
    with engine_server([]) as (engine, calls):
        with pytest.raises(ImageResourceError, match='^image_cancelled$'):
            engine.pull(binding, cancelled=cancelled)
    assert not calls


def test_total_deadline_does_not_restart_for_progress(binding):
    def slow(connection):
        connection.sendall(b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n')
        for _ in range(30):
            connection.sendall(b'3\r\n{  \r\n')
            time.sleep(0.02)

    start = time.monotonic()
    with engine_server([slow], limits=ImagePullLimits(total_seconds=0.15, idle_seconds=0.1)) as (engine, _):
        with pytest.raises(ImageResourceError, match='^image_timeout$'):
            engine.pull(binding)
    assert time.monotonic() - start < 1.5


def test_idle_timeout_is_shorter_than_total_budget(binding):
    def stalled(connection):
        time.sleep(0.3)

    with engine_server([stalled], limits=ImagePullLimits(total_seconds=1, idle_seconds=0.05)) as (engine, _):
        with pytest.raises(ImageResourceError, match='^image_timeout$'):
            engine.pull(binding)


@pytest.mark.parametrize('raw', [
    b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 50\r\n\r\n{}\n',
    b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n3\r\n{}\n\r\n',
    b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 3\r\nContent-Length: 3\r\n\r\n{}\n',
    b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Encoding: gzip\r\nContent-Length: 3\r\n\r\n{}\n',
    b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nContent-Length: 3\r\n\r\n{}\n',
    b'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 3\r\n\r\n{}\n',
    b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n3;extension=x\r\n{}\n\r\n0\r\n\r\n',
    b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nAuthorization: hidden\r\n\r\n',
])
def test_truncated_or_ambiguous_http_is_not_a_success(binding, raw):
    with engine_server([raw]) as (engine, _):
        with pytest.raises(ImageResourceError, match='^image_protocol$'):
            engine.pull(binding)


def test_close_delimited_progress_is_still_bounded_and_must_be_inspected(binding):
    raw = b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{"status":"Done"}\n'
    with engine_server([raw]) as (engine, _):
        assert engine.pull(binding) is None


def test_cancellation_during_stalled_read_closes_connection_promptly(binding):
    cancelled, receiving = threading.Event(), threading.Event()

    def stalled(connection):
        receiving.set()
        assert connection.recv(1) == b''

    with engine_server([stalled], limits=ImagePullLimits(total_seconds=5, idle_seconds=3)) as (engine, _):
        failures = []

        def pull():
            try:
                engine.pull(binding, cancelled=cancelled)
            except ImageResourceError as error:
                failures.append(error.code)

        thread = threading.Thread(target=pull)
        thread.start()
        assert receiving.wait(1)
        cancelled.set()
        thread.join(1)
        assert not thread.is_alive() and failures == ['image_cancelled']


def test_missing_socket_is_static_without_host_path_leak(binding):
    engine = UnixImageEngine(DockerEndpoint('/missing-private-engine.sock', os.getuid()))
    with pytest.raises(ImageResourceError, match='^image_engine_unavailable$'):
        engine.inspect(binding)


def test_binding_fields_cannot_be_changed_independently_of_source_catalog(binding):
    from dataclasses import replace
    changed = replace(binding, reference='ghcr.io/attacker/image@sha256:' + '0' * 64)
    with engine_server([]) as (engine, calls):
        with pytest.raises(ImageResourceError, match='^invalid_image_binding$'):
            engine.pull(changed)
    assert not calls


def test_configuration_is_bounded_and_only_returned_privately(binding):
    snapshot = image(binding)
    snapshot['Config'] = {'Env': ['SECRET=' + 'x' * 65536]}
    with engine_server([response(snapshot)]) as (engine, _):
        with pytest.raises(ImageResourceError, match='^image_unverified$'):
            engine.inspect(binding)


@pytest.mark.skipif(sys.platform != 'linux', reason='real SO_PEERCRED requires Linux')
def test_real_unix_peer_uid_passes_in_linux_ci(binding):
    with engine_server([response(image(binding))]) as (engine, _):
        production = UnixImageEngine(engine._endpoint)
        assert production.inspect(binding).image_id == binding.config_digest


@pytest.mark.parametrize('variant', ['', 'v8'])
def test_arm64_uses_its_own_pinned_config_and_manifest(source, variant):
    _, _, catalog, policy = source
    stack = build_media_stack_plan(catalog, {}, 'linux/arm64',
                                  ContextResponse(schemaVersion=1, coreId='a' * 32, homeId='b' * 32), 'c' * 32)
    plan = build_resource_plan(stack, catalog, policy)
    selected = image_binding(plan, stack, catalog, policy, plan.resources[0].resourceId)
    value = {**image(selected), 'Architecture': 'arm64', 'Variant': variant}
    with engine_server([response(value), response(b'{"status":"Done"}\n')],
                       version={**VERSION, 'Arch': 'arm64'}) as (engine, calls):
        assert engine.inspect(selected).image_id == plan.resources[0].image.configDigest
        assert engine.pull(selected) is None
    assert selected.config_digest != source[0].resources[0].image.configDigest
    assert parse_qs(urlsplit(calls[-1].split(b' ')[1].decode()).query)['platform'] == ['linux/arm64']


@pytest.mark.parametrize('change', ['variant', 'amd64_config'])
def test_arm64_rejects_foreign_variant_or_amd64_config(source, change):
    _, _, catalog, policy = source
    stack = build_media_stack_plan(catalog, {}, 'linux/arm64',
                                  ContextResponse(schemaVersion=1, coreId='a' * 32, homeId='b' * 32), 'c' * 32)
    plan = build_resource_plan(stack, catalog, policy)
    selected = image_binding(plan, stack, catalog, policy, plan.resources[0].resourceId)
    value = {**image(selected), 'Architecture': 'arm64', 'Variant': 'v8'}
    value.update({'Variant': 'v7'} if change == 'variant'
                 else {'Id': source[0].resources[0].image.configDigest})
    with engine_server([response(value)], version={**VERSION, 'Arch': 'arm64'}) as (engine, _):
        with pytest.raises(ImageResourceError, match='^image_unverified$'):
            engine.inspect(selected)
