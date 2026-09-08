"""Closed state diagnosis after the one allowed helper-base start attempt."""
import importlib
import json

import pytest


class Daemon:
    def __init__(self, result=None, error=None):
        self.result = result
        self.error = error
        self.calls = []

    def docker(self, args, **kwargs):
        self.calls.append((list(args), dict(kwargs)))
        if self.error is not None:
            raise self.error
        return json.dumps(self.result).encode()


@pytest.mark.parametrize('state,expected', [
    ({'Status':'exited','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':True,'ExitCode':137,'Error':''},
     'helper_base_process_oom'),
    ({'Status':'exited','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':137,'Error':''},
     'helper_base_process_nonzero'),
    ({'Status':'exited','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':17,'Error':''},
     'helper_base_process_nonzero'),
    ({'Status':'exited','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,'Error':''},
     'helper_base_process_exited_zero'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,'Error':''},
     'helper_base_process_not_started'),
    ({'Status':'running','Running':True,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,'Error':''},
     'helper_base_process_running'),
    ({'Status':'dead','Running':False,'Paused':False,'Restarting':False,'Dead':True,
      'OOMKilled':False,'ExitCode':0,'Error':''},
     'helper_base_process_dead'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'OCI runtime create failed: permission denied: private'},
     'helper_base_permission_failed'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'private unknown path/token'}, 'fixture_command_exit_failed'),
], ids=['oom','high-nonzero','nonzero','exited-zero','not-started','running','dead',
        'known-error','unknown-error'])
def test_failed_start_is_classified_from_one_bounded_owned_state_read(state, expected):
    smoke = importlib.import_module('tool.jellyfin_storage_smoke')
    daemon = Daemon(state)

    assert smoke._diagnose_base_start_state(
        daemon, 'd'*64, smoke.SmokeError('fixture_command_exit_failed')) == expected
    assert daemon.calls == [
        (['container','inspect','--format','{{json .State}}','d'*64],
         {'timeout':10,'limit':65536})]


@pytest.mark.parametrize('payload', [
    None, [], {},
    {'Status':'exited','Running':False,'Paused':False,'Restarting':False,'Dead':False,
     'OOMKilled':False,'ExitCode':True,'Error':''},
])
def test_invalid_or_unbound_state_preserves_original_closed_code(payload):
    smoke = importlib.import_module('tool.jellyfin_storage_smoke')
    daemon = Daemon(payload)
    original = smoke.SmokeError('helper_base_wait_failed')

    assert smoke._diagnose_base_start_state(daemon, 'd'*64, original) == 'helper_base_wait_failed'
    assert len(daemon.calls) == 1


def test_failed_state_read_preserves_original_without_retry_or_exception_text():
    smoke = importlib.import_module('tool.jellyfin_storage_smoke')
    daemon = Daemon(error=smoke.SmokeError('owned_daemon_lost'))

    assert smoke._diagnose_base_start_state(
        daemon, 'd'*64, smoke.SmokeError('fixture_command_exit_failed')) == 'fixture_command_exit_failed'
    assert len(daemon.calls) == 1


def test_only_exact_smoke_error_enters_state_diagnosis():
    smoke = importlib.import_module('tool.jellyfin_storage_smoke')
    daemon = Daemon({'Status':'exited','Running':False,'Paused':False,'Restarting':False,
        'Dead':False,'OOMKilled':False,'ExitCode':17,'Error':''})

    with pytest.raises(TypeError):
        smoke._diagnose_base_start_state(daemon, 'd'*64, RuntimeError('private'))
    assert daemon.calls == []
