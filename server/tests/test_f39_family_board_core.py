import os

import pytest

from larenor_server.errors import ApiError, StartupError
from larenor_server.family_board import (
    BoardAuthority,
    BoardCard,
    BoardCommand,
    BoardPoint,
    BoardStroke,
    FamilyBoardStore,
)


CORE = "1" * 32
HOME = "2" * 32
BOARD = "3" * 32
ADMIN = "4" * 32
MEMBER = "5" * 32
SESSION = "6" * 32


def authority(account=ADMIN, *, role="admin", read=True, write=True, member_revision=1):
    return BoardAuthority(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        homeRevision=7,
        boardId=BOARD,
        accountId=account,
        accountRevision=3,
        memberRevision=member_revision,
        sessionFamilyId=SESSION if account == ADMIN else "7" * 32,
        role=role,
        canRead=read,
        canWrite=write,
        active=True,
    )


@pytest.fixture
def board(tmp_path):
    current = {
        ADMIN: authority(),
        MEMBER: authority(MEMBER, role="member", write=False),
    }
    path = tmp_path / "family-board.sqlite3"
    store = FamilyBoardStore(path, b"k" * 32, lambda account_id: current.get(account_id), clock=lambda: 17.0)
    return store, current, path


def card(identity="8" * 32, text="Akşam yemeği 19:00"):
    return BoardCard(
        schemaVersion=1, id=identity, kind="card", text=text,
        x=20, y=30, color="yellow",
    )


def command(request, expected, action, *, element=None, element_id=None):
    return BoardCommand(
        schemaVersion=1,
        requestId=request,
        expectedBoardRevision=expected,
        action=action,
        element=element,
        elementId=element_id,
    )


def test_bounded_card_and_drawing_contract_exact_scope_and_revision(board):
    store, _current, _path = board
    first = store.apply(authority(), command("9" * 32, 0, "append", element=card()))
    stroke = BoardStroke(
        schemaVersion=1, id="a" * 32, kind="stroke", color="blue", width=4,
        points=[BoardPoint(x=1, y=2), BoardPoint(x=3, y=4)],
    )
    second = store.apply(authority(), command("a" * 32, 1, "append", element=stroke))
    snapshot = store.snapshot(authority())

    assert first.boardRevision == 1 and second.boardRevision == 2
    assert snapshot.boardRevision == 2
    assert [item.kind for item in snapshot.elements] == ["card", "stroke"]
    assert snapshot.authority.homeRevision == 7
    assert snapshot.authority.memberRevision == 1
    assert set(snapshot.model_dump()) == {"schemaVersion", "authority", "boardRevision", "auditHead", "elements"}

    with pytest.raises(ValueError):
        card(text="x" * 2001)
    with pytest.raises(ValueError):
        BoardStroke(schemaVersion=1, id="b" * 32, kind="stroke", color="blue", width=4,
                    points=[BoardPoint(x=1, y=2)] * 257)
    wrong = authority().model_copy(update={"homeId": "f" * 32})
    with pytest.raises(ApiError, match="not_found"):
        store.snapshot(wrong)


def test_idempotent_mutations_conflict_replay_and_immutable_audit(board):
    store, current, _path = board
    append = command("9" * 32, 0, "append", element=card())
    receipt = store.apply(authority(), append)
    assert store.apply(authority(), append) == receipt

    changed_replay = append.model_copy(update={"element": card(text="changed")})
    with pytest.raises(ApiError, match="idempotency_conflict"):
        store.apply(authority(), changed_replay)
    with pytest.raises(ApiError, match="revision_conflict"):
        store.apply(authority(), command("b" * 32, 0, "update", element=card(text="late")))

    current[MEMBER] = authority(MEMBER, role="member", write=True)
    with pytest.raises(ApiError, match="revision_conflict"):
        store.apply(current[MEMBER], append)

    updated = store.apply(authority(), command("c" * 32, 1, "update", element=card(text="Film gecesi")))
    deleted = store.apply(authority(), command("d" * 32, 2, "delete", element_id=card().id))
    delta = store.delta(authority(), after_sequence=0, limit=10)
    assert (updated.boardRevision, deleted.boardRevision) == (2, 3)
    assert [event.action for event in delta.events] == ["append", "update", "delete"]
    assert [event.sequence for event in delta.events] == [1, 2, 3]
    assert delta.events[1].previousHash == delta.events[0].eventHash
    assert delta.events[2].previousHash == delta.events[1].eventHash
    assert delta.events[0].actorId == ADMIN
    with pytest.raises(ValueError):
        delta.events[0].boardRevision = 99


def test_encrypted_restart_role_authority_and_secret_free_exports(board):
    store, current, path = board
    secret_text = "private-family-note-never-in-sqlite-plain"
    receipt = store.apply(authority(), command("9" * 32, 0, "append", element=card(text=secret_text)))
    raw = path.read_bytes()
    assert secret_text.encode() not in raw
    assert os.stat(path).st_mode & 0o077 == 0

    restarted = FamilyBoardStore(path, b"k" * 32, lambda account_id: current.get(account_id), clock=lambda: 18.0)
    assert restarted.snapshot(authority()).elements[0].text == secret_text
    assert restarted.apply(authority(), command("9" * 32, 0, "append", element=card(text=secret_text))) == receipt

    member = current[MEMBER]
    assert restarted.snapshot(member).boardRevision == 1
    with pytest.raises(ApiError, match="forbidden"):
        restarted.apply(member, command("e" * 32, 1, "delete", element_id=card().id))
    for field, value in (
        ("homeRevision", 8), ("accountRevision", 4), ("memberRevision", 2),
        ("sessionFamilyId", "e" * 32),
    ):
        stale = authority().model_copy(update={field: value})
        with pytest.raises(ApiError, match="revision_conflict"):
            restarted.snapshot(stale)
    exported = restarted.export_snapshot(member, limit=10).model_dump_json()
    delta = restarted.delta(member, after_sequence=0, limit=10).model_dump_json()
    for forbidden in ("ciphertext", "nonce", "kkkk", "sessionFamilyId", "accountRevision"):
        assert forbidden not in exported
        assert forbidden not in delta
    denied = authority(MEMBER, role="member", read=False, write=False)
    current[MEMBER] = denied
    with pytest.raises(ApiError, match="not_found"):
        restarted.snapshot(denied)


@pytest.mark.parametrize("tamper", ["ciphertext", "delete", "state"])
def test_tamper_and_deleted_journal_fail_closed(board, tamper):
    store, current, path = board
    store.apply(authority(), command("9" * 32, 0, "append", element=card()))
    with store._connection() as connection:
        if tamper == "ciphertext":
            connection.execute("UPDATE family_board_events SET ciphertext=? WHERE sequence=1", (b"x" * 32,))
        elif tamper == "delete":
            connection.execute("DELETE FROM family_board_events WHERE sequence=1")
        else:
            connection.execute("UPDATE family_boards SET board_revision=2")
    with pytest.raises(StartupError, match="family_board_storage_invalid"):
        FamilyBoardStore(path, b"k" * 32, lambda account_id: current.get(account_id))


def test_closed_commands_and_export_bounds(board):
    store, _current, _path = board
    with pytest.raises(ValueError):
        BoardCommand(schemaVersion=1, requestId="9" * 32, expectedBoardRevision=0,
                     action="delete", element=card(), elementId=card().id)
    with pytest.raises(ValueError):
        BoardCommand(schemaVersion=1, requestId="9" * 32, expectedBoardRevision=0,
                     action="append", element=None, elementId=None)
    store.apply(authority(), command("9" * 32, 0, "append", element=card()))
    assert len(store.delta(authority(), after_sequence=0, limit=1).events) == 1
    with pytest.raises(ValueError):
        store.delta(authority(), after_sequence=0, limit=101)
    with pytest.raises(ValueError):
        store.export_snapshot(authority(), limit=0)


def test_authority_change_during_write_is_rejected_without_effect(tmp_path):
    current = authority()
    calls = 0

    def changing_resolver(_account_id):
        nonlocal calls
        calls += 1
        if calls == 1:
            return current
        return current.model_copy(update={"memberRevision": 2})

    store = FamilyBoardStore(tmp_path / "stale.sqlite3", b"z" * 32, changing_resolver)
    with pytest.raises(ApiError, match="revision_conflict"):
        store.apply(current, command("9" * 32, 0, "append", element=card()))
    with store._connection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM family_boards").fetchone()[0] == 0
        assert connection.execute("SELECT COUNT(*) FROM family_board_events").fetchone()[0] == 0
