import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/dashboard/presentation/dashboard_card_editor_screen.dart';
import 'package:larenor/features/dashboard/presentation/dashboard_widget_picker_screen.dart';
import 'package:larenor/features/dashboard/presentation/tiles/home_accessory_tile.dart';
import 'package:larenor/features/dashboard/presentation/tiles/tile_registry.dart';
import 'package:larenor/features/dashboard/presentation/widgets/more_info_sheet.dart';
import 'package:larenor/features/dashboard/providers/dashboard_live_providers.dart';
import 'package:larenor/features/dashboard/providers/dashboard_providers.dart';
import 'package:larenor/features/dashboard/providers/entity_history_providers.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/navigation/search/providers/local_search_providers.dart';
import 'package:larenor/features/wellbeing/providers/wellbeing_privacy_providers.dart';
import 'package:larenor/features/wellbeing/providers/wellbeing_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

const privateScale = HaEntity(
  entityId: 'sensor.scale',
  state: '70',
  attributes: {'friendly_name': 'Synthetic scale', 'unit_of_measurement': 'kg'},
);
const lamp = HaEntity(
  entityId: 'light.lamp',
  state: 'on',
  attributes: {'friendly_name': 'Public lamp'},
);

class Privacy extends Notifier<AsyncValue<Set<String>>> {
  @override
  AsyncValue<Set<String>> build() => const AsyncData({});
  void hide() => state = const AsyncData({'sensor.scale'});
  void show() => state = const AsyncData({});
  void loading() => state = const AsyncLoading();
  void fail() => state = AsyncError(
    StateError('synthetic-storage-failure'),
    StackTrace.empty,
  );
}

final privacyFixture = NotifierProvider<Privacy, AsyncValue<Set<String>>>(
  Privacy.new,
);

class States extends Entities {
  @override
  Future<Map<String, HaEntity>> build() async => {
    'sensor.scale': privateScale,
    'light.lamp': lamp,
  };
}

class Connection extends ConnectionConfig {
  @override
  Future<HaConnectionConfig?> build() async => const HaConnectionConfig(
    baseUrl: 'https://fixture.invalid',
    token: 'synthetic',
  );
}

class Layout extends DashboardLayoutNotifier {
  @override
  Future<DashboardLayout> build() async => const DashboardLayout(
    favoriteEntityIds: ['sensor.scale', 'light.lamp'],
    rooms: [
      DashboardRoom(
        id: 'room',
        name: 'Room',
        entityIds: ['sensor.scale', 'light.lamp'],
      ),
    ],
  );
}

ProviderContainer container() => ProviderContainer(
  overrides: [
    wellbeingPrivateEntityIdsProvider.overrideWith(
      (ref) => ref.watch(privacyFixture),
    ),
    entitiesProvider.overrideWith(States.new),
    connectionConfigProvider.overrideWith(Connection.new),
    haWebSocketClientProvider.overrideWithValue(null),
    haRestClientProvider.overrideWithValue(null),
    dashboardWidgetRegistryProvider.overrideWith((ref) async => []),
    dashboardLayoutProvider.overrideWith(Layout.new),
  ],
);
Widget app(ProviderContainer container, Widget child) =>
    UncontrolledProviderScope(
      container: container,
      child: CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: CupertinoPageScaffold(child: child),
      ),
    );

void main() {
  testWidgets(
    'private sensor leaves widget picker and stale choice cannot select it',
    (tester) async {
      final c = container();
      await tester.pumpWidget(
        app(c, const DashboardWidgetPickerScreen(initialType: TileType.entity)),
      );
      await tester.pumpAndSettle();
      final choice = find.byKey(const ValueKey('widget-entity-sensor.scale'));
      expect(choice, findsOneWidget);
      final callback = tester.widget<CupertinoButton>(choice).onPressed!;
      c.read(privacyFixture.notifier).hide();
      await tester.pump();
      expect(find.text('Synthetic scale'), findsNothing);
      expect(find.text('sensor.scale'), findsNothing);
      callback();
      await tester.pump();
      expect(find.byType(DashboardWidgetPickerScreen), findsOneWidget);
      expect(find.text('Public lamp'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'static room editor hides private saved IDs and names without initializing clients',
    (tester) async {
      final c = container();
      final live = c.listen(entitiesProvider, (_, _) {});
      await c.read(entitiesProvider.future);
      await tester.pumpWidget(
        app(
          c,
          const DashboardCardEditorScreen(
            mode: DashboardEditorMode.room,
            roomId: 'room',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Synthetic scale'), findsOneWidget);
      c.read(privacyFixture.notifier).hide();
      await tester.pump();
      expect(find.text('Synthetic scale'), findsNothing);
      expect(find.text('sensor.scale'), findsNothing);
      expect(find.text('Public lamp'), findsOneWidget);
      expect(c.exists(haRestClientProvider), false);
      await tester.pumpWidget(const SizedBox());
      live.close();
      c.dispose();
    },
  );
  test('new binding removes names from cached search and favorite/room summaries immediately', () async {
    final c = container();
    addTearDown(c.dispose);
    await c.read(entitiesProvider.future);
    await c.read(dashboardLayoutProvider.future);
    final subs = [
      c.listen(localSearchIndexProvider, (_, _) {}),
      c.listen(dashboardSummaryProvider, (_, _) {}),
      c.listen(publicHaEntitiesProvider, (_, _) {}),
      c.listen(dashboardEntityProvider('sensor.scale'), (_, _) {}),
    ];
    final old = c.read(localSearchIndexProvider);
    expect(old.search('synthetic scale'), hasLength(1));
    expect(c.read(dashboardSummaryProvider).accessories, 2);
    c.read(privacyFixture.notifier).hide();
    final current = c.read(localSearchIndexProvider);
    expect(identical(old, current), false);
    expect(current.search('synthetic scale'), isEmpty);
    expect(current.search('public lamp'), hasLength(1));
    expect(c.read(dashboardVisibleIdsProvider), {'light.lamp'});
    expect(c.read(dashboardSummaryProvider).accessories, 1);
    expect(c.read(dashboardEntityProvider('sensor.scale')).attributes, isEmpty);
    expect(c.read(publicHaEntitiesProvider).requireValue.keys, ['light.lamp']);
    c.read(privacyFixture.notifier).show();
    expect(
      c.read(localSearchIndexProvider).search('synthetic scale'),
      hasLength(1),
    );
    for (final sub in subs) {
      sub.close();
    }
  });
  test(
    'loading and storage failure remove old public cache rather than fail open',
    () async {
      final c = container();
      addTearDown(c.dispose);
      await c.read(entitiesProvider.future);
      await c.read(dashboardLayoutProvider.future);
      final sub = c.listen(publicHaEntitiesProvider, (_, _) {});
      c.listen(localSearchIndexProvider, (_, _) {});
      expect(c.read(publicHaEntitiesProvider).requireValue.length, 2);
      c.read(privacyFixture.notifier).loading();
      expect(c.read(publicHaEntitiesProvider).isLoading, true);
      expect(c.read(publicHaEntitiesProvider).value, isNull);
      expect(c.read(localSearchIndexProvider).search('scale'), isEmpty);
      expect(c.read(dashboardVisibleIdsProvider), isEmpty);
      c.read(privacyFixture.notifier).fail();
      expect(c.read(publicHaEntitiesProvider).hasError, true);
      expect(c.read(publicHaEntitiesProvider).value, isNull);
      expect(c.read(localSearchIndexProvider).search('lamp'), isEmpty);
      sub.close();
    },
  );
  test(
    'private saved history does not initialize HTTP client or fetch history',
    () async {
      final c = container();
      addTearDown(c.dispose);
      c.read(privacyFixture.notifier).hide();
      final sub = c.listen(entityHistoryProvider('sensor.scale'), (_, _) {});
      expect(
        await c.read(entityHistoryProvider('sensor.scale').future),
        isNull,
      );
      expect(c.exists(haRestClientProvider), false);
      sub.close();
    },
  );
  testWidgets(
    'existing explicit accessory and custom title disappear when sensor becomes private',
    (tester) async {
      final c = container();
      await tester.pumpWidget(
        app(
          c,
          const SizedBox(
            width: 300,
            height: 200,
            child: HomeAccessoryTile(
              entity: privateScale,
              title: 'Private custom card',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Private custom card'), findsOneWidget);
      c.read(privacyFixture.notifier).hide();
      await tester.pump();
      expect(find.text('Private custom card'), findsNothing);
      expect(find.text('70 kg'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'saved history registry entry never mounts reader while private',
    (tester) async {
      final c = container();
      c.read(privacyFixture.notifier).hide();
      await tester.pumpWidget(
        app(
          c,
          SizedBox(
            width: 300,
            height: 250,
            child: buildTileContent(
              const TileConfig(
                id: 'private-history',
                x: 0,
                y: 0,
                type: TileType.history,
                entityId: 'sensor.scale',
                title: 'Private scale history',
                width: 2,
                height: 2,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Private scale history'), findsNothing);
      expect(c.exists(entityHistoryProvider('sensor.scale')), false);
      expect(c.exists(haRestClientProvider), false);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'direct MoreInfo destination cannot reveal private entity state',
    (tester) async {
      final c = container();
      await c.read(entitiesProvider.future);
      await c.read(connectionConfigProvider.future);
      await tester.pumpWidget(
        app(c, const EntityMoreInfo(entityId: 'sensor.scale', asPage: true)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Synthetic scale'), findsOneWidget);
      c.read(privacyFixture.notifier).hide();
      await tester.pumpAndSettle();
      expect(find.text('Synthetic scale'), findsNothing);
      expect(find.text('70'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
}
