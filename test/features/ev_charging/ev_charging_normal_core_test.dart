import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/ev_charging/data/ev_charging_api.dart';
import 'package:larenor/features/ev_charging/domain/ev_charging_models.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

final class _Store implements ServerSessionPersistence {
  _Store(this.value);
  ServerSession? value;
  @override
  Future<ServerSession?> read() async => value;
  @override
  Future<void> write(ServerSession? session) async => value = session;
}

void main() {
  final url = Platform.environment['LARENOR_EV_CORE_URL'];
  final phase = Platform.environment['LARENOR_EV_PHASE'];
  setUpAll(() => HttpOverrides.global = null);
  test(
    'real Client reconciles evcc lost ACK and durable receipt after Core restart',
    () async {
      final file = File(Platform.environment['LARENOR_EV_STATE_FILE']!);
      Map<String, dynamic>? saved;
      ServerSession? restored;
      if (phase == 'restart') {
        saved = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        // Only the owned Core listener port changes; the same real session family
        // is revalidated by production account.initialize against restarted Core.
        final storage =
            jsonDecode(saved['session'] as String) as Map<String, dynamic>;
        storage['baseUrl'] = url;
        restored = ServerSession.decodeStorage(jsonEncode(storage));
      }
      final account = ServerAccountController(store: _Store(restored));
      addTearDown(account.dispose);
      if (restored == null) {
        await account.signIn(
          baseUrl: url!,
          username: 'admin',
          password: 'Synthetic new password 2026',
          deviceName: 'EV acceptance',
        );
      } else {
        await account.initialize();
      }
      expect(account.failure, isNull);
      expect(account.session, isNotNull);
      var current = true;
      final gateway = AccountEvChargingGateway(
        account: account,
        isCurrent: () => current,
      );
      addTearDown(gateway.retire);
      final capability = await gateway.capability();
      expect(capability.providerKind, 'evcc');
      expect(capability.canPlan, isTrue);
      expect(capability.canControl, isTrue);
      late EvChargePlan plan;
      if (phase == 'confirm') {
        plan = await gateway.preview(
          charger: capability.chargers.single,
          previewId: 'e' * 32,
          departure: DateTime.fromMillisecondsSinceEpoch(
            int.parse(Platform.environment['LARENOR_EV_DEPARTURE_MS']!),
            isUtc: true,
          ),
          targetSoc: 42,
        );
        expect(plan.slots.single.currentAmp, 8);
        expect(plan.slots.single.tariffMicrosPerKwh, -50000);
        final receipt = await gateway.confirm(plan, 'f' * 32);
        expect(receipt.status, 'uncertain');
        expect(receipt.targetCurrentAmp, 8);
        expect((await gateway.confirm(plan, 'f' * 32)).status, 'uncertain');
        final verified = await gateway.result(plan, 'f' * 32);
        expect(verified.status, 'verified');
        expect(verified.observedCurrentAmp, 8);
        expect(verified.observedAt, isNotNull);
        await file.writeAsString(
          jsonEncode({
            'session': account.session!.encodeStorage(),
            'plan': {
              'coreId': plan.coreId,
              'homeId': plan.homeId,
              'chargerId': plan.chargerId,
              'accountId': plan.accountId,
              'sessionFamilyId': plan.sessionFamilyId,
              'previewId': plan.previewId,
              'planHash': plan.planHash,
              'chargerRevision': plan.chargerRevision,
              'scheduleRevision': plan.scheduleRevision,
              'requiredWh': plan.requiredWh,
              'status': plan.status,
            },
          }),
        );
      } else {
        final raw = saved!['plan'] as Map<String, dynamic>;
        plan = EvChargePlan(
          coreId: raw['coreId'] as String,
          homeId: raw['homeId'] as String,
          chargerId: raw['chargerId'] as String,
          accountId: raw['accountId'] as String,
          sessionFamilyId: raw['sessionFamilyId'] as String,
          previewId: raw['previewId'] as String,
          planHash: raw['planHash'] as String,
          chargerRevision: raw['chargerRevision'] as int,
          scheduleRevision: raw['scheduleRevision'] as int,
          requiredWh: raw['requiredWh'] as int,
          status: raw['status'] as String,
          slots: const [],
        );
        expect((await gateway.result(plan, 'f' * 32)).status, 'verified');
        expect((await gateway.confirm(plan, 'f' * 32)).status, 'verified');
      }
      current = false;
      await expectLater(
        gateway.confirm(plan, '1' * 32),
        throwsA(
          isA<LarenorServerException>().having(
            (e) => e.code,
            'code',
            'cancelled',
          ),
        ),
      );
    },
    skip: url == null
        ? 'Run with server/tests/support/f46_flutter_acceptance.py'
        : false,
  );
}
