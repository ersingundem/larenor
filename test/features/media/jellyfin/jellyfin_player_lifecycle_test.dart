import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_client.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_config.dart';
import 'package:larenor/features/media/jellyfin/data/models/jellyfin_item.dart';
import 'package:larenor/features/media/jellyfin/presentation/player/jellyfin_player_screen.dart';
import 'package:larenor/features/media/jellyfin/providers/jellyfin_providers.dart';
import 'package:larenor/features/media/local_audio/data/local_audio_bridge.dart';
import 'package:larenor/features/media/local_audio/providers/local_audio_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:media_kit/media_kit.dart';

const _source = JellyfinPlaybackSource(
  streamUrl: 'http://media.test/video',
  mediaSourceId: 'source',
  playSessionId: 'session',
  isTranscoding: false,
);

class _DelayedClient extends JellyfinClient {
  _DelayedClient()
    : super(
        config: const JellyfinConfig(
          baseUrl: 'http://media.test',
          userId: 'user',
          accessToken: 'example',
          deviceId: 'device',
        ),
        httpClient: MockClient((_) async => http.Response('', 204)),
      );
  final pending = Completer<JellyfinPlaybackSource>();
  @override
  Future<JellyfinPlaybackSource> getPlaybackInfo(
    String itemId, {
    int? maxStreamingBitrate,
  }) => pending.future;
}

class _FakePlayer extends PlatformPlayer {
  _FakePlayer() : super(configuration: const PlayerConfiguration());
  final opened = <bool>[];
  final openComplete = Completer<void>();
  var disposed = false;
  var stopCalls = 0;
  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opened.add(play);
    await openComplete.future;
  }

  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await super.dispose();
  }
}

// These tests exercise video lifecycle after the OS audio boundary. Dedicated
// local_audio_video_handoff_test cases cover pending and failed native stops.
class _StoppedAudio extends LocalAudioBridge {
  _StoppedAudio() : super(isAndroid: false);
  @override
  Future<void> stopForVideo() async {}
}

Widget _app(_DelayedClient? client, _FakePlayer player) => ProviderScope(
  overrides: [
    localAudioBridgeProvider.overrideWithValue(_StoppedAudio()),
    jellyfinClientProvider.overrideWithValue(client),
    jellyfinPlayerFactoryProvider.overrideWithValue(
      () => Player(platformPlayer: player),
    ),
  ],
  child: const CupertinoApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: Locale('en'),
    home: JellyfinPlayerScreen(
      item: JellyfinItem(id: 'movie', name: 'Movie', type: 'Movie'),
    ),
  ),
);

void main() {
  testWidgets('late playback negotiation cannot reopen a disposed player', (
    tester,
  ) async {
    final client = _DelayedClient();
    final player = _FakePlayer();
    addTearDown(client.dispose);
    await tester.pumpWidget(_app(client, player));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    client.pending.complete(_source);
    await tester.pump();
    expect(player.disposed, isTrue);
    expect(player.opened, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'account removal discards playback info from the previous account',
    (tester) async {
      final client = _DelayedClient();
      final player = _FakePlayer();
      addTearDown(client.dispose);
      await tester.pumpWidget(_app(client, player));
      await tester.pump();
      await tester.pumpWidget(_app(null, player));
      client.pending.complete(_source);
      await tester.pump();
      expect(player.opened, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('account removal during native open stops its late completion', (
    tester,
  ) async {
    final client = _DelayedClient();
    final player = _FakePlayer();
    addTearDown(client.dispose);
    await tester.pumpWidget(_app(client, player));
    await tester.pump();
    client.pending.complete(_source);
    await tester.pump();
    expect(player.opened, [true]);
    await tester.pumpWidget(_app(null, player));
    expect(player.stopCalls, 1);
    player.openComplete.complete();
    await tester.pump();
    expect(player.stopCalls, 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'background completion opens paused and disposal prevents later setup',
    (tester) async {
      final client = _DelayedClient();
      final player = _FakePlayer();
      addTearDown(client.dispose);
      await tester.pumpWidget(_app(client, player));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      client.pending.complete(_source);
      await tester.pump();
      expect(player.opened, [false]);
      await tester.pumpWidget(const SizedBox());
      player.openComplete.complete();
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(minutes: 1));
      expect(player.disposed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
