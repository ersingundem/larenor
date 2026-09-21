import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/features/game_streaming/data/android_game_stream_port.dart';
import 'package:larenor/features/game_streaming/domain/game_stream_session.dart';
import 'package:larenor/features/game_streaming/presentation/game_stream_settings_screen.dart';
import 'package:larenor/features/settings/presentation/settings_split_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

final class _CapabilitiesPort implements GameStreamCapabilityPort {
  _CapabilitiesPort({this.pending});

  final Completer<AndroidGameStreamCapabilities>? pending;
  int calls = 0;

  @override
  Future<AndroidGameStreamCapabilities> capabilities() {
    calls += 1;
    final wait = pending;
    if (calls == 1 && wait != null) return wait.future;
    return Future.value(
      const AndroidGameStreamCapabilities(
        available: false,
        engineRevision: null,
        intents: {},
      ),
    );
  }
}

Future<AppInteractionController> _mount(
  WidgetTester tester, {
  required Widget child,
  required String language,
  required double width,
  AppInteractionController? interaction,
  bool settle = true,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = interaction ?? AppInteractionController();
  if (interaction == null) addTearDown(controller.dispose);
  await tester.pumpWidget(
    ProviderScope(
      child: AppInteractionScope(
        controller: controller,
        child: CupertinoApp(
          theme: larenorTheme(brightness: Brightness.light),
          locale: Locale(language),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: child,
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return controller;
}

void main() {
  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1280.0]) {
      testWidgets(
        'game streaming route is discoverable and accessible $language $width 2x',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            final port = _CapabilitiesPort();
            await _mount(
              tester,
              language: language,
              width: width,
              child: SettingsSplitScreen(
                gameStreamPort: port,
                remoteGateCurrent: () => true,
              ),
            );
            final l10n = AppLocalizations.of(
              tester.element(find.byType(SettingsSplitScreen)),
            );
            final entry = find.text(l10n.gameStreamingTitle).first;
            await tester.ensureVisible(entry);
            final entryNode = tester.getSemantics(entry);
            expect(entryNode.flagsCollection.isButton, isTrue);
            expect(
              entryNode.getSemanticsData().hasAction(ui.SemanticsAction.tap),
              isTrue,
            );
            expect(entryNode.rect.height, greaterThanOrEqualTo(48));
            Focus.of(tester.element(entry)).requestFocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pumpAndSettle();

            expect(find.byType(GameStreamSettingsScreen), findsOneWidget);
            expect(
              tester
                  .getSemantics(
                    find.byKey(const ValueKey('game-stream-engine-header')),
                  )
                  .flagsCollection
                  .isHeader,
              isTrue,
            );
            final status = find.byKey(const ValueKey('game-stream-status'));
            expect(
              tester.getSemantics(status).flagsCollection.isLiveRegion,
              isTrue,
            );
            expect(
              tester.getSemantics(status).label,
              contains(l10n.gameStreamingUnavailable),
            );
            final refresh = find.byKey(const ValueKey('game-stream-refresh'));
            expect(tester.getRect(refresh).height, greaterThanOrEqualTo(48));
            expect(
              tester.getSemantics(refresh).flagsCollection.isButton,
              isTrue,
            );
            final refreshLabel = find.descendant(
              of: refresh,
              matching: find.byType(Text),
            );
            Focus.of(tester.element(refreshLabel)).requestFocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.space);
            await tester.pumpAndSettle();
            expect(port.calls, 2);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump();
            semantics.dispose();
          }
        },
      );
    }
  }

  testWidgets('late capability callback cannot revive an expired route', (
    tester,
  ) async {
    final pending = Completer<AndroidGameStreamCapabilities>();
    final port = _CapabilitiesPort(pending: pending);
    final interaction = AppInteractionController();
    addTearDown(interaction.dispose);
    await _mount(
      tester,
      language: 'en',
      width: 1280,
      interaction: interaction,
      settle: false,
      child: GameStreamSettingsScreen(port: port, gateCurrent: () => true),
    );
    await tester.pump();
    expect(port.calls, 1);
    interaction.setActive(false);
    interaction.setActive(true);
    await tester.pump();
    pending.complete(
      const AndroidGameStreamCapabilities(
        available: true,
        engineRevision: 'fixture-1',
        intents: {GameStreamIntent.stream},
      ),
    );
    await tester.pump();
    final l10n = AppLocalizations.of(
      tester.element(find.byType(GameStreamSettingsScreen)),
    );
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('game-stream-status')))
          .label,
      contains(l10n.gameStreamingNotChecked),
    );
    expect(find.text(l10n.gameStreamingAvailable), findsNothing);
  });

  testWidgets('covering the route expires previously verified capability', (
    tester,
  ) async {
    final port = _CapabilitiesPort();
    await _mount(
      tester,
      language: 'en',
      width: 1280,
      child: GameStreamSettingsScreen(port: port, gateCurrent: () => true),
    );
    final screen = find.byType(GameStreamSettingsScreen);
    final l10n = AppLocalizations.of(tester.element(screen));
    final navigator = Navigator.of(tester.element(screen));
    expect(find.text(l10n.gameStreamingUnavailable), findsOneWidget);
    unawaited(
      navigator.push(
        CupertinoPageRoute<void>(builder: (_) => const SizedBox.expand()),
      ),
    );
    await tester.pumpAndSettle();
    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.text(l10n.gameStreamingNotChecked), findsOneWidget);
    expect(port.calls, 1);
  });
}
