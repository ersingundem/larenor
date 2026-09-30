import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/core_ha/data/core_ha_api.dart';
import 'package:larenor/features/core_ha/domain/core_ha_models.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

final class _Store implements ServerSessionPersistence {
  @override
  Future<ServerSession?> read() async => null;

  @override
  Future<void> write(ServerSession? session) async {}
}

Map<String, dynamic> _object(Object? value) {
  if (value is! Map) throw const FormatException('invalid_fixture');
  return value.map((key, child) => MapEntry(key as String, child));
}

void _arbitrationSnapshot(
  Map<String, dynamic>? body, {
  required String resourceId,
}) {
  final value = _object(body);
  expect(
    value.keys.toSet(),
    containsAll(<String>{
      'schemaVersion',
      'activeOwnership',
      'externalObservations',
      'externalWritesAreObservedOnly',
    }),
  );
  expect(value['schemaVersion'], 1);
  expect(value['externalWritesAreObservedOnly'], isTrue);
  final ownership = value['activeOwnership'] as List<dynamic>;
  expect(ownership, hasLength(1));
  final owner = _object(ownership.single);
  expect(owner['deviceId'], resourceId);
  expect(owner['source'], 'manual');
  expect(owner['action'], 'turn_on');
  final observations = value['externalObservations'] as List<dynamic>;
  expect(observations, hasLength(1));
  final observed = _object(observations.single);
  expect(observed['deviceId'], resourceId);
  expect(observed['controlMode'], 'observed_only');
  expect(observed['authoritative'], isFalse);
}

Future<void> _assertSuppressedDecision(
  LarenorServerApi transport,
  String token,
  String arbitrationPath, {
  required String resourceId,
  required String ruleId,
  required String requestId,
}) async {
  final result = await transport.request(
    'POST',
    '$arbitrationPath/rules',
    token: token,
    body: {
      'schemaVersion': 1,
      'requestKey': 'ha-rule:$requestId',
      'deviceId': resourceId,
      'expectedDeviceRevision': 1,
      'action': 'turn_off',
      'ruleId': ruleId,
      'expectedRuleRevision': 1,
      'priority': 50,
      'leaseSeconds': 30,
    },
  );
  final decision = _object(result?['decision']);
  expect(decision['deviceId'], resourceId);
  expect(decision['source'], 'rule');
  expect(decision['state'], 'suppressed');
  expect(decision['reason'], 'active_manual');
  expect(decision['shouldWrite'], isFalse);
  expect(decision['effectToken'], isNull);
}

Future<void> _suppressed(Future<Map<String, dynamic>?> request) async {
  try {
    await request;
  } on LarenorServerException catch (error) {
    // The generic transport deliberately collapses an unlisted 409 code to
    // conflict. The arbiter snapshot below proves the exact suppression cause.
    expect(error.code, 'conflict');
    return;
  }
  fail('suppressed rule unexpectedly reached the provider');
}

void main() {
  final coreUrl = Platform.environment['LARENOR_F04_CORE_URL'];
  final phase = Platform.environment['LARENOR_F04_PHASE'];
  final fixturePath = Platform.environment['LARENOR_F04_FIXTURE'];

  setUpAll(() => HttpOverrides.global = null);

  test(
    'real Client keeps manual ownership across rule suppression and restart',
    () async {
      final fixture = _object(
        jsonDecode(await File(fixturePath!).readAsString()),
      );
      final account = ServerAccountController(store: _Store());
      addTearDown(account.dispose);
      await account.signIn(
        baseUrl: coreUrl!,
        username: 'admin',
        password: 'Synthetic new password 2026',
        deviceName: 'F04 arbitration acceptance',
      );
      expect(account.failure, isNull);

      final resource = _object(fixture['resource']);
      final ref = _object(resource['ref']);
      final expectedContext = ServerContext.fromJson({
        'schemaVersion': ref['schemaVersion'],
        'coreId': ref['coreId'],
        'homeId': ref['homeId'],
      });
      final target = HomeResourceRecord.fromJson(
        resource,
        expectedContext: expectedContext,
      );
      final ruleId = fixture['ruleId'] as String;
      final manualRequestId = fixture['manualRequestId'] as String;
      final ruleRequestId = fixture['ruleRequestId'] as String;
      final scope = '${target.context.coreId}/${target.context.homeId}';
      final rulePath =
          '/home-assistant/$scope/resources/${target.id}/rules/$ruleId/executions';
      final arbitrationPath = '/rule-arbitration/$scope';

      await account.withSession((transport, session) async {
        var current = true;
        final api = CoreHaApi(
          transport,
          session.accessToken,
          target,
          isCurrent: () => current,
        );
        addTearDown(() {
          current = false;
          api.retire();
        });

        if (phase == 'manual-suppress') {
          final before = await api.snapshot();
          expect(before.projection.state, CoreHaSwitchState.off);
          final receipt = await api.command(
            requestId: manualRequestId,
            action: CoreHaCommandAction.turnOn,
            snapshot: before,
          );
          expect(receipt.dispatchState, CoreHaDispatchState.accepted);
          expect(receipt.observationMatchesTarget, isTrue);

          await _suppressed(
            transport.request(
              'POST',
              rulePath,
              token: session.accessToken,
              body: {
                'schemaVersion': 1,
                'requestId': ruleRequestId,
                'expectedRuleRevision': 1,
              },
            ),
          );
          await _assertSuppressedDecision(
            transport,
            session.accessToken,
            arbitrationPath,
            resourceId: target.id,
            ruleId: ruleId,
            requestId: ruleRequestId,
          );
          final observation = await transport.request(
            'POST',
            '$arbitrationPath/external-observations',
            token: session.accessToken,
            body: {
              'schemaVersion': 1,
              'observationId': List.filled(32, '7').join(),
              'deviceId': target.id,
              'providerRevision': 2,
              'action': 'turn_off',
              'observedAt': 1788609600.0,
              'origin': 'home_assistant',
            },
          );
          final observed = _object(observation?['observation']);
          expect(observed['controlMode'], 'observed_only');
          expect(observed['authoritative'], isFalse);
        } else {
          expect(phase, 'restart');
          final retained = await api.commandResult(manualRequestId);
          expect(retained.dispatchState, CoreHaDispatchState.accepted);
          expect(retained.observationMatchesTarget, isTrue);
          final currentSnapshot = await api.snapshot();
          expect(currentSnapshot.projection.state, CoreHaSwitchState.on);

          // Exact replay after a Core restart remains suppressed and never
          // becomes a second provider write.
          await _suppressed(
            transport.request(
              'POST',
              rulePath,
              token: session.accessToken,
              body: {
                'schemaVersion': 1,
                'requestId': ruleRequestId,
                'expectedRuleRevision': 1,
              },
            ),
          );
          await _assertSuppressedDecision(
            transport,
            session.accessToken,
            arbitrationPath,
            resourceId: target.id,
            ruleId: ruleId,
            requestId: ruleRequestId,
          );
        }

        _arbitrationSnapshot(
          await transport.request(
            'GET',
            arbitrationPath,
            token: session.accessToken,
          ),
          resourceId: target.id,
        );
      });
    },
    skip: coreUrl == null || phase == null || fixturePath == null
        ? 'Requires the isolated F04 normal Core runner'
        : false,
  );
}
