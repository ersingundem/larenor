import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/resource_reservations/data/resource_reservation_controller.dart';
import 'package:larenor/features/resource_reservations/domain/resource_reservation_models.dart';

const reservationAuthorityA = ResourceReservationAuthority(
  coreId: 'core-a',
  homeId: 'home-a',
  accountId: 'ada',
  sessionId: 'session-a',
  routeId: 'resources-a',
  coreRevision: 3,
  homeRevision: 5,
  accountRevision: 9,
  membersRevision: 11,
  resourceId: 'room-study',
  resourceRevision: 13,
);

const reservationAuthorityB = ResourceReservationAuthority(
  coreId: 'core-b',
  homeId: 'home-b',
  accountId: 'baran',
  sessionId: 'session-b',
  routeId: 'resources-b',
  coreRevision: 4,
  homeRevision: 6,
  accountRevision: 10,
  membersRevision: 12,
  resourceId: 'car-family',
  resourceRevision: 14,
);

const studyResource = ReservationResource(
  id: 'room-study',
  revision: 13,
  label: 'Study room',
  timezone: 'Europe/Berlin',
  capacity: 2,
);

ResourceReservationItem reservation({
  String id = 'reservation-1',
  bool canCancel = true,
  bool cancelled = false,
}) => ResourceReservationItem(
  id: id,
  ownerId: 'ada',
  resourceId: 'room-study',
  timezone: 'Europe/Berlin',
  localStart: '2026-10-25T02:30:00',
  fold: 1,
  durationSeconds: 3600,
  units: 1,
  recurrence: const ReservationRecurrence(frequency: 'weekly', count: 2),
  occurrences: const [
    ReservationOccurrence(
      startUtc: '2026-10-25T01:30:00Z',
      endUtc: '2026-10-25T02:30:00Z',
    ),
    ReservationOccurrence(
      startUtc: '2026-11-01T01:30:00Z',
      endUtc: '2026-11-01T02:30:00Z',
    ),
  ],
  canCancel: canCancel,
  cancelled: cancelled,
);

ReservationSnapshot snapshot(
  ResourceReservationAuthority authority, {
  int calendarRevision = 7,
  bool canCreate = true,
  List<ResourceReservationItem> reservations = const [],
  List<ReservationHistoryItem> history = const [
    ReservationHistoryItem(
      eventId: 'event-1',
      action: ReservationAction.create,
      actorId: 'ada',
      reservationId: 'reservation-1',
      calendarRevision: 7,
    ),
  ],
}) => ReservationSnapshot(
  authority: authority,
  calendarRevision: calendarRevision,
  resource: studyResource,
  canCreate: canCreate,
  reservations: reservations,
  history: history,
  busy: const [
    ReservationBusyWindow(
      startUtc: '2026-10-25T01:30:00Z',
      endUtc: '2026-10-25T02:30:00Z',
      units: 1,
    ),
  ],
);

ReservationDraft draft() => ReservationDraft.tryCreate(
  timezone: 'Europe/Berlin',
  localStart: '2026-10-25T02:30:00',
  fold: 1,
  durationMinutes: 60,
  units: 1,
  frequency: 'weekly',
  recurrenceCount: 2,
)!;

class FakeReservationApi implements ResourceReservationApi {
  final snapshots = <Completer<ReservationSnapshot>>[];
  int createCalls = 0;
  int cancelCalls = 0;
  int receiptReads = 0;
  int exportReads = 0;
  bool timeoutCreate = false;
  bool conflictCreate = false;
  ReservationReceipt? reconciled;
  ReservationExport? exported;

  @override
  Future<ReservationSnapshot> snapshot(ResourceReservationAuthority authority) {
    final completer = Completer<ReservationSnapshot>();
    snapshots.add(completer);
    return completer.future;
  }

  @override
  Future<ReservationReceipt> create(
    ResourceReservationAuthority authority, {
    required int expectedCalendarRevision,
    required String commandId,
    required ReservationDraft draft,
  }) async {
    createCalls++;
    if (conflictCreate) {
      throw const ReservationApiException('reservation_overlap');
    }
    if (timeoutCreate) throw TimeoutException('lost ack');
    return ReservationReceipt(
      authority: authority,
      eventId: 'event-create',
      actorId: authority.accountId,
      commandId: commandId,
      action: ReservationAction.create,
      expectedCalendarRevision: expectedCalendarRevision,
      calendarRevision: expectedCalendarRevision + 1,
      reservation: reservation(id: 'created'),
    );
  }

  @override
  Future<ReservationReceipt> cancel(
    ResourceReservationAuthority authority, {
    required int expectedCalendarRevision,
    required String commandId,
    required String reservationId,
  }) async {
    cancelCalls++;
    return ReservationReceipt(
      authority: authority,
      eventId: 'event-cancel',
      actorId: authority.accountId,
      commandId: commandId,
      action: ReservationAction.cancel,
      expectedCalendarRevision: expectedCalendarRevision,
      calendarRevision: expectedCalendarRevision + 1,
      reservation: reservation(id: reservationId, cancelled: true),
    );
  }

  @override
  Future<ReservationReceipt?> receipt(
    ResourceReservationAuthority authority,
    String commandId,
  ) async {
    receiptReads++;
    return reconciled;
  }

  @override
  Future<ReservationExport> export(
    ResourceReservationAuthority authority, {
    required int expectedCalendarRevision,
    required int limit,
  }) async {
    exportReads++;
    return exported ??
        ReservationExport(
          authority: authority,
          calendarRevision: expectedCalendarRevision,
          reservations: const [],
        );
  }
}

void main() {
  test('draft is bounded and keeps explicit timezone and DST fold', () {
    final value = draft();
    expect(value.timezone, 'Europe/Berlin');
    expect(value.fold, 1);
    expect(value.durationSeconds, 3600);
    expect(
      value.recurrence,
      const ReservationRecurrence(frequency: 'weekly', count: 2),
    );
    expect(
      ReservationDraft.tryCreate(
        timezone: 'Europe/Berlin',
        localStart: '2026-10-25 02:30',
        fold: 1,
        durationMinutes: 60,
        units: 1,
        frequency: 'weekly',
        recurrenceCount: 2,
      ),
      isNull,
    );
    expect(
      ReservationDraft.tryCreate(
        timezone: 'Europe/Berlin',
        localStart: '2026-10-25T02:30:00',
        fold: 1,
        durationMinutes: 60,
        units: 3,
        frequency: 'weekly',
        recurrenceCount: 2,
        capacity: 2,
      ),
      isNull,
    );
  });

  test('late authority is ignored and overlap is a visible conflict', () async {
    final api = FakeReservationApi();
    final controller = ResourceReservationController(
      api,
      commandIds: () => 'cmd-1',
    );
    final oldLease = controller.bind(reservationAuthorityA);
    final oldLoad = controller.load(oldLease);
    final currentLease = controller.bind(reservationAuthorityB);
    api.snapshots.single.complete(snapshot(reservationAuthorityA));
    await oldLoad;
    expect(controller.authority, reservationAuthorityB);
    expect(controller.reservations, isEmpty);

    final currentLoad = controller.load(currentLease);
    api.snapshots.last.complete(
      ReservationSnapshot(
        authority: reservationAuthorityB,
        calendarRevision: 8,
        resource: const ReservationResource(
          id: 'car-family',
          revision: 14,
          label: 'Family car',
          timezone: 'Europe/Berlin',
          capacity: 1,
        ),
        canCreate: true,
        reservations: const [],
        history: const [],
        busy: const [],
      ),
    );
    await currentLoad;
    expect(controller.state, ReservationViewState.empty);

    api.conflictCreate = true;
    await controller.create(currentLease, draft());
    expect(controller.state, ReservationViewState.conflict);
    expect(api.createCalls, 1);
  });

  test(
    'lost acknowledgement reconciles without replay and export is read-only',
    () async {
      final api = FakeReservationApi()..timeoutCreate = true;
      final controller = ResourceReservationController(
        api,
        commandIds: () => 'create-1',
      );
      final lease = controller.bind(reservationAuthorityA);
      final load = controller.load(lease);
      api.snapshots.single.complete(snapshot(reservationAuthorityA));
      await load;

      await controller.create(lease, draft());
      await controller.create(lease, draft());
      expect(controller.state, ReservationViewState.uncertain);
      expect(
        api.createCalls,
        1,
        reason: 'uncertain commands are never replayed',
      );
      api.reconciled = ReservationReceipt(
        authority: reservationAuthorityA,
        eventId: 'event-reconciled',
        actorId: 'ada',
        commandId: 'create-1',
        action: ReservationAction.create,
        expectedCalendarRevision: 7,
        calendarRevision: 8,
        reservation: reservation(id: 'created'),
      );
      await controller.reconcile(lease);
      expect(api.receiptReads, 1);
      expect(controller.calendarRevision, 8);
      expect(controller.reservations.single.id, 'created');
      expect(controller.history.last.action, ReservationAction.create);

      api.exported = ReservationExport(
        authority: reservationAuthorityA,
        calendarRevision: 8,
        reservations: [controller.reservations.single],
      );
      await controller.readExport(lease);
      expect(api.exportReads, 1);
      expect(controller.exported.single.id, 'created');
      expect(api.createCalls, 1, reason: 'export cannot emit a mutator');
    },
  );

  test('server role grants gate create and cancellation', () async {
    final api = FakeReservationApi();
    final controller = ResourceReservationController(
      api,
      commandIds: () => 'denied',
    );
    final lease = controller.bind(reservationAuthorityA);
    final load = controller.load(lease);
    api.snapshots.single.complete(
      snapshot(
        reservationAuthorityA,
        canCreate: false,
        reservations: [reservation(canCancel: false)],
      ),
    );
    await load;
    await controller.create(lease, draft());
    await controller.cancel(lease, controller.reservations.single);
    expect(api.createCalls, 0);
    expect(api.cancelCalls, 0);
  });

  test('authorized cancellation advances exact calendar revision', () async {
    final api = FakeReservationApi();
    final controller = ResourceReservationController(
      api,
      commandIds: () => 'cancel-1',
    );
    final lease = controller.bind(reservationAuthorityA);
    final load = controller.load(lease);
    api.snapshots.single.complete(
      snapshot(reservationAuthorityA, reservations: [reservation()]),
    );
    await load;

    await controller.cancel(lease, controller.reservations.single);
    expect(api.cancelCalls, 1);
    expect(controller.calendarRevision, 8);
    expect(controller.reservations.single.cancelled, isTrue);
    expect(controller.history.last.action, ReservationAction.cancel);
  });
}
