import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/music_manager/data/server_longform_session_api.dart';
import 'package:larenor/features/server/music_manager/domain/server_longform_session_models.dart';
import 'package:larenor/features/server/music_manager/domain/server_music_manager_models.dart';
import 'package:larenor/features/server/music_manager/presentation/server_longform_session_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import 'server_music_manager_test_support.dart';

const _uri = 'spotify://audiobook/fixture';

ServerMusicLongformItem _item() => ServerMusicLongformCatalog.fromJson({
  'requestId': 'f' * 32,
  'managerRevision': 6,
  'items': [
    {
      'uri': _uri,
      'name': 'Fixture audiobook',
      'mediaType': 'audiobook',
      'providerInstanceId': 'spotify--fixture',
      'durationSeconds': 3600.0,
      'resumePositionSeconds': 900.0,
      'fullyPlayed': false,
      'chapters': <Object>[],
    },
  ],
}).items.single;

Map<String, dynamic> _session({
  int revision = 1,
  int? deadline,
  String state = 'off',
  String? code,
  String? target,
}) => {
  'schemaVersion': 2,
  'sessionId': '1' * 32,
  'revision': revision,
  'coreId': '2' * 32,
  'homeId': '3' * 32,
  'accountId': '4' * 32,
  'installationId': 'a' * 32,
  'installationRevision': 4,
  'coreRevision': 2,
  'managerRevision': 6,
  'providerInstanceId': 'spotify--fixture',
  'mediaUri': _uri,
  'mediaType': 'audiobook',
  'title': 'Fixture audiobook',
  'durationSeconds': 3600.0,
  'positionSeconds': 900.0,
  'playbackState': 'playing',
  'sleepTimerEndsAt': deadline,
  'sleepTimerState': state,
  'sleepTimerCode': code,
  'sleepTimerTargetId': target,
  'bookmarks': <Object>[],
  'ownedByCurrentSession': true,
  'updatedAt': 1788609600,
};

void main() {
  test(
    'client binds sleep deadline to the exact verified receiver and queue',
    () async {
      final fixture = MusicManagerFixture();
      fixture
        ..playbackState = 'playing'
        ..positionSeconds = 900
        ..currentItemUri = _uri;
      addTearDown(fixture.account.dispose);
      await fixture.account.initialize();
      final manager = ServerMusicManager.fromJson(fixture.manager());
      final item = _item();
      final before = ServerLongformSession.fromJson(_session());
      final deadline = DateTime.fromMillisecondsSinceEpoch(
        1788611400 * 1000,
        isUtc: true,
      );
      fixture.respond = (request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body.keys.toSet(), {
          'schemaVersion',
          'requestId',
          'installationId',
          'expectedInstallationRevision',
          'expectedCoreRevision',
          'expectedManagerRevision',
          'limit',
          'mediaUri',
          'providerInstanceId',
          'takeover',
          'expectedRevision',
          'positionSeconds',
          'playbackState',
          'sleepTimerEndsAt',
          'sleepTimerTarget',
          'bookmarks',
        });
        expect(body['schemaVersion'], 2);
        expect(body['sleepTimerEndsAt'], 1788611400);
        expect(body['sleepTimerTarget'], {
          'targetId': 'homepod-living',
          'expectedProvider': 'airplay--main',
          'expectedTargetKind': 'homepod',
          'expectedQueueId': 'homepod-living',
          'expectedGroupMembers': <Object>[],
        });
        return fixture.json({
          'session': _session(
            revision: 2,
            deadline: 1788611400,
            state: 'scheduled',
            code: 'scheduled',
            target: 'homepod-living',
          ),
        });
      };

      final value = await fixture.account.withSession(
        (api, login) =>
            ServerLongformSessionApi(
              api,
              login.accessToken,
              requestId: () => '5' * 32,
            ).update(
              manager: manager,
              item: item,
              session: before,
              positionSeconds: 900,
              playbackState: ServerLongformPlaybackState.playing,
              bookmarks: const [],
              sleepTimerEndsAt: deadline,
              sleepTimerReceiver: manager.receivers.first,
            ),
      );

      expect(value.sleepTimerState, ServerLongformSleepState.scheduled);
      expect(value.sleepTimerTargetId, 'homepod-living');
      expect(value.sleepTimerEndsAt, deadline);
    },
  );

  test(
    'client rejects a timer on a queue that does not own the longform item',
    () async {
      final fixture = MusicManagerFixture();
      addTearDown(fixture.account.dispose);
      await fixture.account.initialize();
      final manager = ServerMusicManager.fromJson(fixture.manager());

      await expectLater(
        fixture.account.withSession(
          (api, login) =>
              ServerLongformSessionApi(
                api,
                login.accessToken,
                requestId: () => '5' * 32,
              ).update(
                manager: manager,
                item: _item(),
                session: ServerLongformSession.fromJson(_session()),
                positionSeconds: 900,
                playbackState: ServerLongformPlaybackState.playing,
                bookmarks: const [],
                sleepTimerEndsAt: DateTime.now().toUtc().add(
                  const Duration(minutes: 15),
                ),
                sleepTimerReceiver: manager.receivers.first,
              ),
        ),
        throwsA(
          isA<LarenorServerException>().having(
            (error) => error.code,
            'code',
            'invalid_request',
          ),
        ),
      );
    },
  );

  test('strict parser rejects contradictory timer evidence', () {
    for (final invalid in [
      _session(deadline: 1788611400),
      _session(deadline: 1788611400, state: 'scheduled', code: 'scheduled'),
      _session(state: 'enforced', code: 'effect_unknown'),
      {..._session(), 'schemaVersion': 1},
    ]) {
      expect(
        () => ServerLongformSession.fromJson(invalid),
        throwsA(
          isA<LarenorServerException>().having(
            (error) => error.code,
            'code',
            'invalid_response',
          ),
        ),
      );
    }
  });

  testWidgets(
    'visible sleep control schedules the selected verified receiver',
    (tester) async {
      final fixture = MusicManagerFixture();
      fixture
        ..playbackState = 'playing'
        ..positionSeconds = 900
        ..currentItemUri = _uri;
      addTearDown(fixture.account.dispose);
      await fixture.account.initialize();
      Map<String, dynamic>? update;
      fixture.respond = (request) async {
        if (request.url.path.endsWith('/sessions/open')) {
          return fixture.json({'session': _session()});
        }
        if (request.url.path.endsWith('/sessions/${'1' * 32}')) {
          update = jsonDecode(request.body) as Map<String, dynamic>;
          return fixture.json({
            'session': _session(
              revision: 2,
              deadline: update!['sleepTimerEndsAt'] as int,
              state: 'scheduled',
              code: 'scheduled',
              target: 'homepod-living',
            ),
          });
        }
        return fixture.response(request);
      };
      await tester.pumpWidget(
        CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ServerLongformSessionScreen(
            account: fixture.account,
            manager: ServerMusicManager.fromJson(fixture.manager()),
            item: _item(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('15'));
      await tester.pump();
      await tester.tap(find.text('Save progress'));
      await tester.pumpAndSettle();

      expect(update, isNotNull);
      expect(update!['sleepTimerTarget'], {
        'targetId': 'homepod-living',
        'expectedProvider': 'airplay--main',
        'expectedTargetKind': 'homepod',
        'expectedQueueId': 'homepod-living',
        'expectedGroupMembers': <Object>[],
      });
      expect(tester.takeException(), isNull);
    },
  );
}
