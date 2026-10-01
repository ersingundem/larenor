"""F58 authenticated bounded terminal and expired receipt retention."""

from fastapi.testclient import TestClient
import pytest

from conftest import auth
from larenor_server.app import create_app
from larenor_server.errors import ApiError, StartupError
import larenor_server.epaper_snapshots.management as management_module
from support.f58_oepl_fixture import DEVICE, OpenEpaperLinkFixture
from test_f58_oepl_normal_core import preview, provision


@pytest.fixture
def oepl():
    value = OpenEpaperLinkFixture()
    yield value
    value.close()


def _confirm(client, actor, expected, admin, shown):
    response = client.post(
        admin + f"/previews/{shown['requestId']}/confirm",
        headers=auth(actor),
        json=expected,
    )
    assert response.status_code == 200, response.text
    return response.json()


def test_terminal_provider_history_releases_capacity_after_restart_without_replay(
    server, oepl, monkeypatch
):
    monkeypatch.setattr(management_module, "MAX_POLLS", 3)
    monkeypatch.setattr(management_module, "RETAINED_TERMINAL_RECEIPTS", 1)
    app, client, actor, expected, _root, admin, mapped = provision(server, oepl)
    old = []
    for _ in range(3):
        shown = preview(client, actor, expected, admin, mapped)
        old.append((shown, _confirm(client, actor, expected, admin, shown)))
    assert oepl.real_sends == 3
    server[3].now += 61

    with TestClient(create_app(server[2])) as restarted:
        replay = restarted.post(
            admin + f"/previews/{old[-1][0]['requestId']}/confirm",
            headers=auth(actor), json=expected,
        )
        assert replay.status_code == 200
        assert replay.json() == old[-1][1]
        assert oepl.real_sends == 3

        newest = preview(restarted, actor, expected, admin, mapped)
        receipt = _confirm(restarted, actor, expected, admin, newest)
        assert receipt["status"] == "uncertain"
        assert oepl.real_sends == 4
        assert restarted.post(
            admin + f"/previews/{old[0][0]['requestId']}/confirm",
            headers=auth(actor), json=expected,
        ).status_code == 404
        with restarted.app.state.core.db.connection() as connection:
            assert connection.execute(
                "SELECT COUNT(*) FROM epaper_previews"
            ).fetchone()[0] == 2
            assert connection.execute(
                "SELECT COUNT(*) FROM epaper_provider_commands"
            ).fetchone()[0] == 2
            assert connection.execute(
                "SELECT COUNT(*) FROM epaper_provider_commands p "
                "LEFT JOIN epaper_previews v ON v.request_id=p.request_id "
                "WHERE v.request_id IS NULL"
            ).fetchone()[0] == 0


def test_unknown_provider_history_is_never_pruned_or_redispatched(
    server, oepl, monkeypatch
):
    monkeypatch.setattr(management_module, "MAX_POLLS", 3)
    monkeypatch.setattr(management_module, "RETAINED_TERMINAL_RECEIPTS", 1)
    app, client, actor, expected, _root, admin, mapped = provision(server, oepl)
    oepl.drop_real_response = True
    shown = []
    for _ in range(3):
        item = preview(client, actor, expected, admin, mapped)
        shown.append(item)
        assert _confirm(client, actor, expected, admin, item)["status"] == "uncertain"
    server[3].now += 61
    dry_runs = oepl.dry_runs
    with app.state.core.db.connection() as connection:
        with pytest.raises(ApiError, match="epaper_poll_limit"):
            app.state.core.epaper._ensure_preview_capacity(
                connection, provider=True, prune=False
            )
    blocked = client.post(
        admin + f"/devices/{DEVICE}/previews", headers=auth(actor),
        json={**expected, "expectedDeviceRevision": mapped["deviceRevision"],
              "action": "refresh"},
    )
    assert blocked.status_code == 409
    assert oepl.dry_runs == dry_runs
    assert oepl.real_sends == 3
    assert _confirm(client, actor, expected, admin, shown[0])["status"] == "uncertain"
    assert oepl.real_sends == 3
    with app.state.core.db.connection() as connection:
        assert connection.execute(
            "SELECT COUNT(*) FROM epaper_provider_commands WHERE state='uncertain'"
        ).fetchone()[0] == 3


def test_expired_untouched_preview_is_replaced_without_provider_write(
    server, oepl, monkeypatch
):
    monkeypatch.setattr(management_module, "MAX_POLLS", 1)
    app, client, actor, expected, _root, admin, mapped = provision(server, oepl)
    abandoned = preview(client, actor, expected, admin, mapped)
    assert oepl.real_sends == 0
    server[3].now += 61

    replacement = preview(client, actor, expected, admin, mapped)
    assert replacement["requestId"] != abandoned["requestId"]
    assert oepl.real_sends == 0
    assert client.post(
        admin + f"/previews/{abandoned['requestId']}/confirm",
        headers=auth(actor), json=expected,
    ).status_code == 404
    with app.state.core.db.connection() as connection:
        assert connection.execute(
            "SELECT COUNT(*) FROM epaper_previews"
        ).fetchone()[0] == 1
        assert connection.execute(
            "SELECT COUNT(*) FROM epaper_provider_commands"
        ).fetchone()[0] == 1


def test_authenticated_child_mismatch_blocks_pruning_without_deleting_history(
    server, oepl, monkeypatch
):
    monkeypatch.setattr(management_module, "MAX_POLLS", 2)
    monkeypatch.setattr(management_module, "RETAINED_TERMINAL_RECEIPTS", 0)
    app, client, actor, expected, _root, admin, mapped = provision(server, oepl)
    items = []
    for _ in range(2):
        item = preview(client, actor, expected, admin, mapped)
        items.append(item)
        _confirm(client, actor, expected, admin, item)
    server[3].now += 61
    other_device = "f" * 32
    with app.state.core.db.transaction() as connection:
        device = dict(connection.execute(
            "SELECT * FROM epaper_devices WHERE device_id=?", (DEVICE,)
        ).fetchone())
        device["device_id"] = other_device
        device["authentication_tag"] = app.state.core.epaper._device_tag(device)
        connection.execute(
            "INSERT INTO epaper_devices VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
            tuple(device.values()),
        )
        provider = dict(connection.execute(
            "SELECT * FROM epaper_provider_commands WHERE request_id=?",
            (items[0]["requestId"],),
        ).fetchone())
        provider["device_id"] = other_device
        provider["authentication_tag"] = app.state.core.epaper._provider_tag(provider)
        connection.execute(
            "UPDATE epaper_provider_commands SET device_id=?,authentication_tag=? "
            "WHERE request_id=?",
            (other_device, provider["authentication_tag"], provider["request_id"]),
        )

    with pytest.raises(StartupError, match="epaper_snapshot_storage_invalid"):
        with app.state.core.db.transaction() as connection:
            app.state.core.epaper._ensure_preview_capacity(
                connection, provider=True, prune=True
            )
    with app.state.core.db.connection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM epaper_previews").fetchone()[0] == 2
        assert connection.execute(
            "SELECT COUNT(*) FROM epaper_provider_commands"
        ).fetchone()[0] == 2


def test_tampered_terminal_receipt_blocks_pruning_without_deleting_history(
    server, oepl, monkeypatch
):
    monkeypatch.setattr(management_module, "MAX_POLLS", 1)
    monkeypatch.setattr(management_module, "RETAINED_TERMINAL_RECEIPTS", 0)
    app, client, actor, expected, _root, admin, mapped = provision(server, oepl)
    item = preview(client, actor, expected, admin, mapped)
    _confirm(client, actor, expected, admin, item)
    server[3].now += 61
    with app.state.core.db.transaction() as connection:
        connection.execute(
            "UPDATE epaper_provider_commands SET authentication_tag=? "
            "WHERE request_id=?", ("0" * 64, item["requestId"]),
        )

    with pytest.raises(StartupError, match="epaper_snapshot_storage_invalid"):
        with app.state.core.db.transaction() as connection:
            app.state.core.epaper._ensure_preview_capacity(
                connection, provider=True, prune=True
            )
    with app.state.core.db.connection() as connection:
        assert connection.execute(
            "SELECT COUNT(*) FROM epaper_previews"
        ).fetchone()[0] == 1
        assert connection.execute(
            "SELECT COUNT(*) FROM epaper_provider_commands"
        ).fetchone()[0] == 1


def test_poll_capacity_failure_rolls_back_candidate_pruning(
    server, oepl, monkeypatch
):
    app, client, actor, expected, root, admin, mapped = provision(
        server, oepl
    )
    management = app.state.core.epaper
    poll_rows = []
    for index, status in enumerate(("pending", "pending", "verified", "verified")):
        row = {
            "request_id": f"{index + 1:x}" * 32,
            "device_id": DEVICE,
            "device_revision": int(mapped["deviceRevision"]),
            "render_digest": mapped["snapshotDigest"],
            "byte_length": 100,
            "frame_count": 1,
            "status": status,
            "received_frames": 0 if status == "pending" else 1,
        }
        row["authentication_tag"] = management._poll_tag(row)
        poll_rows.append(row)
    with app.state.core.db.transaction() as connection:
        for row in poll_rows:
            connection.execute(
                "INSERT INTO epaper_polls VALUES(?,?,?,?,?,?,?,?,?)",
                tuple(row.values()),
            )
    monkeypatch.setattr(management_module, "MAX_POLLS", 3)
    monkeypatch.setattr(management_module, "RETAINED_TERMINAL_RECEIPTS", 1)
    with pytest.raises(ApiError, match="epaper_poll_limit"):
        with app.state.core.db.transaction() as connection:
            management._ensure_poll_capacity(connection, prune=True)
    with app.state.core.db.connection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM epaper_polls").fetchone()[0] == 4


def test_terminal_poll_retention_preserves_current_readback_across_restart(
    server, oepl, monkeypatch
):
    app, client, actor, expected, root, _admin, mapped = provision(server, oepl)
    management = app.state.core.epaper
    for index in range(3):
        row = {
            "request_id": f"{index + 1:x}" * 32,
            "device_id": DEVICE,
            "device_revision": int(mapped["deviceRevision"]),
            "render_digest": mapped["snapshotDigest"],
            "byte_length": 100,
            "frame_count": 1,
            "status": "verified",
            "received_frames": 1,
        }
        row["authentication_tag"] = management._poll_tag(row)
        with app.state.core.db.transaction() as connection:
            connection.execute(
                "INSERT INTO epaper_polls VALUES(?,?,?,?,?,?,?,?,?)",
                tuple(row.values()),
            )
    monkeypatch.setattr(management_module, "MAX_POLLS", 2)
    monkeypatch.setattr(management_module, "RETAINED_TERMINAL_RECEIPTS", 1)
    with app.state.core.db.transaction() as connection:
        management._ensure_poll_capacity(connection, prune=True)
    with app.state.core.db.connection() as connection:
        assert connection.execute(
            "SELECT COUNT(*) FROM epaper_polls"
        ).fetchone()[0] == 1

    with TestClient(create_app(server[2])) as restarted:
        current = restarted.post(
            root + f"/devices/{DEVICE}", headers=auth(actor), json=expected,
        )
        assert current.status_code == 200
        assert current.json()["snapshotTrust"] == "acknowledged"


def test_default_2000_prepared_preview_history_recovers_through_normal_core_restart(server, oepl):
    app, client, actor, expected, _root, admin, mapped = provision(server, oepl)
    shown = preview(client, actor, expected, admin, mapped)
    management = app.state.core.epaper
    with app.state.core.db.transaction() as connection:
        parent = dict(connection.execute('SELECT * FROM epaper_previews WHERE request_id=?', (shown['requestId'],)).fetchone())
        child = dict(connection.execute('SELECT * FROM epaper_provider_commands WHERE request_id=?', (shown['requestId'],)).fetchone())
        # Signed copies represent abandoned real dry-run preparations, not 2000
        # physical displays or provider effects. The final request is normal HTTP.
        for index in range(1, 2000):
            request_id = f'{index:032x}'
            preview_row = parent | {'request_id': request_id}
            preview_row['authentication_tag'] = management._preview_tag(preview_row)
            provider_row = child | {'request_id': request_id}
            provider_row['authentication_tag'] = management._provider_tag(provider_row)
            for table, row in (('epaper_previews', preview_row), ('epaper_provider_commands', provider_row)):
                names = tuple(row)
                connection.execute('INSERT INTO ' + table + ' (' + ','.join(names) + ') VALUES (' + ','.join('?' for _ in names) + ')', tuple(row.values()))
    assert oepl.real_sends == 0
    server[3].now += 61
    with TestClient(create_app(server[2])) as restarted:
        newest = preview(restarted, actor, expected, admin, mapped)
        receipt = _confirm(restarted, actor, expected, admin, newest)
        assert receipt['status'] == 'uncertain'
        assert oepl.real_sends == 1
        with restarted.app.state.core.db.connection() as connection:
            assert connection.execute('SELECT COUNT(*) FROM epaper_previews').fetchone()[0] == 1
            assert connection.execute('SELECT COUNT(*) FROM epaper_provider_commands').fetchone()[0] == 1
        assert restarted.post(admin + f"/previews/{shown['requestId']}/confirm", headers=auth(actor), json=expected).status_code == 404
        assert oepl.real_sends == 1
