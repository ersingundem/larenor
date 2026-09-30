import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/resource_reservations/data/resource_reservation_api.dart';
import 'package:larenor/features/resource_reservations/domain/resource_reservation_models.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

final class _Store implements ServerSessionPersistence {
  @override
  Future<ServerSession?> read() async => null;

  @override
  Future<void> write(ServerSession? session) async {}
}

void main() {
  final coreUrl = Platform.environment['LARENOR_RESERVATION_CORE_URL'];
  final phase = Platform.environment['LARENOR_RESERVATION_PHASE'];

  setUpAll(() => HttpOverrides.global = null);

  test(
    'real Client reconciles reservation receipts across normal Core restart',
    () async {
      final account = ServerAccountController(store: _Store());
      addTearDown(account.dispose);
      await account.signIn(
        baseUrl: coreUrl!,
        username: 'admin',
        password: 'Synthetic new password 2026',
        deviceName: 'Resource reservation acceptance',
      );
      expect(account.failure, isNull);
      final context = account.session!.context!;
      var current = true;

      final catalogApi = await ResourceReservationAccountApi.connect(
        account: account,
        context: context,
        routeId: 'f40-normal-core-catalog',
        isCurrent: () => current,
      );
      addTearDown(catalogApi.close);
      final catalog = await catalogApi.resources();
      expect(catalog.canManage, isTrue);

      late ReservationResource resource;
      if (phase == 'create') {
        expect(catalog.catalogRevision, 1);
        expect(catalog.resources.single.label, 'Shared home resource');
        const commandId = '11111111111111111111111111111111';
        final created = await catalogApi.createResource(
          expectedCatalogRevision: catalog.catalogRevision,
          commandId: commandId,
          label: 'Acceptance workshop',
          timezone: 'Europe/Istanbul',
          capacity: 2,
        );
        final replay = await catalogApi.createResource(
          expectedCatalogRevision: catalog.catalogRevision,
          commandId: commandId,
          label: 'Acceptance workshop',
          timezone: 'Europe/Istanbul',
          capacity: 2,
        );
        expect(replay.catalogRevision, created.catalogRevision);
        expect(replay.resource.id, created.resource.id);
        expect(created.catalogRevision, 2);
        resource = created.resource;
      } else {
        expect(phase, 'restart');
        expect(catalog.catalogRevision, 2);
        resource = catalog.resources.singleWhere(
          (item) => item.label == 'Acceptance workshop',
        );
        expect(resource.timezone, 'Europe/Istanbul');
        expect(resource.capacity, 2);
      }

      final primary = await ResourceReservationAccountApi.connect(
        account: account,
        context: context,
        routeId: 'f40-normal-core-calendar',
        resourceId: resource.id,
        isCurrent: () => current,
      );
      final staleReceiptReader = await ResourceReservationAccountApi.connect(
        account: account,
        context: context,
        routeId: 'f40-normal-core-calendar',
        resourceId: resource.id,
        isCurrent: () => current,
      );
      addTearDown(primary.close);
      addTearDown(staleReceiptReader.close);

      final before = await primary.snapshot(primary.authority);
      final staleBefore = await staleReceiptReader.snapshot(
        staleReceiptReader.authority,
      );
      expect(staleBefore.calendarRevision, before.calendarRevision);

      if (phase == 'create') {
        expect(before.calendarRevision, 1);
        expect(before.reservations, isEmpty);
        final draft = ReservationDraft.tryCreate(
          timezone: resource.timezone,
          localStart: '2026-11-01T10:00:00',
          fold: 0,
          durationMinutes: 60,
          units: 2,
          frequency: 'none',
          recurrenceCount: 1,
          capacity: resource.capacity,
        )!;
        const commandId = '22222222222222222222222222222222';
        final receipt = await primary.create(
          primary.authority,
          expectedCalendarRevision: before.calendarRevision,
          commandId: commandId,
          draft: draft,
        );
        expect(receipt.calendarRevision, 2);
        expect(receipt.action, ReservationAction.create);

        // This API retained revision 1 as if the create response was lost. It
        // resolves the durable receipt and never calls the mutator again.
        final recovered = await staleReceiptReader.receipt(
          staleReceiptReader.authority,
          commandId,
        );
        expect(recovered!.eventId, receipt.eventId);
        expect(recovered.reservation.id, receipt.reservation.id);
        final after = await staleReceiptReader.snapshot(
          staleReceiptReader.authority,
        );
        expect(after.calendarRevision, 2);
        expect(after.reservations.single.cancelled, isFalse);
        expect(after.history.single.action, ReservationAction.create);
      } else {
        expect(before.calendarRevision, 2);
        final reservation = before.reservations.single;
        expect(reservation.cancelled, isFalse);
        expect(before.history.single.action, ReservationAction.create);
        const commandId = '33333333333333333333333333333333';
        final receipt = await primary.cancel(
          primary.authority,
          expectedCalendarRevision: before.calendarRevision,
          commandId: commandId,
          reservationId: reservation.id,
        );
        expect(receipt.calendarRevision, 3);
        expect(receipt.action, ReservationAction.cancel);

        final recovered = await staleReceiptReader.receipt(
          staleReceiptReader.authority,
          commandId,
        );
        expect(recovered!.eventId, receipt.eventId);
        expect(recovered.reservation.cancelled, isTrue);
        final after = await staleReceiptReader.snapshot(
          staleReceiptReader.authority,
        );
        expect(after.calendarRevision, 3);
        expect(after.reservations.single.cancelled, isTrue);
        expect(after.history.map((item) => item.action), [
          ReservationAction.create,
          ReservationAction.cancel,
        ]);
        final exported = await staleReceiptReader.export(
          staleReceiptReader.authority,
          expectedCalendarRevision: after.calendarRevision,
          limit: 256,
        );
        expect(exported.reservations.single.cancelled, isTrue);
      }

      current = false;
      await expectLater(
        primary.snapshot(primary.authority),
        throwsA(
          isA<ReservationApiException>().having(
            (error) => error.code,
            'code',
            'authority_changed',
          ),
        ),
      );
    },
    skip: coreUrl == null || phase == null
        ? 'Requires explicit isolated normal Core runner'
        : false,
  );
}
