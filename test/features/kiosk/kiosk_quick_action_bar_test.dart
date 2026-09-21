import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/kiosk/presentation/kiosk_quick_action_bar.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

Future<void> _mount(
  WidgetTester tester, {
  required Locale locale,
  required double width,
  required Future<void> Function() exit,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 800);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    CupertinoApp(
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(2)),
        child: child!,
      ),
      home: CupertinoPageScaffold(
        child: KioskQuickActionBar(
          onHome: () async {},
          onSettings: () async {},
          onExit: exit,
          exitEnabled: true,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1280.0]) {
      testWidgets(
        '${locale.languageCode} $width 2x has keyboard-reachable 48dp actions',
        (tester) async {
          var exits = 0;
          await _mount(
            tester,
            locale: locale,
            width: width,
            exit: () async => exits++,
          );
          for (final key in const [
            'kiosk-quick-home',
            'kiosk-quick-settings',
            'kiosk-quick-exit',
          ]) {
            final finder = find.byKey(ValueKey(key));
            expect(tester.getSize(finder).height, greaterThanOrEqualTo(48));
          }
          for (var i = 0; i < 3; i++) {
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          }
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pump();
          expect(exits, 1);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('pending exit is single-flight and disables every stale action', (
    tester,
  ) async {
    final gate = Completer<void>();
    var exits = 0;
    await _mount(
      tester,
      locale: const Locale('en'),
      width: 600,
      exit: () {
        exits++;
        return gate.future;
      },
    );
    final exit = find.byKey(const ValueKey('kiosk-quick-exit'));
    await tester.tap(exit);
    await tester.tap(exit, warnIfMissed: false);
    await tester.pump();
    expect(exits, 1);
    expect(tester.widget<CupertinoButton>(exit).onPressed, isNull);
    gate.complete();
    await tester.pumpAndSettle();
  });
}
