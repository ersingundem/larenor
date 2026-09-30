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

  test('reserve-only capability confirms exact percent readback', () async {
    final api = FakeEnergyPriorityApi(reserveOnly: true);
    final controller = EnergyPriorityController(
      api: api,
      isCurrent: () => true,
    );
    await controller.load();
    expect(controller.snapshot!.canCharge, isFalse);
    await controller.previewReserve();
    expect(controller.state, EnergyPriorityViewState.awaitingConfirmation);
    await controller.confirmReserve();
    expect(controller.state, EnergyPriorityViewState.verified);
    expect(api.reserveReadbacks, 1);
    controller.dispose();
  });

  test('verified source setup reloads reserve capability once', () async {
    final api = FakeEnergyPriorityApi();
    final setup = FakeReserveSetupApi(api);
    final controller = EnergyPriorityController(
      api: api,
      reserveSetupApi: setup,
      isCurrent: () => true,
    );
    await controller.load();
    expect(controller.reserveSources, hasLength(1));
    await controller.acceptReserveSource(
      'number.gen24_battery_minimum_reserve',
    );
    expect(setup.accepts, 1);
    expect(controller.snapshot!.canSetReserve, isTrue);
    controller.dispose();
  });
}

EnergyPrioritySnapshot snapshot({
  bool canControl = true,
  bool canCharge = true,
  bool canSetReserve = false,
}) => EnergyPrioritySnapshot(
  coreId: '11111111111111111111111111111111',
  homeId: '22222222222222222222222222222222',
  accountId: '33333333333333333333333333333333',
  sessionFamilyId: '44444444444444444444444444444444',
  homeRevision: 1,
  accountRevision: 1,
  canAdminister: true,
  canControl: canControl,
  canCharge: canControl && canCharge,
  canDischarge: canControl && canCharge,
  canSetReserve: canControl && canSetReserve,
  planId: '55555555555555555555555555555555',
  inputDigest:
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  batteryId: '66666666666666666666666666666666',
  batteryRevision: 1,
  batteryProviderRevision: 3,
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
  FakeEnergyPriorityApi({this.loadResult, this.reserveOnly = false});
  final Future<EnergyPrioritySnapshot>? loadResult;
  bool reserveOnly;
  int readbacks = 0;
  int reserveReadbacks = 0;
  @override
  Future<EnergyPrioritySnapshot> load() =>
      loadResult ??
      Future.value(
        snapshot(canCharge: !reserveOnly, canSetReserve: reserveOnly),
      );
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

  @override
  Future<EnergyReservePreview> previewReserve(
    EnergyPrioritySnapshot value,
  ) async => EnergyReservePreview(
    requestId: '99999999999999999999999999999999',
    inputDigest: value.inputDigest,
    coreId: value.coreId,
    homeId: value.homeId,
    accountId: value.accountId,
    sessionFamilyId: value.sessionFamilyId,
    inverterId: value.inverterId!,
    inverterRevision: value.inverterRevision!,
    batteryId: value.batteryId,
    batteryRevision: value.batteryRevision,
    batteryProviderRevision: value.batteryProviderRevision,
    targetReservePercent: value.reservePercent,
    confirmationToken:
        'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
  );
  @override
  Future<EnergyReserveResult> confirmReserve(
    EnergyReservePreview value,
  ) async => EnergyReserveResult(
    requestId: value.requestId,
    confirmed: true,
    targetReservePercent: value.targetReservePercent,
    observedReservePercent: value.targetReservePercent,
    bindingRevision: 1,
  );
  @override
  Future<EnergyReserveResult> readbackReserve(
    EnergyReservePreview value,
  ) async {
    reserveReadbacks++;
    return EnergyReserveResult(
      requestId: value.requestId,
      confirmed: true,
      targetReservePercent: value.targetReservePercent,
      observedReservePercent: value.targetReservePercent,
      bindingRevision: 1,
    );
  }
}

final class FakeReserveSetupApi implements EnergyReserveSetupApi {
  FakeReserveSetupApi(this.energy);
  final FakeEnergyPriorityApi energy;
  int accepts = 0;
  final source = const EnergyReserveSource(
    serviceId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    serviceRevision: 2,
    name: 'Home Assistant',
    bindingRevision: 0,
    boundModel: null,
  );

  @override
  Future<List<EnergyReserveSource>> loadReserveSources(
    EnergyPrioritySnapshot snapshot,
  ) async => [source];

  @override
  Future<void> acceptReserveSource(
    EnergyPrioritySnapshot snapshot,
    EnergyReserveSource source,
    String entityId,
  ) async {
    expect(source, same(this.source));
    expect(entityId, 'number.gen24_battery_minimum_reserve');
    accepts++;
    energy.reserveOnly = true;
  }
}
