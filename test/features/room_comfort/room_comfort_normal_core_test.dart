import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/room_comfort/data/room_comfort_api.dart';
import 'package:larenor/features/room_comfort/data/room_comfort_controller.dart';
import 'package:larenor/features/room_comfort/data/room_comfort_source_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

final class _Store implements ServerSessionPersistence {
  @override
  Future<ServerSession?> read() async => null;

  @override
  Future<void> write(ServerSession? value) async {}
}

void main() {
  final url = Platform.environment['LARENOR_COMFORT_CORE_URL'];
  setUpAll(() => HttpOverrides.global = null);

  test(
    'Client → normal Core → HA source, exact retry, and readback receipt',
    () async {
      final account = ServerAccountController(store: _Store());
      addTearDown(account.dispose);
      await account.signIn(
        baseUrl: url!,
        username: 'admin',
        password: 'Synthetic new password 2026',
        deviceName: 'Comfort acceptance',
      );
      expect(account.failure, isNull);
      final source = AccountRoomComfortSourceApi(
        account: account,
        isCurrent: () => true,
      );
      addTearDown(source.retire);
      final setup = await source.load();
      expect(setup.configuration, isNull);
      final service = setup.services.single;
      final room = setup.rooms.singleWhere(
        (value) => value.label == 'Living room',
      );
      final area = setup.areas.singleWhere(
        (value) => value.label == 'Downstairs',
      );
      final entities = await source.entities(service);
      expect(entities.climates, contains('climate.living_room'));
      expect(entities.weather, contains('weather.home'));
      final configured = await source.save({
        'schemaVersion': 1,
        'expectedRevision': null,
        'serviceId': service.id,
        'expectedServiceRevision': service.revision,
        'weatherEntityId': 'weather.home',
        'aqiEntityId': 'sensor.outdoor_aqi',
        'targetTemperatureMilliC': 22000,
        'temperatureToleranceMilliC': 1000,
        'humidityHighPermille': 700,
        'co2HighPpm': 1000,
        'vocHighPpb': 500,
        'outdoorAqiLimit': 100,
        'freezeThresholdMilliC': 3000,
        'indoorMaxAgeMs': 60000,
        'outdoorMaxAgeMs': 120000,
        'occupancyMaxAgeMs': 60000,
        'previewTtlMs': 30000,
        'rooms': [
          {
            'roomId': room.id,
            'roomRevision': room.revision,
            'areaId': area.id,
            'areaRevision': area.revision,
            'climateEntityId': 'climate.living_room',
            'windowEntityId': 'cover.living_room_window',
            'temperatureEntityId': 'sensor.living_temperature',
            'humidityEntityId': 'sensor.living_humidity',
            'co2EntityId': 'sensor.living_co2',
            'vocEntityId': 'sensor.living_voc',
            'smokeEntityId': 'binary_sensor.living_smoke',
            'occupancyEntityId': 'binary_sensor.living_occupancy',
          },
        ],
      });
      expect(configured.revision, 1);
      expect(configured.serviceId, service.id);

      final context = account.session!.context!;
      final gateway = AccountRoomComfortGateway(
        account: account,
        isCurrent: () => true,
      );
      final controller = RoomComfortController(
        gateway: gateway,
        isCurrent: () => true,
        coreId: context.coreId,
        homeId: context.homeId,
        requestId: () => 'f' * 32,
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      expect(controller.failure, isNull);
      expect(controller.plan?.rooms.single.hvacMode.name, 'heat');
      final preview = await controller.preview();
      expect(preview, isNotNull);
      expect(preview!.expiresAt.isAfter(DateTime.now().toUtc()), isTrue);

      expect(await controller.confirm(preview), isFalse);
      expect(controller.failure, RoomComfortFailure.unavailable);
      expect(controller.previewValue, same(preview));
      expect(await controller.preview(), isNull);

      final reconciled = await controller.confirm(preview);
      expect(reconciled, isTrue);
      expect(controller.previewValue, isNull);
      expect(controller.receipt?.status, 'applied');
      expect(controller.receipt?.appliedCount, 1);
      expect(controller.receipt?.unknownCount, 0);

      await account.signOut();
      await expectLater(
        gateway.loadPlan(),
        throwsA(
          isA<LarenorServerException>().having(
            (error) => error.code,
            'code',
            'cancelled',
          ),
        ),
      );
    },
    skip: url == null ? 'Requires explicit isolated normal Core runner' : false,
  );
}
