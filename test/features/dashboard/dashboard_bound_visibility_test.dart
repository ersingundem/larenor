import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/features/dashboard/domain/ha_area_binding.dart';
import 'package:larenor/features/dashboard/domain/home_domains.dart';
import 'package:larenor/features/dashboard/providers/dashboard_live_providers.dart';
import 'package:larenor/features/dashboard/providers/dashboard_providers.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';

class _Connection extends ConnectionConfig {
  @override
  Future<HaConnectionConfig?> build() async =>
      const HaConnectionConfig(baseUrl: 'http://first.test/', token: 'fixture');
  void setUrl(String url) =>
      state = AsyncData(HaConnectionConfig(baseUrl: url, token: 'fixture'));
  void setToken(String token) => state = AsyncData(
    HaConnectionConfig(baseUrl: 'http://first.test/', token: token),
  );
  void loading() => state = const AsyncLoading();
  void failed() =>
      state = AsyncError(StateError('Unavailable'), StackTrace.current);
}

class _Layout extends DashboardLayoutNotifier {
  _Layout(this.value);
  final DashboardLayout value;
  @override
  Future<DashboardLayout> build() async => value;
}

class _Entities extends Entities {
  @override
  Future<Map<String, HaEntity>> build() async => {
    for (final id in [
      'light.first',
      'light.second',
      'light.manual',
      'light.favorite',
    ])
      id: HaEntity(entityId: id, state: id == 'light.second' ? 'off' : 'on'),
  };
}

class _AccountEntities extends Entities {
  _AccountEntities(this.replacement);
  final Completer<Map<String, HaEntity>> replacement;
  @override
  Future<Map<String, HaEntity>> build() async {
    final connection = await ref.watch(connectionConfigProvider.future);
    if (connection?.token != 'fixture') return replacement.future;
    return const {
      'sensor.private': HaEntity(
        entityId: 'sensor.private',
        state: '22',
        attributes: {
          'friendly_name': 'Old private temperature',
          'device_class': 'temperature',
        },
      ),
      'light.secret': HaEntity(
        entityId: 'light.secret',
        state: 'on',
        attributes: {'friendly_name': 'Old private lamp'},
      ),
    };
  }
}

DashboardRoom _bound(String id, String server) => DashboardRoom(
  id: id,
  name: id,
  entityIds: ['light.$id'],
  areaBinding: HaAreaBinding(
    serverUrl: server,
    areaId: id,
    sourceName: id,
    importedEntityIds: ['light.$id'],
  ),
);

void main() {
  test('same-server token reload hides retained entity metadata and failed replacement cannot restore it', () async {
    final replacement = Completer<Map<String, HaEntity>>();
    final container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        connectionConfigProvider.overrideWith(_Connection.new),
        entitiesProvider.overrideWith(() => _AccountEntities(replacement)),
        dashboardLayoutProvider.overrideWith(
          () => _Layout(
            const DashboardLayout(
              rooms: [
                DashboardRoom(
                  id: 'room',
                  name: 'Room',
                  entityIds: ['sensor.private', 'light.secret'],
                ),
              ],
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(connectionConfigProvider.future);
    await container.read(dashboardLayoutProvider.future);
    await container.read(entitiesProvider.future);
    container.listen(dashboardSummaryProvider, (_, _) {});
    container.listen(dashboardCategoriesProvider, (_, _) {});
    container.listen(dashboardEntityProvider('sensor.private'), (_, _) {});
    expect(container.read(dashboardSummaryProvider).lightsOn, 1);
    expect(
      container.read(dashboardEntityProvider('sensor.private')).friendlyName,
      'Old private temperature',
    );
    expect(
      container.read(dashboardCategoriesProvider).byId['sensor.private'],
      HomeCategory.climate,
    );
    (container.read(connectionConfigProvider.notifier) as _Connection).setToken(
      'replacement-fixture',
    );
    await container.pump();
    expect(container.read(entitiesProvider).isReloading, isTrue);
    expect(
      container.read(entitiesProvider).value,
      isNotEmpty,
      reason: 'fixture exercises Riverpod retained cache',
    );
    expect(container.read(dashboardSummaryProvider).lightsOn, 0);
    expect(container.read(dashboardSummaryProvider).unavailable, 2);
    expect(
      container.read(dashboardEntityProvider('sensor.private')).attributes,
      isEmpty,
    );
    expect(
      container.read(dashboardCategoriesProvider).byId['sensor.private'],
      HomeCategory.other,
    );
    final rejected = expectLater(
      container.read(entitiesProvider.future),
      throwsStateError,
    );
    replacement.completeError(StateError('replacement read denied'));
    await rejected;
    await container.pump();
    expect(container.read(entitiesProvider).hasError, isTrue);
    expect(
      container.read(dashboardEntityProvider('sensor.private')).attributes,
      isEmpty,
    );
    expect(container.read(dashboardSummaryProvider).lightsOn, 0);
    expect(container.read(dashboardSummaryProvider).unavailable, 2);
  });
  test(
    'summary and categories exclude foreign bound rooms during account changes',
    () async {
      final container = ProviderContainer(
        overrides: [
          connectionConfigProvider.overrideWith(_Connection.new),
          entitiesProvider.overrideWith(_Entities.new),
          dashboardLayoutProvider.overrideWith(
            () => _Layout(
              DashboardLayout(
                rooms: [
                  _bound('first', 'http://first.test'),
                  _bound('second', 'http://second.test'),
                  const DashboardRoom(
                    id: 'manual',
                    name: 'Manual',
                    entityIds: ['light.manual'],
                  ),
                ],
                favoriteEntityIds: ['light.favorite'],
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(connectionConfigProvider.future);
      await container.read(dashboardLayoutProvider.future);
      await container.read(entitiesProvider.future);
      container.listen(dashboardSummaryProvider, (_, _) {});
      container.listen(dashboardCategoriesProvider, (_, _) {});
      expect(container.read(dashboardVisibleIdsProvider), {
        'light.first',
        'light.manual',
        'light.favorite',
      });
      expect(container.read(dashboardSummaryProvider).lightsOn, 3);
      final config =
          container.read(connectionConfigProvider.notifier) as _Connection;
      config.loading();
      expect(container.read(dashboardVisibleIdsProvider), {
        'light.manual',
        'light.favorite',
      });
      config.failed();
      expect(
        container.read(dashboardCategoriesProvider).byId.keys,
        unorderedEquals(['light.manual', 'light.favorite']),
      );
      config.setUrl('http://second.test');
      expect(container.read(dashboardVisibleIdsProvider), {
        'light.second',
        'light.manual',
        'light.favorite',
      });
      expect(container.read(dashboardSummaryProvider).lightsOn, 2);
      expect(
        container
            .read(dashboardCategoriesProvider)
            .byId
            .containsKey('light.first'),
        isFalse,
      );
    },
  );

  test(
    'manual layouts never initialize connection providers for visibility',
    () async {
      var connectionReads = 0;
      final container = ProviderContainer(
        overrides: [
          connectionConfigProvider.overrideWithBuild((ref, notifier) async {
            connectionReads++;
            return null;
          }),
          dashboardLayoutProvider.overrideWith(
            () => _Layout(
              const DashboardLayout(
                rooms: [
                  DashboardRoom(
                    id: 'room',
                    name: 'Room',
                    entityIds: ['light.manual'],
                  ),
                ],
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(dashboardLayoutProvider.future);
      expect(container.read(dashboardVisibleIdsProvider), {'light.manual'});
      expect(connectionReads, 0);
    },
  );
}
