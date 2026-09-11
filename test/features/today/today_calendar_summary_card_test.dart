import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/today/domain/today_calendar_summary.dart';
import 'package:larenor/features/today/domain/today_models.dart';
import 'package:larenor/features/today/presentation/today_calendar_summary_card.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

TodayCalendarSummary _summary() => TodayCalendarSummary(
  allDay: [
    TodayCalendarSummaryEntry(
      sourceId: 'calendar.family',
      sourceTitle: 'Family',
      event: TodayCalendarEvent(
        uid: 'holiday',
        title: 'Day off',
        start: DateTime.utc(2026, 9, 11),
        end: DateTime.utc(2026, 9, 12),
        allDay: true,
        startDate: '2026-09-11',
        endDate: '2026-09-12',
      ),
      phase: TodayCalendarPhase.current,
      stale: true,
    ),
  ],
  timed: [
    TodayCalendarSummaryEntry(
      sourceId: 'calendar.family',
      sourceTitle: 'Family',
      event: TodayCalendarEvent(
        uid: 'dentist',
        title: 'Dentist',
        start: DateTime.parse('2026-09-11T14:00:00+03:00'),
        end: DateTime.parse('2026-09-11T15:00:00+03:00'),
        allDay: false,
      ),
      phase: TodayCalendarPhase.upcoming,
      stale: true,
    ),
  ],
  staleSources: const [
    TodayCalendarSourceEvidence(
      sourceId: 'calendar.family',
      sourceTitle: 'Family',
      failure: TodayFailure.timeout,
    ),
  ],
  unavailableSources: const [
    TodayCalendarSourceEvidence(
      sourceId: 'calendar.work',
      sourceTitle: 'Work',
      failure: TodayFailure.permission,
    ),
  ],
);

Future<void> _mount(
  WidgetTester tester, {
  required Size size,
  String query = '',
  String? selectedItemId,
  ValueChanged<String>? onQueryChanged,
  ValueChanged<TodayCalendarSummaryEntry>? onSelected,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    CupertinoApp(
      locale: const Locale('tr'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: const TextScaler.linear(2),
        ),
        child: CupertinoPageScaffold(
          child: SingleChildScrollView(
            child: TodayCalendarSummaryCard(
              summary: _summary(),
              query: query,
              selectedSourceId: 'calendar.family',
              selectedItemId: selectedItemId,
              onQueryChanged: onQueryChanged,
              onItemSelected: onSelected,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final size in [const Size(600, 900), const Size(1280, 900)]) {
    testWidgets('shows temporal and source evidence at ${size.width}px 2x', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await _mount(tester, size: size, selectedItemId: 'dentist');

      expect(find.text('Tüm gün etkinlikleri'), findsOneWidget);
      expect(find.text('Saatli etkinlikler'), findsOneWidget);
      expect(find.text('Şu anda sürüyor'), findsOneWidget);
      expect(find.text('Yaklaşan'), findsOneWidget);
      expect(find.text('Kayıtlı kaynak: Family'), findsOneWidget);
      expect(find.text('Erişilemeyen kaynak: Work'), findsOneWidget);
      expect(
        tester
            .getSemantics(
              find.byKey(
                const ValueKey('today-calendar-event-calendar.family-dentist'),
              ),
            )
            .flagsCollection
            .isSelected,
        ui.Tristate.isTrue,
      );
      expect(find.byKey(const ValueKey('today-calendar-create')), findsNothing);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });
  }

  testWidgets('keeps the retained filter and supports keyboard selection', (
    tester,
  ) async {
    final changes = <String>[];
    final selected = <TodayCalendarSummaryEntry>[];
    await _mount(
      tester,
      size: const Size(1280, 900),
      query: 'dentist',
      onQueryChanged: changes.add,
      onSelected: selected.add,
    );

    expect(find.text('Dentist'), findsOneWidget);
    expect(find.text('Day off'), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('today-calendar-search')),
      'day',
    );
    expect(changes.last, 'day');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(selected.single.event.uid, 'holiday');
  });
}
