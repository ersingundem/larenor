import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/workshop/data/workshop_api.dart';
import 'package:larenor/features/workshop/data/workshop_controller.dart';
import 'package:larenor/features/workshop/domain/workshop_models.dart';

final class _Store implements ServerSessionPersistence {
  @override
  Future<ServerSession?> read() async => null;
  @override
  Future<void> write(ServerSession? value) async {}
}

void main() {
  final url = Platform.environment['LARENOR_WORKSHOP_CORE_URL'];
  final phase = Platform.environment['LARENOR_WORKSHOP_PHASE'];
  setUpAll(() => HttpOverrides.global = null);

  test(
    'actual Client onboards and controls the normal Core printer provider',
    () async {
      final account = ServerAccountController(store: _Store());
      addTearDown(account.dispose);
      await account.signIn(
        baseUrl: url!,
        username: 'admin',
        password: 'Synthetic new password 2026',
        deviceName: 'Workshop acceptance',
      );
      expect(account.failure, isNull);
      final gateway = AccountWorkshopGateway(
        account: account,
        isCurrent: () => true,
      );
      final controller = WorkshopController(
        gateway: gateway,
        isCurrent: () => true,
        requestKey: () => '59595959595959595959595959595959',
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      final service = controller.services.single;
      expect(service.name, 'Actual OctoPrint');
      expect(await controller.register(service, 'Kitchen printer'), isTrue);
      final printer = controller.printers.single;
      expect(printer.id, service.id);
      expect(printer.material.kind, WorkshopMaterialKind.unknown);
      expect(printer.material.remainingGrams, isNull);

      if (phase == 'prepare') {
        final current = (await gateway.load()).single;
        expect(current.availableActions, contains(WorkshopAction.pause));
        final preview = await gateway.preview(
          printer: current,
          action: WorkshopAction.pause,
          requestKey: 'f59-client-pause-request-0001',
        );
        final receipt = await gateway.confirm(preview);
        expect(receipt.effect, WorkshopIntentEffect.applied);
        final replay = await gateway.confirm(preview);
        expect(replay.id, receipt.id);
        expect(replay.execution?.commandId, receipt.execution?.commandId);
      } else {
        expect(phase, 'restart');
        final current = (await gateway.load()).single;
        expect(current.id, printer.id);
        expect(current.job.state, WorkshopJobState.paused);
        expect(current.availableActions, [WorkshopAction.cancel]);
      }
    },
    skip: url == null || phase == null
        ? 'Requires explicit isolated normal Core runner'
        : false,
  );
}
