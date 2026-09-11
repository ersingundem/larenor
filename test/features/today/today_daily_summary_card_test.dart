import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/today/domain/today_daily_summary.dart';
import 'package:larenor/features/today/presentation/today_daily_summary_card.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

const _summary = TodayDailySummary(
  shopping: TodayDailySummarySection(
    kind: TodayDailySummaryKind.shopping,
    state: TodayDailySummaryState.current,
    totalCount: 2,
    entries: [TodayDailySummaryEntry(sourceId: 'todo.shopping', title: 'Milk')],
  ),
  chores: TodayDailySummarySection(
    kind: TodayDailySummaryKind.chores,
    state: TodayDailySummaryState.empty,
    totalCount: 0,
  ),
  calendar: TodayDailySummarySection(
    kind: TodayDailySummaryKind.calendar,
    state: TodayDailySummaryState.stale,
    totalCount: 1,
    entries: [
      TodayDailySummaryEntry(sourceId: 'calendar.home', title: 'Dentist'),
    ],
  ),
  notifications: TodayDailySummarySection(
    kind: TodayDailySummaryKind.notifications,
    state: TodayDailySummaryState.offline,
  ),
);

Future<void> _mount(
  WidgetTester tester, {
  Size size = const Size(600, 900),
  double scale = 1,
  Locale locale = const Locale('en'),
  VoidCallback? onPressed,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    CupertinoApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: CupertinoPageScaffold(
        child: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(scale),
          ),
          child: Center(
            child: SizedBox(
              width: size.width,
              child: TodayDailySummaryCard(
                summary: _summary,
                onPressed: onPressed,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders four source states without false success', (
    tester,
  ) async {
    await _mount(tester);

    expect(find.text('Shopping'), findsOneWidget);
    expect(find.text('Chores'), findsOneWidget);
    expect(find.text('Calendar'), findsOneWidget);
    expect(find.text('Notifications'), findsOneWidget);
    expect(find.text('2 open'), findsOneWidget);
    expect(find.text('Nothing due'), findsOneWidget);
    expect(find.text('Saved view · 1'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);
    expect(find.text('0 open'), findsNothing);
  });

  testWidgets('fits 600 and 1280 widths at 2x text in EN and TR', (
    tester,
  ) async {
    for (final size in [const Size(600, 1200), const Size(1280, 900)]) {
      for (final locale in [const Locale('en'), const Locale('tr')]) {
        await _mount(tester, size: size, scale: 2, locale: locale);
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const ValueKey('today-daily-summary-card')),
          findsOneWidget,
        );
      }
    }
  });

  testWidgets('is one accessible 48dp keyboard action', (tester) async {
    var calls = 0;
    final semantics = tester.ensureSemantics();
    await _mount(tester, onPressed: () => calls++);
    final card = find.byKey(const ValueKey('today-daily-summary-card'));
    expect(tester.getSize(card).height, greaterThanOrEqualTo(48));
    expect(
      find.bySemanticsLabel(RegExp('Today.*Shopping.*2 open.*Offline')),
      findsOneWidget,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(calls, 1);
    semantics.dispose();
  });
}
