import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/dashboard/presentation/home_dashboard_screen.dart';
import 'package:larenor/features/dashboard/presentation/tiles/home_accessory_tile.dart';
import 'package:larenor/features/dashboard/presentation/widgets/home_surface.dart';
import 'package:larenor/features/settings/providers/enabled_services_providers.dart';
import 'package:larenor/features/ha_client/data/ws_client.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/features/dashboard/domain/home_domains.dart';
import 'package:larenor/features/dashboard/providers/dashboard_live_providers.dart';
import 'package:larenor/features/dashboard/providers/dashboard_providers.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';

class _Entities extends Entities {
  _Entities(this.initial);
  final Map<String, HaEntity> initial;

  @override
  Future<Map<String, HaEntity>> build() async => initial;

  void publish(Map<String, HaEntity> entities) => state = AsyncData(entities);
}

void main() {
  testWidgets(
    'a live accessory change retains navigation and other tile widgets',
    (tester) async {
      tester.view.physicalSize = const Size(1366, 1024);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final entities = _Entities({
        'light.one': const HaEntity(entityId: 'light.one', state: 'off'),
        'light.two': const HaEntity(entityId: 'light.two', state: 'off'),
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            entitiesProvider.overrideWith(() => entities),
            dashboardLayoutProvider.overrideWithBuild(
              (ref, notifier) async => const DashboardLayout(
                favoriteEntityIds: ['light.one', 'light.two'],
              ),
            ),
            enabledServicesProvider.overrideWithBuild(
              (ref, notifier) async => {},
            ),
            haConnectionStatusProvider.overrideWith(
              (ref) => Stream.value(HaConnectionStatus.connected),
            ),
          ],
          child: const CupertinoApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: HomeDashboardScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      HomeAccessoryTile tile(String id) => tester
          .widgetList<HomeAccessoryTile>(find.byType(HomeAccessoryTile))
          .singleWhere((tile) => tile.entity.entityId == id);
      final navigation = tester.widget(find.byType(HomeSidebar));
      final first = tile('light.one');
      final second = tile('light.two');
      entities.publish({
        ...entities.initial,
        'light.one': entities.initial['light.one']!.copyWith(state: 'on'),
      });
      await tester.pumpAndSettle();
      expect(
        identical(tester.widget(find.byType(HomeSidebar)), navigation),
        isTrue,
      );
      expect(identical(tile('light.two'), second), isTrue);
      expect(identical(tile('light.one'), first), isFalse);
      expect(tile('light.one').entity.state, 'on');
      expect(tester.takeException(), isNull);
    },
  );

  test(
    '5000 entities: unrelated state bursts do not notify dashboard consumers',
    () async {
      final initial = <String, HaEntity>{
        for (var i = 0; i < 5000; i++)
          'sensor.diagnostic_$i': HaEntity(
            entityId: 'sensor.diagnostic_$i',
            state: '0',
          ),
        'light.lamp': const HaEntity(entityId: 'light.lamp', state: 'off'),
        'sensor.room': const HaEntity(
          entityId: 'sensor.room',
          state: '20',
          attributes: {'device_class': 'temperature'},
        ),
      };
      final entities = _Entities(initial);
      final container = ProviderContainer(
        overrides: [
          entitiesProvider.overrideWith(() => entities),
          dashboardLayoutProvider.overrideWithBuild(
            (ref, notifier) async => const DashboardLayout(
              favoriteEntityIds: ['light.lamp', 'light.lamp'],
              hiddenEntityIds: ['sensor.diagnostic_1'],
              rooms: [
                DashboardRoom(
                  id: 'room',
                  name: 'Room',
                  entityIds: [
                    'light.lamp',
                    'sensor.room',
                    'sensor.diagnostic_1',
                  ],
                ),
              ],
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.listen(dashboardLayoutProvider, (_, _) {});
      await container.read(dashboardLayoutProvider.future);
      await container.read(entitiesProvider.future);
      var structureChanges = 0;
      var summaryChanges = 0;
      var lampChanges = 0;
      container.listen(
        dashboardCategoriesProvider,
        (_, _) => structureChanges++,
      );
      container.listen(dashboardSummaryProvider, (_, _) => summaryChanges++);
      container.listen(
        dashboardEntityProvider('light.lamp'),
        (_, _) => lampChanges++,
      );
      expect(container.read(dashboardSummaryProvider), (
        accessories: 2,
        lightsOn: 0,
        unavailable: 0,
      ));

      final changed = {...initial};
      for (var i = 0; i < 1000; i++) {
        changed['sensor.diagnostic_$i'] = initial['sensor.diagnostic_$i']!
            .copyWith(state: '1');
      }
      entities.publish(changed);
      await container.pump();
      expect((structureChanges, summaryChanges, lampChanges), (0, 0, 0));

      entities.publish({
        ...changed,
        'light.lamp': initial['light.lamp']!.copyWith(state: 'on'),
      });
      await container.pump();
      expect((structureChanges, summaryChanges, lampChanges), (0, 1, 1));
      expect(container.read(dashboardSummaryProvider).lightsOn, 1);

      entities.publish({
        ...changed,
        'light.lamp': initial['light.lamp']!.copyWith(state: 'on'),
        'sensor.room': initial['sensor.room']!.copyWith(
          attributes: {'device_class': 'motion'},
        ),
      });
      await container.pump();
      expect((structureChanges, summaryChanges, lampChanges), (1, 1, 1));
      expect(
        container.read(dashboardCategoriesProvider).byId['sensor.room'],
        HomeCategory.security,
      );
    },
  );

  test(
    'deletions stay removable and update only affected summaries and tiles',
    () async {
      final entities = _Entities({
        'light.lamp': const HaEntity(entityId: 'light.lamp', state: 'on'),
      });
      final container = ProviderContainer(
        overrides: [
          entitiesProvider.overrideWith(() => entities),
          dashboardLayoutProvider.overrideWithBuild(
            (ref, notifier) async =>
                const DashboardLayout(favoriteEntityIds: ['light.lamp']),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.listen(dashboardLayoutProvider, (_, _) {});
      await container.read(dashboardLayoutProvider.future);
      await container.read(entitiesProvider.future);
      container.listen(dashboardSummaryProvider, (_, _) {});
      container.listen(dashboardEntityProvider('light.lamp'), (_, _) {});
      entities.publish({});
      await container.pump();
      expect(container.read(dashboardSummaryProvider), (
        accessories: 1,
        lightsOn: 0,
        unavailable: 1,
      ));
      expect(
        container.read(dashboardEntityProvider('light.lamp')).state,
        'unavailable',
      );
    },
  );
}
