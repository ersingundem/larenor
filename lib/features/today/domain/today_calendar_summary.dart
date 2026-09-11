import 'today_models.dart';

enum TodayCalendarPhase { past, current, upcoming }

class TodayCalendarSummaryEntry {
  const TodayCalendarSummaryEntry({
    required this.sourceId,
    required this.sourceTitle,
    required this.event,
    required this.phase,
    required this.stale,
  });

  final String sourceId;
  final String sourceTitle;
  final TodayCalendarEvent event;
  final TodayCalendarPhase phase;
  final bool stale;
}

class TodayCalendarSourceEvidence {
  const TodayCalendarSourceEvidence({
    required this.sourceId,
    required this.sourceTitle,
    required this.failure,
  });

  final String sourceId;
  final String sourceTitle;
  final TodayFailure failure;
}

/// A bounded, read-only calendar projection. All-day dates are evaluated in
/// the Home Assistant timezone; timed events are compared by exact instant.
class TodayCalendarSummary {
  const TodayCalendarSummary({
    this.allDay = const [],
    this.timed = const [],
    this.staleSources = const [],
    this.unavailableSources = const [],
  });

  static const maximumEventsPerGroup = 16;
  static const maximumEvidence = 16;

  final List<TodayCalendarSummaryEntry> allDay;
  final List<TodayCalendarSummaryEntry> timed;
  final List<TodayCalendarSourceEvidence> staleSources;
  final List<TodayCalendarSourceEvidence> unavailableSources;

  factory TodayCalendarSummary.fromSnapshot(
    TodaySnapshot snapshot, {
    required DateTime now,
    int maximumPerGroup = maximumEventsPerGroup,
  }) {
    if (maximumPerGroup < 1 || maximumPerGroup > maximumEventsPerGroup) {
      throw ArgumentError.value(maximumPerGroup, 'maximumPerGroup');
    }
    final allDay = <TodayCalendarSummaryEntry>[];
    final timed = <TodayCalendarSummaryEntry>[];
    final stale = <TodayCalendarSourceEvidence>[];
    final unavailable = <TodayCalendarSourceEvidence>[];
    if (snapshot.calendars.isEmpty) {
      final global = snapshot.issues
          .where(
            (issue) =>
                issue.source == TodaySource.calendars && issue.entityId == null,
          )
          .firstOrNull;
      if (global != null) {
        unavailable.add(
          TodayCalendarSourceEvidence(
            sourceId: 'calendar',
            sourceTitle: '',
            failure: global.failure,
          ),
        );
      }
    }
    for (final calendar in snapshot.calendars) {
      final values = calendar.events.value;
      if (values == null) {
        _addEvidence(
          unavailable,
          calendar,
          calendar.events.issue?.failure ?? TodayFailure.unavailable,
        );
        continue;
      }
      if (!_validEvents(values)) {
        _addEvidence(unavailable, calendar, TodayFailure.invalidResponse);
        continue;
      }
      final isStale = snapshot.retained || calendar.events.isStale;
      if (isStale) {
        _addEvidence(
          stale,
          calendar,
          calendar.events.issue?.failure ?? TodayFailure.unavailable,
        );
      }
      for (final event in values) {
        final entry = TodayCalendarSummaryEntry(
          sourceId: calendar.entityId,
          sourceTitle: calendar.title,
          event: event,
          phase: _eventPhase(event, now),
          stale: isStale,
        );
        if (event.allDay) {
          _addBounded(allDay, entry, maximumPerGroup, _compareAllDay);
        } else {
          _addBounded(timed, entry, maximumPerGroup, _compareTimed);
        }
      }
    }

    allDay.sort(_compareAllDay);
    timed.sort(_compareTimed);
    return TodayCalendarSummary(
      allDay: List.unmodifiable(allDay),
      timed: List.unmodifiable(timed),
      staleSources: List.unmodifiable(stale.take(maximumEvidence)),
      unavailableSources: List.unmodifiable(unavailable.take(maximumEvidence)),
    );
  }
}

bool _validEvents(List<TodayCalendarEvent> events) {
  for (final event in events) {
    if (!event.end.isAfter(event.start)) return false;
    if (!event.allDay) continue;
    if (event.startDate == null || event.endDate == null) {
      return false;
    }
    final start = _dateOnly(event.startDate!);
    final end = _dateOnly(event.endDate!);
    if (start == null || end == null || !end.isAfter(start)) return false;
  }
  return true;
}

TodayCalendarPhase _eventPhase(TodayCalendarEvent event, DateTime now) {
  if (!event.end.isAfter(now)) return TodayCalendarPhase.past;
  if (event.start.isAfter(now)) return TodayCalendarPhase.upcoming;
  return TodayCalendarPhase.current;
}

DateTime? _dateOnly(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return null;
  final parsed = DateTime.tryParse(value);
  if (parsed == null || parsed.toIso8601String().substring(0, 10) != value) {
    return null;
  }
  return parsed;
}

int _compareAllDay(
  TodayCalendarSummaryEntry left,
  TodayCalendarSummaryEntry right,
) {
  final start = left.event.startDate!.compareTo(right.event.startDate!);
  return start != 0 ? start : _tieBreak(left, right);
}

int _compareTimed(
  TodayCalendarSummaryEntry left,
  TodayCalendarSummaryEntry right,
) {
  final start = left.event.start.compareTo(right.event.start);
  return start != 0 ? start : _tieBreak(left, right);
}

int _tieBreak(TodayCalendarSummaryEntry left, TodayCalendarSummaryEntry right) {
  final source = left.sourceId.compareTo(right.sourceId);
  if (source != 0) return source;
  final uid = (left.event.uid ?? '').compareTo(right.event.uid ?? '');
  return uid != 0 ? uid : left.event.title.compareTo(right.event.title);
}

void _addEvidence(
  List<TodayCalendarSourceEvidence> target,
  TodayCalendar calendar,
  TodayFailure failure,
) {
  if (target.length >= TodayCalendarSummary.maximumEvidence) return;
  target.add(
    TodayCalendarSourceEvidence(
      sourceId: calendar.entityId,
      sourceTitle: calendar.title,
      failure: failure,
    ),
  );
}

void _addBounded(
  List<TodayCalendarSummaryEntry> target,
  TodayCalendarSummaryEntry value,
  int maximum,
  int Function(TodayCalendarSummaryEntry, TodayCalendarSummaryEntry) compare,
) {
  target.add(value);
  target.sort(compare);
  if (target.length > maximum) target.removeLast();
}
