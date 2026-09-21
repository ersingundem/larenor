class ResourceReservationAuthority {
  const ResourceReservationAuthority({
    required this.coreId,
    required this.homeId,
    required this.accountId,
    required this.sessionId,
    required this.routeId,
    required this.coreRevision,
    required this.homeRevision,
    required this.accountRevision,
    required this.membersRevision,
    required this.resourceId,
    required this.resourceRevision,
  });

  final String coreId;
  final String homeId;
  final String accountId;
  final String sessionId;
  final String routeId;
  final int coreRevision;
  final int homeRevision;
  final int accountRevision;
  final int membersRevision;
  final String resourceId;
  final int resourceRevision;

  @override
  bool operator ==(Object other) =>
      other is ResourceReservationAuthority &&
      other.coreId == coreId &&
      other.homeId == homeId &&
      other.accountId == accountId &&
      other.sessionId == sessionId &&
      other.routeId == routeId &&
      other.coreRevision == coreRevision &&
      other.homeRevision == homeRevision &&
      other.accountRevision == accountRevision &&
      other.membersRevision == membersRevision &&
      other.resourceId == resourceId &&
      other.resourceRevision == resourceRevision;

  @override
  int get hashCode => Object.hash(
    coreId,
    homeId,
    accountId,
    sessionId,
    routeId,
    coreRevision,
    homeRevision,
    accountRevision,
    membersRevision,
    resourceId,
    resourceRevision,
  );
}

class ReservationResource {
  const ReservationResource({
    required this.id,
    required this.revision,
    required this.label,
    required this.timezone,
    required this.capacity,
  });

  final String id;
  final int revision;
  final String label;
  final String timezone;
  final int capacity;
}

class ReservationRecurrence {
  const ReservationRecurrence({required this.frequency, required this.count});

  final String frequency;
  final int count;

  @override
  bool operator ==(Object other) =>
      other is ReservationRecurrence &&
      other.frequency == frequency &&
      other.count == count;

  @override
  int get hashCode => Object.hash(frequency, count);
}

class ReservationOccurrence {
  const ReservationOccurrence({required this.startUtc, required this.endUtc});

  final String startUtc;
  final String endUtc;
}

class ReservationBusyWindow {
  const ReservationBusyWindow({
    required this.startUtc,
    required this.endUtc,
    required this.units,
  });

  final String startUtc;
  final String endUtc;
  final int units;
}

class ReservationDraft {
  const ReservationDraft._({
    required this.timezone,
    required this.localStart,
    required this.fold,
    required this.durationSeconds,
    required this.units,
    required this.recurrence,
  });

  final String timezone;
  final String localStart;
  final int fold;
  final int durationSeconds;
  final int units;
  final ReservationRecurrence recurrence;

  static ReservationDraft? tryCreate({
    required String timezone,
    required String localStart,
    required int fold,
    required int durationMinutes,
    required int units,
    required String frequency,
    required int recurrenceCount,
    int capacity = 64,
  }) {
    final canonicalLocal = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$');
    final parsed = DateTime.tryParse(localStart);
    final maxCount = frequency == 'weekly' ? 53 : 64;
    if (timezone.isEmpty ||
        timezone.length > 128 ||
        !canonicalLocal.hasMatch(localStart) ||
        parsed == null ||
        parsed.isUtc ||
        (fold != 0 && fold != 1) ||
        durationMinutes < 1 ||
        durationMinutes > 1440 ||
        units < 1 ||
        units > capacity ||
        !const {'none', 'daily', 'weekly'}.contains(frequency) ||
        recurrenceCount < 1 ||
        recurrenceCount > maxCount ||
        (frequency == 'none' && recurrenceCount != 1)) {
      return null;
    }
    return ReservationDraft._(
      timezone: timezone,
      localStart: localStart,
      fold: fold,
      durationSeconds: durationMinutes * 60,
      units: units,
      recurrence: ReservationRecurrence(
        frequency: frequency,
        count: recurrenceCount,
      ),
    );
  }
}

class ResourceReservationItem {
  ResourceReservationItem({
    required this.id,
    required this.ownerId,
    required this.resourceId,
    required this.timezone,
    required this.localStart,
    required this.fold,
    required this.durationSeconds,
    required this.units,
    required this.recurrence,
    required List<ReservationOccurrence> occurrences,
    required this.canCancel,
    required this.cancelled,
  }) : occurrences = List.unmodifiable(occurrences);

  final String id;
  final String ownerId;
  final String resourceId;
  final String timezone;
  final String localStart;
  final int fold;
  final int durationSeconds;
  final int units;
  final ReservationRecurrence recurrence;
  final List<ReservationOccurrence> occurrences;
  final bool canCancel;
  final bool cancelled;

  bool matchesDraft(ReservationDraft draft) =>
      timezone == draft.timezone &&
      localStart == draft.localStart &&
      fold == draft.fold &&
      durationSeconds == draft.durationSeconds &&
      units == draft.units &&
      recurrence == draft.recurrence &&
      occurrences.isNotEmpty &&
      occurrences.length <= 64;
}

class ReservationHistoryItem {
  const ReservationHistoryItem({
    required this.eventId,
    required this.action,
    required this.actorId,
    required this.reservationId,
    required this.calendarRevision,
  });

  final String eventId;
  final ReservationAction action;
  final String actorId;
  final String reservationId;
  final int calendarRevision;
}

class ReservationSnapshot {
  ReservationSnapshot({
    required this.authority,
    required this.calendarRevision,
    required this.resource,
    required this.canCreate,
    required List<ResourceReservationItem> reservations,
    required List<ReservationHistoryItem> history,
    required List<ReservationBusyWindow> busy,
  }) : reservations = List.unmodifiable(reservations),
       history = List.unmodifiable(history),
       busy = List.unmodifiable(busy);

  final ResourceReservationAuthority authority;
  final int calendarRevision;
  final ReservationResource resource;
  final bool canCreate;
  final List<ResourceReservationItem> reservations;
  final List<ReservationHistoryItem> history;
  final List<ReservationBusyWindow> busy;
}

enum ReservationAction { create, cancel }

class ReservationReceipt {
  const ReservationReceipt({
    required this.authority,
    required this.eventId,
    required this.actorId,
    required this.commandId,
    required this.action,
    required this.expectedCalendarRevision,
    required this.calendarRevision,
    required this.reservation,
  });

  final ResourceReservationAuthority authority;
  final String eventId;
  final String actorId;
  final String commandId;
  final ReservationAction action;
  final int expectedCalendarRevision;
  final int calendarRevision;
  final ResourceReservationItem reservation;
}

class ReservationExport {
  ReservationExport({
    required this.authority,
    required this.calendarRevision,
    required List<ResourceReservationItem> reservations,
  }) : reservations = List.unmodifiable(reservations);

  final ResourceReservationAuthority authority;
  final int calendarRevision;
  final List<ResourceReservationItem> reservations;
}

class ReservationApiException implements Exception {
  const ReservationApiException(this.code);

  final String code;
}

abstract interface class ResourceReservationApi {
  Future<ReservationSnapshot> snapshot(ResourceReservationAuthority authority);

  Future<ReservationReceipt> create(
    ResourceReservationAuthority authority, {
    required int expectedCalendarRevision,
    required String commandId,
    required ReservationDraft draft,
  });

  Future<ReservationReceipt> cancel(
    ResourceReservationAuthority authority, {
    required int expectedCalendarRevision,
    required String commandId,
    required String reservationId,
  });

  Future<ReservationReceipt?> receipt(
    ResourceReservationAuthority authority,
    String commandId,
  );

  Future<ReservationExport> export(
    ResourceReservationAuthority authority, {
    required int expectedCalendarRevision,
    required int limit,
  });
}
