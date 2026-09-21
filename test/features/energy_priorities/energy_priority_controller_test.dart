import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/energy_priorities/data/energy_priority_controller.dart';
import 'package:larenor/features/energy_priorities/domain/energy_priority_models.dart';

void main() {
  test('preview confirm succeeds only after exact readback', () async {
    final api = FakeEnergyPriorityApi();
    final controller = EnergyPriorityController(
      api: api,
      isCurrent: () => true,
    );
    await controller.load();
    await controller.preview(controller.snapshot!.slots.first);
    expect(controller.state, EnergyPriorityViewState.awaitingConfirmation);
    await controller.confirm();
    expect(controller.state, EnergyPriorityViewState.verified);
    expect(api.readbacks, 1);
    controller.dispose();
  });

  test('late response after route retirement clears energy state', () async {
    final pending = Completer<EnergyPrioritySnapshot>();
    final api = FakeEnergyPriorityApi(loadResult: pending.future);
    var current = true;
    final controller = EnergyPriorityController(
      api: api,
      isCurrent: () => current,
    );
    final load = controller.load();
    current = false;
    controller.setInteractive(false);
    pending.complete(snapshot());
    await load;
    expect(controller.state, EnergyPriorityViewState.stale);
    expect(controller.snapshot, isNull);
    controller.dispose();
  });
}

EnergyPrioritySnapshot snapshot({bool canControl = true}) =>
    EnergyPrioritySnapshot(
      coreId: '11111111111111111111111111111111',
      homeId: '22222222222222222222222222222222',
      accountId: '33333333333333333333333333333333',
      sessionFamilyId: '44444444444444444444444444444444',
      homeRevision: 1,
      accountRevision: 1,
      canControl: canControl,
      planId: '55555555555555555555555555555555',
      inputDigest:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      batteryId: '66666666666666666666666666666666',
      batteryRevision: 1,
      inverterId: '77777777777777777777777777777777',
      inverterRevision: 1,
      reservePercent: 40,
      stateOfChargePercent: 50,
      solarEnergyWh: 3000,
      consumptionEnergyWh: 1000,
      importPriceMicrosPerKwh: 100000,
      slots: const [
        EnergyPlanSlot(
          index: 0,
          action: EnergyPlanAction.charge,
          powerW: 2000,
          projectedSocWh: 7000,
          reason: 'solar_surplus',
        ),
      ],
    );

final class FakeEnergyPriorityApi implements EnergyPriorityApi {
  FakeEnergyPriorityApi({this.loadResult});
  final Future<EnergyPrioritySnapshot>? loadResult;
  int readbacks = 0;
  @override
  Future<EnergyPrioritySnapshot> load() =>
      loadResult ?? Future.value(snapshot());
  @override
  Future<EnergyCommandPreview> preview(
    EnergyPrioritySnapshot value,
    EnergyPlanSlot slot,
  ) async => EnergyCommandPreview(
    requestId: '88888888888888888888888888888888',
    planId: value.planId,
    inputDigest: value.inputDigest,
    coreId: value.coreId,
    homeId: value.homeId,
    accountId: value.accountId,
    sessionFamilyId: value.sessionFamilyId,
    inverterId: value.inverterId!,
    inverterRevision: value.inverterRevision!,
    batteryId: value.batteryId,
    batteryRevision: value.batteryRevision,
    targetPowerW: slot.powerW,
    confirmationToken:
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  );
  @override
  Future<EnergyCommandResult> confirm(EnergyCommandPreview value) async =>
      EnergyCommandResult(
        requestId: value.requestId,
        verified: true,
        targetPowerW: value.targetPowerW,
        observedPowerW: value.targetPowerW,
      );
  @override
  Future<EnergyCommandResult> readback(EnergyCommandPreview value) async {
    readbacks++;
    return EnergyCommandResult(
      requestId: value.requestId,
      verified: true,
      targetPowerW: value.targetPowerW,
      observedPowerW: value.targetPowerW,
    );
  }
}
