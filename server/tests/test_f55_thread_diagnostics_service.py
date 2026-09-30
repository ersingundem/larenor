from contextlib import contextmanager
from types import MappingProxyType, SimpleNamespace
import os
import sqlite3

import pytest

from larenor_server.errors import ApiError, StartupError
from larenor_server.mesh_center.thread_diagnostics import (
    ThreadDatasetDiagnostic,
    ThreadDiagnosticSnapshot,
    ThreadRouterDiagnostic,
)
from larenor_server.mesh_center.thread_diagnostics_service import (
    ThreadDiagnosticsService,
)
from larenor_server.services.service import ServiceConnection


ACCOUNT = "1" * 32
CORE = "2" * 32
HOME = "3" * 32
SERVICE = "4" * 32
TOKEN = "private-home-assistant-token"


class _Database:
    def __init__(self, path):
        self.path = path
        with self.connection() as connection:
            connection.execute(
                "CREATE TABLE users(id TEXT PRIMARY KEY,role TEXT,disabled INT,"
                "must_change_password INT)"
            )
            connection.execute(
                "INSERT INTO users VALUES(?,?,0,0)", (ACCOUNT, "admin")
            )
            connection.commit()

    @contextmanager
    def connection(self):
        connection = sqlite3.connect(self.path)
        connection.row_factory = sqlite3.Row
        try:
            yield connection
        finally:
            connection.close()

    @contextmanager
    def transaction(self):
        with self.connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                yield connection
                connection.commit()
            except BaseException:
                connection.rollback()
                raise


class _Auth:
    def assert_current(self, connection, actor):
        if actor.id != ACCOUNT:
            raise ApiError("invalid_session", 401)


class _Services:
    def __init__(self):
        self.revision = 7
        self.state = "authenticated"

    def _record(self, connection, service_id, revision):
        if (service_id, revision) != (SERVICE, self.revision):
            raise ApiError("revision_conflict", 409)
        return ({"id": SERVICE, "revision": self.revision}, {
            "name": "Home Assistant",
            "kind": "home_assistant",
            "baseUrl": "http://ha.invalid",
            "credentials": {"token": TOKEN},
            "verification": {"state": self.state},
        })

    def _private(self, row, record):
        return ServiceConnection(
            id=row["id"],
            revision=row["revision"],
            name=record["name"],
            kind=record["kind"],
            base_url=record["baseUrl"],
            credentials=MappingProxyType(dict(record["credentials"])),
        )

    def list(self, actor):
        return {"services": [
            {
                "id": SERVICE,
                "revision": self.revision,
                "name": "Home Assistant",
                "kind": "home_assistant",
                "credentialKeys": ["token"],
                "verification": {"state": self.state},
            },
            {
                "id": "5" * 32,
                "revision": 1,
                "name": "Unverified",
                "kind": "home_assistant",
                "credentialKeys": ["token"],
                "verification": {"state": "never"},
            },
        ]}


class _Transport:
    after_before = None

    def __init__(self, service):
        assert service.credentials["token"] == TOKEN

    def observe(self, *, before_io, after_io):
        before_io()
        if self.after_before is not None:
            self.after_before()
        after_io()
        return ThreadDiagnosticSnapshot(
            serviceId=SERVICE,
            serviceRevision=7,
            capturedAtMs=1234,
            datasets=(ThreadDatasetDiagnostic(
                datasetId="provider-dataset-id",
                networkName="Home Thread",
                channel=15,
                panId=4660,
                extendedPanId="0011223344556677",
                preferred=True,
                source="otbr",
                preferredBorderAgentId=None,
                preferredExtendedAddress=None,
            ),),
            routers=(ThreadRouterDiagnostic(
                routerId="1122334455667788",
                networkName="Home Thread",
                extendedAddress="1122334455667788",
                extendedPanId="0011223344556677",
                borderAgentId=None,
                brand="homeassistant",
                modelName="OTBR",
                threadVersion="1.3.0",
                vendorName="Home Assistant",
                unconfigured=False,
            ),),
        )


def _service(tmp_path, services, transport=_Transport):
    return ThreadDiagnosticsService(
        _Database(tmp_path / "core.db"),
        _Auth(),
        services,
        SimpleNamespace(coreId=CORE, homeId=HOME),
        b"k" * 32,
        tmp_path,
        transport=transport,
    )


def _input(expected=None):
    return {
        "schemaVersion": 1,
        "expectedRevision": expected,
        "serviceId": SERVICE,
        "expectedServiceRevision": 7,
    }


def test_admin_selects_only_verified_ha_and_reads_redacted_diagnostics(tmp_path):
    services = _Services()
    service = _service(tmp_path, services)
    actor = SimpleNamespace(id=ACCOUNT)

    configuration = service.configuration(actor)
    assert [item.serviceId for item in configuration.services] == [SERVICE]
    binding = service.configure(actor, _input())
    assert binding.revision == 1

    snapshot = service.observe(actor, CORE, HOME)
    assert snapshot.bindingRevision == 1
    assert snapshot.datasets[0].networkName == "Home Thread"
    assert snapshot.datasets[0].datasetId != "provider-dataset-id"
    assert snapshot.routers[0].routerId != "1122334455667788"
    payload = snapshot.model_dump_json()
    assert TOKEN not in payload
    assert "extendedPanId" not in payload
    assert "borderAgentId" not in payload


def test_binding_is_durable_and_revision_cas_is_exact(tmp_path):
    services = _Services()
    actor = SimpleNamespace(id=ACCOUNT)
    first = _service(tmp_path, services)
    first.configure(actor, _input())

    reloaded = ThreadDiagnosticsService(
        first._db,
        _Auth(),
        services,
        SimpleNamespace(coreId=CORE, homeId=HOME),
        b"k" * 32,
        tmp_path,
        transport=_Transport,
    )
    assert reloaded.configuration(actor).binding.revision == 1
    with pytest.raises(ApiError) as error:
        reloaded.configure(actor, _input())
    assert (error.value.code, error.value.status) == ("revision_conflict", 409)
    assert reloaded.configure(actor, _input(1)).revision == 2


def test_configure_holds_authority_snapshot_through_durable_save(tmp_path):
    services = _Services()
    service = _service(tmp_path, services)
    actor = SimpleNamespace(id=ACCOUNT)
    original_save = service._store.save

    def assert_write_lock_held(binding):
        contender = sqlite3.connect(service._db.path, timeout=0)
        try:
            with pytest.raises(sqlite3.OperationalError, match="locked"):
                contender.execute("BEGIN IMMEDIATE")
        finally:
            contender.close()
        original_save(binding)

    service._store.save = assert_write_lock_held
    assert service.configure(actor, _input()).revision == 1


def test_oversize_binding_state_is_rejected_before_payload_read(tmp_path, monkeypatch):
    services = _Services()
    state = tmp_path / "thread-diagnostics-binding.state"
    with state.open("wb") as stream:
        stream.truncate(16 * 1024 + 1)

    original_fdopen = os.fdopen
    read_called = False

    class TrackingStream:
        def __init__(self, descriptor, mode):
            self._stream = original_fdopen(descriptor, mode)

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return self._stream.__exit__(*args)

        def fileno(self):
            return self._stream.fileno()

        def read(self, size=-1):
            nonlocal read_called
            read_called = True
            return self._stream.read(size)

    monkeypatch.setattr(os, "fdopen", TrackingStream)
    with pytest.raises(StartupError) as error:
        _service(tmp_path, services)
    assert str(error.value) == "thread_diagnostics_storage_invalid"
    assert read_called is False


def test_service_revision_change_during_io_fails_closed(tmp_path):
    services = _Services()

    class Changed(_Transport):
        after_before = staticmethod(lambda: setattr(services, "revision", 8))

    service = _service(tmp_path, services, Changed)
    actor = SimpleNamespace(id=ACCOUNT)
    service.configure(actor, _input())

    with pytest.raises(ApiError) as error:
        service.observe(actor, CORE, HOME)
    assert (error.value.code, error.value.status) == (
        "thread_diagnostics_binding_changed", 409
    )
