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


class RawDaemon:
    def __init__(self, raw):
        self.raw = raw
        self.calls = []

    def docker(self, args, **kwargs):
        self.calls.append((list(args), dict(kwargs)))
        return self.raw


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
      'Error':'private unknown path/token'}, 'helper_base_state_error_unclassified'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'unable to apply cgroup configuration: private'},
     'helper_base_isolation_failed'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'resource temporarily unavailable: private'},
     'helper_base_host_resource_failed'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'stat /private/token: no such file or directory'},
     'helper_base_path_failed'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'containerd: stat /private/token: no such file or directory'},
     'helper_base_path_failed'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'stat /usr/local/bin/python: no such file or directory'},
     'helper_base_image_path_failed'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'open /proc/private/value: no such file or directory'},
     'helper_base_proc_path_failed'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'open /proc/sys/net/ipv4/private: no such file or directory'},
     'helper_base_proc_path_failed'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'open /sys/private/value: no such file or directory'},
     'helper_base_sys_path_failed'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'open /run/private/value: no such file or directory'},
     'helper_base_runtime_path_failed'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'open /tmp/larenor-jellyfin-private/data/value: no such file or directory'},
     'helper_base_engine_path_failed'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'open /etc/resolv.conf: no such file or directory'},
     'helper_base_host_path_failed'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'open /etc/hosts/private: not a directory'},
     'helper_base_host_path_failed'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'open /tmp/larenor-jellyfin-private/merged/usr/local/bin/python: no such file or directory'},
     'helper_base_engine_image_path_failed'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'open /tmp/larenor-jellyfin-private/merged/proc/private: no such file or directory'},
     'helper_base_engine_proc_path_failed'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'open /tmp/larenor-jellyfin-private/merged/sys/private: no such file or directory'},
     'helper_base_engine_sys_path_failed'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'open /tmp/larenor-jellyfin-private/merged/run/private: no such file or directory'},
     'helper_base_engine_runtime_path_failed'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'open /tmp/larenor-jellyfin-private/merged/etc/resolv.conf: no such file or directory'},
     'helper_base_engine_host_path_failed'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'open /proc/private/from /run/private: no such file or directory'},
     'helper_base_path_location_ambiguous'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'open /tmp/larenor-jellyfin-private/merged/proc/from /run/private: no such file or directory'},
     'helper_base_path_location_ambiguous'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'open /tmp/larenor-jellyfin-private/data /usr/local/bin/python: no such file or directory'},
     'helper_base_engine_image_paths_observed'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'open /tmp/larenor-jellyfin-private/data /proc/private: no such file or directory'},
     'helper_base_engine_proc_paths_observed'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'open /tmp/larenor-jellyfin-private/data /proc/sys/net/ipv4/private: no such file or directory'},
     'helper_base_proc_sys_net_path_observed'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'open /tmp/larenor-jellyfin-private/data /proc/self/fd/7: no such file or directory'},
     'helper_base_proc_self_fd_path_observed'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'open /tmp/larenor-jellyfin-private/data /proc/self/mountinfo: no such file or directory'},
     'helper_base_proc_self_mountinfo_observed'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'open /tmp/larenor-jellyfin-private/data /proc/self/ns/mnt: no such file or directory'},
     'helper_base_proc_self_namespace_observed'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'open /tmp/larenor-jellyfin-private/data /proc/4242/ns/mnt: no such file or directory'},
     'helper_base_proc_process_namespace_observed'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'open /tmp/larenor-jellyfin-private/data /proc/4242/fd/7: no such file or directory'},
     'helper_base_proc_process_fd_path_observed'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'open /tmp/larenor-jellyfin-private/data /proc/self/fd/7 /proc/self/mountinfo: no such file or directory'},
     'helper_base_proc_subpaths_ambiguous'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'open /tmp/larenor-jellyfin-private/data /proc/private /backup/proc/self/fd/7: no such file or directory'},
     'helper_base_engine_proc_paths_observed'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'open /tmp/larenor-jellyfin-private/data /proc/self/mountinfo-private: no such file or directory'},
     'helper_base_engine_proc_paths_observed'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'open /tmp/larenor-jellyfin-private/data /sys/private: no such file or directory'},
     'helper_base_engine_sys_paths_observed'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'open /tmp/larenor-jellyfin-private/data /run/private: no such file or directory'},
     'helper_base_engine_runtime_paths_observed'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'open /tmp/larenor-jellyfin-private/data /etc/resolv.conf: no such file or directory'},
     'helper_base_engine_host_paths_observed'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'unable to find user private: no matching entries in passwd file'},
     'helper_base_identity_failed'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'private option: invalid argument'},
     'helper_base_configuration_failed'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,
      'Error':'failed to mount /private/token: no such file or directory'},
     'helper_base_state_error_ambiguous'),
    ({'Status':'created','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':125,'Error':''},
     'helper_base_process_not_started_nonzero'),
    ({'Status':'private-unknown','Running':False,'Paused':False,'Restarting':False,
      'Dead':False,'OOMKilled':False,'ExitCode':0,'Error':''},
     'helper_base_state_status_unclassified'),
    ({'Status':'paused','Running':False,'Paused':False,'Restarting':False,'Dead':False,
      'OOMKilled':False,'ExitCode':0,'Error':''},
     'helper_base_state_known_status_unclassified'),
    ({'Status':'removing','Running':False,'Paused':False,'Restarting':False,
      'Dead':False,'OOMKilled':False,'ExitCode':0,'Error':''},
     'helper_base_state_known_status_unclassified'),
], ids=['oom','high-nonzero','nonzero','exited-zero','not-started','running','dead',
        'known-error','unknown-error','isolation-error','host-resource-error',
        'path-error','runtime-name-only','image-path','proc-path','proc-sys-path','sys-path','runtime-path','engine-path',
        'host-path','host-not-directory','engine-image-path','engine-proc-path','engine-sys-path',
        'engine-runtime-path','engine-host-path','ambiguous-path','ambiguous-engine-paths',
        'observed-engine-image-paths','observed-engine-proc-paths','proc-sys-net',
        'proc-self-fd','proc-self-mountinfo','proc-self-namespace','proc-process-namespace',
        'proc-process-fd','ambiguous-proc-subpaths','proc-lookalike-outside-root',
        'proc-mountinfo-lookalike','observed-engine-sys-paths',
        'observed-engine-runtime-paths','observed-engine-host-paths','identity-error',
        'configuration-error',
        'ambiguous-state-error','created-nonzero','unknown-status','known-status-other',
        'removing'])
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
def test_invalid_or_unbound_state_has_one_private_invalid_observation(payload):
    smoke = importlib.import_module('tool.jellyfin_storage_smoke')
    daemon = Daemon(payload)
    original = smoke.SmokeError('fixture_command_exit_failed')

    assert smoke._diagnose_base_start_state(daemon, 'd'*64, original) == 'helper_base_state_invalid'
    assert len(daemon.calls) == 1


def test_specific_start_observation_survives_an_unreadable_state():
    smoke = importlib.import_module('tool.jellyfin_storage_smoke')
    daemon = Daemon(error=smoke.SmokeError('owned_daemon_lost'))

    assert smoke._diagnose_base_start_state(
        daemon, 'd'*64, smoke.SmokeError('helper_base_wait_failed')) == 'helper_base_wait_failed'
    assert len(daemon.calls) == 1


@pytest.mark.parametrize('state', [
    {'Status':'created','Running':False,'Paused':False,'Restarting':False,
     'Dead':False,'OOMKilled':False,'ExitCode':0,
     'Error':'private unknown path/token'},
    {'Status':'private-unknown','Running':False,'Paused':False,
     'Restarting':False,'Dead':False,'OOMKilled':False,'ExitCode':0,'Error':''},
    {'Status':'removing','Running':False,'Paused':False,'Restarting':False,
     'Dead':False,'OOMKilled':False,'ExitCode':0,'Error':''},
], ids=['unknown-error','unknown-status','known-status-other'])
def test_specific_start_observation_survives_unclassified_state_shape(state):
    smoke = importlib.import_module('tool.jellyfin_storage_smoke')
    daemon = Daemon(state)

    assert smoke._diagnose_base_start_state(
        daemon, 'd'*64,
        smoke.SmokeError('helper_base_wait_failed')) == 'helper_base_wait_failed'
    assert len(daemon.calls) == 1


def test_failed_state_read_is_closed_without_retry_or_exception_text():
    smoke = importlib.import_module('tool.jellyfin_storage_smoke')
    daemon = Daemon(error=smoke.SmokeError('owned_daemon_lost'))

    assert smoke._diagnose_base_start_state(
        daemon, 'd'*64, smoke.SmokeError('fixture_command_exit_failed')) == 'helper_base_state_read_failed'
    assert len(daemon.calls) == 1


@pytest.mark.parametrize('raw', [
    (b'{"Status":"created","Running":false,"Paused":false,'
     b'"Restarting":false,"Dead":false,"OOMKilled":false,'
     b'"ExitCode":0,"Error":"\\ud800"}'),
    b'[' * 1000 + b'0' + b']' * 1000,
], ids=['unpaired-surrogate', 'deep-json'])
@pytest.mark.parametrize('original,expected', [
    ('fixture_command_exit_failed', 'helper_base_state_invalid'),
    ('helper_base_wait_failed', 'helper_base_wait_failed'),
])
def test_malformed_bounded_state_stays_closed(raw, original, expected):
    smoke = importlib.import_module('tool.jellyfin_storage_smoke')
    daemon = RawDaemon(raw)

    assert smoke._diagnose_base_start_state(
        daemon, 'd'*64, smoke.SmokeError(original)) == expected
    assert len(daemon.calls) == 1


def test_recursive_decoder_failure_is_a_closed_invalid_observation(monkeypatch):
    smoke = importlib.import_module('tool.jellyfin_storage_smoke')
    daemon = RawDaemon(b'{}')
    monkeypatch.setattr(smoke.json, 'loads', lambda _raw: (_ for _ in ()).throw(RecursionError()))

    assert smoke._diagnose_base_start_state(
        daemon, 'd'*64,
        smoke.SmokeError('fixture_command_exit_failed')) == 'helper_base_state_invalid'
    assert len(daemon.calls) == 1


def test_only_exact_smoke_error_enters_state_diagnosis():
    smoke = importlib.import_module('tool.jellyfin_storage_smoke')
    daemon = Daemon({'Status':'exited','Running':False,'Paused':False,'Restarting':False,
        'Dead':False,'OOMKilled':False,'ExitCode':17,'Error':''})

    with pytest.raises(TypeError):
        smoke._diagnose_base_start_state(daemon, 'd'*64, RuntimeError('private'))
    assert daemon.calls == []
