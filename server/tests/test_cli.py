from larenor_server import cli
from larenor_server.config import Settings

from conftest import bootstrap_password


def test_initialize_only_prints_private_file_location_never_password_or_key(tmp_path, monkeypatch, capsys):
    root = tmp_path.resolve()
    settings = Settings(root / "data", root / "secrets/vault.key")
    monkeypatch.setattr(Settings, "from_environment", classmethod(lambda _cls: settings))
    assert cli.main(["--initialize-only"]) == 0
    output = capsys.readouterr()
    assert str(settings.effective_bootstrap_file) in output.out
    assert bootstrap_password(settings) not in output.out + output.err
    assert settings.key_file.read_bytes().hex() not in output.out + output.err
    assert cli.main(["--initialize-only"]) == 0
    assert capsys.readouterr().out == ""


def test_invalid_key_error_has_static_code_without_path_or_secret(tmp_path, monkeypatch, capsys):
    root = tmp_path.resolve()
    settings = Settings(root / "data", root / "secrets/vault.key")
    monkeypatch.setattr(Settings, "from_environment", classmethod(lambda _cls: settings))
    assert cli.main(["--initialize-only"]) == 0
    capsys.readouterr()
    settings.key_file.write_bytes(b"synthetic-secret-invalid-key")
    assert cli.main(["--initialize-only"]) == 1
    output = capsys.readouterr()
    assert output.out == ""
    assert output.err == "Larenor Server initialization failed: vault_key_invalid\n"
    assert "synthetic" not in output.err
