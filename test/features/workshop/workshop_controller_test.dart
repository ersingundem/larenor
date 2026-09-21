import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/workshop/data/workshop_controller.dart';
import 'package:larenor/features/workshop/domain/workshop_models.dart';

WorkshopPrinter printer({bool safe = true}) => WorkshopPrinter(
  coreId: 'a' * 32,
  homeId: 'b' * 32,
  id: 'd' * 32,
  revision: 4,
  name: 'Workshop printer',
  service: WorkshopServiceRef(id: 'e' * 32, revision: 3),
  job: WorkshopJob(
    revision: 7,
    id: 'f' * 32,
    state: WorkshopJobState.printing,
    progressPermille: 420,
    remainingSeconds: 900,
  ),
  material: const WorkshopMaterial(
    revision: 5,
    kind: WorkshopMaterialKind.pla,
    remainingGrams: 280,
  ),
  safety: WorkshopSafety(
    revision: 9,
    connectivity: safe
        ? WorkshopConnectivity.online
        : WorkshopConnectivity.offline,
    thermal: WorkshopThermal.normal,
    filament: WorkshopFilament.available,
    door: WorkshopDoor.closed,
    emergency: WorkshopEmergency.clear,
    observedAt: DateTime.utc(2026, 9, 21),
    freshness: WorkshopFreshness.current,
  ),
  availableActions: safe
      ? const [WorkshopAction.pause, WorkshopAction.cancel]
      : const [],
);

WorkshopPreview previewFor(WorkshopPrinter printer, WorkshopAction action) =>
    WorkshopPreview(
      coreId: printer.coreId,
      homeId: printer.homeId,
      id: '1' * 32,
      printerId: printer.id,
      action: action,
      confirmationToken: 't' * 43,
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 1)),
    );

WorkshopIntentReceipt receiptFor(WorkshopPreview preview) =>
    WorkshopIntentReceipt(
      id: '2' * 32,
      sequence: 1,
      printerId: preview.printerId,
      action: preview.action,
      effect: WorkshopIntentEffect.notDispatched,
      authority: const WorkshopIntentAuthority(
        printerRevision: 4,
        serviceRevision: 3,
        jobRevision: 7,
        materialRevision: 5,
        safetyRevision: 9,
      ),
      createdAt: DateTime.now().toUtc(),
    );

final class _Gateway implements WorkshopGateway {
  List<WorkshopPrinter> values;
  _Gateway(this.values);
  int previews = 0, confirmations = 0;
  Completer<List<WorkshopPrinter>>? delayedLoad;

  @override
  Future<List<WorkshopPrinter>> load() =>
      delayedLoad?.future ?? Future.value(values);

  @override
  Future<WorkshopPreview> preview({
    required WorkshopPrinter printer,
    required WorkshopAction action,
    required String requestKey,
  }) async {
    previews++;
    return previewFor(printer, action);
  }

  @override
  Future<WorkshopIntentReceipt> confirm(WorkshopPreview preview) async {
    confirmations++;
    return receiptFor(preview);
  }

  @override
  void retire() {}
}

void main() {
  test(
    'preview and confirmation are separate single-flight user actions',
    () async {
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
      expect(
        controller.lastReceipt?.effect,
        WorkshopIntentEffect.notDispatched,
      );
      expect(await controller.confirm(preview), isFalse);
      expect(gateway.confirmations, 1);
    },
  );

  test(
    'hazard state and late authority never create or accept an action',
    () async {
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
    },
  );
}
