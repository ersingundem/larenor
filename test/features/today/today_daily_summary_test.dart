import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/today/domain/today_daily_summary.dart';
import 'package:larenor/features/today/domain/today_models.dart';

const _active = TodayTodoItem(
  uid: 'active',
  summary: 'Milk',
  status: TodayTodoStatus.needsAction,
);
const _done = TodayTodoItem(
  uid: 'done',
  summary: 'Bread',
  status: TodayTodoStatus.completed,
);
final _now = DateTime.utc(2026, 9, 11, 8);

TodayTodoList _list(
  String entityId,
  String title,
  TodayRead<List<TodayTodoItem>> items,
) => TodayTodoList(
  entityId: entityId,
  title: title,
  supportedFeatures: 5,
  available: true,
  items: items,
);

TodaySnapshot _snapshot({
  List<TodayTodoList> todoLists = const [],
  List<TodayCalendar> calendars = const [],
  TodayRead<List<TodayNotification>> notifications = const TodayRead(value: []),
  List<TodayIssue> issues = const [],
}) => TodaySnapshot(
  configured: true,
  refreshedAt: _now,
  todoLists: todoLists,
  calendars: calendars,
  notifications: notifications,
  issues: issues,
);

void main() {
  test(
    'separates canonical shopping lists from chores without guessing titles',
    () {
      final summary = TodayDailySummary.fromSnapshot(
        _snapshot(
          todoLists: [
            _list(
              'todo.shopping',
              'Market',
              TodayRead(value: const [_active, _done], readAt: _now),
            ),
            _list(
              'todo.home',
              'Shopping-looking custom title',
              TodayRead(value: const [_active], readAt: _now),
            ),
          ],
        ),
      );

      expect(summary.shopping.state, TodayDailySummaryState.current);
      expect(summary.shopping.totalCount, 1);
      expect(summary.shopping.entries.single.sourceId, 'todo.shopping');
      expect(summary.shopping.entries.single.itemId, 'active');
      expect(summary.chores.totalCount, 1);
      expect(summary.chores.entries.single.sourceId, 'todo.home');
      expect(summary.chores.entries.single.itemId, 'active');
    },
  );

  test(
    'does not turn unread or failed sources into successful zero counts',
    () {
      const denied = TodayIssue(
        TodaySource.todos,
        TodayFailure.permission,
        entityId: 'todo.shopping',
      );
      const offline = TodayIssue(
        TodaySource.notifications,
        TodayFailure.network,
      );
      final summary = TodayDailySummary.fromSnapshot(
        _snapshot(
          todoLists: [
            _list('todo.shopping', 'Shopping', const TodayRead(issue: denied)),
            _list('todo.home', 'Home', const TodayRead()),
          ],
          notifications: const TodayRead(issue: offline),
          issues: const [denied, offline],
        ),
      );

      expect(summary.shopping.state, TodayDailySummaryState.denied);
      expect(summary.shopping.totalCount, isNull);
      expect(summary.chores.state, TodayDailySummaryState.unread);
      expect(summary.chores.totalCount, isNull);
      expect(summary.notifications.state, TodayDailySummaryState.offline);
      expect(summary.notifications.totalCount, isNull);
    },
  );

  test('retains bounded preview data while marking stale calendar reads', () {
    const issue = TodayIssue(TodaySource.calendars, TodayFailure.timeout);
    final events = List.generate(
      5,
      (index) => TodayCalendarEvent(
        uid: '$index',
        title: 'Event $index',
        start: _now.add(Duration(hours: index)),
        end: _now.add(Duration(hours: index + 1)),
        allDay: false,
      ),
    );
    final summary = TodayDailySummary.fromSnapshot(
      _snapshot(
        calendars: [
          TodayCalendar(
            entityId: 'calendar.home',
            title: 'Home',
            events: TodayRead(value: events, issue: issue, readAt: _now),
          ),
        ],
        issues: const [issue],
      ),
      maxEntriesPerSection: 2,
    );

    expect(summary.calendar.state, TodayDailySummaryState.stale);
    expect(summary.calendar.totalCount, 5);
    expect(summary.calendar.entries, hasLength(2));
    expect(summary.calendar.entries.first.itemId, '0');
    expect(summary.calendar.readAt, _now);
  });

  test('keeps unidentified rows read-only while notifications stay stable', () {
    final summary = TodayDailySummary.fromSnapshot(
      _snapshot(
        todoLists: [
          _list(
            'todo.shopping',
            'Shopping',
            const TodayRead(
              value: [
                TodayTodoItem(
                  summary: 'Unidentified',
                  status: TodayTodoStatus.needsAction,
                ),
              ],
            ),
          ),
        ],
        calendars: [
          TodayCalendar(
            entityId: 'calendar.home',
            title: 'Home',
            events: TodayRead(
              value: [
                TodayCalendarEvent(
                  title: 'No UID',
                  start: _now,
                  end: _now,
                  allDay: false,
                ),
              ],
            ),
          ),
        ],
        notifications: TodayRead(
          value: [
            TodayNotification(
              id: 'notice-1',
              message: 'Door open',
              createdAt: _now,
            ),
          ],
        ),
      ),
    );

    expect(summary.shopping.entries.single.itemId, isNull);
    expect(summary.calendar.entries.single.itemId, isNull);
    expect(summary.notifications.entries.single.itemId, 'notice-1');
  });

  test('rejects unbounded preview requests', () {
    expect(
      () =>
          TodayDailySummary.fromSnapshot(_snapshot(), maxEntriesPerSection: 0),
      throwsArgumentError,
    );
    expect(
      () =>
          TodayDailySummary.fromSnapshot(_snapshot(), maxEntriesPerSection: 9),
      throwsArgumentError,
    );
  });
}
