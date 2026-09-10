"""Local FD fixtures only; no real volume, ownership change or Docker."""
import importlib
import importlib.util
import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import sys
from types import SimpleNamespace

import pytest

from larenor_server.plugins.arr_owned_config import render_arr_owned_config
from larenor_server.plugins.qbittorrent_owned_config import (
    render_qbittorrent_owned_config,
)

# Collected by the pinned Server pytest job, not dependency-free tool unittest.
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
_REAL_FSTAT = os.fstat


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


def test_media_directories_are_fixed_idempotent_and_preserve_unrelated_entries(local, monkeypatch):
    m, root, state, effects = local
    state.update(uid=1000, gid=1000, mode=0o750)
    monkeypatch.setattr(m.os, 'geteuid', lambda: 1000)
    monkeypatch.setattr(m.os, 'getegid', lambda: 1000)
    (root / 'unrelated').write_text('keep')
    assert m.run('prepare_media_directories') == {
        'schemaVersion': 1, 'state': 'media_directories_prepared',
    }
    assert {item.name for item in root.iterdir()} == {'movies', 'shows', 'unrelated'}
    assert stat.S_IMODE((root / 'movies').stat().st_mode) == 0o750
    assert stat.S_IMODE((root / 'shows').stat().st_mode) == 0o750
    assert m.run('prepare_media_directories')['state'] == 'media_directories_prepared'
    assert (root / 'unrelated').read_text() == 'keep' and effects == [('fsync',), ('fsync',)]


@pytest.mark.parametrize('name', ['movies', 'shows'])
def test_media_directory_symlink_or_wrong_metadata_is_rejected(local, name, monkeypatch):
    m, root, state, _effects = local
    state.update(uid=1000, gid=1000, mode=0o750)
    monkeypatch.setattr(m.os, 'geteuid', lambda: 1000)
    monkeypatch.setattr(m.os, 'getegid', lambda: 1000)
    (root / name).symlink_to('/outside')
    with pytest.raises(m.BootstrapError, match='^bootstrap_conflict$'):
        m.run('prepare_media_directories')


def owned_config():
    return render_qbittorrent_owned_config(
        'p' * 40, api_key='qbt_' + 'k' * 28,
        salt=bytes(range(16))).configuration


def arr_config(service_id):
    return render_arr_owned_config(
        service_id, '01234567' * 4).configuration


def config_local(local, monkeypatch):
    m, root, state, effects = local
    state.update(uid=1000, gid=1000, mode=0o750)
    monkeypatch.setattr(m.os, 'geteuid', lambda: 1000)
    monkeypatch.setattr(m.os, 'getegid', lambda: 1000)
    root_identity = (root.stat().st_dev, root.stat().st_ino)
    def metadata(fd):
        value = _REAL_FSTAT(fd)
        mode = stat.S_IMODE(value.st_mode)
        if (value.st_dev, value.st_ino) == root_identity:
            mode = 0o750
        if stat.S_ISREG(value.st_mode):
            return SimpleNamespace(
                st_dev=value.st_dev, st_ino=value.st_ino,
                st_uid=1000, st_gid=1000, st_mode=stat.S_IFREG | mode,
                st_nlink=value.st_nlink, st_size=value.st_size)
        return SimpleNamespace(
            st_dev=value.st_dev, st_ino=value.st_ino,
            st_uid=1000, st_gid=1000, st_mode=stat.S_IFDIR | mode,
            st_nlink=value.st_nlink, st_size=value.st_size)
    monkeypatch.setattr(m.os, 'fstat', metadata)
    return m, root, effects


def test_qbittorrent_config_is_written_atomically_to_one_fixed_private_file(local, monkeypatch):
    m, root, effects = config_local(local, monkeypatch)
    configuration = owned_config()

    result = m.run('install_qbittorrent_config', io.BytesIO(configuration))

    target = root / 'qBittorrent' / 'qBittorrent.conf'
    assert result == {
        'schemaVersion': 1,
        'state': 'qbittorrent_config_installed',
        'sha256': hashlib.sha256(configuration).hexdigest(),
    }
    assert target.read_bytes() == configuration
    assert stat.S_IMODE(target.stat().st_mode) == 0o600
    assert stat.S_IMODE(target.parent.stat().st_mode) == 0o750
    assert not (target.parent / '.larenor-qbittorrent-config.tmp').exists()
    assert effects == [('fsync',), ('fsync',), ('fsync',)]


def test_exact_qbittorrent_config_is_idempotent_and_wrong_existing_file_is_preserved(local, monkeypatch):
    m, root, _effects = config_local(local, monkeypatch)
    configuration = owned_config()
    m.run('install_qbittorrent_config', io.BytesIO(configuration))
    target = root / 'qBittorrent' / 'qBittorrent.conf'
    before = target.stat()
    assert m.run('install_qbittorrent_config', io.BytesIO(configuration))['state'] == \
        'qbittorrent_config_already_installed'
    assert target.stat().st_ino == before.st_ino
    target.write_bytes(b'foreign')
    with pytest.raises(m.BootstrapError, match='^bootstrap_conflict$'):
        m.run('install_qbittorrent_config', io.BytesIO(configuration))
    assert target.read_bytes() == b'foreign'


@pytest.mark.parametrize('configuration', [
    b'', b'x' * 4097, b'not-qbittorrent\n',
    owned_config().replace(b'WebUI\\CSRFProtection=true', b'WebUI\\CSRFProtection=false'),
    owned_config().replace(
        b'WebUI\\APIKey=qbt_' + b'k' * 28, b'WebUI\\APIKey=short'),
    owned_config() + b'Hidden\\Option=true\n',
])
def test_invalid_qbittorrent_config_never_creates_storage(local, monkeypatch, configuration):
    m, root, _effects = config_local(local, monkeypatch)
    with pytest.raises(m.BootstrapError, match='^bootstrap_conflict$'):
        m.run('install_qbittorrent_config', io.BytesIO(configuration))
    assert list(root.iterdir()) == []


@pytest.mark.parametrize('kind', ['directory', 'symlink'])
def test_qbittorrent_config_target_type_conflict_is_never_replaced(local, monkeypatch, kind):
    m, root, _effects = config_local(local, monkeypatch)
    directory = root / 'qBittorrent'
    directory.mkdir(mode=0o750)
    target = directory / 'qBittorrent.conf'
    if kind == 'directory':
        target.mkdir()
    else:
        target.symlink_to('/outside')
    with pytest.raises(m.BootstrapError, match='^bootstrap_conflict$'):
        m.run('install_qbittorrent_config', io.BytesIO(owned_config()))
    assert target.is_symlink() or target.is_dir()


@pytest.mark.parametrize('kind', ['file', 'symlink', 'wrong_mode'])
def test_qbittorrent_config_parent_conflict_is_never_changed(local, monkeypatch, kind):
    m, root, _effects = config_local(local, monkeypatch)
    directory = root / 'qBittorrent'
    if kind == 'file':
        directory.write_bytes(b'foreign')
    elif kind == 'symlink':
        directory.symlink_to('/outside')
    else:
        directory.mkdir(mode=0o755)
    with pytest.raises(m.BootstrapError, match='^bootstrap_conflict$'):
        m.run('install_qbittorrent_config', io.BytesIO(owned_config()))
    assert directory.is_symlink() or directory.exists()


def test_qbittorrent_config_stale_temporary_file_requires_review(local, monkeypatch):
    m, root, _effects = config_local(local, monkeypatch)
    directory = root / 'qBittorrent'
    directory.mkdir(mode=0o750)
    temporary = directory / '.larenor-qbittorrent-config.tmp'
    temporary.write_bytes(b'preserve')
    with pytest.raises(m.BootstrapError, match='^bootstrap_conflict$'):
        m.run('install_qbittorrent_config', io.BytesIO(owned_config()))
    assert temporary.read_bytes() == b'preserve'
    assert not (directory / 'qBittorrent.conf').exists()


def test_qbittorrent_config_input_failure_is_closed_before_storage(local, monkeypatch):
    m, root, _effects = config_local(local, monkeypatch)
    class BrokenInput:
        def read(self, _limit):
            raise OSError('synthetic private input detail')
    with pytest.raises(m.BootstrapError, match='^bootstrap_unavailable$'):
        m.run('install_qbittorrent_config', BrokenInput())
    assert list(root.iterdir()) == []


def test_qbittorrent_config_cli_reads_only_stdin_and_emits_no_secret(local, monkeypatch, capsys):
    m, _root, _effects = config_local(local, monkeypatch)
    configuration = owned_config()
    monkeypatch.setattr(m.sys, 'stdin', SimpleNamespace(buffer=io.BytesIO(configuration)))
    assert m.main(['install_qbittorrent_config']) == 0
    output = capsys.readouterr()
    assert json.loads(output.out) == {
        'schemaVersion': 1,
        'state': 'qbittorrent_config_installed',
        'sha256': hashlib.sha256(configuration).hexdigest(),
    }
    assert b'WebUI' not in output.out.encode()
    assert output.err == ''


@pytest.mark.parametrize('service_id,mode', [
    ('sonarr', 'install_sonarr_config'),
    ('radarr', 'install_radarr_config'),
])
def test_arr_config_is_written_atomically_to_one_fixed_private_file(
        local, monkeypatch, service_id, mode):
    m, root, effects = config_local(local, monkeypatch)
    configuration = arr_config(service_id)

    result = m.run(mode, io.BytesIO(configuration))

    target = root / 'config.xml'
    assert result == {
        'schemaVersion': 1,
        'state': f'{service_id}_config_installed',
        'sha256': hashlib.sha256(configuration).hexdigest(),
    }
    assert target.read_bytes() == configuration
    assert stat.S_IMODE(target.stat().st_mode) == 0o600
    assert not (root / '.larenor-arr-config.tmp').exists()
    assert effects == [('fsync',), ('fsync',)]


@pytest.mark.parametrize('service_id,mode', [
    ('sonarr', 'install_sonarr_config'),
    ('radarr', 'install_radarr_config'),
])
def test_arr_config_is_idempotent_and_foreign_existing_file_is_preserved(
        local, monkeypatch, service_id, mode):
    m, root, _effects = config_local(local, monkeypatch)
    configuration = arr_config(service_id)
    m.run(mode, io.BytesIO(configuration))
    target = root / 'config.xml'
    before = target.stat()
    assert m.run(mode, io.BytesIO(configuration))['state'] == \
        f'{service_id}_config_already_installed'
    assert target.stat().st_ino == before.st_ino
    target.write_bytes(b'foreign')
    with pytest.raises(m.BootstrapError, match='^bootstrap_conflict$'):
        m.run(mode, io.BytesIO(configuration))
    assert target.read_bytes() == b'foreign'


@pytest.mark.parametrize('mode,configuration', [
    ('install_sonarr_config', b''),
    ('install_sonarr_config', b'x' * 4097),
    ('install_sonarr_config', arr_config('radarr')),
    ('install_radarr_config', arr_config('sonarr')),
    ('install_radarr_config', arr_config('radarr') + b'<Hidden/>\n'),
    ('install_sonarr_config', arr_config('sonarr').replace(
        b'<UpdateAutomatically>False', b'<UpdateAutomatically>True')),
])
def test_invalid_arr_config_never_creates_storage(
        local, monkeypatch, mode, configuration):
    m, root, _effects = config_local(local, monkeypatch)
    with pytest.raises(m.BootstrapError, match='^bootstrap_conflict$'):
        m.run(mode, io.BytesIO(configuration))
    assert list(root.iterdir()) == []


@pytest.mark.parametrize('kind', ['directory', 'symlink'])
def test_arr_config_target_type_conflict_is_never_replaced(
        local, monkeypatch, kind):
    m, root, _effects = config_local(local, monkeypatch)
    target = root / 'config.xml'
    if kind == 'directory':
        target.mkdir()
    else:
        target.symlink_to('/outside')
    with pytest.raises(m.BootstrapError, match='^bootstrap_conflict$'):
        m.run('install_sonarr_config', io.BytesIO(arr_config('sonarr')))
    assert target.is_symlink() or target.is_dir()


@pytest.mark.parametrize('conflict', ['wrong_mode', 'hardlink'])
def test_arr_config_existing_file_metadata_conflict_is_preserved(
        local, monkeypatch, conflict):
    m, root, _effects = config_local(local, monkeypatch)
    target = root / 'config.xml'
    target.write_bytes(arr_config('sonarr'))
    if conflict == 'wrong_mode':
        target.chmod(0o640)
    else:
        target.chmod(0o600)
        os.link(target, root / 'foreign-link')
    before = target.read_bytes()
    with pytest.raises(m.BootstrapError, match='^bootstrap_conflict$'):
        m.run('install_sonarr_config', io.BytesIO(arr_config('sonarr')))
    assert target.read_bytes() == before
    assert stat.S_IMODE(target.stat().st_mode) == (
        0o640 if conflict == 'wrong_mode' else 0o600)


def test_arr_config_stale_temporary_file_requires_review(local, monkeypatch):
    m, root, _effects = config_local(local, monkeypatch)
    temporary = root / '.larenor-arr-config.tmp'
    temporary.write_bytes(b'preserve')
    with pytest.raises(m.BootstrapError, match='^bootstrap_conflict$'):
        m.run('install_radarr_config', io.BytesIO(arr_config('radarr')))
    assert temporary.read_bytes() == b'preserve'
    assert not (root / 'config.xml').exists()


@pytest.mark.parametrize('service_id,mode', [
    ('sonarr', 'install_sonarr_config'),
    ('radarr', 'install_radarr_config'),
])
def test_arr_config_cli_reads_only_stdin_and_emits_no_secret(
        local, monkeypatch, capsys, service_id, mode):
    m, _root, _effects = config_local(local, monkeypatch)
    configuration = arr_config(service_id)
    monkeypatch.setattr(
        m.sys, 'stdin', SimpleNamespace(buffer=io.BytesIO(configuration)))
    assert m.main([mode]) == 0
    output = capsys.readouterr()
    assert json.loads(output.out) == {
        'schemaVersion': 1,
        'state': f'{service_id}_config_installed',
        'sha256': hashlib.sha256(configuration).hexdigest(),
    }
    assert b'<ApiKey>' not in output.out.encode()
    assert output.err == ''


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
