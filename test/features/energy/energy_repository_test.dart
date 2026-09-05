import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/energy/data/energy_repository.dart';
import 'package:larenor/features/energy/domain/energy_models.dart';
import 'package:larenor/features/ha_client/data/ha_api_exception.dart';

import 'energy_fixture.dart';

class _NullPreferencesApi extends FakeEnergyApi {
  @override
  Future<Object?> getPreferences() async => null;
}

void main() {
  test(
    'null preferences are invalid, never unconfigured or silently empty',
    () async {
      final result = await EnergyRepository(
        api: _NullPreferencesApi(),
        now: () => energyNow,
      ).load(EnergyRange.today, isCurrent: () => true);
      expect(result.energyConfigured, isNull);
      expect(
        result.issues.map((issue) => issue.failure),
        contains(EnergyFailure.invalidResponse),
      );
      expect(result.costsConfigurationKnown, isFalse);
    },
  );
  test('failed information preserves direct flow but leaves cost configuration unknown', () async {
    final api = FakeEnergyApi()..infoError = TimeoutException('fixture');
    final result = await EnergyRepository(
      api: api,
      now: () => energyNow,
    ).load(EnergyRange.today, isCurrent: () => true);
    expect(result.meters.single.reportedTotal, 3);
    expect(result.costsConfigured, isFalse);
    expect(result.costsConfigurationKnown, isFalse);
  });
  for (final zone in ['Europe/Berlin', 'Asia/Kathmandu']) {
    test(
      'numeric recorder wire rows match $zone day boundaries after timezone conversion',
      () async {
        final api = FakeEnergyApi(now: DateTime.utc(2026, 3, 29, 12))
          ..timeZone = zone;
        final result = await EnergyRepository(
          api: api,
          now: () => api.now,
        ).load(EnergyRange.today, isCurrent: () => true);
        expect(result.meters.single.reportedTotal, 3);
        expect(
          result.meters.single.coverageIssues,
          isNot(contains(EnergyCoverageIssue.missingDay)),
        );
      },
    );
  }
  Future<EnergySnapshot> load(FakeEnergyApi api) => EnergyRepository(
    api: api,
    now: () => api.now,
  ).load(EnergyRange.today, isCurrent: () => true);
  test('server-converted Wh metadata does not cause a second conversion or tariff estimate', () async {
    final api = FakeEnergyApi()
      ..metadata['sensor.grid'] = energyMetadata('sensor.grid', unit: 'Wh');
    final result = await load(api);
    expect(result.meters.single.unit, 'kWh');
    expect(result.meters.single.reportedTotal, 3);
    expect(result.meters.single.coverageIssues, {EnergyCoverageIssue.ongoing});
    expect(result.energyConfigured, isTrue);
    expect(result.costsConfigured, isFalse);
  });
  test('only HA not_found means unconfigured; permission and transport remain errors', () async {
    final missing = await load(
      FakeEnergyApi()
        ..prefsError = HaApiException('not found', code: 'not_found'),
    );
    expect(missing.energyConfigured, isFalse);
    expect(missing.issues, isEmpty);
    for (final error in [
      HaApiException('fixture-secret', statusCode: 401),
      HaApiException('fixture-secret', statusCode: 403),
      TimeoutException('fixture-secret'),
    ]) {
      final api = FakeEnergyApi()..prefsError = error;
      final result = await load(api);
      expect(result.energyConfigured, isNull);
      expect(result.issues, isNotEmpty);
      expect(api.calls, isNot(contains('metadata')));
      expect(result.issues.toString(), isNot(contains('fixture-secret')));
    }
  });
  test('invalid timezone prevents any statistics request and is never device-local fallback', () async {
    final api = FakeEnergyApi()..timeZone = 'Unknown/Fixture';
    final result = await load(api);
    expect(result.period, isNull);
    expect(result.issues.single.failure, EnergyFailure.invalidTimezone);
    expect(api.calls.toSet(), {'config', 'prefs', 'info'});
  });
  test('bad unit, conflicting role and broken device hierarchy never expose usable totals', () async {
    final api = FakeEnergyApi()
      ..prefs = energyPreferences(
        devices: [
          {'stat_consumption': 'sensor.grid'},
          {
            'stat_consumption': 'sensor.cycle',
            'included_in_stat': 'sensor.cycle',
          },
          {'stat_consumption': 'sensor.voltage'},
        ],
      )
      ..metadata['sensor.voltage'] = energyMetadata(
        'sensor.voltage',
        unit: 'V',
        unitClass: 'voltage',
      );
    final result = await load(api);
    expect(result.meters.every((meter) => meter.reportedTotal == null), isTrue);
    expect(api.calls, isNot(contains('day')));
  });
  test('hourly failure retains HA-reported daily value with explicit incomplete coverage', () async {
    final api = FakeEnergyApi()
      ..hourlyError = HaApiException('denied', statusCode: 403);
    final result = await load(api);
    expect(result.meters.single.reportedTotal, 3);
    expect(result.meters.single.isPartial, isTrue);
    expect(
      result.meters.single.coverageIssues,
      containsAll([
        EnergyCoverageIssue.missingBaseline,
        EnergyCoverageIssue.hourlyGap,
      ]),
    );
    expect(result.issues.single.source, EnergySource.hourly);
    expect(result.issues.single.failure, EnergyFailure.permission);
    expect(api.calls.where((call) => call == 'hour'), hasLength(1));
  });
  test('direct currency stats are separate, configured and validated; wrong currency stays unknown', () async {
    final api = FakeEnergyApi()
      ..prefs = energyPreferences(
        sources: [
          {
            'type': 'grid',
            'stat_energy_from': 'sensor.grid',
            'stat_cost': 'sensor.cost',
          },
        ],
      )
      ..metadata['sensor.cost'] = energyMetadata(
        'sensor.cost',
        unit: 'TRY',
        unitClass: null,
      );
    final result = await load(api);
    expect(result.costsConfigured, isTrue);
    expect(
      result.meters
          .singleWhere((meter) => meter.role == EnergyRole.gridCost)
          .unit,
      'TRY',
    );
    api.currency = 'USD';
    final changed = await load(api);
    expect(
      changed.meters
          .singleWhere((meter) => meter.role == EnergyRole.gridCost)
          .reportedTotal,
      isNull,
    );
    expect(
      changed.meters
          .singleWhere((meter) => meter.role == EnergyRole.gridImport)
          .reportedTotal,
      3,
    );
  });
  test(
    'a failed meter does not hide another valid meter or become zero',
    () async {
      final api = FakeEnergyApi()
        ..prefs = energyPreferences(
          devices: [
            {'stat_consumption': 'sensor.device'},
          ],
        )
        ..daily = {
          'sensor.grid': [
            {
              ...energyPoint(
                DateTime.utc(2026, 9, 5),
                3,
                end: DateTime.utc(2026, 9, 6),
              ),
            },
          ],
          'sensor.device': [
            energyPoint(
              DateTime.utc(2026, 9, 5),
              double.nan,
              end: DateTime.utc(2026, 9, 6),
            ),
          ],
        };
      final result = await load(api);
      expect(
        result.meters
            .singleWhere((meter) => meter.statisticId == 'sensor.grid')
            .reportedTotal,
        3,
      );
      expect(
        result.meters
            .singleWhere((meter) => meter.statisticId == 'sensor.device')
            .reportedTotal,
        isNull,
      );
      expect(
        result.meters
            .singleWhere((meter) => meter.statisticId == 'sensor.device')
            .issues
            .single
            .failure,
        EnergyFailure.invalidResponse,
      );
    },
  );
  test('128 IDs are bounded into batches and duplicates do not multiply requests or readings', () async {
    final api = FakeEnergyApi()
      ..prefs = energyPreferences(
        devices: [
          for (var i = 0; i < 100; i++)
            {'stat_consumption': 'sensor.device_$i'},
        ],
      );
    final result = await load(api);
    expect(result.meters, hasLength(101));
    expect(
      api.batches.every(
        (batch) => batch.length <= 32 && batch.toSet().length == batch.length,
      ),
      isTrue,
    );
    expect(api.calls.where((call) => call == 'day'), hasLength(4));
  });
  test('cancellation after initial reads prevents metadata and statistics from starting', () async {
    final api = FakeEnergyApi()..gate = Completer<void>();
    var current = true;
    final future = EnergyRepository(
      api: api,
      now: () => api.now,
    ).load(EnergyRange.today, isCurrent: () => current);
    final rejected = expectLater(future, throwsA(isA<EnergyReadCancelled>()));
    current = false;
    api.gate!.complete();
    await rejected;
    expect(api.calls.toSet(), {'config', 'prefs', 'info'});
  });
}
