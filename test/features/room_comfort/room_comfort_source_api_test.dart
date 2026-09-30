import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/room_comfort/data/room_comfort_source_api.dart';

import '../server/server_admin_test_support.dart';

Map<String, Object?> _service() => {
  'id': '1' * 32,
  'name': 'Verified Home Assistant',
  'kind': 'home_assistant',
  'baseUrl': 'https://ha.fixture.invalid',
  'revision': 3,
  'credentialKeys': ['token'],
  'verification': {
    'state': 'authenticated',
    'checkedAt': '2026-09-05T08:00:00Z',
    'version': '2026.9',
  },
};

Map<String, Object?> _resource(
  String id,
  String kind,
  String label,
  int revision,
) => {
  'ref': {
    'schemaVersion': 1,
    'coreId': 'a' * 32,
    'homeId': 'b' * 32,
    'kind': kind,
    'id': id,
  },
  'label': label,
  'order': 0,
  'revision': revision,
  'aclRevision': 1,
  'permissions': {'read': true, 'write': true},
};

Map<String, Object?> _configuration() => {
  'schemaVersion': 1,
  'revision': 4,
  'serviceId': '1' * 32,
  'serviceRevision': 3,
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
      'roomId': '2' * 32,
      'roomRevision': 4,
      'areaId': '3' * 32,
      'areaRevision': 5,
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
};

void main() {
  late AdminFixture fixture;

  setUp(() async {
    fixture = AdminFixture();
    fixture.respond = (request) async {
      final path = request.url.path;
      if (request.method == 'GET' && path.endsWith('/configuration/setup')) {
        return fixture.json({
          'schemaVersion': 1,
          'services': [_service()],
          'rooms': [_resource('2' * 32, 'room', 'Living room', 4)],
          'areas': [_resource('3' * 32, 'resource', 'Downstairs', 5)],
        });
      }
      if (request.method == 'GET' && path.endsWith('/configuration')) {
        return fixture.json({
          'schemaVersion': 1,
          'configuration': _configuration(),
        });
      }
      if (request.method == 'GET' &&
          path.contains('/configuration/entities/')) {
        return fixture.json({
          'schemaVersion': 1,
          'entities': {
            'climate': ['climate.living_room'],
            'cover': ['cover.living_room_window'],
            'sensor': [
              'sensor.living_co2',
              'sensor.living_humidity',
              'sensor.living_temperature',
              'sensor.living_voc',
              'sensor.outdoor_aqi',
            ],
            'binary_sensor': [
              'binary_sensor.living_occupancy',
              'binary_sensor.living_smoke',
            ],
            'weather': ['weather.home'],
          },
        });
      }
      if (request.method == 'PUT' && path.endsWith('/configuration')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['expectedRevision'], 4);
        expect(body['serviceId'], '1' * 32);
        expect(body['rooms'], hasLength(1));
        return fixture.json({
          'schemaVersion': 1,
          'configuration': _configuration(),
        });
      }
      return fixture.defaultResponse(request);
    };
    await fixture.account.initialize();
  });

  tearDown(() => fixture.account.dispose());

  test(
    'setup and save use exact session scope and server candidates',
    () async {
      final api = AccountRoomComfortSourceApi(
        account: fixture.account,
        isCurrent: () => true,
      );
      final setup = await api.load();
      expect(setup.services.single.name, 'Verified Home Assistant');
      expect(setup.rooms.single.label, 'Living room');
      expect(setup.areas.single.label, 'Downstairs');
      expect(setup.configuration?.targetTemperatureMilliC, 22000);

      final entities = await api.entities(setup.services.single);
      expect(entities.climates, ['climate.living_room']);
      expect(entities.weather, ['weather.home']);

      final source = setup.configuration!;
      final saved = await api.save({
        'schemaVersion': 1,
        'expectedRevision': source.revision,
        'serviceId': source.serviceId,
        'expectedServiceRevision': source.serviceRevision,
        'weatherEntityId': source.weatherEntityId,
        'aqiEntityId': source.aqiEntityId,
        'targetTemperatureMilliC': source.targetTemperatureMilliC,
        'temperatureToleranceMilliC': source.temperatureToleranceMilliC,
        'humidityHighPermille': source.humidityHighPermille,
        'co2HighPpm': source.co2HighPpm,
        'vocHighPpb': source.vocHighPpb,
        'outdoorAqiLimit': source.outdoorAqiLimit,
        'freezeThresholdMilliC': source.freezeThresholdMilliC,
        'indoorMaxAgeMs': source.indoorMaxAgeMs,
        'outdoorMaxAgeMs': source.outdoorMaxAgeMs,
        'occupancyMaxAgeMs': source.occupancyMaxAgeMs,
        'previewTtlMs': source.previewTtlMs,
        'rooms': [for (final room in source.rooms) room.toJson()],
      });
      expect(saved.revision, 4);
      expect(
        fixture.calls.where(
          (call) =>
              call.url.path.contains('/room-comfort/') &&
              call.headers['authorization'] ==
                  'Bearer synthetic_admin_access_12345',
        ),
        hasLength(4),
      );
      api.retire();
    },
  );

  test('unsorted or caller-invented entity catalogs fail closed', () async {
    final api = AccountRoomComfortSourceApi(
      account: fixture.account,
      isCurrent: () => true,
    );
    final service = (await api.load()).services.single;
    fixture.respond = (request) async {
      if (request.url.path.contains('/configuration/entities/')) {
        return fixture.json({
          'schemaVersion': 1,
          'entities': {
            'climate': ['climate.z', 'climate.a'],
            'cover': <String>[],
            'sensor': <String>[],
            'binary_sensor': <String>[],
            'weather': <String>[],
          },
        });
      }
      return fixture.defaultResponse(request);
    };
    await expectLater(api.entities(service), throwsA(isA<Object>()));
  });
}
