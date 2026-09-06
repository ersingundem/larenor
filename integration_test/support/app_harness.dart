import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/home_session_scope.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/core/configuration_scope.dart';
import 'package:larenor/features/auth/data/ha_discovery.dart';
import 'package:larenor/features/auth/presentation/connect_screen.dart';
import 'package:larenor/features/backup/data/backup_repository.dart';
import 'package:larenor/features/backup/presentation/backup_file_access.dart';
import 'package:larenor/features/backup/presentation/backup_screen.dart';
import 'package:larenor/features/dashboard/data/dashboard_repository.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/features/settings/presentation/settings_split_screen.dart';
import 'package:larenor/features/settings/domain/screen_program.dart';
import 'package:larenor/features/ha_client/data/ws_client.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/ha_client/providers/ha_health_bindings.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/io.dart';

import 'synthetic_ha_server.dart';
import 'synthetic_core_account.dart';
import 'synthetic_core_resources.dart';
import 'synthetic_core_resource_admin.dart';
import 'synthetic_core_resource_grants.dart';

/// OS file dialogs use ciphertext in memory. Preferences and credential storage
/// are also replaced in AppHarness; encryption, schema validation, repository
/// operations, PIN verification and full configuration reload are real.
class FixtureVaultFiles extends BackupFileAccess {
  Uint8List? ciphertext;
  String? filename;
  bool cancelNextPick = false;
  int saves = 0;
  int picks = 0;
  @override
  Future<Uri?> save(Uint8List bytes, String filename) async {
    saves++;
    ciphertext = Uint8List.fromList(bytes);
    this.filename = filename;
    return Uri.parse('content://larenor-e2e/synthetic.larenor-vault');
  }

  @override
  Future<Uint8List?> pick() async {
    picks++;
    if (cancelNextPick) {
      cancelNextPick = false;
      return null;
    }
    return ciphertext == null ? null : Uint8List.fromList(ciphertext!);
  }
}

class _NoNetworkDiscovery extends HaDiscoveryService {
  @override
  Future<void> start() async {}
}

class AppHarness {
  AppHarness._(this.server, this.network, this.previousNetwork, {bool cleanupOnly = false})
    : _cleanupOnly = cleanupOnly;

  /// Host-only teardown regression seam. It never starts or mounts the app,
  /// initializes storage, or relaxes the E2E-only gate in [start].
  factory AppHarness.forSyntheticCleanup(SyntheticHaServer server) =>
      AppHarness._(server, FixtureNetwork(server.port), HttpOverrides.current, cleanupOnly: true);
  final bool _cleanupOnly;
  final SyntheticHaServer server;
  final FixtureNetwork network;
  final HttpOverrides? previousNetwork;
  final files = FixtureVaultFiles();
  int wsClientsCreated = 0;
  static const pin = '2468';
  static const passphrase = 'Synthetic vault passphrase 2026';

  static Future<AppHarness> start({
    bool connected = false,
    bool coreSource = false,
    bool coreResources = false,
    bool coreResourceAdmin = false,
    bool coreResourceGrants = false,
  }) async {
    if (!const bool.fromEnvironment('LARENOR_E2E')) {
      throw StateError(
        'Use tool/run_android_e2e.sh with a disposable emulator.',
      );
    }
    if (coreResourceAdmin && (!coreSource || coreResources)) {
      throw ArgumentError(
        'Admin fixture requires its own explicit Core source.',
      );
    }
    if (coreResourceGrants &&
        (!coreSource || coreResources || coreResourceAdmin)) {
      throw ArgumentError(
        'Grants fixture requires its own explicit Core source.',
      );
    }
    final server = await SyntheticHaServer.start();
    if (coreSource) {
      server.coreAccount = SyntheticCoreAccount(
        resources: coreResources ? SyntheticCoreResources() : null,
        adminResources: coreResourceAdmin ? SyntheticCoreResourceAdmin() : null,
        grants: coreResourceGrants ? SyntheticCoreResourceGrants() : null,
      );
    }
    final harness = AppHarness._(
      server,
      FixtureNetwork(server.port),
      HttpOverrides.current,
    );
    HttpOverrides.global = harness.network;
    // No read of this device's existing preferences or credential store.
    FlutterSecureStorage.setMockInitialValues({
      'settings_pin': pin,
      if (connected) 'ha_base_url': server.baseUrl,
      if (connected) 'ha_token': SyntheticHaServer.token,
    });
    SharedPreferences.setMockInitialValues({
      'enabled_services_migrated': true,
      'enabled_services': <String>[],
      'idle_mode_enabled': false,
      'keep_screen_on': false,
      if (coreSource)
        SharedPreferencesHomeSourceStore.key: HomeSource.verifiedCore.name,
      ScreenProgram.preferenceKey: ScreenProgram().encode(),
    });
    await DashboardRepository().save(
      const DashboardLayout(
        rooms: [
          DashboardRoom(
            id: 'fixture-room',
            name: 'Fixture room',
            entityIds: ['sensor.fixture_temperature', 'light.fixture_lamp'],
          ),
        ],
        favoriteEntityIds: ['sensor.fixture_temperature'],
      ),
    );
    return harness;
  }

  Future<void> mount(WidgetTester tester) async {
    if (_cleanupOnly) throw StateError('Synthetic cleanup harness cannot mount.');
    // Android IME can asynchronously replay the prior empty editing value after
    // an obscured field is cleared by the app. Inject input through Flutter's
    // official test keyboard; these journeys do not claim native IME coverage.
    tester.testTextInput.register();
    tester.platformDispatcher.localesTestValue = const [Locale('en')];
    MediaKit.ensureInitialized();
    await tester.pumpWidget(
      ConfigurationScope(
        initialize: BackupRepository().recoverPendingRestore,
        child: ProviderScope(
          overrides: [
            homeSourceStoreProvider.overrideWithValue(
              SharedPreferencesHomeSourceStore(),
            ),
          ],
          child: HomeSessionScope(
            runtimeOverrides: [
              haDiscoveryFactoryProvider.overrideWithValue(
                _NoNetworkDiscovery.new,
              ),
              backupFileAccessProvider.overrideWithValue(files),
              // dart:io caches its default WebSocket HttpClient for the entire
              // isolate. Give each real HA client its fixture-bound transport,
              // so a previous journey's closed port cannot survive a new test.
              haWebSocketClientFactoryProvider.overrideWith(
                (ref) => (config, health) {
                  wsClientsCreated++;
                  final http = network.createHttpClient(null);
                  ref.onDispose(() => http.close(force: true));
                  return HaWebSocketClient(
                    baseUrl: config.baseUrl,
                    token: config.token,
                    connectionObserver: (event) =>
                        observeHaConnection(health, event),
                    channelFactory: (uri) =>
                        IOWebSocketChannel.connect(uri, customClient: http),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
    tester.platformDispatcher.clearLocalesTestValue();
    tester.testTextInput.unregister();
    HttpOverrides.global = previousNetwork;
    server.coreAccount?.adminResources?.close();
    server.coreAccount?.grants?.close();
    await server.close();
    expect(network.blocked, 0, reason: 'No production/external destinations');
    expect(
      server.rejectedWrites,
      0,
      reason: 'Only explicitly allowed fixture actions',
    );
    expect(server.coreAccount?.rejectedRequests ?? 0, 0);
  }
}

Future<void> waitFor(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(finder, findsWidgets);
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> waitUntil(
  WidgetTester tester,
  bool Function() condition, {
  String Function()? describe,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(condition(), isTrue, reason: describe?.call());
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump(const Duration(milliseconds: 500));
  if (finder.evaluate().isEmpty &&
      find.byType(Scrollable).evaluate().isNotEmpty) {
    await tester.scrollUntilVisible(
      finder,
      250,
      scrollable: find.byType(Scrollable).last,
      maxScrolls: 20,
    );
  }
  await waitFor(tester, finder);
  await tester.ensureVisible(finder.first);
  // Busy indicators underneath a confirmation dialog intentionally keep
  // scheduling frames. Wait for the route animation, not global quiescence.
  await tester.pump(const Duration(milliseconds: 500));
  await tester.tap(finder.first);
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> openSettings(WidgetTester tester) async {
  await tapVisible(tester, find.byKey(const ValueKey('global-settings')));
  await waitFor(tester, find.text('Unlock'));
  await tester.enterText(find.byType(CupertinoTextField), AppHarness.pin);
  await tapVisible(tester, find.text('Unlock'));
  await waitFor(tester, find.byType(SettingsSplitScreen));
}
