enum TodaySource { configuration, todos, calendars, notifications }

enum TodayFailure {
  authentication,
  permission,
  network,
  timeout,
  invalidResponse,
  unsupported,
  unavailable,
}

class TodayIssue {
  const TodayIssue(this.source, this.failure, {this.entityId});
  final TodaySource source;
  final TodayFailure failure;
  final String? entityId;
}

/// Null means not read, while an empty successful list is genuinely empty.
/// A failed refresh may retain prior data alongside its issue and old readAt.
class TodayRead<T> {
  const TodayRead({this.value, this.issue, this.readAt});
  final T? value;
  final TodayIssue? issue;
  final DateTime? readAt;
  bool get isStale => value != null && issue != null;
}

enum TodayTodoStatus { needsAction, completed, unknown }

class TodayTodoItem {
  const TodayTodoItem({
    this.uid,
    this.summary,
    this.status = TodayTodoStatus.unknown,
    this.dueDate,
    this.dueAt,
    this.description,
    this.completedAt,
  });
  final String? uid;
  final String? summary;
  final TodayTodoStatus status;

  /// A date without an implied local/UTC time (YYYY-MM-DD).
  final String? dueDate;
  final DateTime? dueAt;
  final String? description;
  final DateTime? completedAt;
  bool get canIdentify => uid != null && uid!.isNotEmpty;
}

class TodayTodoList {
  const TodayTodoList({
    required this.entityId,
    required this.title,
    required this.supportedFeatures,
    required this.available,
    required this.items,
  });
  final String entityId;
  final String title;
  final int supportedFeatures;
  final bool available;
  final TodayRead<List<TodayTodoItem>> items;
  bool get canAdd => available && (supportedFeatures & 1) != 0;
  bool get canUpdate => available && (supportedFeatures & 4) != 0;
  bool get canSetDueDate => (supportedFeatures & 16) != 0;
  bool get canSetDueTime => (supportedFeatures & 32) != 0;
  bool get canSetDescription => (supportedFeatures & 64) != 0;
}

class TodayCalendarEvent {
  const TodayCalendarEvent({
    this.uid,
    required this.title,
    required this.start,
    required this.end,
    required this.allDay,
    this.startDate,
    this.endDate,
    this.description,
    this.location,
  });
  final String? uid;
  final String title;

  /// Already converted to Home Assistant's timezone. Do not call toLocal()
  /// when formatting: that would replace it with the phone's timezone.
  final DateTime start;
  final DateTime end;
  final bool allDay;
  final String? startDate;

  /// Exclusive end date: a Sept 5–6 all-day event occurs on Sept 5 only.
  final String? endDate;
  final String? description;
  final String? location;
}

class TodayCalendar {
  const TodayCalendar({
    required this.entityId,
    required this.title,
    required this.events,
  });
  final String entityId;
  final String title;
  final TodayRead<List<TodayCalendarEvent>> events;
}

class TodayNotification {
  const TodayNotification({
    required this.id,
    required this.message,
    required this.createdAt,
    this.title,
    this.isRead = false,
  });
  final String id;
  final String message;
  final String? title;
  final DateTime createdAt;

  /// Local to this account's active Today session; never a server mutation.
  final bool isRead;
  TodayNotification withRead(bool value) => TodayNotification(
    id: id,
    message: message,
    createdAt: createdAt,
    title: title,
    isRead: value,
  );
}

class TodaySnapshot {
  const TodaySnapshot({
    required this.configured,
    required this.refreshedAt,
    this.timeZone,
    this.dayStart,
    this.dayEnd,
    this.todoLists = const [],
    this.calendars = const [],
    this.notifications = const TodayRead(),
    this.issues = const [],
  });
  final bool configured;
  final DateTime refreshedAt;
  final String? timeZone;
  final DateTime? dayStart;
  final DateTime? dayEnd;
  final List<TodayTodoList> todoLists;
  final List<TodayCalendar> calendars;
  final TodayRead<List<TodayNotification>> notifications;
  final List<TodayIssue> issues;

  TodaySnapshot withNotifications(
    TodayRead<List<TodayNotification>> value, {
    List<TodayIssue>? issues,
  }) => TodaySnapshot(
    configured: configured,
    refreshedAt: refreshedAt,
    timeZone: timeZone,
    dayStart: dayStart,
    dayEnd: dayEnd,
    todoLists: todoLists,
    calendars: calendars,
    notifications: value,
    issues: issues ?? this.issues,
  );
}

class TodayException implements Exception {
  const TodayException(this.code);
  final String code;
  @override
  String toString() => 'The Today operation could not be completed ($code).';
}
