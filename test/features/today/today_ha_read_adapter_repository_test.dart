import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/ha_client/data/ha_api_exception.dart';
import 'package:larenor/features/today/data/today_controller.dart';
import 'package:larenor/features/today/data/today_repository.dart';
import 'package:larenor/features/today/domain/today_daily_summary.dart';
import 'package:larenor/features/today/domain/today_models.dart';

import 'fake_today_api.dart';

void main() {
  late FakeTodayApi api;
  late TodayRepository repository;
  final now = DateTime.utc(2026, 9, 11, 9);

  setUp(() {
    api = FakeTodayApi();
    repository = TodayRepository(api: api, now: () => now);
  });
  tearDown(() => repository.dispose());

  test(
    'unsupported adapters are not probed and never look successfully empty',
    () async {
      api.components = ['todo'];

      final snapshot = await repository.load();
      final summary = TodayDailySummary.fromSnapshot(snapshot);

      expect(api.entitiesCalls, 1);
      expect(api.legacyShoppingCalls, 0);
      expect(api.calendarIndexCalls, 0);
      expect(api.notificationCalls, 0);
      expect(summary.calendar.state, TodayDailySummaryState.unsupported);
      expect(summary.calendar.totalCount, isNull);
      expect(summary.notifications.state, TodayDailySummaryState.unsupported);
      expect(api.serviceCalls, isEmpty);
    },
  );

  test(
    'legacy shopping_list is normalized only when no todo adapter is present',
    () async {
      api.components = ['shopping_list', 'calendar', 'persistent_notification'];
      api.legacyShoppingItems = [
        {'id': 'one', 'name': 'Milk', 'complete': false},
        {'id': 'two', 'name': 'Bread', 'complete': true},
      ];

      final snapshot = await repository.load();
      final list = snapshot.todoLists.single;
      final summary = TodayDailySummary.fromSnapshot(snapshot);

      expect(api.entitiesCalls, 0);
      expect(api.legacyShoppingCalls, 1);
      expect(api.itemCalls, isEmpty);
      expect(list.entityId, 'todo.shopping_list');
      expect(list.supportedFeatures, 0);
      expect(list.canAdd, isFalse);
      expect(list.canUpdate, isFalse);
      expect(summary.shopping.totalCount, 1);
      expect(api.serviceCalls, isEmpty);
    },
  );

  test(
    'unsupported persistent notifications do not start a subscription probe',
    () async {
      api.components = ['todo'];
      final controller = TodayController(repository: repository);
      addTearDown(controller.dispose);

      controller.setConnected(true);
      await controller.refresh();
      await drain();

      expect(api.subscriptions, isEmpty);
      expect(api.notificationCalls, 0);
      expect(api.serviceCalls, isEmpty);
    },
  );

  test(
    'capability removal closes an existing notification subscription',
    () async {
      final controller = TodayController(repository: repository);
      addTearDown(controller.dispose);
      controller.setConnected(true);
      await controller.refresh();
      await drain();
      expect(api.subscriptions, hasLength(1));

      api.components = ['todo', 'calendar'];
      await controller.refresh();
      await drain();

      expect(api.cancelled, 1);
      expect(
        controller.snapshot!.notifications.issue!.failure,
        TodayFailure.unsupported,
      );
      expect(api.serviceCalls, isEmpty);
    },
  );

  test(
    'capability permission loss retains old values but starts no adapter reads',
    () async {
      final before = await repository.load();
      final entitiesCalls = api.entitiesCalls;
      final calendarCalls = api.calendarIndexCalls;
      final notificationCalls = api.notificationCalls;
      api.componentsError = HaApiException('Fixture', statusCode: 403);

      final after = await repository.load(previous: before);
      final summary = TodayDailySummary.fromSnapshot(after);

      expect(api.entitiesCalls, entitiesCalls);
      expect(api.calendarIndexCalls, calendarCalls);
      expect(api.notificationCalls, notificationCalls);
      expect(api.legacyShoppingCalls, 0);
      expect(summary.shopping.state, TodayDailySummaryState.stale);
      expect(summary.calendar.state, TodayDailySummaryState.stale);
      expect(summary.notifications.state, TodayDailySummaryState.stale);
      expect(
        after.issues
            .where((issue) => issue.failure == TodayFailure.permission)
            .map((issue) => issue.source)
            .toSet(),
        {
          TodaySource.shopping,
          TodaySource.todos,
          TodaySource.calendars,
          TodaySource.notifications,
        },
      );
      expect(api.serviceCalls, isEmpty);
    },
  );

  test('malformed discovery starts no downstream reads', () async {
    api.components = ['todo', 'todo'];

    final snapshot = await repository.load();

    expect(api.entitiesCalls, 0);
    expect(api.legacyShoppingCalls, 0);
    expect(api.calendarIndexCalls, 0);
    expect(api.notificationCalls, 0);
    expect(snapshot.issues.map((issue) => issue.failure).toSet(), {
      TodayFailure.invalidResponse,
    });
    expect(api.serviceCalls, isEmpty);
  });

  test(
    'one denied calendar keeps known events but makes the count partial',
    () async {
      api.calendars = [
        {'entity_id': 'calendar.family', 'name': 'Family'},
        {'entity_id': 'calendar.private', 'name': 'Private'},
      ];
      api.events['calendar.family'] = [
        calendarEvent(from: '2026-09-11', until: '2026-09-12'),
      ];
      api.calendarErrors['calendar.private'] = HaApiException(
        'Fixture',
        statusCode: 403,
      );

      final snapshot = await repository.load();
      final calendar = TodayDailySummary.fromSnapshot(snapshot).calendar;

      expect(calendar.state, TodayDailySummaryState.partial);
      expect(calendar.totalCount, isNull);
      expect(calendar.entries.single.sourceId, 'calendar.family');
      expect(
        snapshot.issues.any(
          (issue) =>
              issue.entityId == 'calendar.private' &&
              issue.failure == TodayFailure.permission,
        ),
        isTrue,
      );
      expect(api.serviceCalls, isEmpty);
    },
  );
}
