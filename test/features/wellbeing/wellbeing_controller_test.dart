import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/ha_client/data/rest_client.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/wellbeing/data/ha_wellbeing_api.dart';
import 'package:larenor/features/wellbeing/data/wellbeing_controller.dart';
import 'package:larenor/features/wellbeing/data/wellbeing_native_api.dart';
import 'package:larenor/features/wellbeing/data/wellbeing_store.dart';
import 'package:larenor/features/wellbeing/domain/wellbeing_models.dart';
import 'package:larenor/features/wellbeing/providers/wellbeing_providers.dart';

import 'wellbeing_data_test.dart' show now, account, binding, scale;

class FakeNative implements WellbeingNativeApi {
  int probes = 0, permissions = 0, reads = 0, cancellations = 0;
  Set<WellbeingMetric> lastMetrics = {};
  Completer<WellbeingProviderStatus>? permissionGate;
  Completer<List<WellbeingReadResult>>? readGate;
  bool failRead = false;
  final grants = <WellbeingMetric, WellbeingPermission>{
    for (final metric in WellbeingMetric.values)
      metric: WellbeingPermission.granted,
  };
  @override
  WellbeingSource get source => WellbeingSource.healthConnect;
  WellbeingProviderStatus get status => WellbeingProviderStatus(
    source: source,
    availability: WellbeingAvailability.available,
    permissions: grants,
  );
  @override
  Future<WellbeingProviderStatus> probe() async {
    probes++;
    return status;
  }

  @override
  Future<WellbeingProviderStatus> requestReadPermissions(
    Set<WellbeingMetric> metrics,
  ) async {
    permissions++;
    lastMetrics = metrics;
    return permissionGate == null ? status : await permissionGate!.future;
  }

  @override
  Future<List<WellbeingReadResult>> read({
    required Set<WellbeingMetric> metrics,
    required DateTime start,
    required DateTime end,
    required String profileLabel,
  }) async {
    reads++;
    lastMetrics = metrics;
    if (failRead) throw StateError('private-value-in-native-error');
    if (readGate != null) return readGate!.future;
    return [
      for (final metric in metrics)
        WellbeingReadResult(
          source: source,
          metric: metric,
          state: WellbeingReadState.empty,
          readAt: now,
        ),
    ];
  }

  @override
  Future<void> cancel() async {
    cancellations++;
  }

  @override
  Future<void> openPermissionSettings() async {}
}

class MemoryStore extends WellbeingStore {
  WellbeingSettings settings = WellbeingSettings();
  Object? failure;
  @override
  Future<WellbeingSettings> read() async {
    if (failure != null) throw failure!;
    return settings;
  }

  @override
  Future<void> save(
    WellbeingSettings value, {
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) throw const WellbeingException(WellbeingFailure.locked);
    settings = value;
  }
}

class Connection extends ConnectionConfig {
  @override
  Future<HaConnectionConfig?> build() async => const HaConnectionConfig(
    baseUrl: 'https://one.invalid',
    token: 'synthetic-token',
  );
  void replace() => state = const AsyncData(
    HaConnectionConfig(baseUrl: 'https://second.invalid', token: 'new-test'),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeNative native;
  late WellbeingController controller;
  var access = true;
  setUp(() {
    native = FakeNative();
    access = true;
    controller = WellbeingController(
      nativeApi: native,
      haApi: null,
      settings: WellbeingSettings(
        enabled: true,
        profileLabel: 'Test',
        nativeMetrics: {
          WellbeingMetric.bodyMass,
          WellbeingMetric.bodyFatPercentage,
        },
      ),
      accessCurrent: () => access,
      now: () => now,
    );
  });
  tearDown(() => controller.dispose());

  test(
    'construction and invisible route never probe, request permission or read',
    () async {
      await controller.probe();
      await controller.refresh();
      await controller.requestNativePermissions({WellbeingMetric.bodyMass});
      expect((native.probes, native.permissions, native.reads), (0, 0, 0));
    },
  );
  test('visible but locked route never accesses sources', () async {
    controller.setVisible(true);
    access = false;
    await controller.probe();
    await controller.loadHaCandidates();
    await controller.refresh();
    expect((native.probes, native.permissions, native.reads), (0, 0, 0));
  });
  test(
    'permission request only selected configured types and no automatic read',
    () async {
      controller.setVisible(true);
      await controller.requestNativePermissions({WellbeingMetric.bodyMass});
      expect(native.lastMetrics, {WellbeingMetric.bodyMass});
      expect(native.permissions, 1);
      expect(native.reads, 0);
      await controller.requestNativePermissions({WellbeingMetric.steps});
      expect(native.permissions, 1);
      expect(controller.snapshot.failure, WellbeingFailure.locked);
    },
  );
  test(
    'permission callback after background cannot reveal or read anything',
    () async {
      native.permissionGate = Completer();
      controller.setVisible(true);
      final first = controller.requestNativePermissions({
        WellbeingMetric.bodyMass,
      });
      final duplicate = controller.requestNativePermissions({
        WellbeingMetric.bodyMass,
      });
      expect(native.permissions, 1);
      controller.setForeground(false);
      native.permissionGate!.complete(native.status);
      await first;
      await duplicate;
      expect(controller.snapshot.statuses, isEmpty);
      expect(native.reads, 0);
      controller.setForeground(true);
      expect(native.reads, 0);
    },
  );
  test('partial native grants read only allowed type and preserve failure separately', () async {
    native.grants[WellbeingMetric.bodyFatPercentage] =
        WellbeingPermission.denied;
    controller.setVisible(true);
    await controller.refresh();
    expect(native.lastMetrics, {WellbeingMetric.bodyMass});
    expect(
      controller.snapshot.results.map((e) => e.state),
      containsAll([WellbeingReadState.failed, WellbeingReadState.empty]),
    );
    expect(
      controller.snapshot.results
          .singleWhere((e) => e.metric == WellbeingMetric.bodyFatPercentage)
          .failure,
      WellbeingFailure.permission,
    );
  });
  test(
    'partial permission failure remains unique when allowed read fails',
    () async {
      native.grants[WellbeingMetric.bodyFatPercentage] =
          WellbeingPermission.denied;
      native.failRead = true;
      controller.setVisible(true);
      await controller.refresh();
      expect(controller.snapshot.results, hasLength(2));
      expect(
        controller.snapshot.results
            .singleWhere((r) => r.metric == WellbeingMetric.bodyFatPercentage)
            .failure,
        WellbeingFailure.permission,
      );
      expect(
        controller.snapshot.results
            .singleWhere((r) => r.metric == WellbeingMetric.bodyMass)
            .failure,
        WellbeingFailure.readFailed,
      );
    },
  );
  for (final reason in ['hidden', 'background', 'access', 'dispose']) {
    test(
      'late native result after $reason never publishes private data',
      () async {
        controller.setVisible(true);
        native.readGate = Completer();
        final read = controller.refresh();
        await Future<void>.delayed(Duration.zero);
        expect(native.reads, 1);
        switch (reason) {
          case 'hidden':
            controller.setVisible(false);
          case 'background':
            controller.setForeground(false);
          case 'access':
            access = false;
            controller.clear();
          case 'dispose':
            controller.dispose();
        }
        native.readGate!.complete([
          WellbeingReadResult(
            source: native.source,
            metric: WellbeingMetric.bodyMass,
            state: WellbeingReadState.data,
            measurements: [
              WellbeingMeasurement(
                source: native.source,
                metric: WellbeingMetric.bodyMass,
                value: 70,
                unit: 'kg',
                profileLabel: 'Private fixture',
                readAt: now,
              ),
            ],
          ),
        ]);
        await read;
        expect(controller.snapshot.results, isEmpty);
        expect(controller.snapshot.busy, false);
        expect(native.cancellations, greaterThan(0));
      },
    );
  }
  test(
    'read failures are sanitized and do not retain previous measurements',
    () async {
      controller.setVisible(true);
      await controller.refresh();
      native.failRead = true;
      await controller.refresh();
      expect(
        controller.snapshot.results.every(
          (e) => e.state == WellbeingReadState.failed,
        ),
        isTrue,
      );
      expect(
        controller.snapshot.results.toString(),
        isNot(contains('private-value')),
      );
      expect(
        controller.snapshot.results.every((e) => e.measurements.isEmpty),
        isTrue,
      );
    },
  );
  test('HA batch stops before next request when route hides', () async {
    final gate = Completer<http.Response>();
    var calls = 0;
    final client = HaRestClient(
      baseUrl: 'https://one.invalid',
      token: 'test',
      httpClient: MockClient((_) {
        calls++;
        return gate.future;
      }),
    );
    final scoped = WellbeingController(
      nativeApi: native,
      accessCurrent: () => true,
      settings: WellbeingSettings(
        enabled: true,
        bindings: [
          binding(),
          binding(entityId: 'sensor.other'),
        ],
      ),
      haApi: RestHaWellbeingApi(
        client: client,
        accountFingerprint: account,
        isCurrent: () => true,
      ),
    );
    scoped.setVisible(true);
    final read = scoped.refresh();
    await Future<void>.delayed(Duration.zero);
    scoped.setVisible(false);
    gate.complete(http.Response(jsonEncode(scale().toJson()), 200));
    await read;
    expect(calls, 1);
    expect(scoped.snapshot.results, isEmpty);
    scoped.dispose();
    client.dispose();
  });
  test(
    'root provider is passive when no private access scope exists',
    () async {
      final container = ProviderContainer(
        overrides: [wellbeingNativeApiProvider.overrideWithValue(native)],
      );
      final sub = container.listen(wellbeingProvider, (_, _) {});
      await container.read(wellbeingProvider.future);
      expect(container.read(wellbeingControllerProvider), isNull);
      expect(container.exists(connectionConfigProvider), false);
      expect(container.exists(wellbeingSettingsProvider), false);
      expect(native.probes, 0);
      sub.close();
      container.dispose();
    },
  );
  test('private entity filter preserves loading/error and remains private after opt-out', () async {
    final store = MemoryStore()
      ..settings = WellbeingSettings(bindings: [binding()]);
    final container = ProviderContainer(
      overrides: [wellbeingStoreProvider.overrideWithValue(store)],
    );
    final sub = container.listen(wellbeingPrivateEntityIdsProvider, (_, _) {});
    expect(container.read(wellbeingPrivateEntityIdsProvider).isLoading, true);
    await container.read(wellbeingSettingsProvider.future);
    expect(container.read(wellbeingPrivateEntityIdsProvider).requireValue, {
      'sensor.scale',
    });
    store.failure = StateError('private-storage');
    container.invalidate(wellbeingSettingsProvider);
    await expectLater(
      container.read(wellbeingSettingsProvider.future),
      throwsA(isA<StateError>()),
    );
    expect(container.read(wellbeingPrivateEntityIdsProvider).hasError, true);
    sub.close();
    container.dispose();
  });
  test('scoped provider discards old-account read completion', () async {
    final store = MemoryStore()
      ..settings = WellbeingSettings(enabled: true, bindings: [binding()]);
    final gate = Completer<http.Response>();
    final firstClient = HaRestClient(
      baseUrl: 'https://one.invalid',
      token: 'test',
      httpClient: MockClient((_) => gate.future),
    );
    final config = Connection();
    final container = ProviderContainer(
      overrides: [
        wellbeingAccessProvider.overrideWithValue(
          WellbeingAccessSession(isCurrent: () => true),
        ),
        wellbeingStoreProvider.overrideWithValue(store),
        wellbeingNativeApiProvider.overrideWithValue(native),
        connectionConfigProvider.overrideWith(() => config),
        haRestClientProvider.overrideWithValue(firstClient),
      ],
    );
    await container.read(wellbeingSettingsProvider.future);
    await container.read(connectionConfigProvider.future);
    final sub = container.listen(wellbeingControllerProvider, (_, _) {});
    final old = container.read(wellbeingControllerProvider)!;
    old.setVisible(true);
    final reading = old.refresh();
    await Future<void>.delayed(Duration.zero);
    config.replace();
    await container.pump();
    gate.complete(http.Response(jsonEncode(scale().toJson()), 200));
    await reading;
    expect(old.snapshot.results, isEmpty);
    expect(identical(old, container.read(wellbeingControllerProvider)), false);
    expect(
      container.read(wellbeingControllerProvider)!.snapshot.results,
      isEmpty,
    );
    sub.close();
    container.dispose();
    firstClient.dispose();
  });
}
