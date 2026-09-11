import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/today/domain/today_daily_summary.dart';
import 'package:larenor/features/today/domain/today_models.dart';
import 'package:larenor/features/today/providers/today_providers.dart';

TodayDailySummary _summary(List<TodayDailySummaryEntry> shopping) =>
    TodayDailySummary(
      shopping: TodayDailySummarySection(
        kind: TodayDailySummaryKind.shopping,
        state: TodayDailySummaryState.current,
        entries: shopping,
      ),
      chores: const TodayDailySummarySection(
        kind: TodayDailySummaryKind.chores,
        state: TodayDailySummaryState.empty,
      ),
      calendar: const TodayDailySummarySection(
        kind: TodayDailySummaryKind.calendar,
        state: TodayDailySummaryState.empty,
      ),
      notifications: const TodayDailySummarySection(
        kind: TodayDailySummaryKind.notifications,
        state: TodayDailySummaryState.empty,
      ),
    );

void main() {
  test('keeps section queries and reconciles item identity after refresh', () {
    final container = ProviderContainer(
      overrides: [todayRetainedScopeProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(
      todaySummarySelectionProvider,
      (_, _) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    final controller = container.read(todaySummarySelectionProvider.notifier);

    controller.select(
      TodayDailySummaryKind.shopping,
      sourceId: 'todo.shopping',
    );
    controller.updateQuery('milk');
    controller.selectItem(sourceId: 'todo.shopping', itemId: 'uid-1');
    controller.reconcile(
      _summary(const [
        TodayDailySummaryEntry(
          sourceId: 'todo.shopping',
          itemId: 'uid-1',
          title: 'Milk',
        ),
      ]),
    );
    expect(container.read(todaySummarySelectionProvider)?.itemId, 'uid-1');
    controller.reconcileSnapshot(
      TodaySnapshot(
        configured: true,
        refreshedAt: DateTime.utc(2026, 9, 11),
        todoLists: const [
          TodayTodoList(
            entityId: 'todo.shopping',
            title: 'Shopping',
            supportedFeatures: 0,
            available: true,
            items: TodayRead(
              value: [
                TodayTodoItem(
                  uid: 'uid-1',
                  summary: 'Milk',
                  status: TodayTodoStatus.needsAction,
                ),
              ],
            ),
          ),
        ],
      ),
    );
    expect(container.read(todaySummarySelectionProvider)?.itemId, 'uid-1');

    controller.select(TodayDailySummaryKind.calendar);
    controller.updateQuery('dentist');
    controller.select(TodayDailySummaryKind.shopping);
    expect(container.read(todaySummarySelectionProvider)?.query, 'milk');

    controller.selectItem(sourceId: 'todo.shopping', itemId: 'uid-1');
    controller.reconcileSnapshot(
      TodaySnapshot(
        configured: true,
        refreshedAt: DateTime.utc(2026, 9, 11, 1),
      ),
    );
    final fallback = container.read(todaySummarySelectionProvider)!;
    expect(fallback.kind, TodayDailySummaryKind.shopping);
    expect(fallback.sourceId, isNull);
    expect(fallback.itemId, isNull);
    expect(fallback.query, 'milk');
  });

  test(
    'invalid query and identity fail closed without replacing selection',
    () {
      final container = ProviderContainer(
        overrides: [todayRetainedScopeProvider.overrideWithValue(null)],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        todaySummarySelectionProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      final controller = container.read(todaySummarySelectionProvider.notifier)
        ..select(TodayDailySummaryKind.shopping);

      expect(
        () => controller.updateQuery(List.filled(129, 'x').join()),
        throwsA(isA<Exception>()),
      );
      expect(
        () => controller.selectItem(sourceId: 'todo.shopping', itemId: 'bad\n'),
        throwsA(isA<Exception>()),
      );
      final selection = container.read(todaySummarySelectionProvider)!;
      expect(selection.kind, TodayDailySummaryKind.shopping);
      expect(selection.query, isEmpty);
      expect(selection.itemId, isNull);
    },
  );
}
