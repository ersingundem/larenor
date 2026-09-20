from pathlib import Path

import pytest

from larenor_server.auth import Principal
from larenor_server.cooking.schema import migrate_cooking_sessions
from larenor_server.cooking.service import CookingSessionStore
from larenor_server.database import Database
from larenor_server.errors import ApiError


def actor(identifier: str) -> Principal:
    return Principal(identifier, identifier, "member", False, "family", "token")


def store(path: Path) -> CookingSessionStore:
    database = Database(path)
    if not path.exists():
        database.create_schema()
    with database.transaction() as connection:
        migrate_cooking_sessions(connection)
    return CookingSessionStore(database)


def test_account_owned_session_keeps_exact_recipe_revision_across_restart(tmp_path):
    path = tmp_path / "core.sqlite3"
    first = store(path)
    created = first.create(
        actor("account-a"), recipe_id="recipe-1", recipe_revision=7,
        title="Mercimek çorbası", steps=("Hazırla", "Pişir", "Dinlendir"),
    )
    moved = first.move(actor("account-a"), created.id, expected_revision=1, step=1)

    restored = store(path).get(actor("account-a"), created.id)
    assert (restored.recipe_id, restored.recipe_revision) == ("recipe-1", 7)
    assert (restored.revision, restored.current_step, restored.steps) == (
        moved.revision, 1, ("Hazırla", "Pişir", "Dinlendir"),
    )


def test_account_and_revision_are_fail_closed(tmp_path):
    sessions = store(tmp_path / "core.sqlite3")
    created = sessions.create(
        actor("account-a"), recipe_id="recipe-1", recipe_revision=4,
        title="Soup", steps=("One", "Two"),
    )

    with pytest.raises(ApiError, match="not_found"):
        sessions.get(actor("account-b"), created.id)
    with pytest.raises(ApiError, match="revision_conflict"):
        sessions.move(actor("account-a"), created.id, expected_revision=9, step=1)
    assert sessions.get(actor("account-a"), created.id).current_step == 0


def test_step_bounds_and_payload_limits_are_closed(tmp_path):
    sessions = store(tmp_path / "core.sqlite3")
    with pytest.raises(ApiError, match="invalid_request"):
        sessions.create(
            actor("account-a"), recipe_id="recipe-1", recipe_revision=1,
            title="Empty", steps=(),
        )
    created = sessions.create(
        actor("account-a"), recipe_id="recipe-1", recipe_revision=1,
        title="Soup", steps=("One",),
    )
    with pytest.raises(ApiError, match="invalid_request"):
        sessions.move(actor("account-a"), created.id, expected_revision=1, step=1)

