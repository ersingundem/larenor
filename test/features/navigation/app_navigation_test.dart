import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/router.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/features/dashboard/providers/dashboard_providers.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';
import 'package:larenor/features/ha_client/data/ws_client.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/media/hub/domain/media_library_index.dart';
import 'package:larenor/features/media/hub/providers/media_catalog_providers.dart';
import 'package:larenor/features/navigation/presentation/destination_screens.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Connection extends ConnectionConfig {
  @override
  Future<HaConnectionConfig?> build() async => const HaConnectionConfig(
    baseUrl: 'https://ha.example.test',
    token: 'fixture-only',
  );
}

class _Layout extends DashboardLayoutNotifier {
  @override
  Future<DashboardLayout> build() async => DashboardLayout(
    rooms: [
      DashboardRoom(
        id: 'salon',
        name: 'Salon',
        entityIds: [for (var i = 0; i < 50; i++) 'light.salon_$i'],
      ),
      const DashboardRoom(
        id: 'bedroom',
        name: 'Bedroom',
        entityIds: ['light.bed'],
      ),
    ],
  );
}

class _Entities extends Entities {
  @override
  Future<Map<String, HaEntity>> build() async => {
    for (var i = 0; i < 50; i++)
      'light.salon_$i': HaEntity(
        entityId: 'light.salon_$i',
        state: 'off',
        attributes: {'friendly_name': 'Salon light $i'},
      ),
    'light.bed': const HaEntity(
      entityId: 'light.bed',
      state: 'off',
      attributes: {'friendly_name': 'Bed lamp'},
    ),
  };
}

Future<ProviderContainer> openApp(WidgetTester tester, {String? pin}) async {
  SharedPreferences.setMockInitialValues({'enabled_services_migrated': true});
  FlutterSecureStorage.setMockInitialValues({'settings_pin': ?pin});
  final container = ProviderContainer(
    overrides: [
      connectionConfigProvider.overrideWith(_Connection.new),
      dashboardLayoutProvider.overrideWith(_Layout.new),
      entitiesProvider.overrideWith(_Entities.new),
      haRestClientProvider.overrideWithValue(null),
      haWebSocketClientProvider.overrideWithValue(null),
      haConnectionStatusProvider.overrideWith(
        (_) => Stream.value(HaConnectionStatus.connected),
      ),
      mediaLibraryIndexProvider.overrideWith(
        (_) async => MediaLibraryIndex.empty,
      ),
      mediaHubRowsProvider.overrideWith((_) async => const []),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: CupertinoApp.router(
        routerConfig: container.read(routerProvider),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets(
    'room selection and scroll survive tab round trip and window resize',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final container = await openApp(tester);
      final router = container.read(routerProvider);
      router.go('/rooms/salon');
      await tester.pumpAndSettle();
      final homeScroll = find.byKey(const PageStorageKey('home-salon'));
      await tester.drag(homeScroll, const Offset(0, -550));
      await tester.pumpAndSettle();
      double offset() => tester
          .state<ScrollableState>(
            find
                .descendant(of: homeScroll, matching: find.byType(Scrollable))
                .first,
          )
          .position
          .pixels;
      final before = offset();
      expect(before, greaterThan(100));
      var tabs = tester.widget<CupertinoTabBar>(find.byType(CupertinoTabBar));
      tabs.onTap!(1);
      await tester.pumpAndSettle();
      tabs = tester.widget<CupertinoTabBar>(find.byType(CupertinoTabBar));
      expect(tabs.currentIndex, 1);
      tabs.onTap!(0);
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, '/rooms/salon');
      expect(offset(), closeTo(before, 1));
      tester.view.physicalSize = const Size(1366, 768);
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoTabBar), findsNothing);
      expect(router.routeInformationProvider.value.uri.path, '/rooms/salon');
      expect(find.text('Routines'), findsOneWidget);
      expect(find.text('System'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'settings deep link remains PIN protected and missing room is explicit',
    (tester) async {
      final container = await openApp(tester, pin: '1234');
      final router = container.read(routerProvider);
      router.go('/settings');
      await tester.pumpAndSettle();
      expect(find.text('Unlock'), findsOneWidget);
      expect(find.text('Backup and restore'), findsNothing);
      router.go('/rooms/deleted-room');
      await tester.pumpAndSettle();
      expect(find.byType(MissingDestinationScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'media destination rejects malformed identities before requesting data',
    () {
      expect(
        mediaIdentityFromLocation(Uri.parse('/media/title?kind=movie&tmdb=42'))
            ?.tmdbId,
        42,
      );
      for (final query in [
        'kind=other&tmdb=42',
        'kind=movie&tmdb=-1',
        'kind=movie&imdb=hello',
        'kind=movie&jellyfin=../escape',
        'kind=tv',
      ]) {
        expect(
          mediaIdentityFromLocation(Uri.parse('/media/title?$query')),
          isNull,
        );
      }
    },
  );
}
