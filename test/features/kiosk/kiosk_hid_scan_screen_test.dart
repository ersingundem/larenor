import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/kiosk/presentation/kiosk_hid_scan_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

Future<AppInteractionController> mountScanner(
  WidgetTester tester, {
  required String language,
  required double width,
  DateTime Function()? now,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 1100);
  addTearDown(tester.view.reset);
  final interaction = AppInteractionController();
  addTearDown(interaction.dispose);
  await tester.pumpWidget(
    ProviderScope(
      child: CupertinoApp(
        locale: Locale(language),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => AppInteractionScope(
          controller: interaction,
          child: MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
        ),
        home: KioskHidScanScreen(now: now),
      ),
    ),
  );
  await tester.pump();
  return interaction;
}

void main() {
  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1280.0]) {
      testWidgets('HID reader is accessible at $language $width with 2x text', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        try {
          await mountScanner(tester, language: language, width: width);
          final start = find.byKey(const ValueKey('kiosk-hid-start'));
          final stop = find.byKey(const ValueKey('kiosk-hid-stop'));
          expect(tester.getSize(start).height, greaterThanOrEqualTo(48));
          expect(tester.getSize(stop).height, greaterThanOrEqualTo(48));
          expect(tester.widget<CupertinoButton>(start).onPressed, isNotNull);
          expect(
            tester
                .getSemantics(find.byKey(const ValueKey('kiosk-hid-status')))
                .flagsCollection
                .isLiveRegion,
            isTrue,
          );
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });
    }
  }

  testWidgets('keyboard scan needs explicit start and review; idle clears it', (
    tester,
  ) async {
    var now = DateTime.utc(2026, 1, 1);
    await mountScanner(tester, language: 'en', width: 600, now: () => now);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: 'A');
    expect(find.byKey(const ValueKey('kiosk-hid-value')), findsNothing);
    final start = find.byKey(const ValueKey('kiosk-hid-start'));
    await tester.tap(start);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: 'A');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB, character: 'B');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.textContaining('Captured 2 characters'), findsOneWidget);
    expect(find.byKey(const ValueKey('kiosk-hid-value')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('kiosk-hid-review')));
    await tester.pump();
    expect(find.text('AB'), findsOneWidget);
    now = now.add(const Duration(seconds: 16));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const ValueKey('kiosk-hid-value')), findsNothing);
    expect(find.textContaining('timed out'), findsOneWidget);
  });

  testWidgets('background and route loss retire captured data', (tester) async {
    final interaction = await mountScanner(tester, language: 'tr', width: 1280);
    await tester.tap(find.byKey(const ValueKey('kiosk-hid-start')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: 'A');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('kiosk-hid-review')));
    await tester.pump();
    expect(find.text('A'), findsOneWidget);
    interaction.setActive(false);
    await tester.pump();
    expect(find.byKey(const ValueKey('kiosk-hid-value')), findsNothing);
    interaction.setActive(true);
    await tester.pump();
    expect(find.byKey(const ValueKey('kiosk-hid-value')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('kiosk-hid-start')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB, character: 'B');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('kiosk-hid-review')));
    await tester.pump();
    expect(find.text('B'), findsOneWidget);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(
      CupertinoPageRoute<void>(builder: (_) => const Text('next')),
    );
    await tester.pumpAndSettle();
    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('kiosk-hid-value')), findsNothing);
  });
}
