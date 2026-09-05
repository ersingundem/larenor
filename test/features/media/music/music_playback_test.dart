import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/ha_client/data/ha_api_exception.dart';
import 'package:larenor/features/ha_client/data/ws_client.dart';
import 'package:larenor/features/media/ha_playback/domain/ha_media_inventory.dart';
import 'package:larenor/features/media/music/data/music_parser.dart';
import 'package:larenor/features/media/music/data/music_playback_api.dart';
import 'package:larenor/features/media/music/data/music_playback_controller.dart';
import 'package:larenor/features/media/music/data/music_repository.dart';
import 'package:larenor/features/media/music/domain/music_models.dart';
import 'package:larenor/features/media/music/domain/music_playback_models.dart';

import 'music_fixtures.dart';

Matcher playbackFailure(MusicPlaybackFailure failure, {bool? unknown}) =>
    isA<MusicPlaybackException>()
        .having((e) => e.failure, 'failure', failure)
        .having(
          (e) => unknown == null || e.outcomeUnknown == unknown,
          'outcome',
          true,
        );

class PlaybackReads extends FakeMusicApi {
  String song = 'Song';
  @override
  Future<Object?> library(
    MusicLibraryQuery query, {
    required bool Function() isCurrent,
  }) async {
    final raw = await super.library(query, isCurrent: isCurrent);
    if (raw is Map &&
        raw['items'] is List &&
        (raw['items'] as List).isNotEmpty) {
      (raw['items'] as List).first['name'] = song;
    }
    return raw;
  }
}

class PlaybackApi extends MusicPlaybackApi {
  final connections = StreamController<bool>.broadcast(sync: true);
  int calls = 0, writes = 0;
  bool delayBeforeSend = false;
  Object? error;
  Completer<void>? gate;
  bool Function()? lastLease;
  void Function()? afterWrite;
  @override
  Stream<bool> get connectionChanges => Stream.multi((sink) {
    final subscription = connections.stream.listen(
      sink.add,
      onDone: sink.close,
    );
    sink.add(true);
    sink.onCancel = subscription.cancel;
  }, isBroadcast: true);
  @override
  Future<void> play({
    required String entityId,
    required MusicMediaItem item,
    required bool Function() isCurrent,
  }) async {
    calls++;
    lastLease = isCurrent;
    if (delayBeforeSend && gate != null) await gate!.future;
    if (!isCurrent()) throw HaApiException('private', code: 'cancelled');
    if (error != null) throw error!;
    writes++;
    afterWrite?.call();
    if (!delayBeforeSend && gate != null) await gate!.future;
  }
}

class PlaybackFixture {
  PlaybackFixture() {
    repository = MusicRepository(
      api: reads,
      accountGeneration: generation,
      isCurrent: () => current,
      now: () => now,
      loadInventory: () async {
        inventoryReads++;
        if (inventoryGate != null) await inventoryGate!.future;
        return inventory();
      },
    );
    controller = MusicPlaybackController(
      repository: repository,
      api: api,
      isCurrent: () => current,
      now: () => now,
    );
    api.afterWrite = () => playing = true;
  }
  final reads = PlaybackReads(), api = PlaybackApi();
  final generation = Object();
  late final MusicRepository repository;
  late final MusicPlaybackController controller;
  var now = musicTime;
  var current = true, playing = false, enabled = true, service = true;
  String entry = 'entry', registry = 'registry';
  var inventoryReads = 0;
  Completer<void>? inventoryGate;
  MusicLibraryQuery get query => MusicLibraryQuery(
    accountGeneration: generation,
    configEntryId: 'entry',
    type: MusicMediaType.track,
  );
  MusicCatalogSelection get selection => MusicCatalogSelection.library(
    query,
    parseMusicLibrary(musicLibrary(query), query).items.single,
  );
  MusicQueueTarget get target => const MusicQueueTarget(
    entityId: 'media_player.kitchen',
    configEntryId: 'entry',
    name: 'Kitchen',
    available: true,
    enabled: true,
    registryId: 'registry',
  );
  HaMediaInventory inventory() => HaMediaInventory(
    targets: [
      HaMediaTarget(
        entityId: 'media_player.kitchen',
        name: 'Kitchen',
        state: playing ? 'playing' : 'idle',
        supportedFeatures: 512,
        enabled: enabled,
        platform: 'music_assistant',
        configEntryId: entry,
        registryId: registry,
      ),
    ],
    services: {
      'music_assistant': {
        ...musicInventory().services['music_assistant'] as Map,
        if (service)
          'play_media': {
            'fields': {
              'media_id': {},
              'media_type': {},
              'enqueue': {
                'selector': {
                  'select': {
                    'options': ['play', 'replace'],
                  },
                },
              },
            },
          },
      },
    },
    readAt: now,
    registryAvailable: true,
  );
  Future<void> ready() async {
    controller.setVisible(true);
    await Future<void>.delayed(Duration.zero);
  }

  void dispose() {
    controller.dispose();
    unawaited(api.connections.close());
  }
}

void main() {
  group('explicit catalog playback', () {
    late PlaybackFixture f;
    setUp(() async {
      f = PlaybackFixture();
      await f.ready();
    });
    tearDown(() => f.dispose());
    test('controller creation/visibility does not read or send', () {
      expect(f.inventoryReads, 0);
      expect(f.reads.libraryReads, 0);
      expect(f.api.writes, 0);
    });
    test('named intent reads catalog but does not send; execute single send and changed matching queue observed', () async {
      final intent = await f.controller.createIntent(
        source: f.selection,
        target: f.target,
      );
      expect(intent.item.name, 'Song');
      expect(intent.target.name, 'Kitchen');
      expect(
        intent.expiresAt.difference(intent.createdAt),
        const Duration(seconds: 30),
      );
      expect(f.api.writes, 0);
      final receipt = await f.controller.execute(intent);
      expect(receipt.status, MusicPlaybackReceiptStatus.observed);
      expect(f.api.writes, 1);
      expect(f.api.calls, 1);
      expect(f.reads.libraryReads, 2);
      expect(f.inventoryReads, 3);
      expect(f.api.lastLease!(), isFalse);
      await expectLater(
        f.controller.execute(intent),
        throwsA(playbackFailure(MusicPlaybackFailure.invalidIntent)),
      );
      expect(f.api.writes, 1);
    });
    test('matching unchanged queue already playing does not prove a new observation', () async {
      f.playing = true;
      final intent = await f.controller.createIntent(
        source: f.selection,
        target: f.target,
      );
      final receipt = await f.controller.execute(intent);
      expect(receipt.status, MusicPlaybackReceiptStatus.unconfirmed);
      expect(receipt.observedAt, isNull);
      expect(f.api.writes, 1);
    });
    test(
      'accepted command with unreadable queue remains unconfirmed, no replay',
      () async {
        f.reads.queueError = TimeoutException('private');
        final intent = await f.controller.createIntent(
          source: f.selection,
          target: f.target,
        );
        final receipt = await f.controller.execute(intent);
        expect(receipt.status, MusicPlaybackReceiptStatus.unconfirmed);
        expect(f.api.calls, 1);
        expect(f.controller.state.outcomeUnknown, isFalse);
      },
    );
    test(
      'source title/URI membership is revalidated after confirmation',
      () async {
        final intent = await f.controller.createIntent(
          source: f.selection,
          target: f.target,
        );
        f.reads.song = 'Replacement';
        await expectLater(
          f.controller.execute(intent),
          throwsA(playbackFailure(MusicPlaybackFailure.sourceChanged)),
        );
        expect(f.api.calls, 0);
        await expectLater(
          f.controller.execute(intent),
          throwsA(playbackFailure(MusicPlaybackFailure.invalidIntent)),
        );
      },
    );
    test(
      'manually supplied URI not found in source page is never dispatched',
      () async {
        final fakeItem = MusicMediaItem(
          type: MusicMediaType.track,
          reference: const MusicMediaReference('http://private.invalid/token'),
          name: 'Song',
          version: '',
        );
        await expectLater(
          f.controller.createIntent(
            source: MusicCatalogSelection.library(f.query, fakeItem),
            target: f.target,
          ),
          throwsA(playbackFailure(MusicPlaybackFailure.sourceChanged)),
        );
        expect(f.api.calls, 0);
      },
    );
    test(
      'search query source is independently rerun before dispatch',
      () async {
        final query = MusicSearchQuery(
          accountGeneration: f.generation,
          configEntryId: 'entry',
          text: 'Song',
        );
        final source = MusicCatalogSelection.search(
          query,
          parseMusicSearch(musicSearch(), query).items.single,
        );
        final intent = await f.controller.createIntent(
          source: source,
          target: f.target,
        );
        await f.controller.execute(intent);
        expect(f.reads.searchReads, 2);
        expect(f.reads.libraryReads, 0);
        expect(f.api.writes, 1);
      },
    );
    for (final change in ['entry', 'registry', 'disabled', 'service']) {
      test('$change changes after confirmation prevent send', () async {
        final intent = await f.controller.createIntent(
          source: f.selection,
          target: f.target,
        );
        switch (change) {
          case 'entry':
            f.entry = 'other';
          case 'registry':
            f.registry = 'other';
          case 'disabled':
            f.enabled = false;
          case 'service':
            f.service = false;
        }
        await expectLater(
          f.controller.execute(intent),
          throwsA(isA<MusicPlaybackException>()),
        );
        expect(f.api.calls, 0);
      });
    }
    for (final invalidate in [
      'hidden',
      'background',
      'account',
      'disconnect',
    ]) {
      test(
        '$invalidate invalidates pending intent even after recovery',
        () async {
          final intent = await f.controller.createIntent(
            source: f.selection,
            target: f.target,
          );
          switch (invalidate) {
            case 'hidden':
              f.controller.setVisible(false);
              f.controller.setVisible(true);
            case 'background':
              f.controller.setForeground(false);
              f.controller.setForeground(true);
            case 'account':
              f.current = false;
            case 'disconnect':
              f.api.connections.add(false);
              await Future<void>.delayed(Duration.zero);
              f.api.connections.add(true);
              await Future<void>.delayed(Duration.zero);
          }
          await expectLater(
            f.controller.execute(intent),
            throwsA(playbackFailure(MusicPlaybackFailure.invalidIntent)),
          );
          expect(f.api.calls, 0);
        },
      );
    }
    test(
      'new intent invalidates previous one; cross-controller intent rejected',
      () async {
        final first = await f.controller.createIntent(
          source: f.selection,
          target: f.target,
        );
        final second = await f.controller.createIntent(
          source: f.selection,
          target: f.target,
        );
        await expectLater(
          f.controller.execute(first),
          throwsA(playbackFailure(MusicPlaybackFailure.invalidIntent)),
        );
        final other = PlaybackFixture();
        await other.ready();
        await expectLater(
          other.controller.execute(second),
          throwsA(playbackFailure(MusicPlaybackFailure.invalidIntent)),
        );
        expect(f.api.calls, 0);
        expect(other.api.calls, 0);
        other.dispose();
      },
    );
    test('expiry and backward clock prevent replay', () async {
      final intent = await f.controller.createIntent(
        source: f.selection,
        target: f.target,
      );
      f.now = f.now.add(const Duration(seconds: 30));
      await expectLater(
        f.controller.execute(intent),
        throwsA(playbackFailure(MusicPlaybackFailure.expiredIntent)),
      );
      final next = await f.controller.createIntent(
        source: f.selection,
        target: f.target,
      );
      f.now = f.now.subtract(const Duration(seconds: 1));
      await expectLater(
        f.controller.execute(next),
        throwsA(playbackFailure(MusicPlaybackFailure.expiredIntent)),
      );
      expect(f.api.calls, 0);
    });
    test(
      'only one preflight/in-flight command at a time; doubletap sends once',
      () async {
        final intent = await f.controller.createIntent(
          source: f.selection,
          target: f.target,
        );
        f.api.gate = Completer<void>();
        final sending = f.controller.execute(intent);
        await Future<void>.delayed(Duration.zero);
        expect(f.api.writes, 1);
        await expectLater(
          f.controller.execute(intent),
          throwsA(playbackFailure(MusicPlaybackFailure.invalidIntent)),
        );
        await expectLater(
          f.controller.createIntent(source: f.selection, target: f.target),
          throwsA(playbackFailure(MusicPlaybackFailure.busy)),
        );
        f.api.gate!.complete();
        await sending;
        expect(f.api.writes, 1);
      },
    );
    test(
      'account/foreground invalidation during preflight prevents delayed send',
      () async {
        final intent = await f.controller.createIntent(
          source: f.selection,
          target: f.target,
        );
        f.inventoryGate = Completer<void>();
        final sending = f.controller.execute(intent);
        await Future<void>.delayed(Duration.zero);
        f.controller.setForeground(false);
        f.controller.setForeground(true);
        f.inventoryGate!.complete();
        await expectLater(
          sending,
          throwsA(playbackFailure(MusicPlaybackFailure.invalidIntent)),
        );
        expect(f.api.calls, 0);
      },
    );
    test(
      'denied action is known rejection; timeout is unknown and never retried',
      () async {
        var intent = await f.controller.createIntent(
          source: f.selection,
          target: f.target,
        );
        f.api.error = HaApiException('private-token', code: 'unauthorized');
        await expectLater(
          f.controller.execute(intent),
          throwsA(
            playbackFailure(MusicPlaybackFailure.permission, unknown: false),
          ),
        );
        expect(f.api.calls, 1);
        intent = await f.controller.createIntent(
          source: f.selection,
          target: f.target,
        );
        f.api.error = TimeoutException('private-token');
        await expectLater(
          f.controller.execute(intent),
          throwsA(playbackFailure(MusicPlaybackFailure.timeout, unknown: true)),
        );
        expect(f.api.calls, 2);
        expect(f.controller.state.outcomeUnknown, isTrue);
        expect(
          const MusicPlaybackException(
            MusicPlaybackFailure.timeout,
            outcomeUnknown: true,
          ).toString(),
          isNot(contains('token')),
        );
      },
    );
  });
  test('HA adapter sends one exact enqueue play command without username or URL resolution', () async {
    final ws = CaptureWs();
    final api = WsMusicPlaybackApi(ws);
    final query = MusicLibraryQuery(
      accountGeneration: Object(),
      configEntryId: 'entry',
      type: MusicMediaType.track,
    );
    final item = parseMusicLibrary(musicLibrary(query), query).items.single;
    await api.play(
      entityId: 'media_player.kitchen',
      item: item,
      isCurrent: () => true,
    );
    expect(ws.calls, [
      {
        'domain': 'music_assistant',
        'service': 'play_media',
        'service_data': {
          'media_id': ['library://track/123'],
          'media_type': 'track',
          'enqueue': 'play',
        },
        'target': {
          'entity_id': ['media_player.kitchen'],
        },
        'return_response': false,
      },
    ]);
    ws.current = false;
    await expectLater(
      api.play(
        entityId: 'media_player.kitchen',
        item: item,
        isCurrent: () => ws.current,
      ),
      throwsA(isA<HaApiException>()),
    );
    expect(ws.calls, hasLength(1));
    ws.dispose();
  });
  testWidgets('timed-out command lease rejects delayed post-wait send', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final f = PlaybackFixture();
    f.controller.setVisible(true);
    await tester.pump();
    final intent = await f.controller.createIntent(
      source: f.selection,
      target: f.target,
    );
    f.api.delayBeforeSend = true;
    f.api.gate = Completer<void>();
    final sending = f.controller.execute(intent);
    final assertion = expectLater(
      sending,
      throwsA(playbackFailure(MusicPlaybackFailure.timeout, unknown: true)),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 31));
    await assertion;
    expect(f.api.lastLease!(), isFalse);
    f.api.gate!.complete();
    await tester.pump();
    expect(f.api.writes, 0);
    expect(f.api.calls, 1);
    f.dispose();
    await tester.pump();
  });
}

class CaptureWs extends HaWebSocketClient {
  CaptureWs() : super(baseUrl: 'http://fixture.invalid', token: 'fixture');
  var current = true;
  final calls = <Map<String, Object?>>[];
  @override
  Future<dynamic> callService(
    String domain,
    String service, {
    Map<String, dynamic>? serviceData,
    Map<String, dynamic>? target,
    bool returnResponse = false,
    bool Function()? isCurrent,
  }) async {
    await Future<void>.delayed(Duration.zero);
    if (isCurrent?.call() == false) {
      throw HaApiException('private', code: 'cancelled');
    }
    calls.add({
      'domain': domain,
      'service': service,
      'service_data': serviceData,
      'target': target,
      'return_response': returnResponse,
    });
    return {
      'context': {'id': 'accepted'},
    };
  }
}
