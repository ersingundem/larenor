"""Durable stack observations: private SQLite and synthetic workers only."""

from concurrent.futures import ThreadPoolExecutor
from threading import Event
import json

import pytest

from conftest import auth, ready
from test_media_preparations_api import create_preparation
from larenor_server.errors import ApiError, StartupError
from larenor_server.plugins.media_inspection_models import (
    CancelMediaInspectionRequest, CreateMediaInspectionRequest, MediaInspection,
)
from larenor_server.plugins.media_inspections import MediaInspectionManagement
from larenor_server.plugins.preflight_models import PreflightResult


class Backend:
    def __init__(self):
        self.calls = []
        self.action = None

    def inspect_stack(self, plan):
        self.calls.append(plan)
        if self.action:
            return self.action(plan)
        return PreflightResult.model_validate({
            'catalogDigest': plan.catalogDigest, 'planHash': plan.planHash,
            'platform': plan.platform, 'checkedAt': '2026-09-05T12:00:00.000Z',
            'checks': [{'code': 'docker_engine', 'status': 'failed'}],
        })


@pytest.fixture
def inspections(server):
    app, client, _, _ = server
    pair = ready(server)
    manager = app.state.core.media_inspections
    backend = Backend()
    manager.backend = backend
    actor = app.state.core.auth.authenticate(pair['accessToken'])
    _, preparation = create_preparation(client, pair)
    body = CreateMediaInspectionRequest(requestId='a' * 32, preparationId=preparation['id'],
                                        expectedRevision=1, planHash=preparation['plan']['planHash'])
    return manager, backend, actor, pair, body


def error(code, function):
    with pytest.raises(ApiError) as caught:
        function()
    assert caught.value.code == code


def start(inspections):
    manager, _, actor, _, body = inspections
    return manager.create(actor, body)['inspection']


def clone(manager, server):
    return MediaInspectionManagement(manager.db, manager.auth, manager.settings,
                                     server[2].key_file.read_bytes(), manager.preparations, manager.backend)


def test_durable_encrypted_stack_observation_is_not_installation(server, inspections):
    manager, backend, actor, _, body = inspections
    record = start(inspections)
    assert record['state'] == record['phase'] == 'queued'
    assert record['revision'] == record['preparationRevision'] == 1
    assert record['preparationId'] == body.preparationId
    assert record['coreId'] == manager.preparations.context.coreId
    assert record['homeId'] == manager.preparations.context.homeId
    assert record['result'] is None and backend.calls == []
    with manager.db.connection() as db:
        row = db.execute('SELECT * FROM media_inspections').fetchone()
        assert len(row['nonce']) == 12 and b'"components"' not in row['ciphertext']
        assert record['planHash'].encode() not in row['ciphertext']
    restarted = clone(manager, server)
    restarted.validate_storage()
    assert restarted.get(actor, record['id'])['inspection'] == record
    finished = restarted.tick()['inspection']
    assert finished['state'] == 'succeeded' and finished['revision'] == 3
    assert finished['result'].checks[0].status == 'failed'
    assert len(backend.calls) == 1 and backend.calls[0].installAvailable is False
    assert all(not component.plan.installable for component in backend.calls[0].components)


def test_same_request_replays_terminal_record_but_new_request_reobserves(inspections):
    manager, backend, actor, _, body = inspections
    initial = manager.create(actor, body)
    assert manager.create(actor, body) == initial
    error('media_inspection_conflict', lambda: manager.create(actor, body.model_copy(update={'planHash': '0' * 64})))
    error('media_inspection_conflict', lambda: manager.create(actor, body.model_copy(update={'requestId': 'b' * 32})))
    terminal = manager.tick()
    assert manager.create(actor, body) == terminal
    assert manager.create(actor, body.model_copy(update={'requestId': 'b' * 32}))['inspection']['id'] != initial['inspection']['id']
    assert len(backend.calls) == 1


def test_concurrent_replay_and_distinct_request_admission_are_atomic(inspections):
    manager, _, actor, _, body = inspections
    with ThreadPoolExecutor(max_workers=4) as pool:
        responses = list(pool.map(lambda _: manager.create(actor, body), range(4)))
    assert len({response['inspection']['id'] for response in responses}) == 1
    assert len(manager.list(actor)['inspections']) == 1


@pytest.mark.parametrize('change,code', [({'expectedRevision': 2}, 'revision_conflict'),
                                        ({'planHash': '0' * 64}, 'media_preparation_changed'),
                                        ({'preparationId': '0' * 32}, 'not_found')])
def test_create_requires_exact_current_preparation(inspections, change, code):
    manager, _, actor, _, body = inspections
    error(code, lambda: manager.create(actor, body.model_copy(update=change)))


def test_cancelled_preparation_rejects_new_work_but_preserves_replay(server, inspections):
    manager, backend, actor, pair, body = inspections
    initial = manager.create(actor, body)
    response = server[1].post('/api/v1/admin/media/preparations/' + body.preparationId + '/cancel',
                              headers=auth(pair), json={'expectedRevision': 1})
    assert response.status_code == 200
    assert manager.create(actor, body) == initial
    result = manager.tick()['inspection']
    assert result['state'] == 'needs_attention' and result['errorCode'] == 'preparation_changed'
    assert backend.calls == []
    error('media_preparation_changed', lambda: manager.create(actor, body.model_copy(update={'requestId': 'b' * 32})))


def test_unconfigured_capability_blocks_new_work_and_reports_no_install(inspections):
    manager, _, actor, _, body = inspections
    manager.backend = None
    assert manager.capabilities(actor) == {'inspectionConfigured': False, 'installAvailable': False}
    error('plugin_worker_unavailable', lambda: manager.create(actor, body))


@pytest.mark.parametrize('bound', ['MAX_ACTIVE', 'MAX_INSPECTIONS'])
def test_bounded_admission(inspections, monkeypatch, bound):
    import larenor_server.plugins.media_inspections as module
    manager, _, actor, _, body = inspections
    monkeypatch.setattr(module, bound, 0)
    error('media_inspection_limit_reached', lambda: manager.create(actor, body))
    assert manager.list(actor)['inspections'] == []


def test_queued_cancel_is_idempotent_and_stale_revision_conflicts(inspections):
    manager, backend, actor, _, _ = inspections
    record = start(inspections)
    error('revision_conflict', lambda: manager.cancel(actor, record['id'], CancelMediaInspectionRequest(expectedRevision=2)))
    cancelled = manager.cancel(actor, record['id'], CancelMediaInspectionRequest(expectedRevision=1))['inspection']
    assert cancelled['state'] == 'cancelled' and cancelled['revision'] == 2 and cancelled['cancelRequested']
    assert manager.cancel(actor, record['id'], CancelMediaInspectionRequest(expectedRevision=2))['inspection'] == cancelled
    assert manager.tick() is None and backend.calls == []


def test_worker_runs_outside_db_transaction_and_running_cancel_wins(server, inspections):
    manager, backend, actor, _, _ = inspections
    record = start(inspections)
    entered, release = Event(), Event()
    def work(plan):
        entered.set()
        assert release.wait(5)
        return Backend().inspect_stack(plan)
    backend.action = work
    with ThreadPoolExecutor(max_workers=2) as pool:
        future = pool.submit(manager.tick)
        try:
            assert entered.wait(5)
            current = manager.get(actor, record['id'])['inspection']
            assert current['state'] == 'running'
            cancelled = manager.cancel(actor, record['id'], CancelMediaInspectionRequest(expectedRevision=2))['inspection']
            assert cancelled['state'] == 'running' and cancelled['cancelRequested']
            assert clone(manager, server).tick() is None
        finally:
            release.set()
        terminal = future.result()['inspection']
    assert terminal['state'] == 'cancelled' and terminal['result'] is None and terminal['revision'] == 4


@pytest.mark.parametrize('when', ['before', 'during'])
@pytest.mark.parametrize('mutation', ['logout', 'cancel_preparation', 'catalog'])
def test_authority_preparation_and_catalog_rechecked_around_observation(server, inspections, monkeypatch, when, mutation):
    manager, backend, _, pair, body = inspections
    start(inspections)
    def change():
        if mutation == 'logout':
            assert server[1].post('/api/v1/auth/logout', headers=auth(pair)).status_code == 204
        elif mutation == 'cancel_preparation':
            assert server[1].post('/api/v1/admin/media/preparations/' + body.preparationId + '/cancel',
                                  headers=auth(pair), json={'expectedRevision': 1}).status_code == 200
        else:
            monkeypatch.setattr('larenor_server.plugins.media_inspections.load_catalog', lambda: (_ for _ in ()).throw(ValueError('private /path')))
    if when == 'before':
        change()
    else:
        def work(plan):
            change()
            return Backend().inspect_stack(plan)
        backend.action = work
    record = manager.tick()['inspection']
    assert record['state'] == 'needs_attention'
    assert record['errorCode'] == {'logout': 'authority_changed', 'cancel_preparation': 'preparation_changed', 'catalog': 'catalog_changed'}[mutation]
    assert record['result'] is None and len(backend.calls) == (when == 'during')


def test_restart_after_uncertain_worker_response_revalidates_before_repeating(server, inspections):
    manager, backend, actor, _, _ = inspections
    record = start(inspections)
    backend.action = lambda _: (_ for _ in ()).throw(SystemExit())
    with pytest.raises(SystemExit):
        manager.tick()
    assert manager.get(actor, record['id'])['inspection']['state'] == 'running'
    backend.action = None
    restarted = clone(manager, server)
    restarted.validate_storage()
    result = restarted.tick()['inspection']
    assert result['state'] == 'succeeded' and result['revision'] == 4 and len(backend.calls) == 2


@pytest.mark.parametrize('mutation', ['exception', 'dict', 'catalogDigest', 'planHash', 'platform'])
def test_worker_failures_and_forged_result_are_static(inspections, mutation):
    manager, backend, _, _, _ = inspections
    start(inspections)
    def work(plan):
        if mutation == 'exception':
            raise RuntimeError('credential-secret /private/path')
        result = Backend().inspect_stack(plan)
        if mutation == 'dict':
            return result.model_dump()
        return result.model_copy(update={mutation: 'linux/arm64' if mutation == 'platform' else '0' * 64})
    backend.action = work
    result = manager.tick()['inspection']
    assert result['state'] == 'failed' and result['result'] is None
    assert result['errorCode'] == ('worker_unavailable' if mutation == 'exception' else 'invalid_worker_result')
    assert 'credential-secret' not in repr(result)


@pytest.mark.parametrize('column,value', [
    ('id', 'f' * 32), ('sequence', 8), ('revision', 2), ('actor_id', 'e' * 32),
    ('actor_revision', 8), ('family_id', 'd' * 32), ('request_id', 'c' * 32),
    ('preparation_id', 'b' * 32), ('state', 'running'), ('phase', 'complete'),
    ('cancel_requested', 1), ('error_code', 'worker_unavailable'), ('created_at', 1), ('updated_at', 2),
    ('nonce', b'x' * 12), ('ciphertext', b'x' * 40),
])
def test_every_storage_routing_field_is_aad_bound(server, inspections, column, value):
    manager, _, actor, _, _ = inspections
    start(inspections)
    with manager.db.transaction() as db:
        db.execute(f'UPDATE media_inspections SET {column}=?', (value,))
    error('media_inspection_storage_unavailable', lambda: manager.list(actor))
    with pytest.raises(StartupError, match='^invalid_media_inspections_storage$'):
        clone(manager, server).validate_storage()


def test_history_survives_catalog_upgrade_but_cannot_dispatch(inspections, monkeypatch):
    manager, _, actor, _, body = inspections
    record = start(inspections)
    monkeypatch.setattr('larenor_server.plugins.media_inspections.verify_media_stack_plan', lambda *_: (_ for _ in ()).throw(ValueError()))
    manager.validate_storage()
    assert manager.get(actor, record['id'])['inspection'] == record
    assert manager.create(actor, body)['inspection'] == record
    assert manager.tick()['inspection']['errorCode'] == 'catalog_changed'


def test_clock_regression_and_pagination_preserve_history(server, inspections):
    manager, _, actor, _, body = inspections
    records = []
    for i in range(3):
        record = manager.create(actor, body.model_copy(update={'requestId': f'{i:032x}'}))['inspection']
        server[3].now -= 20
        terminal = manager.cancel(actor, record['id'], CancelMediaInspectionRequest(expectedRevision=1))['inspection']
        assert terminal['updatedAt'] == terminal['createdAt']
        records.append(terminal)
    page = manager.list(actor, limit=2)
    assert page['inspections'] == list(reversed(records[1:]))
    assert manager.list(actor, before=page['nextBefore'], limit=2) == {'inspections': records[:1], 'nextBefore': None}


@pytest.mark.parametrize('change', [{'state': 'succeeded'}, {'phase': 'complete'}, {'cancelRequested': True},
                                  {'preparationRevision': True}, {'revision': True}, {'revision': 0},
                                  {'updatedAt': '2020-01-01T00:00:00.000Z'}, {'result': {}},
                                  {'errorCode': 'authority_changed'}, {'coreId': 'X' * 32}])
def test_public_contract_rejects_incoherent_or_non_strict_records(inspections, change):
    value = start(inspections)
    with pytest.raises(ValueError):
        MediaInspection.model_validate(value | change)
