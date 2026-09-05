"""Private policy validation and synthetic process lifecycle; no real worker run."""

import json
import os
from pathlib import Path
import signal
import socket
from types import SimpleNamespace

import pytest

from larenor_server.plugins import preflight_runtime as runtime


def contents(root='/approved/not-observed'):
    return {'version': 1, 'roots': [{'id': 'appdata', 'path': root, 'purpose': 'data'}]}


@pytest.fixture
def configuration(tmp_path, monkeypatch):
    policy = tmp_path / 'worker-policy.json'
    policy.write_text(json.dumps(contents()))
    policy.chmod(0o600)
    monkeypatch.setattr(runtime, '_host_platform', lambda: 'linux/amd64')
    return policy


def arguments(policy, *extra):
    return ['--policy', str(policy), '--socket', str(policy.parent / 'worker.sock'),
            '--api-uid', str(os.getuid()), *extra]


def test_check_config_validates_only_private_config_without_host_or_socket_access(configuration, monkeypatch, capsys):
    def forbidden(*args, **kwargs):
        pytest.fail('check-only must not instantiate a worker or observe a host root')
    monkeypatch.setattr(runtime, 'HostInspector', forbidden)
    monkeypatch.setattr(runtime, 'PreflightWorkerServer', forbidden)
    monkeypatch.setattr(socket, 'socket', forbidden)
    assert runtime.main(arguments(configuration, '--check-config')) == 0
    assert sorted(p.name for p in configuration.parent.iterdir()) == ['worker-policy.json']
    assert str(configuration.parent) not in capsys.readouterr().out


@pytest.mark.parametrize('change', [
    lambda x: x.update(version=2), lambda x: x.update(version=True), lambda x: x.update(version=1.0),
    lambda x: x.update(command='private-secret'), lambda x: x.update(roots=[]),
    lambda x: x.update(roots=x['roots'] * 17), lambda x: x['roots'][0].update(extra='private-secret'),
    lambda x: x['roots'][0].update(path='relative'), lambda x: x['roots'][0].update(path='/a/../b'),
    lambda x: x['roots'][0].update(purpose='other'), lambda x: x['roots'][0].update(id='../private-secret'),
    lambda x: x.update(roots=x['roots'] * 2),
])
def test_invalid_policy_is_static_and_never_starts_worker(configuration, monkeypatch, capsys, change):
    data = contents()
    change(data)
    configuration.write_text(json.dumps(data))
    calls = []
    monkeypatch.setattr(runtime, 'PreflightWorkerServer', lambda *args, **kwargs: calls.append(args))
    assert runtime.main(arguments(configuration, '--check-config')) != 0
    assert not calls
    assert 'private-secret' not in capsys.readouterr().err


@pytest.mark.parametrize('raw', [b'{"version":1,"version":1,"roots":[]}', b'null', b'[]', b'\xff', b'{}', b' ' * 32769])
def test_duplicate_malformed_or_oversized_policy_is_rejected(configuration, raw):
    configuration.write_bytes(raw)
    assert runtime.main(arguments(configuration, '--check-config')) != 0


@pytest.mark.parametrize('mode', [0o644, 0o660, 0o400, 0o777])
def test_nonprivate_policy_modes_are_rejected(configuration, mode):
    configuration.chmod(mode)
    assert runtime.main(arguments(configuration, '--check-config')) != 0


def test_symlink_policy_or_parent_and_foreign_writable_parent_are_rejected(configuration, tmp_path):
    alias = tmp_path / 'alias.json'
    alias.symlink_to(configuration)
    assert runtime.main(arguments(alias, '--check-config')) != 0
    link = tmp_path / 'link'
    link.symlink_to(tmp_path, target_is_directory=True)
    assert runtime.main(arguments(link / configuration.name, '--check-config')) != 0
    tmp_path.chmod(0o777)
    try:
        assert runtime.main(arguments(configuration, '--check-config')) != 0
    finally:
        tmp_path.chmod(0o700)


def test_hardlinked_and_missing_policy_are_rejected(configuration):
    alias = configuration.parent / 'copy.json'
    os.link(configuration, alias)
    assert runtime.main(arguments(configuration, '--check-config')) != 0
    configuration.unlink()
    assert runtime.main(arguments(configuration, '--check-config')) != 0


@pytest.mark.parametrize('uid', ['-1', '2147483648', '1.5', 'true', 'private-secret'])
def test_bad_uid_never_reads_policy(configuration, monkeypatch, capsys, uid):
    monkeypatch.setattr(runtime, 'load_policy', lambda *args: pytest.fail('arguments first'))
    values = arguments(configuration, '--check-config')
    values[values.index('--api-uid') + 1] = uid
    assert runtime.main(values) == 2
    assert 'private-secret' not in capsys.readouterr().err


def test_distinct_api_uid_requires_socket_group(configuration):
    values = arguments(configuration, '--check-config')
    values[values.index('--api-uid') + 1] = str(os.getuid() + 1)
    assert runtime.main(values) != 0
    assert runtime.main([*values, '--socket-gid', str(os.getgid())]) == 0


@pytest.mark.parametrize('platform', [None, 'darwin/arm64', 'linux/riscv64'])
def test_nonlinux_or_unsupported_architecture_is_rejected_even_in_check_mode(configuration, monkeypatch, platform):
    monkeypatch.setattr(runtime, '_host_platform', lambda: platform)
    assert runtime.main(arguments(configuration, '--check-config')) != 0


def test_help_works_without_policy_or_linux(monkeypatch, capsys):
    monkeypatch.setattr(runtime, '_host_platform', lambda: pytest.fail('help must not discover host'))
    assert runtime.main(['--help']) == 0
    assert 'larenor-preflight-worker' in capsys.readouterr().out


@pytest.mark.parametrize('flag,value', [('--socket', 'relative'), ('--policy', 'relative'), ('--socket-gid', '-1')])
def test_argument_paths_and_optional_group_are_strict(configuration, flag, value):
    values = arguments(configuration, '--check-config')
    if flag in values:
        values[values.index(flag) + 1] = value
    else:
        values.extend([flag, value])
    assert runtime.main(values) != 0


def install_lifecycle(monkeypatch, *, stop_signal=signal.SIGTERM, start_error=None, close_error=None):
    events, handlers = [], {}
    class Event:
        def set(self): events.append('signal')
        def wait(self):
            handlers[stop_signal](stop_signal, None)
    class Worker:
        def start(self):
            events.append('start')
            if start_error:
                raise start_error
        def close(self):
            events.append('close')
            if close_error:
                raise close_error
    def build(path, inspector, **kwargs):
        assert kwargs['platform'] == 'linux/amd64'
        assert kwargs['allowed_uid'] == os.getuid()
        assert 'peer_uid' not in kwargs
        events.append('construct')
        return Worker()
    def handler(sig, callback):
        events.append(('handler', sig))
        handlers[sig] = callback
    monkeypatch.setattr(runtime.threading, 'Event', Event)
    monkeypatch.setattr(runtime.signal, 'getsignal', lambda sig: f'original-{sig}')
    monkeypatch.setattr(runtime.signal, 'signal', handler)
    monkeypatch.setattr(runtime, 'PreflightWorkerServer', build)
    return events, handlers


@pytest.mark.parametrize('stop_signal', [signal.SIGINT, signal.SIGTERM])
def test_runtime_wires_real_peer_defaults_and_restores_handlers(configuration, monkeypatch, stop_signal):
    events, handlers = install_lifecycle(monkeypatch, stop_signal=stop_signal)
    assert runtime.main(arguments(configuration)) == 0
    assert events.index('start') < events.index('signal') < events.index('close')
    for value in (signal.SIGINT, signal.SIGTERM):
        assert handlers[value] == f'original-{value}'


@pytest.mark.parametrize('stage', ['start', 'close'])
def test_startup_and_bounded_shutdown_errors_are_static(configuration, monkeypatch, capsys, stage):
    kwargs = {stage + '_error': RuntimeError('private-policy-secret')}
    events, handlers = install_lifecycle(monkeypatch, **kwargs)
    assert runtime.main(arguments(configuration)) != 0
    assert events.count('close') == 1
    assert 'private-policy-secret' not in capsys.readouterr().err
    assert all(handlers[value] == f'original-{value}' for value in (signal.SIGINT, signal.SIGTERM))


def test_nonregular_policy_is_rejected_before_opening(configuration, monkeypatch):
    configuration.unlink()
    os.mkfifo(configuration, mode=0o600)
    monkeypatch.setattr(os, 'open', lambda *args, **kwargs: pytest.fail('must not open a FIFO'))
    assert runtime.main(arguments(configuration, '--check-config')) != 0


def test_wrong_file_owner_is_rejected_by_private_read(configuration, monkeypatch):
    original = os.fstat
    def metadata(fd):
        values = list(original(fd))
        values[4] = os.getuid() + 1000000
        return os.stat_result(values)
    monkeypatch.setattr(os, 'fstat', metadata)
    assert runtime.main(arguments(configuration, '--check-config')) != 0


def test_signal_setup_failure_restores_handlers_without_constructing_worker(configuration, monkeypatch, capsys):
    events, handlers = install_lifecycle(monkeypatch)
    original = runtime.signal.signal
    def install(number, handler):
        if number == signal.SIGTERM and callable(handler):
            raise ValueError('private-signal-error')
        return original(number, handler)
    monkeypatch.setattr(runtime.signal, 'signal', install)
    assert runtime.main(arguments(configuration)) == 1
    assert 'construct' not in events
    assert handlers[signal.SIGINT] == f'original-{signal.SIGINT}'
    assert 'private-signal-error' not in capsys.readouterr().err


def test_failed_signal_restoration_is_reported_after_worker_close(configuration, monkeypatch):
    events, _ = install_lifecycle(monkeypatch)
    original = runtime.signal.signal
    def install(number, handler):
        if isinstance(handler, str):
            raise OSError('private-signal-error')
        return original(number, handler)
    monkeypatch.setattr(runtime.signal, 'signal', install)
    assert runtime.main(arguments(configuration)) == 1
    assert events.count('close') == 1


def test_module_help_entrypoint_does_not_start_runtime(monkeypatch, capsys):
    import runpy
    monkeypatch.setattr('sys.argv', ['larenor-preflight-worker', '--help'])
    # The module is already imported by these tests; runpy warns before testing
    # its real __main__ guard in another globals dictionary.
    with pytest.warns(RuntimeWarning, match='found in sys.modules'):
        with pytest.raises(SystemExit) as result:
            runpy.run_module('larenor_server.plugins.preflight_runtime', run_name='__main__')
    assert result.value.code == 0
    assert 'larenor-preflight-worker' in capsys.readouterr().out
