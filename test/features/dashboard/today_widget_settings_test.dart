import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/dashboard/presentation/today_widget_settings_screen.dart';
import 'package:larenor/features/today/domain/today_daily_summary.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/service_root_scaffold.dart';
import 'package:larenor/shared/widgets/settings_action_tile.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

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
  String language = 'tr',
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final results = <TileConfig>[];
  await tester.pumpWidget(
    ProviderScope(
      child: CupertinoApp(
        locale: Locale(language),
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
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  return results;
}

void main() {
  for (final language in ['en', 'tr']) {
    for (final size in [const Size(600, 900), const Size(1200, 900)]) {
      testWidgets(
        '$language edits Today context at ${size.width}px with 2x text',
        (tester) async {
          final semantics = tester.ensureSemantics();
          final results = await _mount(tester, size: size, language: language);
          expect(find.byType(ServiceRootScaffold), findsOneWidget);
          expect(find.byType(SettingsSection), findsNWidgets(3));
          expect(find.byType(SettingsActionTile), findsOneWidget);
          final title = tester.getSemantics(
            find.byKey(const ValueKey('today-widget-title')),
          );
          final searchTitle = tester.getSemantics(
            find.byKey(const ValueKey('today-widget-search-title')),
          );
          expect(title.flagsCollection.isHeader, isTrue);
          expect(title.flagsCollection.isButton, isFalse);
          expect(searchTitle.flagsCollection.isHeader, isTrue);
          expect(searchTitle.flagsCollection.isButton, isFalse);

          final shopping = find.byKey(
            const ValueKey('today-widget-section-shopping'),
          );
          final shoppingNode = tester.getSemantics(shopping);
          expect(shoppingNode.id, isNot(title.id));
          expect(shoppingNode.flagsCollection.isHeader, isFalse);
          expect(shoppingNode.flagsCollection.isButton, isTrue);
          expect(shoppingNode.flagsCollection.isSelected, ui.Tristate.isTrue);
          for (final kind in TodayDailySummaryKind.values) {
            expect(
              tester
                  .getRect(
                    find.byKey(ValueKey('today-widget-section-${kind.name}')),
                  )
                  .shortestSide,
              greaterThanOrEqualTo(48),
            );
          }

          final calendar = find.byKey(
            const ValueKey('today-widget-section-calendar'),
          );
          final calendarLabel = find.descendant(
            of: calendar,
            matching: find.byType(Text),
          );
          Focus.of(tester.element(calendarLabel)).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pump();
          expect(
            tester.getSemantics(calendar).flagsCollection.isSelected,
            ui.Tristate.isTrue,
          );

          final save = find.byKey(const ValueKey('today-widget-save'));
          expect(tester.getRect(save).shortestSide, greaterThanOrEqualTo(48));
          expect(tester.getSemantics(save).flagsCollection.isButton, isTrue);
          await tester.enterText(
            find.byKey(const ValueKey('today-widget-query')),
            'dişçi',
          );
          Focus.of(
            tester.element(
              find.descendant(of: save, matching: find.byType(Text)),
            ),
          ).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();

          expect(results, hasLength(1));
          expect(results.single.todaySection, 'calendar');
          expect(results.single.todayQuery, 'dişçi');
          expect(results.single.width, 3);
          expect(results.single.height, 2);
          expect(tester.takeException(), isNull);
          semantics.dispose();
        },
      );
    }
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
