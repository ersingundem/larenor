"""Independent persistence/security checks using private SQLite and no host calls."""

from concurrent.futures import ThreadPoolExecutor
import json
import re
import sqlite3
from threading import Barrier

import pytest

from conftest import auth, ready
from test_admin import activate, create as create_user
from larenor_server.app import create_app
from larenor_server.errors import ApiError, StartupError
from larenor_server.plugins.media_models import CancelMediaPreparationRequest, CreateMediaPreparationRequest
from larenor_server.plugins.media_preparations import MediaPreparationManagement
from larenor_server.plugins.stack_plan import MediaStackSettings


BASE = "/api/v1/admin/media/preparations"


@pytest.fixture
def preparations(server):
    core = server[0].state.core
    pair = ready(server)
    return core.media_preparations, core.auth.authenticate(pair["accessToken"]), pair


def submission(manager, number=1, *, name=None):
    return CreateMediaPreparationRequest(
        requestId=f"{number:032x}", templateId="media", context=manager.context,
        catalogDigest=manager.plugins._catalog.digest, platform="linux/amd64",
        settings=MediaStackSettings(instanceName=name or f"house-{number}"),
    )


def saved_row(manager, identifier):
    with manager.db.connection() as connection:
        return dict(connection.execute("SELECT * FROM media_preparations WHERE id=?", (identifier,)).fetchone())


def count(manager):
    with manager.db.connection() as connection:
        return connection.execute("SELECT COUNT(*) FROM media_preparations").fetchone()[0]


def expect_error(code, action, status=None):
    with pytest.raises(ApiError) as caught:
        action()
    assert str(caught.value) == caught.value.code == code
    if status is not None:
        assert caught.value.status == status


def clone_manager(manager, server):
    return MediaPreparationManagement(manager.db, manager.auth, manager.settings,
                                      server[2].key_file.read_bytes(), manager.plugins, manager.context)


def test_payload_is_encrypted_with_fresh_nonce_after_cancellation_and_restart(server, preparations):
    manager, actor, _ = preparations
    body = submission(manager, name="private-synthetic")
    record = manager.create(actor, body)["preparation"]
    before = saved_row(manager, record["id"])
    for marker in (b"private-synthetic", b'"components"', record["plan"].planHash.encode(),
                   manager.context.homeId.encode(), b"ghcr.io"):
        assert marker not in before["ciphertext"]
    assert len(before["nonce"]) == 12 and len(before["ciphertext"]) > 16000
    cancelled = manager.cancel(actor, record["id"], CancelMediaPreparationRequest(expectedRevision=1))
    after = saved_row(manager, record["id"])
    assert before["nonce"] != after["nonce"] and before["ciphertext"] != after["ciphertext"]
    restarted = create_app(server[2]).state.core.media_preparations
    assert restarted.get(actor, record["id"]) == cancelled
    assert cancelled["preparation"]["plan"] == record["plan"]
    assert after["cancelled_by"] == actor.id


@pytest.mark.parametrize("field,value", [
    ("id", "e" * 32), ("sequence", 900), ("revision", 2), ("state", "cancelled"),
    ("actor_id", "e" * 32), ("actor_revision", 900), ("family_id", "e" * 32),
    ("request_id", "e" * 32), ("created_at", 1788609599), ("updated_at", 1788609601),
    ("cancelled_by", "e" * 32), ("nonce", b"n" * 12), ("ciphertext", b"c" * 17000),
    ("nonce", b"short"), ("ciphertext", b"short"), ("ciphertext", b"x" * 131073),
])
def test_every_bound_metadata_column_and_ciphertext_fail_closed(server, preparations, field, value):
    manager, actor, pair = preparations
    record = manager.create(actor, submission(manager))["preparation"]
    with manager.db.transaction() as connection:
        connection.execute(f"UPDATE media_preparations SET {field}=? WHERE id=?", (value, record["id"]))
    identifier = value if field == "id" else record["id"]
    expect_error("media_preparation_storage_unavailable", lambda: manager.get(actor, identifier), 503)
    expect_error("media_preparation_storage_unavailable", lambda: manager.list(actor), 503)
    response = server[1].get(BASE + "/" + identifier, headers=auth(pair))
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "media_preparation_storage_unavailable"
    assert "ciphertext" not in response.text and "SELECT" not in response.text
    with pytest.raises(StartupError, match="^invalid_media_preparations_storage$"):
        manager.validate_storage()
    assert count(manager) == 1


def test_ciphertext_and_nonce_cannot_be_transplanted_between_preparations(preparations):
    manager, actor, _ = preparations
    first, second = [manager.create(actor, submission(manager, n))["preparation"] for n in (1, 2)]
    source = saved_row(manager, first["id"])
    with manager.db.transaction() as connection:
        connection.execute("UPDATE media_preparations SET nonce=?,ciphertext=? WHERE id=?",
                           (source["nonce"], source["ciphertext"], second["id"]))
    assert manager.get(actor, first["id"])["preparation"] == first
    expect_error("media_preparation_storage_unavailable", lambda: manager.get(actor, second["id"]))


@pytest.mark.parametrize("mutation", ["request_id", "preparation_id", "context", "settings", "platform", "catalog", "hash", "unknown"])
def test_authenticated_payload_still_requires_matching_identity_request_and_self_hash(preparations, mutation):
    manager, actor, _ = preparations
    record = manager.create(actor, submission(manager))["preparation"]
    row = saved_row(manager, record["id"])
    payload = json.loads(manager._cipher.decrypt(row["nonce"], row["ciphertext"], manager._aad(row)))
    if mutation == "request_id":
        payload["request"]["requestId"] = "f" * 32
    elif mutation == "preparation_id":
        payload["plan"]["preparationId"] = "f" * 32
    elif mutation == "context":
        payload["request"]["context"]["homeId"] = "f" * 32
    elif mutation == "settings":
        payload["request"]["settings"]["instanceName"] = "changed"
    elif mutation == "platform":
        payload["request"]["platform"] = "linux/arm64"
    elif mutation == "catalog":
        payload["request"]["catalogDigest"] = "f" * 64
    elif mutation == "hash":
        payload["plan"]["planHash"] = "f" * 64
    else:
        payload["unexpected"] = "synthetic-private-content"
    ciphertext = manager._cipher.encrypt(row["nonce"], json.dumps(payload).encode(), manager._aad(row))
    with manager.db.transaction() as connection:
        connection.execute("UPDATE media_preparations SET ciphertext=? WHERE id=?", (ciphertext, record["id"]))
    expect_error("media_preparation_storage_unavailable", lambda: manager.get(actor, record["id"]), 503)


def test_historical_plan_survives_catalog_upgrade_without_rederivation(server, preparations, monkeypatch):
    manager, actor, _ = preparations
    body = submission(manager)
    record = manager.create(actor, body)["preparation"]
    # Model the package update boundary. History needs only the new catalog's
    # identity; it must not reinterpret or rederive the previously authenticated plan.
    newer = manager.plugins._catalog.model_copy(update={"digest": "f" * 64})
    monkeypatch.setattr("larenor_server.plugins.service.load_catalog", lambda: newer)

    def forbidden(*_args, **_kwargs):
        pytest.fail("Historical media preparation was rederived against a new catalog")

    monkeypatch.setattr("larenor_server.plugins.media_preparations.build_media_stack_plan", forbidden)
    monkeypatch.setattr("larenor_server.plugins.media_preparations.verify_media_stack_plan", forbidden)
    restarted = create_app(server[2]).state.core.media_preparations
    expected = record | {"catalogCurrent": False}
    assert restarted.get(actor, record["id"])["preparation"] == expected
    assert restarted.list(actor)["preparations"] == [expected]
    assert restarted.create(actor, body)["preparation"] == expected
    expect_error("media_catalog_changed", lambda: restarted.create(actor, body.model_copy(update={"requestId": "2" * 32})), 409)
    cancelled = restarted.cancel(actor, record["id"], CancelMediaPreparationRequest(expectedRevision=1))["preparation"]
    assert cancelled["catalogCurrent"] is False and cancelled["plan"] == record["plan"]


@pytest.mark.parametrize("change", ["logout", "rotated", "expired", "disabled", "demoted", "password_required"])
def test_current_authority_is_required_for_read_replay_and_cancel(server, preparations, change):
    manager, actor, pair = preparations
    body = submission(manager)
    record = manager.create(actor, body)["preparation"]
    if change == "logout":
        manager.auth.logout(actor)
    elif change == "rotated":
        manager.auth.refresh(pair["refreshToken"], "synthetic-test")
    elif change == "expired":
        server[3].now += server[2].access_ttl_seconds
    else:
        field, value = {"disabled": ("disabled", 1), "demoted": ("role", "member"),
                        "password_required": ("must_change_password", 1)}[change]
        with manager.db.transaction() as connection:
            connection.execute(f"UPDATE users SET {field}=? WHERE id=?", (value, actor.id))
    for action in (lambda: manager.get(actor, record["id"]), lambda: manager.list(actor),
                   lambda: manager.create(actor, body),
                   lambda: manager.cancel(actor, record["id"], CancelMediaPreparationRequest(expectedRevision=1))):
        expect_error("invalid_session", action, 401)
    assert saved_row(manager, record["id"])["state"] == "prepared" and count(manager) == 1


def test_request_ids_are_user_scoped_and_creator_session_deletion_does_not_destroy_history(server, preparations):
    manager, actor, pair = preparations
    body = submission(manager)
    first = manager.create(actor, body)["preparation"]
    create_user(server[1], pair, "other-admin", "admin")
    other = manager.auth.authenticate(activate(server[1], "other-admin")["accessToken"])
    other_body = body.model_copy(update={"settings": MediaStackSettings(instanceName="other-house")})
    second = manager.create(other, other_body)["preparation"]
    assert first["id"] != second["id"] and first["requestId"] == second["requestId"]
    with manager.db.transaction() as connection:
        connection.execute("DELETE FROM session_tokens WHERE family_id=?", (actor.family_id,))
        connection.execute("DELETE FROM session_families WHERE id=?", (actor.family_id,))
    manager.validate_storage()
    assert manager.get(other, first["id"])["preparation"] == first
    assert manager.cancel(other, first["id"], CancelMediaPreparationRequest(expectedRevision=1))["preparation"]["state"] == "cancelled"


def test_parallel_replay_across_manager_instances_commits_only_one_record(server, preparations):
    manager, actor, _ = preparations
    body = submission(manager)
    managers = [manager] + [clone_manager(manager, server) for _ in range(3)]
    barrier = Barrier(4)

    def run(current):
        barrier.wait(timeout=5)
        return current.create(actor, body)

    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(run, managers))
    assert all(result == results[0] for result in results) and count(manager) == 1


def test_parallel_cancel_accepts_one_revision_and_replay_never_resurrects(server, preparations):
    manager, actor, _ = preparations
    body = submission(manager)
    record = manager.create(actor, body)["preparation"]
    managers = [manager, clone_manager(manager, server)]
    barrier = Barrier(3)

    def cancel(current):
        barrier.wait(timeout=5)
        try:
            return current.cancel(actor, record["id"], CancelMediaPreparationRequest(expectedRevision=1))["preparation"]["state"]
        except ApiError as error:
            return error.code

    def replay():
        barrier.wait(timeout=5)
        return manager.create(actor, body)["preparation"]

    with ThreadPoolExecutor(max_workers=3) as pool:
        futures = [pool.submit(cancel, current) for current in managers]
        retried = pool.submit(replay)
        assert sorted(future.result(timeout=10) for future in futures) == ["cancelled", "revision_conflict"]
        assert retried.result(timeout=10)["id"] == record["id"]
    final = manager.create(actor, body)["preparation"]
    assert final["state"] == "cancelled" and final["revision"] == 2 and count(manager) == 1


def test_real_active_capacity_is_atomic_and_cancel_frees_only_active_slot(server, preparations):
    manager, actor, _ = preparations
    initial = [manager.create(actor, submission(manager, n))["preparation"] for n in range(1, 8)]
    barrier = Barrier(2)

    def create(number):
        barrier.wait(timeout=5)
        try:
            return clone_manager(manager, server).create(actor, submission(manager, number))["preparation"]["state"]
        except ApiError as error:
            return error.code

    with ThreadPoolExecutor(max_workers=2) as pool:
        assert sorted(pool.map(create, (8, 9))) == ["media_preparation_limit_reached", "prepared"]
    assert count(manager) == 8
    manager.cancel(actor, initial[0]["id"], CancelMediaPreparationRequest(expectedRevision=1))
    assert manager.create(actor, submission(manager, 10, name="house-1"))["preparation"]["state"] == "prepared"
    assert count(manager) == 9
    manager.validate_storage()


def test_real_history_capacity_256_preserves_replays_and_sequence_pagination(server, preparations):
    manager, actor, _ = preparations
    records = []
    for number in range(1, 257):
        # A regressing clock cannot alter the durable pagination ordering.
        server[3].now -= 1
        record = manager.create(actor, submission(manager, number))["preparation"]
        records.append(manager.cancel(actor, record["id"], CancelMediaPreparationRequest(expectedRevision=1))["preparation"])
    assert count(manager) == 256
    expect_error("media_preparation_limit_reached", lambda: manager.create(actor, submission(manager, 257)), 409)
    assert manager.create(actor, submission(manager, 1))["preparation"] == records[0]
    actual, before = [], None
    while True:
        page = manager.list(actor, before=before)
        assert 1 <= len(page["preparations"]) <= 10
        actual.extend(page["preparations"])
        before = page["nextBefore"]
        if before is None:
            break
    assert actual == list(reversed(records))
    manager.validate_storage()


def test_cancel_under_clock_regression_preserves_timestamp_and_plan(server, preparations):
    manager, actor, _ = preparations
    record = manager.create(actor, submission(manager))["preparation"]
    server[3].now -= 3600
    cancelled = manager.cancel(actor, record["id"], CancelMediaPreparationRequest(expectedRevision=1))["preparation"]
    assert cancelled["createdAt"] == cancelled["updatedAt"] == record["createdAt"]
    assert cancelled["plan"] == record["plan"]
    manager.validate_storage()


@pytest.mark.parametrize("options", [{"limit": True}, {"limit": 0}, {"limit": 11}, {"limit": 1.0},
                                     {"before": False}, {"before": 0}, {"before": 2**63}, {"before": "secret-cursor"}])
def test_paging_rejects_unbounded_or_coerced_parameters_without_echo(preparations, options):
    manager, actor, _ = preparations
    expect_error("invalid_request", lambda: manager.list(actor, **options), 400)


def test_migration_failure_rolls_back_table_marker_and_preserves_context(server, preparations, monkeypatch):
    manager, actor, _ = preparations
    original_context = manager.context
    key = server[2].key_file.read_bytes()
    with manager.db.transaction() as connection:
        connection.execute("DROP TABLE media_preparations")
        connection.execute("DELETE FROM metadata WHERE key='media_preparations_schema'")
    import larenor_server.core as core_module
    original = core_module.migrate_media_preparations

    def interrupted(connection):
        original(connection)
        raise sqlite3.OperationalError("synthetic-private-migration-data")

    with monkeypatch.context() as context:
        context.setattr(core_module, "migrate_media_preparations", interrupted)
        with pytest.raises(StartupError, match="^storage_initialization_failed$"):
            create_app(server[2])
    with manager.db.connection() as connection:
        assert connection.execute("SELECT 1 FROM sqlite_master WHERE name='media_preparations'").fetchone() is None
        assert connection.execute("SELECT 1 FROM metadata WHERE key='media_preparations_schema'").fetchone() is None
    restarted = create_app(server[2]).state.core
    assert restarted.context == original_context and server[2].key_file.read_bytes() == key
    assert restarted.media_preparations.list(actor) == {"preparations": [], "nextBefore": None}
    assert not server[2].effective_bootstrap_file.exists()


@pytest.mark.parametrize("corruption", ["orphan_table", "missing_table", "bad_version", "extra_table"])
def test_partial_or_unknown_schema_fails_startup_without_reset(server, preparations, corruption):
    manager, _, _ = preparations
    with manager.db.transaction() as connection:
        if corruption == "orphan_table":
            connection.execute("DELETE FROM metadata WHERE key='media_preparations_schema'")
        elif corruption == "missing_table":
            connection.execute("DROP TABLE media_preparations")
        elif corruption == "bad_version":
            connection.execute("UPDATE metadata SET value='synthetic-private-version' WHERE key='media_preparations_schema'")
        else:
            connection.execute("CREATE TABLE media_preparations_extra (secret TEXT)")
    with pytest.raises(StartupError, match="^media_preparations_schema_unsupported$"):
        create_app(server[2])
    assert not server[2].effective_bootstrap_file.exists()


def test_empty_table_with_missing_required_columns_fails_at_startup(server, preparations):
    manager, _, _ = preparations
    with manager.db.transaction() as connection:
        connection.execute("DROP TABLE media_preparations")
        connection.execute("CREATE TABLE media_preparations (id TEXT PRIMARY KEY)")
    with pytest.raises(StartupError):
        create_app(server[2])


@pytest.mark.parametrize("missing", ["id", "sequence", "request", "partial_sequence", "composite_request"])
def test_missing_or_weakened_unique_constraints_fail_at_startup(server, preparations, missing):
    manager, _, _ = preparations
    with manager.db.transaction() as connection:
        schema = connection.execute("SELECT sql FROM sqlite_master WHERE name='media_preparations'").fetchone()[0]
        if missing == "id":
            schema = schema.replace("id TEXT PRIMARY KEY", "id TEXT")
        elif missing in ("sequence", "partial_sequence"):
            schema = schema.replace("sequence INTEGER NOT NULL UNIQUE", "sequence INTEGER NOT NULL")
        else:
            schema, replaced = re.subn(r",\s*UNIQUE\(actor_id,request_id\)", "", schema)
            assert replaced == 1
        connection.execute("DROP TABLE media_preparations")
        connection.execute(schema)
        if missing == "partial_sequence":
            connection.execute("CREATE UNIQUE INDEX media_sequence_partial ON media_preparations(sequence) WHERE sequence>10")
        elif missing == "composite_request":
            connection.execute("CREATE UNIQUE INDEX media_request_weakened ON media_preparations(actor_id,request_id,id)")
    with pytest.raises(StartupError):
        create_app(server[2])


def test_sqlite_runtime_failure_is_static_http_and_does_not_echo_paths(server, preparations, monkeypatch, caplog):
    manager, _, pair = preparations

    def failed(*_args, **_kwargs):
        raise sqlite3.OperationalError("synthetic-private-database-path")

    monkeypatch.setattr(manager, "list", failed)
    response = server[1].get(BASE, headers=auth(pair))
    assert response.status_code == 503 and response.json()["error"]["code"] == "server_unavailable"
    assert "synthetic-private" not in response.text + caplog.text
