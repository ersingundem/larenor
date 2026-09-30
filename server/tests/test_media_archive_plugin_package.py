import importlib.util
import io
import json
import zipfile

from larenor_server.media_archive_actions.plugin_package import callback_plugin_package, main


def test_packaged_plugin_imports_standalone_and_preserves_event_contract(tmp_path, monkeypatch):
    monkeypatch.delenv('LARENOR_UNMANIC_CALLBACK_CONFIG', raising=False)
    first = callback_plugin_package()
    assert first == callback_plugin_package()
    with zipfile.ZipFile(io.BytesIO(first)) as archive:
        assert archive.namelist() == ['info.json', 'plugin.py', 'description.md']
        metadata = json.loads(archive.read('info.json'))
        assert metadata['compatibility'] == [2]
        assert metadata['priorities'] == {'emit_postprocessor_complete': 0}
        path = tmp_path / 'plugin.py'
        path.write_bytes(archive.read('plugin.py'))
    spec = importlib.util.spec_from_file_location('standalone_larenor_unmanic_test', path)
    plugin = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(plugin)
    assert callable(plugin.emit_postprocessor_complete)
    assert plugin._PLUGIN is None
    # Importing the packaged module does not require Larenor/Pydantic imports.
    assert all('larenor_server' not in name for name in plugin.__dict__)


def test_packager_never_replaces_an_existing_artifact(tmp_path, capsys):
    output = tmp_path / 'plugin.zip'
    assert main(['--output', str(output)]) == 0
    original = output.read_bytes()
    assert main(['--output', str(output)]) == 2
    assert output.read_bytes() == original
    assert 'archive_callback_package_unavailable' in capsys.readouterr().err
