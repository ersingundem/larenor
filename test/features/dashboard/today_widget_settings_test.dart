import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/dashboard/presentation/today_widget_settings_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

const _tile = TileConfig(
  id: 'today',
  type: TileType.today,
  x: 0,
  y: 0,
  width: 3,
  height: 2,
  todaySection: 'shopping',
  todayQuery: 'milk',
);

Future<List<TileConfig>> _mount(
  WidgetTester tester, {
  required Size size,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final results = <TileConfig>[];
  await tester.pumpWidget(
    CupertinoApp(
      locale: const Locale('tr'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(2)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => CupertinoPageScaffold(
          child: Center(
            child: CupertinoButton(
              onPressed: () async {
                final value = await Navigator.push<TileConfig>(
                  context,
                  CupertinoPageRoute(
                    builder: (_) =>
                        const TodayWidgetSettingsScreen(initialTile: _tile),
                  ),
                );
                if (value != null) results.add(value);
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  return results;
}

void main() {
  for (final size in [const Size(600, 900), const Size(1280, 900)]) {
    testWidgets('edits Today context at ${size.width}px with 2x text', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final results = await _mount(tester, size: size);
      final shopping = find.byKey(
        const ValueKey('today-widget-section-shopping'),
      );
      expect(
        tester.getSemantics(shopping).flagsCollection.isSelected,
        ui.Tristate.isTrue,
      );
      await tester.tap(
        find.byKey(const ValueKey('today-widget-section-calendar')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('today-widget-query')),
        'dişçi',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(results, hasLength(1));
      expect(results.single.todaySection, 'calendar');
      expect(results.single.todayQuery, 'dişçi');
      expect(results.single.width, 3);
      expect(results.single.height, 2);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });
  }

  testWidgets('filter strips controls and is bounded before save', (
    tester,
  ) async {
    final results = await _mount(tester, size: const Size(600, 900));
    await tester.enterText(
      find.byKey(const ValueKey('today-widget-query')),
      '${List.filled(140, 'x').join()}\nsecret',
    );
    await tester.tap(find.byKey(const ValueKey('today-widget-save')));
    await tester.pumpAndSettle();
    expect(results.single.todayQuery, hasLength(128));
    expect(results.single.todayQuery, isNot(contains('secret')));
  });
}
