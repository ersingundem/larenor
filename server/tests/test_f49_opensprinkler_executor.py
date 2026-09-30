import json

import pytest

from larenor_server.errors import ApiError
from larenor_server.garden_irrigation.models import (
    IrrigationZone,
    ValveStopCommand,
    ValveWorkerCommand,
)
from larenor_server.garden_irrigation.opensprinkler import (
    OpenSprinklerBinding,
    OpenSprinklerConnection,
    OpenSprinklerExecutor,
    OpenSprinklerError,
    migrate_opensprinkler_commands,
)
from larenor_server.services.transport import ProbeResponse


CORE = "1" * 32
HOME = "2" * 32
ACCOUNT = "3" * 32
ZONE = "4" * 32
AREA = "5" * 32
SERVICE = "6" * 32
BINDING = "7" * 32
COMMAND = "8" * 32
REQUEST = "9" * 32
PLAN = "a" * 32
PASSWORD = "b" * 32


class MutableClock:
    def __init__(self):
        self.now = 2_000.0

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


def _zone():
    return IrrigationZone(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        zoneId=ZONE,
        zoneRevision=2,
        areaId=AREA,
        areaRevision=3,
        valveServiceId=SERVICE,
        valveServiceRevision=4,
        valveBindingId=BINDING,
        valveBindingRevision=5,
        flowMlPerMinute=30_000,
        maxDurationSeconds=900,
    )


def _run_command():
    return ValveWorkerCommand(
        schemaVersion=1,
        commandId=COMMAND,
        requestId=REQUEST,
        planId=PLAN,
        policyRevision=7,
        actorAccountId=ACCOUNT,
        zone=_zone(),
        expectedStateRevision=1_000,
        durationSeconds=2,
        expectedWaterMl=1_000,
    )


def _stop_command():
    return ValveStopCommand(
        schemaVersion=1,
        commandId="c" * 32,
        requestId=REQUEST,
        actorAccountId=ACCOUNT,
        zone=_zone(),
        expectedStateRevision=1_100,
    )


def _json(value):
    return ProbeResponse(
        200,
        (("content-type", "application/json"),),
        json.dumps(value, separators=(",", ":")).encode(),
    )


class OpenSprinklerFixture:
    def __init__(self, clock, *, phase="idle", device_time=1_000):
        self.clock = clock
        self.phase = phase
        self.device_time = device_time
        self.boot = 900
        self.flow = 10
        self.last_run = [0, 0, 0, 0]
        self.calls = []
        self.complete_after_snapshot = False
        self.interrupt_on_run = False
        self.lose_run_ack = False
        self.lose_stop_ack = False
        self.before_cm = None

    def __call__(self, base_url, **limits):
        assert base_url == "http://sprinkler.fixture.invalid"
        assert limits == {"timeout": 5.0, "max_bytes": 65_536}
        return self

    def close(self):
        pass

    def _status(self):
        running = self.phase == "running"
        return {
            "devt": self.device_time,
            "lupt": self.boot,
            "lrun": self.last_run,
            "sbits": [1 if running else 0],
            "ps": [[99, 1, self.device_time, 0] if running else [0, 0, 0, 0]]
            + [[0, 0, 0, 0] for _ in range(7)],
            "flwrt": 1,
            "flcrt": 1 if running else 0,
            "flcto": self.flow,
            "nq": 1 if running else 0,
            "en": 1,
            "ocs": 0,
        }

    def _finish_run(self):
        self.phase = "completed"
        self.device_time += 2
        self.flow += 2
        self.last_run = [0, 99, 2, self.device_time]

    def request(self, method, path, headers=None, body=None, query_parameters=None, before_send=None):
        if path == '/cm' and self.before_cm is not None:
            callback, self.before_cm = self.before_cm, None
            callback()
        if before_send is not None:
            before_send()
        assert method == "GET"
        assert headers == {"Accept": "application/json"}
        assert query_parameters["pw"] == PASSWORD
        self.calls.append((path, dict(query_parameters)))
        if path == "/jo":
            return _json({
                "fwv": 221,
                "fwm": 5,
                "sn1t": 2,
                "fpr0": 50,
                "fpr1": 0,
                "mas": 0,
                "mas2": 0,
                "mas3": 0,
                "mas4": 0,
            })
        if path == "/jn":
            return _json({"stn_dis": [0], "stn_spe": [0]})
        if path == "/jc":
            if self.phase == "running":
                self.complete_after_snapshot = True
            return _json(self._status())
        if path == "/js":
            running = self.phase == "running"
            result = _json({
                "sn": [1 if running else 0] + [0] * 7,
                "nstations": 8,
            })
            if self.complete_after_snapshot:
                self.complete_after_snapshot = False
                self._finish_run()
            return result
        assert path == "/cm"
        if query_parameters["en"] == "1":
            self.phase = "running"
            if self.interrupt_on_run:
                self.interrupt_on_run = False
                self._finish_run()
                raise KeyboardInterrupt()
            if self.lose_run_ack:
                self.lose_run_ack = False
                raise OSError("lost fixture acknowledgement")
        else:
            self.phase = "closed"
            self.device_time += 1
            if self.lose_stop_ack:
                self.lose_stop_ack = False
                raise OSError("lost fixture acknowledgement")
        return _json({"result": 1})


def _executor(server, fixture, clock):
    app, _client, settings, _server_clock = server
    with app.state.core.db.transaction() as connection:
        migrate_opensprinkler_commands(connection)
    binding = OpenSprinklerBinding(
        connection=OpenSprinklerConnection(
            id=SERVICE,
            revision=1,
            base_url="http://sprinkler.fixture.invalid",
            password_md5=PASSWORD,
        ),
        station_index=0,
        zone=_zone(),
    )
    executor = OpenSprinklerExecutor(
        app.state.core.db,
        settings.key_file.read_bytes(),
        clock,
        lambda expected: binding if expected == _zone() else None,
        transport_factory=fixture,
        sleep=clock.sleep,
        poll_seconds=1,
    )
    return executor


def test_timer_flow_receipt_is_actual_and_replay_does_not_resend(server):
    clock = MutableClock()
    fixture = OpenSprinklerFixture(clock)
    executor = _executor(server, fixture, clock)

    before = executor.readback(_zone())
    assert before.stateRevision == 1_000
    assert before.valveOpen is False
    result = executor.run(_run_command())
    assert result.stateRevision == 1_002
    assert result.valveOpen is False
    assert result.flowVerified is True
    assert result.deliveredMl == 1_000
    mutations = [call for call in fixture.calls if call[0] == "/cm"]
    assert mutations == [("/cm", {
        "pw": PASSWORD, "sid": "0", "en": "1", "t": "2", "qo": "1",
    })]

    assert executor.run(_run_command()) == result
    assert [call for call in fixture.calls if call[0] == "/cm"] == mutations


def test_authority_loss_at_socket_send_prevents_mutation_and_replay(server):
    clock = MutableClock()
    fixture = OpenSprinklerFixture(clock)
    executor = _executor(server, fixture, clock)
    allowed = [True]
    def guard():
        if not allowed[0]:
            raise ApiError('authority_changed', 409)
    fixture.before_cm = lambda: allowed.__setitem__(0, False)
    with pytest.raises(ApiError):
        executor.run(_run_command(), guard=guard)
    assert fixture.phase == 'idle'
    assert not any(path == '/cm' for path, _ in fixture.calls)
    allowed[0] = True
    with pytest.raises(OpenSprinklerError):
        executor.run(_run_command(), guard=guard)
    assert not any(path == '/cm' for path, _ in fixture.calls)


def test_dispatch_survives_process_loss_without_resending_mutation(server):
    clock = MutableClock()
    fixture = OpenSprinklerFixture(clock)
    executor = _executor(server, fixture, clock)
    fixture.interrupt_on_run = True

    with pytest.raises(KeyboardInterrupt):
        executor.run(_run_command())
    assert len([call for call in fixture.calls if call[0] == "/cm"]) == 1

    recovered = _executor(server, fixture, clock).run(_run_command())
    assert recovered.flowVerified is True
    assert recovered.deliveredMl == 1_000
    assert len([call for call in fixture.calls if call[0] == "/cm"]) == 1


def test_stop_lost_ack_reconciles_closed_and_never_repeats(server):
    clock = MutableClock()
    fixture = OpenSprinklerFixture(clock, phase="running", device_time=1_100)
    fixture.lose_stop_ack = True
    executor = _executor(server, fixture, clock)

    result = executor.stop(_stop_command())
    assert result.valveOpen is False
    assert result.flowActive is False
    assert result.stateRevision > 1_100
    mutations = [call for call in fixture.calls if call[0] == "/cm"]
    assert len(mutations) == 1
    assert mutations[0][1] == {
        "pw": PASSWORD, "sid": "0", "en": "0", "ssta": "0",
    }
    assert executor.stop(_stop_command()) == result
    assert len([call for call in fixture.calls if call[0] == "/cm"]) == 1


def test_flow_receipt_rejects_controller_overlap(server):
    clock = MutableClock()
    fixture = OpenSprinklerFixture(clock, phase="running")
    executor = _executor(server, fixture, clock)
    with pytest.raises(ApiError) as error:
        executor.run(_run_command())
    assert error.value.code == "revision_conflict"
    assert not [call for call in fixture.calls if call[0] == "/cm"]


def test_connection_repr_redacts_endpoint_and_password():
    value = OpenSprinklerConnection(
        id=SERVICE,
        revision=1,
        base_url="http://secret-controller.invalid",
        password_md5=PASSWORD,
    )
    assert "secret-controller" not in repr(value)
    assert PASSWORD not in repr(value)
