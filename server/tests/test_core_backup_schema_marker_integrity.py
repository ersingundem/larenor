"""Fail-closed S09.1 component schema marker capture."""

import pytest
from conftest import auth, ready

PASSPHRASE = "Correct horse battery staple 2026"


def _plan(client, pair):
    response = client.get("/api/v1/admin/backups/plan", headers=auth(pair))
    assert response.status_code == 200
    return response.json()["manifest"]


@pytest.mark.parametrize(
    ("corruption", "key", "value"),
    (
        ("noncanonical-value", "plugins_schema", "01"),
        ("out-of-range-value", "plugins_schema", str(2**31)),
        ("unsafe-key", "private-path_schema", "1"),
    ),
)
def test_schema_marker_corruption_blocks_every_backup_contract_endpoint(
    server, corruption, key, value
):
    app, client, _settings, _clock = server
    pair = ready(server)
    compatible_manifest = _plan(client, pair)
    with app.state.core.db.transaction() as connection:
        if corruption == "unsafe-key":
            connection.execute(
                "INSERT INTO metadata(key,value) VALUES(?,?)",
                (key, value),
            )
        else:
            connection.execute(
                "UPDATE metadata SET value=? WHERE key=?",
                (value, key),
            )

    responses = (
        client.get("/api/v1/admin/backups/plan", headers=auth(pair)),
        client.post(
            "/api/v1/admin/backups/export",
            headers=auth(pair),
            json={"passphrase": PASSPHRASE},
        ),
        client.post(
            "/api/v1/admin/backups/restore/validate",
            headers=auth(pair),
            json={"manifest": compatible_manifest},
        ),
    )

    for response in responses:
        assert response.status_code == 503
        assert response.json()["error"] == {
            "code": "server_unavailable",
            "message": "The service is temporarily unavailable.",
        }
        assert key not in response.text
        assert value not in response.text
