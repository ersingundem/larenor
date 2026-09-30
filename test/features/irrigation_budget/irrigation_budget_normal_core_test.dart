import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/irrigation_budget/data/irrigation_budget_api.dart';
import 'package:larenor/features/irrigation_budget/data/irrigation_source_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

class _Store implements ServerSessionPersistence {
  @override
  Future<ServerSession?> read() async => null;

  @override
  Future<void> write(ServerSession? value) async {}
}

void main() {
  final coreUrl = Platform.environment['LARENOR_IRRIGATION_CORE_URL'];
  final controllerUrl =
      Platform.environment['LARENOR_IRRIGATION_CONTROLLER_URL'];
  final passwordMd5 =
      Platform.environment['LARENOR_IRRIGATION_CONTROLLER_PASSWORD_MD5'];

  setUpAll(() => HttpOverrides.global = null);

  test(
    'actual Flutter Client configures source and applies verified irrigation once',
    () async {
      final account = ServerAccountController(store: _Store());
      addTearDown(account.dispose);
      await account.signIn(
        baseUrl: coreUrl!,
        username: 'admin',
        password: 'Synthetic new password 2026',
        deviceName: 'Irrigation gate',
      );
      expect(account.failure, isNull);

      final sourceApi = CoreIrrigationSourceApi(
        account: account,
        isCurrent: () => true,
      );
      addTearDown(sourceApi.retire);
      final catalog = await sourceApi.load();
      expect(catalog.source, isNull);
      expect(catalog.controller, isNull);
      final service = catalog.services.single;
      final room = catalog.rooms.single;

      final source = await sourceApi.saveSource({
        'schemaVersion': 1,
        'expectedRevision': null,
        'serviceId': service.id,
        'expectedServiceRevision': service.revision,
        'weatherEntityId': 'weather.garden',
        'leakEntityId': 'binary_sensor.garden_leak',
        'dailyWaterEntityId': 'sensor.daily_irrigation_water',
        'targetMoisturePermille': 600,
        'soilMaxAgeMs': 60000,
        'safetyMaxAgeMs': 60000,
        'forecastMaxAgeMs': 21600000,
        'rainDeferralMilliMm': 4000,
        'freezeThresholdMilliC': 2000,
        'windLimitMilliMps': 12000,
        'previewTtlMs': 30000,
        'dailyLimitMl': 100000,
        'priceMicrosPerLiter': 2500000,
        'zones': [
          {
            'roomId': room.id,
            'roomRevision': room.revision,
            'valveEntityId': 'valve.back_garden',
            'soilMoistureEntityId': 'sensor.back_soil',
            'plantName': 'Tomatoes',
            'flowMlPerMinute': 4000,
            'maxDurationSeconds': 900,
          },
        ],
      });
      expect(source.revision, 1);
      expect(source.zones.single.roomId, room.id);

      final controller = await sourceApi.saveController({
        'schemaVersion': 1,
        'expectedRevision': null,
        'expectedSourceRevision': source.revision,
        'baseUrl': controllerUrl!,
        'passwordMd5': passwordMd5!,
        'stations': [
          {
            'zoneId': source.zones.single.zoneId,
            'expectedZoneRevision': source.zones.single.zoneRevision,
            'stationIndex': 0,
          },
        ],
      });
      expect(controller.revision, 1);
      expect(controller.sourceRevision, source.revision);
      expect(controller.stationIndexes[source.zones.single.zoneId], 0);

      final reloaded = await sourceApi.load();
      expect(reloaded.source!.revision, source.revision);
      expect(reloaded.controller!.revision, controller.revision);

      final api = CoreIrrigationBudgetApi(
        account: account,
        routeId: 'irrigation-normal-core-gate',
        sessionRevision: 1,
        routeRevision: 1,
        isCurrent: () => true,
      );
      addTearDown(api.retire);
      final snapshot = await api.load();
      expect(snapshot.controlCapability, 'verified_control');
      expect(snapshot.commandEndpointAvailable, isTrue);
      expect(snapshot.rainMilliMm, 1250);
      expect(snapshot.usedMl, 12500);
      expect(snapshot.plannedMl, 30000);
      expect(snapshot.zones.single.durationSeconds, 450);
      expect(snapshot.zones.single.areaName, 'Back garden');
      expect(snapshot.zones.single.plantName, 'Tomatoes');

      final preview = await api.preview(snapshot);
      final receipt = await api.confirm(preview);
      expect(receipt.status, 'applied');
      expect(receipt.results.single.status, 'applied');
      expect(receipt.results.single.flowVerified, isTrue);
      expect(receipt.results.single.deliveredMl, 30000);

      final replay = await api.confirm(preview);
      expect(replay.requestId, receipt.requestId);
      expect(replay.planId, receipt.planId);
      expect(replay.results.single.zoneId, receipt.results.single.zoneId);
      expect(replay.results.single.code, receipt.results.single.code);
      expect(replay.results.single.deliveredMl, 30000);
    },
    skip: coreUrl == null || controllerUrl == null || passwordMd5 == null
        ? 'Requires explicit isolated normal Core runner'
        : false,
  );
}
