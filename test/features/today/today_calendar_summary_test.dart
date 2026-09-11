import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/today/data/today_timezone.dart';
import 'package:larenor/features/today/domain/today_calendar_summary.dart';
import 'package:larenor/features/today/domain/today_models.dart';

TodayCalendarEvent _timed(String uid, String title, String start, String end) =>
    TodayCalendarEvent(
      uid: uid,
      title: title,
      start: DateTime.parse(start),
      end: DateTime.parse(end),
      allDay: false,
    );

TodayCalendarEvent _allDay(String uid, String title, String day) {
  final zone = TodayTimeZone('Europe/Berlin');
  final start = zone.date(day);
  final date = DateTime.parse('${day}T00:00:00Z').add(const Duration(days: 1));
  final endDay = date.toIso8601String().substring(0, 10);
  return TodayCalendarEvent(
    uid: uid,
    title: title,
    start: start,
    end: zone.date(endDay),
    allDay: true,
    startDate: day,
    endDate: endDay,
  );
}

TodayCalendar _calendar(
  String id,
  String title,
  TodayRead<List<TodayCalendarEvent>> events,
) => TodayCalendar(entityId: id, title: title, events: events);

void main() {
  test('separates and safely orders all-day and DST-overlap timed events', () {
    final agenda = TodayCalendarSummary.fromSnapshot(
      TodaySnapshot(
        configured: true,
        refreshedAt: DateTime.parse('2026-10-25T00:45:00Z'),
        timeZone: 'Europe/Berlin',
        calendars: [
          _calendar(
            'calendar.family',
            'Family',
            TodayRead(
              value: [
                _timed(
                  'late-overlap',
                  'Second 02:30',
                  '2026-10-25T02:30:00+01:00',
                  '2026-10-25T03:00:00+01:00',
                ),
                _allDay('holiday-2', 'Monday holiday', '2026-10-26'),
                _timed(
                  'early-overlap',
                  'First 02:30',
                  '2026-10-25T02:30:00+02:00',
                  '2026-10-25T03:00:00+02:00',
                ),
                _allDay('holiday-1', 'Sunday holiday', '2026-10-25'),
              ],
            ),
          ),
        ],
      ),
      now: DateTime.parse('2026-10-25T00:45:00Z'),
    );

    expect(agenda.allDay.map((entry) => entry.event.uid), [
      'holiday-1',
      'holiday-2',
    ]);
    expect(agenda.timed.map((entry) => entry.event.uid), [
      'early-overlap',
      'late-overlap',
    ]);
    expect(agenda.allDay.first.phase, TodayCalendarPhase.current);
    expect(agenda.allDay.last.phase, TodayCalendarPhase.upcoming);
    expect(agenda.timed.first.phase, TodayCalendarPhase.current);
    expect(agenda.timed.last.phase, TodayCalendarPhase.upcoming);
  });

  test('classifies past current and upcoming by exact instant', () {
    final agenda = TodayCalendarSummary.fromSnapshot(
      TodaySnapshot(
        configured: true,
        refreshedAt: DateTime.parse('2026-09-11T10:00:00Z'),
        timeZone: 'Europe/Istanbul',
        calendars: [
          _calendar(
            'calendar.family',
            'Family',
            TodayRead(
              value: [
                _timed(
                  'upcoming',
                  'Lunch',
                  '2026-09-11T14:00:00+03:00',
                  '2026-09-11T15:00:00+03:00',
                ),
                _timed(
                  'past',
                  'Breakfast',
                  '2026-09-11T08:00:00+03:00',
                  '2026-09-11T09:00:00+03:00',
                ),
                _timed(
                  'current',
                  'Stand-up',
                  '2026-09-11T12:30:00+03:00',
                  '2026-09-11T13:30:00+03:00',
                ),
              ],
            ),
          ),
        ],
      ),
      now: DateTime.parse('2026-09-11T10:00:00Z'),
    );

    expect(agenda.timed.map((entry) => entry.phase), [
      TodayCalendarPhase.past,
      TodayCalendarPhase.current,
      TodayCalendarPhase.upcoming,
    ]);
  });

  test('keeps stale and unavailable source evidence separate', () {
    final agenda = TodayCalendarSummary.fromSnapshot(
      TodaySnapshot(
        configured: true,
        retained: true,
        refreshedAt: DateTime.utc(2026, 9, 11, 10),
        timeZone: 'Europe/Istanbul',
        calendars: [
          _calendar(
            'calendar.saved',
            'Saved',
            TodayRead(
              value: [
                _timed(
                  'saved-event',
                  'Saved event',
                  '2026-09-11T13:00:00+03:00',
                  '2026-09-11T14:00:00+03:00',
                ),
              ],
              issue: const TodayIssue(
                TodaySource.calendars,
                TodayFailure.timeout,
                entityId: 'calendar.saved',
              ),
            ),
          ),
          _calendar(
            'calendar.denied',
            'Private',
            const TodayRead(
              issue: TodayIssue(
                TodaySource.calendars,
                TodayFailure.permission,
                entityId: 'calendar.denied',
              ),
            ),
          ),
        ],
      ),
      now: DateTime.utc(2026, 9, 11, 10),
    );

    expect(agenda.timed.single.stale, isTrue);
    expect(agenda.staleSources.single.sourceId, 'calendar.saved');
    expect(agenda.unavailableSources.single.sourceId, 'calendar.denied');
    expect(agenda.unavailableSources.single.failure, TodayFailure.permission);
  });

  test('invalid all-day date evidence fails the source closed', () {
    final agenda = TodayCalendarSummary.fromSnapshot(
      TodaySnapshot(
        configured: true,
        refreshedAt: DateTime.utc(2026, 9, 11),
        timeZone: 'Europe/Istanbul',
        calendars: [
          _calendar(
            'calendar.bad',
            'Bad source',
            TodayRead(
              value: [
                TodayCalendarEvent(
                  uid: 'day',
                  title: 'Day',
                  start: DateTime.utc(2026, 9, 11),
                  end: DateTime.utc(2026, 9, 12),
                  allDay: true,
                ),
              ],
            ),
          ),
        ],
      ),
      now: DateTime.utc(2026, 9, 11),
    );

    expect(agenda.allDay, isEmpty);
    expect(agenda.timed, isEmpty);
    expect(
      agenda.unavailableSources.single.failure,
      TodayFailure.invalidResponse,
    );
  });

  test('global calendar read failure is unavailable rather than empty', () {
    final agenda = TodayCalendarSummary.fromSnapshot(
      TodaySnapshot(
        configured: true,
        refreshedAt: DateTime.utc(2026, 9, 11),
        timeZone: 'Europe/Istanbul',
        issues: const [TodayIssue(TodaySource.calendars, TodayFailure.network)],
      ),
      now: DateTime.utc(2026, 9, 11),
    );

    expect(agenda.allDay, isEmpty);
    expect(agenda.timed, isEmpty);
    expect(agenda.unavailableSources.single.failure, TodayFailure.network);
  });
}
