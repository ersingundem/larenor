"""Real SQLite restart/tamper boundaries; test files contain synthetic data."""
import hashlib
import tracemalloc
from fastapi.testclient import TestClient
import pytest
from conftest import auth
from test_direct_ha_migration import setup_transfer, stored, preview, confirm
from test_home_assistant_adapter import ha
from larenor_server.app import create_app
from larenor_server.errors import StartupError
from larenor_server.home_assistant import migration_schema as schema


def committed(server,ha):
    app,client,admin,record,path,base,body=setup_transfer(server,ha)
    p=preview(client,admin,base,body)
    assert confirm(client,admin,base,body,p).status_code==201
    return app,client,admin,record,path,base,body


def dump(app):
    with app.state.core.db.connection() as c:
        return hashlib.sha256('\n'.join(c.iterdump()).encode()).hexdigest()


@pytest.mark.parametrize('fault',['foreign_index','ignore_trigger','marker','missing_table','tag','cipher','nonce','foreign_resource'])
def test_restart_rejects_changed_owned_storage_without_reset(server,ha,fault):
    app,client,admin,_,_,base,body=committed(server,ha)
    with app.state.core.db.transaction() as c:
        statements={
            'foreign_index':'CREATE UNIQUE INDEX foreign_name ON direct_ha_migrations(resource_id)',
            'ignore_trigger':'CREATE TRIGGER foreign_name BEFORE INSERT ON direct_ha_migrations BEGIN SELECT RAISE(IGNORE); END',
            'marker':"UPDATE metadata SET value='2' WHERE key='direct_ha_schema'",
            'missing_table':'DROP TABLE direct_ha_state',
            'tag':"UPDATE direct_ha_state SET authentication_tag='"+'0'*64+"'",
            'cipher':"UPDATE direct_ha_migrations SET ciphertext=zeroblob(32)",
            'nonce':"UPDATE direct_ha_migrations SET nonce=zeroblob(11)",
            'foreign_resource':"UPDATE direct_ha_migrations SET resource_id='"+'f'*32+"'",
        }
        c.execute(statements[fault])
        if fault in ('cipher','foreign_resource'):
            # Even a recomputed inventory tag is insufficient without valid
            # authenticated ciphertext and the exact per-row AAD/scope.
            schema.update(c,app.state.core.direct_ha_migration._key,app.state.core.context)
    before=dump(app);calls=ha.calls
    with pytest.raises(StartupError,match='direct_ha_migration_storage_invalid'):
        create_app(server[2])
    assert dump(app)==before and ha.calls==calls


@pytest.mark.parametrize('field,prefix',[('request_id','c'*32),('resource_id','d'*32),('authentication_tag','a'*64)])
@pytest.mark.parametrize('suffix',['nul','plain'])
def test_byte_bound_precedes_fetch_of_giant_sqlite_metadata(server,ha,field,prefix,suffix):
    app,_,_,_,_,_,_=committed(server,ha)
    value=prefix+('\0' if suffix=='nul' else '')+'x'*4_194_304
    table='direct_ha_state' if field=='authentication_tag' else 'direct_ha_migrations'
    with app.state.core.db.transaction() as c:
        c.execute(f'UPDATE {table} SET {field}=?',(value,))
    with app.state.core.db.connection() as c:
        tracemalloc.start()
        try:
            with pytest.raises(ValueError):
                schema.validate(c,app.state.core.direct_ha_migration._key,app.state.core.context)
            _,peak=tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()
    assert peak<1_048_576


@pytest.mark.parametrize('fault',['cipher','nonce','type','rows'])
def test_payload_and_row_limits_fail_before_snapshot_materialization(server,ha,fault):
    app,client,admin,_,_,base,body=committed(server,ha)
    with app.state.core.db.transaction() as c:
        if fault=='cipher': c.execute('UPDATE direct_ha_migrations SET ciphertext=zeroblob(4194304)')
        elif fault=='nonce': c.execute('UPDATE direct_ha_migrations SET nonce=zeroblob(4194304)')
        elif fault=='type': c.execute("UPDATE direct_ha_migrations SET ciphertext='text'")
        else:
            row=c.execute('SELECT * FROM direct_ha_migrations').fetchone()
            c.executemany('INSERT INTO direct_ha_migrations VALUES(?,?,?,?)',
                [(f'{i:032x}',row['resource_id'],row['nonce'],row['ciphertext']) for i in range(256)])
    with app.state.core.db.connection() as c:
        tracemalloc.start()
        try:
            with pytest.raises(ValueError):
                schema.rows(c)
            _,peak=tracemalloc.get_traced_memory()
        finally: tracemalloc.stop()
    assert peak<1_048_576
    calls=ha.calls
    r=client.get(base+'/direct-migration/results/'+body['requestId'],headers=auth(admin))
    assert r.status_code==503 and len(r.content)<200 and ha.calls==calls


def test_additive_domain_preserves_existing_accepted_ha_service_and_resources(server,ha):
    app,client,admin,_,_,base,body=committed(server,ha)
    before=stored(app);calls=ha.calls
    # Historical absence of this new domain is an additive migration, not a
    # reset of any previously accepted service/resource/binding table.
    with app.state.core.db.transaction() as c:
        c.execute('DROP TABLE direct_ha_migrations');c.execute('DROP TABLE direct_ha_state')
        c.execute("DELETE FROM metadata WHERE key='direct_ha_schema'")
    with TestClient(create_app(server[2])) as restarted:
        assert stored(app)==before
        assert restarted.get(base+'/direct-migration/results/'+body['requestId'],headers=auth(admin)).status_code==404
        assert ha.calls==calls
