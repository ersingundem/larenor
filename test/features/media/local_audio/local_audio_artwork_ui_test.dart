import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/media/local_audio/data/local_audio_artwork_file_access.dart';
import 'package:larenor/features/media/local_audio/domain/local_audio_models.dart';
import 'package:larenor/features/media/local_audio/presentation/local_audio_screen.dart';
import 'package:larenor/features/media/local_audio/providers/local_audio_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import 'local_audio_artwork_fixture.dart';
import 'local_audio_ui_fixture.dart';

class _Files extends LocalAudioArtworkFileAccess {
  int picks = 0;
  Completer<Uint8List?>? gate;
  bool cancel = false;
  @override
  Future<Uint8List?> pick() async {
    picks++;
    return gate != null
        ? await gate!.future
        : cancel
        ? null
        : artworkJpeg();
  }
}

class _Bridge extends FakeLocalAudioBridge {
  int preparations = 0, artworkReads = 0;
  Completer<LocalAudioArtwork>? prepareGate, imageGate;
  bool failArtwork = false;
  @override
  Future<LocalAudioArtwork> prepareArtwork(Uint8List bytes) async {
    preparations++;
    if (failArtwork) {
      throw const LocalAudioException(LocalAudioFailure.invalidArtwork);
    }
    return prepareGate != null ? await prepareGate!.future : artworkFixture();
  }

  @override
  Future<LocalAudioArtwork> artwork({
    required String sourceId,
    required String artworkId,
  }) async {
    artworkReads++;
    return imageGate != null ? await imageGate!.future : artworkFixture();
  }
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(Duration.zero);
  }
}

class _Harness {
  final bridge = _Bridge();
  final files = _Files();
  final interaction = AppInteractionController();
  final visible = ValueNotifier(true);
  late ProviderContainer container;
  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(700, 1300),
    double scale = 1,
  }) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(bridge.events.close);
    addTearDown(interaction.dispose);
    addTearDown(visible.dispose);
    container = ProviderContainer(
      overrides: [
        localAudioBridgeProvider.overrideWithValue(bridge),
        localAudioArtworkFileAccessProvider.overrideWithValue(files),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: AppInteractionScope(
          controller: interaction,
          child: CupertinoApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: ValueListenableBuilder(
              valueListenable: visible,
              builder: (_, value, _) =>
                  TickerMode(enabled: value, child: const LocalAudioScreen()),
            ),
          ),
        ),
      ),
    );
    await _frames(tester);
  }

  void click(WidgetTester tester, String key) =>
      tester.widget<CupertinoButton>(find.byKey(ValueKey(key))).onPressed!();
  Future<void> choose(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('local-audio-artwork-choose')),
      350,
      scrollable: find.byType(Scrollable).first,
    );
    click(tester, 'local-audio-artwork-choose');
    await _frames(tester);
  }

  Future<void> source(WidgetTester tester) async {
    final name = find.byKey(const ValueKey('local-audio-name'));
    final address = find.byKey(const ValueKey('local-audio-url'));
    await tester.ensureVisible(name);
    await tester.enterText(name, 'Selected station');
    await tester.ensureVisible(address);
    await tester.enterText(address, 'https://radio.example/live.mp3');
    tester.testTextInput.hide();
    await _frames(tester);
  }
}

LocalAudioSnapshot _covered(String source, String cover) => LocalAudioSnapshot(
  supported: true,
  sourceId: source,
  title: source,
  artworkId: cover,
  artworkState: LocalAudioArtworkState.ready,
);
void main() {
  testWidgets(
    'selection is explicit draft; duplicate picker is blocked and Play carries normalized pixels once',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      expect(h.files.picks, 0);
      expect(h.bridge.preparations, 0);
      expect(h.bridge.artworkReads, 0);
      await h.source(tester);
      h.files.gate = Completer<Uint8List?>();
      final pick = tester
          .widget<CupertinoButton>(
            find.byKey(const ValueKey('local-audio-artwork-choose')),
          )
          .onPressed!;
      pick();
      pick();
      await _frames(tester);
      expect(h.files.picks, 1);
      h.files.gate!.complete(artworkJpeg());
      await _frames(tester);
      expect(h.bridge.preparations, 1);
      expect(h.bridge.plays, isEmpty);
      expect(
        find.byKey(const ValueKey('local-audio-draft-cover')),
        findsOneWidget,
      );
      h.click(tester, 'local-audio-start');
      await _frames(tester);
      expect(h.bridge.plays, hasLength(1));
      expect(h.bridge.plays.single.artwork?.bytes, artworkJpeg());
    },
  );
  testWidgets(
    'cancel and invalid cover never start audio; failed cover offers safe fallback',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      h.files.cancel = true;
      await h.choose(tester);
      expect(h.bridge.preparations, 0);
      h.files.cancel = false;
      await h.choose(tester);
      expect(
        find.byKey(const ValueKey('local-audio-draft-cover')),
        findsOneWidget,
      );
      h.bridge.failArtwork = true;
      await h.choose(tester);
      expect(h.bridge.plays, isEmpty);
      expect(
        find.byKey(const ValueKey('local-audio-draft-cover')),
        findsNothing,
      );
      final l10n = AppLocalizations.of(
        tester.element(find.byType(LocalAudioScreen)),
      );
      expect(find.text(l10n.localAudioArtworkInvalid), findsOneWidget);
      await h.source(tester);
      h.click(tester, 'local-audio-start');
      await _frames(tester);
      expect(h.bridge.plays.single.artwork, isNull);
    },
  );
  testWidgets(
    'OS picker background can return a draft but never restores playback authority',
    (tester) async {
      final h = _Harness();
      h.bridge.current = audioState();
      await h.mount(tester);
      h.files.gate = Completer<Uint8List?>();
      await h.choose(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      h.interaction.setActive(false);
      await _frames(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      h.interaction.setActive(true);
      await _frames(tester);
      h.files.gate!.complete(artworkJpeg());
      await _frames(tester);
      expect(
        find.byKey(const ValueKey('local-audio-draft-cover')),
        findsOneWidget,
      );
      expect(h.bridge.plays, isEmpty);
      expect(h.bridge.commands, isEmpty);
    },
  );
  testWidgets(
    'preparing optional artwork does not disable current audio pause',
    (tester) async {
      final h = _Harness();
      h.bridge.current = audioState();
      await h.mount(tester);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(LocalAudioScreen)),
      );
      final pause = tester
          .widget<CupertinoButton>(
            find.widgetWithText(CupertinoButton, l10n.localAudioPause),
          )
          .onPressed!;
      h.bridge.prepareGate = Completer<LocalAudioArtwork>();
      await h.choose(tester);
      pause();
      await _frames(tester);
      expect(h.bridge.commands, ['pause']);
      expect(h.bridge.plays, isEmpty);
      h.bridge.prepareGate!.complete(artworkFixture());
      await _frames(tester);
    },
  );
  testWidgets(
    'source replacement while OS picker is open discards selection before decode',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      h.files.gate = Completer<Uint8List?>();
      await h.choose(tester);
      h.bridge.emit(audioState(id: 'replacement'));
      await _frames(tester);
      h.files.gate!.complete(artworkJpeg());
      await _frames(tester);
      expect(h.bridge.preparations, 0);
      expect(h.bridge.plays, isEmpty);
      expect(
        find.byKey(const ValueKey('local-audio-draft-cover')),
        findsNothing,
      );
    },
  );
  for (final change in ['idle', 'background', 'source', 'bridge']) {
    testWidgets('late native preparation discarded after $change', (
      tester,
    ) async {
      final h = _Harness();
      await h.mount(tester);
      h.bridge.prepareGate = Completer<LocalAudioArtwork>();
      await h.choose(tester);
      expect(h.bridge.preparations, 1);
      if (change == 'idle') {
        h.interaction.setActive(false);
        h.interaction.setActive(true);
      }
      if (change == 'background') {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }
      if (change == 'source') {
        h.bridge.emit(audioState(id: 'replacement'));
      }
      if (change == 'bridge') {
        final replacement = _Bridge();
        addTearDown(replacement.events.close);
        h.container.updateOverrides([
          localAudioBridgeProvider.overrideWithValue(replacement),
          localAudioArtworkFileAccessProvider.overrideWithValue(h.files),
        ]);
      }
      await _frames(tester);
      h.bridge.prepareGate!.complete(artworkFixture());
      await _frames(tester);
      expect(
        find.byKey(const ValueKey('local-audio-draft-cover')),
        findsNothing,
      );
      expect(h.bridge.plays, isEmpty);
    });
  }
  testWidgets(
    'current cover reused across position updates then removed on source change and stop',
    (tester) async {
      final h = _Harness();
      h.bridge.current = _covered('station', 'cover');
      await h.mount(tester);
      expect(
        find.byKey(const ValueKey('local-audio-cover-station-cover')),
        findsOneWidget,
      );
      h.bridge.emit(_covered('station', 'cover'));
      await _frames(tester);
      expect(h.bridge.artworkReads, 1);
      h.bridge.emit(audioState(id: 'new-source'));
      await _frames(tester);
      expect(
        find.byKey(const ValueKey('local-audio-cover-station-cover')),
        findsNothing,
      );
      h.bridge.emit(const LocalAudioSnapshot(supported: true));
      await _frames(tester);
      expect(find.byType(Image), findsNothing);
      expect(h.bridge.commands, isEmpty);
    },
  );
  testWidgets(
    'late current cover does not render under replacement source and hidden screen reads no artwork',
    (tester) async {
      final h = _Harness();
      h.bridge.current = _covered('station', 'cover');
      h.bridge.imageGate = Completer<LocalAudioArtwork>();
      await h.mount(tester);
      h.bridge.emit(_covered('new-source', 'new-cover'));
      await _frames(tester);
      h.bridge.imageGate!.complete(artworkFixture());
      await _frames(tester);
      expect(
        find.byKey(const ValueKey('local-audio-cover-station-cover')),
        findsNothing,
      );
      final reads = h.bridge.artworkReads;
      h.visible.value = false;
      await _frames(tester);
      h.bridge.emit(_covered('hidden-source', 'hidden-cover'));
      await _frames(tester);
      expect(h.bridge.artworkReads, reads);
      expect(h.bridge.commands, isEmpty);
    },
  );
  for (final size in [const Size(320, 900), const Size(1280, 900)]) {
    testWidgets('artwork form and playback fit $size at 2x text', (
      tester,
    ) async {
      final h = _Harness();
      h.bridge.current = _covered('Station with a longer real title', 'cover');
      await h.mount(tester, size: size, scale: 2);
      await h.choose(tester);
      await tester.ensureVisible(
        find.byKey(const ValueKey('local-audio-artwork-remove')),
      );
      await _frames(tester);
      expect(tester.takeException(), isNull);
      h.click(tester, 'local-audio-artwork-remove');
      await _frames(tester);
      expect(
        find.byKey(const ValueKey('local-audio-draft-cover')),
        findsNothing,
      );
    });
  }
}
