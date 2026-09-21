import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/workshop/data/workshop_controller.dart';
import 'package:larenor/features/workshop/domain/workshop_models.dart';

WorkshopPrinter printer({bool safe = true}) => WorkshopPrinter.fixture(
  id: 'd' * 32,
  name: 'Workshop printer',
  availableActions: safe
      ? const [WorkshopAction.pause, WorkshopAction.cancel]
      : const [],
  safety: WorkshopSafety.fixture(
    connectivity: safe
        ? WorkshopConnectivity.online
        : WorkshopConnectivity.offline,
  ),
);

final class _Gateway implements WorkshopGateway {
  List<WorkshopPrinter> values;
  _Gateway(this.values);
  int previews = 0, confirmations = 0;
  Completer<List<WorkshopPrinter>>? delayedLoad;

  @override
  Future<List<WorkshopPrinter>> load() => delayedLoad?.future ?? Future.value(values);

  @override
  Future<WorkshopPreview> preview({
    required WorkshopPrinter printer,
    required WorkshopAction action,
    required String requestKey,
  }) async {
    previews++;
    return WorkshopPreview.fixture(printer: printer, action: action);
  }

  @override
  Future<WorkshopIntentReceipt> confirm(WorkshopPreview preview) async {
    confirmations++;
    return WorkshopIntentReceipt.fixture(preview: preview);
  }

  @override
  void retire() {}
}

void main() {
  test('preview and confirmation are separate single-flight user actions', () async {
    final gateway = _Gateway([printer()]);
    final controller = WorkshopController(
      gateway: gateway,
      isCurrent: () => true,
      requestKey: () => 'pause-request-key-0001',
    );
    await controller.refresh();
    final preview = await controller.requestAction(
      controller.printers.single,
      WorkshopAction.pause,
    );
    expect(preview, isNotNull);
    expect(gateway.previews, 1);
    expect(gateway.confirmations, 0);
    expect(await controller.confirm(preview!), isTrue);
    expect(gateway.confirmations, 1);
    expect(controller.lastReceipt?.effect, WorkshopIntentEffect.notDispatched);
    expect(await controller.confirm(preview), isFalse);
    expect(gateway.confirmations, 1);
  });

  test('hazard state and late authority never create or accept an action', () async {
    var current = true;
    final gateway = _Gateway([printer(safe: false)]);
    final controller = WorkshopController(
      gateway: gateway,
      isCurrent: () => current,
      requestKey: () => 'pause-request-key-0001',
    );
    await controller.refresh();
    expect(
      await controller.requestAction(
        controller.printers.single,
        WorkshopAction.pause,
      ),
      isNull,
    );
    expect(gateway.previews, 0);

    gateway.values = [printer()];
    gateway.delayedLoad = Completer<List<WorkshopPrinter>>();
    final late = controller.refresh();
    current = false;
    gateway.delayedLoad!.complete(gateway.values);
    await late;
    expect(controller.printers, isEmpty);
    expect(controller.failure, WorkshopFailure.staleAuthority);
  });
}
