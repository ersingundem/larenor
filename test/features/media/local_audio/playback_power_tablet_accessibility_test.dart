import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/media/local_audio/presentation/playback_power_screen.dart';
import 'package:larenor/features/media/local_audio/providers/local_audio_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/app_page_scaffold.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

import 'local_audio_ui_fixture.dart';

Widget _tabletApp(Locale locale, {AppInteractionController? interaction}) {
  final app = CupertinoApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: const TextScaler.linear(2)),
      child: child!,
    ),
    home: const PlaybackPowerScreen(),
  );
  return interaction == null
      ? app
      : AppInteractionScope(controller: interaction, child: app);
}

void main() {
  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1200.0]) {
      testWidgets('${locale.languageCode} playback power hierarchy fits '
          '${width.toInt()}px at 2x text', (tester) async {
        final semantics = tester.ensureSemantics();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final bridge = FakeLocalAudioBridge();
        addTearDown(bridge.events.close);

        try {
          await tester.pumpWidget(
            ProviderScope(
              overrides: [localAudioBridgeProvider.overrideWithValue(bridge)],
              child: _tabletApp(locale),
            ),
          );
          await tester.pumpAndSettle();
          final l10n = await AppLocalizations.delegate.load(locale);

          expect(find.byType(AppSurface), findsOneWidget);
          expect(find.byType(SettingsSection), findsAtLeastNWidgets(2));

          final heading = find.byKey(
            const ValueKey('local-audio-power-section-title'),
          );
          final headingNode = tester.getSemantics(heading);
          expect(headingNode.label, l10n.localAudioPowerTitle);
          expect(headingNode.flagsCollection.isHeader, isTrue);
          expect(headingNode.flagsCollection.isButton, isFalse);

          for (final key in const [
            'local-audio-open-battery',
            'local-audio-open-notifications',
            'local-audio-power-refresh',
          ]) {
            final action = find.byKey(ValueKey(key));
            final node = tester.getSemantics(action);
            expect(node.flagsCollection.isButton, isTrue);
            expect(node.rect.width, greaterThanOrEqualTo(48));
            expect(node.rect.height, greaterThanOrEqualTo(48));
          }

          final refresh = find.descendant(
            of: find.byKey(const ValueKey('local-audio-power-refresh')),
            matching: find.text(l10n.commonRefresh),
          );
          Focus.of(tester.element(refresh)).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(bridge.powerReads, 2);

          final battery = find.descendant(
            of: find.byKey(const ValueKey('local-audio-open-battery')),
            matching: find.text(l10n.localAudioOpenBattery),
          );
          Focus.of(tester.element(battery)).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(bridge.batteryOpens, 1);
          expect(bridge.notificationOpens, 0);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });
    }
  }

  testWidgets('idle retires captured native power settings callback', (
    tester,
  ) async {
    final bridge = FakeLocalAudioBridge();
    final interaction = AppInteractionController();
    addTearDown(bridge.events.close);
    addTearDown(interaction.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [localAudioBridgeProvider.overrideWithValue(bridge)],
        child: _tabletApp(const Locale('en'), interaction: interaction),
      ),
    );
    await tester.pumpAndSettle();
    final battery = find.byKey(const ValueKey('local-audio-open-battery'));
    final stale = tester.widget<CupertinoButton>(battery).onPressed!;
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    interaction.setActive(false);
    await tester.pump();
    expect(find.text(l10n.localAudioNotifications), findsNothing);
    interaction.setActive(true);
    await tester.pumpAndSettle();
    expect(bridge.powerReads, 2);
    expect(find.text(l10n.localAudioNotifications), findsOneWidget);
    stale();
    await tester.pumpAndSettle();
    expect(bridge.batteryOpens, 0);
    tester.widget<CupertinoButton>(battery).onPressed!();
    await tester.pumpAndSettle();
    expect(bridge.batteryOpens, 1);
  });

  testWidgets('power read failure is private and announced as live status', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final bridge = FakeLocalAudioBridge()
      ..powerError = StateError('private native diagnostic');
    addTearDown(bridge.events.close);
    try {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [localAudioBridgeProvider.overrideWithValue(bridge)],
          child: _tabletApp(const Locale('en')),
        ),
      );
      await tester.pumpAndSettle();
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      final status = find.byKey(const ValueKey('local-audio-power-status'));
      expect(tester.getSemantics(status).label, l10n.healthReadError);
      expect(tester.getSemantics(status).flagsCollection.isLiveRegion, isTrue);
      expect(find.textContaining('private native diagnostic'), findsNothing);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('bridge replacement retires captured native settings callback', (
    tester,
  ) async {
    final oldBridge = FakeLocalAudioBridge();
    final newBridge = FakeLocalAudioBridge();
    final container = ProviderContainer(
      overrides: [localAudioBridgeProvider.overrideWithValue(oldBridge)],
    );
    addTearDown(oldBridge.events.close);
    addTearDown(newBridge.events.close);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _tabletApp(const Locale('en')),
      ),
    );
    await tester.pumpAndSettle();
    final battery = find.byKey(const ValueKey('local-audio-open-battery'));
    final stale = tester.widget<CupertinoButton>(battery).onPressed!;
    container.updateOverrides([
      localAudioBridgeProvider.overrideWithValue(newBridge),
    ]);
    await tester.pump();
    stale();
    await tester.pumpAndSettle();
    expect(oldBridge.batteryOpens, 0);
    expect(newBridge.batteryOpens, 0);
    expect(oldBridge.powerReads, 1);
    expect(newBridge.powerReads, 1);
    tester.widget<CupertinoButton>(battery).onPressed!();
    await tester.pumpAndSettle();
    expect(newBridge.batteryOpens, 1);
  });
}
