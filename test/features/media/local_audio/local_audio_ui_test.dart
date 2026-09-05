import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/local_audio/presentation/local_audio_screen.dart';
import 'package:larenor/features/media/local_audio/presentation/playback_power_screen.dart';
import 'package:larenor/features/media/local_audio/providers/local_audio_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import 'local_audio_ui_fixture.dart';

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(Duration.zero);
  }
}

class _Harness {
  final bridge = FakeLocalAudioBridge();
  final visible = ValueNotifier(true);
  late ProviderContainer container;
  Future<void> mount(
    WidgetTester tester, {
    bool power = false,
    bool pushed = false,
    Size size = const Size(600, 1100),
    double scale = 1,
  }) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(visible.dispose);
    addTearDown(bridge.events.close);
    container = ProviderContainer(
      overrides: [localAudioBridgeProvider.overrideWithValue(bridge)],
    );
    addTearDown(container.dispose);
    Widget screen() => ValueListenableBuilder(
      valueListenable: visible,
      builder: (_, value, _) => TickerMode(
        enabled: value,
        child: power ? const PlaybackPowerScreen() : const LocalAudioScreen(),
      ),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: CupertinoApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: pushed
              ? Builder(
                  builder: (context) => CupertinoPageScaffold(
                    child: CupertinoButton(
                      child: const Text('Open audio'),
                      onPressed: () => Navigator.of(context).push(
                        CupertinoPageRoute<void>(builder: (_) => screen()),
                      ),
                    ),
                  ),
                )
              : screen(),
        ),
      ),
    );
    await _frames(tester);
    if (pushed) {
      await tester.tap(find.text('Open audio'));
      await _frames(tester);
      await tester.pump(const Duration(milliseconds: 400));
      await _frames(tester);
    }
  }

  AppLocalizations labels(WidgetTester tester) => AppLocalizations.of(
    tester.element(
      find.byType(LocalAudioScreen).evaluate().isNotEmpty
          ? find.byType(LocalAudioScreen)
          : find.byType(PlaybackPowerScreen),
    ),
  );
  Future<void> source(
    WidgetTester tester, {
    String uri = 'https://radio.example/live.mp3',
  }) async {
    final name = find.byKey(const ValueKey('local-audio-name'));
    final address = find.byKey(const ValueKey('local-audio-url'));
    await tester.ensureVisible(name);
    await tester.enterText(name, 'Chosen station');
    await tester.ensureVisible(address);
    await tester.enterText(address, uri);
    tester.testTextInput.hide();
    await _frames(tester);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await _frames(tester);
  }
}

void main() {
  testWidgets('current source identity accompanies all native controls', (
    tester,
  ) async {
    final h = _Harness();
    h.bridge.current = audioState();
    await h.mount(tester);
    final l10n = h.labels(tester);
    tester
        .widget<CupertinoButton>(
          find.widgetWithText(CupertinoButton, l10n.localAudioPause),
        )
        .onPressed!();
    await _frames(tester);
    tester.widget<CupertinoSlider>(find.byType(CupertinoSlider)).onChangeEnd!(
      5000,
    );
    await _frames(tester);
    tester
        .widget<CupertinoButton>(
          find.widgetWithText(CupertinoButton, l10n.localAudioStop),
        )
        .onPressed!();
    await _frames(tester);
    h.bridge.emit(audioState(playing: false));
    await _frames(tester);
    tester
        .widget<CupertinoButton>(
          find.widgetWithText(CupertinoButton, l10n.localAudioResume),
        )
        .onPressed!();
    await _frames(tester);
    expect(h.bridge.expectedSources, List.filled(4, 'station-one'));
    expect(h.bridge.commands, ['pause', 'stop', 'resume']);
    expect(h.bridge.seeks, [const Duration(seconds: 5)]);
    await h.unmount(tester);
  });
  testWidgets(
    'opening local audio is passive and double play starts one validated source',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      expect(h.bridge.plays, isEmpty);
      expect(h.bridge.commands, isEmpty);
      await h.source(tester);
      h.bridge.playGate = Completer<void>();
      final play = tester
          .widget<CupertinoButton>(
            find.byKey(const ValueKey('local-audio-start')),
          )
          .onPressed!;
      play();
      play();
      await _frames(tester);
      expect(h.bridge.plays, hasLength(1));
      expect(h.bridge.plays.single.title, 'Chosen station');
      expect(
        h.bridge.plays.single.uri.toString(),
        'https://radio.example/live.mp3',
      );
      h.bridge.playGate!.complete();
      await _frames(tester);
      expect(find.text(h.labels(tester).localAudioPlaying), findsNothing);
      await h.unmount(tester);
    },
  );

  for (final invalid in [
    'https://radio.example/live?token=secret',
    'https://user:secret@radio.example/live',
    'https://@radio.example/live',
    'https://radio.example/live#secret',
    'file:///private/audio.mp3',
  ]) {
    testWidgets('raw protected or unsupported source is rejected ($invalid)', (
      tester,
    ) async {
      final h = _Harness();
      await h.mount(tester);
      await h.source(tester, uri: invalid);
      tester
          .widget<CupertinoButton>(
            find.byKey(const ValueKey('local-audio-start')),
          )
          .onPressed!();
      await _frames(tester);
      expect(h.bridge.plays, isEmpty);
      expect(
        find.text(h.labels(tester).localAudioInvalidSource),
        findsOneWidget,
      );
      await h.unmount(tester);
    });
  }

  testWidgets('live stream duration remains unknown and has no seek slider', (
    tester,
  ) async {
    final h = _Harness();
    h.bridge.current = audioState(duration: null);
    await h.mount(tester);
    expect(find.text('Current performer'), findsOneWidget);
    expect(find.text('Current album'), findsOneWidget);
    expect(find.byType(CupertinoSlider), findsNothing);
    expect(find.textContaining('00:00'), findsNothing);
    expect(find.text(h.labels(tester).localAudioPlaying), findsOneWidget);
    await h.unmount(tester);
  });

  testWidgets('stale source pause and seek recheck current native identity', (
    tester,
  ) async {
    final h = _Harness();
    h.bridge.current = audioState();
    await h.mount(tester);
    final pause = tester
        .widget<CupertinoButton>(
          find.widgetWithText(
            CupertinoButton,
            h.labels(tester).localAudioPause,
          ),
        )
        .onPressed!;
    final seek = tester
        .widget<CupertinoSlider>(find.byType(CupertinoSlider))
        .onChangeEnd!;
    h.bridge.current = audioState(id: 'replacement-source');
    pause();
    await _frames(tester);
    seek(5000);
    await _frames(tester);
    expect(h.bridge.snapshotReads, 2);
    expect(h.bridge.commands, isEmpty);
    expect(h.bridge.seeks, isEmpty);
    expect(find.text(h.labels(tester).localAudioUnavailable), findsOneWidget);
    await h.unmount(tester);
  });

  for (final visibility in ['background', 'offstage']) {
    testWidgets(
      '$visibility rejects captured actions and late identity reads',
      (tester) async {
        final h = _Harness();
        h.bridge.current = audioState();
        await h.mount(tester);
        final pause = tester
            .widget<CupertinoButton>(
              find.widgetWithText(
                CupertinoButton,
                h.labels(tester).localAudioPause,
              ),
            )
            .onPressed!;
        h.bridge.snapshotGate = Completer<void>();
        pause();
        await _frames(tester);
        if (visibility == 'background') {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
        } else {
          h.visible.value = false;
        }
        await _frames(tester);
        h.bridge.snapshotGate!.complete();
        await _frames(tester);
        pause();
        await _frames(tester);
        expect(h.bridge.commands, isEmpty);
        expect(h.bridge.snapshotReads, 1);
        if (visibility == 'background') {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        }
        await h.unmount(tester);
      },
    );
  }

  testWidgets('popping audio route never sends native stop', (tester) async {
    final h = _Harness();
    h.bridge.current = audioState();
    await h.mount(tester, pushed: true);
    Navigator.of(tester.element(find.byType(LocalAudioScreen))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(LocalAudioScreen), findsNothing);
    expect(h.bridge.commands, isEmpty);
    await h.unmount(tester);
  });

  testWidgets(
    'power opening is read-only; settings need explicit action and resume refreshes',
    (tester) async {
      final h = _Harness();
      await h.mount(tester, power: true);
      expect(h.bridge.powerReads, 1);
      expect(h.bridge.batteryOpens, 0);
      expect(h.bridge.notificationOpens, 0);
      expect(h.bridge.plays, isEmpty);
      final l10n = h.labels(tester);
      await tester.ensureVisible(find.text(l10n.localAudioOpenBattery));
      await tester.tap(find.text(l10n.localAudioOpenBattery));
      await _frames(tester);
      expect(h.bridge.batteryOpens, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await _frames(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _frames(tester);
      expect(h.bridge.powerReads, 2);
      await tester.ensureVisible(find.text(l10n.localAudioOpenNotifications));
      await tester.tap(find.text(l10n.localAudioOpenNotifications));
      await _frames(tester);
      expect(h.bridge.notificationOpens, 1);
      await h.unmount(tester);
    },
  );

  testWidgets(
    'hidden power callback cannot open OS settings and missing OEM action is visible',
    (tester) async {
      final h = _Harness();
      await h.mount(tester, power: true);
      final l10n = h.labels(tester);
      final open = tester
          .widget<CupertinoButton>(
            find.widgetWithText(CupertinoButton, l10n.localAudioOpenBattery),
          )
          .onPressed!;
      h.visible.value = false;
      await _frames(tester);
      open();
      await _frames(tester);
      expect(h.bridge.batteryOpens, 0);
      h.visible.value = true;
      h.bridge.settingsAvailable = false;
      await _frames(tester);
      open();
      await _frames(tester);
      expect(h.bridge.batteryOpens, 1);
      expect(find.text(l10n.localAudioSettingsUnavailable), findsOneWidget);
      await h.unmount(tester);
    },
  );

  for (final device in [
    (name: 'phone', size: const Size(320, 1100), scale: 2.0),
    (name: 'tablet', size: const Size(1280, 1000), scale: 1.6),
  ]) {
    for (final power in [false, true]) {
      testWidgets(
        '${device.name} ${power ? 'power' : 'audio'} fits large text',
        (tester) async {
          final h = _Harness();
          h.bridge.current = audioState();
          await h.mount(
            tester,
            power: power,
            size: device.size,
            scale: device.scale,
          );
          final scroll = find.byType(Scrollable).first;
          await tester.drag(scroll, const Offset(0, -900));
          await _frames(tester);
          expect(tester.takeException(), isNull);
          expect(h.bridge.plays, isEmpty);
          expect(h.bridge.commands, isEmpty);
          await h.unmount(tester);
        },
      );
    }
  }
}
