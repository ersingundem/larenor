Never _invalidReservation() =>
    throw const ReservationApiException('invalid_response');

Map<Object?, Object?> _reservationMap(Object? raw, Set<String> keys) {
  if (raw is! Map ||
      raw.length != keys.length ||
      !keys.every(raw.containsKey)) {
    _invalidReservation();
  }
  return raw;
}

String _reservationId(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value.length > 128 ||
      !RegExp(r'^[A-Za-z0-9_.:-]+$').hasMatch(value)) {
    _invalidReservation();
  }
  return value;
}

int _reservationRevision(Object? value, {bool zero = false}) {
  if (value is! int || value < (zero ? 0 : 1) || value > 9223372036854775807) {
    _invalidReservation();
  }
  return value;
}

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

  factory ResourceReservationAuthority.fromJson(
    Object? raw, {
    required String routeId,
    required String coreId,
    required String homeId,
    required String accountId,
  }) {
    final value = _reservationMap(raw, const {
      'coreId',
      'homeId',
      'accountId',
      'sessionId',
      'coreRevision',
      'homeRevision',
      'accountRevision',
      'membersRevision',
      'resourceId',
      'resourceRevision',
    });
    if (_reservationId(value['coreId']) != coreId ||
        _reservationId(value['homeId']) != homeId ||
        _reservationId(value['accountId']) != accountId) {
      _invalidReservation();
    }
    return ResourceReservationAuthority(
      coreId: coreId,
      homeId: homeId,
      accountId: accountId,
      sessionId: _reservationId(value['sessionId']),
      routeId: _reservationId(routeId),
      coreRevision: _reservationRevision(value['coreRevision']),
      homeRevision: _reservationRevision(value['homeRevision']),
      accountRevision: _reservationRevision(value['accountRevision']),
      membersRevision: _reservationRevision(value['membersRevision']),
      resourceId: _reservationId(value['resourceId']),
      resourceRevision: _reservationRevision(value['resourceRevision']),
    );
  }

  Map<String, Object> expectations(int calendarRevision) => {
    'schemaVersion': 1,
    'coreId': coreId,
    'homeId': homeId,
    'accountId': accountId,
    'sessionId': sessionId,
    'coreRevision': coreRevision,
    'homeRevision': homeRevision,
    'accountRevision': accountRevision,
    'membersRevision': membersRevision,
    'resourceId': resourceId,
    'resourceRevision': resourceRevision,
    'expectedCalendarRevision': calendarRevision,
  };

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

  factory ReservationResource.fromJson(Object? raw) {
    final value = _reservationMap(raw, const {
      'id',
      'revision',
      'label',
      'timezone',
      'capacity',
    });
    final label = value['label'], timezone = value['timezone'];
    final capacity = value['capacity'];
    if (label is! String ||
        label.trim().isEmpty ||
        label.length > 80 ||
        timezone is! String ||
        timezone.isEmpty ||
        timezone.length > 128 ||
        capacity is! int ||
        capacity < 1 ||
        capacity > 64) {
      _invalidReservation();
    }
    return ReservationResource(
      id: _reservationId(value['id']),
      revision: _reservationRevision(value['revision']),
      label: label,
      timezone: timezone,
      capacity: capacity,
    );
  }
}

class ResourceReservationBootstrap {
  const ResourceReservationBootstrap({
    required this.authority,
    required this.calendarRevision,
    required this.resource,
  });

  final ResourceReservationAuthority authority;
  final int calendarRevision;
  final ReservationResource resource;

  factory ResourceReservationBootstrap.fromJson(
    Object? raw, {
    required String routeId,
    required String coreId,
    required String homeId,
    required String accountId,
  }) {
    final value = _reservationMap(raw, const {
      'schemaVersion',
      'authority',
      'calendarRevision',
      'resource',
    });
    if (value['schemaVersion'] != 1) _invalidReservation();
    final authority = ResourceReservationAuthority.fromJson(
      value['authority'],
      routeId: routeId,
      coreId: coreId,
      homeId: homeId,
      accountId: accountId,
    );
    final resource = ReservationResource.fromJson(value['resource']);
    if (resource.id != authority.resourceId ||
        resource.revision != authority.resourceRevision) {
      _invalidReservation();
    }
    return ResourceReservationBootstrap(
      authority: authority,
      calendarRevision: _reservationRevision(value['calendarRevision']),
      resource: resource,
    );
  }
}

class ReservationRecurrence {
  const ReservationRecurrence({required this.frequency, required this.count});

  final String frequency;
  final int count;

  factory ReservationRecurrence.fromJson(Object? raw) {
    final value = _reservationMap(raw, const {'frequency', 'count'});
    final frequency = value['frequency'], count = value['count'];
    if (!const {'none', 'daily', 'weekly'}.contains(frequency) ||
        count is! int ||
        count < 1 ||
        count > 64 ||
        frequency == 'none' && count != 1) {
      _invalidReservation();
    }
    return ReservationRecurrence(frequency: frequency! as String, count: count);
  }

  Map<String, Object> toJson() => {'frequency': frequency, 'count': count};

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

  factory ReservationOccurrence.fromJson(Object? raw) {
    final value = _reservationMap(raw, const {'startUtc', 'endUtc'});
    if (value['startUtc'] is! String || value['endUtc'] is! String) {
      _invalidReservation();
    }
    return ReservationOccurrence(
      startUtc: value['startUtc']! as String,
      endUtc: value['endUtc']! as String,
    );
  }
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

  factory ReservationBusyWindow.fromJson(Object? raw) {
    final value = _reservationMap(raw, const {'startUtc', 'endUtc', 'units'});
    if (value['startUtc'] is! String ||
        value['endUtc'] is! String ||
        value['units'] is! int) {
      _invalidReservation();
    }
    return ReservationBusyWindow(
      startUtc: value['startUtc']! as String,
      endUtc: value['endUtc']! as String,
      units: value['units']! as int,
    );
  }
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

  Map<String, Object> toJson() => {
    'timezone': timezone,
    'localStart': localStart,
    'fold': fold,
    'durationSeconds': durationSeconds,
    'units': units,
    'recurrence': recurrence.toJson(),
  };

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

  factory ResourceReservationItem.fromJson(Object? raw) {
    final value = _reservationMap(raw, const {
      'id',
      'ownerId',
      'resourceId',
      'timezone',
      'localStart',
      'fold',
      'durationSeconds',
      'units',
      'recurrence',
      'occurrences',
      'canCancel',
      'cancelled',
    });
    final occurrences = value['occurrences'];
    if (value['timezone'] is! String ||
        value['localStart'] is! String ||
        value['fold'] is! int ||
        value['durationSeconds'] is! int ||
        value['units'] is! int ||
        value['canCancel'] is! bool ||
        value['cancelled'] is! bool ||
        occurrences is! List ||
        occurrences.isEmpty ||
        occurrences.length > 64) {
      _invalidReservation();
    }
    return ResourceReservationItem(
      id: _reservationId(value['id']),
      ownerId: _reservationId(value['ownerId']),
      resourceId: _reservationId(value['resourceId']),
      timezone: value['timezone']! as String,
      localStart: value['localStart']! as String,
      fold: value['fold']! as int,
      durationSeconds: value['durationSeconds']! as int,
      units: value['units']! as int,
      recurrence: ReservationRecurrence.fromJson(value['recurrence']),
      occurrences: occurrences.map(ReservationOccurrence.fromJson).toList(),
      canCancel: value['canCancel']! as bool,
      cancelled: value['cancelled']! as bool,
    );
  }

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

  factory ReservationHistoryItem.fromJson(Object? raw) {
    final value = _reservationMap(raw, const {
      'eventId',
      'action',
      'actorId',
      'reservationId',
      'calendarRevision',
    });
    final action = switch (value['action']) {
      'create' => ReservationAction.create,
      'cancel' => ReservationAction.cancel,
      _ => _invalidReservation(),
    };
    return ReservationHistoryItem(
      eventId: _reservationId(value['eventId']),
      action: action,
      actorId: _reservationId(value['actorId']),
      reservationId: _reservationId(value['reservationId']),
      calendarRevision: _reservationRevision(value['calendarRevision']),
    );
  }
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

  factory ReservationSnapshot.fromJson(
    Object? raw,
    ResourceReservationAuthority expected,
  ) {
    final value = _reservationMap(raw, const {
      'schemaVersion',
      'authority',
      'calendarRevision',
      'resource',
      'canCreate',
      'reservations',
      'history',
      'busy',
    });
    if (value['schemaVersion'] != 1 ||
        value['canCreate'] is! bool ||
        value['reservations'] is! List ||
        value['history'] is! List ||
        value['busy'] is! List) {
      _invalidReservation();
    }
    final authority = ResourceReservationAuthority.fromJson(
      value['authority'],
      routeId: expected.routeId,
      coreId: expected.coreId,
      homeId: expected.homeId,
      accountId: expected.accountId,
    );
    if (authority != expected) _invalidReservation();
    return ReservationSnapshot(
      authority: authority,
      calendarRevision: _reservationRevision(value['calendarRevision']),
      resource: ReservationResource.fromJson(value['resource']),
      canCreate: value['canCreate']! as bool,
      reservations: (value['reservations']! as List)
          .map(ResourceReservationItem.fromJson)
          .toList(),
      history: (value['history']! as List)
          .map(ReservationHistoryItem.fromJson)
          .toList(),
      busy: (value['busy']! as List)
          .map(ReservationBusyWindow.fromJson)
          .toList(),
    );
  }
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

  factory ReservationReceipt.fromJson(
    Object? raw,
    ResourceReservationAuthority expected,
  ) {
    final value = _reservationMap(raw, const {
      'schemaVersion',
      'authority',
      'eventId',
      'actorId',
      'commandId',
      'action',
      'expectedCalendarRevision',
      'calendarRevision',
      'reservation',
    });
    if (value['schemaVersion'] != 1) _invalidReservation();
    final authority = ResourceReservationAuthority.fromJson(
      value['authority'],
      routeId: expected.routeId,
      coreId: expected.coreId,
      homeId: expected.homeId,
      accountId: expected.accountId,
    );
    if (authority != expected) _invalidReservation();
    return ReservationReceipt(
      authority: authority,
      eventId: _reservationId(value['eventId']),
      actorId: _reservationId(value['actorId']),
      commandId: _reservationId(value['commandId']),
      action: switch (value['action']) {
        'create' => ReservationAction.create,
        'cancel' => ReservationAction.cancel,
        _ => _invalidReservation(),
      },
      expectedCalendarRevision: _reservationRevision(
        value['expectedCalendarRevision'],
      ),
      calendarRevision: _reservationRevision(value['calendarRevision']),
      reservation: ResourceReservationItem.fromJson(value['reservation']),
    );
  }
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

  factory ReservationExport.fromJson(
    Object? raw,
    ResourceReservationAuthority expected,
  ) {
    final value = _reservationMap(raw, const {
      'schemaVersion',
      'authority',
      'calendarRevision',
      'reservations',
    });
    if (value['schemaVersion'] != 1 || value['reservations'] is! List) {
      _invalidReservation();
    }
    final authority = ResourceReservationAuthority.fromJson(
      value['authority'],
      routeId: expected.routeId,
      coreId: expected.coreId,
      homeId: expected.homeId,
      accountId: expected.accountId,
    );
    if (authority != expected) _invalidReservation();
    return ReservationExport(
      authority: authority,
      calendarRevision: _reservationRevision(value['calendarRevision']),
      reservations: (value['reservations']! as List)
          .map(ResourceReservationItem.fromJson)
          .toList(),
    );
  }
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
