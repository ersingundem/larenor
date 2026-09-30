import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/energy_priorities/data/core_energy_priority_api.dart';
import 'package:larenor/features/energy_priorities/data/energy_priority_controller.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/services/data/server_services_api.dart';
import 'package:larenor/features/server/services/domain/server_service_models.dart';

final class _Store implements ServerSessionPersistence {
  @override
  Future<ServerSession?> read() async => null;

  @override
  Future<void> write(ServerSession? value) async {}
}

Future<ServerAccountController> _account(String url) async {
  final account = ServerAccountController(store: _Store());
  await account.signIn(
    baseUrl: url,
    username: 'admin',
    password: 'Synthetic new password 2026',
    deviceName: 'F47 acceptance',
  );
  expect(account.failure, isNull);
  expect(account.session, isNotNull);
  return account;
}

void main() {
  final url = Platform.environment['LARENOR_F47_CORE_URL'];
  final phase = Platform.environment['LARENOR_F47_PHASE'];
  final entity = Platform.environment['LARENOR_F47_ENTITY'];
  setUpAll(() => HttpOverrides.global = null);
  tearDownAll(() => HttpOverrides.global = null);

  test('actual Client configures and reads F47 through normal Core and owned providers', () async {
    if (url == null || phase == null || entity == null) {
      markTestSkipped(
        'Run with server/tests/support/f47_flutter_acceptance.py',
      );
      return;
    }
    expect(const {'setup', 'restart'}, contains(phase));
    final account = await _account(url);
    addTearDown(account.dispose);
    final services = await account.withSession(
      (core, session) => ServerServicesApi(core, session.accessToken).list(),
    );
    expect(
      services.where(
        (service) =>
            service.kind == ServerServiceKind.homeAssistant &&
            service.verification.state ==
                ServerServiceVerificationState.authenticated,
      ),
      hasLength(1),
    );
    var current = true;
    final api = CoreEnergyPriorityApi(
      account: account,
      isCurrent: () => current,
      random: Random(47),
    );
    addTearDown(api.retire);
    final controller = EnergyPriorityController(
      api: api,
      reserveSetupApi: api,
      isCurrent: () => current,
    );
    addTearDown(controller.dispose);

    await controller.load();
    expect(controller.state, EnergyPriorityViewState.ready);
    expect(controller.snapshot!.reservePercent, 40);
    expect(controller.snapshot!.stateOfChargePercent, 55);
    expect(controller.snapshot!.solarEnergyWh, 5000);
    expect(controller.snapshot!.consumptionEnergyWh, 1000);

    if (phase == 'setup') {
      expect(controller.snapshot!.canSetReserve, isFalse);
      expect(controller.reserveSources, hasLength(1));
      expect(controller.reserveSources.single.boundModel, isNull);
      await controller.acceptReserveSource(entity);
      expect(controller.reserveSetupFailure, isNull);
      expect(controller.snapshot!.canSetReserve, isTrue);
      expect(controller.snapshot!.canCharge, isFalse);
      expect(controller.snapshot!.canDischarge, isFalse);
      await controller.previewReserve();
      expect(controller.state, EnergyPriorityViewState.awaitingConfirmation);
      await controller.confirmReserve();
      expect(controller.state, EnergyPriorityViewState.verified);
      expect(controller.reservePending!.targetReservePercent, 40);
      return;
    }

    expect(controller.snapshot!.canSetReserve, isTrue);
    expect(controller.snapshot!.canCharge, isFalse);
    expect(controller.snapshot!.canDischarge, isFalse);
    await controller.previewReserve();
    expect(controller.state, EnergyPriorityViewState.awaitingConfirmation);

    // Drift the real Core home revision after preview. The exact old command
    // must fail before Home Assistant receives another mutation.
    await account.withSession((core, session) async {
      final context = session.context!;
      await core.request(
        'POST',
        '/admin/home-resources/${context.coreId}/${context.homeId}',
        token: session.accessToken,
        body: {'kind': 'resource', 'label': 'F47 drift', 'order': 0},
      );
    });
    await controller.confirmReserve();
    expect(controller.state, EnergyPriorityViewState.failed);

    current = false;
    api.retire();
    await expectLater(
      api.load(),
      throwsA(
        isA<LarenorServerException>().having(
          (error) => error.code,
          'code',
          'cancelled',
        ),
      ),
    );
  });
}
