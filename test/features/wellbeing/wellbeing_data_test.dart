import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/configuration_writes.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';
import 'package:larenor/features/ha_client/data/rest_client.dart';
import 'package:larenor/features/wellbeing/data/ha_wellbeing_api.dart';
import 'package:larenor/features/wellbeing/data/wellbeing_native_api.dart';
import 'package:larenor/features/wellbeing/data/wellbeing_store.dart';
import 'package:larenor/features/wellbeing/domain/wellbeing_models.dart';

final now = DateTime.utc(2026, 9, 5, 12);
final start = now.subtract(const Duration(days: 1));
final account = wellbeingAccountFingerprint(
  const HaConnectionConfig(
    baseUrl: 'https://one.invalid',
    token: 'synthetic-token',
  ),
);
HaWellbeingBinding binding({
  WellbeingMetric metric = WellbeingMetric.bodyMass,
  String? fingerprint,
  String entityId = 'sensor.scale',
}) => HaWellbeingBinding(
  id: 'binding1',
  accountFingerprint: fingerprint ?? account,
  entityId: entityId,
  metric: metric,
  profileLabel: 'Synthetic person',
);
HaEntity scale({String state = '70', String unit = 'kg'}) => HaEntity(
  entityId: 'sensor.scale',
  state: state,
  lastUpdated: now,
  attributes: {'unit_of_measurement': unit, 'friendly_name': 'Test scale'},
);
List<Object?> result({
  Object? value = 70,
  Object? time,
  String state = 'data',
  List<Object?>? records,
  String metric = 'bodyMass',
}) => [
  {
    'metric': metric,
    'state': state,
    'truncated': false,
    'records':
        records ??
        [
          {
            'id': 'synthetic-record',
            'value': value,
            'timeMillis':
                time ??
                now.subtract(const Duration(seconds: 1)).millisecondsSinceEpoch,
          },
        ],
  },
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test(
    'native error codes preserve safe failure kind without private details',
    () async {
      const channel = MethodChannel('test/wellbeing-native-errors');
      var code = 'timeout';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) async => throw PlatformException(
              code: code,
              message: 'private measurement fixture',
              details: {'value': 70},
            ),
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final api = ChannelWellbeingNativeApi(
        channel: channel,
        platform: TargetPlatform.android,
        now: () => now,
      );
      for (final entry in {
        'timeout': WellbeingFailure.timeout,
        'cancelled': WellbeingFailure.cancelled,
        'invalidData': WellbeingFailure.invalidData,
        'unavailable': WellbeingFailure.unavailable,
        'unknown-native': WellbeingFailure.readFailed,
      }.entries) {
        code = entry.key;
        await expectLater(
          api.read(
            metrics: {WellbeingMetric.bodyMass},
            start: start,
            end: now,
            profileLabel: 'Fixture',
          ),
          throwsA(
            isA<WellbeingException>()
                .having((e) => e.failure, 'failure', entry.value)
                .having(
                  (e) => e.toString(),
                  'safe message',
                  isNot(contains('private')),
                ),
          ),
        );
      }
    },
  );

  test(
    'Android channel sends bounded selected query and no profile alias',
    () async {
      const channel = MethodChannel('test/wellbeing-android');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return result();
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final api = ChannelWellbeingNativeApi(
        channel: channel,
        platform: TargetPlatform.android,
        now: () => now,
      );
      final readings = await api.read(
        metrics: {WellbeingMetric.bodyMass},
        start: start,
        end: now,
        profileLabel: 'Private alias fixture',
      );
      expect(
        readings.single.measurements.single.profileLabel,
        'Private alias fixture',
      );
      expect(calls.single.method, 'read');
      expect(calls.single.arguments, {
        'metrics': ['bodyMass'],
        'startMillis': start.millisecondsSinceEpoch,
        'endMillis': now.millisecondsSinceEpoch,
        'maxRecords': 500,
      });
      await expectLater(
        api.read(
          metrics: {WellbeingMetric.bodyMass},
          start: now.subtract(const Duration(days: 31)),
          end: now,
          profileLabel: 'Private alias fixture',
        ),
        throwsA(isA<WellbeingException>()),
      );
      expect(calls, hasLength(1));
    },
  );
  test(
    'secure configuration stores bindings but no credential or measurement',
    () async {
      final store = WellbeingStore();
      await store.save(
        WellbeingSettings(
          enabled: true,
          profileLabel: 'Synthetic profile',
          nativeMetrics: {WellbeingMetric.bodyMass},
          bindings: [binding()],
        ),
        isCurrent: () => true,
      );
      final loaded = await store.read();
      expect(loaded.bindings.single.accountFingerprint, account);
      final raw = (await const FlutterSecureStorage()
          .readAll())[WellbeingStore.storageKey]!;
      expect(raw, isNot(contains('synthetic-token')));
      expect(raw, isNot(contains('https://one.invalid')));
      expect(raw, isNot(contains('measuredAt')));
      expect(loaded.toString(), isNot(contains('Synthetic profile')));
      expect(loaded.bindings.single.toString(), isNot(contains(account)));
    },
  );
  test('queued save cannot persist after gate closes', () async {
    final blocker = Completer<void>();
    final head = ConfigurationWrites.run(() => blocker.future);
    var current = true;
    final pending = WellbeingStore().save(
      WellbeingSettings(enabled: true),
      isCurrent: () => current,
    );
    final check = expectLater(pending, throwsA(isA<WellbeingException>()));
    current = false;
    blocker.complete();
    await head;
    await check;
    expect(await const FlutterSecureStorage().readAll(), isEmpty);
  });
  test(
    'malformed secure storage fails closed instead of empty settings',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        WellbeingStore.storageKey: '{private invalid json',
      });
      await expectLater(
        WellbeingStore().read(),
        throwsA(
          isA<WellbeingException>().having(
            (e) => e.toString(),
            'safe',
            isNot(contains('private')),
          ),
        ),
      );
    },
  );
  test('binding schema rejects duplicate entity, steps mapping, unknown fields and labels', () {
    for (final settings in [
      WellbeingSettings(bindings: [binding(), binding()]),
      WellbeingSettings(bindings: [binding(metric: WellbeingMetric.steps)]),
      WellbeingSettings(profileLabel: 'A\nB'),
      WellbeingSettings(nativeMetrics: {WellbeingMetric.bodyMass}),
    ]) {
      expect(
        () => WellbeingStore.encode(settings),
        throwsA(isA<WellbeingException>()),
      );
    }
    final map = WellbeingStore.encode(WellbeingSettings());
    map['value'] = 70;
    expect(
      () => WellbeingStore.decode(map),
      throwsA(isA<WellbeingException>()),
    );
  });
  test(
    'account token and endpoint changes invalidate saved source fingerprint',
    () {
      expect(
        wellbeingAccountFingerprint(
          const HaConnectionConfig(
            baseUrl: 'https://one.invalid',
            token: 'synthetic-token',
          ),
        ),
        account,
      );
      expect(
        wellbeingAccountFingerprint(
          const HaConnectionConfig(
            baseUrl: 'https://two.invalid',
            token: 'synthetic-token',
          ),
        ),
        isNot(account),
      );
      expect(
        wellbeingAccountFingerprint(
          const HaConnectionConfig(
            baseUrl: 'https://one.invalid',
            token: 'replacement-token',
          ),
        ),
        isNot(account),
      );
    },
  );
  test('HA unit conversion preserves original value and separates state update from measurement time', () {
    final mapped = RestHaWellbeingApi.mapEntity(
      scale(state: '154.3235835294143', unit: 'lb'),
      binding(),
      now,
    );
    final sample = mapped.measurements.single;
    expect(sample.value, closeTo(70, .0001));
    expect(sample.originalUnit, 'lb');
    expect(sample.unit, 'kg');
    expect(sample.measuredAt, isNull);
    expect(sample.sourceUpdatedAt, now);
    expect(sample.readAt, now);
  });
  test('HA invalid states and wrong units never become zero measurements', () {
    for (final entity in [
      scale(state: 'unknown'),
      scale(state: 'unavailable'),
      scale(state: 'NaN'),
      scale(state: 'Infinity'),
      scale(state: '-3'),
      scale(unit: '%'),
    ]) {
      final mapped = RestHaWellbeingApi.mapEntity(entity, binding(), now);
      expect(mapped.state, WellbeingReadState.failed);
      expect(mapped.measurements, isEmpty);
    }
    expect(
      RestHaWellbeingApi.mapEntity(
        scale(state: '101', unit: '%'),
        binding(metric: WellbeingMetric.bodyFatPercentage),
        now,
      ).state,
      WellbeingReadState.failed,
    );
  });
  test('candidates read metadata only and never automatically bind or read measurement records', () async {
    final requests = <http.Request>[];
    final client = HaRestClient(
      baseUrl: 'https://one.invalid',
      token: 'test',
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode([
            scale().toJson(),
            scale(unit: '%').copyWith(entityId: 'sensor.humidity').toJson(),
            scale(unit: '°C').copyWith(entityId: 'sensor.temperature').toJson(),
          ]),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final api = RestHaWellbeingApi(
      client: client,
      accountFingerprint: account,
      isCurrent: () => true,
    );
    final candidates = await api.candidates();
    expect(candidates.map((e) => e.entityId), [
      'sensor.scale',
      'sensor.humidity',
    ]);
    expect(candidates.first.toString(), isNot(contains('70')));
    expect(requests.single.method, 'GET');
    expect(requests.single.url.path, '/api/states');
    client.dispose();
  });
  test(
    'different account bindings issue no GET even with same sensor id',
    () async {
      var calls = 0;
      final client = HaRestClient(
        baseUrl: 'https://one.invalid',
        token: 'test',
        httpClient: MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      final api = RestHaWellbeingApi(
        client: client,
        accountFingerprint: account,
        isCurrent: () => true,
      );
      final data = await api.read([binding(fingerprint: '0' * 64)]);
      expect(calls, 0);
      expect(data.single.failure, WellbeingFailure.accountChanged);
      client.dispose();
    },
  );
  test('late HA result after account change is discarded before next selected read', () async {
    final pending = Completer<http.Response>();
    var current = true, calls = 0;
    final client = HaRestClient(
      baseUrl: 'https://one.invalid',
      token: 'test',
      httpClient: MockClient((_) {
        calls++;
        return pending.future;
      }),
    );
    final api = RestHaWellbeingApi(
      client: client,
      accountFingerprint: account,
      isCurrent: () => current,
    );
    final reading = api.read([binding(), binding(entityId: 'sensor.other')]);
    final check = expectLater(reading, throwsA(isA<WellbeingException>()));
    await Future<void>.delayed(Duration.zero);
    current = false;
    pending.complete(http.Response(jsonEncode(scale().toJson()), 200));
    await check;
    expect(calls, 1);
    client.dispose();
  });
  test(
    'native parser preserves missing data vs per-type permission failure',
    () {
      final data = ChannelWellbeingNativeApi.parseResults(
        [
          {
            'metric': 'bodyMass',
            'state': 'empty',
            'records': [],
            'truncated': false,
          },
          {
            'metric': 'bodyFatPercentage',
            'state': 'failed',
            'failure': 'permission',
            'records': [],
            'truncated': false,
          },
        ],
        {WellbeingMetric.bodyMass, WellbeingMetric.bodyFatPercentage},
        WellbeingSource.healthConnect,
        'Test',
        now,
        start,
        now,
      );
      expect(data.first.state, WellbeingReadState.empty);
      expect(data.first.measurements, isEmpty);
      expect(data.last.failure, WellbeingFailure.permission);
    },
  );
  test('HealthKit granted-looking status remains unknown and empty may mean not shared', () {
    final status = ChannelWellbeingNativeApi.parseStatus(
      {
        'availability': 'available',
        'permissions': {'bodyMass': 'granted'},
      },
      WellbeingSource.healthKit,
      now,
    );
    expect(
      status.permissions[WellbeingMetric.bodyMass],
      WellbeingPermission.unknown,
    );
    final data = ChannelWellbeingNativeApi.parseResults(
      result(state: 'empty', records: []),
      {WellbeingMetric.bodyMass},
      WellbeingSource.healthKit,
      'Test',
      now,
      start,
      now,
    );
    expect(data.single.state, WellbeingReadState.emptyOrNotShared);
  });
  test('native parser rejects nonfinite, old data, overlarge and mismatched query replies', () {
    for (final raw in [
      result(value: double.nan),
      result(value: double.infinity),
      result(value: -1),
      result(time: now.millisecondsSinceEpoch),
      result(time: 9223372036854775807),
      result(
        time: start.subtract(const Duration(seconds: 1)).millisecondsSinceEpoch,
      ),
      result(metric: 'steps'),
      result(
        records: List.generate(
          501,
          (i) => {
            'id': '$i',
            'value': 70,
            'timeMillis': start.millisecondsSinceEpoch,
          },
        ),
      ),
    ]) {
      expect(
        () => ChannelWellbeingNativeApi.parseResults(
          raw,
          {WellbeingMetric.bodyMass},
          WellbeingSource.healthConnect,
          'Test',
          now,
          start,
          now,
        ),
        throwsA(isA<WellbeingException>()),
      );
    }
  });
  test('native duplicate ids collapse; equal values from distinct records stay distinct', () {
    final data = ChannelWellbeingNativeApi.parseResults(
      result(
        records: [
          for (final id in ['one', 'one', 'two'])
            {'id': id, 'value': 70, 'timeMillis': start.millisecondsSinceEpoch},
        ],
      ),
      {WellbeingMetric.bodyMass},
      WellbeingSource.healthConnect,
      'Test',
      now,
      start,
      now,
    );
    expect(data.single.measurements.length, 2);
  });
  test(
    'unsupported and pending native adapters never invoke platform channel',
    () async {
      const channel = MethodChannel('test/wellbeing-unsupported');
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls++;
            return null;
          });
      final ios = ChannelWellbeingNativeApi(
        channel: channel,
        platform: TargetPlatform.iOS,
      );
      expect(
        (await ios.probe()).availability,
        WellbeingAvailability.integrationPending,
      );
      expect(
        (await ios.requestReadPermissions({WellbeingMetric.bodyMass}))
            .availability,
        WellbeingAvailability.integrationPending,
      );
      final linux = ChannelWellbeingNativeApi(
        channel: channel,
        platform: TargetPlatform.linux,
      );
      expect(
        (await linux.probe()).availability,
        WellbeingAvailability.unsupportedPlatform,
      );
      expect(calls, 0);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    },
  );
}
