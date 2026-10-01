import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/power_budget/data/power_budget_api.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

final class _Store implements ServerSessionPersistence {
  @override
  Future<ServerSession?> read() async => null;

  @override
  Future<void> write(ServerSession? value) async {}
}

Future<void> _signIn(ServerAccountController account, String url) async {
  await account.signIn(
    baseUrl: url,
    username: 'admin',
    password: 'Synthetic new password 2026',
    deviceName: 'F48 acceptance',
  );
  expect(account.failure, isNull);
  expect(account.session, isNotNull);
}

CorePowerBudgetApi _api(
  ServerAccountController account, {
  required bool Function() current,
}) => CorePowerBudgetApi(
  account: account,
  routeId: 'f48-power-budget-route',
  sessionRevision: account.generation,
  routeRevision: 1,
  isCurrent: current,
);

Matcher _serverCode(String code) => throwsA(
  isA<LarenorServerException>().having((error) => error.code, 'code', code),
);

Future<String> _mappedError(int status, String upstreamCode) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final serving = server.listen((request) {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write('{"error":{"code":"$upstreamCode"}}');
    unawaited(request.response.close());
  }).asFuture<void>();
  final api = LarenorServerApi(
    endpoint: ServerEndpoint('http://127.0.0.1:${server.port}'),
  );
  try {
    await api.request(
      'GET',
      '/admin/power-budget',
      token: 'f48-parser-boundary-token',
    );
    return 'unexpected_success';
  } on LarenorServerException catch (error) {
    return error.code;
  } finally {
    api.close();
    await server.close(force: true);
    await serving;
  }
}

void main() {
  final url = Platform.environment['LARENOR_F48_CORE_URL'];
  final phase = Platform.environment['LARENOR_F48_PHASE'];
  setUpAll(() => HttpOverrides.global = null);

  test('shared error parser exposes only exact F48 code and status', () async {
    expect(
      await _mappedError(409, 'critical_load_protection'),
      'critical_load_protection',
    );
    expect(
      await _mappedError(400, 'critical_load_protection'),
      'invalid_request',
    );
    expect(await _mappedError(409, 'private_provider_detail'), 'conflict');
  });

  test(
    'actual Client enforces F48 authority and causal evcc readback',
    () async {
      final account = ServerAccountController(store: _Store());
      addTearDown(account.dispose);
      await _signIn(account, url!);

      if (phase == 'critical' || phase == 'restart') {
        final api = _api(account, current: () => true);
        addTearDown(api.retire);
        await expectLater(api.load(), _serverCode('critical_load_protection'));
        return;
      }
      expect(phase, 'control');

      var routeCurrent = true;
      final routed = _api(account, current: () => routeCurrent);
      final routedSnapshot = await routed.load();
      expect(routedSnapshot.gridImportW, 15300);
      expect(routedSnapshot.gridLimitW, 8400);
      expect(routedSnapshot.requiredReductionW, 6900);
      expect(routedSnapshot.actions.single.loadId, 'evcc-lp-1');
      expect(routedSnapshot.actions.single.targetW, 4140);
      expect(
        routedSnapshot.actions.single.communicationLossBehavior,
        'hold_last_safe_limit',
      );
      routeCurrent = false;
      await expectLater(
        routed.confirm(routedSnapshot),
        _serverCode('cancelled'),
      );

      final sessionBound = _api(account, current: () => true);
      final sessionSnapshot = await sessionBound.load();
      await account.signOut();
      await expectLater(
        sessionBound.confirm(sessionSnapshot),
        _serverCode('unauthorized'),
      );

      await _signIn(account, url);
      final active = _api(account, current: () => true);
      addTearDown(active.retire);
      final snapshot = await active.load();
      final receipt = await active.confirm(snapshot);
      expect(receipt.status, 'verified');
      expect(receipt.applyCount, 1);
      expect(receipt.planHash, snapshot.planHash);
      expect(receipt.previewId, snapshot.planId);
    },
    skip: url == null || phase == null
        ? 'Requires explicit isolated F48 normal-Core runner'
        : false,
  );
}
