import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/dashboard/providers/dashboard_live_providers.dart';
import 'package:larenor/features/energy/domain/maintenance_models.dart';
import 'package:larenor/features/energy/providers/energy_providers.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';
import 'package:larenor/features/ha_client/data/ws_client.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';

import 'energy_fixture.dart';

class _Config extends ConnectionConfig {
  @override
  Future<HaConnectionConfig?> build() async => const HaConnectionConfig(
    baseUrl: 'http://fixture.test',
    token: 'first-fixture',
  );
  void change(String token) => state = AsyncData(
    HaConnectionConfig(baseUrl: 'http://fixture.test', token: token),
  );
}

class _Entities extends Entities {
  _Entities(this.replacement);
  final Completer<Map<String, HaEntity>> replacement;
  @override
  Future<Map<String, HaEntity>> build() async {
    final config = await ref.watch(connectionConfigProvider.future);
    if (config?.token != 'first-fixture') return replacement.future;
    return const {
      'sensor.selected': HaEntity(
        entityId: 'sensor.selected',
        state: 'unavailable',
        attributes: {'friendly_name': 'Private selected device'},
      ),
      'update.other': HaEntity(entityId: 'update.other', state: 'on'),
    };
  }
}

Future<void> pumpProviders(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(Duration.zero);
  }
}

void main() {
  testWidgets(
    'account token change disposes old generation and late energy results cannot replace new account',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final gate = Completer<void>();
      final first = FakeEnergyApi()..gate = gate;
      final replacement = FakeEnergyApi()
        ..prefs = energyPreferences(
          sources: [
            {'type': 'grid', 'stat_energy_from': 'sensor.new_account'},
          ],
        );
      final container = ProviderContainer(
        retry: (_, _) => null,
        overrides: [
          connectionConfigProvider.overrideWith(_Config.new),
          energyApiProvider.overrideWith((ref) {
            final config = ref.watch(connectionConfigProvider);
            if (config.isLoading || config.hasError) return null;
            return config.value?.token == 'first-fixture' ? first : replacement;
          }),
          energyClockProvider.overrideWithValue(() => energyNow),
          haConnectionStatusProvider.overrideWith(
            (_) => Stream.value(HaConnectionStatus.disconnected),
          ),
        ],
      );
      addTearDown(container.dispose);
      final listener = container.listen(energyProvider, (_, _) {});
      await pumpProviders(tester);
      expect(first.calls, ['config', 'prefs', 'info']);
      final oldController = container.read(energyControllerProvider)!;
      (container.read(connectionConfigProvider.notifier) as _Config).change(
        'second-fixture',
      );
      await pumpProviders(tester);
      await pumpProviders(tester);
      expect(
        container.read(energyControllerProvider),
        isNot(same(oldController)),
      );
      expect(
        container
            .read(energyProvider)
            .value
            ?.snapshot
            ?.meters
            .single
            .statisticId,
        'sensor.new_account',
      );
      expect(oldController.state.connectionConfigured, isFalse);
      gate.complete();
      await pumpProviders(tester);
      expect(first.calls, ['config', 'prefs', 'info']);
      expect(
        container
            .read(energyProvider)
            .value
            ?.snapshot
            ?.meters
            .single
            .statisticId,
        'sensor.new_account',
      );
      listener.close();
      container.dispose();
      await tester.pump();
    },
  );
  testWidgets(
    'provider obeys application background and foreground, hidden page and disposal',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final api = FakeEnergyApi();
      final container = ProviderContainer(
        overrides: [
          connectionConfigProvider.overrideWith(_Config.new),
          energyApiProvider.overrideWith((_) => api),
          energyClockProvider.overrideWithValue(() => energyNow),
          haConnectionStatusProvider.overrideWith(
            (_) => Stream.value(HaConnectionStatus.disconnected),
          ),
        ],
      );
      addTearDown(container.dispose);
      final listener = container.listen(energyProvider, (_, _) {});
      await pumpProviders(tester);
      expect(api.calls.where((value) => value == 'config'), hasLength(1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(minutes: 10));
      expect(api.calls.where((value) => value == 'config'), hasLength(1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await pumpProviders(tester);
      expect(api.calls.where((value) => value == 'config'), hasLength(2));
      container.read(energyControllerProvider)!.setVisible(false);
      await tester.pump(const Duration(minutes: 10));
      expect(api.calls.where((value) => value == 'config'), hasLength(2));
      listener.close();
      await pumpProviders(tester);
      container.dispose();
      await tester.pump(const Duration(minutes: 10));
      expect(api.calls.where((value) => value == 'config'), hasLength(2));
    },
  );
  testWidgets(
    'maintenance selected and all scopes hide retained account metadata on loading and failure',
    (tester) async {
      final replacement = Completer<Map<String, HaEntity>>();
      final container = ProviderContainer(
        retry: (_, _) => null,
        overrides: [
          connectionConfigProvider.overrideWith(_Config.new),
          entitiesProvider.overrideWith(() => _Entities(replacement)),
          dashboardVisibleIdsProvider.overrideWith((_) => {'sensor.selected'}),
        ],
      );
      addTearDown(container.dispose);
      container.listen(
        maintenanceProvider(MaintenanceScope.selected),
        (_, _) {},
      );
      container.listen(maintenanceProvider(MaintenanceScope.all), (_, _) {});
      await pumpProviders(tester);
      expect(
        container
            .read(maintenanceProvider(MaintenanceScope.selected))
            .items
            .single
            .name,
        'Private selected device',
      );
      expect(
        container.read(maintenanceProvider(MaintenanceScope.all)).items,
        hasLength(2),
      );
      (container.read(connectionConfigProvider.notifier) as _Config).change(
        'second-fixture',
      );
      await pumpProviders(tester);
      expect(
        container.read(entitiesProvider).value,
        isNotEmpty,
        reason: 'exercise retained previous-account data',
      );
      for (final scope in MaintenanceScope.values) {
        final state = container.read(maintenanceProvider(scope));
        expect(state.isLoading, isTrue);
        expect(state.items, isEmpty);
      }
      replacement.completeError(StateError('Replacement failed'));
      await pumpProviders(tester);
      for (final scope in MaintenanceScope.values) {
        final state = container.read(maintenanceProvider(scope));
        expect(state.readFailed, isTrue);
        expect(state.items, isEmpty);
      }
      container.dispose();
      await tester.pump();
    },
  );
}
