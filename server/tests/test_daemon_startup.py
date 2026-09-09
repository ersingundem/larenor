"""Held daemon argv/config evidence uses bounded no-follow descriptors."""

import os
import time

import pytest


def implementation():
    from larenor_server.plugins import daemon_startup
    return daemon_startup


@pytest.fixture
def startup_tree(tmp_path, monkeypatch):
    module = implementation()
    root = tmp_path / 'root'
    proc = tmp_path / 'proc'
    config = root / 'etc' / 'docker' / 'daemon.json'
    config.parent.mkdir(parents=True)
    proc.mkdir()
    for path in (root, root / 'etc', config.parent, proc):
        path.chmod(0o700)
    config.write_bytes(b'{"data-root":"/var/lib/docker"}')
    config.chmod(0o600)
    executable = '/usr/bin/dockerd'
    (proc / 'cmdline').write_bytes(
        executable.encode() + b'\0--config-file=/etc/docker/daemon.json\0'
    )
    monkeypatch.setattr(module, '_ROOT_UID', os.getuid())
    proc_fd = os.open(proc, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        yield module, root, proc, config, proc_fd, root_fd, executable
    finally:
        os.close(proc_fd)
        os.close(root_fd)


def capture(values):
    module, _root, _proc, _config, proc_fd, root_fd, executable = values
    return module.capture_daemon_startup(
        proc_fd,
        root_fd,
        pid=9001,
        daemon_executable=executable,
        deadline=time.monotonic() + 2,
    )


def test_capture_retains_exact_argv_and_config_then_revalidates(startup_tree):
    module, _root, _proc, _config, proc_fd, root_fd, _executable = startup_tree
    held = capture(startup_tree)
    try:
        assert held.argv == ('/usr/bin/dockerd', '--config-file=/etc/docker/daemon.json')
        assert held.config_path == '/etc/docker/daemon.json'
        assert held.config == b'{"data-root":"/var/lib/docker"}'
        assert held.check(time.monotonic() + 2) is None
        assert repr(held) == 'HeldDaemonStartup(<private>)'
        assert all(not os.get_inheritable(fd) for fd in held._handles)
    finally:
        held.close()
    os.fstat(proc_fd)
    os.fstat(root_fd)


@pytest.mark.parametrize('change', ['cmdline', 'config_contents', 'config_replace', 'config_mode'])
def test_any_startup_or_config_change_invalidates_held_evidence(startup_tree, change):
    module, _root, proc, config, _proc_fd, _root_fd, _executable = startup_tree
    held = capture(startup_tree)
    if change == 'cmdline':
        (proc / 'cmdline').write_bytes(b'/usr/bin/dockerd\0--debug\0')
    elif change == 'config_contents':
        config.write_bytes(b'{"debug":true}')
    elif change == 'config_replace':
        config.unlink()
        config.write_bytes(b'{"data-root":"/var/lib/docker"}')
        config.chmod(0o600)
    else:
        config.chmod(0o660)
    with pytest.raises(module.DaemonStartupError,
                       match='^daemon_startup_unavailable$'):
        held.check(time.monotonic() + 2)
    held.close()


def test_absent_default_config_is_retained_as_absent(startup_tree):
    module, _root, proc, config, proc_fd, root_fd, executable = startup_tree
    config.unlink()
    (proc / 'cmdline').write_bytes(executable.encode() + b'\0')
    held = module.capture_daemon_startup(
        proc_fd, root_fd, pid=9001, daemon_executable=executable,
        deadline=time.monotonic() + 2,
    )
    try:
        assert held.config is None and held.config_path == '/etc/docker/daemon.json'
        held.check(time.monotonic() + 2)
        config.write_bytes(b'{}')
        config.chmod(0o600)
        with pytest.raises(module.DaemonStartupError):
            held.check(time.monotonic() + 2)
    finally:
        held.close()


def test_missing_explicit_config_fails_closed(startup_tree):
    module, _root, proc, config, proc_fd, root_fd, executable = startup_tree
    config.unlink()
    with pytest.raises(module.DaemonStartupError,
                       match='^daemon_startup_unavailable$'):
        module.capture_daemon_startup(
            proc_fd, root_fd, pid=9001, daemon_executable=executable,
            deadline=time.monotonic() + 2,
        )


@pytest.mark.parametrize('contents', [
    b'', b'/usr/bin/dockerd', b'/usr/bin/dockerd\0\0', b'\xff\0',
    b'/usr/bin/dockerd\0--config-file=relative\0',
    b'/usr/bin/dockerd\0--config-file=/etc/docker/daemon.json\0' + b'x' * 65537,
])
def test_malformed_or_oversized_cmdline_is_rejected(startup_tree, contents):
    module, _root, proc, _config, proc_fd, root_fd, executable = startup_tree
    (proc / 'cmdline').write_bytes(contents)
    with pytest.raises(module.DaemonStartupError,
                       match='^daemon_startup_unavailable$'):
        module.capture_daemon_startup(
            proc_fd, root_fd, pid=9001, daemon_executable=executable,
            deadline=time.monotonic() + 2,
        )


@pytest.mark.parametrize('kind', ['symlink', 'directory', 'fifo', 'oversized'])
def test_config_must_be_bounded_regular_private_and_nofollow(startup_tree, tmp_path, kind):
    module, _root, _proc, config, proc_fd, root_fd, executable = startup_tree
    config.unlink()
    if kind == 'symlink':
        target = tmp_path / 'private-target'
        target.write_bytes(b'{}')
        config.symlink_to(target)
    elif kind == 'directory':
        config.mkdir()
    elif kind == 'fifo':
        os.mkfifo(config)
    else:
        config.write_bytes(b'x' * 65537)
    with pytest.raises(module.DaemonStartupError,
                       match='^daemon_startup_unavailable$'):
        module.capture_daemon_startup(
            proc_fd, root_fd, pid=9001, daemon_executable=executable,
            deadline=time.monotonic() + 2,
        )


@pytest.mark.parametrize('deadline', [True, None, float('nan'), float('inf'), -1, 0])
def test_invalid_inputs_fail_before_descriptor_duplication(startup_tree, monkeypatch, deadline):
    module, _root, _proc, _config, proc_fd, root_fd, executable = startup_tree
    monkeypatch.setattr(module.os, 'dup', lambda _fd: pytest.fail('invalid input reached I/O'))
    with pytest.raises(module.DaemonStartupError,
                       match='^daemon_startup_unavailable$'):
        module.capture_daemon_startup(
            proc_fd, root_fd, pid=9001, daemon_executable=executable,
            deadline=deadline,
        )


def test_closed_evidence_cannot_be_reused_and_hides_private_values(startup_tree):
    module, _root, _proc, config, _proc_fd, _root_fd, _executable = startup_tree
    config.write_bytes(b'{"private-secret":true}')
    held = capture(startup_tree)
    assert 'private-secret' not in repr(held)
    held.close()
    held.close()
    with pytest.raises(module.DaemonStartupError) as caught:
        held.check(time.monotonic() + 2)
    assert caught.value.args == ('daemon_startup_unavailable',)
