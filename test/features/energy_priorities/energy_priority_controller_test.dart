import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/energy_priorities/data/energy_priority_controller.dart';
import 'package:larenor/features/energy_priorities/domain/energy_priority_models.dart';

void main() {
  test('preview confirm succeeds only after exact readback', () async {
    final api = FakeEnergyPriorityApi();
    final controller = EnergyPriorityController(api: api, isCurrent: () => true);
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
    final controller = EnergyPriorityController(api: api, isCurrent: () => current);
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

EnergyPrioritySnapshot snapshot({bool canControl = true}) => EnergyPrioritySnapshot.fixture(
  canControl: canControl,
  reservePercent: 40,
  stateOfChargePercent: 50,
  solarEnergyWh: 3000,
  consumptionEnergyWh: 1000,
);

final class FakeEnergyPriorityApi implements EnergyPriorityApi {
  FakeEnergyPriorityApi({this.loadResult});
  final Future<EnergyPrioritySnapshot>? loadResult;
  int readbacks = 0;
  @override
  Future<EnergyPrioritySnapshot> load() => loadResult ?? Future.value(snapshot());
  @override
  Future<EnergyCommandPreview> preview(EnergyPrioritySnapshot value, EnergyPlanSlot slot) async =>
      EnergyCommandPreview.fixture(value: value, slot: slot);
  @override
  Future<EnergyCommandResult> confirm(EnergyCommandPreview value) async =>
      EnergyCommandResult.fixture(value: value);
  @override
  Future<EnergyCommandResult> readback(EnergyCommandPreview value) async {
    readbacks++;
    return EnergyCommandResult.fixture(value: value);
  }
}
