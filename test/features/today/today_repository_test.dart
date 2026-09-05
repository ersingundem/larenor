import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/ha_client/data/ha_api_exception.dart';
import 'package:larenor/features/today/data/today_repository.dart';
import 'package:larenor/features/today/data/today_timezone.dart';
import 'package:larenor/features/today/domain/today_models.dart';

import 'fake_today_api.dart';

void main() {
  late FakeTodayApi api;
  late TodayRepository repository;
  var now = DateTime.utc(2026, 9, 5, 12);
  setUp(() {
    api = FakeTodayApi();
    repository = TodayRepository(api: api, now: () => now);
  });
  tearDown(() => repository.dispose());

  test(
    'explicit HA UTC alias reads calendars with UTC midnight boundaries',
    () async {
      api.config = {'time_zone': 'UTC'};
      api.events['calendar.family'] = [
        calendarEvent(from: '2026-09-05', until: '2026-09-06'),
      ];
      final snapshot = await repository.load();
      expect(snapshot.timeZone, 'Etc/UTC');
      expect(
        snapshot.dayStart!.isAtSameMomentAs(DateTime.utc(2026, 9, 5)),
        isTrue,
      );
      expect(
        snapshot.dayEnd!.isAtSameMomentAs(DateTime.utc(2026, 9, 6)),
        isTrue,
      );
      expect(
        api.calendarCalls.single.start.isAtSameMomentAs(
          DateTime.utc(2026, 9, 5),
        ),
        isTrue,
      );
      expect(snapshot.calendars.single.events.value, hasLength(1));
      expect(
        () => TodayTimeZone('Invalid/Fixture'),
        throwsA(isA<TodayException>()),
      );
      expect(api.serviceCalls, isEmpty);
    },
  );

  test(
    'HA day uses its timezone, DST calendar day and exclusive all-day end',
    () async {
      final spring = TodayTimeZone('Europe/Berlin')
          .dayRange(DateTime.utc(2026, 3, 29, 12));
      final autumn = TodayTimeZone('Europe/Berlin')
          .dayRange(DateTime.utc(2026, 10, 25, 12));
      expect(spring.end.difference(spring.start), const Duration(hours: 23));
      expect(autumn.end.difference(autumn.start), const Duration(hours: 25));
      api.events['calendar.family'] = [
        calendarEvent(from: '2026-09-04', until: '2026-09-05'),
        calendarEvent(from: '2026-09-04', until: '2026-09-06'),
        calendarEvent(from: '2026-09-06', until: '2026-09-07'),
        calendarEvent(
          from: '2026-09-04T22:00:00Z',
          until: '2026-09-04T23:00:00Z',
          allDay: false,
        ),
      ];
      final snapshot = await repository.load();
      expect(snapshot.timeZone, 'Europe/Istanbul');
      expect(snapshot.dayStart!.toUtc(), DateTime.utc(2026, 9, 4, 21));
      expect(snapshot.dayEnd!.toUtc(), DateTime.utc(2026, 9, 5, 21));
      final events = snapshot.calendars.single.events.value!;
      expect(events, hasLength(2));
      expect(events.first.endDate, '2026-09-06');
      expect(events.last.start.hour, 1);
      expect(events.last.start.day, 5);
      expect(api.serviceCalls, isEmpty);
    },
  );

  test(
    'invalid dates, missing offsets and mixed calendar times are rejected',
    () {
      for (final date in [
        '2026-02-30',
        '0000-01-01',
        '2026-13-01',
        '2026-9-5',
      ]) {
        expect(() => parseDateOnly(date), throwsA(isA<TodayException>()));
      }
      for (final date in [
        '2026-02-30T01:00:00Z',
        '2026-09-05T24:00:00Z',
        '2026-09-05T01:00:00',
        '2026-09-05T01:00:00+25:00',
      ]) {
        expect(() => parseTimestamp(date), throwsA(isA<TodayException>()));
      }
      expect(
        parseTimestamp('2026-09-05T13:00:00+03:00'),
        DateTime.utc(2026, 9, 5, 10),
      );
      expect(
        () => parseCalendarEvents([
          {
            'summary': 'x',
            'start': {'date': '2026-09-05'},
            'end': {'dateTime': '2026-09-06T00:00:00Z'},
          },
        ], TodayTimeZone('UTC')),
        throwsA(isA<TodayException>()),
      );
    },
  );

  test('partial 401, 403 and timeout failures do not turn unknown reads into empty lists', () async {
    api.entities.add(todoEntity('todo.second'));
    api.itemErrors['todo.shopping'] = HaApiException(
      'Fixture',
      statusCode: 401,
    );
    api.calendarErrors['calendar.family'] = HaApiException(
      'Fixture',
      statusCode: 403,
    );
    api.notificationsError = TimeoutException('Fixture');
    final result = await repository.load();
    expect(result.todoLists.first.items.value, isNull);
    expect(
      result.todoLists.first.items.issue!.failure,
      TodayFailure.authentication,
    );
    expect(result.todoLists.last.items.value, isEmpty);
    expect(result.todoLists.last.items.issue, isNull);
    expect(result.calendars.single.events.value, isNull);
    expect(
      result.calendars.single.events.issue!.failure,
      TodayFailure.permission,
    );
    expect(result.notifications.value, isNull);
    expect(result.notifications.issue!.failure, TodayFailure.timeout);
  });

  test('failed refresh keeps useful old data and timestamp, recovery clears issues', () async {
    final before = await repository.load();
    now = now.add(const Duration(minutes: 1));
    api.itemErrors['todo.shopping'] = TimeoutException('Fixture');
    api.calendars = [
      {'entity_id': 'bad', 'name': 'Malformed response'},
    ];
    api.notificationsError = HaApiException('Fixture', code: 'unknown_command');
    final failed = await repository.load(previous: before);
    expect(failed.todoLists.single.items.value!.single.summary, 'Milk');
    expect(
      failed.todoLists.single.items.readAt,
      before.todoLists.single.items.readAt,
    );
    expect(failed.todoLists.single.items.isStale, isTrue);
    expect(failed.calendars.single.events.value, hasLength(1));
    expect(failed.calendars.single.events.isStale, isTrue);
    expect(failed.notifications.value, hasLength(1));
    expect(failed.notifications.issue!.failure, TodayFailure.unsupported);
    api.itemErrors.clear();
    api.calendars = [
      {'entity_id': 'calendar.family'},
    ];
    api.notificationsError = null;
    expect((await repository.load(previous: failed)).issues, isEmpty);
  });

  test(
    'unknown HA timezone never silently queries using phone timezone',
    () async {
      api.config = {'time_zone': 'Invented/Zone'};
      final result = await repository.load();
      expect(result.dayStart, isNull);
      expect(result.timeZone, isNull);
      expect(api.calendarCalls, isEmpty);
      expect(result.todoLists.single.items.value, hasLength(1));
      expect(
        result.issues.map((issue) => issue.source),
        contains(TodaySource.configuration),
      );
    },
  );

  test(
    'todo UID and capability data preserve read-only missing UID items',
    () async {
      api.items['todo.shopping'] = {
        'items': [
          todoItem(uid: null),
          {
            ...todoItem(uid: 'two'),
            'status': 'future_status',
            'due': '2026-09-06',
          },
        ],
      };
      final list = (await repository.load()).todoLists.single;
      expect(list.canAdd, isTrue);
      expect(list.canUpdate, isTrue);
      expect(list.canSetDueDate, isTrue);
      expect(list.canSetDueTime, isTrue);
      expect(list.items.value!.first.canIdentify, isFalse);
      expect(list.items.value!.last.status, TodayTodoStatus.unknown);
      expect(list.items.value!.last.dueDate, '2026-09-06');
      expect(
        () => parseTodoItems({
          'items': [todoItem(), todoItem()],
        }),
        throwsA(isA<TodayException>()),
      );
    },
  );

  test('unavailable and failed entity catalog retain items but disable mutation capabilities', () async {
    final before = await repository.load();
    api.entities = [todoEntity('todo.shopping', state: 'unavailable')];
    final unavailable = await repository.load(previous: before);
    expect(unavailable.todoLists.single.canAdd, isFalse);
    expect(unavailable.todoLists.single.items.isStale, isTrue);
    api.entitiesError = HaApiException('Fixture', code: 'connection_error');
    final disconnected = await repository.load(previous: before);
    expect(disconnected.todoLists.single.items.value, hasLength(1));
    expect(disconnected.todoLists.single.available, isFalse);
    expect(
      disconnected.todoLists.single.items.issue!.failure,
      TodayFailure.network,
    );
  });

  test('per-entity reads are bounded to four and disposal starts no further requests', () async {
    api.entities = [for (var i = 0; i < 12; i++) todoEntity('todo.list_$i')];
    final release = Completer<void>();
    api.beforeItems = (_) => release.future;
    final result = repository.load();
    final check = expectLater(result, throwsA(isA<TodayException>()));
    await drain();
    expect(api.itemCalls, hasLength(4));
    repository.dispose();
    release.complete();
    await check;
    expect(api.itemCalls, hasLength(4));
  });

  test(
    'bounded schemas reject duplicate notifications and oversized collections',
    () {
      expect(
        () => parseNotifications([notification(), notification()]),
        throwsA(isA<TodayException>()),
      );
      expect(
        () => parseTodoItems({'items': List.filled(5001, todoItem())}),
        throwsA(isA<TodayException>()),
      );
      expect(
        () => parseNotifications({'notice': notification()}),
        throwsA(isA<TodayException>()),
      );
    },
  );
}
