import hashlib
import json

from conftest import auth, ready


def test_normal_core_pantry_write_and_cooking_deduction_are_atomic(server):
    app, client, _settings, _clock = server
    actor = ready(server)
    headers = auth(actor)
    context = app.state.core.context
    pantry = f"/api/v1/pantry/{context.coreId}/{context.homeId}"

    received = client.post(
        pantry + "/receive",
        headers=headers,
        json={
            "schemaVersion": 1,
            "requestId": "1" * 32,
            "expectedRevision": 0,
            "lot": {
                "schemaVersion": 1,
                "id": "a" * 32,
                "ingredientKey": "flour",
                "amount": {
                    "schemaVersion": 1,
                    "quantityMillis": 1000,
                    "unit": "g",
                },
                "expiresOn": "2026-10-31",
            },
        },
    )
    assert received.status_code == 201, received.text
    assert received.json()["snapshot"]["revision"] == 1

    created = client.post(
        "/api/v1/cooking/sessions",
        headers=headers,
        json={
            "schemaVersion": 1,
            "recipeId": "recipe.normal-core-gate",
            "recipeRevision": 7,
            "title": "Acceptance bread",
            "steps": ["Prepare dough", "Bake"],
        },
    )
    assert created.status_code == 201, created.text
    document = created.json()["session"]
    moved = client.put(
        f"/api/v1/cooking/sessions/{document['id']}/step",
        headers=headers,
        json={"schemaVersion": 1, "expectedRevision": 1, "step": 1},
    )
    assert moved.status_code == 200, moved.text
    document = moved.json()["session"]
    item = {"stockItemId": "flour", "quantityMicros": 250, "unit": "g"}
    canonical = json.dumps(
        [
            "larenor-ingredient-deduction-v1",
            actor["user"]["id"],
            document["id"],
            7,
            1,
            document["revision"],
            1,
            [["flour", 250, "g"]],
        ],
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode("utf-8")
    body = {
        "schemaVersion": 1,
        "idempotencyKey": hashlib.sha256(canonical).hexdigest(),
        "recipeRevision": 7,
        "completedStep": 1,
        "stepRevision": document["revision"],
        "expectedPantryRevision": 1,
        "items": [item],
    }
    endpoint = (
        f"/api/v1/cooking/{context.coreId}/{context.homeId}/sessions/"
        f"{document['id']}/ingredient-deductions"
    )
    applied = client.post(endpoint, headers=headers, json=body)
    assert applied.status_code == 200, applied.text
    assert applied.json()["receipt"]["pantryRevision"] == 2
    replay = client.post(endpoint, headers=headers, json=body)
    assert replay.status_code == 200
    assert replay.json() == applied.json()

    snapshot = client.get(pantry, headers=headers)
    assert snapshot.status_code == 200
    assert snapshot.json()["snapshot"] == {
        "schemaVersion": 1,
        "revision": 2,
        "lots": [
            {
                "schemaVersion": 1,
                "lotId": "a" * 32,
                "ingredientKey": "flour",
                "measure": "mass_mg",
                "remaining": 750,
                "expiresOn": "2026-10-31",
            }
        ],
    }
