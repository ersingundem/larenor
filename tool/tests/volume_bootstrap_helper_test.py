"""Local FD fixtures only; no real volume, ownership change or Docker."""
import importlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
from types import SimpleNamespace

import pytest


def api():
    name = 'tool.volume_bootstrap_helper'
    assert importlib.util.find_spec(name) is not None, 'fixed volume bootstrap helper is absent'
    return importlib.import_module(name)


@pytest.fixture
def local(tmp_path, monkeypatch):
    m = api()
    root = tmp_path / 'volume'
    root.mkdir(mode=0o755)
    state = {'uid': 0, 'gid': 0, 'mode': 0o755}
    effects = []
    actual_stat = os.fstat

    def observed(fd):
        value = actual_stat(fd)
        return SimpleNamespace(st_dev=value.st_dev, st_ino=value.st_ino,
            st_uid=state['uid'], st_gid=state['gid'], st_mode=stat.S_IFDIR | state['mode'])

    def chmod(fd, mode):
        effects.append(('chmod', mode))
        state['mode'] = mode

    def chown(fd, uid, gid):
        effects.append(('chown', uid, gid))
        state.update(uid=uid, gid=gid)

    monkeypatch.setattr(m, '_open_root', lambda: os.open(root, os.O_RDONLY | os.O_DIRECTORY))
    monkeypatch.setattr(m.os, 'fstat', observed)
    monkeypatch.setattr(m.os, 'geteuid', lambda: 0)
    monkeypatch.setattr(m.os, 'fchmod', chmod)
    monkeypatch.setattr(m.os, 'fchown', chown)
    monkeypatch.setattr(m.os, 'fsync', lambda fd: effects.append(('fsync',)))
    return m, root, state, effects


def test_empty_root_changes_only_directory_metadata_then_verifies(local):
    m, root, state, effects = local
    assert m.run('check') == {'schemaVersion': 1, 'state': 'empty_uninitialized'}
    assert effects == []
    assert m.run('initialize_empty_root') == {'schemaVersion': 1, 'state': 'empty_initialized'}
    assert effects == [('chmod', 0o750), ('chown', 1000, 1000), ('fsync',)]
    assert list(root.iterdir()) == []
    assert m.run('verify_root') == {'schemaVersion': 1, 'state': 'root_verified'}


@pytest.mark.parametrize('mode', ['check', 'initialize_empty_root'])
@pytest.mark.parametrize('kind', ['file', 'directory', 'symlink'])
def test_foreign_entry_never_changed_or_named(local, mode, kind):
    m, root, _, effects = local
    target = root / 'synthetic-private-name'
    if kind == 'file':
        target.write_text('do not alter')
    elif kind == 'directory':
        target.mkdir()
    else:
        target.symlink_to('/outside')
    with pytest.raises(m.BootstrapError, match='^bootstrap_conflict$'):
        m.run(mode)
    assert target.is_symlink() or target.exists()
    assert effects == []


@pytest.mark.parametrize('change', [{'uid': 1000}, {'gid': 1000}, {'mode': 0o750}, {'mode': 0o777}])
def test_initialize_requires_exact_uninitialized_root(local, change):
    m, _, state, effects = local
    state.update(change)
    with pytest.raises(m.BootstrapError, match='^bootstrap_conflict$'):
        m.run('initialize_empty_root')
    assert effects == []


def test_partial_metadata_failure_is_static_and_not_retried(local, monkeypatch):
    m, _, state, effects = local
    def fail(*_):
        raise OSError('synthetic private OS data')
    monkeypatch.setattr(m.os, 'fchown', fail)
    with pytest.raises(m.BootstrapError, match='^bootstrap_unavailable$'):
        m.run('initialize_empty_root')
    assert state['mode'] == 0o750 and effects == [('chmod', 0o750)]
    with pytest.raises(m.BootstrapError, match='^bootstrap_conflict$'):
        m.run('initialize_empty_root')
    assert effects == [('chmod', 0o750)]


def test_verify_allows_existing_app_data_without_walking_or_mutating(local):
    m, root, state, effects = local
    state.update(uid=1000, gid=1000, mode=0o750)
    (root / 'app-data').write_text('existing')
    assert m.run('verify_root')['state'] == 'root_verified'
    assert effects == [] and (root / 'app-data').read_text() == 'existing'


def test_directory_identity_drift_rejects_success(local, monkeypatch):
    m, _, _, _ = local
    original = m.os.fstat
    calls = 0
    def drift(fd):
        nonlocal calls
        value = original(fd)
        calls += 1
        if calls > 1:
            value.st_ino += 1
        return value
    monkeypatch.setattr(m.os, 'fstat', drift)
    with pytest.raises(m.BootstrapError, match='^bootstrap_conflict$'):
        m.run('check')


def test_root_fd_closed_on_success_and_failure(local, monkeypatch):
    m, root, _, _ = local
    actual = os.open
    captured = []
    def opened():
        fd = actual(root, os.O_RDONLY | os.O_DIRECTORY)
        captured.append(fd)
        return fd
    monkeypatch.setattr(m, '_open_root', opened)
    m.run('check')
    (root / 'foreign').touch()
    with pytest.raises(m.BootstrapError):
        m.run('initialize_empty_root')
    for fd in captured:
        with pytest.raises(OSError):
            os.fstat(fd)


@pytest.mark.parametrize('arguments', [[], ['initialize_empty_root', '/tmp'], ['delete'], ['--path', '/volume']])
def test_cli_has_no_caller_path_or_generic_command(arguments, capsys, monkeypatch):
    m = api()
    monkeypatch.setattr(m, '_open_root', lambda: pytest.fail('invalid CLI opened storage'))
    assert m.main(arguments) == 2
    output = capsys.readouterr()
    assert output.out == '' and output.err == 'bootstrap_invalid_command\n'


def test_cli_emits_only_closed_json(local, capsys):
    m, _, _, _ = local
    assert m.main(['check']) == 0
    output = capsys.readouterr()
    assert json.loads(output.out) == {'schemaVersion': 1, 'state': 'empty_uninitialized'}
    assert output.err == ''


def test_native_mount_gate_rejects_regular_directory_and_symlink(tmp_path, monkeypatch):
    m = api()
    root = tmp_path / 'not-a-volume'
    root.mkdir()
    monkeypatch.setattr(m, '_ROOT', str(root))
    with pytest.raises(m.BootstrapError):
        m.run('check')
    link = tmp_path / 'link'
    link.symlink_to(root)
    monkeypatch.setattr(m, '_ROOT', str(link))
    with pytest.raises(m.BootstrapError):
        m.run('check')


def test_dockerfile_pins_existing_base_and_has_no_volume_or_remote_run():
    root = Path(__file__).resolve().parents[2]
    path = root / 'server/Dockerfile.volume-bootstrap'
    assert path.exists(), 'own helper image build is absent'
    source = path.read_text()
    assert 'python:3.12.14-slim-bookworm@sha256:782412e85d0f0984994c290652577d4018aff08145c85b262bb63dc0c7522254' in source
    assert not re.search(r'^VOLUME\s', source, re.MULTILINE)
    assert 'ADD http' not in source and 'curl ' not in source
    assert 'tool/volume_bootstrap_helper.py' in source
