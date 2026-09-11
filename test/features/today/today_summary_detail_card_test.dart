import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/today/domain/today_daily_summary.dart';
import 'package:larenor/features/today/presentation/today_summary_detail_card.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

Future<void> _mount(
  WidgetTester tester,
  TodayDailySummarySection section, {
  Size size = const Size(600, 800),
  double scale = 1,
  VoidCallback? onOpen,
  VoidCallback? onClose,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    CupertinoApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MediaQuery(
        data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
        child: CupertinoPageScaffold(
          child: TodaySummaryDetailCard(
            section: section,
            onOpen: onOpen,
            onClose: onClose,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

TodayDailySummarySection _section(
  TodayDailySummaryState state, {
  List<TodayDailySummaryEntry> entries = const [],
  int? count,
}) => TodayDailySummarySection(
  kind: TodayDailySummaryKind.shopping,
  state: state,
  totalCount: count,
  entries: entries,
);

void main() {
  testWidgets('keeps loading empty partial stale and offline detail explicit', (
    tester,
  ) async {
    for (final state in <(TodayDailySummaryState, String)>[
      (TodayDailySummaryState.unread, 'Awaiting source'),
      (TodayDailySummaryState.empty, 'Nothing due'),
      (TodayDailySummaryState.partial, 'Partial view'),
      (TodayDailySummaryState.stale, 'Saved view · 1'),
      (TodayDailySummaryState.offline, 'Offline'),
    ]) {
      await _mount(
        tester,
        _section(
          state.$1,
          count: state.$1 == TodayDailySummaryState.stale ? 1 : null,
        ),
        onOpen: () {},
      );
      expect(find.text(state.$2), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('bounds entries and exposes 48dp keyboard actions', (
    tester,
  ) async {
    final opened = <bool>[];
    final closed = <bool>[];
    await _mount(
      tester,
      _section(
        TodayDailySummaryState.current,
        count: 20,
        entries: [
          for (var index = 0; index < 20; index++)
            TodayDailySummaryEntry(
              sourceId: 'todo.shopping',
              title: 'Entry $index',
            ),
        ],
      ),
      size: const Size(1280, 900),
      scale: 2,
      onOpen: () => opened.add(true),
      onClose: () => closed.add(true),
    );

    expect(find.text('Entry 0'), findsOneWidget);
    expect(find.text('Entry 8'), findsNothing);
    for (final key in [
      'today-summary-detail-close',
      'today-summary-detail-open',
    ]) {
      expect(
        tester.getSize(find.byKey(ValueKey(key))).height,
        greaterThanOrEqualTo(48),
      );
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(closed, [true]);
    expect(opened, isEmpty);
    await tester.tap(find.byKey(const ValueKey('today-summary-detail-open')));
    expect(opened, [true]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('offline detail never offers a false open action', (
    tester,
  ) async {
    await _mount(
      tester,
      _section(TodayDailySummaryState.offline),
      onOpen: () => fail('offline detail must stay closed'),
    );
    expect(
      find.byKey(const ValueKey('today-summary-detail-open')),
      findsNothing,
    );
  });
}
