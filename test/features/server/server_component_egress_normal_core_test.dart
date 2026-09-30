import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/component_egress/data/server_component_egress_controller.dart';
import 'package:larenor/features/server/component_egress/domain/server_component_egress_models.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/services/data/server_services_controller.dart';
import 'package:larenor/features/server/services/domain/server_service_models.dart';

final class _Store implements ServerSessionPersistence {
  _Store(this.value);
  ServerSession? value;

  @override
  Future<ServerSession?> read() async => value;

  @override
  Future<void> write(ServerSession? session) async => value = session;
}

void main() {
  final coreUrl = Platform.environment['LARENOR_F13_CORE_URL'];
  final phase = Platform.environment['LARENOR_F13_PHASE'];
  setUpAll(() => HttpOverrides.global = null);

  test(
    'real Client pins, probes and reloads one component egress policy',
    () async {
      final stateFile = File(Platform.environment['LARENOR_F13_STATE_FILE']!);
      Map<String, dynamic>? saved;
      ServerSession? restored;
      if (phase == 'restart') {
        saved =
            jsonDecode(await stateFile.readAsString()) as Map<String, dynamic>;
        final storage =
            jsonDecode(saved['session'] as String) as Map<String, dynamic>;
        storage['baseUrl'] = coreUrl;
        restored = ServerSession.decodeStorage(jsonEncode(storage));
      }
      final account = ServerAccountController(store: _Store(restored));
      addTearDown(account.dispose);
      if (restored == null) {
        await account.signIn(
          baseUrl: coreUrl!,
          username: 'admin',
          password: 'Synthetic new password 2026',
          deviceName: 'F13 acceptance',
        );
      } else {
        await account.initialize();
      }
      expect(account.failure, isNull);
      expect(account.session, isNotNull);

      var current = true;
      final services = ServerServicesController(account);
      addTearDown(services.dispose);
      await services.load(current: () => current);
      expect(services.failure, isNull);

      late ServerService service;
      if (phase == 'configure') {
        expect(services.services, isEmpty);
        await services.save(
          name: 'Owned Home Assistant',
          kind: ServerServiceKind.homeAssistant,
          baseUrl: Platform.environment['LARENOR_F13_HA_URL']!,
          credentials: const {'token': 'f13-owned-token'},
          current: () => current,
        );
        expect(services.failure, isNull);
        service = services.services.single;
      } else {
        service = services.services.singleWhere(
          (value) => value.id == saved!['serviceId'],
        );
        expect(
          service.verification.state,
          ServerServiceVerificationState.authenticated,
        );
      }

      final egress = ServerComponentEgressController(account, service);
      addTearDown(egress.dispose);
      await egress.load(current: () => current);
      expect(egress.failure, isNull);

      if (phase == 'configure') {
        expect(egress.value!.policy.revision, 0);
        expect(egress.value!.policy.grants, isEmpty);
        await egress.resolve(current: () => current);
        expect(egress.failure, isNull);
        final grant = egress.resolution!.grant;
        expect(grant.host, Uri.parse(service.baseUrl).host);
        expect(grant.addresses.single.network, ServerEgressNetwork.lan);
        await egress.replace(grant: grant, current: () => current);
        expect(egress.failure, isNull);
        expect(egress.value!.policy.revision, 1);
        expect(egress.value!.policy.grants, [grant]);

        await services.check(service, current: () => current);
        expect(services.failure, isNull);
        service = services.services.single;
        expect(
          service.verification.state,
          ServerServiceVerificationState.authenticated,
        );
        await egress.load(current: () => current);
        expect(egress.value!.audit.map((value) => value.reason), [
          ServerEgressReason.policyReplaced,
          ServerEgressReason.dispatchAuthorized,
          ServerEgressReason.probeCompleted,
        ]);
        await stateFile.writeAsString(
          jsonEncode({
            'session': account.session!.encodeStorage(),
            'serviceId': service.id,
          }),
        );
      } else {
        expect(egress.value!.policy.revision, 1);
        expect(egress.value!.policy.grants, hasLength(1));
        expect(egress.value!.audit, hasLength(3));

        await services.check(service, current: () => current);
        expect(services.failure, isNull);
        await egress.load(current: () => current);
        expect(egress.value!.audit, hasLength(5));
        expect(
          egress.value!.audit
              .where(
                (value) => value.reason == ServerEgressReason.probeCompleted,
              )
              .length,
          2,
        );

        await egress.replace(current: () => current);
        expect(egress.failure, isNull);
        expect(egress.value!.policy.grants, isEmpty);
        await services.check(service, current: () => current);
        expect(services.failure, 'forbidden');
        expect(services.needsRefresh, isTrue);

        current = false;
        egress.invalidate();
        await egress.load(current: () => current);
        expect(egress.value, isNull);
      }
    },
    skip: coreUrl == null
        ? 'Run with server/tests/support/f13_flutter_acceptance.py'
        : false,
  );
}
