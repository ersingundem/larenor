"""Fixture-only probe against synthetic local files/HTTP; never physical data."""
import importlib
import importlib.util
import json
import os
from pathlib import Path

import pytest


def api():
    name = 'tool.jellyfin_storage_probe'
    assert importlib.util.find_spec(name) is not None, 'fixed characterization probe is absent'
    return importlib.import_module(name)


def test_seed_is_exclusive_and_restart_verify_preserves_bytes(tmp_path, monkeypatch):
    m = api()
    monkeypatch.setattr(m, '_ROOT', str(tmp_path))
    monkeypatch.setattr(m.os, 'geteuid', lambda:1000)
    monkeypatch.setattr(m.os, 'getegid', lambda:1000)
    assert m.run('write_sentinel') == {'sentinel': 'verified', 'uid':1000,'gid':1000}
    snapshot = {p.name:p.read_bytes() for p in tmp_path.iterdir()}
    assert m.run('verify_sentinel') == {'sentinel': 'verified', 'uid':1000,'gid':1000}
    assert {p.name:p.read_bytes() for p in tmp_path.iterdir()} == snapshot
    with pytest.raises(m.ProbeError):
        m.run('write_sentinel')


def test_write_permission_probe_only_removes_its_exclusive_file(tmp_path, monkeypatch):
    m = api()
    monkeypatch.setattr(m, '_ROOT', str(tmp_path))
    result = m.run('writable')
    assert result['writable'] is True and list(tmp_path.iterdir()) == []
    (tmp_path / m._WRITE_TEST).write_text('foreign')
    with pytest.raises(m.ProbeError):
        m.run('writable')
    assert (tmp_path / m._WRITE_TEST).read_text() == 'foreign'


def test_permission_denial_is_distinguished_from_other_io_failure(tmp_path, monkeypatch):
    m = api()
    monkeypatch.setattr(m, '_ROOT', str(tmp_path))
    original = m.os.open
    def denied(path, flags, *args, **kwargs):
        if path == m._WRITE_TEST:
            raise PermissionError()
        return original(path, flags, *args, **kwargs)
    monkeypatch.setattr(m.os, 'open', denied)
    assert m.run('writable')['writable'] is False


def test_initial_data_requires_real_sqlite_header_and_nonempty_system_xml(tmp_path, monkeypatch):
    m = api()
    monkeypatch.setattr(m, '_ROOT', str(tmp_path))
    (tmp_path/'data').mkdir()
    (tmp_path/'config').mkdir()
    (tmp_path/'data/jellyfin.db').write_bytes(b'SQLite format 3\x00'+b'0'*128)
    (tmp_path/'config/system.xml').write_bytes(b'<ServerConfiguration/>')
    assert m.run('initial_data') == {'database':True,'configuration':True}
    (tmp_path/'data/jellyfin.db').write_bytes(b'not sqlite')
    with pytest.raises(m.ProbeError):
        m.run('initial_data')


def test_symlink_data_is_never_followed(tmp_path, monkeypatch):
    m = api()
    monkeypatch.setattr(m, '_ROOT', str(tmp_path))
    (tmp_path/'data').symlink_to(tmp_path, target_is_directory=True)
    with pytest.raises(m.ProbeError):
        m.run('initial_data')


@pytest.mark.parametrize('mode', ['shell','/tmp','delete',''])
def test_closed_probe_cli(mode, capsys):
    m = api()
    assert m.main([mode]) == 2
    assert capsys.readouterr().err == 'fixture_probe_invalid\n'


def test_health_bound_to_loopback_no_proxy_or_redirect(monkeypatch):
    m = api()
    requests = []
    def read(path):
        requests.append(path)
        return b'Healthy' if path == '/health' else json.dumps({
            'Id':'a'*32,'Version':'10.11.11','StartupWizardCompleted':False}).encode()
    monkeypatch.setattr(m, '_read', read)
    assert m.run('health') == {'id':'a'*32,'version':'10.11.11','wizardCompleted':False}
    assert requests == ['/health','/System/Info/Public']
    with pytest.raises(m.ProbeError):
        m.NoRedirect().redirect_request(None,None,302,'',{},'http://outside')
