import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/media/archive_health/data/core_media_archive_api.dart';
import 'package:larenor/features/media/archive_health/data/media_archive_health_controller.dart';
import 'package:larenor/features/media/archive_health/domain/media_archive_health.dart';
import 'package:larenor/features/media/archive_health/presentation/media_archive_health_card.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

const installationId = '11111111111111111111111111111111';
const requestId = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';

Map<String, Object?> archiveJson({
  String state = 'attention',
  String trendState = 'ready',
}) => {
  'installationId': installationId,
  'installationRevision': 12,
  'snapshotRevision': 4,
  'state': state,
  'sourceStates': {
    'jellyfin': state == 'incomplete' ? 'stale' : 'verified',
    'sonarr': 'verified',
    'radarr': 'verified',
    'qbittorrent': 'verified',
  },
  'sourceRevisions': {
    'jellyfin': 7,
    'sonarr': 7,
    'radarr': 7,
    'qbittorrent': 7,
  },
  'counts': {
    'missing': 2,
    'broken': 1,
    'failedDownloads': 3,
    'savingCandidates': 1,
    'potentialSavingBytes': 4000,
  },
  'issues': const [],
  'suggestions': const [],
  'savingsPlan': {
    'state': 'partial',
    'laneStates': {
      'duplicate': state == 'incomplete' ? 'stale' : 'verified',
      'transcode': state == 'incomplete' ? 'stale' : 'unsupported',
      'retention': state == 'incomplete' ? 'stale' : 'verified',
    },
    'candidates': const [],
    'candidateCounts': const {'duplicate': 0, 'transcode': 0, 'retention': 0},
    'totalPotentialBytes': 0,
    'dataGaps': state == 'incomplete'
        ? const [
            {'lane': 'duplicate', 'reason': 'stale'},
            {'lane': 'transcode', 'reason': 'stale'},
            {'lane': 'retention', 'reason': 'stale'},
          ]
        : const [
            {'lane': 'transcode', 'reason': 'unsupported'},
          ],
    'truncated': false,
    'actionAvailable': false,
  },
  'weeklyTrend': {
    'state': trendState,
    'points': trendState == 'unavailable'
        ? const []
        : List.generate(12, (index) => {
            'weekStart': 1788134400 + index * 604800,
            'capturedAt': 1788138000 + index * 604800,
            'snapshotRevision': index + 1,
            'totalBytes': 1000000000000,
            'freeBytes': 300000000000 - index * 1000000000,
            'reclaimableBytes': 12000000000 + index * 100000000,
            'duplicateCandidates': index + 1,
            'lowQualityCandidates': index,
          }),
    'actionAvailable': false,
  },
  'cleanupAvailable': false,
  'generatedAt': 1788609610,
};

Map<String, Object?> installationJson() => {
  'id': installationId,
  'requestId': '22222222222222222222222222222222',
  'preparationId': '33333333333333333333333333333333',
  'inspectionId': '44444444444444444444444444444444',
  'serviceId': 'jellyfin',
  'operationId': '55555555555555555555555555555555',
  'revision': 12,
  'state': 'container_started',
  'phase': 'complete',
  'cancelRequested': false,
  'installAvailable': false,
  'steps': [
    {'stepId': '66666666666666666666666666666666', 'kind': 'create_container'},
    {'stepId': '77777777777777777777777777777777', 'kind': 'start_container'},
  ],
  'errorCode': null,
  'createdAt': '2026-09-11T10:00:00.000Z',
  'updatedAt': '2026-09-11T10:01:00.000Z',
};

void main() {
  test('Core API discovers one current installation and exact authority before read', () async {
    final calls = <http.Request>[];
    final api = LarenorServerApi(
      endpoint: ServerEndpoint('https://core.test'),
      client: MockClient((request) async {
        calls.add(request);
        if (request.url.path == '/api/v1/admin/media/installations') {
          return http.Response(
            jsonEncode({
              'installations': [installationJson()],
              'nextBefore': null,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path ==
            '/api/v1/admin/media/archive-health/authority') {
          expect(jsonDecode(request.body), {
            'requestId': requestId,
            'installationId': installationId,
            'expectedInstallationRevision': 12,
          });
          return http.Response(
            jsonEncode({
              'requestId': requestId,
              'installationId': installationId,
              'installationRevision': 12,
              'snapshotRevision': 4,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        expect(jsonDecode(request.body)['expectedSnapshotRevision'], 4);
        return http.Response(
          jsonEncode({'requestId': requestId, 'archive': archiveJson()}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(api.close);
    final value = await CoreMediaArchiveApi(
      api,
      'access',
      requestId: () => requestId,
    ).read();
    expect(value.state, MediaArchiveSnapshotState.attention);
    expect(value.counts.potentialSavingBytes, 4000);
    expect(value.weeklyTrend.points.length, 12);
    expect(value.weeklyTrend.points.last.duplicateCandidates, 12);
    expect(calls.map((e) => e.url.path), [
      '/api/v1/admin/media/installations',
      '/api/v1/admin/media/archive-health/authority',
      '/api/v1/admin/media/archive-health/read',
    ]);
  });

  test('weekly trend rejects overflow, disorder and impossible capacity', () {
    final tooMany = archiveJson();
    final trend = tooMany['weeklyTrend']! as Map<String, Object?>;
    trend['points'] = List<Object?>.from(trend['points']! as List)..add(
      (trend['points']! as List).last,
    );
    expect(
      () => MediaArchiveHealthSnapshot.fromJson(tooMany),
      throwsA(isA<LarenorServerException>()),
    );

    final impossible = archiveJson();
    final points =
        (impossible['weeklyTrend']! as Map<String, Object?>)['points']!
            as List;
    (points.last as Map<String, Object?>)['freeBytes'] = 1000000000001;
    expect(
      () => MediaArchiveHealthSnapshot.fromJson(impossible),
      throwsA(isA<LarenorServerException>()),
    );
  });

  testWidgets(
    'tablet trend chart supports 600 and 1280 widths, 2x and TalkBack',
    (tester) async {
      for (final width in [600.0, 1280.0]) {
        tester.view.physicalSize = Size(width, 1100);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        final controller = MediaArchiveHealthController(
          read: () async => MediaArchiveHealthSnapshot.fromJson(archiveJson()),
          authorized: () => true,
        );
        final semantics = tester.ensureSemantics();
        await tester.pumpWidget(
          CupertinoApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: CupertinoPageScaffold(
              child: SingleChildScrollView(
                child: MediaArchiveHealthCard(controller: controller),
              ),
            ),
          ),
        );
        await controller.refresh();
        await tester.pumpAndSettle();
        expect(find.text('12-week storage trend'), findsOneWidget);
        expect(find.byKey(const ValueKey('media-archive-weekly-trend')), findsOneWidget);
        expect(
          find.bySemanticsLabel(RegExp('Week.*total.*free.*potential')),
          findsNWidgets(12),
        );
        expect(tester.takeException(), isNull);
        semantics.dispose();
        controller.dispose();
      }
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    },
  );

  testWidgets('trend stale and unavailable remain visibly distinct', (tester) async {
    for (final entry in const {
      'stale': 'Weekly storage trend is stale.',
      'unavailable': 'Weekly storage trend is unavailable.',
    }.entries) {
      final controller = MediaArchiveHealthController(
        read: () async => MediaArchiveHealthSnapshot.fromJson(
          archiveJson(trendState: entry.key),
        ),
        authorized: () => true,
      );
      await tester.pumpWidget(
        CupertinoApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: CupertinoPageScaffold(
            child: MediaArchiveHealthCard(controller: controller),
          ),
        ),
      );
      await controller.refresh();
      await tester.pumpAndSettle();
      expect(find.text(entry.value), findsOneWidget);
      controller.dispose();
    }
  });

  test(
    'Core API fails closed on ambiguous installation and response drift',
    () async {
      Future<void> expectCode(Object body, String code) async {
        final api = LarenorServerApi(
          endpoint: ServerEndpoint('https://core.test'),
          client: MockClient(
            (_) async => http.Response(
              jsonEncode(body),
              200,
              headers: {'content-type': 'application/json'},
            ),
          ),
        );
        addTearDown(api.close);
        await expectLater(
          CoreMediaArchiveApi(api, 'access').read(),
          throwsA(
            isA<MediaArchiveReadException>().having(
              (e) => e.kind,
              'kind',
              code,
            ),
          ),
        );
      }

      await expectCode({
        'installations': [installationJson(), installationJson()],
        'nextBefore': null,
      }, 'unsupported');
      await expectCode({
        'installations': [installationJson()],
        'nextBefore': 4,
      }, 'unsupported');
    },
  );

  test('Core API preserves stale and unavailable classifications', () async {
    for (final entry in const {
      409: ('media_archive_snapshot_stale', 'media_archive_snapshot_stale'),
      503: ('media_archive_worker_unavailable', 'connection_failed'),
    }.entries) {
      var calls = 0;
      final api = LarenorServerApi(
        endpoint: ServerEndpoint('https://core.test'),
        client: MockClient((request) async {
          calls++;
          if (calls == 1) {
            return http.Response(
              jsonEncode({
                'installations': [installationJson()],
                'nextBefore': null,
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode({
              'error': {'code': entry.value.$1, 'message': 'discarded'},
            }),
            entry.key,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(api.close);
      await expectLater(
        CoreMediaArchiveApi(api, 'access').read(),
        throwsA(
          isA<MediaArchiveReadException>().having(
            (error) => error.kind,
            'kind',
            entry.value.$2,
          ),
        ),
      );
    }
  });

  test(
    'controller only refreshes explicitly and retires late results',
    () async {
      final pending = Completer<MediaArchiveHealthSnapshot>();
      var calls = 0;
      final controller = MediaArchiveHealthController(
        read: () {
          calls++;
          return pending.future;
        },
        authorized: () => true,
      );
      addTearDown(controller.dispose);
      expect(calls, 0);
      expect(controller.state, MediaArchiveCardState.idle);
      final future = controller.refresh();
      expect(controller.state, MediaArchiveCardState.loading);
      controller.retire();
      pending.complete(MediaArchiveHealthSnapshot.fromJson(archiveJson()));
      await future;
      expect(controller.snapshot, isNull);
      expect(controller.state, MediaArchiveCardState.idle);
      expect(calls, 1);
    },
  );

  test('controller keeps incomplete evidence distinct as partial', () async {
    final controller = MediaArchiveHealthController(
      read: () async =>
          MediaArchiveHealthSnapshot.fromJson(archiveJson(state: 'incomplete')),
      authorized: () => true,
    );
    addTearDown(controller.dispose);
    await controller.refresh();
    expect(controller.state, MediaArchiveCardState.partial);
  });

  for (final entry in const {
    'media_archive_snapshot_stale': MediaArchiveCardState.stale,
    'connection_failed': MediaArchiveCardState.offline,
    'forbidden': MediaArchiveCardState.denied,
    'unsupported': MediaArchiveCardState.unsupported,
  }.entries) {
    test('controller exposes ${entry.value.name} separately', () async {
      final controller = MediaArchiveHealthController(
        read: () => Future.error(MediaArchiveReadException(entry.key)),
        authorized: () => true,
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      expect(controller.state, entry.value);
    });
  }

  testWidgets(
    'tablet and DeX card supports 2x, TalkBack and keyboard refresh',
    (tester) async {
      for (final width in [600.0, 1280.0]) {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        final controller = MediaArchiveHealthController(
          read: () async => MediaArchiveHealthSnapshot.fromJson(archiveJson()),
          authorized: () => true,
        );
        await tester.pumpWidget(
          CupertinoApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: CupertinoPageScaffold(
              child: SingleChildScrollView(
                child: MediaArchiveHealthCard(controller: controller),
              ),
            ),
          ),
        );
        final semantics = tester.ensureSemantics();
        expect(find.bySemanticsLabel('Refresh archive health'), findsOneWidget);
        final refresh = find.byKey(const ValueKey('media-archive-refresh'));
        expect(tester.getSize(refresh).height, greaterThanOrEqualTo(48));
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.text('4.0 KB'), findsOneWidget);
        expect(
          find.textContaining(RegExp(r'clean|delete', caseSensitive: false)),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        semantics.dispose();
        controller.dispose();
      }
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    },
  );
}
