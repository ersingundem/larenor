import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/media/music/core/data/core_music_playback_api.dart';
import 'package:larenor/features/media/music/core/data/core_music_targets_api.dart';
import 'package:larenor/features/media/music/core/data/core_music_targets_controller.dart';
import 'package:larenor/features/media/music/core/domain/core_music_playback_models.dart';
import 'package:larenor/features/media/music/core/domain/core_music_target_models.dart';
import 'package:larenor/features/media/music/core/presentation/core_music_targets_panel.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import 'core_music_targets_test.dart' show discoveryFixture;

CoreMusicTargetInventory inventoryFixture({
  int revision = 9,
  String state = 'paused',
  bool available = true,
}) {
  final json = jsonDecode(
    jsonEncode(discoveryFixture()['inventory']),
  ) as Map<String, dynamic>;
  json['playerRevision'] = revision;
  final target = (json['targets'] as List).single as Map<String, dynamic>;
  target['available'] = available;
  target['playbackState'] = state;
  target['capabilities'] = [
    'play',
    'pause',
    'next_previous',
    'volume_set',
    'queue',
  ];
  (target['queue'] as Map<String, dynamic>)['state'] = state;
  return CoreMusicTargetInventory.fromJson(json);
}

void main() {
  test(
    'command sends one exact revision-bound request and validates receipt',
    () async {
      final requests = <http.Request>[];
      final transport = LarenorServerApi(
        endpoint: ServerEndpoint('https://core.fixture'),
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode({
              'receipt': {
                'requestId': '5' * 32,
                'targetId': 'homepod-living',
                'operation': 'pause',
                'state': 'succeeded',
                'playerRevision': 11,
                'code': 'authenticated_readback',
                'installAvailable': false,
              },
            }),
            201,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final inventory = inventoryFixture();
      final receipt =
          await ServerCoreMusicPlaybackApi(
            transport,
            'a' * 43,
            requestId: () => '5' * 32,
          ).execute(
            inventory: inventory,
            target: inventory.targets.single,
            operation: CoreMusicPlaybackOperation.pause,
            isCurrent: () => true,
          );
      expect(requests, hasLength(1));
      expect(requests.single.method, 'POST');
      expect(
        requests.single.url.path,
        '/api/v1/admin/media/music-assistant/playback/commands',
      );
      expect(jsonDecode(requests.single.body), {
        'requestId': '5' * 32,
        'installationId': '1' * 32,
        'expectedInstallationRevision': 4,
        'expectedCoreRevision': 7,
        'expectedPlayerRevision': 9,
        'targetId': 'homepod-living',
        'expectedProvider': 'universal_player--living',
        'expectedTargetKind': 'homepod',
        'expectedQueueId': 'homepod-living',
        'expectedGroupMembers': <String>[],
        'operation': 'pause',
        'volumeLevel': null,
        'muted': null,
        'seekPosition': null,
        'mediaUris': <String>[],
      });
      expect(receipt.playerRevision, 11);
      expect(receipt.state, CoreMusicReceiptState.succeeded);
      expect(receipt.toString(), isNot(contains('core.fixture')));
      expect(receipt.toString(), isNot(contains('a' * 43)));
    },
  );

  test('stale or secret-bearing receipt fails closed without retry', () async {
    for (final receipt in [
      {
        'requestId': '5' * 32,
        'targetId': 'homepod-living',
        'operation': 'pause',
        'state': 'succeeded',
        'playerRevision': 9,
        'code': 'authenticated_readback',
        'installAvailable': false,
      },
      {
        'requestId': '5' * 32,
        'targetId': 'homepod-living',
        'operation': 'pause',
        'state': 'succeeded',
        'playerRevision': 11,
        'code': 'authenticated_readback',
        'installAvailable': false,
        'token': 'private',
      },
    ]) {
      var calls = 0;
      final transport = LarenorServerApi(
        endpoint: ServerEndpoint('https://core.fixture'),
        client: MockClient((_) async {
          calls++;
          return http.Response(
            jsonEncode({'receipt': receipt}),
            201,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final inventory = inventoryFixture();
      await expectLater(
        ServerCoreMusicPlaybackApi(
          transport,
          'a' * 43,
          requestId: () => '5' * 32,
        ).execute(
          inventory: inventory,
          target: inventory.targets.single,
          operation: CoreMusicPlaybackOperation.pause,
          isCurrent: () => true,
        ),
        throwsA(isA<LarenorServerException>()),
      );
      expect(calls, 1);
    }
  });

  test('play, next, previous and bounded volume use the allowlist', () async {
    for (final fixture in [
      (operation: CoreMusicPlaybackOperation.play, volume: null),
      (operation: CoreMusicPlaybackOperation.next, volume: null),
      (operation: CoreMusicPlaybackOperation.previous, volume: null),
      (operation: CoreMusicPlaybackOperation.volume, volume: 100),
    ]) {
      http.Request? sent;
      final transport = LarenorServerApi(
        endpoint: ServerEndpoint('https://core.fixture'),
        client: MockClient((request) async {
          sent = request;
          return http.Response(
            jsonEncode({
              'receipt': {
                'requestId': '5' * 32,
                'targetId': 'homepod-living',
                'operation': fixture.operation.wire,
                'state': 'succeeded',
                'playerRevision': 11,
                'code': 'authenticated_readback',
                'installAvailable': false,
              },
            }),
            201,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final inventory = inventoryFixture();
      await ServerCoreMusicPlaybackApi(
        transport,
        'a' * 43,
        requestId: () => '5' * 32,
      ).execute(
        inventory: inventory,
        target: inventory.targets.single,
        operation: fixture.operation,
        volumeLevel: fixture.volume,
        isCurrent: () => true,
      );
      final body = jsonDecode(sent!.body) as Map<String, dynamic>;
      expect(body['operation'], fixture.operation.wire);
      expect(body['volumeLevel'], fixture.volume);
    }

    var calls = 0;
    final transport = LarenorServerApi(
      endpoint: ServerEndpoint('https://core.fixture'),
      client: MockClient((_) async {
        calls++;
        return http.Response('{}', 500);
      }),
    );
    final inventory = inventoryFixture();
    await expectLater(
      ServerCoreMusicPlaybackApi(transport, 'a' * 43).execute(
        inventory: inventory,
        target: inventory.targets.single,
        operation: CoreMusicPlaybackOperation.volume,
        volumeLevel: 101,
        isCurrent: () => true,
      ),
      throwsA(isA<LarenorServerException>()),
    );
    expect(calls, 0);
  });

  testWidgets(
    'PIN gates controls and authenticated readback updates media state',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.reset);
      final lifecycle = ValueNotifier(0);
      final reads = _MutableTargetsApi();
      final commands = _FixturePlaybackApi(reads);
      final controller = CoreMusicTargetsController(
        api: reads,
        playbackApi: commands,
        lifecycle: lifecycle,
        authorized: () => true,
      );
      var pinAccepted = false;
      await tester.pumpWidget(
        CupertinoApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: CupertinoPageScaffold(
            child: CoreMusicTargetsPanel(
              controller: controller,
              authorizeMutation: (_) async => pinAccepted,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('core-music-target-homepod-living')),
      );
      await tester.pump();
      expect(controller.mediaSessionState.title, 'Synthetic Song');
      expect(controller.mediaSessionState.isPlaying, isFalse);
      expect(find.byKey(const ValueKey('core-music-previous')), findsOneWidget);
      expect(find.byKey(const ValueKey('core-music-next')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('core-music-volume-down')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('core-music-volume-up')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('core-music-play-pause')));
      await tester.pumpAndSettle();
      expect(commands.calls, 0);

      pinAccepted = true;
      await tester.tap(find.byKey(const ValueKey('core-music-play-pause')));
      await tester.pumpAndSettle();
      expect(commands.calls, 1);
      expect(controller.inventory!.playerRevision, 11);
      expect(controller.mediaSessionState.isPlaying, isTrue);
      expect(controller.lastReceipt!.playerRevision, 11);
      expect(tester.takeException(), isNull);
      controller.dispose();
      lifecycle.dispose();
    },
  );

  testWidgets('offline output exposes no enabled playback action', (
    tester,
  ) async {
    final lifecycle = ValueNotifier(0);
    final reads = _MutableTargetsApi(available: false);
    final commands = _FixturePlaybackApi(reads);
    final controller = CoreMusicTargetsController(
      api: reads,
      playbackApi: commands,
      lifecycle: lifecycle,
      authorized: () => true,
    );
    await tester.pumpWidget(
      CupertinoApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: CupertinoPageScaffold(
          child: CoreMusicTargetsPanel(
            controller: controller,
            authorizeMutation: (_) async => true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('core-music-target-homepod-living')),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('core-music-play-pause')), findsNothing);
    expect(commands.calls, 0);
    controller.dispose();
    lifecycle.dispose();
  });

  testWidgets('tablet controls fit 600px at 2x text with 48px actions', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 1000);
    addTearDown(tester.view.reset);
    final lifecycle = ValueNotifier(0);
    final reads = _MutableTargetsApi();
    final controller = CoreMusicTargetsController(
      api: reads,
      playbackApi: _FixturePlaybackApi(reads),
      lifecycle: lifecycle,
      authorized: () => true,
    );
    await tester.pumpWidget(
      CupertinoApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: CupertinoPageScaffold(
          child: SingleChildScrollView(
            child: CoreMusicTargetsPanel(
              controller: controller,
              authorizeMutation: (_) async => true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('core-music-target-homepod-living')),
    );
    await tester.pump();
    for (final key in const [
      'core-music-previous',
      'core-music-play-pause',
      'core-music-next',
      'core-music-volume-down',
      'core-music-volume-up',
    ]) {
      expect(
        tester.getSize(find.byKey(ValueKey(key))).height,
        greaterThanOrEqualTo(48),
      );
    }
    expect(tester.takeException(), isNull);
    controller.dispose();
    lifecycle.dispose();
  });
}

class _MutableTargetsApi implements CoreMusicTargetsApi {
  _MutableTargetsApi({this.available = true});
  final bool available;
  int revision = 9;
  String state = 'paused';

  @override
  Future<CoreMusicTargetInventory> read({
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) throw const LarenorServerException('cancelled');
    return inventoryFixture(
      revision: revision,
      state: state,
      available: available,
    );
  }
}

class _FixturePlaybackApi implements CoreMusicPlaybackApi {
  _FixturePlaybackApi(this.reads);
  final _MutableTargetsApi reads;
  int calls = 0;

  @override
  Future<CoreMusicPlaybackReceipt> execute({
    required CoreMusicTargetInventory inventory,
    required CoreMusicTarget target,
    required CoreMusicPlaybackOperation operation,
    int? volumeLevel,
    required bool Function() isCurrent,
  }) async {
    calls++;
    reads.revision = 11;
    reads.state = 'playing';
    return CoreMusicPlaybackReceipt(
      requestId: '5' * 32,
      targetId: target.id,
      operation: operation,
      state: CoreMusicReceiptState.succeeded,
      playerRevision: 11,
    );
  }
}
