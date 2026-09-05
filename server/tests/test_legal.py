import pytest
from fastapi.testclient import TestClient

from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.errors import StartupError
from larenor_server.legal import SourceInformation


def test_source_offer_is_public_without_exposing_runtime_configuration(server):
    app, client, settings, _ = server
    response = client.get("/api/v1/source")
    assert response.status_code == 200
    assert response.json() == {
        "service": "larenor-server", "version": "0.1.0", "license": "AGPL-3.0-only",
        "sourceUrl": "https://github.com/ersingundem/larenor",
        "sourceRevision": None,
        "licenseUrl": "https://github.com/ersingundem/larenor/blob/main/LICENSE",
    }
    assert str(settings.data_dir) not in response.text
    assert str(settings.key_file) not in response.text
    assert app.openapi()["info"]["license"]["identifier"] == "AGPL-3.0-only"
    assert client.get("/api/v1/openapi.json").status_code == 401


def test_fork_build_reports_its_actual_source_and_revision(tmp_path, monkeypatch):
    revision = "a" * 40
    monkeypatch.setenv("LARENOR_SOURCE_URL", f"https://github.com/example/fork/tree/{revision}")
    monkeypatch.setenv("LARENOR_SOURCE_REVISION", revision)
    monkeypatch.setenv("LARENOR_LICENSE_URL", f"https://github.com/example/fork/blob/{revision}/LICENSE")
    settings = Settings(tmp_path.resolve() / "data", tmp_path.resolve() / "secrets/key")
    with TestClient(create_app(settings)) as client:
        body = client.get("/api/v1/source").json()
        assert body["sourceRevision"] == revision
        assert body["sourceUrl"].endswith(f"/fork/tree/{revision}")
        assert body["licenseUrl"].endswith(f"/fork/blob/{revision}/LICENSE")


@pytest.mark.parametrize("url", [
    "http://example.com/source", "https://example.com/?token=synthetic",
    "https://user:synthetic@example.com/source", "https://example.com/#synthetic",
    "https://example.com:broken/source", "https://example.com/\nsource",
])
def test_invalid_public_urls_fail_with_static_errors(url):
    with pytest.raises(StartupError, match="^source_url_invalid$"):
        SourceInformation(source_url=url)


def test_invalid_source_revision_is_not_repeated_in_an_error():
    with pytest.raises(StartupError, match="^source_revision_invalid$"):
        SourceInformation(source_revision="synthetic-invalid-value")
