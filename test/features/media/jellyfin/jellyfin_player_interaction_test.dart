import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/app_interaction_scope.dart';
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
  streamUrl: 'https://fixture.invalid/video',
  mediaSourceId: 'source',
  playSessionId: 'session',
  isTranscoding: false,
);
const _movie = JellyfinItem(id: 'movie', name: 'Movie', type: 'Movie');
const _tracks = Tracks(
  audio: [
    AudioTrack('1', 'English audio', 'en'),
    AudioTrack('2', 'Turkish audio', 'tr'),
  ],
  subtitle: [SubtitleTrack('3', 'English subtitles', 'en')],
);

class _Client extends JellyfinClient {
  _Client([String user = 'fixture'])
    : super(
        config: JellyfinConfig(
          baseUrl: 'https://fixture.invalid',
          userId: user,
          accessToken: 'fixture',
          deviceId: 'tablet',
        ),
        httpClient: MockClient((_) async => http.Response('', 204)),
      );
  final negotiations = <int?>[];
  Completer<JellyfinPlaybackSource>? next;
  @override
  Future<JellyfinPlaybackSource> getPlaybackInfo(
    String itemId, {
    int? maxStreamingBitrate,
  }) async {
    negotiations.add(maxStreamingBitrate);
    return next?.future ?? _source;
  }
}

class _Player extends PlatformPlayer {
  _Player() : super(configuration: const PlayerConfiguration());
  final commands = <String>[];
  Completer<void>? trackGate;
  void emitTracks(Tracks tracks) => tracksController.add(tracks);
  void emitDuration(Duration duration) => durationController.add(duration);
  @override
  Future<void> open(Playable playable, {bool play = true}) async =>
      commands.add('open:$play');
  @override
  Future<void> seek(Duration position) async =>
      commands.add('seek:${position.inSeconds}');
  @override
  Future<void> pause() async => commands.add('pause');
  @override
  Future<void> stop() async => commands.add('stop');
  @override
  Future<void> playOrPause() async => commands.add('toggle');
  @override
  Future<void> setVolume(double volume) async => commands.add('volume');
  @override
  Future<void> setAudioTrack(AudioTrack track) async {
    commands.add('audio:${track.id}');
    await trackGate?.future;
  }

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    commands.add('subtitle:${track.id}');
    await trackGate?.future;
  }
}

class _Audio extends LocalAudioBridge {
  _Audio() : super(isAndroid: false);
  int stops = 0;
  bool running = false;
  @override
  Future<void> stopForVideo() async {
    stops++;
    running = false;
  }
}

class _Harness {
  final client = _Client();
  final replacement = _Client('other');
  final player = _Player();
  final audio = _Audio();
  final interaction = AppInteractionController();
  final navigator = GlobalKey<NavigatorState>();
  final item = ValueNotifier(_movie);
  late ProviderContainer container;
  Future<void> mount(WidgetTester tester) async {
    container = ProviderContainer(
      overrides: [
        jellyfinClientProvider.overrideWithValue(client),
        jellyfinPlayerFactoryProvider.overrideWithValue(
          () => Player(platformPlayer: player),
        ),
        jellyfinVideoSurfaceProvider.overrideWithValue((_) => const SizedBox()),
        localAudioBridgeProvider.overrideWithValue(audio),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(client.dispose);
    addTearDown(replacement.dispose);
    addTearDown(interaction.dispose);
    addTearDown(item.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: CupertinoApp(
          navigatorKey: navigator,
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (_, child) =>
              AppInteractionScope(controller: interaction, child: child!),
          home: ValueListenableBuilder(
            valueListenable: item,
            builder: (_, value, _) => JellyfinPlayerScreen(item: value),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    player.emitTracks(_tracks);
    player.emitDuration(const Duration(minutes: 10));
    await tester.pumpAndSettle();
    expect(client.negotiations, [null]);
    expect(player.commands, ['open:true']);
    player.commands.clear();
  }

  VoidCallback opener(WidgetTester tester, IconData icon) => tester
      .widget<CupertinoButton>(
        find
            .ancestor(
              of: find.byIcon(icon),
              matching: find.byType(CupertinoButton),
            )
            .first,
      )
      .onPressed!;
  Future<VoidCallback> pick(
    WidgetTester tester,
    IconData icon,
    String label,
  ) async {
    final open = opener(tester, icon);
    open();
    open();
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoActionSheet), findsOneWidget);
    return tester
        .widget<CupertinoActionSheetAction>(
          find.widgetWithText(CupertinoActionSheetAction, label),
        )
        .onPressed;
  }

  void invalidate(String reason, WidgetTester tester) {
    switch (reason) {
      case 'idle':
        interaction.setActive(false);
        interaction.setActive(true);
      case 'background':
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
      case 'account':
        container.updateOverrides([
          jellyfinClientProvider.overrideWithValue(replacement),
          jellyfinPlayerFactoryProvider.overrideWithValue(
            () => Player(platformPlayer: player),
          ),
          jellyfinVideoSurfaceProvider.overrideWithValue(
            (_) => const SizedBox(),
          ),
          localAudioBridgeProvider.overrideWithValue(audio),
        ]);
      case 'item':
        item.value = const JellyfinItem(
          id: 'other',
          name: 'Other',
          type: 'Movie',
        );
    }
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }
}

void main() {
  for (final kind in [
    (
      name: 'subtitle',
      icon: CupertinoIcons.captions_bubble,
      label: 'English subtitles',
      command: 'subtitle:3',
    ),
    (
      name: 'audio',
      icon: CupertinoIcons.speaker_2,
      label: 'English audio',
      command: 'audio:1',
    ),
    (
      name: 'quality',
      icon: CupertinoIcons.settings,
      label: '20 Mbps',
      command: 'open:true',
    ),
  ]) {
    testWidgets(
      '${kind.name} selection is single flight and a fresh confirmation acts once',
      (tester) async {
        final h = _Harness();
        await h.mount(tester);
        final choose = await h.pick(tester, kind.icon, kind.label);
        choose();
        choose();
        await tester.pumpAndSettle();
        expect(h.player.commands, [kind.command]);
        expect(h.client.negotiations.length, kind.name == 'quality' ? 2 : 1);
        await h.close(tester);
      },
    );
    for (final reason in ['idle', 'background', 'account', 'item']) {
      testWidgets(
        '${kind.name} picker expires on $reason without late commands or source opens',
        (tester) async {
          final h = _Harness();
          await h.mount(tester);
          final choose = await h.pick(tester, kind.icon, kind.label);
          h.invalidate(reason, tester);
          if (reason == 'idle') {
            choose(); // Expiry must happen before the next frame.
          }
          await tester.pumpAndSettle();
          final allowedLifecycleCommands = List.of(h.player.commands);
          choose();
          await tester.pumpAndSettle();
          expect(h.player.commands, allowedLifecycleCommands);
          expect(h.client.negotiations, [null]);
          expect(h.replacement.negotiations, isEmpty);
          expect(find.byType(CupertinoActionSheet), findsNothing);
          await h.close(tester);
        },
      );
    }
  }

  testWidgets('one pending track command owns all pickers until it completes', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester);
    h.player.trackGate = Completer<void>();
    final qualityOpen = h.opener(tester, CupertinoIcons.settings);
    final choose = await h.pick(
      tester,
      CupertinoIcons.speaker_2,
      'English audio',
    );
    choose();
    await tester.pumpAndSettle();
    expect(h.player.commands, ['audio:1']);
    qualityOpen();
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoActionSheet), findsNothing);
    h.player.trackGate!.complete();
    await tester.pumpAndSettle();
    qualityOpen();
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoActionSheet), findsOneWidget);
    await h.close(tester);
  });
  testWidgets(
    'expired picker callback never pops another root dialog or stops native audio on idle',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      final choose = await h.pick(tester, CupertinoIcons.settings, '20 Mbps');
      unawaited(
        h.navigator.currentState!.push(
          CupertinoDialogRoute<void>(
            context: h.navigator.currentContext!,
            builder: (_) => const CupertinoAlertDialog(
              title: Text('Unrelated root dialog'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      h.audio.running = true;
      h.interaction.setActive(false);
      h.interaction.setActive(true);
      choose();
      await tester.pumpAndSettle();
      choose();
      expect(find.text('Unrelated root dialog'), findsOneWidget);
      expect(h.player.commands, isEmpty);
      expect(h.audio.running, isTrue);
      expect(h.audio.stops, 1); // Only the original video-start handoff.
      await h.close(tester);
    },
  );
  testWidgets(
    'quality response arriving after idle cannot open or seek a new source',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      h.client.next = Completer<JellyfinPlaybackSource>();
      final choose = await h.pick(tester, CupertinoIcons.settings, '20 Mbps');
      choose();
      await tester.pumpAndSettle();
      expect(h.client.negotiations.length, 2);
      h.interaction.setActive(false);
      h.interaction.setActive(true);
      h.client.next!.complete(_source);
      await tester.pumpAndSettle();
      expect(h.player.commands, isEmpty);
      expect(h.audio.stops, 1);
      await h.close(tester);
    },
  );
  testWidgets('a removed track cannot be selected from the old sheet', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester);
    final choose = await h.pick(
      tester,
      CupertinoIcons.speaker_2,
      'English audio',
    );
    h.player.emitTracks(
      const Tracks(audio: [AudioTrack('2', 'Turkish audio', 'tr')]),
    );
    await tester.pump();
    choose();
    await tester.pumpAndSettle();
    expect(h.player.commands, isEmpty);
    await h.close(tester);
  });
  testWidgets(
    'seek and volume gestures captured before idle cannot command the player after wake',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      final seek = tester.widget<CupertinoSlider>(find.byType(CupertinoSlider));
      seek.onChangeStart!(0);
      seek.onChanged!(120);
      final gesture = tester.widget<GestureDetector>(
        find.byWidgetPredicate(
          (widget) =>
              widget is GestureDetector && widget.onVerticalDragStart != null,
        ),
      );
      gesture.onVerticalDragStart!(
        DragStartDetails(globalPosition: const Offset(700, 300)),
      );
      h.interaction.setActive(false);
      h.interaction.setActive(true);
      seek.onChangeEnd!(120);
      gesture.onVerticalDragUpdate!(
        DragUpdateDetails(
          globalPosition: const Offset(700, 100),
          delta: const Offset(0, -200),
        ),
      );
      await tester.pumpAndSettle();
      expect(h.player.commands, isEmpty);
      expect(
        tester.widget<CupertinoSlider>(find.byType(CupertinoSlider)).value,
        0,
      );
      await h.close(tester);
    },
  );
}
