from dataclasses import dataclass

import pytest
from fastapi.testclient import TestClient

from larenor_server.app import create_app
from larenor_server.config import Settings


@dataclass
class Clock:
    now: float = 1788609600.0

    def __call__(self):
        return self.now


@pytest.fixture
def server(tmp_path):
    root = tmp_path.resolve()
    clock = Clock()
    settings = Settings(root / "data", root / "secrets/vault.key", clock=clock,
                        login_ip_limit=100, login_account_limit=100, login_global_limit=100)
    app = create_app(settings)
    with TestClient(app) as client:
        yield app, client, settings, clock


def login(client, username, password, device="Test tablet"):
    return client.post("/api/v1/auth/login", json={"username": username, "password": password, "deviceName": device})


def bootstrap_password(settings):
    return settings.effective_bootstrap_file.read_text().split("password: ", 1)[1].strip()


def auth(pair):
    return {"Authorization": "Bearer " + pair["accessToken"]}


def ready(server):
    _app, client, settings, _clock = server
    initial_password = bootstrap_password(settings)
    initial = login(client, "admin", initial_password).json()
    changed = client.post("/api/v1/auth/password", headers=auth(initial),
                          json={"currentPassword": initial_password, "newPassword": "Synthetic new password 2026"})
    assert changed.status_code == 200
    return changed.json()


def document(secret="synthetic-only-token"):
    return {"version": 1, "snapshot": {
        "version": 2, "createdAt": "2026-09-05T12:00:00Z",
        "groups": {"privacy": {"version": 1, "entityIds": ["sensor.fixture_mass"], "reviewRequired": True},
                   "settings": {"appearance": "dark"},
                   "connections": {"ha": {"baseUrl": "http://fixture.invalid:8123", "token": secret}}}}}
