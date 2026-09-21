import importlib.util
from pathlib import Path


def test_container_acceptance_script_runs_without_exposing_secrets(tmp_path, capsys):
    path = Path(__file__).parents[2] / "tool/server_restore_acceptance.py"
    spec = importlib.util.spec_from_file_location("server_restore_acceptance", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)

    module.run(tmp_path)

    output = capsys.readouterr()
    assert output.err == ""
    assert output.out == "Encrypted empty-target restore and restart passed.\n"
    assert module._PASSWORD not in output.out
    assert module._PASSPHRASE not in output.out
    assert module._TOKEN not in output.out
