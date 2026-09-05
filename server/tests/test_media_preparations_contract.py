"""The same actual HTTP responses are consumed by Python and Dart tests."""

import json
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from uuid import UUID

from fastapi.testclient import TestClient

from conftest import Clock, auth, ready
from test_media_preparations_api import BASE, create_preparation
from larenor_server.app import create_app
from larenor_server.config import Settings


FIXTURE = Path(__file__).resolve().parents[2] / "contracts/media-preparations.v1.json"


def actual_journey(root, *, core_id="a" * 32, home_id="b" * 32, preparation_id="c" * 32):
    identities = iter((core_id, home_id))
    clock = Clock()
    settings = Settings(root / "data", root / "secrets/vault.key", clock=clock)
    with patch("larenor_server.context.secrets", SimpleNamespace(token_hex=lambda _: next(identities))):
        app = create_app(settings)
        with TestClient(app) as client:
            pair = ready((app, client, settings, clock))
            context = client.get("/api/v1/context", headers=auth(pair)).json()
            catalog = client.get("/api/v1/admin/plugins/catalog", headers=auth(pair)).json()
            with patch("larenor_server.plugins.media_preparations.uuid",
                       SimpleNamespace(uuid4=lambda: UUID(hex=preparation_id))):
                body, prepared = create_preparation(client, pair)
            listing = client.get(BASE, headers=auth(pair)).json()
            cancelled = client.post(BASE + "/" + prepared["id"] + "/cancel", headers=auth(pair),
                                    json={"expectedRevision": 1}).json()["preparation"]
            return {"context": context, "catalog": catalog, "createRequest": body,
                    "prepared": prepared, "cancelled": cancelled, "list": listing}


def test_shared_media_preparation_contract_matches_actual_authenticated_http(tmp_path):
    expected = json.loads(FIXTURE.read_text())
    assert actual_contract(tmp_path.resolve()) == expected


def actual_contract(root):
    contract = actual_journey(root / "first")
    contract["otherContextPrepared"] = actual_journey(
        root / "other", core_id="d" * 32, home_id="e" * 32, preparation_id="f" * 32)["prepared"]
    return contract
