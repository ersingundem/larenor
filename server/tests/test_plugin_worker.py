"""Worker primitives use synthetic Docker replies and private temporary journals."""

import copy
import json
import os
from pathlib import Path
import socket
import tempfile
import threading
import time

import pytest

from larenor_server.plugins.worker import (
    ContainerBinding, DockerWorkerError, JournaledContainerOperations,
    UnixDockerEngine, WorkerJournal, WorkerStep,
)


def binding(journal):
    labels = {
        "org.larenor.server": "a" * 32,
        "org.larenor.installation": "b" * 32,
        "org.larenor.worker-journal": journal.identity,
        "org.larenor.plan": "c" * 64,
        "org.larenor.catalog": "d" * 64,
        "org.larenor.manifest": "e" * 64,
    }
    body = {
        "Image": "ghcr.io/example/fixture@sha256:" + "f" * 64,
        "User": "1000:1000", "Labels": labels, "Env": ["TZ=UTC"],
        "HostConfig": {"Privileged": False, "CapDrop": ["ALL"], "CapAdd": [],
                       "SecurityOpt": ["no-new-privileges:true"], "NetworkMode": "bridge",
                       "Memory": 256 * 1024 * 1024, "NanoCpus": 1000000000,
                       "PidsLimit": 64, "ReadonlyRootfs": False},
    }
    return ContainerBinding("larenor-" + "b" * 32, "linux/amd64", "sha256:" + "1" * 64,
                            json.dumps(body, sort_keys=True, separators=(",", ":")).encode())


def snapshot(item, *, running=False):
    body = json.loads(item.specification)
    inherited = json.loads(item.image_configuration)
    configuration = {**inherited, **{key: value for key, value in body.items() if key != "HostConfig"}}
    configuration['Env'] = list({**{value.partition('=')[0]: value for value in inherited.get('Env', [])},
                                 **{value.partition('=')[0]: value for value in body.get('Env', [])}}.values())
    configuration['Labels'] = {**inherited.get('Labels', {}), **body['Labels']}
    if inherited.get('ExposedPorts') or body.get('ExposedPorts'):
        configuration['ExposedPorts'] = {**inherited.get('ExposedPorts', {}), **body.get('ExposedPorts', {})}
    if body['HostConfig'].get('RestartPolicy'):
        body['HostConfig']['RestartPolicy']['MaximumRetryCount'] = 0
    return {"Id": "2" * 64, "Name": "/" + item.name, "Image": item.image_id,
            "Config": configuration,
            "HostConfig": body["HostConfig"], "Mounts": [],
            "State": {"Running": running, "Status": "running" if running else "created"}}


class FakeEngine:
    def __init__(self):
        self.container = None
        self.calls = []
        self.lose_create_reply = False
        self.lose_start_reply = False
        self.image_configuration = {}

    def inspect_image(self, reference):
        self.calls.append(('image', reference))
        return {'Id': 'sha256:' + '1' * 64, 'Os': 'linux', 'Architecture': 'amd64', 'Config': self.image_configuration}

    def inspect_container(self, name):
        self.calls.append(("inspect", name))
        return copy.deepcopy(self.container)

    def create_container(self, item):
        self.calls.append(("create", item.name))
        self.container = snapshot(item)
        if self.lose_create_reply:
            raise DockerWorkerError("engine_unavailable")
        return self.container["Id"]

    def start_container(self, identity):
        self.calls.append(("start", identity))
        self.container["State"] = {"Running": True, "Status": "running"}
        if self.lose_start_reply:
            raise DockerWorkerError("engine_unavailable")


@pytest.fixture
def setup(tmp_path):
    journal = WorkerJournal(tmp_path / "worker", initialize=True)
    engine = FakeEngine()
    yield journal, engine, JournaledContainerOperations(journal, engine), binding(journal)
    journal.close()


def command(kind="create_container", *, deadline=None, dispatch="3" * 32):
    return WorkerStep("4" * 32, "b" * 32, kind, dispatch, time.time() + 30 if deadline is None else deadline)


def test_create_then_start_have_durable_phase_receipts(setup):
    journal, engine, worker, item = setup
    created = worker.apply(command(), item)
    assert (created.state, created.code, created.container_id) == ("succeeded", "container_created", "2" * 64)
    started = worker.apply(command("start_container", dispatch="5" * 32), item)
    assert (started.state, started.code) == ("succeeded", "container_started")
    assert engine.calls.count(("create", item.name)) == 1
    assert worker.observe("4" * 32, "create_container") == created
    assert oct(journal.directory.stat().st_mode & 0o777) == "0o700"
    assert all(path.stat().st_mode & 0o077 == 0 for path in journal.directory.iterdir())


def test_expired_new_dispatch_fails_but_completed_receipt_is_replayable(setup):
    _, engine, worker, item = setup
    with pytest.raises(DockerWorkerError, match="dispatch_expired"):
        worker.apply(command(deadline=0), item)
    assert not engine.calls
    original = command()
    result = worker.apply(original, item)
    assert worker.apply(original, item) == result
    assert engine.calls.count(("create", item.name)) == 1


def test_uncertain_create_is_observed_after_restart_without_second_create(setup):
    journal, engine, worker, item = setup
    engine.lose_create_reply = True
    assert worker.apply(command(), item).state == "uncertain"
    identity, directory = journal.identity, journal.directory
    journal.close()
    reopened = WorkerJournal(directory)
    try:
        assert reopened.identity == identity
        recovered = JournaledContainerOperations(reopened, engine).reconcile("4" * 32, "create_container")
        assert recovered.code == "container_created"
        assert engine.calls.count(("create", item.name)) == 1
    finally:
        reopened.close()


def test_uncertain_absence_never_blindly_recreates(setup):
    _, engine, worker, item = setup
    engine.lose_create_reply = True
    request = command()
    worker.apply(request, item)
    engine.container = None
    assert worker.reconcile("4" * 32, "create_container").state == "needs_attention"
    worker.apply(request, item)
    assert engine.calls.count(("create", item.name)) == 1


def test_existing_container_is_never_adopted_even_with_matching_labels(setup):
    _, engine, worker, item = setup
    engine.container = snapshot(item)
    assert worker.apply(command(), item).code == "resource_conflict"
    assert not any(call[0] in {"create", "start"} for call in engine.calls)


@pytest.mark.parametrize("change", ["label", "image", "privileged", "capability", "host_pid", "mount", "environment", "command"])
def test_reconcile_rejects_identity_or_spec_drift(setup, change):
    _, engine, worker, item = setup
    engine.lose_create_reply = True
    worker.apply(command(), item)
    if change == "label":
        engine.container["Config"]["Labels"]["org.larenor.plan"] = "9" * 64
    elif change == "image":
        engine.container["Image"] = "sha256:" + "9" * 64
    elif change == "privileged":
        engine.container["HostConfig"]["Privileged"] = True
    elif change == "capability":
        engine.container["HostConfig"]["CapAdd"] = ["SYS_ADMIN"]
    elif change == "host_pid":
        engine.container["HostConfig"]["PidMode"] = "host"
    elif change == "mount":
        engine.container["Mounts"] = [{"Source": "/", "Destination": "/host"}]
    elif change == "environment":
        engine.container["Config"]["Env"] = ["TOKEN=private-value"]
    else:
        engine.container["Config"]["Cmd"] = ["unexpected"]
    receipt = worker.reconcile("4" * 32, "create_container")
    assert (receipt.state, receipt.code) == ("needs_attention", "resource_conflict")
    assert "private-value" not in repr(receipt)
    assert len([call for call in engine.calls if call[0] == "create"]) == 1


def test_start_requires_a_successful_matching_create_receipt(setup):
    _, engine, worker, item = setup
    with pytest.raises(DockerWorkerError, match="step_order"):
        worker.apply(command("start_container"), item)
    assert not engine.calls


def test_uncertain_start_reconciles_running_state_without_restart(setup):
    _, engine, worker, item = setup
    worker.apply(command(), item)
    engine.lose_start_reply = True
    assert worker.apply(command("start_container", dispatch="5" * 32), item).state == "uncertain"
    assert worker.reconcile("4" * 32, "start_container").code == "container_started"
    assert len([call for call in engine.calls if call[0] == "start"]) == 1


def test_same_job_step_with_changed_dispatch_or_payload_conflicts(setup):
    _, engine, worker, item = setup
    worker.apply(command(), item)
    with pytest.raises(DockerWorkerError, match="idempotency_conflict"):
        worker.apply(command(dispatch="5" * 32), item)
    changed = ContainerBinding(item.name, item.platform, "sha256:" + "8" * 64, item.specification)
    with pytest.raises(DockerWorkerError, match="idempotency_conflict"):
        worker.apply(command(), changed)


def test_missing_or_corrupt_existing_journal_is_not_reinitialized(tmp_path):
    directory = tmp_path / "worker"
    journal = WorkerJournal(directory, initialize=True)
    journal.close()
    (directory / "journal.sqlite").unlink()
    with pytest.raises(DockerWorkerError, match="journal_unavailable"):
        WorkerJournal(directory, initialize=True)


def test_symlink_journal_directory_is_rejected(tmp_path):
    actual = tmp_path / "actual"
    actual.mkdir(mode=0o700)
    link = tmp_path / "worker"
    link.symlink_to(actual, target_is_directory=True)
    with pytest.raises(DockerWorkerError, match="unsafe_worker_path"):
        WorkerJournal(link, initialize=True)
    assert not list(actual.iterdir())


def test_binding_rejects_arbitrary_engine_effects(setup):
    journal, _, _, item = setup
    for key, value in (("Privileged", True), ("PidMode", "host"), ("Binds", ["/:/host"]), ("Devices", [{"PathOnHost": "/dev/sda"}])):
        body = json.loads(item.specification)
        body["HostConfig"][key] = value
        with pytest.raises(DockerWorkerError, match="invalid_binding"):
            ContainerBinding(item.name, item.platform, item.image_id, json.dumps(body).encode())


def unix_fixture(tmp_path, response, *, delay=0):
    # macOS AF_UNIX is limited to 104 bytes; pytest's default temp path is longer.
    directory = tempfile.TemporaryDirectory(prefix="lpw-", dir="/private/tmp" if Path("/private/tmp").is_dir() else "/tmp")
    path = Path(directory.name) / "docker.sock"
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(str(path))
    os.chmod(path, 0o600)
    listener.listen(1)
    captured = []
    def serve():
        client, _ = listener.accept()
        with client:
            client.settimeout(2)
            request = client.recv(65536)
            while request and b'\r\n\r\n' not in request:
                request += client.recv(65536 - len(request))
            if request:
                head, body = request.split(b'\r\n\r\n', 1)
                length = next((int(line.split(b':', 1)[1]) for line in head.split(b'\r\n')
                               if line.lower().startswith(b'content-length:')), 0)
                while len(body) < length:
                    part = client.recv(length - len(body))
                    if not part:
                        break
                    request += part
                    body += part
            captured.append(request)
            time.sleep(delay)
            try:
                client.sendall(response)
            except OSError:
                pass
        listener.close()
        directory.cleanup()
    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    return path, captured, thread


def test_unix_engine_uses_fixed_http_route_without_ambient_proxies(tmp_path, monkeypatch):
    monkeypatch.setenv("HTTP_PROXY", "http://must-not-be-used.test")
    path, captured, thread = unix_fixture(tmp_path, b'HTTP/1.1 404 Not Found\r\nContent-Length: 2\r\n\r\n{}')
    engine = UnixDockerEngine(path, socket_uid=os.getuid(), peer_uid=lambda _: os.getuid())
    assert engine.inspect_container("larenor-" + "b" * 32) is None
    thread.join(1)
    assert captured[0].startswith(b"GET /v1.47/containers/larenor-" + b"b" * 32 + b"/json HTTP/1.1\r\n")
    assert b"Authorization" not in captured[0]


def test_unix_engine_deadline_and_malformed_reply_are_static(tmp_path):
    path, _, thread = unix_fixture(tmp_path, b'', delay=1)
    engine = UnixDockerEngine(path, timeout=0.04, socket_uid=os.getuid(), peer_uid=lambda _: os.getuid())
    start = time.monotonic()
    with pytest.raises(DockerWorkerError, match="engine_unavailable"):
        engine.inspect_container("larenor-" + "b" * 32)
    assert time.monotonic() - start < 0.5
    thread.join(2)


def test_unix_engine_rejects_wrong_peer_before_sending_request(tmp_path):
    path, captured, thread = unix_fixture(tmp_path, b'')
    engine = UnixDockerEngine(path, socket_uid=os.getuid(), peer_uid=lambda _: os.getuid() + 1)
    with pytest.raises(DockerWorkerError, match="engine_peer_rejected"):
        engine.inspect_container("larenor-" + "b" * 32)
    thread.join(1)
    assert captured == [b'']


def test_start_rejects_replacement_even_with_identical_labels_and_configuration(setup):
    _, engine, worker, item = setup
    worker.apply(command(), item)
    engine.container['Id'] = '9' * 64
    result = worker.apply(command('start_container', dispatch='5' * 32), item)
    assert (result.state, result.code) == ('needs_attention', 'resource_conflict')
    assert not any(call[0] == 'start' for call in engine.calls)


@pytest.mark.parametrize('damage', ['digest', 'code', 'container', 'command', 'schema'])
def test_journal_damage_never_leaks_raw_data_or_recreates(setup, damage):
    journal, engine, worker, item = setup
    worker.apply(command(), item)
    if damage == 'schema':
        journal._database.execute('DROP TABLE operations')
    elif damage == 'command':
        import hashlib
        row = journal._database.execute('SELECT payload FROM operations').fetchone()
        payload = json.loads(row[0])
        payload['command']['job_id'] = '9' * 32
        raw = json.dumps(payload).encode()
        journal._database.execute('UPDATE operations SET payload=?,digest=?', (raw, hashlib.sha256(raw).hexdigest()))
    else:
        journal._database.execute(f'UPDATE operations SET {damage}=?', ('sensitive-raw-value',))
    with pytest.raises(DockerWorkerError, match='^journal_unavailable$') as error:
        worker.observe('4' * 32, 'create_container')
    assert 'sensitive' not in repr(error.value)
    assert len([call for call in engine.calls if call[0] == 'create']) == 1


def test_intent_is_committed_before_engine_mutation_and_survives_lost_local_receipt(setup, monkeypatch):
    import sqlite3
    journal, engine, worker, item = setup
    original = engine.create_container
    def crash_after_mutation(value):
        independent = sqlite3.connect(journal.directory / 'journal.sqlite')
        try:
            assert independent.execute('SELECT state FROM operations').fetchone()[0] == 'mutating'
        finally:
            independent.close()
        original(value)
        raise SystemExit('simulated worker process loss')
    monkeypatch.setattr(engine, 'create_container', crash_after_mutation)
    with pytest.raises(SystemExit):
        worker.apply(command(), item)
    assert worker.reconcile('4' * 32, 'create_container').code == 'container_created'
    assert len([call for call in engine.calls if call[0] == 'create']) == 1


def test_process_lock_refuses_parallel_worker_and_preserves_journal(setup):
    journal, engine, worker, item = setup
    other = WorkerJournal(journal.directory)
    try:
        with other.locked():
            with pytest.raises(DockerWorkerError, match='worker_busy'):
                worker.apply(command(), item)
        assert not engine.calls
        assert worker.apply(command(), item).code == 'container_created'
    finally:
        other.close()


def test_worker_rejects_writable_ancestor_and_symlinked_sqlite_sidecar(tmp_path):
    parent = tmp_path / 'unsafe'
    parent.mkdir(mode=0o777)
    parent.chmod(0o777)
    safe = parent / 'safe'
    safe.mkdir(mode=0o700)
    with pytest.raises(DockerWorkerError, match='unsafe_worker_path'):
        WorkerJournal(safe / 'worker', initialize=True)
    directory = tmp_path / 'worker'
    journal = WorkerJournal(directory, initialize=True)
    journal.close()
    victim = tmp_path / 'victim'
    victim.write_text('untouched')
    (directory / 'journal.sqlite-journal').symlink_to(victim)
    with pytest.raises(DockerWorkerError, match='unsafe_worker_path'):
        WorkerJournal(directory)
    assert victim.read_text() == 'untouched'


def test_all_packaged_component_plans_are_verified_without_engine_access(monkeypatch):
    from larenor_server.plugins.catalog import load_catalog, plan
    from larenor_server.plugins.worker import inspect_catalog_plan
    catalog = load_catalog()
    def no_socket(*args, **kwargs):
        pytest.fail('catalog inspection must not access Docker')
    monkeypatch.setattr(socket, 'socket', no_socket)
    for entry in catalog.entries:
        selected = plan(entry, {}, 'linux/amd64')
        result = inspect_catalog_plan(selected, catalog)
        assert result['installable'] is False and result['code'] == 'worker_unverified'
        assert result['planHash'] == selected.planHash
        assert result['integrationRole'] == selected.integrationRole
        for changed in ({'installable': True}, {'planHash': '0' * 64}):
            with pytest.raises(DockerWorkerError, match='catalog_rejected'):
                inspect_catalog_plan(selected.model_copy(update=changed), catalog)


@pytest.mark.parametrize('change', ['identity', 'platform', 'configuration'])
def test_create_requires_the_exact_prepared_local_image(setup, change):
    _, engine, worker, item = setup
    image = {'Id': item.image_id, 'Os': 'linux', 'Architecture': 'amd64', 'Config': {}}
    if change == 'identity':
        image['Id'] = 'sha256:' + '9' * 64
    elif change == 'platform':
        image['Architecture'] = 'arm64'
    else:
        image['Config'] = {'Cmd': ['unexpected']}
    engine.inspect_image = lambda _: image
    assert worker.apply(command(), item).code == 'resource_conflict'
    assert not any(call[0] == 'create' for call in engine.calls)


def test_inherited_image_configuration_and_docker_defaults_are_exactly_reconciled(setup):
    journal, engine, worker, item = setup
    from dataclasses import replace
    image_config = {'Env': ['PATH=/usr/bin'], 'Labels': {'vendor': 'fixture'},
                    'Cmd': ['/opt/component'], 'WorkingDir': '/opt', 'ExposedPorts': {'8096/tcp': {}}}
    body = json.loads(item.specification)
    body['HostConfig']['RestartPolicy'] = {'Name': 'no'}
    item = replace(item, specification=json.dumps(body).encode(), image_configuration=json.dumps(image_config).encode())
    engine.image_configuration = image_config
    worker.apply(command(), item)
    assert worker.observe('4' * 32, 'create_container').code == 'container_created'
    engine.container['Config']['Labels']['unrequested'] = 'true'
    result = worker.apply(command('start_container', dispatch='5' * 32), item)
    assert result.code == 'resource_conflict'


@pytest.mark.parametrize('response', [
    b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}',
    b'HTTP/1.1 200 OK\r\nContent-Length: 1048577\r\n\r\n',
    b'HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\n{"x":1,"x":2}',
    b'HTTP/1.1 200 OK\r\nContent-Length: 14\r\n\r\n{"value":1e999}',
    b'HTTP/1.1 302 Found\r\nLocation: http://must-not-follow\r\nContent-Length: 0\r\n\r\n',
])
def test_engine_malformed_or_oversized_responses_are_bounded_and_static(tmp_path, response):
    path, _, thread = unix_fixture(tmp_path, response)
    engine = UnixDockerEngine(path, timeout=0.2, socket_uid=os.getuid(), peer_uid=lambda _: os.getuid())
    try:
        with pytest.raises(DockerWorkerError) as error:
            engine.inspect_container('larenor-' + 'b' * 32)
        assert str(error.value) in {'engine_protocol', 'engine_unavailable'}
    finally:
        thread.join(1)


def test_engine_sends_only_fixed_create_and_start_routes(setup, tmp_path):
    _, _, _, item = setup
    raw = json.dumps({'Id': '2' * 64, 'Warnings': []}).encode()
    reply = b'HTTP/1.1 201 Created\r\nContent-Length: ' + str(len(raw)).encode() + b'\r\n\r\n' + raw
    path, captured, thread = unix_fixture(tmp_path, reply)
    engine = UnixDockerEngine(path, socket_uid=os.getuid(), peer_uid=lambda _: os.getuid())
    assert engine.create_container(item) == '2' * 64
    thread.join(1)
    head, body = captured[0].split(b'\r\n\r\n', 1)
    assert head.startswith(b'POST /v1.47/containers/create?name=larenor-' + b'b' * 32 + b'&platform=linux%2Famd64 HTTP/1.1')
    assert json.loads(body) == json.loads(item.specification)
    path, captured, thread = unix_fixture(tmp_path, b'HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n')
    engine = UnixDockerEngine(path, socket_uid=os.getuid(), peer_uid=lambda _: os.getuid())
    engine.start_container('2' * 64)
    thread.join(1)
    assert captured[0].startswith(b'POST /v1.47/containers/' + b'2' * 64 + b'/start HTTP/1.1')


def test_prepared_dispatch_cannot_mutate_after_its_deadline(setup, monkeypatch):
    journal, engine, worker, item = setup
    request = command()
    inspect = engine.inspect_container
    engine.inspect_container = lambda _: (_ for _ in ()).throw(DockerWorkerError())
    assert worker.apply(request, item).state == 'prepared'
    engine.inspect_container = inspect
    monkeypatch.setattr(time, 'time', lambda: request.start_deadline + 1)
    result = worker.apply(request, item)
    assert (result.state, result.code) == ('needs_attention', 'dispatch_expired')
    assert not any(call[0] == 'create' for call in engine.calls)


def test_malformed_container_inspection_is_attention_without_raw_exception(setup):
    _, engine, worker, item = setup
    engine.lose_create_reply = True
    worker.apply(command(), item)
    engine.container['Config']['Env'] = {'secret': 'private-value'}
    result = worker.reconcile('4' * 32, 'create_container')
    assert result.code == 'resource_conflict' and 'private-value' not in repr(result)


def test_engine_rejects_untyped_resource_identifiers_without_opening_socket(monkeypatch):
    monkeypatch.setattr(socket, 'socket', lambda *args, **kwargs: pytest.fail('no socket permitted'))
    engine = UnixDockerEngine('/run/docker.sock')
    for value in (None, [], 42, '../host', 'container?x=1'):
        for operation in (engine.inspect_container, engine.inspect_image, engine.start_container):
            with pytest.raises(DockerWorkerError, match='invalid_binding'):
                operation(value)
