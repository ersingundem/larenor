import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/dashboard/presentation/tiles/today_tile.dart';
import 'package:larenor/features/today/data/today_controller.dart';
import 'package:larenor/features/today/domain/today_daily_summary.dart';
import 'package:larenor/features/today/domain/today_models.dart';
import 'package:larenor/features/today/providers/today_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

final _now = DateTime.utc(2026, 9, 11, 8);

TodayDailySummarySection _section(
  TodayDailySummaryState state, {
  int? count,
  List<TodayDailySummaryEntry> entries = const [],
}) => TodayDailySummarySection(
  kind: TodayDailySummaryKind.shopping,
  state: state,
  totalCount: count,
  entries: entries,
);

Future<void> _mountCard(
  WidgetTester tester,
  TodayDailySummarySection? section, {
  bool loading = false,
  bool offline = false,
  String query = '',
  Size size = const Size(600, 900),
  Locale locale = const Locale('en'),
  VoidCallback? onOpen,
  VoidCallback? onRefresh,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    CupertinoApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: const TextScaler.linear(2),
        ),
        child: CupertinoPageScaffold(
          child: Center(
            child: SizedBox(
              width: size.width >= 1000 ? 520 : 360,
              height: 300,
              child: TodayDashboardCard(
                section: section,
                loading: loading,
                offline: offline,
                query: query,
                onOpen: onOpen,
                onRefresh: onRefresh,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

class _Controller implements TodayController {
  int reads = 0;
  @override
  Future<void> refresh({bool afterCurrent = false}) async => reads++;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

TodaySnapshot _snapshot() => TodaySnapshot(
  configured: true,
  refreshedAt: _now,
  calendars: [
    TodayCalendar(
      entityId: 'calendar.family',
      title: 'Family',
      events: TodayRead(
        value: [
          TodayCalendarEvent(
            uid: 'dentist',
            title: 'Dentist',
            start: _now,
            end: _now.add(const Duration(hours: 1)),
            allDay: false,
          ),
          TodayCalendarEvent(
            uid: 'school',
            title: 'School',
            start: _now,
            end: _now.add(const Duration(hours: 1)),
            allDay: false,
          ),
        ],
      ),
    ),
  ],
);

void main() {
  testWidgets('keeps every read state explicit without false rows', (
    tester,
  ) async {
    for (final state in <(TodayDailySummaryState, String)>[
      (TodayDailySummaryState.empty, 'Nothing due'),
      (TodayDailySummaryState.partial, 'Partial view'),
      (TodayDailySummaryState.stale, 'Saved view'),
      (TodayDailySummaryState.offline, 'Offline'),
    ]) {
      await _mountCard(
        tester,
        _section(
          state.$1,
          count: state.$1 == TodayDailySummaryState.stale ? 1 : null,
        ),
      );
      expect(find.textContaining(state.$2), findsOneWidget);
      expect(
        find.byKey(const ValueKey('today-dashboard-refresh')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    }
    await _mountCard(tester, null, loading: true);
    expect(find.text('Loading…'), findsOneWidget);
    await _mountCard(tester, null, offline: true);
    expect(find.text('Offline'), findsOneWidget);
  });

  testWidgets(
    'filters locally and exposes 48dp keyboard and TalkBack actions',
    (tester) async {
      final opened = <bool>[];
      final refreshed = <bool>[];
      final semantics = tester.ensureSemantics();
      for (final size in [const Size(600, 900), const Size(1280, 900)]) {
        await _mountCard(
          tester,
          _section(
            TodayDailySummaryState.current,
            count: 2,
            entries: const [
              TodayDailySummaryEntry(
                sourceId: 'todo.shopping',
                itemId: 'milk',
                title: 'Sut',
              ),
              TodayDailySummaryEntry(
                sourceId: 'todo.shopping',
                itemId: 'bread',
                title: 'Ekmek',
              ),
            ],
          ),
          size: size,
          locale: const Locale('tr'),
          query: 'süt',
          onOpen: () => opened.add(true),
          onRefresh: () => refreshed.add(true),
        );
        expect(find.text('Sut'), findsOneWidget);
        expect(find.text('Ekmek'), findsNothing);
        for (final key in ['today-dashboard-open', 'today-dashboard-refresh']) {
          expect(
            tester.getSize(find.byKey(ValueKey(key))).height,
            greaterThanOrEqualTo(48),
          );
        }
        expect(
          tester
              .getSemantics(find.byKey(const ValueKey('today-dashboard-card')))
              .label,
          contains('Alışveriş'),
        );
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(opened, [true]);
      expect(refreshed, isEmpty);
      semantics.dispose();
    },
  );

  testWidgets(
    'tile prefers its personal section/query and refreshes only explicitly',
    (tester) async {
      final controller = _Controller();
      final stream = StreamController<TodaySnapshot>();
      final container = ProviderContainer(
        overrides: [
          todayRetainedScopeProvider.overrideWithValue(null),
          todayProvider.overrideWith((_) => stream.stream),
          todayControllerProvider.overrideWithValue(controller),
        ],
      );
      addTearDown(stream.close);
      addTearDown(container.dispose);
      container.read(todaySummarySelectionProvider.notifier)
        ..select(TodayDailySummaryKind.shopping)
        ..updateQuery('milk');
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: CupertinoApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const CupertinoPageScaffold(
              child: SizedBox(
                width: 520,
                height: 300,
                child: TodayTile(
                  tile: TileConfig(
                    id: 'today',
                    type: TileType.today,
                    x: 0,
                    y: 0,
                    width: 3,
                    height: 2,
                    todaySection: 'calendar',
                    todayQuery: 'dentist',
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      stream.add(_snapshot());
      await tester.pumpAndSettle();
      expect(find.text('Dentist'), findsOneWidget);
      expect(find.text('School'), findsNothing);
      expect(controller.reads, 0);
      await tester.tap(find.byKey(const ValueKey('today-dashboard-refresh')));
      await tester.pumpAndSettle();
      expect(controller.reads, 1);
      expect(container.read(todaySummarySelectionProvider)?.query, 'milk');
      expect(
        container.read(todaySummarySelectionProvider)?.kind,
        TodayDailySummaryKind.shopping,
      );
    },
  );
}
