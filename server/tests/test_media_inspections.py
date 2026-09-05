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


@pytest.mark.parametrize('kind', ['symlink', 'public', 'hardlink', 'directory'])
def test_dispatch_lock_requires_private_owned_single_file(server, inspections, kind):
    manager, backend, _, _, _ = inspections
    start(inspections)
    path = server[2].data_dir / '.media-inspections.lock'
    if kind == 'directory':
        path.mkdir()
    else:
        target = server[2].data_dir / 'fixture-lock'
        target.write_bytes(b'')
        target.chmod(0o600)
        if kind == 'symlink':
            path.symlink_to(target)
        elif kind == 'hardlink':
            import os
            os.link(target, path)
        else:
            path.write_bytes(b'')
            path.chmod(0o644)
    error('media_inspection_storage_unavailable', manager.tick)
    assert backend.calls == []


@pytest.mark.parametrize('mutation', ['demoted', 'disabled', 'password', 'revision', 'expired', 'removed'])
def test_original_authority_binding_survives_history_without_authorizing_dispatch(inspections, mutation):
    manager, backend, actor, _, _ = inspections
    start(inspections)
    with manager.db.transaction() as db:
        if mutation == 'expired':
            db.execute('UPDATE session_families SET expires_at=1 WHERE id=?', (actor.family_id,))
        elif mutation == 'removed':
            db.execute('DELETE FROM session_tokens WHERE family_id=?', (actor.family_id,))
            db.execute('DELETE FROM session_families WHERE id=?', (actor.family_id,))
        else:
            field, value = {'demoted': ('role', 'member'), 'disabled': ('disabled', 1),
                            'password': ('must_change_password', 1), 'revision': ('revision', 9)}[mutation]
            db.execute(f'UPDATE users SET {field}=? WHERE id=?', (value, actor.id))
    manager.validate_storage()
    record = manager.tick()['inspection']
    assert record['state'] == 'needs_attention' and record['errorCode'] == 'authority_changed'
    assert backend.calls == []


def test_access_rotation_preserves_work_but_stale_principal_cannot_read_or_replay(inspections):
    manager, _, actor, pair, body = inspections
    start(inspections)
    replacement = manager.auth.refresh(pair['refreshToken'], 'synthetic')
    assert manager.tick()['inspection']['state'] == 'succeeded'
    error('invalid_session', lambda: manager.create(actor, body))
    current = manager.auth.authenticate(replacement['accessToken'])
    assert manager.create(current, body)['inspection']['state'] == 'succeeded'


def test_context_change_never_returns_mixed_history_and_stops_dispatch(inspections):
    manager, backend, actor, _, body = inspections
    record = start(inspections)
    manager.preparations.context = manager.preparations.context.model_copy(update={'homeId': 'f' * 32})
    for action in (lambda: manager.get(actor, record['id']), lambda: manager.list(actor), lambda: manager.create(actor, body)):
        error('media_context_changed', action)
    result = manager.tick()['inspection']
    assert result['state'] == 'needs_attention' and result['errorCode'] == 'context_changed'
    assert backend.calls == []
    with pytest.raises(StartupError, match='invalid_media_inspections_storage'):
        manager.validate_storage()


def test_preparation_missing_after_queue_is_attention_not_an_unbound_observation(inspections):
    manager, backend, _, _, body = inspections
    start(inspections)
    with manager.db.transaction() as db:
        db.execute('DELETE FROM media_preparations WHERE id=?', (body.preparationId,))
    assert manager.tick()['inspection']['errorCode'] == 'preparation_changed'
    assert backend.calls == []


def test_disabled_worker_after_admission_is_explicit_failed(inspections):
    manager, _, _, _, _ = inspections
    start(inspections)
    manager.backend = None
    assert manager.tick()['inspection']['errorCode'] == 'worker_unavailable'


def test_interrupted_running_cancellation_recovers_without_worker(server, inspections):
    manager, backend, actor, _, _ = inspections
    record = start(inspections)
    backend.action = lambda _: (_ for _ in ()).throw(SystemExit())
    with pytest.raises(SystemExit):
        manager.tick()
    manager.cancel(actor, record['id'], CancelMediaInspectionRequest(expectedRevision=2))
    assert clone(manager, server).tick()['inspection']['state'] == 'cancelled'
    assert len(backend.calls) == 1


@pytest.mark.parametrize('method,args', [('get', ['bad']), ('cancel', ['bad', None]), ('get', ['f' * 32])])
def test_internal_identifier_boundary(inspections, method, args):
    manager, _, actor, _, _ = inspections
    error('not_found' if args[0] == 'f' * 32 else 'invalid_request', lambda: getattr(manager, method)(actor, *args))


@pytest.mark.parametrize('kwargs', [{'limit': True}, {'limit': 11}, {'before': 0}, {'before': True}])
def test_internal_paging_boundary(inspections, kwargs):
    manager, _, actor, _, _ = inspections
    error('invalid_request', lambda: manager.list(actor, **kwargs))


def test_internal_forged_model_copy_cannot_bypass_strict_request_validation(inspections):
    manager, _, actor, _, body = inspections
    error('invalid_request', lambda: manager.create(actor, body.model_copy(update={'expectedRevision': True})))
    error('invalid_request', lambda: manager.create(actor, {}))


@pytest.mark.parametrize('mutation', ['requestId', 'preparationId', 'planHash', 'expectedRevision', 'plan_self_hash'])
def test_authenticated_payload_must_still_match_routing_and_plan_self_hash(inspections, mutation):
    manager, _, actor, _, _ = inspections
    start(inspections)
    with manager.db.transaction() as db:
        row = dict(db.execute('SELECT * FROM media_inspections').fetchone())
        decoded = json.loads(manager._cipher.decrypt(row['nonce'], row['ciphertext'], manager._aad(row)))
        if mutation == 'plan_self_hash':
            decoded['plan']['settings']['instanceName'] = 'changed'
        else:
            decoded['request'][mutation] = 2 if mutation == 'expectedRevision' else 'f' * (64 if mutation == 'planHash' else 32)
        ciphertext = manager._cipher.encrypt(row['nonce'], json.dumps(decoded).encode(), manager._aad(row))
        db.execute('UPDATE media_inspections SET ciphertext=?', (ciphertext,))
    error('media_inspection_storage_unavailable', lambda: manager.list(actor))


@pytest.mark.parametrize('mutation', ['marker', 'missing_table', 'missing_marker', 'columns', 'index', 'unique'])
def test_empty_current_schema_requires_exact_semantic_structure(server, inspections, mutation):
    from larenor_server.plugins.media_inspection_schema import migrate_media_inspections
    manager = inspections[0]
    with manager.db.transaction() as db:
        if mutation == 'marker':
            db.execute("UPDATE metadata SET value='9' WHERE key='media_inspections_schema'")
        elif mutation == 'missing_table':
            db.execute('DROP TABLE media_inspections')
        elif mutation == 'missing_marker':
            db.execute("DELETE FROM metadata WHERE key='media_inspections_schema'")
        elif mutation == 'columns':
            db.execute('ALTER TABLE media_inspections ADD COLUMN secret TEXT')
        elif mutation == 'index':
            db.execute('DROP INDEX media_inspections_state')
        else:
            source = db.execute("SELECT sql FROM sqlite_master WHERE name='media_inspections'").fetchone()[0]
            db.execute('DROP TABLE media_inspections')
            db.execute(source.replace('UNIQUE(actor_id,request_id)', 'CHECK(1)'))
            db.execute('CREATE INDEX media_inspections_state ON media_inspections(state,sequence)')
    with manager.db.transaction() as db, pytest.raises(StartupError, match='^media_inspections_schema_unsupported$'):
        migrate_media_inspections(db)


def test_migration_rollback_preserves_existing_context_and_records(server, inspections, monkeypatch):
    import sqlite3
    import larenor_server.core as core_module
    from larenor_server.app import create_app
    manager = inspections[0]
    with manager.db.transaction() as db:
        db.execute('DROP TABLE media_inspections')
        db.execute("DELETE FROM metadata WHERE key='media_inspections_schema'")
    original = core_module.migrate_media_inspections
    def interrupted(connection):
        original(connection)
        raise sqlite3.OperationalError('secret-path')
    with monkeypatch.context() as patch:
        patch.setattr(core_module, 'migrate_media_inspections', interrupted)
        with pytest.raises(StartupError, match='^storage_initialization_failed$'):
            create_app(server[2])
    with manager.db.connection() as db:
        assert db.execute("SELECT 1 FROM metadata WHERE key='media_inspections_schema'").fetchone() is None
        assert db.execute("SELECT 1 FROM sqlite_master WHERE name='media_inspections'").fetchone() is None
        assert db.execute('SELECT COUNT(*) FROM media_preparations').fetchone()[0] == 1
    assert create_app(server[2]).state.core.context == manager.preparations.context


def test_capacity_bounds_validate_retained_storage(inspections, monkeypatch):
    import larenor_server.plugins.media_inspections as module
    manager = inspections[0]
    start(inspections)
    monkeypatch.setattr(module, 'MAX_INSPECTIONS', 0)
    with pytest.raises(StartupError, match='invalid_media_inspections_storage'):
        manager.validate_storage()
    monkeypatch.setattr(module, 'MAX_INSPECTIONS', 256)
    monkeypatch.setattr(module, 'MAX_ACTIVE', 0)
    with pytest.raises(StartupError, match='invalid_media_inspections_storage'):
        manager.validate_storage()


def test_different_preparations_compete_atomically_for_last_slot(server, inspections, monkeypatch):
    import larenor_server.plugins.media_inspections as module
    manager, _, actor, pair, body = inspections
    _, prep = create_preparation(server[1], pair, request_id='2' * 32, name='other')
    second = CreateMediaInspectionRequest(requestId='b' * 32, preparationId=prep['id'], expectedRevision=1,
                                          planHash=prep['plan']['planHash'])
    monkeypatch.setattr(module, 'MAX_ACTIVE', 1)
    def submit(candidate):
        try:
            return manager.create(actor, candidate)['inspection']['state']
        except ApiError as exc:
            return exc.code
    with ThreadPoolExecutor(max_workers=2) as pool:
        assert sorted(pool.map(submit, (body, second))) == ['media_inspection_limit_reached', 'queued']


def test_real_256_retained_limit_preserves_terminal_replay(inspections):
    from larenor_server.plugins.media_inspections import MAX_INSPECTIONS, MAX_ACTIVE
    manager, _, actor, _, body = inspections
    assert MAX_INSPECTIONS == 256 and MAX_ACTIVE == 16
    for i in range(256):
        candidate = body.model_copy(update={'requestId': f'{i:032x}'})
        record = manager.create(actor, candidate)['inspection']
        manager.cancel(actor, record['id'], CancelMediaInspectionRequest(expectedRevision=1))
    error('media_inspection_limit_reached', lambda: manager.create(actor, body))
    replay = manager.create(actor, body.model_copy(update={'requestId': '0' * 32}))['inspection']
    assert replay['state'] == 'cancelled'
    manager.validate_storage()


def test_worker_model_copy_cannot_launder_boolean_capacity(inspections):
    manager, backend, _, _, _ = inspections
    start(inspections)
    def forged(plan):
        result = Backend().inspect_stack(plan)
        bad = result.checks[0].model_copy(update={'availableMiB': True})
        return result.model_copy(update={'checks': [bad]})
    backend.action = forged
    assert manager.tick()['inspection']['errorCode'] == 'invalid_worker_result'
