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
  @override
  Future<RoomComfortPlan> loadPlan() => next;
  @override
  void retire() => retired = true;
}

RoomComfortController _controller(_Gateway gateway, bool Function() current) =>
    RoomComfortController(
      gateway: gateway,
      isCurrent: current,
      coreId: 'a' * 32,
      homeId: 'b' * 32,
      sessionFamilyId: 'e' * 32,
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
}
