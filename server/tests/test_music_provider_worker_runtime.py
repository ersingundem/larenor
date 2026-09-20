import json
import os
from pathlib import Path
import tempfile
import threading
import time

from larenor_server.plugins.installation_ipc import (
    InstallationWorkerClient, InstallationWorkerServer,
)
from larenor_server.plugins.music_provider_setup_models import (
    PrivateMusicProviderSetupAction, ProviderSetupWorkerResult,
)
from larenor_server.plugins.music_provider_setup_runtime import (
    MusicProviderSetupRuntime, MusicProviderSetupRuntimeError,
)


class Response:
    status = 200

    def __init__(self, value):
        self.value = value

    def read(self, _limit):
        return json.dumps(self.value).encode()


class Connection:
    def __init__(self, responses, calls):
        self.responses, self.calls = responses, calls

    def request(self, method, path, body, headers):
        parsed = json.loads(body)
        self.calls.append((method, path, parsed, headers))

    def getresponse(self):
        command = self.calls[-1][2]
        return Response({'message_id': command['message_id'],
                         'result': self.responses.pop(0)})

    def close(self):
        pass


def action(**changes):
    body = dict(setupId='a' * 32, providerDomain='ytmusic', command='submit',
                flowId='flow-private', stepId='user',
                values={'cookie': 'private-cookie'}, token='private-mass-token')
    body.update(changes)
    return PrivateMusicProviderSetupAction(**body)


def test_runtime_submits_once_then_authenticates_exact_instance_readback():
    calls = []
    responses = [
        {'type': 'finish', 'flow_id': 'flow-private',
         'result': {'instance_id': 'ytmusic--family'}},
        {'instance_id': 'ytmusic--family', 'domain': 'ytmusic',
         'status': 'loaded'},
    ]
    runtime = MusicProviderSetupRuntime(
        lambda _timeout: Connection(responses, calls))
    result = runtime.execute(action(), deadline=time.monotonic() + 2)
    assert result == ProviderSetupWorkerResult(
        state='ready', providerDomain='ytmusic',
        providerInstanceId='ytmusic--family')
    assert [call[2]['command'] for call in calls] == [
        'config/flows/submit', 'config/providers/get']
    assert calls[0][2]['args'] == {
        'flow_id': 'flow-private', 'values': {'cookie': 'private-cookie'}}
    assert calls[1][2]['args'] == {'instance_id': 'ytmusic--family'}
    assert all(call[3]['Authorization'] == 'Bearer private-mass-token'
               for call in calls)
    assert 'private-cookie' not in repr(action())
    assert 'private-mass-token' not in repr(action())


def test_runtime_projects_pinned_external_step_without_exposing_upstream_metadata():
    calls = []
    responses = [{
        'flow_id': 'flow-private', 'step_id': 'authenticate',
        'type': 'external', 'title': 'private localized title',
        'description': None, 'entries': [], 'errors': {}, 'last_step': None,
        'url': 'https://accounts.spotify.com/authorize?state=private-state',
        'progress_text': None, 'progress': None, 'image': None,
        'expires_at': time.time() + 600, 'result': None, 'reason': None,
    }]
    runtime = MusicProviderSetupRuntime(
        lambda _timeout: Connection(responses, calls))

    result = runtime.execute(
        action(providerDomain='spotify', command='start', flowId=None,
               stepId=None, values={}),
        deadline=time.monotonic() + 2)

    assert result.state == 'action_required'
    assert result.discovery.kind == 'external'
    assert result.discovery.stepId == 'authenticate'
    assert result.discovery.externalUrl.startswith(
        'https://accounts.spotify.com/authorize?')
    assert 'private localized title' not in repr(result)


def test_runtime_projects_pinned_form_entries_and_ignores_only_known_ui_entries():
    calls = []
    responses = [{
        'flow_id': 'flow-private', 'step_id': 'user', 'type': 'form',
        'title': None, 'description': None,
        'entries': [
            {'key': 'unofficial_provider_note', 'type': 'alert',
             'required': False, 'value': None},
            {'key': 'music_user_manual_token', 'type': 'secure_string',
             'required': False, 'value': None, 'advanced': True},
        ],
        'errors': {}, 'last_step': None, 'url': None,
        'progress_text': None, 'progress': None, 'image': None,
        'expires_at': None, 'result': None, 'reason': None,
    }]
    runtime = MusicProviderSetupRuntime(
        lambda _timeout: Connection(responses, calls))

    result = runtime.execute(
        action(providerDomain='apple_music', command='start', flowId=None,
               stepId=None, values={}),
        deadline=time.monotonic() + 2)

    assert [entry.model_dump() for entry in result.discovery.entries] == [{
        'key': 'music_user_manual_token', 'type': 'secure_string',
        'required': False}]


def test_runtime_rejects_obsolete_or_unbounded_setup_step_shapes():
    invalid = [
        {'type': 'external', 'flow_id': 'flow-private',
         'step_id': 'authenticate', 'external_url': 'https://accounts.spotify.com'},
        {'type': 'form', 'flow_id': 'flow-private', 'step_id': 'user',
         'entries': [{'key': 'secret', 'type': 'integer', 'required': True}]},
        {'type': 'form', 'flow_id': 'flow-private', 'step_id': 'user',
         'entries': [{'key': 'note', 'type': 'alert', 'required': True}]},
    ]
    for response in invalid:
        runtime = MusicProviderSetupRuntime(
            lambda _timeout, response=response: Connection([response], []))
        try:
            runtime.execute(
                action(providerDomain='spotify', command='start', flowId=None,
                       stepId=None, values={}),
                deadline=time.monotonic() + 1)
        except MusicProviderSetupRuntimeError as error:
            assert str(error) == 'provider_setup_upstream_changed'
        else:
            raise AssertionError('unreviewed setup-flow shape was accepted')


class WorkerBackend:
    def __init__(self):
        self.seen = None

    def execute_music_provider_setup(self, private, *, deadline, gate):
        assert gate() is True and time.monotonic() < deadline
        self.seen = private
        return ProviderSetupWorkerResult(
            state='ready', providerDomain=private.providerDomain,
            providerInstanceId='spotify--fixture')


def test_private_unix_worker_roundtrip_keeps_action_out_of_public_result():
    base = '/private/tmp' if Path('/private/tmp').is_dir() else '/tmp'
    with tempfile.TemporaryDirectory(prefix='mpw-', dir=base) as root:
        path = Path(root) / 'install.sock'
        backend = WorkerBackend()
        server = InstallationWorkerServer(
            path, backend, allowed_uid=os.getuid(),
            peer_uid=lambda _connection: os.getuid(), timeout=1)
        server.start()
        try:
            client = InstallationWorkerClient(
                path, owner_uid=os.getuid(),
                peer_uid=lambda _connection: os.getuid(), timeout=1)
            private = action(providerDomain='spotify', command='resume',
                             values={}, stepId=None)
            result = client.execute_music_provider_setup(
                private, deadline=time.monotonic() + 1, gate=lambda: True)
            assert result.providerInstanceId == 'spotify--fixture'
            assert backend.seen == private
            assert 'private-mass-token' not in result.model_dump_json()
            assert 'flow-private' not in result.model_dump_json()
        finally:
            server.close()


def test_runtime_honours_cancel_before_any_network_attempt():
    calls = []
    cancelled = threading.Event()
    cancelled.set()
    runtime = MusicProviderSetupRuntime(
        lambda _timeout: Connection([], calls))
    try:
        runtime.execute(action(), deadline=time.monotonic() + 1,
                        cancelled=cancelled)
    except Exception as error:
        assert str(error) == 'provider_setup_cancelled'
    else:
        raise AssertionError('cancelled execution was accepted')
    assert calls == []


def test_runtime_abort_is_one_authenticated_bounded_command():
    calls = []
    responses = [None]
    runtime = MusicProviderSetupRuntime(
        lambda _timeout: Connection(responses, calls))
    result = runtime.execute(
        action(command='abort', values={}, stepId=None),
        deadline=time.monotonic() + 1)
    assert result == ProviderSetupWorkerResult(
        state='cancelled', providerDomain='ytmusic')
    assert [call[2]['command'] for call in calls] == ['config/flows/abort']


def test_runtime_rejects_stale_flow_before_provider_readback():
    calls = []
    responses = [{'type': 'finish', 'flow_id': 'different-flow',
                  'result': {'instance_id': 'ytmusic--family'}}]
    runtime = MusicProviderSetupRuntime(
        lambda _timeout: Connection(responses, calls))
    try:
        runtime.execute(action(), deadline=time.monotonic() + 1)
    except MusicProviderSetupRuntimeError as error:
        assert str(error) == 'provider_setup_upstream_changed'
    else:
        raise AssertionError('stale flow was accepted')
    assert len(calls) == 1


def test_finished_provider_requires_exact_instance_and_domain_readback():
    bad_readbacks = [
        None, {}, [],
        [{'instance_id': 'ytmusic--family', 'domain': 'ytmusic'}],
        {'instance_id': 'other', 'domain': 'ytmusic'},
        {'instance_id': 'ytmusic--family', 'domain': 'spotify'},
        {'instance_id': 'ytmusic--family'},
        {'domain': 'ytmusic'},
        {'instance_id': 'ytmusic--family', 'domain': 'ytmusic',
         'status': 'auth_required'},
    ]
    for readback in bad_readbacks:
        calls = []
        responses = [
            {'type': 'finish', 'flow_id': 'flow-private',
             'result': {'instance_id': 'ytmusic--family'}},
            readback,
        ]
        runtime = MusicProviderSetupRuntime(
            lambda _timeout: Connection(responses, calls))
        try:
            runtime.execute(action(), deadline=time.monotonic() + 1)
        except MusicProviderSetupRuntimeError as error:
            assert str(error) == 'provider_setup_readback_failed'
        else:
            raise AssertionError('unbound provider readback was accepted')
