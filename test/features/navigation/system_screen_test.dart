import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:larenor/features/keenetic/data/keenetic_config.dart';
import 'package:larenor/features/health/providers/health_providers.dart';
import 'package:larenor/features/keenetic/providers/keenetic_providers.dart';
import 'package:larenor/features/media/arr/providers/lidarr_providers.dart';
import 'package:larenor/features/media/arr/providers/radarr_providers.dart';
import 'package:larenor/features/media/arr/providers/readarr_providers.dart';
import 'package:larenor/features/media/arr/providers/sonarr_providers.dart';
import 'package:larenor/features/media/bazarr/providers/bazarr_providers.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_config.dart';
import 'package:larenor/features/media/jellyfin/data/models/jellyfin_item.dart';
import 'package:larenor/features/media/jellyfin/providers/jellyfin_providers.dart';
import 'package:larenor/features/media/jellyseerr/providers/jellyseerr_providers.dart';
import 'package:larenor/features/media/prowlarr/providers/prowlarr_providers.dart';
import 'package:larenor/features/media/qbittorrent/providers/qbittorrent_providers.dart';
import 'package:larenor/features/navigation/presentation/system_screen.dart';
import 'package:larenor/features/navigation/providers/service_connection_providers.dart';
import 'package:larenor/features/proxmox/data/proxmox_config.dart';
import 'package:larenor/features/proxmox/presentation/proxmox_connect_screen.dart';
import 'package:larenor/features/proxmox/providers/proxmox_providers.dart';
import 'package:larenor/features/settings/data/app_service.dart';
import 'package:larenor/features/settings/presentation/settings_gate_screen.dart';
import 'package:larenor/features/settings/providers/enabled_services_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Enabled extends EnabledServices {
  _Enabled(this.services);
  final Set<AppService> services;
  @override
  Future<Set<AppService>> build() async => services;
}

class _Proxmox extends ProxmoxConnection {
  _Proxmox({this.config = savedProxmox, this.fail = false});
  ProxmoxConfig? config;
  bool fail;
  int reads = 0;
  int signOutCalls = 0;
  @override
  Future<ProxmoxConfig?> build() async {
    reads++;
    if (fail) throw StateError('storage details must not be displayed');
    return config;
  }

  void disconnect() => state = const AsyncData(null);
  @override
  Future<void> signOut() async {
    signOutCalls++;
    disconnect();
  }
}

class _Keenetic extends KeeneticConnection {
  int signOutCalls = 0;
  @override
  Future<KeeneticConfig?> build() async => const KeeneticConfig(
    baseUrl: 'https://router.invalid',
    username: 'test',
    password: 'test',
  );
  @override
  Future<void> signOut({bool Function()? isCurrent}) async {
    if (isCurrent != null && !isCurrent()) return;
    signOutCalls++;
  }
}

class _Jellyfin extends JellyfinConnection {
  int signOutCalls = 0;
  @override
  Future<JellyfinConfig?> build() async => const JellyfinConfig(
    baseUrl: 'https://media.invalid',
    userId: 'test',
    accessToken: 'test',
    deviceId: 'test',
  );
  @override
  Future<void> signOut() async => signOutCalls++;
}

const savedProxmox = ProxmoxConfig(
  host: 'server.invalid',
  port: 8006,
  username: 'test',
  realm: 'pve',
  password: 'test',
  allowSelfSigned: false,
);

Future<GoRouter> _show(
  WidgetTester tester,
  ProviderContainer container, {
  Widget page = const SystemScreen(),
  bool realSettingsGate = false,
}) async {
  tester.view.physicalSize = const Size(500, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (context, state) => page),
      GoRoute(
        path: '/settings',
        builder: (context, state) => realSettingsGate
            ? const SettingsGateScreen()
            : const CupertinoPageScaffold(
                child: Center(child: Text('Protected settings')),
              ),
      ),
      GoRoute(
        path: '/system/:service',
        builder: (context, state) => OperationalServiceScreen(
          service: AppService.values.byName(state.pathParameters['service']!),
        ),
      ),
      GoRoute(path: '/search', builder: (context, state) => const SizedBox()),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: CupertinoApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

Future<void> _close(WidgetTester tester, ProviderContainer container) async {
  // This fixture owns its container separately from the widget tree. Unmount
  // within the test zone so auto-disposed UI clocks can stop before invariants.
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const SizedBox()),
  );
  await tester.pumpAndSettle();
  expect(container.exists(healthClockProvider), isFalse);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'enabled_services_migrated': true});
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets(
    'lists enabled or saved services without starting any remote client',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          enabledServicesProvider.overrideWith(
            () => _Enabled({AppService.keenetic}),
          ),
          proxmoxConnectionProvider.overrideWith(_Proxmox.new),
        ],
      );
      addTearDown(container.dispose);
      await _show(tester, container);
      expect(find.byKey(const ValueKey('system-proxmox')), findsOneWidget);
      expect(find.byKey(const ValueKey('system-keenetic')), findsOneWidget);
      expect(find.byKey(const ValueKey('system-jellyfin')), findsNothing);
      expect(find.text('Saved connection'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('system-keenetic')),
          matching: find.text('No saved connection'),
        ),
        findsOneWidget,
      );
      expect([
        container.exists(jellyfinClientProvider),
        container.exists(jellyseerrClientProvider),
        container.exists(sonarrClientProvider),
        container.exists(radarrClientProvider),
        container.exists(lidarrClientProvider),
        container.exists(readarrClientProvider),
        container.exists(bazarrClientProvider),
        container.exists(prowlarrClientProvider),
        container.exists(qbittorrentClientProvider),
        container.exists(proxmoxClientProvider),
        container.exists(keeneticClientProvider),
      ], everyElement(isFalse));
      expect(find.textContaining('server.invalid'), findsNothing);
      await _close(tester, container);
    },
  );

  for (final service in AppService.values) {
    testWidgets(
      '${service.name} missing connection opens PIN protected settings, never inline setup',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({'settings_pin': '1234'});
        final container = ProviderContainer();
        addTearDown(container.dispose);
        await _show(
          tester,
          container,
          page: OperationalServiceScreen(service: service),
          realSettingsGate: true,
        );
        expect(find.byType(CupertinoTextField), findsNothing);
        expect(find.text('No saved connection'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('system-configure')));
        await tester.pumpAndSettle();
        expect(find.text('Unlock'), findsOneWidget);
        expect(find.text('Integrations'), findsNothing);
        await _close(tester, container);
      },
    );
  }

  testWidgets(
    'removing credentials closes operational content without exposing setup',
    (tester) async {
      final connection = _Proxmox();
      final container = ProviderContainer(
        overrides: [
          proxmoxConnectionProvider.overrideWith(() => connection),
          proxmoxNodesProvider.overrideWith((ref) async => []),
        ],
      );
      addTearDown(container.dispose);
      await _show(
        tester,
        container,
        page: const OperationalServiceScreen(service: AppService.proxmox),
      );
      expect(find.text('Proxmox VE'), findsWidgets);
      connection.disconnect();
      await tester.pumpAndSettle();
      expect(find.text('Proxmox VE'), findsNothing);
      expect(find.byType(ProxmoxConnectScreen), findsNothing);
      expect(find.byKey(const ValueKey('system-configure')), findsOneWidget);
      expect(
        container
            .read(savedServiceConnectionProvider(AppService.proxmox))
            .value,
        isFalse,
      );
      await _close(tester, container);
    },
  );

  testWidgets('storage failures stay generic and retry rereads the source', (
    tester,
  ) async {
    final connection = _Proxmox(fail: true);
    final container = ProviderContainer(
      retry: (count, error) => null,
      overrides: [
        proxmoxConnectionProvider.overrideWith(() => connection),
        proxmoxNodesProvider.overrideWith((ref) async => []),
      ],
    );
    addTearDown(container.dispose);
    await _show(
      tester,
      container,
      page: const OperationalServiceScreen(service: AppService.proxmox),
    );
    expect(find.text('Error'), findsOneWidget);
    expect(find.textContaining('storage details'), findsNothing);
    expect(find.byType(ProxmoxConnectScreen), findsNothing);
    expect(connection.reads, 1);
    connection.fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(connection.reads, 2);
    expect(find.text('Proxmox VE'), findsWidgets);
    await _close(tester, container);
  });

  for (final service in [
    AppService.proxmox,
    AppService.keenetic,
    AppService.jellyfin,
  ]) {
    testWidgets(
      '${service.name} operational account action routes to Settings without sign out',
      (tester) async {
        final proxmox = _Proxmox();
        final keenetic = _Keenetic();
        final jellyfin = _Jellyfin();
        final container = ProviderContainer(
          overrides: [
            proxmoxConnectionProvider.overrideWith(() => proxmox),
            proxmoxNodesProvider.overrideWith((ref) async => []),
            keeneticConnectionProvider.overrideWith(() => keenetic),
            keeneticRouterStatusProvider.overrideWith((ref) async => null),
            keeneticDevicesProvider.overrideWith((ref) async => []),
            keeneticAccessPointsProvider.overrideWith((ref) async => []),
            jellyfinConnectionProvider.overrideWith(() => jellyfin),
            jellyfinResumeItemsProvider.overrideWith((ref) async => []),
            jellyfinLatestItemsProvider.overrideWith((ref) async => []),
            jellyfinLibrariesProvider.overrideWith(
              (ref) async => [
                const JellyfinItem(
                  id: 'library',
                  name: 'Movies',
                  type: 'CollectionFolder',
                ),
              ],
            ),
          ],
        );
        addTearDown(container.dispose);
        await _show(
          tester,
          container,
          page: OperationalServiceScreen(service: service),
        );
        expect(find.byIcon(CupertinoIcons.square_arrow_right), findsNothing);
        await tester.tap(find.byKey(const ValueKey('service-account-action')));
        await tester.pumpAndSettle();
        expect(find.text('Protected settings'), findsOneWidget);
        expect(
          proxmox.signOutCalls + keenetic.signOutCalls + jellyfin.signOutCalls,
          0,
        );
        await _close(tester, container);
      },
    );
  }

  testWidgets(
    'operational detail retains a back button alongside refresh and account actions',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          enabledServicesProvider.overrideWith(
            () => _Enabled({AppService.proxmox}),
          ),
          proxmoxConnectionProvider.overrideWith(_Proxmox.new),
          proxmoxNodesProvider.overrideWith((ref) async => []),
        ],
      );
      addTearDown(container.dispose);
      await _show(tester, container);
      await tester.tap(find.byKey(const ValueKey('system-proxmox')));
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoNavigationBarBackButton), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.refresh), findsOneWidget);
      await tester.tap(find.byType(CupertinoNavigationBarBackButton));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('system-proxmox')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _close(tester, container);
    },
  );
}
