import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/room_comfort/data/room_comfort_controller.dart';
import 'package:larenor/features/room_comfort/domain/room_comfort_models.dart';

RoomComfortPlan plan({String? homeId, List<RoomComfortPlanItem>? rooms}) =>
    RoomComfortPlan(
      coreId: 'a' * 32,
      homeId: homeId ?? 'b' * 32,
      planId: 'c' * 32,
      policyId: 'd' * 32,
      homeRevision: 2,
      policyRevision: 3,
      accountRevision: 4,
      sessionFamilyId: 'e' * 32,
      generatedAt: DateTime.utc(2026, 9, 21),
      rooms: rooms ?? [room('f')],
    );

RoomComfortPlanItem room(String id) => RoomComfortPlanItem(
  roomId: id * 32,
  roomRevision: 5,
  areaId: '1' * 32,
  areaRevision: 6,
  status: ComfortPlanStatus.planned,
  reason: ComfortReason.temperatureLow,
  hvacMode: ComfortHvacMode.heat,
  windowState: ComfortWindowState.closed,
  occupancy: ComfortOccupancy.occupied,
);

final class _Gateway implements RoomComfortGateway {
  _Gateway(this.next);
  final Future<RoomComfortPlan> next;
  bool retired = false;
  Future<RoomComfortPreview>? nextPreview;
  Future<RoomComfortReceipt>? nextReceipt;
  @override
  Future<RoomComfortPlan> loadPlan() => next;
  @override
  Future<RoomComfortPreview> preview(RoomComfortPlan plan, String requestId) =>
      nextPreview ??
      Future.value(
        RoomComfortPreview(
          id: '1' * 32,
          planId: plan.planId,
          policyRevision: plan.policyRevision,
          token: 'A' * 43,
          expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 1)),
          commandCount: 1,
        ),
      );
  @override
  Future<RoomComfortReceipt> confirm(RoomComfortPreview preview) =>
      nextReceipt ??
      Future.value(
        RoomComfortReceipt(
          requestId: '2' * 32,
          planId: preview.planId,
          status: 'unknown',
          commandCount: preview.commandCount,
        ),
      );
  @override
  void retire() => retired = true;
}

RoomComfortController _controller(_Gateway gateway, bool Function() current) =>
    RoomComfortController(
      gateway: gateway,
      isCurrent: current,
      coreId: 'a' * 32,
      homeId: 'b' * 32,
      requestId: () => '3' * 32,
    );

void main() {
  test('exact Core home and session plan is retained', () async {
    final gateway = _Gateway(Future.value(plan()));
    final value = _controller(gateway, () => true);
    await value.refresh();
    expect(value.plan?.policyRevision, 3);
    expect(value.failure, isNull);
    value.dispose();
    expect(gateway.retired, isTrue);
  });

  test('wrong home and duplicate room plans fail closed', () async {
    for (final invalid in [
      plan(homeId: '9' * 32),
      plan(rooms: [room('f'), room('f')]),
    ]) {
      final value = _controller(_Gateway(Future.value(invalid)), () => true);
      await value.refresh();
      expect(value.plan, isNull);
      expect(value.failure, RoomComfortFailure.invalidScope);
      value.dispose();
    }
  });

  test('late result after route retirement is discarded', () async {
    final pending = Completer<RoomComfortPlan>();
    var current = true;
    final gateway = _Gateway(pending.future);
    final value = _controller(gateway, () => current);
    final operation = value.refresh();
    current = false;
    value.retire();
    pending.complete(plan());
    await operation;
    expect(value.plan, isNull);
    expect(gateway.retired, isTrue);
    value.dispose();
  });

  test('preview and exact receipt reconcile once', () async {
    final gateway = _Gateway(Future.value(plan()));
    final value = _controller(gateway, () => true);
    await value.refresh();
    final preview = await value.preview();
    expect(preview, isNotNull);
    expect(await value.confirm(preview!), isTrue);
    expect(value.receipt?.status, 'unknown');
    expect(await value.confirm(preview), isFalse);
    value.dispose();
  });

  test('late confirmation is rejected after authority retires', () async {
    final gateway = _Gateway(Future.value(plan()));
    final pending = Completer<RoomComfortReceipt>();
    gateway.nextReceipt = pending.future;
    var current = true;
    final value = _controller(gateway, () => current);
    await value.refresh();
    final preview = await value.preview();
    final operation = value.confirm(preview!);
    current = false;
    value.retire();
    pending.complete(
      RoomComfortReceipt(
        requestId: '2' * 32,
        planId: preview.planId,
        status: 'unknown',
        commandCount: preview.commandCount,
      ),
    );
    expect(await operation, isFalse);
    expect(value.receipt, isNull);
    value.dispose();
  });
}
