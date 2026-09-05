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
import 'package:larenor/features/media/local_audio/providers/local_audio_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:media_kit/media_kit.dart';

import 'local_audio_ui_fixture.dart';

class _Client extends JellyfinClient {
  _Client()
    : super(
        config: const JellyfinConfig(
          baseUrl: 'https://jellyfin.test',
          userId: 'fixture',
          accessToken: 'fixture',
          deviceId: 'local-tablet',
        ),
        httpClient: MockClient((_) async => http.Response('', 204)),
      );
  int negotiations = 0;
  final source = Completer<JellyfinPlaybackSource>();
  @override
  Future<JellyfinPlaybackSource> getPlaybackInfo(
    String itemId, {
    int? maxStreamingBitrate,
  }) {
    negotiations++;
    return source.future;
  }
}

class _Player extends PlatformPlayer {
  _Player() : super(configuration: const PlayerConfiguration());
  var opens = 0;
  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opens++;
  }

  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
}

Widget _app(_Client? client, FakeLocalAudioBridge bridge, _Player player) =>
    ProviderScope(
      overrides: [
        jellyfinClientProvider.overrideWithValue(client),
        localAudioBridgeProvider.overrideWithValue(bridge),
        jellyfinPlayerFactoryProvider.overrideWithValue(
          () => Player(platformPlayer: player),
        ),
      ],
      child: const CupertinoApp(
        locale: Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: JellyfinPlayerScreen(
          item: JellyfinItem(id: 'movie', name: 'Movie', type: 'Movie'),
        ),
      ),
    );
Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(Duration.zero);
  }
}

void main() {
  testWidgets(
    'native stop completes before video negotiation and native open',
    (tester) async {
      final client = _Client();
      final bridge = FakeLocalAudioBridge()..stopGate = Completer<void>();
      final player = _Player();
      addTearDown(client.dispose);
      addTearDown(bridge.events.close);
      await tester.pumpWidget(_app(client, bridge, player));
      await _frames(tester);
      expect(bridge.commands, ['stop']);
      expect(client.negotiations, 0);
      expect(player.opens, 0);
      bridge.stopGate!.complete();
      await _frames(tester);
      expect(client.negotiations, 1);
      expect(player.opens, 0);
      // Disposing before the pending negotiation resolves must still prevent open.
      await tester.pumpWidget(const SizedBox.shrink());
      client.source.complete(
        const JellyfinPlaybackSource(
          streamUrl: 'https://fixture.test/video',
          mediaSourceId: 'source',
          playSessionId: 'session',
          isTranscoding: false,
        ),
      );
      await _frames(tester);
      expect(player.opens, 0);
    },
  );

  testWidgets(
    'failed native stop does not negotiate or open video and never exposes raw error',
    (tester) async {
      final client = _Client();
      final bridge = FakeLocalAudioBridge()
        ..stopError = StateError('https://private.example/?api_key=SECRET');
      final player = _Player();
      addTearDown(client.dispose);
      addTearDown(bridge.events.close);
      await tester.pumpWidget(_app(client, bridge, player));
      await _frames(tester);
      expect(bridge.commands, ['stop']);
      expect(client.negotiations, 0);
      expect(player.opens, 0);
      expect(find.textContaining('SECRET'), findsNothing);
      expect(find.textContaining('private.example'), findsNothing);
      expect(find.byType(CupertinoActivityIndicator), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'account replacement while waiting for native stop discards old video request',
    (tester) async {
      final client = _Client();
      final bridge = FakeLocalAudioBridge()..stopGate = Completer<void>();
      final player = _Player();
      addTearDown(client.dispose);
      addTearDown(bridge.events.close);
      await tester.pumpWidget(_app(client, bridge, player));
      await _frames(tester);
      expect(client.negotiations, 0);
      await tester.pumpWidget(_app(null, bridge, player));
      bridge.stopGate!.complete();
      await _frames(tester);
      expect(client.negotiations, 0);
      expect(player.opens, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
