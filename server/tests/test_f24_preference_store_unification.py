from fastapi.testclient import TestClient
from conftest import auth, ready
from larenor_server.app import create_app


def roots(app):
    context = app.state.core.context
    scope = f'{context.coreId}/{context.homeId}'
    return '/api/v1/media/jellyfin/preferences/'+scope, '/api/v1/media/language-preferences/'+scope


def test_legacy_and_player_endpoints_share_revision_and_encrypted_record(server):
    app, client, _settings, _clock = server
    actor = ready(server)
    legacy, player = roots(app)
    saved = client.put(legacy, headers=auth(actor), json={
        'schemaVersion':1, 'expectedRevision':0,
        'audioLanguage':'zh-hant-tw', 'subtitleLanguage':'off',
    })
    assert saved.status_code == 200, saved.text
    observed = client.get(player, headers=auth(actor))
    assert observed.status_code == 200, observed.text
    current = observed.json()
    assert current['preference']['audioLanguage'] == 'zh-hant-tw'
    assert current['preference']['revision'] == 1
    updated = client.put(player, headers=auth(actor), json={
        'schemaVersion':1, 'requestId':'d'*32,
        'expectedAccountRevision':current['authority']['accountRevision'],
        'expectedRevision':1, 'audioLanguage':'en', 'subtitleLanguage':None,
    })
    assert updated.status_code == 200, updated.text
    assert client.get(legacy, headers=auth(actor)).json()['preference']['audioLanguage'] == 'en'
    assert client.put(legacy, headers=auth(actor), json={
        'schemaVersion':1,'expectedRevision':1,'audioLanguage':'tr','subtitleLanguage':None,
    }).status_code == 409
    with app.state.core.db.connection() as connection:
        assert connection.execute('SELECT COUNT(*) FROM jellyfin_track_preferences').fetchone()[0] == 0
        assert connection.execute('SELECT COUNT(*) FROM media_language_preferences').fetchone()[0] == 1


def seed_legacy(app, owner_id, *, audio='tr', revision=3):
    row = dict(owner_id=owner_id, revision=revision, audio_language=audio,
               subtitle_language='off', updated_at=float(app.state.core.settings.clock()))
    row['authentication_tag'] = app.state.core.jellyfin_track_preferences._tag(row)
    with app.state.core.db.transaction() as connection:
        connection.execute('INSERT INTO jellyfin_track_preferences VALUES(?,?,?,?,?,?)',
            tuple(row[key] for key in ('owner_id','revision','audio_language','subtitle_language','updated_at','authentication_tag')))


def test_startup_migrates_authenticated_legacy_preference_once(server):
    app, client, settings, _clock = server
    actor = ready(server)
    legacy, player = roots(app)
    seed_legacy(app, actor['user']['id'])
    restarted_app = create_app(settings)
    with TestClient(restarted_app) as restarted:
        migrated = restarted.get(player, headers=auth(actor))
        assert migrated.status_code == 200, migrated.text
        assert migrated.json()['preference']['audioLanguage'] == 'tr'
        assert migrated.json()['preference']['revision'] == 3
        assert restarted.get(legacy, headers=auth(actor)).json()['preference']['revision'] == 3
    again = create_app(settings)
    with again.state.core.db.connection() as connection:
        assert connection.execute('SELECT COUNT(*) FROM jellyfin_track_preferences').fetchone()[0] == 0
        assert connection.execute('SELECT revision FROM media_language_preferences').fetchone()[0] == 3


def test_current_explicit_player_preference_wins_over_legacy_import(server):
    app, client, settings, _clock = server
    actor = ready(server)
    legacy, player = roots(app)
    saved = client.put(legacy, headers=auth(actor), json={
        'schemaVersion':1,'expectedRevision':0,'audioLanguage':'en','subtitleLanguage':None,
    })
    assert saved.status_code == 200
    seed_legacy(app, actor['user']['id'], audio='tr', revision=5)
    with TestClient(create_app(settings)) as restarted:
        assert restarted.get(player, headers=auth(actor)).json()['preference']['audioLanguage'] == 'en'
        assert restarted.get(legacy, headers=auth(actor)).json()['preference']['revision'] == 1
