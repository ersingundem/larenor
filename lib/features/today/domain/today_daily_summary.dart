import 'today_models.dart';

enum TodayDailySummaryKind { shopping, chores, calendar, notifications }

enum TodayDailySummaryState {
  unread,
  current,
  empty,
  partial,
  stale,
  offline,
  denied,
  unsupported,
  error,
}

class TodayDailySummaryEntry {
  const TodayDailySummaryEntry({
    required this.sourceId,
    required this.title,
    this.supportingText,
  });

  final String sourceId;
  final String title;
  final String? supportingText;
}

class TodayDailySummarySection {
  const TodayDailySummarySection({
    required this.kind,
    required this.state,
    this.totalCount,
    this.entries = const [],
    this.readAt,
  });

  final TodayDailySummaryKind kind;
  final TodayDailySummaryState state;

  /// Null means the source could not provide a complete count. It must never
  /// be displayed as zero.
  final int? totalCount;
  final List<TodayDailySummaryEntry> entries;
  final DateTime? readAt;
}

class TodayDailySummary {
  const TodayDailySummary({
    required this.shopping,
    required this.chores,
    required this.calendar,
    required this.notifications,
  });

  static const defaultShoppingListEntityIds = {
    'todo.shopping',
    'todo.shopping_list',
  };

  final TodayDailySummarySection shopping;
  final TodayDailySummarySection chores;
  final TodayDailySummarySection calendar;
  final TodayDailySummarySection notifications;

  List<TodayDailySummarySection> get sections => [
    shopping,
    chores,
    calendar,
    notifications,
  ];

  factory TodayDailySummary.fromSnapshot(
    TodaySnapshot snapshot, {
    int maxEntriesPerSection = 3,
    Set<String> shoppingListEntityIds = defaultShoppingListEntityIds,
  }) {
    if (maxEntriesPerSection < 1 || maxEntriesPerSection > 8) {
      throw ArgumentError.value(
        maxEntriesPerSection,
        'maxEntriesPerSection',
        'must be between 1 and 8',
      );
    }
    if (shoppingListEntityIds.length > 32 ||
        shoppingListEntityIds.any(
          (id) => !RegExp(r'^todo\.[a-z0-9_]+$').hasMatch(id),
        )) {
      throw ArgumentError.value(
        shoppingListEntityIds,
        'shoppingListEntityIds',
        'must contain at most 32 canonical todo entity IDs',
      );
    }

    final shoppingLists = snapshot.todoLists
        .where((list) => shoppingListEntityIds.contains(list.entityId))
        .toList(growable: false);
    final choreLists = snapshot.todoLists
        .where((list) => !shoppingListEntityIds.contains(list.entityId))
        .toList(growable: false);

    return TodayDailySummary(
      shopping: _todoSection(
        TodayDailySummaryKind.shopping,
        shoppingLists,
        snapshot.issues,
        maxEntriesPerSection,
      ),
      chores: _todoSection(
        TodayDailySummaryKind.chores,
        choreLists,
        snapshot.issues,
        maxEntriesPerSection,
      ),
      calendar: _calendarSection(
        snapshot.calendars,
        snapshot.issues,
        maxEntriesPerSection,
      ),
      notifications: _notificationSection(
        snapshot.notifications,
        maxEntriesPerSection,
      ),
    );
  }
}

TodayDailySummarySection _todoSection(
  TodayDailySummaryKind kind,
  List<TodayTodoList> lists,
  List<TodayIssue> issues,
  int limit,
) {
  if (lists.isEmpty) {
    final issue = _globalIssue(issues, TodaySource.todos);
    return TodayDailySummarySection(
      kind: kind,
      state: issue == null ? TodayDailySummaryState.empty : _failure(issue),
      totalCount: issue == null ? 0 : null,
    );
  }

  final reads = lists.map((list) => list.items).toList(growable: false);
  final entries = <TodayDailySummaryEntry>[];
  var knownCount = 0;
  for (final list in lists) {
    for (final item in list.items.value ?? const <TodayTodoItem>[]) {
      if (item.status != TodayTodoStatus.needsAction) continue;
      knownCount++;
      if (entries.length < limit) {
        entries.add(
          TodayDailySummaryEntry(
            sourceId: list.entityId,
            title: item.summary?.trim().isNotEmpty == true
                ? item.summary!.trim()
                : list.title,
          ),
        );
      }
    }
  }
  return _fromReads(
    kind: kind,
    reads: reads,
    entries: entries,
    knownCount: knownCount,
  );
}

TodayDailySummarySection _calendarSection(
  List<TodayCalendar> calendars,
  List<TodayIssue> issues,
  int limit,
) {
  if (calendars.isEmpty) {
    final issue = _globalIssue(issues, TodaySource.calendars);
    return TodayDailySummarySection(
      kind: TodayDailySummaryKind.calendar,
      state: issue == null ? TodayDailySummaryState.empty : _failure(issue),
      totalCount: issue == null ? 0 : null,
    );
  }
  final reads = calendars.map((calendar) => calendar.events).toList();
  final entries = <TodayDailySummaryEntry>[];
  var knownCount = 0;
  for (final calendar in calendars) {
    for (final event in calendar.events.value ?? const <TodayCalendarEvent>[]) {
      knownCount++;
      if (entries.length < limit) {
        entries.add(
          TodayDailySummaryEntry(
            sourceId: calendar.entityId,
            title: event.title,
            supportingText: event.start.toIso8601String(),
          ),
        );
      }
    }
  }
  return _fromReads(
    kind: TodayDailySummaryKind.calendar,
    reads: reads,
    entries: entries,
    knownCount: knownCount,
  );
}

TodayDailySummarySection _notificationSection(
  TodayRead<List<TodayNotification>> read,
  int limit,
) {
  final values = read.value;
  final entries = values
      ?.take(limit)
      .map(
        (item) => TodayDailySummaryEntry(
          sourceId: item.id,
          title: item.title?.trim().isNotEmpty == true
              ? item.title!.trim()
              : item.message,
          supportingText: item.createdAt.toIso8601String(),
        ),
      )
      .toList(growable: false);
  return _fromReads(
    kind: TodayDailySummaryKind.notifications,
    reads: [read],
    entries: entries ?? const [],
    knownCount: values?.length ?? 0,
  );
}

TodayDailySummarySection _fromReads<T>({
  required TodayDailySummaryKind kind,
  required List<TodayRead<T>> reads,
  required List<TodayDailySummaryEntry> entries,
  required int knownCount,
}) {
  final knownReads = reads.where((read) => read.value != null).length;
  final incomplete = knownReads != reads.length;
  final stale = reads.any((read) => read.isStale);
  final readAt = reads
      .map((read) => read.readAt)
      .whereType<DateTime>()
      .fold<DateTime?>(null, (oldest, value) {
        if (oldest == null || value.isBefore(oldest)) return value;
        return oldest;
      });

  TodayDailySummaryState state;
  if (stale) {
    state = TodayDailySummaryState.stale;
  } else if (incomplete && knownReads > 0) {
    state = TodayDailySummaryState.partial;
  } else if (incomplete) {
    final issue = reads
        .map((read) => read.issue)
        .whereType<TodayIssue>()
        .firstOrNull;
    state = issue == null ? TodayDailySummaryState.unread : _failure(issue);
  } else {
    state = knownCount == 0
        ? TodayDailySummaryState.empty
        : TodayDailySummaryState.current;
  }
  return TodayDailySummarySection(
    kind: kind,
    state: state,
    totalCount: incomplete ? null : knownCount,
    entries: List.unmodifiable(entries),
    readAt: readAt,
  );
}

TodayIssue? _globalIssue(List<TodayIssue> issues, TodaySource source) => issues
    .where((issue) => issue.source == source && issue.entityId == null)
    .firstOrNull;

TodayDailySummaryState _failure(TodayIssue issue) => switch (issue.failure) {
  TodayFailure.authentication ||
  TodayFailure.permission => TodayDailySummaryState.denied,
  TodayFailure.network ||
  TodayFailure.timeout ||
  TodayFailure.unavailable => TodayDailySummaryState.offline,
  TodayFailure.unsupported => TodayDailySummaryState.unsupported,
  TodayFailure.invalidResponse => TodayDailySummaryState.error,
};
